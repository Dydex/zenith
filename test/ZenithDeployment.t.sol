// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {Test} from "forge-std/Test.sol";

import {ZenithHook} from "../src/ZenithHook.sol";

/// @notice Deploys the hook the way a Foundry script does: through the standard CREATE2 factory at a mined
/// address. The account that initialises the pool must still be the intended one, not the factory.
contract ZenithDeploymentTest is Test, Deployers {
    function test_deploysThroughCreate2FactoryAndInitialises() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        address initializer = makeAddr("initializer");
        bytes memory args = abi.encode(manager, initializer);
        (address expected, bytes32 salt) =
            HookMiner.find(CREATE2_FACTORY, uint160(Hooks.BEFORE_INITIALIZE_FLAG), type(ZenithHook).creationCode, args);

        (bool ok, bytes memory deployed) =
            CREATE2_FACTORY.call(abi.encodePacked(salt, type(ZenithHook).creationCode, args));
        assertTrue(ok, "factory deployment");
        assertEq(address(bytes20(deployed)), expected, "mined address");

        ZenithHook hook = ZenithHook(expected);
        PoolKey memory poolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(address(hook)));
        vm.prank(initializer);
        manager.initialize(poolKey, SQRT_PRICE_1_1);
        assertTrue(hook.poolBound(), "the intended account could initialise the pool");
    }

    function test_revertsOnZeroInitializer() public {
        deployFreshManagerAndRouters();
        vm.expectRevert(ZenithHook.ZeroInitializer.selector);
        deployCodeTo(
            "ZenithHook.sol:ZenithHook", abi.encode(manager, address(0)), address(uint160(Hooks.BEFORE_INITIALIZE_FLAG))
        );
    }
}
