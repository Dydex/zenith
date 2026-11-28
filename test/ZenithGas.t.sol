// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {console2} from "forge-std/console2.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {ZenithHook} from "../src/ZenithHook.sol";
import {ZenithSettler} from "../src/ZenithSettler.sol";
import {ZenithTestBase} from "./utils/ZenithTestBase.sol";

/// @notice Gas, measured as a fresh transaction would pay it: every contract the call touches is cooled first, and
/// the figures exclude the 21,000 base cost. The hookless pool has the same tokens, fee and liquidity.
/// Run with: forge test --match-contract ZenithGasTest -vv. The README's figures come from Foundry 1.10.1, the
/// version CI pins; older versions cool storage less completely and report lower numbers.
contract ZenithGasTest is ZenithTestBase {
    PoolKey internal plain;
    ZenithSettler internal settler;
    address internal curator = makeAddr("curator");
    uint256 internal sleeve;
    uint128 internal narrow;

    function setUp() public override {
        super.setUp();
        (plain,) = initPool(currency0, currency1, IHooks(address(0)), 3000, SQRT_PRICE_1_1);
        _addExternalLiquidity(-6000, 6000, 1000e18);
        modifyLiquidityRouter.modifyLiquidity(plain, ModifyLiquidityParams(-6000, 6000, 1000e18, 0), ZERO_BYTES);

        settler = new ZenithSettler(hook);
        hook.setSettler(address(settler));
        hook.fund(hook.CONTROL_SLEEVE(), 100e18, 100e18);
        hook.deployControl();
        sleeve = _openFundedSleeve(curator, 100e18, 100e18);
        narrow = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_PRICE_1_1, TickMath.getSqrtPriceAtTick(-600), TickMath.getSqrtPriceAtTick(600), 100e18 - 1, 100e18 - 1
        );
        // The same liquidity in the hookless pool, so both swaps cross the same ticks.
        modifyLiquidityRouter.modifyLiquidity(
            plain, ModifyLiquidityParams(-887220, 887220, int256(uint256(_controlLiquidity())), 0), ZERO_BYTES
        );
        MockERC20 token1 = MockERC20(Currency.unwrap(currency1));
        token1.mint(curator, 1000e18);
        vm.prank(curator);
        token1.approve(address(settler), type(uint256).max);
        vm.prank(curator);
        settler.postBond(sleeve, 20e18);
        _shape(_single(narrow));
        modifyLiquidityRouter.modifyLiquidity(
            plain, ModifyLiquidityParams(-600, 600, int256(uint256(narrow)), 0), ZERO_BYTES
        );

        // Warm-up swaps in an earlier block, so no slot is written for the first time while measuring.
        _swap(plain, true, 1e15);
        _swap(key, true, 1e15);
        vm.roll(block.number + 1);
    }

    /// @dev Each case starts from the same saved state, so every swap crosses the same ticks at the same prices.
    /// "Later in the block" follows a dust swap that has already recorded the block's opening price, in both pools
    /// alike, so the hook only reads it.
    function test_swapGas() public {
        uint256 snap = vm.snapshotState();
        uint256 plainFirst = _measureSwap(plain, false);
        vm.revertToState(snap);
        uint256 zenithFirst = _measureSwap(key, false);
        vm.revertToState(snap);
        uint256 plainLater = _measureSwap(plain, true);
        vm.revertToState(snap);
        uint256 zenithLater = _measureSwap(key, true);

        console2.log("hookless pool, first swap        ", plainFirst);
        console2.log("Zenith, first swap of the block  ", zenithFirst);
        console2.log("hookless pool, later swap        ", plainLater);
        console2.log("Zenith, later swap in the block  ", zenithLater);
        // The hook only records the block's opening price: one slot write per block, one read otherwise.
        assertLt(zenithFirst - plainFirst, 15_000, "first swap of a block");
        assertLt(zenithLater - plainLater, 8_000, "every other swap");
    }

    function test_operationGas() public {
        ZenithHook.Range[] memory four = new ZenithHook.Range[](4);
        four[0] = _range(-600, 600, narrow / 8);
        four[1] = _range(-1200, 1200, narrow / 16);
        four[2] = _range(-1800, 1800, narrow / 16);
        four[3] = _range(-120, 120, narrow / 8);

        _cool();
        uint256 g = gasleft();
        hook.fund(sleeve, 10e18, 10e18);
        console2.log("fund, one-range sleeve      ", g - gasleft());

        _cool();
        g = gasleft();
        hook.withdraw(sleeve, hook.sharesOf(sleeve, address(this)) / 10, address(this));
        console2.log("withdraw, one-range sleeve  ", g - gasleft());

        _cool();
        g = gasleft();
        hook.poke(sleeve);
        console2.log("poke, one range             ", g - gasleft());

        _cool();
        vm.prank(curator);
        g = gasleft();
        hook.setShape(sleeve, four);
        console2.log("setShape, one to four ranges", g - gasleft());

        _cool();
        g = gasleft();
        hook.poke(sleeve);
        console2.log("poke, four ranges           ", g - gasleft());

        vm.warp(block.timestamp + hook.PERIOD());
        _cool();
        g = gasleft();
        settler.settle(sleeve);
        console2.log("settle, four ranges         ", g - gasleft());
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _measureSwap(PoolKey memory k, bool afterDust) internal returns (uint256 used) {
        if (afterDust) _swap(k, true, 1e6);
        _cool();
        uint256 g = gasleft();
        _swap(k, true, 1e18);
        used = g - gasleft();
    }

    function _swap(PoolKey memory k, bool zeroForOne, uint256 amountIn) internal {
        swapRouter.swap(
            k,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
    }

    /// @dev Marks every contract a call can touch as cold, as at the start of a transaction.
    function _cool() internal {
        vm.cool(address(manager));
        vm.cool(address(hook));
        vm.cool(address(settler));
        vm.cool(address(swapRouter));
        vm.cool(Currency.unwrap(currency0));
        vm.cool(Currency.unwrap(currency1));
    }

    function _controlLiquidity() internal view returns (uint128) {
        return hook.getRanges(hook.CONTROL_SLEEVE())[0].liquidity;
    }

    function _single(uint128 liquidity) internal pure returns (ZenithHook.Range[] memory shape) {
        shape = new ZenithHook.Range[](1);
        shape[0] = _range(-600, 600, liquidity);
    }

    function _shape(ZenithHook.Range[] memory shape) internal {
        vm.prank(curator);
        hook.setShape(sleeve, shape);
    }
}
