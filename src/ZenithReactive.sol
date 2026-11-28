// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AbstractReactive} from "@reactive/src/base/AbstractReactive.sol";
import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";

import {IZenithKeeper} from "./interfaces/IZenith.sol";

/// @title ZenithReactive
/// @notice Zenith's reactive contract on Reactive Network. It turns two kinds of events into callbacks to
/// ZenithKeeper on the hook's chain: a Cron tick, which sweeps every sleeve (settle, release, forced close), and a
/// deposit into a sleeve, which checks that sleeve's bond at once.
/// @dev Built on Reactive Omni: the system contract calls `react` directly and callbacks are requested from it. The
/// keeper must know this contract's address, so this contract is deployed first and told the keeper's address once,
/// by its deployer. Until then it reacts to nothing. The first argument of each callback is left as address(0);
/// the callback proxy writes this contract's address there, which is what the keeper checks.
contract ZenithReactive is AbstractReactive {
    /// @notice Cron events are emitted by the legacy system contract.
    address public constant LEGACY_SYSTEM = 0x0000000000000000000000000000000000fffFfF;

    /// @notice topic0 of the hook's SleeveFunded event.
    uint256 public constant SLEEVE_FUNDED_TOPIC =
        uint256(keccak256("SleeveFunded(uint256,address,uint256,uint256,uint256)"));

    /// @notice Gas the keeper is given for each callback.
    uint64 public constant CALLBACK_GAS_LIMIT = 3_000_000;

    address public immutable owner;
    uint256 public immutable destinationChainId;
    address public immutable hook;
    uint256 public immutable cronTopic;

    /// @notice The keeper on the destination chain. Set once.
    address public keeper;

    event KeeperSet(address keeper);
    event Retired(address to, uint256 amount);

    error NotOwner();
    error KeeperAlreadySet();

    constructor(uint256 _destinationChainId, address _hook, uint256 _cronTopic) payable {
        owner = msg.sender;
        destinationChainId = _destinationChainId;
        hook = _hook;
        cronTopic = _cronTopic;
        SYSTEM.subscribe(block.chainid, LEGACY_SYSTEM, _cronTopic, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        SYSTEM.subscribe(
            _destinationChainId, _hook, SLEEVE_FUNDED_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
        );
    }

    /// @notice Points this contract at the keeper deployed with its address. Once, by the deployer.
    function setKeeper(address _keeper) external {
        if (msg.sender != owner) revert NotOwner();
        if (keeper != address(0)) revert KeeperAlreadySet();
        keeper = _keeper;
        emit KeeperSet(_keeper);
    }

    /// @notice Stops this contract for good, so a redeployment does not strand its balance: unsubscribes from both
    /// events, settles any debt and returns what is left to `to`. By the deployer. Settlement, release and forced
    /// close stay public functions on the hook's chain, so retiring the automation takes nothing from Zenith.
    function retire(address payable to) external {
        if (msg.sender != owner) revert NotOwner();
        SYSTEM.unsubscribe(block.chainid, LEGACY_SYSTEM, cronTopic, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        SYSTEM.unsubscribe(
            destinationChainId, hook, SLEEVE_FUNDED_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
        );
        _coverDebt();
        uint256 amount = address(this).balance;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit Retired(to, amount);
    }

    /// @notice Pays any debt to the system contract from this contract's balance.
    function coverDebt() external {
        _coverDebt();
    }

    /// @notice Called by the system contract for every event this contract subscribed to.
    function react(LogRecord calldata log) external onlySystem {
        address target = keeper;
        if (target == address(0)) return;
        bytes memory payload;
        if (log.topic0 == cronTopic && log.contractAddress == LEGACY_SYSTEM) {
            payload = abi.encodeCall(IZenithKeeper.tick, (address(0)));
        } else if (
            log.topic0 == SLEEVE_FUNDED_TOPIC && log.contractAddress == hook && log.chainId == destinationChainId
        ) {
            payload = abi.encodeCall(IZenithKeeper.checkBond, (address(0), log.topic1));
        } else {
            return;
        }
        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: destinationChainId, recipient: target, gasLimit: CALLBACK_GAS_LIMIT, payload: payload
            })
        );
    }
}
