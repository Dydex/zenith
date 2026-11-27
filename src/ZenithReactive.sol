// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AbstractReactive} from "reactive-lib/abstract-base/AbstractReactive.sol";

import {ZenithKeeper} from "./ZenithKeeper.sol";

/// @title ZenithReactive
/// @notice Zenith's reactive contract, deployed on Reactive Network. It turns two kinds of events into callbacks to
/// ZenithKeeper on the hook's chain: a Cron tick, which sweeps every sleeve (settle, release, forced close), and a
/// deposit into a sleeve, which checks that sleeve's bond at once.
/// @dev Reactive runs `react` inside a ReactVM copy of this contract; subscriptions are made by the copy deployed to
/// the Reactive Network itself. The first argument of each callback is left as address(0): Reactive replaces it
/// with this contract's ReactVM id, which the keeper checks.
contract ZenithReactive is AbstractReactive {
    /// @notice topic_0 of the hook's SleeveFunded event.
    uint256 public constant SLEEVE_FUNDED_TOPIC =
        uint256(keccak256("SleeveFunded(uint256,address,uint256,uint256,uint256)"));

    /// @notice Gas the keeper is given for each callback.
    uint64 public constant CALLBACK_GAS_LIMIT = 3_000_000;

    /// @notice Chain the hook and keeper are on, and the contracts this watches and calls.
    uint256 public immutable destinationChainId;
    address public immutable hook;
    address public immutable keeper;

    /// @notice topic_0 of the Cron event that drives sweeps.
    uint256 public immutable cronTopic;

    constructor(uint256 _destinationChainId, address _hook, address _keeper, uint256 _cronTopic) payable {
        destinationChainId = _destinationChainId;
        hook = _hook;
        keeper = _keeper;
        cronTopic = _cronTopic;
        if (!vm) {
            service.subscribe(
                block.chainid, address(service), _cronTopic, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
            );
            service.subscribe(
                _destinationChainId, _hook, SLEEVE_FUNDED_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
            );
        }
    }

    /// @notice Called by Reactive Network inside the ReactVM for every event this contract subscribed to.
    function react(LogRecord calldata log) external vmOnly {
        bytes memory payload;
        if (log.topic_0 == cronTopic && log._contract == address(service)) {
            payload = abi.encodeCall(ZenithKeeper.tick, (address(0)));
        } else if (log.topic_0 == SLEEVE_FUNDED_TOPIC && log._contract == hook && log.chain_id == destinationChainId) {
            payload = abi.encodeCall(ZenithKeeper.checkBond, (address(0), log.topic_1));
        } else {
            return;
        }
        emit Callback(destinationChainId, keeper, CALLBACK_GAS_LIMIT, payload);
    }
}
