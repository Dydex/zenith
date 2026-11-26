// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Script, console2} from "forge-std/Script.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {ZenithHook} from "../src/ZenithHook.sol";
import {ZenithSettler} from "../src/ZenithSettler.sol";

/// @notice Runs one end-to-end flow against a deployment from Deploy.s.sol: liquidity from an ordinary LP, a funded
/// control, a bonded curator sleeve with a two-range shape, swaps in both directions, and fee collection.
///
/// forge script script/Demo.s.sol --rpc-url <rpc> --broadcast --private-key <key>
///
/// Needs the demo tokens deployed by Deploy.s.sol, because it mints them.
contract Demo is Script {
    uint256 internal constant UNICHAIN_SEPOLIA = 1301;
    address internal constant UNICHAIN_SEPOLIA_SWAP_ROUTER = 0x9140a78c1A137c7fF1c151EC8231272aF78a99A4;
    address internal constant UNICHAIN_SEPOLIA_LIQUIDITY_ROUTER = 0x5fa728C0A5cfd51BEe4B060773f50554c0C8A7AB;

    function run() external {
        string memory path = string.concat(vm.projectRoot(), "/deployments/", vm.toString(block.chainid), ".json");
        string memory json = vm.readFile(path);
        IPoolManager manager = IPoolManager(vm.parseJsonAddress(json, ".poolManager"));
        ZenithHook hook = ZenithHook(vm.parseJsonAddress(json, ".hook"));
        ZenithSettler settler = ZenithSettler(vm.parseJsonAddress(json, ".settler"));
        PoolKey memory key = PoolKey(
            Currency.wrap(vm.parseJsonAddress(json, ".token0")),
            Currency.wrap(vm.parseJsonAddress(json, ".token1")),
            uint24(vm.parseJsonUint(json, ".fee")),
            int24(vm.parseJsonInt(json, ".tickSpacing")),
            IHooks(address(hook))
        );

        vm.startBroadcast();
        (, address me,) = vm.readCallers();
        (PoolSwapTest swapRouter, PoolModifyLiquidityTest liquidityRouter) = _routers(manager);

        MockERC20 token0 = MockERC20(Currency.unwrap(key.currency0));
        MockERC20 token1 = MockERC20(Currency.unwrap(key.currency1));
        for (uint256 i; i < 2; ++i) {
            MockERC20 token = i == 0 ? token0 : token1;
            token.mint(me, 1_000e18);
            token.approve(address(hook), type(uint256).max);
            token.approve(address(swapRouter), type(uint256).max);
            token.approve(address(liquidityRouter), type(uint256).max);
            token.approve(address(settler), type(uint256).max);
        }

        // An ordinary LP, so swaps have depth beyond the sleeves.
        liquidityRouter.modifyLiquidity(key, ModifyLiquidityParams(-6000, 6000, 100e18, bytes32(0)), "");

        // The passive control, fully in range.
        uint256 control = hook.CONTROL_SLEEVE();
        hook.fund(control, 10e18, 10e18);
        hook.deployControl();

        // A curator sleeve with a two-range shape. Here the broadcaster plays the curator.
        uint256 sleeve = hook.openSleeve(me);
        hook.fund(sleeve, 10e18, 10e18);
        settler.postBond(sleeve, 2e18); // at least 5% of the sleeve's value, before it may shape
        ZenithHook.Range[] memory shape = new ZenithHook.Range[](2);
        shape[0] = ZenithHook.Range(-600, 600, 100e18);
        shape[1] = ZenithHook.Range(-120, 120, 200e18);
        hook.setShape(sleeve, shape);

        // Trading in both directions.
        for (uint256 i; i < 4; ++i) {
            bool zeroForOne = i % 2 == 0;
            swapRouter.swap(
                key,
                SwapParams(zeroForOne, -1e18, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
                PoolSwapTest.TestSettings(false, false),
                ""
            );
        }

        hook.poke(control);
        hook.poke(sleeve);
        vm.stopBroadcast();

        ZenithHook.Sleeve memory c = hook.getSleeve(control);
        ZenithHook.Sleeve memory s = hook.getSleeve(sleeve);
        console2.log("sleeve id", sleeve);
        console2.log("control fees token0/token1", c.fees0, c.fees1);
        console2.log("sleeve fees token0/token1", s.fees0, s.fees1);
    }

    function _routers(IPoolManager manager) internal returns (PoolSwapTest, PoolModifyLiquidityTest) {
        if (block.chainid == UNICHAIN_SEPOLIA) {
            return
                (PoolSwapTest(UNICHAIN_SEPOLIA_SWAP_ROUTER), PoolModifyLiquidityTest(UNICHAIN_SEPOLIA_LIQUIDITY_ROUTER));
        }
        return (new PoolSwapTest(manager), new PoolModifyLiquidityTest(manager));
    }
}
