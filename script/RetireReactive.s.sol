// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";

import {ZenithReactive} from "../src/ZenithReactive.sol";

/// @notice Retires the reactive contract recorded in deployments/reactive-<chain id>.json: unsubscribes it and returns
/// its balance to the broadcasting account. Run before replacing a deployment, so its balance is not stranded.
///
///   forge script script/RetireReactive.s.sol --rpc-url https://lasna-rpc.rnk.dev/ --broadcast --account <name>
contract RetireReactive is Script {
    function run() external {
        string memory path =
            string.concat(vm.projectRoot(), "/deployments/reactive-", vm.toString(block.chainid), ".json");
        ZenithReactive reactive = ZenithReactive(payable(vm.parseJsonAddress(vm.readFile(path), ".reactive")));
        vm.startBroadcast();
        (, address broadcaster,) = vm.readCallers();
        uint256 balance = address(reactive).balance;
        reactive.retire(payable(broadcaster));
        vm.stopBroadcast();
        console2.log("retired", address(reactive));
        console2.log("returned", balance);
    }
}
