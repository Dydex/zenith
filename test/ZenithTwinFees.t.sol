// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {ZenithHook} from "../src/ZenithHook.sol";
import {ZenithTestBase} from "./utils/ZenithTestBase.sol";

/// @notice Proves Zenith's per-sleeve fee accounting is exact. Every range a sleeve holds gets a "twin": an
/// identical position (same ticks, same liquidity) opened by an ordinary router under its own salt. After any
/// sequence of swaps, each sleeve must have collected exactly the fees its twins collected, to the wei.
contract ZenithTwinFeesTest is ZenithTestBase {
    address internal curatorA = makeAddr("curator-a");
    address internal curatorB = makeAddr("curator-b");
    uint256 internal sleeveA;
    uint256 internal sleeveB;

    function setUp() public override {
        super.setUp();
        _addExternalLiquidity(-6000, 6000, 1000e18);
        sleeveA = _openFundedSleeve(curatorA, 500e18, 500e18);
        sleeveB = _openFundedSleeve(curatorB, 500e18, 500e18);
    }

    // ------------------------------------------------------------------
    // Deterministic cases
    // ------------------------------------------------------------------

    /// @notice Two curators hold the exact same range (different salts). Each must match its own twin, so no fees
    /// leak between sleeves even when their positions are identical.
    function test_overlappingSleevesEachMatchTheirTwin() public {
        ZenithHook.Range[] memory shapeA = new ZenithHook.Range[](2);
        shapeA[0] = _range(-600, 600, 5e18);
        shapeA[1] = _range(-120, 120, 10e18);
        ZenithHook.Range[] memory shapeB = new ZenithHook.Range[](2);
        shapeB[0] = _range(-600, 600, 7e18); // same range as sleeve A
        shapeB[1] = _range(-1800, -60, 3e18);
        _shapeWithTwins(sleeveA, curatorA, shapeA);
        _shapeWithTwins(sleeveB, curatorB, shapeB);

        swap(key, true, -40e18, ZERO_BYTES);
        swap(key, false, -70e18, ZERO_BYTES);
        swap(key, true, -25e18, ZERO_BYTES);

        (uint256 a0, uint256 a1) = _assertSleeveMatchesTwins(sleeveA);
        _assertSleeveMatchesTwins(sleeveB);
        assertGt(a0, 0, "non-trivial: token0 fees earned");
        assertGt(a1, 0, "non-trivial: token1 fees earned");
        _assertLedgerEqualsClaims();
    }

    /// @notice The passive control earns exactly what a plain full-range LP earns, so the benchmark curators are
    /// scored against is a real, ordinary position.
    function test_controlMatchesAPlainFullRangeLp() public {
        uint256 control = hook.CONTROL_SLEEVE();
        hook.fund(control, 200e18, 200e18);
        hook.deployControl();
        _openTwinsFor(control);

        swap(key, true, -30e18, ZERO_BYTES);
        swap(key, false, -45e18, ZERO_BYTES);

        (uint256 c0, uint256 c1) = _assertSleeveMatchesTwins(control);
        assertGt(c0 + c1, 0, "control earned fees");
        _assertLedgerEqualsClaims();
    }

    // ------------------------------------------------------------------
    // Fuzz
    // ------------------------------------------------------------------

    /// @notice Random shapes for two curators plus the control, then a random sequence of swaps. Every sleeve's
    /// collected fees must equal its twins' fees exactly, for both tokens.
    function testFuzz_sleeveFeesMatchTwinsToTheWei(uint256 seed) public {
        _shapeWithTwins(sleeveA, curatorA, _randomShape(uint256(keccak256(abi.encode(seed, "a")))));
        _shapeWithTwins(sleeveB, curatorB, _randomShape(uint256(keccak256(abi.encode(seed, "b")))));
        uint256 control = hook.CONTROL_SLEEVE();
        hook.fund(control, 100e18, 100e18);
        hook.deployControl();
        _openTwinsFor(control);

        _randomSwaps(seed, 10);

        _assertSleeveMatchesTwins(sleeveA);
        _assertSleeveMatchesTwins(sleeveB);
        (uint256 c0, uint256 c1) = _assertSleeveMatchesTwins(control);
        // The control is always in range, so every run must have earned real fees: no run passes on 0 == 0.
        assertGt(c0 + c1, 0, "fees actually earned this run");
        _assertLedgerEqualsClaims();
    }

    /// @notice Fees a sleeve collects while being reshaped must also match its twins exactly. The twins mirror
    /// the reshape: they collect their fees, close, and reopen at the new shape.
    function testFuzz_feesCollectedOnReshapeMatchTwins(uint256 seed) public {
        _shapeWithTwins(sleeveA, curatorA, _randomShape(seed));
        _randomSwaps(seed, 6);

        // Twins collect their fees first; the sleeve collects the same fees inside its reshape.
        (uint256 twin0, uint256 twin1) = _pokeTwins(sleeveA);
        _closeTwins(sleeveA);
        ZenithHook.Sleeve memory before = hook.getSleeve(sleeveA);

        ZenithHook.Range[] memory next = _randomShape(uint256(keccak256(abi.encode(seed, "next"))));
        _shapeWithTwins(sleeveA, curatorA, next);

        ZenithHook.Sleeve memory afterReshape = hook.getSleeve(sleeveA);
        assertEq(afterReshape.fees0 - before.fees0, twin0, "reshape fees match twins (token0)");
        assertEq(afterReshape.fees1 - before.fees1, twin1, "reshape fees match twins (token1)");

        // And the new shape keeps matching after further trading.
        _randomSwaps(uint256(keccak256(abi.encode(seed, "after"))), 6);
        _assertSleeveMatchesTwins(sleeveA);
        _assertLedgerEqualsClaims();
    }

    // ------------------------------------------------------------------
    // Twin helpers
    // ------------------------------------------------------------------

    function _twinSalt(uint256 sleeveId, int24 tickLower, int24 tickUpper) internal pure returns (bytes32) {
        return keccak256(abi.encode("twin", sleeveId, tickLower, tickUpper));
    }

    /// @dev Sets the sleeve's shape through the hook, then opens an identical twin for every range.
    function _shapeWithTwins(uint256 sleeveId, address curator, ZenithHook.Range[] memory shape) internal {
        vm.prank(curator);
        hook.setShape(sleeveId, shape);
        _openTwinsFor(sleeveId);
    }

    function _openTwinsFor(uint256 sleeveId) internal {
        ZenithHook.Range[] memory ranges = hook.getRanges(sleeveId);
        for (uint256 i; i < ranges.length; ++i) {
            _modifyTwin(sleeveId, ranges[i], int256(uint256(ranges[i].liquidity)));
        }
    }

    function _closeTwins(uint256 sleeveId) internal {
        ZenithHook.Range[] memory ranges = hook.getRanges(sleeveId);
        for (uint256 i; i < ranges.length; ++i) {
            _modifyTwin(sleeveId, ranges[i], -int256(uint256(ranges[i].liquidity)));
        }
    }

    /// @dev Collects the twins' fees with a zero-liquidity modify; the router returns exactly the fees owed.
    function _pokeTwins(uint256 sleeveId) internal returns (uint256 fees0, uint256 fees1) {
        ZenithHook.Range[] memory ranges = hook.getRanges(sleeveId);
        for (uint256 i; i < ranges.length; ++i) {
            BalanceDelta delta = _modifyTwin(sleeveId, ranges[i], 0);
            fees0 += uint256(int256(delta.amount0()));
            fees1 += uint256(int256(delta.amount1()));
        }
    }

    function _modifyTwin(uint256 sleeveId, ZenithHook.Range memory range, int256 liquidityDelta)
        internal
        returns (BalanceDelta)
    {
        return modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: range.tickLower,
                tickUpper: range.tickUpper,
                liquidityDelta: liquidityDelta,
                salt: _twinSalt(sleeveId, range.tickLower, range.tickUpper)
            }),
            ZERO_BYTES
        );
    }

    /// @dev Pokes the twins and the sleeve, then requires identical fees and that the sleeve's fees landed in idle.
    function _assertSleeveMatchesTwins(uint256 sleeveId) internal returns (uint256 fees0, uint256 fees1) {
        (uint256 twin0, uint256 twin1) = _pokeTwins(sleeveId);

        ZenithHook.Sleeve memory before = hook.getSleeve(sleeveId);
        hook.poke(sleeveId);
        ZenithHook.Sleeve memory afterPoke = hook.getSleeve(sleeveId);

        fees0 = afterPoke.fees0 - before.fees0;
        fees1 = afterPoke.fees1 - before.fees1;
        assertEq(fees0, twin0, "sleeve fees == twin fees (token0)");
        assertEq(fees1, twin1, "sleeve fees == twin fees (token1)");
        assertEq(afterPoke.idle0 - before.idle0, fees0, "fees credited to idle (token0)");
        assertEq(afterPoke.idle1 - before.idle1, fees1, "fees credited to idle (token1)");
    }

    function _randomSwaps(uint256 seed, uint256 maxSwaps) internal {
        uint256 n = bound(seed, 1, maxSwaps);
        for (uint256 i; i < n; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, "swap", i)));
            swap(key, r & 1 == 1, -int256(bound(r >> 8, 1e15, 40e18)), ZERO_BYTES);
        }
    }
}
