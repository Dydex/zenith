// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {ZenithReactive} from "../src/ZenithReactive.sol";

/// @notice Deploys Zenith's reactive contract on Reactive Network, pointed at a Zenith deployment on another chain.
///
///   forge script script/DeployReactive.s.sol --rpc-url https://lasna-rpc.rnk.dev/ --broadcast --account <name>
///
/// Use the same account that ran script/Deploy.s.sol: the keeper accepts callbacks only from reactive contracts
/// deployed by its own deployer. DESTINATION_CHAIN_ID (default 1301, Unichain Sepolia) selects which
/// deployments/<chain id>.json to read. The contract is funded with REACTIVE_FUNDING wei (default 1 ether of lREACT)
/// to pay for its subscriptions. CRON_TOPIC picks the schedule; the default, Cron1000, fires every 1,000 Reactive
/// blocks. The address is written to deployments/reactive-<Reactive chain id>.json.
contract DeployReactive is Script {
    uint256 internal constant CRON1000 = 0xe20b31294d84c3661ddc8f423abb9c70310d0cf172aa2714ead78029b325e3f4;

    function run() external returns (ZenithReactive reactive) {
        uint256 destination = vm.envOr("DESTINATION_CHAIN_ID", uint256(1301));
        string memory zenith =
            vm.readFile(string.concat(vm.projectRoot(), "/deployments/", vm.toString(destination), ".json"));
        address hook = vm.parseJsonAddress(zenith, ".hook");
        address keeper = vm.parseJsonAddress(zenith, ".keeper");
        uint256 cron = vm.envOr("CRON_TOPIC", CRON1000);
        uint256 funding = vm.envOr("REACTIVE_FUNDING", uint256(1 ether));

        vm.startBroadcast();
        reactive = new ZenithReactive{value: funding}(destination, hook, keeper, cron);
        vm.stopBroadcast();

        string memory json = "reactive";
        vm.serializeUint(json, "chainId", block.chainid);
        vm.serializeUint(json, "block", block.number);
        vm.serializeUint(json, "destinationChainId", destination);
        vm.serializeAddress(json, "hook", hook);
        vm.serializeAddress(json, "keeper", keeper);
        vm.serializeBytes32(json, "cronTopic", bytes32(cron));
        string memory out = vm.serializeAddress(json, "reactive", address(reactive));
        string memory path =
            string.concat(vm.projectRoot(), "/deployments/reactive-", vm.toString(block.chainid), ".json");
        vm.writeJson(out, path);
        console2.log("reactive", address(reactive));
        console2.log("written", path);
    }
}
