// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "../vendor/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "../vendor/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "../vendor/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "../vendor/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "../vendor/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "../vendor/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "../vendor/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "../vendor/v4-core/src/types/BalanceDelta.sol";
import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary,
    toBeforeSwapDelta
} from "../vendor/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "../vendor/v4-core/src/types/PoolOperation.sol";

/// @title SNEWTHook — opening-fee and standing-fee hook for the Newton Swarm (SNEWT) / IMD pool
/// @notice Uniswap v4 hook for the single launch pool of SNEWT paired with IMD. On every swap it
///         takes a fee in the paired currency (IMD), on top of the pool's static 1.25% LP fee:
///
///         - for the first 60 minutes after the pool is initialized the fee starts at 40.00% and
///           decreases linearly with `block.timestamp` to 3.00%;
///         - afterwards it stays at 3.00% forever.
///
///         The fee is always proportional to what actually filled: it is `feeNow()` basis points
///         of the IMD that moved through the pool in that swap. It accrues inside the hook as an
///         ERC-6909 claim on the PoolManager, and `sweep()`, callable by anyone, delivers the whole
///         balance to the fixed treasury.
///
/// @dev Fee mechanics per swap direction (IMD is the "paired" currency, SNEWT the "token"):
///
///      | swap               | specified side | where the fee is taken                             |
///      | ------------------ | -------------- | -------------------------------------------------- |
///      | buy,  exact input  | IMD (input)    | reserved in beforeSwap, reconciled in afterSwap    |
///      | buy,  exact output | SNEWT (output) | afterSwap return delta on the unspecified IMD side |
///      | sell, exact input  | SNEWT (input)  | afterSwap return delta on the unspecified IMD side |
///      | sell, exact output | IMD (output)   | reserved in beforeSwap, reconciled in afterSwap    |
///
///      When the fee had to be reserved on the specified side, beforeSwap sizes it for a full
///      fill. afterSwap then scales it down by the fraction that actually filled and refunds the
///      excess as an ERC-6909 claim. Routers can pass `abi.encode(refundRecipient)` as hookData
///      to credit the swapper directly; otherwise the claim goes to the PoolManager's caller
///      (usually the router). The fee bound includes this claim and integer rounding dust.
///      Exact-output sells can require IMD settlement when the reservation exceeds the fill.
///
///      No owner, no setters, no proxy, no delegatecall, no selfdestruct. Every parameter is a
///      compile-time constant or an immutable fixed at construction.
contract SNEWTHook is IHooks, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;
    using Hooks for IHooks;

    // ---------------------------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------------------------

    /// @notice Fee at the moment the pool is initialized, in basis points (40.00%).
    uint256 public constant OPENING_FEE_BPS = 4000;
    /// @notice Fee once the opening window has elapsed, in basis points (3.00%).
    uint256 public constant STANDING_FEE_BPS = 300;
    /// @notice Length of the linear decay from the opening fee to the standing fee.
    uint256 public constant DECAY_SECONDS = 60 minutes;
    /// @notice Basis-point denominator.
    uint256 public constant BPS = 10_000;

    /// @notice The static LP fee of the launch pool (1.25%). The hook fee comes on top of it.
    uint24 public constant POOL_FEE = 12_500;
    /// @notice The tick spacing of the launch pool.
    int24 public constant POOL_TICK_SPACING = 60;

    /// @notice Receives every swept fee. Fixed at construction, no setter.
    address public constant TREASURY = 0x5F948c351EB9F0734C28B605BbeEe9AB9d04318E;

    // ---------------------------------------------------------------------------------------
    // Immutables
    // ---------------------------------------------------------------------------------------

    /// @notice The Uniswap v4 PoolManager this hook serves.
    IPoolManager public immutable poolManager;
    /// @notice The launch token (SNEWT). The launch pool must contain it.
    address public immutable token;

    // ---------------------------------------------------------------------------------------
    // State (written once at initialization, then only by fee accounting)
    // ---------------------------------------------------------------------------------------

    /// @notice The currency the launch token is paired with (IMD); the fee currency.
    Currency public paired;
    /// @notice Id of the single pool this hook serves.
    PoolId public poolId;

    uint256 private _openedAt;
    uint256 private _collected;
    uint256 private _swept;

    // ---------------------------------------------------------------------------------------
    // Events and errors
    // ---------------------------------------------------------------------------------------

    event PoolOpened(PoolId indexed id, Currency indexed paired, uint256 openedAt);
    event FeeTaken(address indexed sender, bool isBuy, uint256 feeBps, uint256 fee, uint256 refund);
    event Swept(address indexed caller, address indexed treasury, uint256 amount);

    error NotPoolManager();
    error ZeroAddress();
    error AlreadyOpened();
    error NotLaunchPool();
    error UnrepresentableFee();
    error NothingToSweep();
    error HookNotImplemented();

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    /// @param manager The chain's Uniswap v4 PoolManager ("$poolManager" in the manifest).
    /// @param launchToken The SNEWT token ("$token" in the manifest).
    /// @dev Makes no external call: the launch checks run constructors on an empty chain.
    constructor(IPoolManager manager, address launchToken) {
        if (address(manager) == address(0) || launchToken == address(0)) revert ZeroAddress();
        poolManager = manager;
        token = launchToken;
        // Reverts unless this address carries exactly the flags getHookPermissions declares.
        IHooks(this).validateHookPermissions(getHookPermissions());
    }

    // ---------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------

    /// @notice Permissions the mined address must carry.
    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice Timestamp at which the launch pool was initialized; 0 until then.
    function openedAt() external view returns (uint256) {
        return _openedAt;
    }

    /// @notice The hook fee that applies to a swap in the current block, in basis points.
    /// @dev Returns the opening fee until the pool is initialized (no swap can happen before).
    function feeNow() public view returns (uint256) {
        uint256 opened = _openedAt;
        if (opened == 0) return OPENING_FEE_BPS;
        uint256 elapsed = block.timestamp - opened;
        if (elapsed >= DECAY_SECONDS) return STANDING_FEE_BPS;
        return OPENING_FEE_BPS - ((OPENING_FEE_BPS - STANDING_FEE_BPS) * elapsed) / DECAY_SECONDS;
    }

    /// @notice Fee accrued in the hook and not yet swept, as the hook's ERC-6909 claim on the
    ///         PoolManager for the paired currency.
    function pending() public view returns (uint256) {
        return poolManager.balanceOf(address(this), paired.toId());
    }

    /// @notice Lifetime fee taken from swaps (swept and not yet swept).
    function collected() external view returns (uint256) {
        return _collected;
    }

    /// @notice Lifetime amount delivered to the treasury by `sweep()`.
    function swept() external view returns (uint256) {
        return _swept;
    }

    // ---------------------------------------------------------------------------------------
    // Sweep
    // ---------------------------------------------------------------------------------------

    /// @notice Sends everything the hook has accrued to the treasury. Anyone may call it.
    /// @return amount The amount of the paired currency delivered.
    function sweep() external returns (uint256 amount) {
        amount = pending();
        if (amount == 0) revert NothingToSweep();
        _swept += amount;
        emit Swept(msg.sender, TREASURY, amount);
        poolManager.unlock(abi.encode(amount));
    }

    /// @dev Only reachable from `sweep()`: the PoolManager calls back whoever called `unlock`.
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        uint256 amount = abi.decode(data, (uint256));
        Currency currency = paired;
        poolManager.burn(address(this), currency.toId(), amount);
        poolManager.take(currency, TREASURY, amount);
        return "";
    }

    // ---------------------------------------------------------------------------------------
    // Hook callbacks
    // ---------------------------------------------------------------------------------------

    /// @inheritdoc IHooks
    /// @dev Accepts exactly one pool: the launch token against any paired currency, at the launch
    ///      LP fee and tick spacing. Records the paired currency and the opening time.
    function beforeInitialize(address, PoolKey calldata key, uint160) external onlyPoolManager returns (bytes4) {
        if (_openedAt != 0) revert AlreadyOpened();
        if (key.fee != POOL_FEE || key.tickSpacing != POOL_TICK_SPACING) revert NotLaunchPool();

        Currency pairedCurrency;
        if (Currency.unwrap(key.currency0) == token) pairedCurrency = key.currency1;
        else if (Currency.unwrap(key.currency1) == token) pairedCurrency = key.currency0;
        else revert NotLaunchPool();

        paired = pairedCurrency;
        PoolId id = key.toId();
        poolId = id;
        _openedAt = block.timestamp;
        emit PoolOpened(id, pairedCurrency, block.timestamp);
        return IHooks.beforeInitialize.selector;
    }

    /// @inheritdoc IHooks
    /// @dev When the paired currency is the specified side, reserves the fee for a full fill;
    ///      otherwise leaves the swap untouched and lets afterSwap take it. Never overrides the LP fee.
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (!_specifiedIsPaired(key, params)) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        (uint256 reserved,) = _reservedFee(params.amountSpecified, feeNow());
        // reserved <= int128.max is enforced by _reservedFee.
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(uint128(reserved)), 0), 0);
    }

    /// @inheritdoc IHooks
    /// @dev Takes or reconciles the fee against the pool's real delta on the paired currency.
    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external onlyPoolManager returns (bytes4, int128) {
        int128 pairedDelta = paired == key.currency0 ? delta.amount0() : delta.amount1();
        // Direction remains meaningful even when no liquidity fills and both deltas are zero.
        bool isBuy = params.zeroForOne == (paired == key.currency0);
        if (_specifiedIsPaired(key, params)) {
            _reconcile(sender, _refundRecipient(sender, hookData), params.amountSpecified, pairedDelta, isBuy);
            return (IHooks.afterSwap.selector, 0);
        }
        return (IHooks.afterSwap.selector, _charge(sender, pairedDelta, isBuy));
    }

    // ---------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------

    /// @dev Accept a single canonical, nonzero ABI-encoded address. Empty, unrelated or malformed
    ///      hookData keeps the legacy sender destination without introducing a swap revert.
    ///      This is a destination supplied by the router, not authenticated user identity.
    function _refundRecipient(address sender, bytes calldata hookData) internal pure returns (address) {
        if (hookData.length == 32) {
            uint256 word = uint256(bytes32(hookData));
            if (word != 0 && word <= type(uint160).max) return address(uint160(word));
        }
        return sender;
    }

    /// @dev Magnitude of the pool's actual paired-currency delta; direction comes from SwapParams.
    function _moved(int128 pairedDelta) internal pure returns (uint256) {
        return pairedDelta < 0 ? uint256(-int256(pairedDelta)) : uint256(int256(pairedDelta));
    }

    /// @dev The paired currency is the unspecified side: charge the fee through the afterSwap
    ///      return delta, proportional to what the pool actually moved.
    function _charge(address sender, int128 pairedDelta, bool isBuy) internal returns (int128) {
        uint256 moved = _moved(pairedDelta);
        uint256 bps = feeNow();
        uint256 fee = (moved * bps) / BPS; // fee <= moved <= int128.max
        _accrue(sender, sender, isBuy, bps, fee, 0);
        return int128(uint128(fee));
    }

    /// @dev The paired currency was the specified side: beforeSwap reserved a fee sized for a full
    ///      fill of `expected`. Scale it to what actually moved and refund the chosen recipient.
    function _reconcile(address sender, address refundRecipient, int256 amountSpecified, int128 pairedDelta, bool isBuy)
        internal
    {
        uint256 moved = _moved(pairedDelta);
        uint256 bps = feeNow();
        (uint256 reserved, uint256 expected) = _reservedFee(amountSpecified, bps);
        uint256 kept = moved >= expected ? reserved : (reserved * moved) / expected;
        _accrue(sender, refundRecipient, isBuy, bps, kept, reserved - kept);
    }

    /// @dev True when the swap's specified amount is denominated in the paired currency.
    function _specifiedIsPaired(PoolKey calldata key, SwapParams calldata params) internal view returns (bool) {
        bool specifiedIs0 = (params.amountSpecified < 0) == params.zeroForOne;
        bool pairedIs0 = paired == key.currency0;
        return specifiedIs0 == pairedIs0;
    }

    /// @dev Fee to reserve in beforeSwap when the paired currency is the specified side, sized so
    ///      that it equals `bps` of the paired amount the pool would move on a full fill.
    ///      - exact input (buy with IMD in):  pool gets net = x * BPS / (BPS + bps), fee = x - net
    ///      - exact output (sell with IMD out): pool pays gross = x + fee, fee = ceil(x * bps / (BPS - bps))
    ///      Reverts with UnrepresentableFee when the amounts do not fit the 128-bit deltas v4 uses.
    /// @return reserved The fee reserved for a full fill.
    /// @return expected The paired amount the pool moves on a full fill.
    function _reservedFee(int256 amountSpecified, uint256 bps)
        internal
        pure
        returns (uint256 reserved, uint256 expected)
    {
        if (amountSpecified < 0) {
            uint256 x;
            unchecked {
                // Correct for type(int256).min as well: wraps to 2**255, its true magnitude.
                x = uint256(-amountSpecified);
            }
            if (x > type(uint128).max) revert UnrepresentableFee();
            expected = (x * BPS) / (BPS + bps);
            if (expected == 0) expected = 1; // never turn a dust swap into a zero-amount swap
            reserved = x - expected;
        } else {
            uint256 x = uint256(amountSpecified);
            if (x > type(uint128).max) revert UnrepresentableFee();
            uint256 d = BPS - bps;
            reserved = (x * bps + d - 1) / d;
            expected = x + reserved;
        }
        if (reserved > uint256(uint128(type(int128).max)) || expected > uint256(uint128(type(int128).max))) {
            revert UnrepresentableFee();
        }
    }

    /// @dev Books `fee` as a claim for the hook and `refund` as a claim for the chosen recipient.
    ///      Both are minted here while the hook is still being credited: once afterSwap returns the
    ///      PoolManager credits the hook `fee + refund`, which nets the hook's delta to zero.
    function _accrue(address sender, address refundRecipient, bool isBuy, uint256 bps, uint256 fee, uint256 refund)
        internal
    {
        uint256 id = paired.toId();
        if (fee != 0) {
            _collected += fee;
            poolManager.mint(address(this), id, fee);
        }
        if (refund != 0) poolManager.mint(refundRecipient, id, refund);
        emit FeeTaken(sender, isBuy, bps, fee, refund);
    }

    // ---------------------------------------------------------------------------------------
    // Callbacks this hook does not implement (never called: their flags are off)
    // ---------------------------------------------------------------------------------------

    /// @inheritdoc IHooks
    function afterInitialize(address, PoolKey calldata, uint160, int24) external view onlyPoolManager returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotImplemented();
    }
}
