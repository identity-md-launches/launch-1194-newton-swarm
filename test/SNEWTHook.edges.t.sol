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
import {CustomRevert} from "../vendor/v4-core/src/libraries/CustomRevert.sol";
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

/// @dev An ERC-20 that refuses transfers to one address: stands in for a paired token that blocks the treasury.
contract BlockingERC20 is MockERC20 {
    address public immutable blocked;

    constructor(address blocked_) MockERC20("IMD", "IMD", 18) {
        blocked = blocked_;
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        require(to != blocked, "blocked recipient");
        _transfer(msg.sender, to, amount);
        return true;
    }
}

/// @dev A router that settles ERC-20 deltas but never forwards ERC-6909 claims to its user.
contract NaiveRouter is IUnlockCallback {
    IPoolManager immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function swap(PoolKey memory key, SwapParams memory params) external {
        manager.unlock(abi.encode(msg.sender, key, params));
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        require(msg.sender == address(manager), "not manager");
        (address payer, PoolKey memory key, SwapParams memory params) = abi.decode(raw, (address, PoolKey, SwapParams));
        BalanceDelta delta = manager.swap(key, params, "");
        _settle(payer, key.currency0, BalanceDeltaLibrary.amount0(delta));
        _settle(payer, key.currency1, BalanceDeltaLibrary.amount1(delta));
        return "";
    }

    function _settle(address payer, Currency currency, int128 amount) internal {
        if (amount < 0) {
            manager.sync(currency);
            MockERC20(Currency.unwrap(currency)).transferFrom(payer, address(manager), uint256(uint128(-amount)));
            manager.settle();
        } else if (amount > 0) {
            manager.take(currency, payer, uint256(uint128(amount)));
        }
    }
}

/// @notice Edge cases the main suite does not reach: empty pools, the largest representable swap,
///         every second of the fee curve, a paired token that blocks the treasury, and routers that
///         mishandle the refund claim. Runs with SNEWT as currency0 and as currency1.
abstract contract SNEWTHookEdgeBase is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 constant FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
    uint256 constant BPS = 10_000;
    uint256 constant LIQUIDITY = 1_000_000 ether;
    address constant TREASURY = 0x5F948c351EB9F0734C28B605BbeEe9AB9d04318E;

    address factory = makeAddr("factory");
    address alice = makeAddr("alice");

    PoolManager manager;
    SNEWT token;
    MockERC20 imd;
    SNEWTHook hook;
    SwapRouter swapRouter;
    LiquidityRouter lpRouter;
    PoolKey key;
    PoolId poolId;
    bool tokenIs0;

    function wantTokenFirst() internal pure virtual returns (bool);

    /// @dev Deploys a fresh stack. `blocking` makes the paired token refuse transfers to the treasury.
    function deploy(bool blocking) internal {
        manager = new PoolManager(address(this));
        token = new SNEWT();
        imd = blocking ? MockERC20(address(new BlockingERC20(TREASURY))) : new MockERC20("IMD", "IMD", 18);
        while ((address(token) < address(imd)) != wantTokenFirst()) {
            imd = blocking ? MockERC20(address(new BlockingERC20(TREASURY))) : new MockERC20("IMD", "IMD", 18);
        }
        tokenIs0 = address(token) < address(imd);

        (, bytes32 salt) =
            HookMiner.find(factory, FLAGS, type(SNEWTHook).creationCode, abi.encode(manager, address(token)));
        vm.prank(factory);
        hook = new SNEWTHook{salt: salt}(manager, address(token));

        key = PoolKey({
            currency0: Currency.wrap(tokenIs0 ? address(token) : address(imd)),
            currency1: Currency.wrap(tokenIs0 ? address(imd) : address(token)),
            fee: 12_500,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        poolId = key.toId();
        swapRouter = new SwapRouter(manager);
        lpRouter = new LiquidityRouter(manager);
        imd.mint(address(this), 1e40);
        token.approve(address(swapRouter), type(uint256).max);
        token.approve(address(lpRouter), type(uint256).max);
        imd.approve(address(swapRouter), type(uint256).max);
        imd.approve(address(lpRouter), type(uint256).max);
    }

    function setUp() public virtual {
        vm.warp(1_700_000_000);
        deploy(false);
    }

    function openPool() internal {
        vm.prank(factory);
        manager.initialize(key, SQRT_PRICE_1_1);
    }

    function seedBothSides() internal {
        openPool();
        lpRouter.modifyLiquidity(key, ModifyLiquidityParams(-887_220, 887_220, int256(LIQUIDITY), bytes32(0)));
    }

    function zeroForOneFor(bool buy) internal view returns (bool) {
        return buy ? !tokenIs0 : tokenIs0;
    }

    function fullLimit(bool zeroForOne) internal pure returns (uint160) {
        return zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }

    function nearLimit(bool zeroForOne, uint256 sqrtBps) internal pure returns (uint160) {
        uint256 step = (uint256(SQRT_PRICE_1_1) * sqrtBps) / BPS;
        return uint160(zeroForOne ? SQRT_PRICE_1_1 - step : SQRT_PRICE_1_1 + step);
    }

    function swap(bool buy, bool exactInput, uint256 amount, uint160 limit) internal returns (BalanceDelta) {
        bool zeroForOne = zeroForOneFor(buy);
        if (limit == 0) limit = fullLimit(zeroForOne);
        return swapRouter.swap(key, SwapParams(zeroForOne, exactInput ? -int256(amount) : int256(amount), limit));
    }

    function claims(address who) internal view returns (uint256) {
        return manager.balanceOf(who, Currency.wrap(address(imd)).toId());
    }

    function reservedBuy(uint256 x, uint256 bps) internal pure returns (uint256 reserved, uint256 net) {
        net = (x * BPS) / (BPS + bps);
        if (net == 0) net = 1;
        reserved = x - net;
    }

    function reservedSell(uint256 x, uint256 bps) internal pure returns (uint256 reserved, uint256 gross) {
        uint256 d = BPS - bps;
        reserved = (x * bps + d - 1) / d;
        gross = x + reserved;
    }

    // ------------------------------------------------------------------ pools with no liquidity

    function test_emptyPoolExactInputBuyRefundsTheWholeReservation() public {
        openPool(); // initialized, never seeded: every swap fills nothing
        uint256 x = 1000 ether;
        (uint256 reserved,) = reservedBuy(x, hook.feeNow());
        uint256 imdBefore = imd.balanceOf(address(this));

        swap(true, true, x, 0);

        assertEq(hook.pending(), 0, "no fill, no fee");
        assertEq(hook.collected(), 0);
        assertEq(claims(address(this)), reserved, "the whole reservation came back as a claim");
        assertEq(imdBefore - imd.balanceOf(address(this)), reserved, "the swapper fronted only the reservation");
        assertEq(imd.balanceOf(address(manager)), reserved, "which backs the claim one for one");
    }

    function test_emptyPoolExactOutputSellRefundsTheWholeReservation() public {
        openPool();
        uint256 x = 1000 ether;
        (uint256 reserved,) = reservedSell(x, hook.feeNow());
        uint256 imdBefore = imd.balanceOf(address(this));

        swap(false, false, x, 0);

        assertEq(hook.pending(), 0, "no fill, no fee");
        assertEq(claims(address(this)), reserved);
        // Nothing filled, so the swapper paid the reservation in ERC-20 and holds it back as a claim.
        assertEq(imdBefore - imd.balanceOf(address(this)), reserved);
    }

    function test_emptyPoolUnspecifiedShapesTakeNoFee() public {
        openPool();
        uint256 imdBefore = imd.balanceOf(address(this));
        uint256 tokBefore = token.balanceOf(address(this));
        swap(true, false, 1000 ether, 0);
        swap(false, true, 1000 ether, 0);
        assertEq(hook.pending(), 0);
        assertEq(hook.collected(), 0);
        assertEq(claims(address(this)), 0);
        assertEq(imd.balanceOf(address(this)), imdBefore);
        assertEq(token.balanceOf(address(this)), tokBefore);
    }

    function test_swapOnAnUninitializedPoolWithTheHookReverts() public {
        openPool();
        MockERC20 other = new MockERC20("O", "O", 18);
        (address c0, address c1) =
            address(token) < address(other) ? (address(token), address(other)) : (address(other), address(token));
        PoolKey memory stranger = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 12_500, 60, IHooks(address(hook)));
        vm.expectRevert(IPoolManager.PoolNotInitialized.selector);
        swapRouter.swap(stranger, SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1));
        assertEq(hook.pending(), 0);
    }

    // ------------------------------------------------------------------ the largest representable swap

    function test_largestRepresentableExactInputBuyFillsPartiallyAndRefunds() public {
        seedBothSides();
        // x = int128.max: expected = x * 10000 / 14000 and reserved both fit int128, so the hook
        // accepts it; the pool can only fill what its liquidity allows and the rest comes back.
        uint256 x = uint256(uint128(type(int128).max));
        (uint256 reserved, uint256 expected) = reservedBuy(x, hook.feeNow());
        uint256 imdBefore = imd.balanceOf(address(this));

        swap(true, true, x, 0);

        uint256 refund = claims(address(this));
        uint256 kept = hook.pending();
        uint256 paid = imdBefore - imd.balanceOf(address(this));
        uint256 moved = paid - kept - refund;
        assertEq(paid, moved + reserved, "the swapper settled the fill plus the reservation");
        assertLe(moved, expected);
        assertEq(kept + refund, reserved);
        assertEq(kept, moved >= expected ? reserved : (reserved * moved) / expected);
        assertLe(kept, (moved * 4000) / BPS + 2);
        assertGt(token.balanceOf(address(this)), 0, "SNEWT was delivered");
        assertEq(hook.collected(), kept);
    }

    function test_smallestUnrepresentableExactInputBuyReverts() public {
        seedBothSides();
        // The smallest x whose expected pool amount exceeds int128.max.
        uint256 limit = uint256(uint128(type(int128).max));
        uint256 x = ((limit + 1) * 14_000 + BPS - 1) / BPS;
        (, uint256 expected) = reservedBuy(x, 4000);
        assertGt(expected, limit);
        (, uint256 justBelow) = reservedBuy(x - 1, 4000);
        assertLe(justBelow, limit);
        assertLe(x, type(uint128).max);
        bool zeroForOne = zeroForOneFor(true);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(SNEWTHook.UnrepresentableFee.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swapRouter.swap(key, SwapParams(zeroForOne, -int256(x), fullLimit(zeroForOne)));
        // One wei less passes the hook. (With a full fill the PoolManager itself would overflow the
        // swapper's combined int128 delta, so stop the fill early with a price limit.)
        (uint256 reserved, uint256 net) = reservedBuy(x - 1, 4000);
        uint256 imdBefore = imd.balanceOf(address(this));
        swapRouter.swap(key, SwapParams(zeroForOne, -int256(x - 1), nearLimit(zeroForOne, 5)));
        uint256 kept = hook.pending();
        uint256 refund = claims(address(this));
        uint256 moved = (imdBefore - imd.balanceOf(address(this))) - kept - refund;
        assertEq(kept + refund, reserved);
        assertGt(refund, 0, "almost everything came back: the fill was tiny next to the request");
        assertLt(kept, reserved / 1_000_000);
        assertEq(kept, (reserved * moved) / net);
    }

    // ------------------------------------------------------------------ the fee curve, second by second

    function test_feeCurveAtEverySecondOfTheOpeningHour() public {
        openPool();
        uint256 opened = block.timestamp;
        uint256 previous = 4000;
        for (uint256 s = 0; s <= 3_700; s++) {
            vm.warp(opened + s);
            uint256 expected = s >= 3600 ? 300 : 4000 - (3700 * s) / 3600;
            uint256 fee = hook.feeNow();
            assertEq(fee, expected);
            assertLe(fee, previous, "never rises");
            assertGe(fee, 300);
            previous = fee;
        }
        assertEq(previous, 300);
    }

    function test_feeDropsOneBpsInTheFirstSecond() public {
        openPool();
        vm.warp(block.timestamp + 1);
        assertEq(hook.feeNow(), 3999);
        vm.warp(block.timestamp + 3598); // 3599 s after opening
        assertEq(hook.feeNow(), 302);
        vm.warp(block.timestamp + 1); // exactly 3600 s
        assertEq(hook.feeNow(), 300);
    }

    function test_feeFollowsTheTimestampNotTheBlockNumber() public {
        seedBothSides();
        vm.roll(block.number + 1_000_000);
        assertEq(hook.feeNow(), 4000, "blocks without seconds do not decay the fee");
        uint256 x = 1000 ether;
        (uint256 reserved,) = reservedBuy(x, 4000);
        swap(true, true, x, 0);
        assertEq(hook.pending(), reserved);
    }

    function test_feeIsFrozenWithinATransaction() public {
        // beforeSwap and afterSwap read the same feeNow(): a swap 30 minutes in reconciles against
        // the mid-decay rate, not the opening one.
        seedBothSides();
        vm.warp(block.timestamp + 30 minutes);
        uint256 bps = hook.feeNow();
        assertEq(bps, 2150);
        uint256 x = 10_000 ether;
        (uint256 reserved, uint256 net) = reservedBuy(x, bps);
        uint256 imdBefore = imd.balanceOf(address(this));
        swap(true, true, x, nearLimit(zeroForOneFor(true), 5));
        uint256 kept = hook.pending();
        uint256 refund = claims(address(this));
        uint256 moved = (imdBefore - imd.balanceOf(address(this))) - kept - refund;
        assertEq(kept + refund, reserved);
        assertLt(kept, reserved);
        assertEq(kept, (reserved * moved) / net, "reconciled at the mid-decay rate");
        (uint256 openingReserved,) = reservedBuy(x, 4000);
        assertLt(reserved, openingReserved, "and not at the opening rate");
    }

    // ------------------------------------------------------------------ routers and refunds

    function test_emptyHookDataKeepsLegacyRouterRefundDestination() public {
        // Empty hookData retains the legacy fallback. Routers can now supply abi.encode(recipient)
        // to deliver a refund directly; this fixture deliberately sends no recipient.
        seedBothSides();
        NaiveRouter naive = new NaiveRouter(manager);
        imd.transfer(alice, 100_000 ether);
        vm.startPrank(alice);
        imd.approve(address(naive), type(uint256).max);
        naive.swap(key, SwapParams(zeroForOneFor(true), -int256(10_000 ether), nearLimit(zeroForOneFor(true), 5)));
        vm.stopPrank();
        assertGt(claims(address(naive)), 0, "the refund sits with the router");
        assertEq(claims(alice), 0, "not with the user");
        assertGt(hook.pending(), 0);
    }

    function test_exactOutputSellBelowTheReservationNeedsImdFromTheSwapper() public {
        // Sized for a full fill, the reservation on an exact-output sell can exceed a small fill.
        // The net result is still fill minus fee, but the swapper's ERC-20 delta on IMD is negative,
        // so a swapper (or router) that cannot pay IMD in that transaction cannot make the trade.
        seedBothSides();
        uint256 x = 10_000 ether;
        (uint256 reserved,) = reservedSell(x, hook.feeNow());
        token.transfer(alice, 100_000 ether);
        vm.startPrank(alice);
        token.approve(address(swapRouter), type(uint256).max);
        imd.approve(address(swapRouter), type(uint256).max);
        // Alice holds no IMD at all: the settlement of the negative IMD delta fails.
        vm.expectRevert();
        swapRouter.swap(key, SwapParams(zeroForOneFor(false), int256(x), nearLimit(zeroForOneFor(false), 5)));
        vm.stopPrank();

        // With IMD to front, the same swap succeeds and nets out to the fill minus its fee.
        imd.transfer(alice, reserved);
        vm.prank(alice);
        swapRouter.swap(key, SwapParams(zeroForOneFor(false), int256(x), nearLimit(zeroForOneFor(false), 5)));
        uint256 refund = claims(alice);
        uint256 kept = hook.pending();
        assertEq(kept + refund, reserved);
        uint256 erc20Received = imd.balanceOf(alice); // started at `reserved`, paid some, took some
        uint256 moved = erc20Received + refund + kept - reserved;
        assertGt(moved, 0);
        assertLt(moved, reserved, "the fill was below the reservation");
        assertEq(erc20Received + refund, reserved + moved - kept, "net: fill minus fee");
    }

    // ------------------------------------------------------------------ a paired token that blocks the treasury

    function test_sweepRevertsWhenThePairedTokenBlocksTheTreasuryButSwapsContinue() public {
        deploy(true);
        seedBothSides();
        swap(true, true, 1000 ether, 0);
        uint256 due = hook.pending();
        assertGt(due, 0);

        vm.expectRevert();
        hook.sweep();
        assertEq(hook.pending(), due, "a failed sweep changes nothing");
        assertEq(hook.swept(), 0);

        // Fees keep accruing as claims; no swap is blocked by the treasury's problem.
        swap(false, true, 500 ether, 0);
        swap(true, false, 100 ether, 0);
        swap(false, false, 100 ether, 0);
        assertGt(hook.pending(), due);
        assertEq(hook.swept(), 0);
    }

    // ------------------------------------------------------------------ sweep callers

    function test_sweepFromAContractAndFromTheTreasuryItself() public {
        seedBothSides();
        swap(true, true, 1000 ether, 0);
        uint256 due = hook.pending();
        vm.prank(TREASURY);
        assertEq(hook.sweep(), due);
        assertEq(imd.balanceOf(TREASURY), due);
        swap(true, true, 10 ether, 0);
        uint256 more = hook.pending();
        assertEq(hook.sweep(), more); // from this contract
        assertEq(imd.balanceOf(TREASURY), due + more);
        assertEq(hook.swept(), due + more);
    }
}

contract SNEWTHookEdgeTokenFirstTest is SNEWTHookEdgeBase {
    function wantTokenFirst() internal pure override returns (bool) {
        return true;
    }
}

contract SNEWTHookEdgePairedFirstTest is SNEWTHookEdgeBase {
    function wantTokenFirst() internal pure override returns (bool) {
        return false;
    }
}
