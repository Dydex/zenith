// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {ZenithMath} from "./ZenithMath.sol";

/// @notice What the hook needs from its settler: whether a sleeve's curator has posted enough bond to manage it.
interface IZenithBond {
    function isBonded(uint256 sleeveId) external view returns (bool);
}

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
    uint256 public constant MAX_SLEEVES = 4;

    /// @notice Maximum number of price ranges in one sleeve's shape.
    uint256 public constant MAX_RANGES = 4;

    /// @notice Length of a scoring period. A curator's excess is measured against its liquidity at period start.
    uint256 public constant PERIOD = 7 days;

    /// @notice Liquidity is only added while the pool's price is within this many ticks of the block's opening
    /// price, so nobody can push the price, add a sleeve's liquidity at it and push it back through that liquidity.
    int24 internal constant MAX_PRICE_MOVE = 30;

    /// @dev Fixed-point scale of the control index (skill per unit of liquidity).
    int256 internal constant INDEX_SCALE = 1e18;

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

    /// @notice Scoring state of one sleeve. All values are in token1.
    /// @dev excess = actual skill - (in-range liquidity at period start x the control's skill per unit of
    /// liquidity) - (liquidity added since period start x the control's long-run average per second). A curator
    /// who never changes its liquidity scores zero, however concentrated, and so does an idle one.
    struct Score {
        uint128 held0; // token0 held at the last checkpoint (idle, collected fees and positions)
        uint128 held1; // token1 held at the last checkpoint
        uint128 inRange; // in-range liquidity right after the last checkpoint
        uint128 startInRange; // in-range liquidity at the start of the current period
        int256 indexLast; // control index at the last checkpoint
        int256 excess; // excess skill in the current period
        int256 lastExcess; // excess skill of the last closed period
        uint64 lastCheckpoint;
        uint64 periodStart; // zero until the sleeve's first shape
    }

    /// @notice The pool's price at the start of a block, taken before that block's first swap.
    struct BlockOpen {
        uint160 sqrtPriceX96;
        int24 tick;
        uint64 blockNumber;
    }

    enum Action {
        Fund,
        SetShape,
        Poke,
        DeployControl,
        RollPeriod,
        Withdraw,
        Settle
    }

    /// @notice The only address allowed to initialise the pool this hook serves. It is passed in explicitly:
    /// hooks are deployed through a CREATE2 factory to mine their address, so msg.sender would be the factory.
    address public immutable initializer;

    PoolKey public poolKey;
    bool public poolBound;
    uint256 public sleeveCount;
    mapping(uint256 sleeveId => Sleeve) internal _sleeves;
    mapping(uint256 sleeveId => Range[]) internal _ranges;
    mapping(uint256 sleeveId => Score) internal _scores;

    /// @notice Depositor shares of each sleeve. A share is a claim on an exact fraction of everything the sleeve
    /// holds, idle tokens and positions alike.
    mapping(uint256 sleeveId => uint256) public totalShares;
    mapping(uint256 sleeveId => mapping(address owner => uint256)) public sharesOf;

    /// @notice Cumulative skill of the control per unit of liquidity, scaled by 1e18. Every curator is compared
    /// with this index.
    int256 public controlIndex;

    /// @notice When the control first had liquidity in range; the index's long-run average is taken from here.
    uint64 public controlIndexStart;

    /// @notice Holds curator bonds and settles each period. Once set, curators need a bond to shape, and only the
    /// settler closes periods, so no period's result can be skipped.
    address public settler;

    BlockOpen internal _open;

    event PoolBound(PoolId indexed poolId);
    event SleeveOpened(uint256 indexed sleeveId, address indexed curator);
    event SleeveFunded(
        uint256 indexed sleeveId, address indexed funder, uint256 amount0, uint256 amount1, uint256 shares
    );
    event Withdrawn(
        uint256 indexed sleeveId, address indexed owner, address to, uint256 shares, uint256 amount0, uint256 amount1
    );
    event ShapeSet(uint256 indexed sleeveId, uint256 rangeCount);
    event FeesCollected(uint256 indexed sleeveId, uint256 fees0, uint256 fees1);
    event Checkpointed(uint256 indexed sleeveId, int256 skill, int256 excess);
    event PeriodClosed(uint256 indexed sleeveId, int256 excess);

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
    error PeriodNotOver();
    error ZeroDeposit();
    error DepositExceedsMax();
    error InsufficientShares();
    error NotSettler();
    error SettlerAlreadySet();
    error NotBonded();
    error UnbackedCredit();
    error PriceMoved();

    constructor(IPoolManager _poolManager, address _initializer) BaseHook(_poolManager) {
        if (_initializer == address(0)) revert ZeroInitializer();
        initializer = _initializer;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory permissions) {
        permissions.beforeInitialize = true;
        permissions.beforeSwap = true;
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

    /// @dev Records the pool's price before the first swap of each block. It returns no delta and no fee
    /// override, so the pool prices and routes exactly as a hookless pool would.
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (_open.blockNumber != block.number) {
            (uint160 sqrtPriceX96, int24 tick,,) = poolManager.getSlot0(key.toId());
            _open = BlockOpen(sqrtPriceX96, tick, uint64(block.number));
        }
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @notice The pool's price at the start of the current block. Scores and bonds are valued at this price, so
    /// pushing the price inside a block (and pushing it back) cannot change them. Holding a pushed price across a
    /// block boundary leaves it open to arbitrage for a whole block.
    function blockOpenPrice() public view returns (uint160 sqrtPriceX96, int24 tick) {
        BlockOpen memory open = _open;
        if (open.blockNumber == block.number) return (open.sqrtPriceX96, open.tick);
        (sqrtPriceX96, tick,,) = poolManager.getSlot0(poolKey.toId());
    }

    /// @dev Reverts if the price has moved more than MAX_PRICE_MOVE ticks from the block's opening price. Removing
    /// liquidity is never restricted: liquidity that leaves at a pushed price has already sold high.
    function _requireSteadyPrice() internal view {
        (, int24 open) = blockOpenPrice();
        (, int24 tick,,) = poolManager.getSlot0(poolKey.toId());
        int24 moved = tick - open;
        if (moved > MAX_PRICE_MOVE || moved < -MAX_PRICE_MOVE) revert PriceMoved();
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

    /// @notice Deposits into a sleeve in kind and mints shares. After the first deposit, tokens are taken in the
    /// ratio the sleeve already holds, up to the amounts given, so a deposit buys an exact fraction of the sleeve
    /// at any price. Tokens move into the PoolManager and are held there as ERC-6909 claims owned by this hook.
    function fund(uint256 sleeveId, uint128 amount0Max, uint128 amount1Max)
        external
        returns (uint256 shares, uint128 amount0, uint128 amount1)
    {
        if (!_sleeves[sleeveId].exists) revert UnknownSleeve();
        bytes memory result =
            poolManager.unlock(abi.encode(Action.Fund, abi.encode(msg.sender, sleeveId, amount0Max, amount1Max)));
        (shares, amount0, amount1) = abi.decode(result, (uint256, uint128, uint128));
    }

    /// @notice Burns shares and sends the owner its fraction of the sleeve: of the idle tokens and of every
    /// position, which the hook removes itself. The curator is not involved.
    function withdraw(uint256 sleeveId, uint256 shares, address to)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        if (shares == 0 || sharesOf[sleeveId][msg.sender] < shares) {
            revert InsufficientShares();
        }
        bytes memory result =
            poolManager.unlock(abi.encode(Action.Withdraw, abi.encode(msg.sender, sleeveId, shares, to)));
        (amount0, amount1) = abi.decode(result, (uint256, uint256));
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
        if (settler != address(0) && !IZenithBond(settler).isBonded(sleeveId)) revert NotBonded();
        _validateShape(ranges);
        poolManager.unlock(abi.encode(Action.SetShape, abi.encode(sleeveId, ranges)));
    }

    /// @notice Collects a sleeve's fees into its idle balance and checkpoints its score. Anyone can call it.
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

    /// @notice Closes a sleeve's scoring period once it has lasted PERIOD, records its excess and starts the next
    /// period from the sleeve's current liquidity. Anyone can call it.
    function rollPeriod(uint256 sleeveId) external {
        if (settler != address(0) && msg.sender != settler) revert NotSettler();
        Score storage score = _scores[sleeveId];
        if (score.periodStart == 0 || block.timestamp < score.periodStart + PERIOD) revert PeriodNotOver();
        poolManager.unlock(abi.encode(Action.RollPeriod, abi.encode(sleeveId)));
    }

    /// @notice Sets the settler, once, by the initializer.
    function setSettler(address _settler) external {
        if (msg.sender != initializer) revert NotInitializer();
        if (settler != address(0)) revert SettlerAlreadySet();
        settler = _settler;
    }

    /// @notice The settler's only lever, applied at a checkpoint so none of it counts as skill. A positive amount
    /// credits token1 claims the settler has already transferred to the hook (a slashed bond) to the sleeve's
    /// depositors. A negative amount pays up to that much token1 from the sleeve to `to` (the curator's fee). Close
    /// removes all of the sleeve's liquidity.
    function settle(uint256 sleeveId, int256 amount1, address to, bool close) external returns (uint256 paid) {
        if (msg.sender != settler) revert NotSettler();
        bytes memory result = poolManager.unlock(abi.encode(Action.Settle, abi.encode(sleeveId, amount1, to, close)));
        paid = abi.decode(result, (uint256));
    }

    function getScore(uint256 sleeveId) external view returns (Score memory) {
        return _scores[sleeveId];
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
    function _totalIdle() internal view returns (uint256 total0, uint256 total1) {
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
            (address funder, uint256 sleeveId, uint128 amount0Max, uint128 amount1Max) =
                abi.decode(payload, (address, uint256, uint128, uint128));
            _checkpoint(sleeveId);
            return _fund(funder, sleeveId, amount0Max, amount1Max);
        } else if (action == Action.Withdraw) {
            (address owner, uint256 sleeveId, uint256 shares, address to) =
                abi.decode(payload, (address, uint256, uint256, address));
            _checkpoint(sleeveId);
            return _withdraw(owner, sleeveId, shares, to);
        } else if (action == Action.Settle) {
            (uint256 sleeveId, int256 amount1, address to, bool close) =
                abi.decode(payload, (uint256, int256, address, bool));
            _checkpoint(sleeveId);
            if (close) {
                _applyShape(sleeveId, new Range[](0));
                _afterShape(sleeveId);
            }
            return abi.encode(_transfer1(sleeveId, amount1, to));
        } else if (action == Action.SetShape) {
            (uint256 sleeveId, Range[] memory ranges) = abi.decode(payload, (uint256, Range[]));
            _checkpoint(sleeveId);
            _applyShape(sleeveId, ranges);
            _afterShape(sleeveId);
            emit ShapeSet(sleeveId, ranges.length);
        } else if (action == Action.Poke) {
            _checkpoint(abi.decode(payload, (uint256)));
        } else if (action == Action.DeployControl) {
            _checkpoint(CONTROL_SLEEVE);
            _deployControl();
            _afterShape(CONTROL_SLEEVE);
        } else if (action == Action.RollPeriod) {
            uint256 sleeveId = abi.decode(payload, (uint256));
            _checkpoint(sleeveId);
            Score storage score = _scores[sleeveId];
            score.lastExcess = score.excess;
            score.excess = 0;
            score.startInRange = score.inRange;
            score.periodStart = uint64(block.timestamp);
            emit PeriodClosed(sleeveId, score.lastExcess);
        } else {
            revert UnknownAction();
        }
        return "";
    }

    // ------------------------------------------------------------------
    // Internal: funding and shapes
    // ------------------------------------------------------------------

    function _fund(address funder, uint256 sleeveId, uint128 amount0Max, uint128 amount1Max)
        internal
        returns (bytes memory)
    {
        uint256 supply = totalShares[sleeveId];
        (uint256 shares, uint256 idle0, uint256 idle1, uint256 amount0, uint256 amount1) =
            _buyIn(sleeveId, supply, amount0Max, amount1Max);
        if (shares == 0) revert ZeroDeposit();

        // The funder pays for the idle part and the added liquidity; the idle part is kept as claims.
        PoolKey memory key = poolKey;
        key.currency0.settle(poolManager, funder, amount0, false);
        key.currency0.take(poolManager, address(this), idle0, true);
        key.currency1.settle(poolManager, funder, amount1, false);
        key.currency1.take(poolManager, address(this), idle1, true);
        Sleeve storage sleeve = _sleeves[sleeveId];
        sleeve.idle0 += idle0.toUint128();
        sleeve.idle1 += idle1.toUint128();

        totalShares[sleeveId] = supply + shares;
        sharesOf[sleeveId][funder] += shares;
        // New money is added after the checkpoint and the baseline grows with it, so it is never counted as skill.
        _rebase(sleeveId, supply + shares, supply);
        emit SleeveFunded(sleeveId, funder, amount0, amount1, shares);
        return abi.encode(shares, amount0, amount1);
    }

    /// @dev Sizes a deposit and adds its liquidity. Later deposits buy the same fraction of everything the sleeve
    /// holds: idle tokens and every position. Adding the liquidity, not just idle tokens, means a deposit cannot
    /// take a share of fees its money did not earn.
    function _buyIn(uint256 sleeveId, uint256 supply, uint256 max0, uint256 max1)
        internal
        returns (uint256 shares, uint256 idle0, uint256 idle1, uint256 amount0, uint256 amount1)
    {
        shares = _sharesFor(sleeveId, supply, max0, max1);
        if (supply == 0) return (shares, max0, max1, max0, max1);
        if (shares == 0) return (0, 0, 0, 0, 0);
        Sleeve storage sleeve = _sleeves[sleeveId];
        idle0 = FullMath.mulDivRoundingUp(sleeve.idle0, shares, supply);
        idle1 = FullMath.mulDivRoundingUp(sleeve.idle1, shares, supply);
        (int256 net0, int256 net1) = _scaleRanges(sleeveId, shares, supply, true);
        amount0 = idle0 + (-net0).toUint256();
        amount1 = idle1 + (-net1).toUint256();
        if (amount0 > max0 || amount1 > max1) revert DepositExceedsMax();
    }

    /// @dev The first deposit sets the ratio and its shares start at its value in token1. Later ones get shares in
    /// proportion to the sleeve's holdings at the current price. Position amounts are rounded down, so each is
    /// counted 1 wei higher, and adding liquidity rounds up by at most 2 wei per range, so the maxima are padded by
    /// that much. Together they keep the charge within what was offered; _buyIn still checks it.
    function _sharesFor(uint256 sleeveId, uint256 supply, uint256 max0, uint256 max1) internal view returns (uint256) {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolKey.toId());
        if (supply == 0) return _value(max0, max1, sqrtPriceX96);
        (uint256 held0, uint256 held1) = _holdings(sleeveId, sqrtPriceX96);
        uint256 n = _ranges[sleeveId].length;
        uint256 pad = 2 * n + 1;
        (uint256 shares,,) = ZenithMath.proportional(
            supply,
            held0 > 0 ? held0 + n : 0,
            held1 > 0 ? held1 + n : 0,
            max0 > pad ? max0 - pad : 0,
            max1 > pad ? max1 - pad : 0
        );
        return shares;
    }

    /// @dev Removes the owner's fraction of every position, adds the same fraction of idle tokens and sends both.
    function _withdraw(address owner, uint256 sleeveId, uint256 shares, address to) internal returns (bytes memory) {
        uint256 supply = totalShares[sleeveId];
        (int256 net0, int256 net1) = _scaleRanges(sleeveId, shares, supply, false);
        (uint256 amount0, uint256 amount1) = _payOut(sleeveId, shares, supply, net0, net1, to);

        totalShares[sleeveId] = supply - shares;
        sharesOf[sleeveId][owner] -= shares;
        _rebase(sleeveId, supply - shares, supply);
        emit Withdrawn(sleeveId, owner, to, shares, amount0, amount1);
        return abi.encode(amount0, amount1);
    }

    /// @dev After a deposit or withdrawal at a checkpoint: records what the sleeve now holds and scales the curator's
    /// baseline with the supply, so depositors arriving or leaving are never scored as the curator's timing.
    function _rebase(uint256 sleeveId, uint256 newSupply, uint256 oldSupply) internal {
        (uint160 sqrtPriceX96, int24 tick) = blockOpenPrice();
        (uint256 held0, uint256 held1) = _holdings(sleeveId, sqrtPriceX96);
        Score storage score = _scores[sleeveId];
        score.held0 = held0.toUint128();
        score.held1 = held1.toUint128();
        if (oldSupply > 0) score.startInRange = FullMath.mulDiv(score.startInRange, newSupply, oldSupply).toUint128();
        score.inRange = _inRangeLiquidity(sleeveId, tick);
    }

    /// @dev Adds or removes shares/supply of each position's liquidity, dropping ranges that reach zero.
    function _scaleRanges(uint256 sleeveId, uint256 shares, uint256 supply, bool add)
        internal
        returns (int256 net0, int256 net1)
    {
        PoolKey memory key = poolKey;
        bytes32 salt = sleeveSalt(sleeveId);
        Range[] storage ranges = _ranges[sleeveId];
        if (add && ranges.length > 0) _requireSteadyPrice();
        for (uint256 i = ranges.length; i > 0; --i) {
            Range storage r = ranges[i - 1];
            uint128 change = FullMath.mulDiv(r.liquidity, shares, supply).toUint128();
            if (change == 0) continue;
            (BalanceDelta delta,) = poolManager.modifyLiquidity(
                key,
                ModifyLiquidityParams({
                    tickLower: r.tickLower,
                    tickUpper: r.tickUpper,
                    liquidityDelta: add ? uint256(change).toInt256() : -uint256(change).toInt256(),
                    salt: salt
                }),
                ""
            );
            net0 += delta.amount0();
            net1 += delta.amount1();
            if (add) {
                r.liquidity += change;
            } else {
                r.liquidity -= change;
                if (r.liquidity == 0) {
                    ranges[i - 1] = ranges[ranges.length - 1];
                    ranges.pop();
                }
            }
        }
    }

    /// @dev Burns the owner's fraction of idle claims and sends it, with the tokens freed from positions, to `to`.
    function _payOut(uint256 sleeveId, uint256 shares, uint256 supply, int256 net0, int256 net1, address to)
        internal
        returns (uint256 amount0, uint256 amount1)
    {
        PoolKey memory key = poolKey;
        Sleeve storage sleeve = _sleeves[sleeveId];
        uint256 idle0 = FullMath.mulDiv(sleeve.idle0, shares, supply);
        uint256 idle1 = FullMath.mulDiv(sleeve.idle1, shares, supply);
        sleeve.idle0 -= idle0.toUint128();
        sleeve.idle1 -= idle1.toUint128();
        key.currency0.settle(poolManager, address(this), idle0, true);
        key.currency1.settle(poolManager, address(this), idle1, true);
        amount0 = idle0 + net0.toUint256();
        amount1 = idle1 + net1.toUint256();
        key.currency0.take(poolManager, to, amount0, false);
        key.currency1.take(poolManager, to, amount1, false);
    }

    /// @dev Moves token1 into or out of a sleeve at a checkpoint, adjusting what the score holds so it is not skill.
    function _transfer1(uint256 sleeveId, int256 amount1, address to) internal returns (uint256 moved) {
        Sleeve storage sleeve = _sleeves[sleeveId];
        Score storage score = _scores[sleeveId];
        Currency currency1 = poolKey.currency1;
        if (amount1 > 0) {
            moved = amount1.toUint256();
            (, uint256 total1) = _totalIdle();
            if (poolManager.balanceOf(address(this), currency1.toId()) < total1 + moved) revert UnbackedCredit();
            sleeve.idle1 += moved.toUint128();
            score.held1 += moved.toUint128();
        } else if (amount1 < 0) {
            moved = _min((-amount1).toUint256(), sleeve.idle1);
            sleeve.idle1 -= moved.toUint128();
            score.held1 -= moved.toUint128();
            currency1.settle(poolManager, address(this), moved, true);
            currency1.take(poolManager, to, moved, false);
        }
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
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

        if (next.length > 0) _requireSteadyPrice();
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
        Sleeve storage control = _sleeves[CONTROL_SLEEVE];
        (int24 lower, int24 upper, uint128 liquidity) =
            ZenithMath.fullRange(key.tickSpacing, sqrtPriceX96, control.idle0, control.idle1);
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

    // ------------------------------------------------------------------
    // Internal: scoring
    // ------------------------------------------------------------------

    /// @dev Values every sleeve at the block-open price, the control first. Each curator is therefore compared with
    /// the control over exactly the same intervals: a checkpoint that only the control took would let a price
    /// excursion count against the control and not against the curator. Only the control and the sleeve being acted
    /// on collect their fees; another sleeve's fees count when that sleeve next collects them. Runs before anything
    /// that changes what a sleeve holds or how its liquidity is placed.
    function _checkpoint(uint256 sleeveId) internal {
        (uint160 sqrtPriceX96, int24 tick) = blockOpenPrice();
        uint256 count = sleeveCount;
        for (uint256 id; id < count; ++id) {
            _accrue(id, sqrtPriceX96, tick, id == CONTROL_SLEEVE || id == sleeveId);
        }
    }

    function _accrue(uint256 sleeveId, uint160 sqrtPriceX96, int24 tick, bool collect) internal {
        if (collect) _poke(sleeveId);
        Score storage score = _scores[sleeveId];
        (uint256 held0, uint256 held1) = _holdings(sleeveId, sqrtPriceX96);

        if (score.lastCheckpoint != 0) {
            // Skill: what the sleeve holds now, minus what its previous holdings are worth at today's price.
            int256 skill = _value(held0, held1, sqrtPriceX96).toInt256()
                - _value(score.held0, score.held1, sqrtPriceX96).toInt256();
            if (sleeveId == CONTROL_SLEEVE) {
                if (score.inRange > 0) controlIndex += skill * INDEX_SCALE / uint256(score.inRange).toInt256();
            } else if (score.periodStart != 0) {
                int256 start = uint256(score.startInRange).toInt256();
                int256 expected = start * (controlIndex - score.indexLast) / INDEX_SCALE;
                int256 drift = _drift(uint256(score.inRange).toInt256() - start, block.timestamp - score.lastCheckpoint);
                score.excess += skill - expected - drift;
                emit Checkpointed(sleeveId, skill, score.excess);
            }
        }

        score.held0 = held0.toUint128();
        score.held1 = held1.toUint128();
        score.indexLast = controlIndex;
        score.lastCheckpoint = uint64(block.timestamp);
        score.inRange = _inRangeLiquidity(sleeveId, tick);
    }

    /// @dev Liquidity added since period start earns the control's long-run average outcome per second for free,
    /// so that much is not counted as skill.
    function _drift(int256 addedLiquidity, uint256 elapsed) internal view returns (int256) {
        if (addedLiquidity == 0 || elapsed == 0 || controlIndexStart == 0) return 0;
        uint256 history = block.timestamp - controlIndexStart;
        if (history == 0) return 0;
        return controlIndex * addedLiquidity / INDEX_SCALE * elapsed.toInt256() / history.toInt256();
    }

    /// @dev After a shape changes, records the new in-range liquidity. A curator's first shape starts its period.
    /// What the sleeve holds is deliberately not re-recorded: tokens moved at a price that differs from the
    /// block-open price show up at the next checkpoint as a real gain or loss, which is what they are.
    function _afterShape(uint256 sleeveId) internal {
        (, int24 tick) = blockOpenPrice();
        Score storage score = _scores[sleeveId];
        score.inRange = _inRangeLiquidity(sleeveId, tick);
        if (sleeveId == CONTROL_SLEEVE) {
            if (controlIndexStart == 0 && score.inRange > 0) controlIndexStart = uint64(block.timestamp);
        } else if (score.periodStart == 0) {
            score.periodStart = uint64(block.timestamp);
            score.startInRange = score.inRange;
        }
    }

    /// @dev Idle balance plus the tokens in every position at the given price.
    function _holdings(uint256 sleeveId, uint160 sqrtPriceX96)
        internal
        view
        returns (uint256 amount0, uint256 amount1)
    {
        Sleeve storage sleeve = _sleeves[sleeveId];
        amount0 = sleeve.idle0;
        amount1 = sleeve.idle1;
        Range[] storage ranges = _ranges[sleeveId];
        for (uint256 i; i < ranges.length; ++i) {
            (uint256 in0, uint256 in1) =
                ZenithMath.amounts(ranges[i].tickLower, ranges[i].tickUpper, ranges[i].liquidity, sqrtPriceX96);
            amount0 += in0;
            amount1 += in1;
        }
    }

    function _inRangeLiquidity(uint256 sleeveId, int24 tick) internal view returns (uint128 liquidity) {
        Range[] storage ranges = _ranges[sleeveId];
        for (uint256 i; i < ranges.length; ++i) {
            if (ranges[i].tickLower <= tick && tick < ranges[i].tickUpper) liquidity += ranges[i].liquidity;
        }
    }

    /// @dev Value in token1 at the given price.
    function _value(uint256 amount0, uint256 amount1, uint160 sqrtPriceX96) internal pure returns (uint256) {
        return ZenithMath.value(amount0, amount1, sqrtPriceX96);
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
