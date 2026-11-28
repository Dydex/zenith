// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {Script, console2} from "forge-std/Script.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {ZenithHook} from "../src/ZenithHook.sol";
import {ZenithSettler} from "../src/ZenithSettler.sol";

/// @notice Deploys Zenith (hook, its math library and settler) and initialises its pool.
///
/// Local node:       forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast --private-key <key>
/// Unichain Sepolia: forge script script/Deploy.s.sol --rpc-url https://sepolia.unichain.org --broadcast --account <name>
///
/// The hook is deployed through the CREATE2 factory at an address mined to carry its permission flags. On a local
/// node a fresh PoolManager is deployed; on Unichain Sepolia the official one is used. Unless TOKEN0 and TOKEN1 are
/// set, two mintable demo tokens are deployed. Addresses are written to deployments/<chain id>.json.
///
/// Reactive Network automation is deployed separately, after this: script/DeployReactive.s.sol on Reactive Lasna, then
/// script/DeployKeeper.s.sol here, then script/SetKeeper.s.sol on Lasna.
contract Deploy is Script {
    uint256 internal constant UNICHAIN_SEPOLIA = 1301;
    address internal constant UNICHAIN_SEPOLIA_POOL_MANAGER = 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;

    uint24 internal constant FEE = 3000;
    int24 internal constant TICK_SPACING = 60;
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    function run() external returns (ZenithHook hook, PoolKey memory key) {
        vm.startBroadcast();
        (, address broadcaster,) = vm.readCallers();

        IPoolManager manager = _poolManager(broadcaster);
        (Currency currency0, Currency currency1) = _tokens();

        bytes memory args = abi.encode(manager, broadcaster);
        (address expected, bytes32 salt) = HookMiner.find(
            CREATE2_FACTORY,
            uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG),
            type(ZenithHook).creationCode,
            args
        );
        hook = new ZenithHook{salt: salt}(manager, broadcaster);
        require(address(hook) == expected, "hook deployed at an unexpected address");

        ZenithSettler settler = new ZenithSettler(hook);
        hook.setSettler(address(settler));

        key = PoolKey(currency0, currency1, FEE, TICK_SPACING, IHooks(address(hook)));
        manager.initialize(key, SQRT_PRICE_1_1);
        vm.stopBroadcast();

        _record(manager, hook, settler, key, broadcaster);
    }

    function _poolManager(address owner) internal returns (IPoolManager) {
        if (block.chainid == UNICHAIN_SEPOLIA) return IPoolManager(UNICHAIN_SEPOLIA_POOL_MANAGER);
        address configured = vm.envOr("POOL_MANAGER", address(0));
        if (configured != address(0)) return IPoolManager(configured);
        return new PoolManager(owner);
    }

    function _tokens() internal returns (Currency, Currency) {
        address a = vm.envOr("TOKEN0", address(0));
        address b = vm.envOr("TOKEN1", address(0));
        if (a == address(0) || b == address(0)) {
            a = address(new MockERC20("Zenith Demo USD", "zUSD", 18));
            b = address(new MockERC20("Zenith Demo ETH", "zETH", 18));
        }
        return a < b ? (Currency.wrap(a), Currency.wrap(b)) : (Currency.wrap(b), Currency.wrap(a));
    }

    function _record(
        IPoolManager manager,
        ZenithHook hook,
        ZenithSettler settler,
        PoolKey memory key,
        address initializer
    ) internal {
        string memory json = "deployment";
        vm.serializeUint(json, "chainId", block.chainid);
        vm.serializeUint(json, "block", block.number);
        vm.serializeAddress(json, "poolManager", address(manager));
        vm.serializeAddress(json, "hook", address(hook));
        vm.serializeAddress(json, "settler", address(settler));
        vm.serializeAddress(json, "initializer", initializer);
        vm.serializeAddress(json, "token0", Currency.unwrap(key.currency0));
        vm.serializeAddress(json, "token1", Currency.unwrap(key.currency1));
        vm.serializeUint(json, "fee", key.fee);
        string memory out = vm.serializeInt(json, "tickSpacing", key.tickSpacing);
        string memory path = string.concat(vm.projectRoot(), "/deployments/", vm.toString(block.chainid), ".json");
        vm.writeJson(out, path);
        console2.log("hook", address(hook));
        console2.log("written", path);
    }
}
