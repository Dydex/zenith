// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AbstractCallback} from "@reactive/src/base/AbstractCallback.sol";
import {IPayable} from "@reactive/src/interfaces/IPayable.sol";

import {IZenithHook, IZenithSettler} from "./interfaces/IZenith.sol";

/// @title ZenithKeeper
/// @notice Receives Reactive Network callbacks on the hook's chain and runs Zenith's scheduled work: it settles every
/// sleeve whose period is over, releases vested slashes to depositors and force-closes sleeves whose bond no longer
/// covers them. Every action it takes is a public function anyone can call, so Zenith keeps working if Reactive
/// stops; the keeper only makes sure someone always does.
/// @dev Built on Reactive Omni. The callback proxy calls this contract and writes the address of the reactive
/// contract that asked for the callback over its first argument. The keeper accepts a callback only from the proxy
/// and only for its own reactive contract, fixed at deployment. The proxy bills callbacks to this contract in native
/// ETH, even ones it rejects, so it must hold some; a keeper in debt receives nothing until `coverDebt` is called.
contract ZenithKeeper is AbstractCallback {
    /// @notice Gas kept back for one sleeve's settlement. A sweep stops before a sleeve it might not finish and
    /// resumes from that sleeve on the next tick, so no sleeve is starved by the ones before it.
    uint256 public constant GAS_PER_SLEEVE = 2_500_000;

    IZenithHook public immutable hook;
    IZenithSettler public immutable settler;

    /// @notice The sleeve the next sweep starts from.
    uint256 public cursor;

    event Swept(uint256 visited, uint256 settled, uint256 released, uint256 closed);
    event ActionFailed(uint256 indexed sleeveId, bytes4 indexed action, bytes reason);

    /// @param _settler The Zenith settler whose sleeves this keeper looks after.
    /// @param callbackProxy Reactive's callback proxy on this chain.
    /// @param reactive The reactive contract allowed to ask this keeper for work.
    constructor(IZenithSettler _settler, IPayable callbackProxy, address reactive)
        payable
        AbstractCallback(callbackProxy, reactive)
    {
        settler = _settler;
        hook = IZenithHook(_settler.hook());
    }

    // ------------------------------------------------------------------
    // Reactive entry points
    // ------------------------------------------------------------------

    /// @notice A Cron tick from Reactive Network: sweep every sleeve.
    function tick(address reactive) external onlyServiceProvider onlyCallbackSender(reactive) {
        _sweep();
    }

    /// @notice A deposit into `sleeveId` was seen on chain. A larger sleeve needs a larger bond, so close it at once
    /// if its curator's bond no longer covers it, rather than waiting for the next tick.
    function checkBond(address reactive, uint256 sleeveId) external onlyServiceProvider onlyCallbackSender(reactive) {
        _closeIfUnderBonded(sleeveId);
    }

    /// @notice The same sweep without Reactive: anyone may run it.
    function sweep() external {
        _sweep();
    }

    /// @notice Pays any debt to the callback proxy from this contract's balance, so callbacks resume.
    function coverDebt() external {
        _coverDebt();
    }

    // ------------------------------------------------------------------
    // Work
    // ------------------------------------------------------------------

    function _sweep() internal {
        uint256 count = hook.sleeveCount();
        uint256 visited;
        uint256 settled;
        uint256 released;
        uint256 closed;
        if (count > 1) {
            // Sleeve 0 is the control, which is never settled.
            uint256 curators = count - 1;
            uint256 id = cursor % curators + 1;
            while (visited < curators && gasleft() > GAS_PER_SLEEVE) {
                if (_settleIfDue(id)) ++settled;
                if (_releaseIfPending(id)) ++released;
                if (_closeIfUnderBonded(id)) ++closed;
                ++visited;
                id = id % curators + 1;
            }
            cursor = id - 1;
        }
        emit Swept(visited, settled, released, closed);
    }

    function _settleIfDue(uint256 sleeveId) internal returns (bool) {
        IZenithHook.Score memory score = hook.getScore(sleeveId);
        if (score.periodStart == 0 || block.timestamp < score.periodStart + hook.PERIOD()) return false;
        try settler.settle(sleeveId) {
            return true;
        } catch (bytes memory reason) {
            emit ActionFailed(sleeveId, IZenithSettler.settle.selector, reason);
            return false;
        }
    }

    function _releaseIfPending(uint256 sleeveId) internal returns (bool) {
        (,,,,, uint256 pending,,) = settler.accounts(sleeveId);
        if (pending == 0) return false;
        try settler.release(sleeveId) returns (uint256 amount) {
            return amount > 0;
        } catch (bytes memory reason) {
            emit ActionFailed(sleeveId, IZenithSettler.release.selector, reason);
            return false;
        }
    }

    function _closeIfUnderBonded(uint256 sleeveId) internal returns (bool) {
        if (sleeveId == 0 || sleeveId >= hook.sleeveCount()) return false;
        if (hook.getRanges(sleeveId).length == 0 || settler.isBonded(sleeveId)) return false;
        try settler.forceClose(sleeveId) {
            return true;
        } catch (bytes memory reason) {
            emit ActionFailed(sleeveId, IZenithSettler.forceClose.selector, reason);
            return false;
        }
    }
}
