// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {console2} from "forge-std/console2.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {ZenithHook} from "../src/ZenithHook.sol";
import {ZenithMath} from "../src/ZenithMath.sol";
import {ZenithSettler} from "../src/ZenithSettler.sol";
import {ZenithTestBase} from "./utils/ZenithTestBase.sol";

/// @notice Attacks on Zenith's own rules, each run end to end against the real hook, settler and PoolManager.
/// Every test states what the attacker tries, then shows it either changes nothing or costs more than it earns.
contract ZenithAttacksTest is ZenithTestBase {
    using StateLibrary for IPoolManager;

    ZenithSettler internal settler;
    address internal curator = makeAddr("curator");
    address internal attacker = makeAddr("attacker");
    uint256 internal sleeve;
    uint128 internal narrow;

    function setUp() public override {
        super.setUp();
        settler = new ZenithSettler(hook);
        hook.setSettler(address(settler));
        _addExternalLiquidity(-6000, 6000, 1000e18);
        hook.fund(hook.CONTROL_SLEEVE(), 100e18, 100e18);
        hook.deployControl();
        sleeve = _openFundedSleeve(curator, 100e18, 100e18);
        narrow = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_PRICE_1_1, TickMath.getSqrtPriceAtTick(-600), TickMath.getSqrtPriceAtTick(600), 100e18 - 1, 100e18 - 1
        );
        _give(curator);
        _give(attacker);
    }

    // ------------------------------------------------------------------
    // Price pushes
    // ------------------------------------------------------------------

    /// @notice Attack: a curator that cut its liquidity since the period began pushes the price just before
    /// settlement, so its smaller position looks as if it lost less than the control, then pushes it back, all in
    /// one transaction. Settlement values the period at the block-open price, so the push earns no fee. Holding the
    /// pushed price into the next block would have worked, which is why it must survive a block of arbitrage.
    function test_pricePushAroundSettlementEarnsNoFee() public {
        _bond(20e18);
        _shape(narrow);
        vm.warp(block.timestamp + 1 days);
        _shape(narrow / 4);
        vm.warp(block.timestamp + hook.PERIOD());
        uint256 snap = vm.snapshotState();

        (int256 clean, uint256 cleanFee,) = settler.settle(sleeve);

        vm.revertToState(snap);
        _swapAs(curator, true, 300e18);
        (int256 pushed, uint256 pushedFee,) = settler.settle(sleeve);
        _swapAs(curator, false, 300e18);

        vm.revertToState(snap);
        _swapAs(curator, true, 300e18);
        vm.roll(block.number + 1);
        (int256 held,,) = settler.settle(sleeve);

        console2.log("excess, clean          ", clean);
        console2.log("excess, pushed in block", pushed);
        console2.log("excess, pushed and held", held);
        assertLe(pushed, clean, "a push inside the block cannot raise the score");
        assertLe(pushedFee, cleanFee, "nor the fee");
        assertGt(held - clean, 1e17, "the same push held into the next block would have paid");
    }

    /// @notice Attack: pushing the price so a bonded sleeve looks under-bonded, to force-close it. The bond is
    /// checked at the block-open price, so the sleeve stays bonded until a pushed price survives a block.
    function test_pricePushCannotForceCloseABondedSleeve() public {
        _bond(10e18); // exactly 5% of a sleeve worth 200e18 at the opening price
        _shape(narrow / 2);
        _swapAs(attacker, false, 300e18); // token0 now looks dearer, so the sleeve looks bigger in token1
        vm.expectRevert(ZenithSettler.StillBonded.selector);
        settler.forceClose(sleeve);

        vm.roll(block.number + 1);
        settler.forceClose(sleeve); // only once the price has held for a block
        assertEq(hook.getRanges(sleeve).length, 0);
    }

    /// @notice Attack: an under-bonded curator pushes the price so its sleeve looks small enough to shape.
    function test_pricePushCannotLetAnUnderBondedCuratorShape() public {
        _bond(9.5e18); // under 5% of 200e18
        _swapAs(curator, true, 300e18); // token0 now looks cheaper, so the sleeve looks smaller in token1
        ZenithHook.Range[] memory shape = new ZenithHook.Range[](1);
        shape[0] = _range(-600, 600, narrow / 2);
        vm.prank(curator);
        vm.expectRevert(ZenithHook.NotBonded.selector);
        hook.setShape(sleeve, shape);
    }

    // ------------------------------------------------------------------
    // Wash trading
    // ------------------------------------------------------------------

    /// @notice Attack: the curator adds liquidity, then trades back and forth through its own range to make the
    /// sleeve's fees look like good timing. It does raise the score, but the curator pays every fee in full and
    /// earns back only its sleeve's share of them, and 20% of that as its fee: a loss.
    function test_washTradingCostsTheCuratorMoreThanItEarns() public {
        _bond(20e18);
        _shape(narrow / 4);
        vm.warp(block.timestamp + 1 days);
        _shape(narrow);
        uint256 before = _wealth(curator);

        // Each round trip sells token0 and then buys it back exactly to the starting price, so the pool ends where
        // it began and the curator's wealth is measured at the same price before and after.
        (uint160 start,,,) = manager.getSlot0(key.toId());
        for (uint256 i; i < 20; ++i) {
            _swapAs(curator, true, 50e18);
            vm.roll(block.number + 1);
            _swapToPrice(curator, start);
            vm.roll(block.number + 1);
        }
        _shape(narrow / 4);
        vm.warp(block.timestamp + hook.PERIOD());
        (int256 excess, uint256 fee,) = settler.settle(sleeve);

        (uint160 end,,,) = manager.getSlot0(key.toId());
        assertEq(end, start, "the pool is back where it started");
        int256 net = int256(_wealth(curator)) - int256(before);
        console2.log("excess from washing", excess);
        console2.log("fee paid to curator", fee);
        console2.log("curator net        ", net);
        assertGt(excess, 0, "washing does look like skill");
        assertGt(fee, 0, "and is paid");
        assertLt(net, 0, "but the curator ends poorer");
    }

    // ------------------------------------------------------------------
    // Depositor sandwiches
    // ------------------------------------------------------------------

    /// @notice Attack: deposit a large amount just before a big swap and withdraw just after, to take the fees the
    /// existing depositors' positions earn. A deposit adds its share of liquidity to every position, so this is
    /// exactly as good as adding that liquidity to the pool directly: the vault gives the attacker nothing extra.
    function test_depositSandwichEarnsNoMoreThanDirectLiquidity() public {
        _bond(20e18);
        _shape(narrow);
        uint256 snap = vm.snapshotState();

        // Through Zenith.
        vm.prank(attacker);
        hook.fund(sleeve, 1000e18, 1000e18);
        uint128 added = hook.getRanges(sleeve)[0].liquidity - narrow;
        _roundTrip();
        uint256 shares = hook.sharesOf(sleeve, attacker);
        vm.prank(attacker);
        hook.withdraw(sleeve, shares, attacker);
        uint256 viaZenith = _depositorExit();

        // The same liquidity added to the pool directly.
        vm.revertToState(snap);
        modifyLiquidityRouter.modifyLiquidity(
            key, ModifyLiquidityParams(-600, 600, int256(uint256(added)), bytes32(uint256(7))), ZERO_BYTES
        );
        _roundTrip();
        uint256 direct = _depositorExit();

        vm.revertToState(snap);
        _roundTrip();
        uint256 alone = _depositorExit();

        console2.log("existing depositor, no attacker   ", alone);
        console2.log("existing depositor, direct JIT    ", direct);
        console2.log("existing depositor, JIT via Zenith", viaZenith);
        assertApproxEqAbs(viaZenith, direct, 1e9, "a Zenith deposit is just liquidity, like any other LP's");
    }

    /// @notice Attack: settlement runs on a known schedule. Deposit heavily just before a settlement that slashes
    /// the curator and leave an hour later, to take the compensation meant for the depositors who bore the loss.
    /// The slash is released over the next period, so an hour earns about 1/168 of the attacker's share of it.
    function test_slashSandwichTakesAlmostNothing() public {
        _bond(20e18);
        _shape(narrow / 4);
        vm.warp(block.timestamp + 1 days);
        _shape(narrow);
        _trade(true, -80e18);
        _shape(narrow / 4);
        vm.warp(block.timestamp + hook.PERIOD());

        uint256 before = _wealth(attacker);
        vm.prank(attacker);
        hook.fund(sleeve, 1000e18, 1000e18);
        (,, uint256 slashed) = settler.settle(sleeve);
        vm.warp(block.timestamp + 1 hours);
        vm.roll(block.number + 1);
        settler.release(sleeve);
        uint256 shares = hook.sharesOf(sleeve, attacker);
        vm.prank(attacker);
        hook.withdraw(sleeve, shares, attacker);
        int256 gain = int256(_wealth(attacker)) - int256(before);

        console2.log("slashed            ", slashed);
        console2.log("attacker's gain    ", gain);
        assertGt(slashed, 1e16, "the curator was slashed");
        assertLt(gain, int256(slashed / 100), "the attacker took under 1% of it");
    }

    // ------------------------------------------------------------------
    // Reshaping at a pushed price
    // ------------------------------------------------------------------

    /// @notice Attack: a curator with its own liquidity outside Zenith pushes the price up through that liquidity,
    /// reshapes its sleeve into a narrow range just below the pushed price, then pushes the price back down through
    /// the sleeve. The sleeve buys high on the way down; the curator's own position sold high on the way up. Before
    /// the steady-price rule this took 7.80 tokens from the sleeve's depositors and left the curator 6.86 ahead, in
    /// one block. Liquidity can now only be added while the price is within 30 ticks of the block's opening price.
    function test_reshapeAtAPushedPriceIsRefused() public {
        _attackSetup();
        _swapAs(curator, false, 300e18); // push the price up through the curator's own range
        ZenithHook.Range[] memory below = _rangeBelowPrice();
        vm.prank(curator);
        vm.expectRevert(ZenithHook.PriceMoved.selector);
        hook.setShape(sleeve, below);
    }

    /// @notice The same attack spread over two blocks: the pushed price must be held through a whole block, open to
    /// any arbitrageur, before the reshape is allowed. With nobody arbitraging, as here, it still pays; that is the
    /// size of the prize an arbitrageur would take instead.
    function test_reshapeAtAPushedPriceNeedsTheMoveToSurviveABlock() public {
        (uint256 own0, uint256 own1) = _attackSetup();
        uint256 depositorBefore = _depositorValueNow();
        uint256 curatorBefore = _wealth(curator) + ZenithMath.value(own0, own1, SQRT_PRICE_1_1);

        _swapAs(curator, false, 300e18);
        vm.roll(block.number + 1); // held for a block: the pushed price is now the block's opening price
        ZenithHook.Range[] memory below = _rangeBelowPrice();
        vm.prank(curator);
        hook.setShape(sleeve, below);
        _swapToPrice(curator, SQRT_PRICE_1_1);
        vm.prank(curator);
        modifyLiquidityRouter.modifyLiquidity(
            key, ModifyLiquidityParams(0, 1200, -2000e18, bytes32(uint256(9))), ZERO_BYTES
        );

        console2.log("held a block, depositors' loss", int256(depositorBefore) - int256(_depositorValueNow()));
        console2.log("held a block, curator's gain  ", int256(_wealth(curator)) - int256(curatorBefore));
    }

    /// @notice A deposit adds liquidity to every range, so it is refused at a pushed price too: otherwise anyone
    /// could push, deposit and push back, spreading the loss on their new slice over every depositor.
    function test_depositAtAPushedPriceIsRefused() public {
        _bond(20e18);
        _shape(narrow);
        _swapAs(attacker, false, 100e18);
        vm.prank(attacker);
        vm.expectRevert(ZenithHook.PriceMoved.selector);
        hook.fund(sleeve, 100e18, 100e18);

        // Leaving is never blocked: liquidity removed at a pushed price has already sold high.
        hook.withdraw(sleeve, hook.sharesOf(sleeve, address(this)) / 2, address(this));
    }

    function test_controlCannotBeRedeployedAtAPushedPrice() public {
        _swapAs(attacker, true, 100e18);
        vm.expectRevert(ZenithHook.PriceMoved.selector);
        hook.deployControl();
        vm.roll(block.number + 1);
        hook.deployControl(); // a block later, the moved price is the opening price
    }

    /// @notice Ordinary trading inside a block does not stop a curator: a small move is within the allowance.
    function test_smallMovesInTheBlockStillAllowReshaping() public {
        _bond(20e18);
        _shape(narrow);
        _swapAs(attacker, true, 1e18);
        (, int24 open) = hook.blockOpenPrice();
        (, int24 tick,,) = manager.getSlot0(key.toId());
        assertTrue(tick != open, "the price did move");
        _shape(narrow / 2);
        assertEq(hook.getRanges(sleeve)[0].liquidity, narrow / 2);
    }

    function _attackSetup() internal returns (uint256 own0, uint256 own1) {
        _bond(20e18);
        _shape(narrow);
        // The curator's own position, outside Zenith, where the push will happen.
        vm.startPrank(curator);
        MockERC20(Currency.unwrap(currency0)).approve(address(modifyLiquidityRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(modifyLiquidityRouter), type(uint256).max);
        modifyLiquidityRouter.modifyLiquidity(
            key, ModifyLiquidityParams(0, 1200, 2000e18, bytes32(uint256(9))), ZERO_BYTES
        );
        vm.stopPrank();
        vm.roll(block.number + 1);
        (own0, own1) = ZenithMath.amounts(0, 1200, 2000e18, SQRT_PRICE_1_1);
    }

    /// @dev A single range from tick 0 up to the current price, holding 90% of what the sleeve would hold in token1.
    function _rangeBelowPrice() internal view returns (ZenithHook.Range[] memory below) {
        (uint160 pushed,,,) = manager.getSlot0(key.toId());
        int24 top = (TickMath.getTickAtSqrtPrice(pushed) / 60) * 60;
        uint256 free1 = hook.getSleeve(sleeve).idle1;
        ZenithHook.Range[] memory current = hook.getRanges(sleeve);
        for (uint256 i; i < current.length; ++i) {
            (, uint256 y) = ZenithMath.amounts(current[i].tickLower, current[i].tickUpper, current[i].liquidity, pushed);
            free1 += y;
        }
        below = new ZenithHook.Range[](1);
        below[0] = _range(
            0,
            top,
            LiquidityAmounts.getLiquidityForAmount1(
                TickMath.getSqrtPriceAtTick(0), TickMath.getSqrtPriceAtTick(top), free1 * 9 / 10
            )
        );
    }

    /// @dev What the original depositor's shares are worth at the current price, valued like the settler does.
    function _depositorValueNow() internal view returns (uint256) {
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(key.toId());
        ZenithHook.Sleeve memory s = hook.getSleeve(sleeve);
        uint256 a0 = s.idle0;
        uint256 a1 = s.idle1;
        ZenithHook.Range[] memory ranges = hook.getRanges(sleeve);
        for (uint256 i; i < ranges.length; ++i) {
            (uint256 x, uint256 y) =
                ZenithMath.amounts(ranges[i].tickLower, ranges[i].tickUpper, ranges[i].liquidity, sqrtPriceX96);
            a0 += x;
            a1 += y;
        }
        uint256 total = ZenithMath.value(a0, a1, sqrtPriceX96);
        return total * hook.sharesOf(sleeve, address(this)) / hook.totalShares(sleeve);
    }

    /// @notice Attack: anyone can poke the control. A curator who pokes it at the far end of a price excursion gives
    /// the control a checkpoint its own sleeve did not get, and the excursion then counted against the control and
    /// not against the curator: a static curator scored +1.18 tokens for one excursion. Every checkpoint now values
    /// every sleeve, so each curator is compared with the control over exactly the same intervals. What is left
    /// comes from fees, which the control collects at every checkpoint and another sleeve only at its own.
    function test_pokingTheControlMidExcursionPaysNothing() public {
        _bond(20e18);
        _shape(narrow);
        vm.roll(block.number + 1);
        (uint160 start,,,) = manager.getSlot0(key.toId());
        uint256 snap = vm.snapshotState();

        _excursion(start, false);
        int256 quiet = hook.getScore(sleeve).excess;

        vm.revertToState(snap);
        _excursion(start, true);
        int256 poked = hook.getScore(sleeve).excess;

        console2.log("static curator's excess, nobody pokes  ", quiet);
        console2.log("static curator's excess, control poked ", poked);
        int256 moved = poked > quiet ? poked - quiet : quiet - poked;
        assertLt(moved, 0.01e18, "under 1% of the 1.18 tokens one excursion used to be worth");
    }

    function _excursion(uint160 start, bool pokeControl) internal {
        _swapAs(attacker, true, 60e18);
        vm.roll(block.number + 1);
        if (pokeControl) hook.poke(hook.CONTROL_SLEEVE());
        _swapToPrice(attacker, start);
        vm.roll(block.number + 1);
        hook.poke(sleeve);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _bond(uint256 amount) internal {
        vm.prank(curator);
        settler.postBond(sleeve, amount);
    }

    function _shape(uint128 liquidity) internal {
        ZenithHook.Range[] memory shape = new ZenithHook.Range[](1);
        shape[0] = _range(-600, 600, liquidity);
        vm.prank(curator);
        hook.setShape(sleeve, shape);
    }

    function _swapAs(address who, bool zeroForOne, uint256 amountIn) internal {
        vm.prank(who);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
    }

    function _swapToPrice(address who, uint160 target) internal {
        (uint160 now_,,,) = manager.getSlot0(key.toId());
        vm.prank(who);
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: now_ > target, amountSpecified: -1000e18, sqrtPriceLimitX96: target}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
    }

    /// @dev A large swap out and back, each in its own block.
    function _roundTrip() internal {
        _trade(true, -50e18);
        _trade(false, -50e18);
    }

    /// @dev The test contract is the sleeve's original depositor; returns what it takes out, in token1.
    function _depositorExit() internal returns (uint256) {
        (uint256 a0, uint256 a1) = hook.withdraw(sleeve, hook.sharesOf(sleeve, address(this)), address(this));
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(key.toId());
        return ZenithMath.value(a0, a1, sqrtPriceX96);
    }

    /// @dev Tokens held, valued in token1 at the current price.
    function _wealth(address who) internal view returns (uint256) {
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(key.toId());
        return ZenithMath.value(currency0.balanceOf(who), currency1.balanceOf(who), sqrtPriceX96);
    }

    function _give(address who) internal {
        MockERC20 t0 = MockERC20(Currency.unwrap(currency0));
        MockERC20 t1 = MockERC20(Currency.unwrap(currency1));
        t0.mint(who, 10_000e18);
        t1.mint(who, 10_000e18);
        vm.startPrank(who);
        t0.approve(address(hook), type(uint256).max);
        t1.approve(address(hook), type(uint256).max);
        t1.approve(address(settler), type(uint256).max);
        t0.approve(address(swapRouter), type(uint256).max);
        t1.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }
}
