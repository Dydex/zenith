// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPayable} from "@reactive/src/interfaces/IPayable.sol";
import {Script, console2} from "forge-std/Script.sol";

import {ZenithKeeper} from "../src/ZenithKeeper.sol";
import {IZenithSettler} from "../src/interfaces/IZenith.sol";

/// @notice Step 2 of 3 of Zenith's Reactive automation: deploys ZenithKeeper next to the hook, accepting callbacks
/// only from the reactive contract deployed in step 1.
///
///   forge script script/DeployKeeper.s.sol --rpc-url https://sepolia.unichain.org --broadcast --account <name>
///
/// Reads the settler from deployments/<chain id>.json and the reactive contract from
/// deployments/reactive-<REACTIVE_CHAIN_ID>.json (default 5318007, Reactive Lasna). The keeper is funded with
/// KEEPER_FUNDING wei (default 0.01 ether) to pay for callbacks. On a local node there is no callback proxy: the
/// deployer stands in for it. Writes deployments/keeper-<chain id>.json.
contract DeployKeeper is Script {
    uint256 internal constant UNICHAIN_SEPOLIA = 1301;
    address internal constant UNICHAIN_SEPOLIA_CALLBACK_PROXY = 0x775c9B990ADe401060B78D0e98684eEf8d2466C1;

    function run() external returns (ZenithKeeper keeper) {
        string memory root = string.concat(vm.projectRoot(), "/deployments/");
        string memory zenith = vm.readFile(string.concat(root, vm.toString(block.chainid), ".json"));
        address settler = vm.parseJsonAddress(zenith, ".settler");
        uint256 reactiveChain = vm.envOr("REACTIVE_CHAIN_ID", uint256(5_318_007));
        string memory reactiveJson = vm.readFile(string.concat(root, "reactive-", vm.toString(reactiveChain), ".json"));
        address reactive = vm.parseJsonAddress(reactiveJson, ".reactive");

        vm.startBroadcast();
        (, address broadcaster,) = vm.readCallers();
        bool live = block.chainid == UNICHAIN_SEPOLIA;
        address proxy = live ? UNICHAIN_SEPOLIA_CALLBACK_PROXY : broadcaster;
        uint256 funding = live ? vm.envOr("KEEPER_FUNDING", uint256(0.01 ether)) : 0;
        keeper = new ZenithKeeper{value: funding}(IZenithSettler(settler), IPayable(payable(proxy)), reactive);
        vm.stopBroadcast();

        string memory json = "keeper";
        vm.serializeUint(json, "chainId", block.chainid);
        vm.serializeUint(json, "block", block.number);
        vm.serializeAddress(json, "settler", settler);
        vm.serializeAddress(json, "callbackProxy", proxy);
        vm.serializeAddress(json, "reactive", reactive);
        string memory out = vm.serializeAddress(json, "keeper", address(keeper));
        string memory path = string.concat(root, "keeper-", vm.toString(block.chainid), ".json");
        vm.writeJson(out, path);
        console2.log("keeper", address(keeper));
        console2.log("written", path);
    }
}
