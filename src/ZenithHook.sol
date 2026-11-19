// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title ZenithHook
/// @notice Curated liquidity for one Uniswap v4 pool. Capital is split into sleeves: sleeve 0 is a passive
/// control that no one manages, and every other sleeve belongs to one curator. Curators never hold funds;
/// the hook holds everything and only executes what curators instruct.
/// @dev Idle sleeve balances never leave the PoolManager. They are held as ERC-6909 claims owned by this hook,
/// and the per-sleeve ledger must always sum to the hook's claim balance for each currency.
contract ZenithHook is BaseHook, IUnlockCallback {
    using CurrencySettler for Currency;

    /// @notice The passive control sleeve. It is opened when the pool is initialised and has no curator.
    uint256 public constant CONTROL_SLEEVE = 0;

    /// @notice Maximum number of sleeves, including the control. Kept small so per-swap scoring stays affordable.
    uint256 public constant MAX_SLEEVES = 8;

    struct Sleeve {
        address curator; // address(0) for the control sleeve
        uint128 idle0; // token0 held for this sleeve as ERC-6909 claims
        uint128 idle1; // token1 held for this sleeve as ERC-6909 claims
        bool exists;
    }

    enum Action {
        Fund
    }

    /// @notice The only address allowed to initialise the pool this hook serves.
    address public immutable deployer;

    PoolKey public poolKey;
    bool public poolBound;
    uint256 public sleeveCount;
    mapping(uint256 sleeveId => Sleeve) internal _sleeves;

    event PoolBound(PoolId indexed poolId);
    event SleeveOpened(uint256 indexed sleeveId, address indexed curator);
    event SleeveFunded(uint256 indexed sleeveId, address indexed funder, uint256 amount0, uint256 amount1);

    error NotDeployer();
    error PoolAlreadyBound();
    error PoolNotBound();
    error NativeCurrencyUnsupported();
    error ZeroCurator();
    error TooManySleeves();
    error UnknownSleeve();
    error UnknownAction();

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {
        deployer = msg.sender;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory permissions) {
        permissions.beforeInitialize = true;
    }

    // ------------------------------------------------------------------
    // Pool binding
    // ------------------------------------------------------------------

    /// @dev Binds the hook to the first pool initialised by the deployer and opens the control sleeve.
    /// Restricting initialisation stops anyone else from claiming the hook with a pool of hostile tokens.
    function _beforeInitialize(address sender, PoolKey calldata key, uint160) internal override returns (bytes4) {
        if (sender != deployer) revert NotDeployer();
        if (poolBound) revert PoolAlreadyBound();
        if (key.currency0.isAddressZero()) revert NativeCurrencyUnsupported();

        poolKey = key;
        poolBound = true;
        _sleeves[CONTROL_SLEEVE] = Sleeve({curator: address(0), idle0: 0, idle1: 0, exists: true});
        sleeveCount = 1;

        emit PoolBound(key.toId());
        emit SleeveOpened(CONTROL_SLEEVE, address(0));
        return this.beforeInitialize.selector;
    }

    // ------------------------------------------------------------------
    // Sleeves
    // ------------------------------------------------------------------

    /// @notice Opens a new sleeve managed by `curator`.
    function openSleeve(address curator) external returns (uint256 sleeveId) {
        if (!poolBound) revert PoolNotBound();
        if (curator == address(0)) revert ZeroCurator();
        if (sleeveCount >= MAX_SLEEVES) revert TooManySleeves();

        sleeveId = sleeveCount++;
        _sleeves[sleeveId] = Sleeve({curator: curator, idle0: 0, idle1: 0, exists: true});
        emit SleeveOpened(sleeveId, curator);
    }

    /// @notice Adds tokens to a sleeve's idle balance. Tokens are pulled from the caller into the PoolManager
    /// and held there as ERC-6909 claims owned by this hook.
    /// @dev Depositor shares are not tracked yet; funding is a sleeve-level credit for now.
    function fund(uint256 sleeveId, uint128 amount0, uint128 amount1) external {
        if (!_sleeves[sleeveId].exists) revert UnknownSleeve();
        poolManager.unlock(abi.encode(Action.Fund, abi.encode(msg.sender, sleeveId, amount0, amount1)));
    }

    function getSleeve(uint256 sleeveId) external view returns (Sleeve memory) {
        if (!_sleeves[sleeveId].exists) revert UnknownSleeve();
        return _sleeves[sleeveId];
    }

    /// @notice Sum of idle balances across all sleeves. Must equal this hook's ERC-6909 claims for each currency.
    function totalIdle() public view returns (uint256 total0, uint256 total1) {
        for (uint256 i; i < sleeveCount; ++i) {
            total0 += _sleeves[i].idle0;
            total1 += _sleeves[i].idle1;
        }
    }

    // ------------------------------------------------------------------
    // PoolManager callback
    // ------------------------------------------------------------------

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (Action action, bytes memory payload) = abi.decode(data, (Action, bytes));
        if (action == Action.Fund) {
            (address funder, uint256 sleeveId, uint128 amount0, uint128 amount1) =
                abi.decode(payload, (address, uint256, uint128, uint128));
            _fund(funder, sleeveId, amount0, amount1);
            return "";
        }
        revert UnknownAction();
    }

    function _fund(address funder, uint256 sleeveId, uint128 amount0, uint128 amount1) internal {
        PoolKey memory key = poolKey;

        // Pay the tokens in from the funder, then take the same amount back as claims for the hook.
        key.currency0.settle(poolManager, funder, amount0, false);
        key.currency0.take(poolManager, address(this), amount0, true);
        key.currency1.settle(poolManager, funder, amount1, false);
        key.currency1.take(poolManager, address(this), amount1, true);

        Sleeve storage sleeve = _sleeves[sleeveId];
        sleeve.idle0 += amount0;
        sleeve.idle1 += amount1;
        emit SleeveFunded(sleeveId, funder, amount0, amount1);
    }
}
