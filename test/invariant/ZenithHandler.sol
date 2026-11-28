// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {ZenithHook} from "../../src/ZenithHook.sol";

/// @notice Drives random sequences of Zenith actions for the invariant tests: funding, reshaping, clearing,
/// swapping, poking and redeploying the control. It acts as each curator through pranks and records ghost
/// state the invariants check.
contract ZenithHandler is Test {
    ZenithHook public immutable hook;
    IPoolManager public immutable manager;
    PoolSwapTest public immutable swapRouter;

    PoolKey internal key;
    MockERC20 internal token0;
    MockERC20 internal token1;

    uint256 public constant CURATOR_COUNT = 3;
    address[CURATOR_COUNT] public curators;
    uint256[CURATOR_COUNT] public curatorSleeves;

    /// @dev Set if any sleeve's cumulative fee counter ever goes down.
    bool public feesDecreased;
    mapping(uint256 sleeveId => uint128) internal _lastFees0;
    mapping(uint256 sleeveId => uint128) internal _lastFees1;

    // Call counters, so a run that never exercises an action is visible.
    mapping(bytes32 action => uint256) public calls;

    constructor(ZenithHook _hook, IPoolManager _manager, PoolSwapTest _swapRouter, PoolKey memory _key) {
        hook = _hook;
        manager = _manager;
        swapRouter = _swapRouter;
        key = _key;
        token0 = MockERC20(Currency.unwrap(_key.currency0));
        token1 = MockERC20(Currency.unwrap(_key.currency1));

        token0.approve(address(_hook), type(uint256).max);
        token1.approve(address(_hook), type(uint256).max);
        token0.approve(address(_swapRouter), type(uint256).max);
        token1.approve(address(_swapRouter), type(uint256).max);

        for (uint256 i; i < CURATOR_COUNT; ++i) {
            curators[i] = makeAddr(string(abi.encode("invariant-curator", i)));
            curatorSleeves[i] = _hook.openSleeve(curators[i]);
        }
    }

    // ------------------------------------------------------------------
    // Actions
    // ------------------------------------------------------------------

    function fund(uint256 sleeveSeed, uint128 amount0, uint128 amount1) external {
        uint256 sleeveId = _anySleeve(sleeveSeed);
        amount0 = uint128(bound(amount0, 0, 50e18));
        amount1 = uint128(bound(amount1, 0, 50e18));
        token0.mint(address(this), amount0);
        token1.mint(address(this), amount1);
        try hook.fund(sleeveId, amount0, amount1) {
            calls["fund"]++;
        } catch {
            calls["fund-empty"]++; // one side missing at the sleeve's ratio buys no shares
        }
        _recordFees();
    }

    function withdraw(uint256 sleeveSeed, uint256 fraction) external {
        uint256 sleeveId = _anySleeve(sleeveSeed);
        uint256 owned = hook.sharesOf(sleeveId, address(this));
        uint256 shares = owned * bound(fraction, 1, 100) / 100;
        if (shares == 0) return;
        hook.withdraw(sleeveId, shares, address(this));
        calls["withdraw"]++;
        _recordFees();
    }

    function setShape(uint256 curatorSeed, uint256 shapeSeed) external {
        uint256 i = curatorSeed % CURATOR_COUNT;
        ZenithHook.Range[] memory shape = _randomShape(shapeSeed);
        vm.prank(curators[i]);
        try hook.setShape(curatorSleeves[i], shape) {
            calls["setShape"]++;
        } catch {
            // Expected when the sleeve cannot afford the shape; any other failure would break an invariant.
            calls["setShape-reverted"]++;
        }
        _recordFees();
    }

    function clearShape(uint256 curatorSeed) external {
        uint256 i = curatorSeed % CURATOR_COUNT;
        vm.prank(curators[i]);
        hook.setShape(curatorSleeves[i], new ZenithHook.Range[](0));
        calls["clearShape"]++;
        _recordFees();
    }

    function swap(bool zeroForOne, uint256 amountIn) external {
        amountIn = bound(amountIn, 1e12, 20e18);
        if (zeroForOne) token0.mint(address(this), amountIn);
        else token1.mint(address(this), amountIn);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.roll(block.number + 1); // each trade in its own block, as on chain
        calls["swap"]++;
        _recordFees();
    }

    function poke(uint256 sleeveSeed) external {
        hook.poke(_anySleeve(sleeveSeed));
        calls["poke"]++;
        _recordFees();
    }

    function deployControl() external {
        hook.deployControl();
        calls["deployControl"]++;
        _recordFees();
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    /// @dev Any sleeve, including the control.
    function _anySleeve(uint256 seed) internal view returns (uint256) {
        return seed % hook.sleeveCount();
    }

    function _recordFees() internal {
        uint256 count = hook.sleeveCount();
        for (uint256 id; id < count; ++id) {
            ZenithHook.Sleeve memory s = hook.getSleeve(id);
            if (s.fees0 < _lastFees0[id] || s.fees1 < _lastFees1[id]) feesDecreased = true;
            _lastFees0[id] = s.fees0;
            _lastFees1[id] = s.fees1;
        }
    }

    /// @dev Up to MAX_RANGES distinct, aligned ranges within +-3000 ticks, sized so a funded sleeve can often
    /// afford them and sometimes cannot.
    function _randomShape(uint256 seed) internal view returns (ZenithHook.Range[] memory shape) {
        uint256 n = bound(seed, 1, hook.MAX_RANGES());
        shape = new ZenithHook.Range[](n);
        for (uint256 i; i < n; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            int24 lower = -3000 + int24(int256(i)) * 600 + int24(int256(bound(r, 0, 9))) * 60;
            int24 upper = lower + int24(int256(bound(r >> 32, 1, 20))) * 60;
            uint128 liquidity = uint128(bound(r >> 64, 1e12, 5e19));
            shape[i] = ZenithHook.Range({tickLower: lower, tickUpper: upper, liquidity: liquidity});
        }
    }
}
