// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {ZenithHook} from "../src/ZenithHook.sol";
import {ZenithSettler} from "../src/ZenithSettler.sol";
import {IZenithKeeper, IZenithReactive} from "../src/interfaces/IZenith.sol";
import {ZenithTestBase} from "./utils/ZenithTestBase.sol";

/// @notice Stands in for Reactive Network's system contract: records subscriptions and callback requests.
contract MockSystemContract {
    struct CallbackConfiguration {
        uint256 chainId;
        address recipient;
        uint64 gasLimit;
        bytes payload;
    }

    uint256[6][] public subscriptions;
    CallbackConfiguration[] internal _callbacks;

    function subscribe(uint256 chainId, address target, uint256 t0, uint256 t1, uint256 t2, uint256 t3) external {
        subscriptions.push([chainId, uint256(uint160(target)), t0, t1, t2, t3]);
    }

    function requestCallbackV_1_0(CallbackConfiguration memory config) external {
        _callbacks.push(config);
    }

    function subscriptionCount() external view returns (uint256) {
        return subscriptions.length;
    }

    function callbackCount() external view returns (uint256) {
        return _callbacks.length;
    }

    function callback(uint256 i) external view returns (CallbackConfiguration memory) {
        return _callbacks[i];
    }

    function debt(address) external pure returns (uint256) {
        return 0;
    }

    receive() external payable {}
}

/// @notice Reactive Network automation on Reactive Omni. The reactive contract turns Cron ticks and deposits into
/// callback requests to the system contract; the callback proxy delivers them to the keeper, writing the reactive
/// contract's address over the first argument; the keeper settles, releases and force-closes. The system contract
/// and the proxy are simulated. The keeper and reactive contract are compiled with 0.8.30 and used here through
/// their interfaces.
contract ZenithReactiveTest is ZenithTestBase {
    uint256 internal constant UNICHAIN_SEPOLIA = 1301;
    uint256 internal constant LASNA = 5_318_007;
    address internal constant SYSTEM = 0x8888888888888888888888888888888888888888;
    address internal constant LEGACY_SYSTEM = 0x0000000000000000000000000000000000fffFfF;
    uint256 internal constant CRON1000 = 0xe20b31294d84c3661ddc8f423abb9c70310d0cf172aa2714ead78029b325e3f4;
    uint256 internal constant IGNORE = 0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad;

    ZenithSettler internal settler;
    IZenithKeeper internal keeper;
    IZenithReactive internal reactive;
    MockSystemContract internal system;
    address internal proxy = makeAddr("callbackProxy");
    address internal curator = makeAddr("curator");
    uint256 internal sleeve;
    uint128 internal narrow;

    function setUp() public override {
        super.setUp();
        settler = new ZenithSettler(hook);
        hook.setSettler(address(settler));

        vm.etch(SYSTEM, address(new MockSystemContract()).code);
        system = MockSystemContract(payable(SYSTEM));
        reactive = IZenithReactive(
            deployCode("ZenithReactive.sol:ZenithReactive", abi.encode(UNICHAIN_SEPOLIA, address(hook), CRON1000))
        );
        keeper = IZenithKeeper(
            deployCode("ZenithKeeper.sol:ZenithKeeper", abi.encode(address(settler), proxy, address(reactive)))
        );
        reactive.setKeeper(address(keeper));

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

        vm.expectEmit(address(keeper));
        emit IZenithKeeper.Swept(2, 0, 0, 0);
        vm.prank(proxy);
        keeper.tick(address(reactive)); // nothing due yet, but every tick leaves a trace

        vm.warp(block.timestamp + hook.PERIOD());
        vm.expectEmit(address(keeper));
        emit IZenithKeeper.Swept(2, 2, 0, 0);
        vm.prank(proxy);
        keeper.tick(address(reactive));
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
        keeper.tick(address(reactive)); // settles, and slashes
        (,,,,, uint256 pending,,) = settler.accounts(sleeve);
        assertGt(pending, 0, "a slash is waiting");

        uint256 idle = hook.getSleeve(sleeve).idle1;
        vm.warp(block.timestamp + hook.PERIOD() / 2);
        vm.prank(proxy);
        keeper.tick(address(reactive));
        assertEq(hook.getSleeve(sleeve).idle1 - idle, pending / 2, "half released to depositors");
    }

    function test_checkBondClosesAnUnderBondedSleeveAtOnce() public {
        _bond(sleeve, 10e18);
        _shape(sleeve, narrow);
        vm.prank(proxy);
        keeper.checkBond(address(reactive), sleeve);
        assertEq(hook.getRanges(sleeve).length, 1, "still bonded: left alone");

        hook.fund(sleeve, 100e18, 100e18); // the same bond no longer covers the larger sleeve
        vm.prank(proxy);
        keeper.checkBond(address(reactive), sleeve);
        assertEq(hook.getRanges(sleeve).length, 0, "closed");
    }

    function test_onlyTheCallbackProxyCanCall() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSignature("NotAuthorized(address,address)", stranger, proxy));
        keeper.tick(address(reactive));
    }

    function test_onlyOurReactiveContractCanAsk() public {
        address other = makeAddr("someone else's reactive contract");
        vm.prank(proxy);
        vm.expectRevert(abi.encodeWithSignature("CallbackNotAuthorized(address,address)", other, address(reactive)));
        keeper.tick(other);
    }

    function test_oneFailingSleeveDoesNotBlockTheOthers() public {
        _bond(sleeve, 20e18);
        _shape(sleeve, narrow);
        uint256 second = _openBondedShapedSleeve();
        vm.warp(block.timestamp + hook.PERIOD());
        vm.mockCallRevert(address(settler), abi.encodeCall(ZenithSettler.settle, (sleeve)), bytes("boom"));

        vm.expectEmit(address(keeper));
        emit IZenithKeeper.ActionFailed(sleeve, ZenithSettler.settle.selector, bytes("boom"));
        keeper.sweep();
        assertEq(hook.getScore(second).periodStart, block.timestamp, "the other sleeve was still settled");
    }

    /// @notice A sweep that runs short of gas stops before a sleeve it might not finish, and the next one starts
    /// from that sleeve.
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
    /// allowance the keeper keeps back. Run with `--isolate` so every call is a fresh transaction with cold storage,
    /// as on chain: about 794k gas on Foundry 1.10.1, against an allowance of 1M.
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

    function test_subscribesToCronAndDeposits() public view {
        assertEq(system.subscriptionCount(), 2);
        _assertSubscription(0, [block.chainid, uint256(uint160(LEGACY_SYSTEM)), CRON1000, IGNORE, IGNORE, IGNORE]);
        _assertSubscription(
            1,
            [UNICHAIN_SEPOLIA, uint256(uint160(address(hook))), reactive.SLEEVE_FUNDED_TOPIC(), IGNORE, IGNORE, IGNORE]
        );
    }

    function test_sleeveFundedTopicMatchesTheHookEvent() public view {
        assertEq(bytes32(reactive.SLEEVE_FUNDED_TOPIC()), ZenithHook.SleeveFunded.selector);
    }

    function test_onlyTheSystemContractCanReact() public {
        address stranger = makeAddr("stranger");
        IZenithReactive.LogRecord memory log = _cronLog();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSignature("NotAuthorized(address,address)", stranger, SYSTEM));
        reactive.react(log);
    }

    function test_keeperIsSetOnceByTheDeployer() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(abi.encodeWithSignature("NotOwner()"));
        reactive.setKeeper(address(1));
        vm.expectRevert(abi.encodeWithSignature("KeeperAlreadySet()"));
        reactive.setKeeper(address(1));
    }

    function test_reactsToNothingUntilTheKeeperIsSet() public {
        IZenithReactive fresh = IZenithReactive(
            deployCode("ZenithReactive.sol:ZenithReactive", abi.encode(UNICHAIN_SEPOLIA, address(hook), CRON1000))
        );
        uint256 before = system.callbackCount();
        vm.prank(SYSTEM);
        fresh.react(_cronLog());
        assertEq(system.callbackCount(), before, "no callback without a keeper");
    }

    function test_cronTickRequestsASweep() public {
        vm.prank(SYSTEM);
        reactive.react(_cronLog());
        _assertCallback(abi.encodeCall(IZenithKeeper.tick, (address(0))));
    }

    function test_depositRequestsABondCheckForThatSleeve() public {
        IZenithReactive.LogRecord memory log = _fundedLog(UNICHAIN_SEPOLIA, address(hook), sleeve);
        vm.prank(SYSTEM);
        reactive.react(log);
        _assertCallback(abi.encodeCall(IZenithKeeper.checkBond, (address(0), sleeve)));
    }

    function test_ignoresLookalikeEvents() public {
        IZenithReactive.LogRecord memory otherHook = _fundedLog(UNICHAIN_SEPOLIA, makeAddr("another hook"), sleeve);
        IZenithReactive.LogRecord memory otherChain = _fundedLog(1, address(hook), sleeve); // same address elsewhere
        IZenithReactive.LogRecord memory fakeCron = _cronLog();
        fakeCron.contractAddress = makeAddr("not the system contract");
        vm.startPrank(SYSTEM);
        reactive.react(otherHook);
        reactive.react(otherChain);
        reactive.react(fakeCron);
        vm.stopPrank();
        assertEq(system.callbackCount(), 0, "no callbacks");
    }

    /// @notice The whole loop: a Cron tick reaches the reactive contract, which requests a callback; the proxy
    /// delivers it on the hook's chain with the reactive contract's address written in; the keeper settles.
    function test_cronTickSettlesASleeveEndToEnd() public {
        _bond(sleeve, 20e18);
        _shape(sleeve, narrow);
        vm.warp(block.timestamp + hook.PERIOD());

        vm.prank(SYSTEM);
        reactive.react(_cronLog());
        MockSystemContract.CallbackConfiguration memory config = system.callback(0);
        assertEq(config.chainId, UNICHAIN_SEPOLIA, "to the hook's chain");
        assertEq(config.recipient, address(keeper), "to the keeper");

        _deliver(config.payload, address(reactive));
        assertEq(hook.getScore(sleeve).periodStart, block.timestamp, "settled by the callback");
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    /// @dev What Reactive's callback proxy does: write the requesting contract's address over the first argument.
    function _deliver(bytes memory payload, address sender) internal {
        assembly {
            mstore(add(payload, 36), sender)
        }
        vm.prank(proxy);
        (bool ok,) = address(keeper).call(payload);
        assertTrue(ok, "callback delivered");
    }

    function _assertCallback(bytes memory payload) internal view {
        assertEq(system.callbackCount(), 1);
        MockSystemContract.CallbackConfiguration memory config = system.callback(0);
        assertEq(config.chainId, UNICHAIN_SEPOLIA);
        assertEq(config.recipient, address(keeper));
        assertEq(config.gasLimit, reactive.CALLBACK_GAS_LIMIT());
        assertEq(config.payload, payload);
    }

    function _cronLog() internal pure returns (IZenithReactive.LogRecord memory log) {
        log.chainId = LASNA;
        log.contractAddress = LEGACY_SYSTEM;
        log.topic0 = CRON1000;
        log.data = abi.encode(uint256(1000));
        log.opCode = 1;
    }

    function _fundedLog(uint256 chainId, address emitter, uint256 sleeveId)
        internal
        view
        returns (IZenithReactive.LogRecord memory log)
    {
        log.chainId = chainId;
        log.contractAddress = emitter;
        log.topic0 = reactive.SLEEVE_FUNDED_TOPIC();
        log.topic1 = sleeveId;
        log.topic2 = uint256(uint160(address(this)));
        log.data = abi.encode(uint256(1e18), uint256(1e18), uint256(1e18));
        log.opCode = 3;
    }

    function _assertSubscription(uint256 i, uint256[6] memory expected) internal view {
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
