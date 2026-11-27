// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AbstractCallback} from "reactive-lib/abstract-base/AbstractCallback.sol";

import {ZenithHook} from "./ZenithHook.sol";
import {ZenithSettler} from "./ZenithSettler.sol";

/// @title ZenithKeeper
/// @notice Receives Reactive Network callbacks on the hook's chain and runs Zenith's scheduled work: it settles every
/// sleeve whose period is over, releases vested slashes to depositors and force-closes sleeves whose bond no longer
/// covers them. Every action it takes is a public function anyone can call, so Zenith keeps working if Reactive
/// stops; the keeper only makes sure someone always does.
/// @dev Reactive's callback proxy calls this contract and replaces the first argument of every callback with the
/// ReactVM id of the reactive contract that asked for it, which is the address that deployed it. The keeper accepts
/// a callback only from the proxy and only for the ReactVM id of its own deployer, so the keeper and the reactive
/// contract must be deployed from the same account. The proxy bills callbacks to this contract in native ETH, so it
/// must hold some; a keeper in debt receives nothing until `coverDebt` is called.
contract ZenithKeeper is AbstractCallback {
    /// @notice Gas kept back for one sleeve's settlement. A sweep stops before a sleeve it might not finish and
    /// resumes from that sleeve on the next tick, so no sleeve is starved by the ones before it.
    uint256 public constant GAS_PER_SLEEVE = 1_000_000;

    ZenithHook public immutable hook;
    ZenithSettler public immutable settler;

    /// @notice The sleeve the next sweep starts from.
    uint256 public cursor;

    event Swept(uint256 visited, uint256 settled, uint256 released, uint256 closed);
    event ActionFailed(uint256 indexed sleeveId, bytes4 indexed action, bytes reason);

    constructor(ZenithSettler _settler, address callbackProxy) payable AbstractCallback(callbackProxy) {
        settler = _settler;
        hook = _settler.hook();
    }

    // ------------------------------------------------------------------
    // Reactive entry points
    // ------------------------------------------------------------------

    /// @notice A Cron tick from Reactive Network: sweep every sleeve.
    function tick(address rvmId) external authorizedSenderOnly rvmIdOnly(rvmId) {
        _sweep();
    }

    /// @notice A deposit into `sleeveId` was seen on chain. A larger sleeve needs a larger bond, so close it at once
    /// if its curator's bond no longer covers it, rather than waiting for the next tick.
    function checkBond(address rvmId, uint256 sleeveId) external authorizedSenderOnly rvmIdOnly(rvmId) {
        _closeIfUnderBonded(sleeveId);
    }

    /// @notice The same sweep without Reactive: anyone may run it.
    function sweep() external {
        _sweep();
    }

    // ------------------------------------------------------------------
    // Work
    // ------------------------------------------------------------------

    function _sweep() internal {
        uint256 count = hook.sleeveCount();
        if (count <= 1) return; // only the control, which is never settled
        uint256 curators = count - 1;
        uint256 id = cursor % curators + 1;
        uint256 visited;
        uint256 settled;
        uint256 released;
        uint256 closed;
        while (visited < curators && gasleft() > GAS_PER_SLEEVE) {
            if (_settleIfDue(id)) ++settled;
            if (_releaseIfPending(id)) ++released;
            if (_closeIfUnderBonded(id)) ++closed;
            ++visited;
            id = id % curators + 1;
        }
        cursor = id - 1;
        emit Swept(visited, settled, released, closed);
    }

    function _settleIfDue(uint256 sleeveId) internal returns (bool) {
        ZenithHook.Score memory score = hook.getScore(sleeveId);
        if (score.periodStart == 0 || block.timestamp < score.periodStart + hook.PERIOD()) return false;
        try settler.settle(sleeveId) {
            return true;
        } catch (bytes memory reason) {
            emit ActionFailed(sleeveId, ZenithSettler.settle.selector, reason);
            return false;
        }
    }

    function _releaseIfPending(uint256 sleeveId) internal returns (bool) {
        (,,,,, uint256 pending,,) = settler.accounts(sleeveId);
        if (pending == 0) return false;
        try settler.release(sleeveId) returns (uint256 amount) {
            return amount > 0;
        } catch (bytes memory reason) {
            emit ActionFailed(sleeveId, ZenithSettler.release.selector, reason);
            return false;
        }
    }

    function _closeIfUnderBonded(uint256 sleeveId) internal returns (bool) {
        if (sleeveId == 0 || sleeveId >= hook.sleeveCount()) return false;
        if (hook.getRanges(sleeveId).length == 0 || settler.isBonded(sleeveId)) return false;
        try settler.forceClose(sleeveId) {
            return true;
        } catch (bytes memory reason) {
            emit ActionFailed(sleeveId, ZenithSettler.forceClose.selector, reason);
            return false;
        }
    }
}
