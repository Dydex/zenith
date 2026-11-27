// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {Vm} from "forge-std/Vm.sol";
import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {ZenithHook} from "../src/ZenithHook.sol";
import {ZenithKeeper} from "../src/ZenithKeeper.sol";
import {ZenithReactive} from "../src/ZenithReactive.sol";
import {ZenithSettler} from "../src/ZenithSettler.sol";
import {ZenithTestBase} from "./utils/ZenithTestBase.sol";

/// @notice Records subscriptions, standing in for Reactive Network's system contract.
contract MockSystemContract {
    uint256[6][] public subscriptions;

    function subscribe(uint256 chainId, address target, uint256 t0, uint256 t1, uint256 t2, uint256 t3) external {
        subscriptions.push([chainId, uint256(uint160(target)), t0, t1, t2, t3]);
    }

    function count() external view returns (uint256) {
        return subscriptions.length;
    }

    function debt(address) external pure returns (uint256) {
        return 0;
    }

    receive() external payable {}
}

/// @notice Reactive Network automation: the reactive contract turns Cron ticks and deposits into callbacks, and the
/// keeper turns callbacks into settlements, releases and forced closes. Reactive's callback proxy is simulated: it
/// is the only caller the keeper accepts, and it overwrites a callback's first argument with the ReactVM id.
contract ZenithReactiveTest is ZenithTestBase {
    uint256 internal constant UNICHAIN_SEPOLIA = 1301;
    uint256 internal constant LASNA = 5_318_007;
    address internal constant SYSTEM = 0x0000000000000000000000000000000000fffFfF;
    uint256 internal constant CRON1000 = 0xe20b31294d84c3661ddc8f423abb9c70310d0cf172aa2714ead78029b325e3f4;

    ZenithSettler internal settler;
    ZenithKeeper internal keeper;
    ZenithReactive internal reactive;
    address internal proxy = makeAddr("callbackProxy");
    address internal curator = makeAddr("curator");
    uint256 internal sleeve;
    uint128 internal narrow;

    function setUp() public override {
        super.setUp();
        settler = new ZenithSettler(hook);
        hook.setSettler(address(settler));
        // This test contract deploys both, as one account must: its address is the ReactVM id the keeper accepts.
        keeper = new ZenithKeeper(settler, proxy);
        reactive = new ZenithReactive(UNICHAIN_SEPOLIA, address(hook), address(keeper), CRON1000);

        _addExternalLiquidity(-6000, 6000, 1000e18);
        hook.fund(hook.CONTROL_SLEEVE(), 100e18, 100e18);
        hook.deployControl();
        sleeve = _openFundedSleeve(curator, 100e18, 100e18);
        narrow = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_PRICE_1_1, TickMath.getSqrtPriceAtTick(-600), TickMath.getSqrtPriceAtTick(600), 100e18 - 1, 100e18 - 1
        );
        MockERC20 token1 = MockERC20(Currency.unwrap(currency1));
        token1.mint(curator, 1000e18);
        vm.prank(curator);
        token1.approve(address(settler), type(uint256).max);
    }

    // ------------------------------------------------------------------
    // Keeper
    // ------------------------------------------------------------------

    function test_tickSettlesEverySleeveWhosePeriodIsOver() public {
        _bond(sleeve, 20e18);
        _shape(sleeve, narrow);
        uint256 second = _openBondedShapedSleeve();

        vm.prank(proxy);
        keeper.tick(address(this));
        assertEq(hook.getScore(sleeve).lastExcess, 0, "nothing due yet");

        vm.warp(block.timestamp + hook.PERIOD());
        vm.expectEmit(address(keeper));
        emit ZenithKeeper.Swept(2, 2, 0, 0);
        vm.prank(proxy);
        keeper.tick(address(this));
        assertEq(hook.getScore(sleeve).periodStart, block.timestamp, "first sleeve settled");
        assertEq(hook.getScore(second).periodStart, block.timestamp, "second sleeve settled");
    }

    function test_tickReleasesVestedSlashes() public {
        _bond(sleeve, 20e18);
        _shape(sleeve, narrow / 4);
        vm.warp(block.timestamp + 1 days);
        _shape(sleeve, narrow);
        _trade(true, -80e18);
        _shape(sleeve, narrow / 4);
        vm.warp(block.timestamp + hook.PERIOD());
        vm.prank(proxy);
        keeper.tick(address(this)); // settles, and slashes
        (,,,,, uint256 pending,,) = settler.accounts(sleeve);
        assertGt(pending, 0, "a slash is waiting");

        uint256 idle = hook.getSleeve(sleeve).idle1;
        vm.warp(block.timestamp + hook.PERIOD() / 2);
        vm.prank(proxy);
        keeper.tick(address(this));
        assertEq(hook.getSleeve(sleeve).idle1 - idle, pending / 2, "half released to depositors");
    }

    function test_checkBondClosesAnUnderBondedSleeveAtOnce() public {
        _bond(sleeve, 10e18);
        _shape(sleeve, narrow);
        vm.prank(proxy);
        keeper.checkBond(address(this), sleeve);
        assertEq(hook.getRanges(sleeve).length, 1, "still bonded: left alone");

        hook.fund(sleeve, 100e18, 100e18); // the same bond no longer covers the larger sleeve
        vm.prank(proxy);
        keeper.checkBond(address(this), sleeve);
        assertEq(hook.getRanges(sleeve).length, 0, "closed");
    }

    function test_onlyTheCallbackProxyCanCall() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert("Authorized sender only");
        keeper.tick(address(this));
    }

    function test_onlyOurReactiveContractCanAsk() public {
        vm.prank(proxy);
        vm.expectRevert("Authorized RVM ID only");
        keeper.tick(makeAddr("someone else's reactive contract"));
    }

    function test_oneFailingSleeveDoesNotBlockTheOthers() public {
        _bond(sleeve, 20e18);
        _shape(sleeve, narrow);
        uint256 second = _openBondedShapedSleeve();
        vm.warp(block.timestamp + hook.PERIOD());
        vm.mockCallRevert(address(settler), abi.encodeCall(ZenithSettler.settle, (sleeve)), bytes("boom"));

        vm.expectEmit(address(keeper));
        emit ZenithKeeper.ActionFailed(sleeve, ZenithSettler.settle.selector, bytes("boom"));
        keeper.sweep();
        assertEq(hook.getScore(second).periodStart, block.timestamp, "the other sleeve was still settled");
    }

    /// @notice A sweep that runs short of gas stops before a sleeve it might not finish, and the next one starts
    /// from that sleeve, so later sleeves are never starved.
    function test_sweepResumesWhereItRanOutOfGas() public {
        _bond(sleeve, 20e18);
        _shape(sleeve, narrow);
        uint256 second = _openBondedShapedSleeve();
        uint256 third = _openBondedShapedSleeve();
        vm.warp(block.timestamp + hook.PERIOD());

        keeper.sweep{gas: keeper.GAS_PER_SLEEVE() + 150_000}();
        uint256 done;
        for (uint256 id = sleeve; id <= third; ++id) {
            if (hook.getScore(id).periodStart == block.timestamp) ++done;
        }
        assertGt(done, 0, "made progress");
        assertLt(done, 3, "ran out of gas before the end");

        keeper.sweep();
        assertEq(hook.getScore(sleeve).periodStart, block.timestamp);
        assertEq(hook.getScore(second).periodStart, block.timestamp);
        assertEq(hook.getScore(third).periodStart, block.timestamp, "the rest were finished next time");
    }

    /// @notice The most one sleeve can cost a sweep: four ranges, a period that ends in a slash, and a bond that no
    /// longer covers the sleeve, so it is settled, slashed and force-closed in one visit. It must fit in the
    /// allowance the keeper keeps back, or a sweep could start a sleeve it cannot finish. Run with `--isolate` so
    /// every call is a fresh transaction with cold storage, as on chain: about 693k gas, against an allowance of 1M.
    function test_worstCaseSleeveFitsTheGasAllowance() public {
        _bond(sleeve, 10.2e18);
        _fourRanges(narrow / 48); // small at the period's start
        vm.warp(block.timestamp + 1 days);
        _fourRanges(narrow / 12); // large just before a trend
        _trade(true, -80e18);
        _fourRanges(narrow / 48);
        hook.fund(sleeve, 100e18, 100e18); // a deposit doubles the sleeve, so the bond falls short
        vm.warp(block.timestamp + hook.PERIOD());

        uint256 before = gasleft();
        keeper.sweep();
        uint256 used = before - gasleft();
        (,,,,, uint256 pending,,) = settler.accounts(sleeve);
        assertGt(pending, 0, "slashed");
        assertEq(hook.getRanges(sleeve).length, 0, "and force-closed");
        emit log_named_uint("gas for the worst-case sleeve", used);
        assertLt(used, keeper.GAS_PER_SLEEVE(), "fits the allowance");
    }

    // ------------------------------------------------------------------
    // Reactive contract
    // ------------------------------------------------------------------

    function test_subscribesToCronAndDepositsOnReactiveNetwork() public {
        vm.etch(SYSTEM, address(new MockSystemContract()).code);
        ZenithReactive deployed = new ZenithReactive(UNICHAIN_SEPOLIA, address(hook), address(keeper), CRON1000);

        MockSystemContract system = MockSystemContract(payable(SYSTEM));
        assertEq(system.count(), 2);
        uint256 ignore = 0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad;
        _assertSubscription(system, 0, [block.chainid, uint256(uint160(SYSTEM)), CRON1000, ignore, ignore, ignore]);
        _assertSubscription(
            system,
            1,
            [UNICHAIN_SEPOLIA, uint256(uint160(address(hook))), deployed.SLEEVE_FUNDED_TOPIC(), ignore, ignore, ignore]
        );

        // The copy on the Reactive Network only subscribes; reacting happens in the ReactVM.
        vm.expectRevert("VM only");
        deployed.react(_cronLog());
    }

    function test_sleeveFundedTopicMatchesTheHookEvent() public view {
        assertEq(bytes32(reactive.SLEEVE_FUNDED_TOPIC()), ZenithHook.SleeveFunded.selector);
    }

    function test_cronTickRequestsASweep() public {
        vm.expectEmit(address(reactive));
        emit IReactive.Callback(
            UNICHAIN_SEPOLIA,
            address(keeper),
            reactive.CALLBACK_GAS_LIMIT(),
            abi.encodeCall(ZenithKeeper.tick, (address(0)))
        );
        reactive.react(_cronLog());
    }

    function test_depositRequestsABondCheckForThatSleeve() public {
        vm.expectEmit(address(reactive));
        emit IReactive.Callback(
            UNICHAIN_SEPOLIA,
            address(keeper),
            reactive.CALLBACK_GAS_LIMIT(),
            abi.encodeCall(ZenithKeeper.checkBond, (address(0), sleeve))
        );
        reactive.react(_fundedLog(UNICHAIN_SEPOLIA, address(hook), sleeve));
    }

    function test_ignoresLookalikeEvents() public {
        vm.recordLogs();
        reactive.react(_fundedLog(UNICHAIN_SEPOLIA, makeAddr("another hook"), sleeve));
        reactive.react(_fundedLog(1, address(hook), sleeve)); // the same address on another chain
        IReactive.LogRecord memory fakeCron = _cronLog();
        fakeCron._contract = makeAddr("not the system contract");
        reactive.react(fakeCron);
        assertEq(vm.getRecordedLogs().length, 0, "no callbacks");
    }

    /// @notice The whole loop: a Cron tick on Reactive Network becomes a callback request, the proxy delivers it on
    /// the hook's chain with the ReactVM id written in, and the keeper settles the sleeve.
    function test_cronTickSettlesASleeveEndToEnd() public {
        _bond(sleeve, 20e18);
        _shape(sleeve, narrow);
        vm.warp(block.timestamp + hook.PERIOD());

        vm.recordLogs();
        reactive.react(_cronLog());
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], IReactive.Callback.selector);
        assertEq(uint256(logs[0].topics[1]), UNICHAIN_SEPOLIA, "to the hook's chain");
        assertEq(address(uint160(uint256(logs[0].topics[2]))), address(keeper), "to the keeper");
        bytes memory payload = abi.decode(logs[0].data, (bytes));

        _deliver(payload, address(this));
        assertEq(hook.getScore(sleeve).periodStart, block.timestamp, "settled by the callback");
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    /// @dev What Reactive's callback proxy does: write the ReactVM id over the first argument, then call.
    function _deliver(bytes memory payload, address rvmId) internal {
        assembly {
            mstore(add(payload, 36), rvmId)
        }
        vm.prank(proxy);
        (bool ok,) = address(keeper).call(payload);
        assertTrue(ok, "callback delivered");
    }

    function _cronLog() internal pure returns (IReactive.LogRecord memory log) {
        log.chain_id = LASNA;
        log._contract = SYSTEM;
        log.topic_0 = CRON1000;
        log.data = abi.encode(uint256(1000));
    }

    function _fundedLog(uint256 chainId, address emitter, uint256 sleeveId)
        internal
        view
        returns (IReactive.LogRecord memory log)
    {
        log.chain_id = chainId;
        log._contract = emitter;
        log.topic_0 = reactive.SLEEVE_FUNDED_TOPIC();
        log.topic_1 = sleeveId;
        log.topic_2 = uint256(uint160(address(this)));
        log.data = abi.encode(uint256(1e18), uint256(1e18), uint256(1e18));
    }

    function _assertSubscription(MockSystemContract system, uint256 i, uint256[6] memory expected) internal view {
        for (uint256 j; j < 6; ++j) {
            assertEq(system.subscriptions(i, j), expected[j]);
        }
    }

    function _fourRanges(uint128 liquidity) internal {
        ZenithHook.Range[] memory shape = new ZenithHook.Range[](4);
        shape[0] = _range(-600, 600, liquidity);
        shape[1] = _range(-1200, 1200, liquidity);
        shape[2] = _range(-1800, 1800, liquidity);
        shape[3] = _range(-2400, 2400, liquidity);
        vm.prank(curator);
        hook.setShape(sleeve, shape);
    }

    function _openBondedShapedSleeve() internal returns (uint256 id) {
        id = _openFundedSleeve(curator, 100e18, 100e18);
        _bond(id, 20e18);
        _shape(id, narrow);
    }

    function _bond(uint256 id, uint256 amount) internal {
        vm.prank(curator);
        settler.postBond(id, amount);
    }

    function _shape(uint256 id, uint128 liquidity) internal {
        ZenithHook.Range[] memory shape = new ZenithHook.Range[](1);
        shape[0] = _range(-600, 600, liquidity);
        vm.prank(curator);
        hook.setShape(id, shape);
    }
}
