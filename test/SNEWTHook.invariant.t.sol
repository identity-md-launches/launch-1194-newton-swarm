// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "../vendor/forge-std/src/Test.sol";
import {PoolManager} from "../vendor/v4-core/src/PoolManager.sol";
import {IPoolManager} from "../vendor/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "../vendor/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "../vendor/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "../vendor/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "../vendor/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "../vendor/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "../vendor/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "../vendor/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "../vendor/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "../vendor/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "../vendor/v4-core/src/types/PoolOperation.sol";

import {SNEWT} from "../src/SNEWT.sol";
import {SNEWTHook} from "../src/SNEWTHook.sol";
import {MockERC20} from "./utils/MockERC20.sol";
import {HookMiner} from "./utils/HookMiner.sol";
import {SwapRouter, LiquidityRouter} from "./utils/Routers.sol";

/// @dev Turns an ERC-6909 claim back into tokens: what a swapper does with a hook refund.
contract ClaimRedeemer is IUnlockCallback {
    IPoolManager immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    /// @dev The caller must have transferred `amount` of claims to this contract first.
    function redeem(Currency currency, uint256 amount, address to) external {
        manager.unlock(abi.encode(currency, amount, to));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not manager");
        (Currency currency, uint256 amount, address to) = abi.decode(data, (Currency, uint256, address));
        manager.burn(address(this), currency.toId(), amount);
        manager.take(currency, to, amount);
        return "";
    }
}

/// @notice Random, bounded sequences of everything anyone can do to the launch pool and the hook.
/// @dev Every call is valid by construction: a revert here is a failure (fail_on_revert is on), because
///      the hook is required never to revert a real swap. Ghost totals record what each swap actually
///      moved so the invariants can hold the hook to "fee rate on what filled" over the whole sequence.
contract SNEWTHookHandler is Test {
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    uint256 constant BPS = 10_000;
    int24 constant FULL_RANGE_LOWER = -887_220;
    int24 constant FULL_RANGE_UPPER = 887_220;
    uint256 constant MAX_SWAP = 5_000 ether;
    uint256 constant MAX_LIQUIDITY_STEP = 100_000 ether;

    PoolManager public manager;
    SNEWT public token;
    MockERC20 public imd;
    SNEWTHook public hook;
    SwapRouter public swapRouter;
    LiquidityRouter public lpRouter;
    ClaimRedeemer public redeemer;
    PoolKey key;
    PoolId poolId;
    bool tokenIs0;
    uint256 imdId;

    address[] public actors;

    // Ghost accounting.
    uint256 public ghostSwaps;
    uint256 public ghostPartialFills;
    uint256 public ghostZeroFills;
    uint256 public ghostMaxFee; // sum over swaps of bps * moved / BPS + 2 (rounding slack)
    uint256 public ghostMoved; // sum over swaps of the IMD the pool actually moved
    uint256 public ghostRefunds; // claims minted back to swappers
    uint256 public ghostGifted; // claims third parties handed to the hook
    uint256 public ghostSwept; // what sweep() reported delivering
    uint256 public ghostRedeemed; // claims actors turned back into IMD
    uint256 public ghostLiquidityAdded; // net liquidity the handler added on top of the seed
    uint256 public ghostLastFee;
    uint256 public ghostLastTimestamp;

    constructor(
        PoolManager manager_,
        SNEWT token_,
        MockERC20 imd_,
        SNEWTHook hook_,
        PoolKey memory key_,
        SwapRouter swapRouter_,
        LiquidityRouter lpRouter_
    ) {
        manager = manager_;
        token = token_;
        imd = imd_;
        hook = hook_;
        key = key_;
        poolId = PoolIdLibrary.toId(key_);
        tokenIs0 = Currency.unwrap(key_.currency0) == address(token_);
        swapRouter = swapRouter_;
        lpRouter = lpRouter_;
        redeemer = new ClaimRedeemer(manager_);
        imdId = Currency.wrap(address(imd_)).toId();

        actors.push(makeAddr("alice"));
        actors.push(makeAddr("bob"));
        actors.push(makeAddr("carol"));
        for (uint256 i = 0; i < actors.length; i++) {
            vm.startPrank(actors[i]);
            token.approve(address(swapRouter), type(uint256).max);
            imd.approve(address(swapRouter), type(uint256).max);
            vm.stopPrank();
        }
        token.approve(address(lpRouter), type(uint256).max);
        imd.approve(address(lpRouter), type(uint256).max);

        ghostLastFee = hook.feeNow();
        ghostLastTimestamp = block.timestamp;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    // ------------------------------------------------------------------ helpers

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _zeroForOne(bool buy) internal view returns (bool) {
        return buy ? !tokenIs0 : tokenIs0;
    }

    function _sqrtPrice() internal view returns (uint160 p) {
        (p,,,) = IPoolManager(address(manager)).getSlot0(poolId);
    }

    /// @dev A limit `sqrtBps` of the current sqrt price away in the swap's direction, or the full
    ///      limit. Returns 0 when no valid limit exists (price pinned at an extreme).
    function _limit(bool zeroForOne, bool useLimit, uint256 sqrtBps) internal view returns (uint160) {
        uint256 p = _sqrtPrice();
        uint256 lo = TickMath.MIN_SQRT_PRICE + 1;
        uint256 hi = TickMath.MAX_SQRT_PRICE - 1;
        uint256 limit;
        if (!useLimit) {
            limit = zeroForOne ? lo : hi;
        } else {
            uint256 step = (p * sqrtBps) / BPS;
            if (step == 0) step = 1;
            limit = zeroForOne ? (p > step + lo ? p - step : lo) : (p + step < hi ? p + step : hi);
        }
        if (zeroForOne ? limit >= p : limit <= p) return 0;
        return uint160(limit);
    }

    function _reserved(bool buy, uint256 x, uint256 bps) internal pure returns (uint256 reserved, uint256 expected) {
        if (buy) {
            expected = (x * BPS) / (BPS + bps);
            if (expected == 0) expected = 1;
            reserved = x - expected;
        } else {
            uint256 d = BPS - bps;
            reserved = (x * bps + d - 1) / d;
            expected = x + reserved;
        }
    }

    // ------------------------------------------------------------------ actions

    struct Snap {
        address actor;
        bool buy;
        bool exactInput;
        uint256 amount;
        uint256 bps;
        uint256 reserved;
        uint256 expected;
        uint256 pending;
        uint256 collected;
        uint256 claims;
        int256 imdBalance;
        uint256 tokBalance;
    }

    /// @notice Any of the four swap shapes, optionally stopped by a price limit, by a random actor.
    function swap(uint256 actorSeed, bool buy, bool exactInput, uint256 amount, bool useLimit, uint16 sqrtBps)
        external
    {
        Snap memory s;
        s.actor = _actor(actorSeed);
        s.buy = buy;
        s.exactInput = exactInput;
        s.amount = bound(amount, 1, MAX_SWAP);
        bool zeroForOne = _zeroForOne(buy);
        uint160 limit = _limit(zeroForOne, useLimit, bound(sqrtBps, 1, 2_000));
        if (limit == 0) return;

        s.bps = hook.feeNow();
        if (buy == exactInput) (s.reserved, s.expected) = _reserved(buy, s.amount, s.bps);
        s.pending = hook.pending();
        s.collected = hook.collected();
        s.claims = manager.balanceOf(s.actor, imdId);
        s.imdBalance = int256(imd.balanceOf(s.actor));
        s.tokBalance = token.balanceOf(s.actor);

        vm.prank(s.actor);
        swapRouter.swap(key, SwapParams(zeroForOne, exactInput ? -int256(s.amount) : int256(s.amount), limit));

        _verify(s);
    }

    function _verify(Snap memory s) internal {
        uint256 fee = hook.pending() - s.pending;
        uint256 refund = manager.balanceOf(s.actor, imdId) - s.claims;
        int256 change = int256(imd.balanceOf(s.actor)) - s.imdBalance;
        assertEq(hook.collected() - s.collected, fee, "collected tracks pending");
        assertEq(manager.balanceOf(address(swapRouter), imdId), 0, "router forwarded every claim");

        // The IMD the pool itself moved, reconstructed from the swapper's side.
        uint256 moved;
        if (s.buy == s.exactInput) {
            // Reserved shapes: buy exact input, sell exact output.
            assertEq(fee + refund, s.reserved, "reserved fee split between hook and refund");
            moved = s.buy ? uint256(-change) - fee - refund : uint256(change + int256(s.reserved));
            assertLe(moved, s.expected, "never more than a full fill");
            if (moved < s.expected) {
                ghostPartialFills++;
                assertEq(fee, (s.reserved * moved) / s.expected, "fee scaled by the filled fraction");
            } else {
                assertEq(refund, 0, "a full fill refunds nothing");
            }
        } else {
            assertEq(refund, 0, "nothing reserved, nothing refunded");
            moved = s.buy ? uint256(-change) - fee : uint256(change) + fee;
            assertEq(fee, (moved * s.bps) / BPS, "fee is bps of what moved");
            // SNEWT is the specified side here: out on an exact-output buy, in on an exact-input sell.
            uint256 snewtMoved =
                s.buy ? token.balanceOf(s.actor) - s.tokBalance : s.tokBalance - token.balanceOf(s.actor);
            assertLe(snewtMoved, s.amount, "never more than specified");
            if (snewtMoved < s.amount) ghostPartialFills++;
        }
        if (moved == 0) {
            ghostZeroFills++;
            assertEq(fee, 0, "no fill, no fee");
        }
        assertLe(fee, (moved * s.bps) / BPS + 2, "never more than the fee rate on what filled");
        if (s.buy) assertGe(token.balanceOf(s.actor), s.tokBalance, "a buy never costs SNEWT");
        else assertLe(token.balanceOf(s.actor), s.tokBalance, "a sell never pays out SNEWT");

        ghostSwaps++;
        ghostMoved += moved;
        ghostMaxFee += (moved * s.bps) / BPS + 2;
        ghostRefunds += refund;
    }

    /// @notice Time passes; the fee may only fall.
    function warp(uint32 secs) external {
        vm.warp(block.timestamp + bound(secs, 0, 2 hours));
        uint256 fee = hook.feeNow();
        assertLe(fee, ghostLastFee, "fee never rises");
        ghostLastFee = fee;
        ghostLastTimestamp = block.timestamp;
    }

    /// @notice Anyone sweeps; an empty sweep must revert and change nothing.
    function sweep(uint256 actorSeed) external {
        address caller = _actor(actorSeed);
        uint256 due = hook.pending();
        uint256 treasuryBefore = imd.balanceOf(hook.TREASURY());
        uint256 sweptBefore = hook.swept();
        vm.prank(caller);
        if (due == 0) {
            try hook.sweep() {
                fail("an empty sweep must revert");
            } catch (bytes memory reason) {
                assertEq(bytes4(reason), SNEWTHook.NothingToSweep.selector, "wrong revert on empty sweep");
            }
            assertEq(hook.swept(), sweptBefore);
            return;
        }
        uint256 amount = hook.sweep();
        assertEq(amount, due, "sweep reports what was pending");
        assertEq(imd.balanceOf(hook.TREASURY()) - treasuryBefore, due, "treasury received it all");
        assertEq(hook.pending(), 0, "nothing left after a sweep");
        assertEq(hook.swept() - sweptBefore, due);
        ghostSwept += due;
    }

    /// @notice A swapper hands some of its refund claims to the hook (a donation; sweep must deliver it).
    function gift(uint256 actorSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        uint256 have = manager.balanceOf(actor, imdId);
        if (have == 0) return;
        amount = bound(amount, 1, have);
        vm.prank(actor);
        manager.transfer(address(hook), imdId, amount);
        ghostGifted += amount;
    }

    /// @notice A swapper turns refund claims back into IMD: the claims must be backed.
    function redeem(uint256 actorSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        uint256 have = manager.balanceOf(actor, imdId);
        if (have == 0) return;
        amount = bound(amount, 1, have);
        uint256 before = imd.balanceOf(actor);
        vm.startPrank(actor);
        manager.transfer(address(redeemer), imdId, amount);
        redeemer.redeem(Currency.wrap(address(imd)), amount, actor);
        vm.stopPrank();
        assertEq(imd.balanceOf(actor) - before, amount, "a claim redeems one for one");
        ghostRedeemed += amount;
    }

    /// @notice An LP adds full-range liquidity (no hook involvement, but it changes what fills).
    function addLiquidity(uint256 amount) external {
        amount = bound(amount, 1 ether, MAX_LIQUIDITY_STEP);
        lpRouter.modifyLiquidity(
            key, ModifyLiquidityParams(FULL_RANGE_LOWER, FULL_RANGE_UPPER, int256(amount), bytes32(0))
        );
        ghostLiquidityAdded += amount;
    }

    /// @notice An LP removes liquidity it added (never the seed, so swaps keep filling).
    function removeLiquidity(uint256 amount) external {
        if (ghostLiquidityAdded == 0) return;
        amount = bound(amount, 1, ghostLiquidityAdded);
        lpRouter.modifyLiquidity(
            key, ModifyLiquidityParams(FULL_RANGE_LOWER, FULL_RANGE_UPPER, -int256(amount), bytes32(0))
        );
        ghostLiquidityAdded -= amount;
    }

    /// @notice Outstanding IMD claims held by everyone this handler knows about.
    function outstandingClaims() external view returns (uint256 total) {
        total = hook.pending();
        for (uint256 i = 0; i < actors.length; i++) {
            total += manager.balanceOf(actors[i], imdId);
        }
        total += manager.balanceOf(address(swapRouter), imdId);
        total += manager.balanceOf(address(lpRouter), imdId);
        total += manager.balanceOf(address(redeemer), imdId);
    }

    function snewtHeldByEveryone() external view returns (uint256 total) {
        total = token.balanceOf(address(this)) + token.balanceOf(address(manager)) + token.balanceOf(address(hook))
            + token.balanceOf(address(swapRouter)) + token.balanceOf(address(lpRouter));
        for (uint256 i = 0; i < actors.length; i++) {
            total += token.balanceOf(actors[i]);
        }
    }
}

/// @notice Invariants of the hook as a value-holding contract, over random call sequences.
/// @dev Two complete deployments run side by side, one with SNEWT as currency0 and one with it as
///      currency1, because the launch token's sort order against IMD is unknown before launch. Both
///      handlers are fuzz targets, and every invariant is checked on both. (One concrete contract
///      rather than an abstract base: forge ignores inline `forge-config` on inherited functions.)
contract SNEWTHookInvariantTest is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 constant FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
    uint256 constant SUPPLY = 1_000_000_000 ether;
    uint256 constant SEED_LIQUIDITY = 1_000_000 ether;
    address constant TREASURY = 0x5F948c351EB9F0734C28B605BbeEe9AB9d04318E;

    struct Deployment {
        PoolManager manager;
        SNEWT token;
        MockERC20 imd;
        SNEWTHook hook;
        SNEWTHookHandler handler;
        PoolId poolId;
        uint256 openedAt;
    }

    address factory = makeAddr("factory");
    Deployment[] deployments;

    function setUp() public {
        vm.warp(1_700_000_000);
        _deploy(true);
        _deploy(false);
    }

    function _deploy(bool tokenFirst) internal {
        Deployment memory d;
        d.manager = new PoolManager(address(this));
        d.token = new SNEWT();
        d.imd = new MockERC20("IMD", "IMD", 18);
        while ((address(d.token) < address(d.imd)) != tokenFirst) {
            d.imd = new MockERC20("IMD", "IMD", 18);
        }
        bool tokenIs0 = address(d.token) < address(d.imd);

        (, bytes32 salt) =
            HookMiner.find(factory, FLAGS, type(SNEWTHook).creationCode, abi.encode(d.manager, address(d.token)));
        vm.prank(factory);
        d.hook = new SNEWTHook{salt: salt}(d.manager, address(d.token));

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(tokenIs0 ? address(d.token) : address(d.imd)),
            currency1: Currency.wrap(tokenIs0 ? address(d.imd) : address(d.token)),
            fee: 12_500,
            tickSpacing: 60,
            hooks: IHooks(address(d.hook))
        });
        d.poolId = key.toId();
        SwapRouter swapRouter = new SwapRouter(d.manager);
        LiquidityRouter lpRouter = new LiquidityRouter(d.manager);

        vm.prank(factory);
        d.manager.initialize(key, SQRT_PRICE_1_1);
        d.openedAt = block.timestamp;

        d.handler = new SNEWTHookHandler(d.manager, d.token, d.imd, d.hook, key, swapRouter, lpRouter);

        // The handler is the LP; the actors are traders. The whole fixed supply stays among them.
        d.token.transfer(address(d.handler), SUPPLY);
        d.imd.mint(address(d.handler), 1e30);
        for (uint256 i = 0; i < d.handler.actorCount(); i++) {
            address actor = d.handler.actors(i);
            vm.prank(address(d.handler));
            d.token.transfer(actor, 100_000_000 ether);
            d.imd.mint(actor, 1e30);
        }
        vm.prank(address(d.handler));
        lpRouter.modifyLiquidity(key, ModifyLiquidityParams(-887_220, 887_220, int256(SEED_LIQUIDITY), bytes32(0)));

        targetContract(address(d.handler));
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = SNEWTHookHandler.swap.selector;
        selectors[1] = SNEWTHookHandler.warp.selector;
        selectors[2] = SNEWTHookHandler.sweep.selector;
        selectors[3] = SNEWTHookHandler.gift.selector;
        selectors[4] = SNEWTHookHandler.redeem.selector;
        selectors[5] = SNEWTHookHandler.addLiquidity.selector;
        selectors[6] = SNEWTHookHandler.removeLiquidity.selector;
        targetSelector(FuzzSelector({addr: address(d.handler), selectors: selectors}));

        deployments.push(d);
    }

    function imdId(Deployment memory d) internal pure returns (uint256) {
        return Currency.wrap(address(d.imd)).toId();
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_pendingPlusSweptIsCollectedPlusGifts() public view {
        for (uint256 i = 0; i < deployments.length; i++) {
            Deployment memory d = deployments[i];
            // Gifts are swept too, so swept can exceed collected: compare sums, never differences.
            assertEq(d.hook.pending() + d.hook.swept(), d.hook.collected() + d.handler.ghostGifted());
            assertEq(d.hook.pending(), d.manager.balanceOf(address(d.hook), imdId(d)));
            if (d.handler.ghostGifted() == 0) assertEq(d.hook.pending(), d.hook.collected() - d.hook.swept());
        }
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_treasuryHoldsExactlyWhatWasSwept() public view {
        for (uint256 i = 0; i < deployments.length; i++) {
            Deployment memory d = deployments[i];
            assertEq(d.imd.balanceOf(TREASURY), d.hook.swept());
            assertEq(d.hook.swept(), d.handler.ghostSwept());
            assertLe(d.hook.swept(), d.hook.collected() + d.handler.ghostGifted());
        }
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_feeNeverExceedsTheRateOnWhatFilled() public view {
        for (uint256 i = 0; i < deployments.length; i++) {
            Deployment memory d = deployments[i];
            assertLe(d.hook.collected(), d.handler.ghostMaxFee());
            // Over the whole sequence the fee is at most the opening rate of everything that moved.
            assertLe(d.hook.collected(), (d.handler.ghostMoved() * 4000) / 10_000 + 2 * d.handler.ghostSwaps());
        }
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_everyClaimIsBackedByImdInTheManager() public view {
        for (uint256 i = 0; i < deployments.length; i++) {
            Deployment memory d = deployments[i];
            assertGe(d.imd.balanceOf(address(d.manager)), d.handler.outstandingClaims());
        }
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_feeScheduleIsTheSpecifiedCurve() public view {
        for (uint256 i = 0; i < deployments.length; i++) {
            Deployment memory d = deployments[i];
            uint256 elapsed = block.timestamp - d.openedAt;
            uint256 expected = elapsed >= 60 minutes ? 300 : 4000 - (3700 * elapsed) / 60 minutes;
            assertEq(d.hook.feeNow(), expected);
            assertGe(d.hook.feeNow(), 300);
            assertLe(d.hook.feeNow(), 4000);
        }
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_poolIdentityNeverChanges() public view {
        for (uint256 i = 0; i < deployments.length; i++) {
            Deployment memory d = deployments[i];
            assertEq(d.hook.openedAt(), d.openedAt);
            assertEq(Currency.unwrap(d.hook.paired()), address(d.imd));
            assertEq(PoolId.unwrap(d.hook.poolId()), PoolId.unwrap(d.poolId));
            (,,, uint24 lpFee) = IPoolManager(address(d.manager)).getSlot0(d.poolId);
            assertEq(lpFee, 12_500, "the LP fee is static");
        }
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_hookHoldsOnlyImdClaims() public view {
        for (uint256 i = 0; i < deployments.length; i++) {
            Deployment memory d = deployments[i];
            assertEq(d.imd.balanceOf(address(d.hook)), 0, "fees live as claims, never as ERC-20 in the hook");
            assertEq(d.token.balanceOf(address(d.hook)), 0, "the hook never takes SNEWT");
            assertEq(d.manager.balanceOf(address(d.hook), Currency.wrap(address(d.token)).toId()), 0);
            assertEq(address(d.hook).balance, 0);
        }
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_launchTokenSupplyIsConserved() public view {
        for (uint256 i = 0; i < deployments.length; i++) {
            Deployment memory d = deployments[i];
            assertEq(d.token.totalSupply(), SUPPLY);
            assertEq(d.handler.snewtHeldByEveryone(), SUPPLY);
        }
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_refundsAndFeesAreConserved() public view {
        for (uint256 i = 0; i < deployments.length; i++) {
            Deployment memory d = deployments[i];
            // Everything the hook ever booked is either still pending, delivered, or refunded and
            // then gifted/redeemed/held by a swapper: nothing is created or lost in between.
            assertEq(d.hook.swept() + d.hook.pending(), d.hook.collected() + d.handler.ghostGifted());
            uint256 heldByActors;
            for (uint256 j = 0; j < d.handler.actorCount(); j++) {
                heldByActors += d.manager.balanceOf(d.handler.actors(j), imdId(d));
            }
            assertEq(heldByActors + d.handler.ghostGifted() + d.handler.ghostRedeemed(), d.handler.ghostRefunds());
        }
    }
}
