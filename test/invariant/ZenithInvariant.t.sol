// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {console2} from "forge-std/console2.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {ZenithTestBase} from "../utils/ZenithTestBase.sol";
import {ZenithHandler} from "./ZenithHandler.sol";

/// @notice Stateful invariant tests. Foundry calls the handler's actions in random order and checks, after
/// every call, the rules Zenith must never break.
contract ZenithInvariantTest is ZenithTestBase {
    ZenithHandler internal handler;

    function setUp() public override {
        super.setUp();
        _addExternalLiquidity(-6000, 6000, 1000e18);
        handler = new ZenithHandler(hook, manager, swapRouter, key);
        targetContract(address(handler));
    }

    /// @notice The per-sleeve ledger always sums to the ERC-6909 claims the hook holds.
    function invariant_ledgerEqualsClaims() public view {
        _assertLedgerEqualsClaims();
    }

    /// @notice Every range a sleeve records exists in the PoolManager with exactly that liquidity.
    function invariant_storedRangesMatchPool() public view {
        uint256 count = hook.sleeveCount();
        for (uint256 id; id < count; ++id) {
            _assertRangesMatchPool(id);
        }
    }

    /// @notice The hook never holds loose tokens: everything it controls sits in the PoolManager as claims.
    function invariant_hookHoldsNoLooseTokens() public view {
        assertEq(MockERC20(Currency.unwrap(currency0)).balanceOf(address(hook)), 0, "no loose token0");
        assertEq(MockERC20(Currency.unwrap(currency1)).balanceOf(address(hook)), 0, "no loose token1");
    }

    /// @notice Curators never hold funds, whatever they do: no tokens and no claims ever reach them.
    function invariant_curatorsNeverHoldFunds() public view {
        for (uint256 i; i < handler.CURATOR_COUNT(); ++i) {
            address curator = handler.curators(i);
            assertEq(MockERC20(Currency.unwrap(currency0)).balanceOf(curator), 0, "curator holds no token0");
            assertEq(MockERC20(Currency.unwrap(currency1)).balanceOf(curator), 0, "curator holds no token1");
            assertEq(manager.balanceOf(curator, currency0.toId()), 0, "curator holds no token0 claims");
            assertEq(manager.balanceOf(curator, currency1.toId()), 0, "curator holds no token1 claims");
        }
    }

    /// @notice A sleeve's cumulative collected fees never go down.
    function invariant_feesNeverDecrease() public view {
        assertFalse(handler.feesDecreased(), "a sleeve's fee counter decreased");
    }

    /// @dev Printed once per run, so it is visible that every action was actually exercised.
    function afterInvariant() public view {
        console2.log("fund", handler.calls("fund"));
        console2.log("setShape", handler.calls("setShape"));
        console2.log("setShape reverted (unaffordable)", handler.calls("setShape-reverted"));
        console2.log("clearShape", handler.calls("clearShape"));
        console2.log("swap", handler.calls("swap"));
        console2.log("poke", handler.calls("poke"));
        console2.log("deployControl", handler.calls("deployControl"));
    }
}
