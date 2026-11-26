// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CurrencySettler} from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {IZenithBond, ZenithHook} from "./ZenithHook.sol";
import {ZenithMath} from "./ZenithMath.sol";

/// @title ZenithSettler
/// @notice Holds curator bonds and settles each scoring period symmetrically. A curator earns a share of its
/// excess skill when its cumulative excess reaches a new high, and pays the same share of a new low to its
/// depositors from its bond. Both marks are cumulative, so a curator who gains and gives back the same amount is
/// neither paid twice nor slashed for the wobble.
/// @dev Bonds are in token1 and stay in the PoolManager as ERC-6909 claims owned by this contract.
contract ZenithSettler is IZenithBond, IUnlockCallback {
    using CurrencySettler for Currency;
    using StateLibrary for IPoolManager;

    uint256 internal constant BPS = 10_000;

    /// @notice Share of excess skill paid to a curator on a new high, and slashed from its bond on a new low.
    uint256 public constant SHARE_BPS = 2_000;

    /// @notice Minimum bond, as a share of the sleeve's value, for a curator to shape or keep its liquidity in.
    uint256 public constant BOND_BPS = 500;

    struct Account {
        uint256 bond; // token1 claims held for this sleeve's curator
        int256 cumulative; // sum of all settled periods' excess
        int256 highWater; // highest cumulative excess paid on
        int256 lowWater; // lowest cumulative excess slashed for
        uint256 feeOwed; // fee earned but not yet paid because the sleeve held too little token1
    }

    ZenithHook public immutable hook;
    IPoolManager public immutable poolManager;

    mapping(uint256 sleeveId => Account) public accounts;

    event BondPosted(uint256 indexed sleeveId, address indexed from, uint256 amount);
    event BondWithdrawn(uint256 indexed sleeveId, address indexed to, uint256 amount);
    event Settled(uint256 indexed sleeveId, int256 excess, int256 cumulative, uint256 feePaid, uint256 slashed);
    event ForceClosed(uint256 indexed sleeveId);

    error NotPoolManager();
    error NotCurator();
    error StillManaging();
    error StillBonded();
    error InsufficientBond();

    constructor(ZenithHook _hook) {
        hook = _hook;
        poolManager = _hook.poolManager();
    }

    // ------------------------------------------------------------------
    // Bonds
    // ------------------------------------------------------------------

    /// @notice Posts token1 as bond for a sleeve's curator. Anyone may post; only the curator can withdraw.
    function postBond(uint256 sleeveId, uint256 amount) external {
        hook.getSleeve(sleeveId); // reverts for an unknown sleeve
        poolManager.unlock(abi.encode(true, abi.encode(msg.sender, amount)));
        accounts[sleeveId].bond += amount;
        emit BondPosted(sleeveId, msg.sender, amount);
    }

    /// @notice Returns bond to the curator once its sleeve holds no liquidity and has nothing left to settle.
    function withdrawBond(uint256 sleeveId, uint256 amount, address to) external {
        if (msg.sender != hook.getSleeve(sleeveId).curator) revert NotCurator();
        ZenithHook.Score memory score = hook.getScore(sleeveId);
        if (hook.getRanges(sleeveId).length > 0 || score.startInRange > 0 || score.excess != 0) {
            revert StillManaging();
        }
        Account storage account = accounts[sleeveId];
        if (amount > account.bond) revert InsufficientBond();
        account.bond -= amount;
        poolManager.unlock(abi.encode(false, abi.encode(to, amount)));
        emit BondWithdrawn(sleeveId, to, amount);
    }

    /// @inheritdoc IZenithBond
    function isBonded(uint256 sleeveId) public view returns (bool) {
        uint256 bond = accounts[sleeveId].bond;
        return bond > 0 && bond * BPS >= sleeveValue(sleeveId) * BOND_BPS;
    }

    /// @notice A sleeve's idle tokens and positions valued in token1 at the current pool price.
    function sleeveValue(uint256 sleeveId) public view returns (uint256) {
        (Currency currency0, Currency currency1, uint24 fee, int24 spacing,) = hook.poolKey();
        PoolKey memory key = PoolKey(currency0, currency1, fee, spacing, hook);
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        ZenithHook.Sleeve memory sleeve = hook.getSleeve(sleeveId);
        uint256 amount0 = sleeve.idle0;
        uint256 amount1 = sleeve.idle1;
        ZenithHook.Range[] memory ranges = hook.getRanges(sleeveId);
        for (uint256 i; i < ranges.length; ++i) {
            (uint256 in0, uint256 in1) =
                ZenithMath.amounts(ranges[i].tickLower, ranges[i].tickUpper, ranges[i].liquidity, sqrtPriceX96);
            amount0 += in0;
            amount1 += in1;
        }
        return ZenithMath.value(amount0, amount1, sqrtPriceX96);
    }

    // ------------------------------------------------------------------
    // Settlement
    // ------------------------------------------------------------------

    /// @notice Closes the sleeve's scoring period and settles it. Anyone can call it once the period is over;
    /// Reactive Network calls it on a schedule.
    function settle(uint256 sleeveId) external returns (int256 excess, uint256 feePaid, uint256 slashed) {
        hook.rollPeriod(sleeveId);
        excess = hook.getScore(sleeveId).lastExcess;

        Account storage account = accounts[sleeveId];
        int256 cumulative = account.cumulative + excess;
        account.cumulative = cumulative;
        if (cumulative > account.highWater) {
            account.feeOwed += uint256(cumulative - account.highWater) * SHARE_BPS / BPS;
            account.highWater = cumulative;
        }
        if (cumulative < account.lowWater) {
            slashed = uint256(account.lowWater - cumulative) * SHARE_BPS / BPS;
            account.lowWater = cumulative;
            if (slashed > account.bond) slashed = account.bond;
        }

        if (slashed > 0) {
            account.bond -= slashed;
            poolManager.transfer(address(hook), _currency1().toId(), slashed);
            hook.settle(sleeveId, int256(slashed), address(0), false);
        }
        if (account.feeOwed > 0) {
            feePaid = hook.settle(sleeveId, -int256(account.feeOwed), hook.getSleeve(sleeveId).curator, false);
            account.feeOwed -= feePaid;
        }
        if (!isBonded(sleeveId) && hook.getRanges(sleeveId).length > 0) _forceClose(sleeveId);

        emit Settled(sleeveId, excess, cumulative, feePaid, slashed);
    }

    /// @notice Removes all of a sleeve's liquidity when its curator's bond no longer covers the minimum. Liquidity
    /// is only removed; the curator must re-bond and reshape to deploy it again.
    function forceClose(uint256 sleeveId) external {
        if (isBonded(sleeveId)) revert StillBonded();
        _forceClose(sleeveId);
    }

    function _forceClose(uint256 sleeveId) internal {
        hook.settle(sleeveId, 0, address(0), true);
        emit ForceClosed(sleeveId);
    }

    // ------------------------------------------------------------------
    // PoolManager callback: moving bond in and out
    // ------------------------------------------------------------------

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (bool deposit, bytes memory payload) = abi.decode(data, (bool, bytes));
        (address account, uint256 amount) = abi.decode(payload, (address, uint256));
        Currency currency1 = _currency1();
        if (deposit) {
            currency1.settle(poolManager, account, amount, false);
            currency1.take(poolManager, address(this), amount, true);
        } else {
            currency1.settle(poolManager, address(this), amount, true);
            currency1.take(poolManager, account, amount, false);
        }
        return "";
    }

    function _currency1() internal view returns (Currency currency1) {
        (, currency1,,,) = hook.poolKey();
    }
}
