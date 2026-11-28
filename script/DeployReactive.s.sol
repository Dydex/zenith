// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";

import {ZenithReactive} from "../src/ZenithReactive.sol";

/// @notice Step 1 of 3 of Zenith's Reactive automation: deploys ZenithReactive on Reactive Network, subscribed to a
/// Cron tick.
///
///   forge script script/DeployReactive.s.sol --rpc-url https://lasna-rpc.rnk.dev/ --broadcast --account <name>
///
/// Then script/DeployKeeper.s.sol on the hook's chain and script/SetKeeper.s.sol back here, from the same account.
/// DESTINATION_CHAIN_ID (default 1301, Unichain Sepolia) is the chain of the keeper it will call. REACTIVE_FUNDING (default 1 ether of lREACT) pays for its reactions. CRON_TOPIC picks the schedule; the
/// default, Cron1000, fires every 1,000 Reactive blocks. Writes deployments/reactive-<Reactive chain id>.json.
contract DeployReactive is Script {
    uint256 internal constant CRON1000 = 0xe20b31294d84c3661ddc8f423abb9c70310d0cf172aa2714ead78029b325e3f4;

    function run() external returns (ZenithReactive reactive) {
        uint256 destination = vm.envOr("DESTINATION_CHAIN_ID", uint256(1301));
        uint256 cron = vm.envOr("CRON_TOPIC", CRON1000);
        uint256 funding = vm.envOr("REACTIVE_FUNDING", uint256(1 ether));

        vm.startBroadcast();
        reactive = new ZenithReactive{value: funding}(destination, cron);
        vm.stopBroadcast();

        string memory json = "reactive";
        vm.serializeUint(json, "chainId", block.chainid);
        vm.serializeUint(json, "block", block.number);
        vm.serializeUint(json, "destinationChainId", destination);
        vm.serializeBytes32(json, "cronTopic", bytes32(cron));
        string memory out = vm.serializeAddress(json, "reactive", address(reactive));
        string memory path =
            string.concat(vm.projectRoot(), "/deployments/reactive-", vm.toString(block.chainid), ".json");
        vm.writeJson(out, path);
        console2.log("reactive", address(reactive));
        console2.log("written", path);
    }
}
