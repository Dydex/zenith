// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {ZenithHook} from "../src/ZenithHook.sol";
import {ZenithTestBase} from "./utils/ZenithTestBase.sol";

contract ZenithLedgerTest is ZenithTestBase {
    // ------------------------------------------------------------------
    // Binding
    // ------------------------------------------------------------------

    function test_bindsPoolAndOpensControlSleeve() public view {
        assertTrue(hook.poolBound());
        assertEq(hook.sleeveCount(), 1);
        ZenithHook.Sleeve memory control = hook.getSleeve(hook.CONTROL_SLEEVE());
        assertEq(control.curator, address(0));
        assertTrue(control.exists);
    }

    function test_revertsWhenSecondPoolInitialised() public {
        _expectHookRevert(address(hook), ZenithHook.PoolAlreadyBound.selector);
        initPool(currency0, currency1, IHooks(address(hook)), 500, SQRT_PRICE_1_1);
    }

    function test_revertsWhenNotInitializerInitialises() public {
        ZenithHook fresh = _deployFreshHook();
        PoolKey memory k = PoolKey(currency0, currency1, 3000, 60, IHooks(address(fresh)));
        vm.prank(makeAddr("stranger"));
        _expectHookRevert(address(fresh), ZenithHook.NotInitializer.selector);
        manager.initialize(k, SQRT_PRICE_1_1);
    }

    function test_revertsOnNativeCurrencyPool() public {
        ZenithHook fresh = _deployFreshHook();
        PoolKey memory k = PoolKey(Currency.wrap(address(0)), currency1, 3000, 60, IHooks(address(fresh)));
        _expectHookRevert(address(fresh), ZenithHook.NativeCurrencyUnsupported.selector);
        manager.initialize(k, SQRT_PRICE_1_1);
    }

    // ------------------------------------------------------------------
    // Sleeves
    // ------------------------------------------------------------------

    function test_openSleeveAssignsCurator() public {
        address curator = makeAddr("curator");
        uint256 id = hook.openSleeve(curator);
        assertEq(id, 1);
        assertEq(hook.getSleeve(id).curator, curator);
    }

    function test_revertsOnZeroCurator() public {
        vm.expectRevert(ZenithHook.ZeroCurator.selector);
        hook.openSleeve(address(0));
    }

    function test_capsSleeveCount() public {
        uint256 max = hook.MAX_SLEEVES();
        for (uint256 i = 1; i < max; ++i) {
            hook.openSleeve(makeAddr(string(abi.encode(i))));
        }
        vm.expectRevert(ZenithHook.TooManySleeves.selector);
        hook.openSleeve(makeAddr("one-too-many"));
    }

    function test_revertsWhenFundingUnknownSleeve() public {
        vm.expectRevert(ZenithHook.UnknownSleeve.selector);
        hook.fund(7, 1, 1);
    }

    function test_unlockCallbackOnlyFromPoolManager() public {
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.unlockCallback(abi.encode(ZenithHook.Action.Fund, ""));
    }

    // ------------------------------------------------------------------
    // Ledger
    // ------------------------------------------------------------------

    function test_fundMovesTokensIntoClaims() public {
        uint256 id = hook.openSleeve(makeAddr("curator"));
        uint256 before0 = currency0.balanceOfSelf();
        uint256 before1 = currency1.balanceOfSelf();

        hook.fund(id, 1e18, 2e18);

        assertEq(before0 - currency0.balanceOfSelf(), 1e18, "token0 pulled from funder");
        assertEq(before1 - currency1.balanceOfSelf(), 2e18, "token1 pulled from funder");
        assertEq(manager.balanceOf(address(hook), currency0.toId()), 1e18, "token0 held as claims");
        assertEq(manager.balanceOf(address(hook), currency1.toId()), 2e18, "token1 held as claims");

        ZenithHook.Sleeve memory s = hook.getSleeve(id);
        assertEq(s.idle0, 1e18);
        assertEq(s.idle1, 2e18);
    }

    /// @notice Random sleeves funded with random amounts: the ledger must always equal the claims held,
    /// and tokens must only ever be credited to the sleeve that was funded.
    function testFuzz_ledgerAlwaysEqualsClaims(uint8 sleeves, uint256 seed) public {
        uint256 n = bound(sleeves, 1, hook.MAX_SLEEVES() - 1);
        for (uint256 i; i < n; ++i) {
            hook.openSleeve(makeAddr(string(abi.encode("curator", i))));
        }

        uint256[] memory expected0 = new uint256[](n + 1);
        uint256[] memory expected1 = new uint256[](n + 1);
        for (uint256 round; round < 12; ++round) {
            seed = uint256(keccak256(abi.encode(seed, round)));
            uint256 id = seed % (n + 1); // includes the control sleeve
            uint128 a0 = uint128(bound(seed >> 8, 0, 1e30));
            uint128 a1 = uint128(bound(seed >> 128, 0, 1e30));
            if (a0 == 0 && a1 == 0) continue;
            try hook.fund(id, a0, a1) returns (uint256, uint128 used0, uint128 used1) {
                expected0[id] += used0;
                expected1[id] += used1;
            } catch (bytes memory reason) {
                // A later deposit takes the sleeve's ratio; if one side is missing it buys nothing.
                assertEq(bytes4(reason), ZenithHook.ZeroDeposit.selector, "only an empty deposit may fail");
            }
        }

        _assertLedgerEqualsClaims();
        for (uint256 id; id <= n; ++id) {
            ZenithHook.Sleeve memory s = hook.getSleeve(id);
            assertEq(s.idle0, expected0[id], "sleeve credited exactly (token0)");
            assertEq(s.idle1, expected1[id], "sleeve credited exactly (token1)");
        }
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    /// @dev The PoolManager wraps hook reverts, so match the exact wrapped error rather than any revert.
    function _expectHookRevert(address hookAddress, bytes4 reason) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                hookAddress,
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(reason),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
    }

    function _deployFreshHook() internal returns (ZenithHook fresh) {
        address target =
            address(uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG) | (uint160(0x5555) << 144));
        deployCodeTo("ZenithHook.sol:ZenithHook", abi.encode(manager, address(this)), target);
        fresh = ZenithHook(target);
    }
}
