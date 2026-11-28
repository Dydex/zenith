// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CurrencySettler} from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {IZenithBond, ZenithHook} from "./ZenithHook.sol";
import {ZenithMath} from "./ZenithMath.sol";

/// @title ZenithSettler
/// @notice Holds curator bonds and settles each scoring period symmetrically. A curator earns a share of its
/// excess skill when its cumulative excess reaches a new high, and pays the same share of a new low to its
/// depositors from its bond. Both marks are cumulative, so a curator who gains and gives back the same amount is
/// neither paid twice nor slashed for the wobble. Both the fee and the slash are capped at the bond. A slash is
/// released to the depositors evenly over the next
/// period rather than all at once, so depositing just before a settlement and leaving just after earns almost none
/// of it.
/// @dev Bonds are in token1 and stay in the PoolManager as ERC-6909 claims owned by this contract, as do slashes
/// waiting to be released.
contract ZenithSettler is IZenithBond, IUnlockCallback {
    using CurrencySettler for Currency;
    using StateLibrary for IPoolManager;

    uint256 internal constant BPS = 10_000;

    /// @notice Share of excess skill paid to a curator on a new high, and slashed from its bond on a new low.
    uint256 public constant SHARE_BPS = 2_000;

    /// @notice Minimum bond, as a share of the sleeve's value, for a curator to shape or keep its liquidity in.
    uint256 public constant BOND_BPS = 500;

    /// @notice The circuit breaker: a sleeve whose value per share falls this far behind the control's, measured from
    /// the best it has done against the control, is moved to full range and its curator locked out. Deposits and
    /// withdrawals move neither share price, so the ratio moves only with performance, price exposure included, and no
    /// depositor can fall much more than this behind passive from when they joined.
    uint256 public constant BREAKER_BPS = 500;

    struct Account {
        uint256 bond; // token1 claims held for this sleeve's curator
        int256 cumulative; // sum of all settled periods' excess
        int256 highWater; // highest cumulative excess paid on
        int256 lowWater; // lowest cumulative excess slashed for
        uint256 feeOwed; // fee earned but not yet paid because the sleeve held too little token1
        uint256 pending; // slashed bond not yet released to the sleeve's depositors
        uint64 lastRelease; // when pending was last released
        uint64 releaseEnd; // when all of pending will have been released
    }

    ZenithHook public immutable hook;
    IPoolManager public immutable poolManager;

    mapping(uint256 sleeveId => Account) public accounts;

    struct Breaker {
        uint256 peak; // best value per share against the control's, scaled by 1e18
        bool passive; // moved to full range, by the breaker or a forced close; the curator is locked out
    }

    mapping(uint256 sleeveId => Breaker) public breakers;

    event BondPosted(uint256 indexed sleeveId, address indexed from, uint256 amount);
    event BondWithdrawn(uint256 indexed sleeveId, address indexed to, uint256 amount);
    event Settled(uint256 indexed sleeveId, int256 excess, int256 cumulative, uint256 feePaid, uint256 slashed);
    event ForceClosed(uint256 indexed sleeveId);
    event Tripped(uint256 indexed sleeveId, uint256 relative, uint256 peak);
    event Resumed(uint256 indexed sleeveId);
    event Released(uint256 indexed sleeveId, uint256 amount);

    error NotPoolManager();
    error NotCurator();
    error StillManaging();
    error StillBonded();
    error InsufficientBond();
    error NotTripping();
    error AlreadyPassive();
    error CannotResume();
    error Balanced();

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
        if (breakers[sleeveId].passive) return false;
        uint256 bond = accounts[sleeveId].bond;
        return bond > 0 && bond * BPS >= sleeveValue(sleeveId) * BOND_BPS;
    }

    /// @notice A sleeve's idle tokens, positions and the fees its positions have earned but not yet collected, valued
    /// in token1 at the block-open price, so a price pushed inside the block can neither force-close a bonded sleeve
    /// nor let an under-bonded one shape. Uncollected fees count because the control collects its fees at every
    /// checkpoint and a curator's sleeve only at its own: without them a sleeve earning well would look behind.
    function sleeveValue(uint256 sleeveId) public view returns (uint256) {
        (uint160 sqrtPriceX96,) = hook.blockOpenPrice();
        ZenithHook.Sleeve memory sleeve = hook.getSleeve(sleeveId);
        uint256 amount0 = sleeve.idle0;
        uint256 amount1 = sleeve.idle1;
        ZenithHook.Range[] memory ranges = hook.getRanges(sleeveId);
        PoolId poolId = _poolId();
        for (uint256 i; i < ranges.length; ++i) {
            (uint256 in0, uint256 in1) = _rangeHoldings(poolId, ranges[i], bytes32(sleeveId), sqrtPriceX96);
            amount0 += in0;
            amount1 += in1;
        }
        return ZenithMath.value(amount0, amount1, sqrtPriceX96);
    }

    /// @dev A position's tokens at a price, plus the fees it has earned since it last collected.
    function _rangeHoldings(PoolId poolId, ZenithHook.Range memory r, bytes32 salt, uint160 sqrtPriceX96)
        internal
        view
        returns (uint256 amount0, uint256 amount1)
    {
        (amount0, amount1) = ZenithMath.amounts(r.tickLower, r.tickUpper, r.liquidity, sqrtPriceX96);
        (uint256 fees0, uint256 fees1) = _uncollectedFees(poolId, r, salt);
        amount0 += fees0;
        amount1 += fees1;
    }

    /// @dev What a hook-owned position has earned since it last collected, from the PoolManager's fee growth.
    function _uncollectedFees(PoolId poolId, ZenithHook.Range memory r, bytes32 salt)
        internal
        view
        returns (uint256 fees0, uint256 fees1)
    {
        (uint256 inside0, uint256 inside1) = poolManager.getFeeGrowthInside(poolId, r.tickLower, r.tickUpper);
        (, uint256 last0, uint256 last1) =
            poolManager.getPositionInfo(poolId, address(hook), r.tickLower, r.tickUpper, salt);
        unchecked {
            // Fee growth is allowed to wrap, as the PoolManager computes it.
            fees0 = FullMath.mulDiv(inside0 - last0, r.liquidity, 1 << 128);
            fees1 = FullMath.mulDiv(inside1 - last1, r.liquidity, 1 << 128);
        }
    }

    function _poolId() internal view returns (PoolId) {
        (Currency currency0, Currency currency1, uint24 fee, int24 spacing,) = hook.poolKey();
        return PoolKey(currency0, currency1, fee, spacing, hook).toId();
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
            // Capped at the bond, as a slash is: a curator can win at most what it has at stake, so a gamble with
            // depositors' money has no upside the bond does not match.
            uint256 fee = uint256(cumulative - account.highWater) * SHARE_BPS / BPS;
            account.feeOwed += fee < account.bond ? fee : account.bond;
            account.highWater = cumulative;
        }
        if (cumulative < account.lowWater) {
            slashed = uint256(account.lowWater - cumulative) * SHARE_BPS / BPS;
            account.lowWater = cumulative;
            if (slashed > account.bond) slashed = account.bond;
        }

        if (slashed > 0) {
            // Everything still pending, old and new, is released evenly over the next period. A slash never releases
            // faster than that, so this costs depositors nothing but a little time.
            account.bond -= slashed;
            account.pending += slashed;
            account.lastRelease = uint64(block.timestamp);
            account.releaseEnd = uint64(block.timestamp + hook.PERIOD());
        }
        if (account.feeOwed > 0) {
            feePaid = hook.settle(sleeveId, -int256(account.feeOwed), hook.getSleeve(sleeveId).curator, false);
            account.feeOwed -= feePaid;
        }
        // A sleeve this leaves under-bonded goes passive through forceClose, which anyone can call and the keeper calls
        // on its next tick. Keeping it out of settle bounds the gas of one settlement.

        emit Settled(sleeveId, excess, cumulative, feePaid, slashed);
    }

    /// @notice Releases the share of slashed bond that has vested since the last release to the sleeve's
    /// depositors. Anyone can call it; Reactive Network calls it on a schedule.
    function release(uint256 sleeveId) public returns (uint256 released) {
        Account storage account = accounts[sleeveId];
        uint256 pending = account.pending;
        if (pending == 0) return 0;
        if (hook.totalShares(sleeveId) == 0) {
            // Nobody holds the sleeve: pause the schedule, so a newcomer cannot collect what was owed to those who
            // left.
            account.releaseEnd += uint64(block.timestamp) - account.lastRelease;
            account.lastRelease = uint64(block.timestamp);
            return 0;
        }
        uint256 left = account.releaseEnd - account.lastRelease;
        uint256 elapsed = block.timestamp - account.lastRelease;
        released = elapsed >= left ? pending : pending * elapsed / left;
        if (released == 0) return 0;
        account.pending = pending - released;
        account.lastRelease = uint64(block.timestamp);
        poolManager.transfer(address(hook), _currency1().toId(), released);
        hook.settle(sleeveId, int256(released), address(0), false);
        emit Released(sleeveId, released);
    }

    /// @notice Moves a sleeve to full range when its curator's bond no longer covers it, and locks the curator out
    /// until it re-bonds and resumes. Anyone can call it.
    function forceClose(uint256 sleeveId) external {
        if (isBonded(sleeveId)) revert StillBonded();
        if (breakers[sleeveId].passive) revert AlreadyPassive();
        _goPassive(sleeveId);
        emit ForceClosed(sleeveId);
    }

    // ------------------------------------------------------------------
    // Circuit breaker
    // ------------------------------------------------------------------

    /// @notice A sleeve's value per share divided by the control's, scaled by 1e18, both at the block-open price.
    /// Zero while either has no shares.
    function relativeValue(uint256 sleeveId) public view returns (uint256) {
        uint256 shares = hook.totalShares(sleeveId);
        uint256 controlShares = hook.totalShares(0);
        if (shares == 0 || controlShares == 0) return 0;
        uint256 controlPerShare = FullMath.mulDiv(sleeveValue(0), 1e18, controlShares);
        if (controlPerShare == 0) return 0;
        return FullMath.mulDiv(FullMath.mulDiv(sleeveValue(sleeveId), 1e18, shares), 1e18, controlPerShare);
    }

    /// @notice Records a new best against the control, and says whether the sleeve has fallen far enough behind it
    /// to trip. Anyone can call it; the keeper does on every tick.
    function observe(uint256 sleeveId) public returns (bool due) {
        Breaker storage breaker = breakers[sleeveId];
        if (sleeveId == 0 || breaker.passive) return false;
        uint256 relative = relativeValue(sleeveId);
        if (relative == 0) return false;
        if (relative > breaker.peak) breaker.peak = relative;
        return relative * BPS < breaker.peak * (BPS - BREAKER_BPS);
    }

    /// @notice Trips the breaker: moves the sleeve to full range and locks its curator out. Anyone can call it once the
    /// sleeve has fallen BREAKER_BPS behind its best against the control; the keeper does on its next tick.
    function trip(uint256 sleeveId) external {
        if (!observe(sleeveId)) revert NotTripping();
        uint256 relative = relativeValue(sleeveId);
        _goPassive(sleeveId);
        emit Tripped(sleeveId, relative, breakers[sleeveId].peak);
    }

    /// @notice Lets a curator manage a passive sleeve again: once its bond covers the sleeve and the sleeve is within
    /// BREAKER_BPS of its best against the control, or at once if every depositor has left, which also resets the
    /// best to whatever comes next.
    function resume(uint256 sleeveId) external {
        if (msg.sender != hook.getSleeve(sleeveId).curator) revert NotCurator();
        Breaker storage breaker = breakers[sleeveId];
        if (!breaker.passive) revert CannotResume();
        if (hook.totalShares(sleeveId) == 0) {
            delete breakers[sleeveId];
        } else {
            breaker.passive = false;
            if (!isBonded(sleeveId) || observe(sleeveId)) revert CannotResume();
        }
        emit Resumed(sleeveId);
    }

    /// @notice Moves more of a passive sleeve's idle tokens into its full-range position. The swap that rebalances a
    /// sleeve is limited to 29 ticks of price movement, so a one-sided sleeve in a thin pool may take several steps;
    /// anyone can take one while more than BREAKER_BPS of the sleeve's value is idle, and the keeper does on every
    /// tick, letting arbitrage restore the price in between.
    function rebalance(uint256 sleeveId) external {
        if (!breakers[sleeveId].passive || !unbalanced(sleeveId)) revert Balanced();
        hook.settle(sleeveId, 0, address(0), true);
    }

    /// @notice Whether more than BREAKER_BPS of a sleeve's value sits idle rather than in its positions.
    function unbalanced(uint256 sleeveId) public view returns (bool) {
        (uint160 sqrtPriceX96,) = hook.blockOpenPrice();
        ZenithHook.Sleeve memory sleeve = hook.getSleeve(sleeveId);
        return ZenithMath.value(sleeve.idle0, sleeve.idle1, sqrtPriceX96) * BPS > sleeveValue(sleeveId) * BREAKER_BPS;
    }

    function _goPassive(uint256 sleeveId) internal {
        breakers[sleeveId].passive = true;
        hook.settle(sleeveId, 0, address(0), true);
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
