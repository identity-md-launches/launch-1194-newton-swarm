// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "../vendor/forge-std/src/Test.sol";
import {PoolManager} from "../vendor/v4-core/src/PoolManager.sol";
import {IPoolManager} from "../vendor/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "../vendor/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "../vendor/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "../vendor/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "../vendor/v4-core/src/libraries/StateLibrary.sol";
import {CustomRevert} from "../vendor/v4-core/src/libraries/CustomRevert.sol";
import {LPFeeLibrary} from "../vendor/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "../vendor/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "../vendor/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "../vendor/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "../vendor/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "../vendor/v4-core/src/types/PoolOperation.sol";
import {IUnlockCallback} from "../vendor/v4-core/src/interfaces/callback/IUnlockCallback.sol";

import {SNEWT} from "../src/SNEWT.sol";
import {SNEWTHook} from "../src/SNEWTHook.sol";
import {MockERC20} from "./utils/MockERC20.sol";
import {HookMiner} from "./utils/HookMiner.sol";
import {SwapRouter, LiquidityRouter} from "./utils/Routers.sol";

/// @dev Calls `sweep()` from inside its own unlock, which the PoolManager must refuse.
contract ReentrantSweeper is IUnlockCallback {
    IPoolManager immutable manager;
    SNEWTHook immutable hook;

    constructor(IPoolManager manager_, SNEWTHook hook_) {
        manager = manager_;
        hook = hook_;
    }

    function attack() external {
        manager.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        hook.sweep();
        return "";
    }
}

/// @notice Unit, fuzz and accounting tests for SNEWTHook on a local PoolManager.
/// @dev Abstract so the whole suite runs twice: once with SNEWT as currency0 and once as currency1,
///      because the launch token's address, and so its sort order against IMD, is unknown before launch.
abstract contract SNEWTHookTestBase is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 constant FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
    uint24 constant POOL_FEE = 12_500;
    int24 constant TICK_SPACING = 60;
    int24 constant FULL_RANGE_LOWER = -887_220;
    int24 constant FULL_RANGE_UPPER = 887_220;
    uint256 constant BPS = 10_000;
    uint256 constant LIQUIDITY = 1_000_000 ether;
    address constant TREASURY = 0x5F948c351EB9F0734C28B605BbeEe9AB9d04318E;

    /// @dev Stands in for the IMD launch factory: deploys the hook and initializes the pool.
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

    event PoolOpened(PoolId indexed id, Currency indexed paired, uint256 openedAt);
    event FeeTaken(address indexed sender, bool isBuy, uint256 feeBps, uint256 fee, uint256 refund);
    event Swept(address indexed caller, address indexed treasury, uint256 amount);

    function wantTokenFirst() internal pure virtual returns (bool);

    function setUp() public virtual {
        manager = new PoolManager(address(this));
        token = new SNEWT();
        imd = new MockERC20("IMD", "IMD", 18);
        // The launch token's sort order against IMD is unknown before launch: cover both.
        while ((address(token) < address(imd)) != wantTokenFirst()) {
            imd = new MockERC20("IMD", "IMD", 18);
        }
        tokenIs0 = address(token) < address(imd);

        (address predicted, bytes32 salt) =
            HookMiner.find(factory, FLAGS, type(SNEWTHook).creationCode, abi.encode(manager, address(token)));
        vm.prank(factory);
        hook = new SNEWTHook{salt: salt}(manager, address(token));
        assertEq(address(hook), predicted, "hook landed off the mined address");

        key = PoolKey({
            currency0: Currency.wrap(tokenIs0 ? address(token) : address(imd)),
            currency1: Currency.wrap(tokenIs0 ? address(imd) : address(token)),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        poolId = key.toId();

        swapRouter = new SwapRouter(manager);
        lpRouter = new LiquidityRouter(manager);
        imd.mint(address(this), 1e27);
        token.approve(address(swapRouter), type(uint256).max);
        token.approve(address(lpRouter), type(uint256).max);
        imd.approve(address(swapRouter), type(uint256).max);
        imd.approve(address(lpRouter), type(uint256).max);
    }

    // ------------------------------------------------------------------ helpers

    function openPool() internal {
        vm.prank(factory);
        manager.initialize(key, SQRT_PRICE_1_1);
    }

    /// @dev Balanced full-range liquidity: both currencies in the manager.
    function seedBothSides() internal {
        openPool();
        lpRouter.modifyLiquidity(
            key, ModifyLiquidityParams(FULL_RANGE_LOWER, FULL_RANGE_UPPER, int256(LIQUIDITY), bytes32(0))
        );
    }

    /// @dev Launch-like seeding: SNEWT only, entirely above the opening price. The manager holds no IMD.
    function seedTokenOnly() internal {
        openPool();
        (int24 lower, int24 upper) = tokenIs0 ? (int24(60), FULL_RANGE_UPPER) : (FULL_RANGE_LOWER, int24(-60));
        lpRouter.modifyLiquidity(key, ModifyLiquidityParams(lower, upper, int256(LIQUIDITY), bytes32(0)));
        assertEq(imd.balanceOf(address(manager)), 0, "manager should hold no IMD after token-only seeding");
    }

    function zeroForOneFor(bool buy) internal view returns (bool) {
        // A buy pays IMD in. IMD is currency1 when the token is currency0.
        return buy ? !tokenIs0 : tokenIs0;
    }

    function fullLimit(bool zeroForOne) internal pure returns (uint160) {
        return zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }

    /// @dev A price limit `sqrtBps` basis points of sqrt-price away from 1:1 in the swap's direction.
    function nearLimit(bool zeroForOne, uint256 sqrtBps) internal pure returns (uint160) {
        uint256 step = (uint256(SQRT_PRICE_1_1) * sqrtBps) / BPS;
        return uint160(zeroForOne ? SQRT_PRICE_1_1 - step : SQRT_PRICE_1_1 + step);
    }

    function swap(bool buy, bool exactInput, uint256 amount, uint160 limit) internal returns (BalanceDelta) {
        bool zeroForOne = zeroForOneFor(buy);
        if (limit == 0) limit = fullLimit(zeroForOne);
        int256 specified = exactInput ? -int256(amount) : int256(amount);
        return swapRouter.swap(key, SwapParams(zeroForOne, specified, limit));
    }

    function swapAs(address who, bool buy, bool exactInput, uint256 amount, uint160 limit)
        internal
        returns (BalanceDelta)
    {
        vm.startPrank(who);
        token.approve(address(swapRouter), type(uint256).max);
        imd.approve(address(swapRouter), type(uint256).max);
        BalanceDelta d = swap(buy, exactInput, amount, limit);
        vm.stopPrank();
        return d;
    }

    function claims(address who) internal view returns (uint256) {
        return manager.balanceOf(who, Currency.wrap(address(imd)).toId());
    }

    function lpFee() internal view returns (uint24 fee) {
        (,,, fee) = IPoolManager(address(manager)).getSlot0(poolId);
    }

    function sqrtPrice() internal view returns (uint160 p) {
        (p,,,) = IPoolManager(address(manager)).getSlot0(poolId);
    }

    /// @dev The ERC-7751 wrapper the PoolManager puts around a hook revert.
    function wrapped(bytes4 callback, bytes4 reason) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            callback,
            abi.encodeWithSelector(reason),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
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

    // ------------------------------------------------------------------ deployment and permissions

    function test_addressCarriesExactlyTheDeclaredFlags() public view {
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, FLAGS);
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(
            p.beforeInitialize && p.beforeSwap && p.afterSwap && p.beforeSwapReturnDelta && p.afterSwapReturnDelta
        );
        assertFalse(
            p.afterInitialize || p.beforeAddLiquidity || p.afterAddLiquidity || p.beforeRemoveLiquidity
                || p.afterRemoveLiquidity || p.beforeDonate || p.afterDonate || p.afterAddLiquidityReturnDelta
                || p.afterRemoveLiquidityReturnDelta
        );
        // The same check v4-periphery's BaseHook runs: the address agrees with the permissions.
        Hooks.validateHookPermissions(IHooks(address(hook)), p);
        assertTrue(Hooks.isValidHookAddress(IHooks(address(hook)), POOL_FEE));
    }

    function test_constantsAndImmutables() public view {
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(hook.token(), address(token));
        assertEq(hook.TREASURY(), TREASURY);
        assertEq(hook.OPENING_FEE_BPS(), 4000);
        assertEq(hook.STANDING_FEE_BPS(), 300);
        assertEq(hook.DECAY_SECONDS(), 60 minutes);
        assertEq(hook.POOL_FEE(), 12_500);
        assertEq(hook.POOL_TICK_SPACING(), 60);
        assertEq(hook.openedAt(), 0);
        assertEq(hook.pending(), 0);
        assertEq(hook.collected(), 0);
        assertEq(hook.swept(), 0);
    }

    function test_constructorRejectsZeroAddresses() public {
        vm.expectRevert(SNEWTHook.ZeroAddress.selector);
        new SNEWTHook(IPoolManager(address(0)), address(token));
        vm.expectRevert(SNEWTHook.ZeroAddress.selector);
        new SNEWTHook(manager, address(0));
    }

    function test_constructorRejectsAnAddressWithoutTheFlags() public {
        // A plain CREATE lands on an address that (all but surely) lacks the flag bits.
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        if (uint160(predicted) & Hooks.ALL_HOOK_MASK == FLAGS) return; // one chance in 16384
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
        new SNEWTHook(manager, address(token));
    }

    function test_creationCodeWithinEip3860() public pure {
        uint256 initcode = type(SNEWTHook).creationCode.length + 64; // two constructor words
        assertLe(initcode, 49_152);
    }

    function test_runtimeHasNoDelegatecallOrSelfdestruct() public view {
        bytes memory code = address(hook).code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i = 0; i < code.length; i++) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
        }
    }

    // ------------------------------------------------------------------ access control

    function test_callbacksRefuseCallersOtherThanThePoolManager() public {
        SwapParams memory sp = SwapParams(true, -1 ether, SQRT_PRICE_1_1 / 2);
        ModifyLiquidityParams memory mp = ModifyLiquidityParams(-60, 60, 1 ether, bytes32(0));
        BalanceDelta zero = BalanceDeltaLibrary.ZERO_DELTA;
        bytes[11] memory calls = [
            abi.encodeCall(IHooks.beforeInitialize, (address(this), key, SQRT_PRICE_1_1)),
            abi.encodeCall(IHooks.afterInitialize, (address(this), key, SQRT_PRICE_1_1, 0)),
            abi.encodeCall(IHooks.beforeAddLiquidity, (address(this), key, mp, "")),
            abi.encodeCall(IHooks.afterAddLiquidity, (address(this), key, mp, zero, zero, "")),
            abi.encodeCall(IHooks.beforeRemoveLiquidity, (address(this), key, mp, "")),
            abi.encodeCall(IHooks.afterRemoveLiquidity, (address(this), key, mp, zero, zero, "")),
            abi.encodeCall(IHooks.beforeSwap, (address(this), key, sp, "")),
            abi.encodeCall(IHooks.afterSwap, (address(this), key, sp, zero, "")),
            abi.encodeCall(IHooks.beforeDonate, (address(this), key, 1, 1, "")),
            abi.encodeCall(IHooks.afterDonate, (address(this), key, 1, 1, "")),
            abi.encodeCall(IUnlockCallback.unlockCallback, (abi.encode(uint256(1))))
        ];
        for (uint256 i = 0; i < calls.length; i++) {
            vm.expectRevert(SNEWTHook.NotPoolManager.selector);
            (bool ok,) = address(hook).call(calls[i]);
            ok;
        }
        // Not even from the factory that deployed it.
        vm.prank(factory);
        vm.expectRevert(SNEWTHook.NotPoolManager.selector);
        hook.beforeInitialize(factory, key, SQRT_PRICE_1_1);
    }

    function test_unimplementedCallbacksRevertEvenForThePoolManager() public {
        ModifyLiquidityParams memory mp = ModifyLiquidityParams(-60, 60, 1 ether, bytes32(0));
        vm.startPrank(address(manager));
        vm.expectRevert(SNEWTHook.HookNotImplemented.selector);
        hook.afterInitialize(address(this), key, SQRT_PRICE_1_1, 0);
        vm.expectRevert(SNEWTHook.HookNotImplemented.selector);
        hook.beforeAddLiquidity(address(this), key, mp, "");
        vm.expectRevert(SNEWTHook.HookNotImplemented.selector);
        hook.beforeDonate(address(this), key, 1, 1, "");
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ initialization

    function test_factoryOpensTheLaunchPool() public {
        vm.warp(1_700_000_000);
        vm.expectEmit(true, true, true, true, address(hook));
        emit PoolOpened(poolId, Currency.wrap(address(imd)), block.timestamp);
        openPool();

        assertEq(hook.openedAt(), block.timestamp);
        assertEq(Currency.unwrap(hook.paired()), address(imd));
        assertEq(PoolId.unwrap(hook.poolId()), PoolId.unwrap(poolId));
        assertEq(hook.feeNow(), 4000);
        assertEq(lpFee(), POOL_FEE, "the LP fee must be the static 1.25%");
        assertEq(sqrtPrice(), SQRT_PRICE_1_1);
    }

    function test_anyoneCanBeTheInitializer() public {
        // The hook does not gate on who initializes: the mined address is only deployed by the factory.
        vm.prank(alice);
        manager.initialize(key, SQRT_PRICE_1_1);
        assertEq(hook.openedAt(), block.timestamp);
    }

    function test_initializeRefusesTheWrongLpFee() public {
        PoolKey memory bad = key;
        bad.fee = 3000;
        vm.prank(factory);
        vm.expectRevert(wrapped(IHooks.beforeInitialize.selector, SNEWTHook.NotLaunchPool.selector));
        manager.initialize(bad, SQRT_PRICE_1_1);
    }

    function test_initializeRefusesADynamicFee() public {
        PoolKey memory bad = key;
        bad.fee = LPFeeLibrary.DYNAMIC_FEE_FLAG;
        vm.prank(factory);
        vm.expectRevert(wrapped(IHooks.beforeInitialize.selector, SNEWTHook.NotLaunchPool.selector));
        manager.initialize(bad, SQRT_PRICE_1_1);
    }

    function test_initializeRefusesTheWrongTickSpacing() public {
        PoolKey memory bad = key;
        bad.tickSpacing = 10;
        vm.prank(factory);
        vm.expectRevert(wrapped(IHooks.beforeInitialize.selector, SNEWTHook.NotLaunchPool.selector));
        manager.initialize(bad, SQRT_PRICE_1_1);
    }

    function test_initializeRefusesAPoolWithoutTheLaunchToken() public {
        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        (address c0, address c1) = address(a) < address(b) ? (address(a), address(b)) : (address(b), address(a));
        PoolKey memory bad =
            PoolKey(Currency.wrap(c0), Currency.wrap(c1), POOL_FEE, TICK_SPACING, IHooks(address(hook)));
        vm.prank(factory);
        vm.expectRevert(wrapped(IHooks.beforeInitialize.selector, SNEWTHook.NotLaunchPool.selector));
        manager.initialize(bad, SQRT_PRICE_1_1);
    }

    function test_initializeRefusesASecondPool() public {
        openPool();
        MockERC20 other = new MockERC20("O", "O", 18);
        (address c0, address c1) =
            address(token) < address(other) ? (address(token), address(other)) : (address(other), address(token));
        PoolKey memory second =
            PoolKey(Currency.wrap(c0), Currency.wrap(c1), POOL_FEE, TICK_SPACING, IHooks(address(hook)));
        vm.prank(factory);
        vm.expectRevert(wrapped(IHooks.beforeInitialize.selector, SNEWTHook.AlreadyOpened.selector));
        manager.initialize(second, SQRT_PRICE_1_1);
        // The first pool is untouched.
        assertEq(Currency.unwrap(hook.paired()), address(imd));
    }

    function test_nobodyCanSwapBeforeThePoolIsOpened() public {
        vm.expectRevert();
        swap(true, true, 1 ether, 0);
    }

    // ------------------------------------------------------------------ fee schedule

    function test_feeIsTheOpeningFeeBeforeThePoolOpens() public view {
        assertEq(hook.feeNow(), 4000);
    }

    function test_feeDecaysLinearlyThenHolds() public {
        vm.warp(1_700_000_000);
        openPool();
        uint256 opened = block.timestamp;
        assertEq(hook.feeNow(), 4000);
        vm.warp(opened + 15 minutes);
        assertEq(hook.feeNow(), 4000 - (3700 * 15 minutes) / 60 minutes); // 3075
        vm.warp(opened + 30 minutes);
        assertEq(hook.feeNow(), 2150);
        vm.warp(opened + 45 minutes);
        assertEq(hook.feeNow(), 1225);
        vm.warp(opened + 60 minutes - 1);
        assertEq(hook.feeNow(), 302);
        vm.warp(opened + 60 minutes);
        assertEq(hook.feeNow(), 300);
        vm.warp(opened + 10 days);
        assertEq(hook.feeNow(), 300);
        vm.warp(opened + 100 * 365 days);
        assertEq(hook.feeNow(), 300);
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_feeScheduleIsBoundedAndNonIncreasing(uint64 start, uint32 a, uint32 b) public {
        vm.warp(uint256(start) + 1);
        openPool();
        uint256 opened = block.timestamp;
        (uint256 early, uint256 late) = a < b ? (uint256(a), uint256(b)) : (uint256(b), uint256(a));
        vm.warp(opened + early);
        uint256 feeEarly = hook.feeNow();
        vm.warp(opened + late);
        uint256 feeLate = hook.feeNow();
        assertGe(feeEarly, feeLate);
        assertLe(feeEarly, 4000);
        assertGe(feeLate, 300);
        if (late >= 60 minutes) assertEq(feeLate, 300);
        if (early == 0) assertEq(feeEarly, 4000);
    }

    // ------------------------------------------------------------------ the four swap shapes, full fills

    function _checkBuyExactInput(uint256 x) internal {
        uint256 bps = hook.feeNow();
        (uint256 reserved, uint256 net) = reservedBuy(x, bps);
        uint256 imdBefore = imd.balanceOf(address(this));
        uint256 tokBefore = token.balanceOf(address(this));
        uint256 managerBefore = imd.balanceOf(address(manager));
        uint256 collectedBefore = hook.collected();

        vm.expectEmit(true, true, true, true, address(hook));
        emit FeeTaken(address(swapRouter), true, bps, reserved, 0);
        swap(true, true, x, 0);

        assertEq(imdBefore - imd.balanceOf(address(this)), x, "swapper pays exactly the specified input");
        if (net >= 1000) assertGt(token.balanceOf(address(this)) - tokBefore, 0, "swapper received SNEWT");
        assertEq(hook.pending() - (collectedBefore - hook.swept()), reserved, "fee accrued as a claim");
        assertEq(hook.collected() - collectedBefore, reserved);
        assertEq(claims(address(this)), 0, "a full fill refunds nothing");
        assertEq(imd.balanceOf(address(manager)) - managerBefore, x, "all IMD paid sits in the manager");
        // The fee is `bps` of the IMD the pool actually received, up to rounding.
        assertApproxEqAbs(reserved, (net * bps) / BPS, 2);
    }

    function _checkBuyExactOutput(uint256 tokensOut) internal {
        uint256 bps = hook.feeNow();
        uint256 imdBefore = imd.balanceOf(address(this));
        uint256 tokBefore = token.balanceOf(address(this));
        uint256 pendingBefore = hook.pending();

        swap(true, false, tokensOut, 0);

        assertEq(token.balanceOf(address(this)) - tokBefore, tokensOut, "swapper receives exactly the output");
        uint256 paid = imdBefore - imd.balanceOf(address(this));
        uint256 fee = hook.pending() - pendingBefore;
        uint256 poolLeg = paid - fee;
        assertEq(fee, (poolLeg * bps) / BPS, "fee is bps of the IMD the pool received");
        assertEq(claims(address(this)), 0);
    }

    function _checkSellExactInput(uint256 tokensIn) internal {
        uint256 bps = hook.feeNow();
        uint256 imdBefore = imd.balanceOf(address(this));
        uint256 tokBefore = token.balanceOf(address(this));
        uint256 pendingBefore = hook.pending();

        swap(false, true, tokensIn, 0);

        assertEq(tokBefore - token.balanceOf(address(this)), tokensIn, "swapper pays exactly the input");
        uint256 received = imd.balanceOf(address(this)) - imdBefore;
        uint256 fee = hook.pending() - pendingBefore;
        uint256 poolLeg = received + fee;
        assertEq(fee, (poolLeg * bps) / BPS, "fee is bps of the IMD the pool paid out");
        assertEq(claims(address(this)), 0);
    }

    function _checkSellExactOutput(uint256 x) internal {
        uint256 bps = hook.feeNow();
        (uint256 reserved, uint256 gross) = reservedSell(x, bps);
        uint256 imdBefore = imd.balanceOf(address(this));
        uint256 tokBefore = token.balanceOf(address(this));
        uint256 pendingBefore = hook.pending();

        vm.expectEmit(true, true, true, true, address(hook));
        emit FeeTaken(address(swapRouter), false, bps, reserved, 0);
        swap(false, false, x, 0);

        assertEq(imd.balanceOf(address(this)) - imdBefore, x, "swapper receives exactly the specified output");
        assertGt(tokBefore - token.balanceOf(address(this)), 0, "swapper paid SNEWT");
        assertEq(hook.pending() - pendingBefore, reserved, "fee accrued as a claim");
        assertEq(claims(address(this)), 0, "a full fill refunds nothing");
        assertApproxEqAbs(reserved, (gross * bps) / BPS, 2);
    }

    function test_buyExactInputAtOpeningFee() public {
        seedBothSides();
        _checkBuyExactInput(1000 ether);
    }

    function test_buyExactOutputAtOpeningFee() public {
        seedBothSides();
        _checkBuyExactOutput(1000 ether);
    }

    function test_sellExactInputAtOpeningFee() public {
        seedBothSides();
        _checkSellExactInput(1000 ether);
    }

    function test_sellExactOutputAtOpeningFee() public {
        seedBothSides();
        _checkSellExactOutput(1000 ether);
    }

    function test_allFourShapesAtStandingFee() public {
        seedBothSides();
        vm.warp(block.timestamp + 61 minutes);
        assertEq(hook.feeNow(), 300);
        _checkBuyExactInput(1000 ether);
        _checkBuyExactOutput(1000 ether);
        _checkSellExactInput(1000 ether);
        _checkSellExactOutput(1000 ether);
    }

    function test_allFourShapesMidDecay() public {
        seedBothSides();
        vm.warp(block.timestamp + 20 minutes);
        uint256 elapsed = 20 minutes;
        uint256 expectedBps = 4000 - (3700 * elapsed) / 60 minutes; // 2767, floor of 2766.67
        assertEq(hook.feeNow(), expectedBps);
        assertEq(expectedBps, 2767);
        _checkBuyExactInput(333 ether);
        _checkBuyExactOutput(333 ether);
        _checkSellExactInput(333 ether);
        _checkSellExactOutput(333 ether);
    }

    function test_dustSwapsDoNotRevert() public {
        seedBothSides();
        swap(true, true, 1, 0);
        swap(true, true, 2, 0);
        swap(false, false, 1, 0);
        swap(true, false, 1, 0);
        swap(false, true, 1, 0);
    }

    function test_lpFeeIsNeverOverridden() public {
        seedBothSides();
        swap(true, true, 100 ether, 0);
        swap(false, true, 100 ether, 0);
        assertEq(lpFee(), POOL_FEE);
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_buyExactInput(uint256 x, uint32 elapsed) public {
        seedBothSides();
        x = bound(x, 1, 100_000 ether);
        vm.warp(block.timestamp + bound(elapsed, 0, 2 hours));
        _checkBuyExactInput(x);
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_buyExactOutput(uint256 x, uint32 elapsed) public {
        seedBothSides();
        x = bound(x, 1, 100_000 ether);
        vm.warp(block.timestamp + bound(elapsed, 0, 2 hours));
        _checkBuyExactOutput(x);
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_sellExactInput(uint256 x, uint32 elapsed) public {
        seedBothSides();
        x = bound(x, 1, 100_000 ether);
        vm.warp(block.timestamp + bound(elapsed, 0, 2 hours));
        _checkSellExactInput(x);
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_sellExactOutput(uint256 x, uint32 elapsed) public {
        seedBothSides();
        x = bound(x, 1, 100_000 ether);
        vm.warp(block.timestamp + bound(elapsed, 0, 2 hours));
        _checkSellExactOutput(x);
    }

    // ------------------------------------------------------------------ partial fills with a price limit

    function test_buyExactInputPartialFillRefundsTheExcessAsAClaim() public {
        seedBothSides();
        uint256 x = 10_000 ether;
        uint256 bps = hook.feeNow();
        (uint256 reserved, uint256 net) = reservedBuy(x, bps);
        uint160 limit = nearLimit(zeroForOneFor(true), 5); // 0.05% of sqrt price: fills ~500 IMD
        uint256 imdBefore = imd.balanceOf(address(this));
        uint256 managerBefore = imd.balanceOf(address(manager));

        swap(true, true, x, limit);

        assertEq(sqrtPrice(), limit, "the swap stopped at the price limit");
        uint256 paid = imdBefore - imd.balanceOf(address(this));
        uint256 refund = claims(address(this));
        uint256 kept = hook.pending();
        uint256 moved = paid - kept - refund;
        assertLt(moved, net, "only part of the input filled");
        assertGt(refund, 0, "the unfilled part's fee came back as a claim");
        assertEq(kept + refund, reserved, "reserved fee was split between hook and refund");
        assertEq(kept, (reserved * moved) / net, "fee scaled by the filled fraction");
        assertLe(kept, (moved * bps) / BPS + 2, "never more than the fee rate on what filled");
        assertEq(hook.collected(), kept);
        assertEq(imd.balanceOf(address(manager)) - managerBefore, paid, "every wei paid is in the manager");
    }

    function test_sellExactOutputPartialFillRefundsTheExcessAsAClaim() public {
        seedBothSides();
        uint256 x = 10_000 ether;
        uint256 bps = hook.feeNow();
        (uint256 reserved, uint256 gross) = reservedSell(x, bps);
        uint160 limit = nearLimit(zeroForOneFor(false), 5);
        uint256 imdBefore = imd.balanceOf(address(this));

        swap(false, false, x, limit);

        assertEq(sqrtPrice(), limit, "the swap stopped at the price limit");
        uint256 refund = claims(address(this));
        uint256 kept = hook.pending();
        // The pool paid `moved` out; the swapper's ERC-20 delta was moved - reserved (negative here,
        // because the reservation was sized for the whole 10,000) and the refund is reserved - kept,
        // so the net IMD received is moved - kept.
        int256 erc20Change = int256(imd.balanceOf(address(this))) - int256(imdBefore);
        uint256 moved = uint256(erc20Change + int256(reserved));
        assertLt(moved, gross, "only part of the output filled");
        assertGt(refund, 0);
        assertEq(kept + refund, reserved);
        assertEq(kept, (reserved * moved) / gross, "fee scaled by the filled fraction");
        assertLe(kept, (moved * bps) / BPS + 2, "never more than the fee rate on what filled");
        assertEq(erc20Change + int256(refund), int256(moved) - int256(kept), "net received is the fill minus its fee");
        assertLt(erc20Change, 0, "the reservation exceeded the fill: the router settled IMD and got claims back");
    }

    function test_buyExactOutputPartialFillPaysFeeOnTheFillOnly() public {
        seedBothSides();
        uint256 bps = hook.feeNow();
        uint160 limit = nearLimit(zeroForOneFor(true), 5);
        uint256 imdBefore = imd.balanceOf(address(this));
        uint256 tokBefore = token.balanceOf(address(this));

        swap(true, false, 10_000 ether, limit);

        assertEq(sqrtPrice(), limit);
        uint256 got = token.balanceOf(address(this)) - tokBefore;
        assertLt(got, 10_000 ether, "partial fill");
        uint256 paid = imdBefore - imd.balanceOf(address(this));
        uint256 fee = hook.pending();
        assertEq(fee, ((paid - fee) * bps) / BPS);
        assertEq(claims(address(this)), 0, "nothing was reserved, nothing to refund");
    }

    function test_sellExactInputPartialFillPaysFeeOnTheFillOnly() public {
        seedBothSides();
        uint256 bps = hook.feeNow();
        uint160 limit = nearLimit(zeroForOneFor(false), 5);
        uint256 imdBefore = imd.balanceOf(address(this));
        uint256 tokBefore = token.balanceOf(address(this));

        swap(false, true, 10_000 ether, limit);

        assertEq(sqrtPrice(), limit);
        assertLt(tokBefore - token.balanceOf(address(this)), 10_000 ether, "partial fill");
        uint256 received = imd.balanceOf(address(this)) - imdBefore;
        uint256 fee = hook.pending();
        assertEq(fee, ((received + fee) * bps) / BPS);
        assertEq(claims(address(this)), 0);
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_partialFillsNeverOvercharge(uint256 x, uint16 sqrtBps, uint32 elapsed, bool sell) public {
        seedBothSides();
        x = bound(x, 1 ether, 200_000 ether);
        sqrtBps = uint16(bound(sqrtBps, 1, 500));
        vm.warp(block.timestamp + bound(elapsed, 0, 2 hours));
        uint256 bps = hook.feeNow();
        bool buy = !sell;
        // Reserved-side shapes: buy exact input, sell exact output.
        (uint256 reserved, uint256 expected) = buy ? reservedBuy(x, bps) : reservedSell(x, bps);
        uint160 limit = nearLimit(zeroForOneFor(buy), sqrtBps);
        int256 imdBefore = int256(imd.balanceOf(address(this)));

        swap(buy, buy, x, limit);

        int256 change = int256(imd.balanceOf(address(this))) - imdBefore;
        uint256 refund = claims(address(this));
        uint256 kept = hook.pending();
        uint256 moved = buy ? uint256(-change) - kept - refund : uint256(change + int256(reserved));
        assertLe(moved, expected);
        assertEq(kept + refund, reserved);
        if (moved >= expected) assertEq(refund, 0);
        else assertEq(kept, (reserved * moved) / expected);
        assertLe(kept, (moved * bps) / BPS + 2, "never more than the fee rate on what filled");
    }

    // ------------------------------------------------------------------ launch-like seeding

    function test_firstBuyOnATokenOnlyPoolAccruesWithoutAnyImdInTheManager() public {
        seedTokenOnly();
        uint256 x = 1000 ether;
        (uint256 reserved,) = reservedBuy(x, hook.feeNow());

        swap(true, true, x, 0);

        assertEq(hook.pending(), reserved);
        assertEq(imd.balanceOf(address(manager)), x, "the swapper's IMD now backs the claim");

        // Exact-output buy and both sells work on the same pool.
        swap(true, false, 10 ether, 0);
        swap(false, true, 10 ether, 0);
        swap(false, false, 1 ether, 0);
        assertGt(hook.pending(), reserved);

        // And the accrued fee reaches the treasury.
        uint256 due = hook.pending();
        vm.prank(alice);
        hook.sweep();
        assertEq(imd.balanceOf(TREASURY), due);
    }

    function test_buyOnATokenOnlyPoolWithAPriceLimitRefundsInClaims() public {
        seedTokenOnly();
        uint160 limit = nearLimit(zeroForOneFor(true), 50);
        swap(true, true, 50_000 ether, limit);
        assertGt(claims(address(this)), 0);
        assertGt(hook.pending(), 0);
    }

    // ------------------------------------------------------------------ sweep

    function test_sweepDeliversEverythingToTheTreasury() public {
        seedBothSides();
        swap(true, true, 1000 ether, 0);
        swap(false, true, 500 ether, 0);
        uint256 due = hook.pending();
        assertGt(due, 0);
        assertEq(hook.collected(), due);

        vm.expectEmit(true, true, true, true, address(hook));
        emit Swept(alice, TREASURY, due);
        vm.prank(alice);
        uint256 amount = hook.sweep();

        assertEq(amount, due);
        assertEq(imd.balanceOf(TREASURY), due);
        assertEq(hook.pending(), 0);
        assertEq(hook.swept(), due);
        assertEq(hook.collected(), due);
        assertEq(manager.balanceOf(address(hook), Currency.wrap(address(imd)).toId()), 0);
    }

    function test_sweepRevertsWhenNothingIsPending() public {
        vm.expectRevert(SNEWTHook.NothingToSweep.selector);
        hook.sweep();
        seedBothSides();
        vm.expectRevert(SNEWTHook.NothingToSweep.selector);
        hook.sweep();
        swap(true, true, 1 ether, 0);
        hook.sweep();
        vm.expectRevert(SNEWTHook.NothingToSweep.selector);
        hook.sweep();
    }

    function test_sweepAccumulatesAcrossRounds() public {
        seedBothSides();
        swap(true, true, 100 ether, 0);
        uint256 first = hook.sweep();
        swap(false, true, 100 ether, 0);
        swap(true, false, 100 ether, 0);
        uint256 second = hook.sweep();
        assertEq(imd.balanceOf(TREASURY), first + second);
        assertEq(hook.swept(), first + second);
        assertEq(hook.collected(), first + second);
        assertEq(hook.pending(), 0);
    }

    function test_sweepCannotRunInsideAnotherUnlock() public {
        seedBothSides();
        swap(true, true, 100 ether, 0);
        ReentrantSweeper attacker = new ReentrantSweeper(manager, hook);
        vm.expectRevert();
        attacker.attack();
        assertGt(hook.pending(), 0);
    }

    function test_claimsSentToTheHookAreSweptToo() public {
        seedBothSides();
        swap(true, true, 100 ether, 0);
        // A partial fill leaves the swapper with a refund claim; a donor could hand claims to the hook.
        swap(true, true, 10_000 ether, nearLimit(zeroForOneFor(true), 5));
        uint256 gift = claims(address(this));
        assertGt(gift, 0);
        manager.transfer(address(hook), Currency.wrap(address(imd)).toId(), gift);
        assertEq(hook.pending(), hook.collected() + gift);
        hook.sweep();
        assertEq(imd.balanceOf(TREASURY), hook.collected() + gift);
        assertEq(hook.pending(), 0);
    }

    // ------------------------------------------------------------------ accepted revert domain

    function test_hugeExactOutputSellRevertsUnrepresentableFee() public {
        seedBothSides();
        bool zeroForOne = zeroForOneFor(false);
        vm.expectRevert(wrapped(IHooks.beforeSwap.selector, SNEWTHook.UnrepresentableFee.selector));
        swapRouter.swap(key, SwapParams(zeroForOne, type(int256).max, fullLimit(zeroForOne)));
    }

    function test_hugeExactInputBuyRevertsUnrepresentableFee() public {
        seedBothSides();
        bool zeroForOne = zeroForOneFor(true);
        vm.expectRevert(wrapped(IHooks.beforeSwap.selector, SNEWTHook.UnrepresentableFee.selector));
        swapRouter.swap(key, SwapParams(zeroForOne, type(int256).min, fullLimit(zeroForOne)));
        vm.expectRevert(wrapped(IHooks.beforeSwap.selector, SNEWTHook.UnrepresentableFee.selector));
        swapRouter.swap(key, SwapParams(zeroForOne, -int256(uint256(type(uint128).max) + 1), fullLimit(zeroForOne)));
    }

    function test_sellExactOutputJustBelowTheInt128LimitStillReservesOrRevertsCleanly() public {
        seedBothSides();
        bool zeroForOne = zeroForOneFor(false);
        // gross = x + ceil(x * 0.4 / 0.6) overflows int128 for x near 2^127: the hook says so itself.
        uint256 x = uint256(uint128(type(int128).max));
        vm.expectRevert(wrapped(IHooks.beforeSwap.selector, SNEWTHook.UnrepresentableFee.selector));
        swapRouter.swap(key, SwapParams(zeroForOne, int256(x), fullLimit(zeroForOne)));
    }

    // ------------------------------------------------------------------ accounting across a random sequence

    /// forge-config: default.fuzz.runs = 64
    function testFuzz_randomSwapSequenceConservesFees(uint256 seed) public {
        seedBothSides();
        imd.mint(alice, 1e24);
        token.transfer(alice, 1e24);
        uint256 treasuryTotal;
        for (uint256 i = 0; i < 12; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            bool buy = r & 1 == 1;
            bool exactInput = (r >> 1) & 1 == 1;
            uint256 amount = bound(r >> 8, 1, 5000 ether);
            uint160 limit = (r >> 2) & 3 == 0 ? nearLimit(zeroForOneFor(buy), uint16(bound(r >> 64, 1, 300))) : 0;
            // A near limit must lie beyond the current price in the swap's direction.
            if (limit != 0) {
                bool zfo = zeroForOneFor(buy);
                uint160 p = sqrtPrice();
                if ((zfo && limit >= p) || (!zfo && limit <= p)) limit = 0;
            }
            vm.warp(block.timestamp + bound(r >> 128, 0, 10 minutes));
            address who = (r >> 3) & 1 == 1 ? alice : address(this);
            if (who == alice) swapAs(alice, buy, exactInput, amount, limit);
            else swap(buy, exactInput, amount, limit);

            assertEq(hook.pending(), hook.collected() - hook.swept(), "pending == collected - swept");
            assertLe(hook.pending(), imd.balanceOf(address(manager)), "claims are backed by IMD in the manager");

            if ((r >> 4) & 7 == 0 && hook.pending() > 0) treasuryTotal += hook.sweep();
        }
        if (hook.pending() > 0) treasuryTotal += hook.sweep();
        assertEq(imd.balanceOf(TREASURY), treasuryTotal);
        assertEq(hook.swept(), hook.collected());
        assertEq(hook.pending(), 0);
    }
}

contract SNEWTHookTokenFirstTest is SNEWTHookTestBase {
    function wantTokenFirst() internal pure override returns (bool) {
        return true;
    }
}

contract SNEWTHookPairedFirstTest is SNEWTHookTestBase {
    function wantTokenFirst() internal pure override returns (bool) {
        return false;
    }
}
