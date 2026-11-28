// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AbstractReactive} from "@reactive/src/base/AbstractReactive.sol";
import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";

import {IZenithKeeper} from "./interfaces/IZenith.sol";

/// @title ZenithReactive
/// @notice Zenith's reactive contract on Reactive Network. It turns a Cron tick into a callback to ZenithKeeper on the
/// hook's chain, which sweeps every sleeve: settles those whose period is over, releases vested slashes and closes any
/// whose bond no longer covers it.
/// @dev Built on Reactive Omni: the system contract calls `react` directly and callbacks are requested from it. The
/// keeper must know this contract's address, so this contract is deployed first and told the keeper's address once,
/// by its deployer. Until then it reacts to nothing. The first argument of each callback is left as address(0);
/// the callback proxy writes this contract's address there, which is what the keeper checks.
contract ZenithReactive is AbstractReactive {
    /// @notice Cron events are emitted by the legacy system contract.
    address public constant LEGACY_SYSTEM = 0x0000000000000000000000000000000000fffFfF;

    /// @notice Gas requested for each callback. Reactive's relayer sends exactly what is requested (our first live
    /// callback went out with this contract's earlier 3,000,000) and neither the system contract nor the callback proxy
    /// caps it; the proxy keeps 130,000 back for itself and charges only for gas used.
    uint64 public constant CALLBACK_GAS_LIMIT = 5_000_000;

    address public immutable owner;
    uint256 public immutable destinationChainId;
    uint256 public immutable cronTopic;

    /// @notice The keeper on the destination chain. Set once.
    address public keeper;

    event KeeperSet(address keeper);
    event Retired(address to, uint256 amount);

    error NotOwner();
    error KeeperAlreadySet();

    constructor(uint256 _destinationChainId, uint256 _cronTopic) payable {
        owner = msg.sender;
        destinationChainId = _destinationChainId;
        cronTopic = _cronTopic;
        SYSTEM.subscribe(block.chainid, LEGACY_SYSTEM, _cronTopic, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    /// @notice Points this contract at the keeper deployed with its address. Once, by the deployer.
    function setKeeper(address _keeper) external {
        if (msg.sender != owner) revert NotOwner();
        if (keeper != address(0)) revert KeeperAlreadySet();
        keeper = _keeper;
        emit KeeperSet(_keeper);
    }

    /// @notice Stops this contract for good, so a redeployment does not strand its balance: unsubscribes, settles any
    /// debt and returns what is left to `to`. By the deployer. Settlement, release and forced
    /// close stay public functions on the hook's chain, so retiring the automation takes nothing from Zenith.
    function retire(address payable to) external {
        if (msg.sender != owner) revert NotOwner();
        SYSTEM.unsubscribe(block.chainid, LEGACY_SYSTEM, cronTopic, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
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
        if (target == address(0) || log.topic0 != cronTopic || log.contractAddress != LEGACY_SYSTEM) return;
        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: destinationChainId,
                recipient: target,
                gasLimit: CALLBACK_GAS_LIMIT,
                payload: abi.encodeCall(IZenithKeeper.tick, (address(0)))
            })
        );
    }
}
