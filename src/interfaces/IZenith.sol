// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice The parts of ZenithHook the Reactive contracts use. ZenithHook is compiled with 0.8.26 and the Reactive
/// contracts with 0.8.30, so they meet through these ABI-identical interfaces rather than imports.
interface IZenithHook {
    struct Score {
        uint128 held0;
        uint128 held1;
        uint128 inRange;
        uint128 startInRange;
        int256 indexLast;
        int256 excess;
        int256 lastExcess;
        uint64 lastCheckpoint;
        uint64 periodStart;
    }

    struct Range {
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    function PERIOD() external view returns (uint256);
    function sleeveCount() external view returns (uint256);
    function getScore(uint256 sleeveId) external view returns (Score memory);
    function getRanges(uint256 sleeveId) external view returns (Range[] memory);
}

/// @notice The parts of ZenithSettler the Reactive contracts use.
interface IZenithSettler {
    function hook() external view returns (address);
    function isBonded(uint256 sleeveId) external view returns (bool);
    function accounts(uint256 sleeveId)
        external
        view
        returns (
            uint256 bond,
            int256 cumulative,
            int256 highWater,
            int256 lowWater,
            uint256 feeOwed,
            uint256 pending,
            uint64 lastRelease,
            uint64 releaseEnd
        );
    function settle(uint256 sleeveId) external returns (int256 excess, uint256 feePaid, uint256 slashed);
    function release(uint256 sleeveId) external returns (uint256 released);
    function forceClose(uint256 sleeveId) external;
}

/// @notice ZenithKeeper, as seen from code compiled with 0.8.26 (tests and scripts).
interface IZenithKeeper {
    event Swept(uint256 visited, uint256 settled, uint256 released, uint256 closed);
    event ActionFailed(uint256 indexed sleeveId, bytes4 indexed action, bytes reason);

    function GAS_PER_SLEEVE() external view returns (uint256);
    function hook() external view returns (address);
    function settler() external view returns (address);
    function cursor() external view returns (uint256);
    function tick(address reactive) external;
    function sweep() external;
    function coverDebt() external;
}

/// @notice ZenithReactive, as seen from code compiled with 0.8.26 (tests and scripts).
interface IZenithReactive {
    /// @dev Same layout as reactive-lib-omni's IReactive.LogRecord.
    struct LogRecord {
        uint256 chainId;
        address contractAddress;
        uint256 topic0;
        uint256 topic1;
        uint256 topic2;
        uint256 topic3;
        bytes data;
        uint256 blockNumber;
        uint256 opCode;
        uint256 blockHash;
        uint256 txHash;
        uint256 logIndex;
    }

    function CALLBACK_GAS_LIMIT() external view returns (uint64);
    function LEGACY_SYSTEM() external view returns (address);
    function owner() external view returns (address);
    function destinationChainId() external view returns (uint256);
    function keeper() external view returns (address);
    function cronTopic() external view returns (uint256);
    function setKeeper(address keeper) external;
    function retire(address payable to) external;
    function react(LogRecord calldata log) external;
    function coverDebt() external;
}
