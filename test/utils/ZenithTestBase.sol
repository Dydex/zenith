// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {ZenithHook} from "../../src/ZenithHook.sol";

/// @notice Shared setup: a fresh PoolManager, two tokens, the hook at an address carrying its permission flags,
/// and one initialised pool (fee 0.3%, tick spacing 60) bound to the hook.
abstract contract ZenithTestBase is Test, Deployers {
    using StateLibrary for IPoolManager;

    ZenithHook internal hook;
    address internal constant HOOK_ADDRESS = address(uint160(Hooks.BEFORE_INITIALIZE_FLAG) | (uint160(0x4444) << 144));

    function setUp() public virtual {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        deployCodeTo("ZenithHook.sol:ZenithHook", abi.encode(manager), HOOK_ADDRESS);
        hook = ZenithHook(HOOK_ADDRESS);

        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);

        (key,) = initPool(currency0, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
    }

    /// @dev Liquidity from an ordinary LP, so swaps have depth outside the sleeves.
    function _addExternalLiquidity(int24 tickLower, int24 tickUpper, uint256 liquidity) internal {
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: int256(liquidity), salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    function _openFundedSleeve(address curator, uint128 amount0, uint128 amount1) internal returns (uint256 id) {
        id = hook.openSleeve(curator);
        hook.fund(id, amount0, amount1);
    }

    function _range(int24 tickLower, int24 tickUpper, uint128 liquidity)
        internal
        pure
        returns (ZenithHook.Range memory)
    {
        return ZenithHook.Range({tickLower: tickLower, tickUpper: tickUpper, liquidity: liquidity});
    }

    /// @dev Liquidity Uniswap itself records for a sleeve's position (owner = hook, salt = sleeve id).
    function _positionLiquidity(uint256 sleeveId, int24 tickLower, int24 tickUpper) internal view returns (uint128) {
        bytes32 positionKey =
            Position.calculatePositionKey(address(hook), tickLower, tickUpper, hook.sleeveSalt(sleeveId));
        return manager.getPositionLiquidity(key.toId(), positionKey);
    }

    /// @dev The core accounting invariant: the per-sleeve ledger sums to the claims the hook holds.
    function _assertLedgerEqualsClaims() internal view {
        (uint256 total0, uint256 total1) = hook.totalIdle();
        assertEq(total0, manager.balanceOf(address(hook), currency0.toId()), "ledger0 == claims0");
        assertEq(total1, manager.balanceOf(address(hook), currency1.toId()), "ledger1 == claims1");
    }

    /// @dev Every range a sleeve stores must exist in the PoolManager with exactly that liquidity.
    function _assertRangesMatchPool(uint256 sleeveId) internal view {
        ZenithHook.Range[] memory ranges = hook.getRanges(sleeveId);
        for (uint256 i; i < ranges.length; ++i) {
            assertEq(
                _positionLiquidity(sleeveId, ranges[i].tickLower, ranges[i].tickUpper),
                ranges[i].liquidity,
                "stored range matches pool position"
            );
        }
    }

    /// @dev Up to MAX_RANGES distinct, aligned ranges within +-3000 ticks, each small enough to afford.
    function _randomShape(uint256 seed) internal view returns (ZenithHook.Range[] memory shape) {
        uint256 n = bound(seed, 0, hook.MAX_RANGES());
        shape = new ZenithHook.Range[](n);
        for (uint256 i; i < n; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            // Distinct by construction: each index gets its own lower tick band.
            int24 lower = -3000 + int24(int256(i)) * 600 + int24(int256(bound(r, 0, 9))) * 60;
            int24 upper = lower + int24(int256(bound(r >> 32, 1, 20))) * 60;
            uint128 liquidity = uint128(bound(r >> 64, 1e12, 2e18));
            shape[i] = _range(lower, upper, liquidity);
        }
    }
}
