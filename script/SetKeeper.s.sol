// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";

import {ZenithReactive} from "../src/ZenithReactive.sol";

/// @notice Step 3 of 3 of Zenith's Reactive automation: points the reactive contract at the keeper, which turns the
/// automation on.
///
///   forge script script/SetKeeper.s.sol --rpc-url https://lasna-rpc.rnk.dev/ --broadcast --account <name>
///
/// Reads deployments/reactive-<chain id>.json and deployments/keeper-<DESTINATION_CHAIN_ID>.json (default 1301).
contract SetKeeper is Script {
    function run() external {
        string memory root = string.concat(vm.projectRoot(), "/deployments/");
        uint256 destination = vm.envOr("DESTINATION_CHAIN_ID", uint256(1301));
        ZenithReactive reactive = ZenithReactive(
            payable(vm.parseJsonAddress(
                    vm.readFile(string.concat(root, "reactive-", vm.toString(block.chainid), ".json")), ".reactive"
                ))
        );
        address keeper = vm.parseJsonAddress(
            vm.readFile(string.concat(root, "keeper-", vm.toString(destination), ".json")), ".keeper"
        );

        vm.startBroadcast();
        reactive.setKeeper(keeper);
        vm.stopBroadcast();
        console2.log("reactive", address(reactive));
        console2.log("now calls keeper", keeper);
    }
}
