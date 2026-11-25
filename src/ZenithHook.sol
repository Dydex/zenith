// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

/// @title ZenithHook
/// @notice Curated liquidity for one Uniswap v4 pool. Capital is split into sleeves: sleeve 0 is a passive
/// control that no one manages, and every other sleeve belongs to one curator. Curators never hold funds;
/// the hook holds everything and only executes the liquidity shapes curators post.
/// @dev Idle sleeve balances never leave the PoolManager. They are held as ERC-6909 claims owned by this hook,
/// and the per-sleeve ledger must always sum to the hook's claim balance for each currency. Each sleeve's
/// positions use the sleeve id as their salt, so Uniswap keeps every sleeve's fee accounting separate.
contract ZenithHook is BaseHook, IUnlockCallback {
    using CurrencySettler for Currency;
    using StateLibrary for IPoolManager;
    using SafeCast for uint256;
    using SafeCast for int256;

    /// @notice The passive control sleeve. It is opened when the pool is initialised and has no curator.
    uint256 public constant CONTROL_SLEEVE = 0;

    /// @notice Maximum number of sleeves, including the control. Kept small so per-swap scoring stays affordable.
    uint256 public constant MAX_SLEEVES = 8;

    /// @notice Maximum number of price ranges in one sleeve's shape.
    uint256 public constant MAX_RANGES = 4;

    struct Sleeve {
        address curator; // address(0) for the control sleeve
        uint128 idle0; // token0 held for this sleeve as ERC-6909 claims
        uint128 idle1; // token1 held for this sleeve as ERC-6909 claims
        uint128 fees0; // cumulative token0 fees collected by this sleeve's positions
        uint128 fees1; // cumulative token1 fees collected by this sleeve's positions
        bool exists;
    }

    /// @notice One position in a sleeve's shape.
    struct Range {
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    enum Action {
        Fund,
        SetShape,
        Poke,
        DeployControl
    }

    /// @notice The only address allowed to initialise the pool this hook serves. It is passed in explicitly:
    /// hooks are deployed through a CREATE2 factory to mine their address, so msg.sender would be the factory.
    address public immutable initializer;

    PoolKey public poolKey;
    bool public poolBound;
    uint256 public sleeveCount;
    mapping(uint256 sleeveId => Sleeve) internal _sleeves;
    mapping(uint256 sleeveId => Range[]) internal _ranges;

    event PoolBound(PoolId indexed poolId);
    event SleeveOpened(uint256 indexed sleeveId, address indexed curator);
    event SleeveFunded(uint256 indexed sleeveId, address indexed funder, uint256 amount0, uint256 amount1);
    event ShapeSet(uint256 indexed sleeveId, uint256 rangeCount);
    event FeesCollected(uint256 indexed sleeveId, uint256 fees0, uint256 fees1);

    error NotInitializer();
    error ZeroInitializer();
    error PoolAlreadyBound();
    error PoolNotBound();
    error NativeCurrencyUnsupported();
    error ZeroCurator();
    error TooManySleeves();
    error UnknownSleeve();
    error UnknownAction();
    error NotCurator();
    error ControlIsPassive();
    error TooManyRanges();
    error InvalidRange(uint256 index);
    error DuplicateRange(uint256 index);
    error InsufficientIdle();

    constructor(IPoolManager _poolManager, address _initializer) BaseHook(_poolManager) {
        if (_initializer == address(0)) revert ZeroInitializer();
        initializer = _initializer;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory permissions) {
        permissions.beforeInitialize = true;
    }

    // ------------------------------------------------------------------
    // Pool binding
    // ------------------------------------------------------------------

    /// @dev Binds the hook to the first pool initialised by the initializer and opens the control sleeve.
    /// Restricting initialisation stops anyone else from claiming the hook with a pool of hostile tokens.
    function _beforeInitialize(address sender, PoolKey calldata key, uint160) internal override returns (bytes4) {
        if (sender != initializer) revert NotInitializer();
        if (poolBound) revert PoolAlreadyBound();
        if (key.currency0.isAddressZero()) revert NativeCurrencyUnsupported();

        poolKey = key;
        poolBound = true;
        _sleeves[CONTROL_SLEEVE].exists = true;
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
        Sleeve storage sleeve = _sleeves[sleeveId];
        sleeve.curator = curator;
        sleeve.exists = true;
        emit SleeveOpened(sleeveId, curator);
    }

    /// @notice Adds tokens to a sleeve's idle balance. Tokens are pulled from the caller into the PoolManager
    /// and held there as ERC-6909 claims owned by this hook.
    /// @dev Depositor shares are not tracked yet; funding is a sleeve-level credit for now.
    function fund(uint256 sleeveId, uint128 amount0, uint128 amount1) external {
        if (!_sleeves[sleeveId].exists) revert UnknownSleeve();
        poolManager.unlock(abi.encode(Action.Fund, abi.encode(msg.sender, sleeveId, amount0, amount1)));
    }

    /// @notice Replaces a sleeve's liquidity shape. Only the sleeve's curator can call this, and the hook
    /// executes it: old positions are removed (collecting their fees), new ones are added, and the net token
    /// difference is settled against the sleeve's idle balance.
    /// @param ranges The new shape. An empty array withdraws all of the sleeve's liquidity to idle.
    function setShape(uint256 sleeveId, Range[] calldata ranges) external {
        if (sleeveId == CONTROL_SLEEVE) revert ControlIsPassive();
        Sleeve storage sleeve = _sleeves[sleeveId];
        if (!sleeve.exists) revert UnknownSleeve();
        if (msg.sender != sleeve.curator) revert NotCurator();
        _validateShape(ranges);
        poolManager.unlock(abi.encode(Action.SetShape, abi.encode(sleeveId, ranges)));
    }

    /// @notice Collects fees accrued by a sleeve's positions into its idle balance. Anyone can call it.
    function poke(uint256 sleeveId) external {
        if (!_sleeves[sleeveId].exists) revert UnknownSleeve();
        poolManager.unlock(abi.encode(Action.Poke, abi.encode(sleeveId)));
    }

    /// @notice Puts all of the control sleeve's funds into one full-range position. Anyone can call it,
    /// because no one manages the control.
    function deployControl() external {
        if (!poolBound) revert PoolNotBound();
        poolManager.unlock(abi.encode(Action.DeployControl, ""));
    }

    function getSleeve(uint256 sleeveId) external view returns (Sleeve memory) {
        if (!_sleeves[sleeveId].exists) revert UnknownSleeve();
        return _sleeves[sleeveId];
    }

    function getRanges(uint256 sleeveId) external view returns (Range[] memory) {
        return _ranges[sleeveId];
    }

    /// @notice The position salt used for a sleeve. A sleeve's positions are keyed (hook, ticks, salt).
    function sleeveSalt(uint256 sleeveId) public pure returns (bytes32) {
        return bytes32(sleeveId);
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
        } else if (action == Action.SetShape) {
            (uint256 sleeveId, Range[] memory ranges) = abi.decode(payload, (uint256, Range[]));
            _applyShape(sleeveId, ranges);
            emit ShapeSet(sleeveId, ranges.length);
        } else if (action == Action.Poke) {
            _poke(abi.decode(payload, (uint256)));
        } else if (action == Action.DeployControl) {
            _deployControl();
        } else {
            revert UnknownAction();
        }
        return "";
    }

    // ------------------------------------------------------------------
    // Internal: funding and shapes
    // ------------------------------------------------------------------

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

    /// @dev Removes every current position of the sleeve, adds the new ranges, then settles the net
    /// difference against the sleeve's idle claims. All of it happens inside one unlock.
    function _applyShape(uint256 sleeveId, Range[] memory next) internal {
        PoolKey memory key = poolKey;
        bytes32 salt = sleeveSalt(sleeveId);
        int256 net0;
        int256 net1;
        uint256 fees0;
        uint256 fees1;

        Range[] storage current = _ranges[sleeveId];
        for (uint256 i; i < current.length; ++i) {
            (BalanceDelta delta, BalanceDelta fees) = poolManager.modifyLiquidity(
                key,
                ModifyLiquidityParams({
                    tickLower: current[i].tickLower,
                    tickUpper: current[i].tickUpper,
                    liquidityDelta: -uint256(current[i].liquidity).toInt256(),
                    salt: salt
                }),
                ""
            );
            net0 += delta.amount0();
            net1 += delta.amount1();
            fees0 += int256(fees.amount0()).toUint256();
            fees1 += int256(fees.amount1()).toUint256();
        }
        delete _ranges[sleeveId];

        for (uint256 i; i < next.length; ++i) {
            (BalanceDelta delta,) = poolManager.modifyLiquidity(
                key,
                ModifyLiquidityParams({
                    tickLower: next[i].tickLower,
                    tickUpper: next[i].tickUpper,
                    liquidityDelta: uint256(next[i].liquidity).toInt256(),
                    salt: salt
                }),
                ""
            );
            net0 += delta.amount0();
            net1 += delta.amount1();
            _ranges[sleeveId].push(next[i]);
        }

        _settleNet(key, sleeveId, net0, net1, fees0, fees1);
    }

    /// @dev Collects fees on every position of the sleeve by modifying each by zero liquidity.
    function _poke(uint256 sleeveId) internal {
        PoolKey memory key = poolKey;
        bytes32 salt = sleeveSalt(sleeveId);
        int256 net0;
        int256 net1;
        uint256 fees0;
        uint256 fees1;

        Range[] storage current = _ranges[sleeveId];
        for (uint256 i; i < current.length; ++i) {
            (BalanceDelta delta, BalanceDelta fees) = poolManager.modifyLiquidity(
                key,
                ModifyLiquidityParams({
                    tickLower: current[i].tickLower, tickUpper: current[i].tickUpper, liquidityDelta: 0, salt: salt
                }),
                ""
            );
            net0 += delta.amount0();
            net1 += delta.amount1();
            fees0 += int256(fees.amount0()).toUint256();
            fees1 += int256(fees.amount1()).toUint256();
        }

        _settleNet(key, sleeveId, net0, net1, fees0, fees1);
    }

    /// @dev Withdraws the control's liquidity to idle (collecting its fees), then redeploys everything idle
    /// as a single full-range position at the current price.
    function _deployControl() internal {
        _applyShape(CONTROL_SLEEVE, new Range[](0));

        PoolKey memory key = poolKey;
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        int24 lower = TickMath.minUsableTick(key.tickSpacing);
        int24 upper = TickMath.maxUsableTick(key.tickSpacing);

        Sleeve storage control = _sleeves[CONTROL_SLEEVE];
        // Leave one wei of margin: adding liquidity rounds the required amounts up.
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(lower),
            TickMath.getSqrtPriceAtTick(upper),
            control.idle0 > 0 ? control.idle0 - 1 : 0,
            control.idle1 > 0 ? control.idle1 - 1 : 0
        );
        if (liquidity == 0) return;

        Range[] memory shape = new Range[](1);
        shape[0] = Range({tickLower: lower, tickUpper: upper, liquidity: liquidity});
        _applyShape(CONTROL_SLEEVE, shape);
        emit ShapeSet(CONTROL_SLEEVE, 1);
    }

    /// @dev Turns the sleeve's net delta into claims: a surplus is minted to the hook as claims, a shortfall is
    /// paid by burning the sleeve's idle claims. Reverts if the sleeve does not hold enough.
    function _settleNet(PoolKey memory key, uint256 sleeveId, int256 net0, int256 net1, uint256 fees0, uint256 fees1)
        internal
    {
        Sleeve storage sleeve = _sleeves[sleeveId];
        sleeve.idle0 = _settleCurrency(key.currency0, sleeve.idle0, net0);
        sleeve.idle1 = _settleCurrency(key.currency1, sleeve.idle1, net1);
        if (fees0 > 0 || fees1 > 0) {
            sleeve.fees0 += fees0.toUint128();
            sleeve.fees1 += fees1.toUint128();
            emit FeesCollected(sleeveId, fees0, fees1);
        }
    }

    function _settleCurrency(Currency currency, uint128 idle, int256 net) internal returns (uint128) {
        if (net > 0) {
            uint256 received = net.toUint256();
            currency.take(poolManager, address(this), received, true);
            return (uint256(idle) + received).toUint128();
        }
        if (net < 0) {
            uint256 owed = (-net).toUint256();
            if (owed > idle) revert InsufficientIdle();
            currency.settle(poolManager, address(this), owed, true);
            return (uint256(idle) - owed).toUint128();
        }
        return idle;
    }

    function _validateShape(Range[] calldata ranges) internal view {
        if (ranges.length > MAX_RANGES) revert TooManyRanges();
        int24 spacing = poolKey.tickSpacing;
        int24 minTick = TickMath.minUsableTick(spacing);
        int24 maxTick = TickMath.maxUsableTick(spacing);
        for (uint256 i; i < ranges.length; ++i) {
            Range calldata r = ranges[i];
            if (
                r.liquidity == 0 || r.tickLower >= r.tickUpper || r.tickLower < minTick || r.tickUpper > maxTick
                    || r.tickLower % spacing != 0 || r.tickUpper % spacing != 0
            ) revert InvalidRange(i);
            for (uint256 j; j < i; ++j) {
                if (ranges[j].tickLower == r.tickLower && ranges[j].tickUpper == r.tickUpper) {
                    revert DuplicateRange(i);
                }
            }
        }
    }
}
