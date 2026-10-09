// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "../vendor/forge-std/src/Test.sol";
import {IPoolManager} from "../vendor/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "../vendor/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "../vendor/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "../vendor/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "../vendor/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "../vendor/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "../vendor/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "../vendor/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "../vendor/v4-core/src/types/PoolOperation.sol";

import {SNEWT} from "../src/SNEWT.sol";
import {SNEWTHook} from "../src/SNEWTHook.sol";
import {HookMiner} from "./utils/HookMiner.sol";
import {SwapRouter, LiquidityRouter} from "./utils/Routers.sol";
import {DeltaSettlementRouter, RefundClaimRedeemer} from "./utils/DeltaSettlementRouter.sol";

interface IERC20Meta {
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

/// @notice Fork rehearsal on Robinhood Chain against the real PoolManager and the real IMD token.
/// @dev Runs only when ROBINHOOD_RPC_URL is set (https://rpc.mainnet.chain.robinhood.com); the
///      verifier has no network, so without it every test here is skipped, never passed.
///      This test contract stands in for the launch factory: it deploys SNEWT and the hook,
///      initializes the pool and seeds it. IMD is dealt with a storage write.
contract SNEWTHookForkTest is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    uint256 constant ROBINHOOD_CHAIN_ID = 4663;
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address constant TREASURY = 0x5F948c351EB9F0734C28B605BbeEe9AB9d04318E;
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 constant FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
    uint256 constant BPS = 10_000;
    uint256 constant LIQUIDITY = 100_000 ether;

    IPoolManager manager = IPoolManager(POOL_MANAGER);
    IERC20Meta imd = IERC20Meta(IMD);
    SNEWT token;
    SNEWTHook hook;
    SwapRouter swapRouter;
    LiquidityRouter lpRouter;
    PoolKey key;
    PoolId poolId;
    bool tokenIs0;

    function setUp() public {
        string memory url = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(url);
        assertEq(block.chainid, ROBINHOOD_CHAIN_ID, "not Robinhood Chain");
        assertGt(POOL_MANAGER.code.length, 0, "no PoolManager at the launch address");
        assertEq(imd.symbol(), "IMD");
        assertEq(imd.decimals(), 18);

        token = new SNEWT();
        tokenIs0 = address(token) < IMD;
        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), FLAGS, type(SNEWTHook).creationCode, abi.encode(manager, address(token)));
        hook = new SNEWTHook{salt: salt}(manager, address(token));
        assertEq(address(hook), predicted);

        key = PoolKey({
            currency0: Currency.wrap(tokenIs0 ? address(token) : IMD),
            currency1: Currency.wrap(tokenIs0 ? IMD : address(token)),
            fee: 12_500,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        poolId = key.toId();

        swapRouter = new SwapRouter(manager);
        lpRouter = new LiquidityRouter(manager);
        deal(IMD, address(this), 1_000_000 ether);
        token.approve(address(swapRouter), type(uint256).max);
        token.approve(address(lpRouter), type(uint256).max);
        imd.approve(address(swapRouter), type(uint256).max);
        imd.approve(address(lpRouter), type(uint256).max);
    }

    function openAndSeed() internal {
        manager.initialize(key, SQRT_PRICE_1_1);
        lpRouter.modifyLiquidity(key, ModifyLiquidityParams(-887_220, 887_220, int256(LIQUIDITY), bytes32(0)));
    }

    function swap(bool buy, bool exactInput, uint256 amount, uint160 limit) internal {
        bool zeroForOne = buy ? !tokenIs0 : tokenIs0;
        if (limit == 0) limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        swapRouter.swap(key, SwapParams(zeroForOne, exactInput ? -int256(amount) : int256(amount), limit));
    }

    function nearLimit(bool zeroForOne, uint256 sqrtBps) internal pure returns (uint160) {
        uint256 step = (uint256(SQRT_PRICE_1_1) * sqrtBps) / BPS;
        return uint160(zeroForOne ? SQRT_PRICE_1_1 - step : SQRT_PRICE_1_1 + step);
    }

    function test_fork_permissionBitsMatchTheMinedAddress() public view {
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, FLAGS);
        Hooks.validateHookPermissions(IHooks(address(hook)), hook.getHookPermissions());
        assertEq(address(hook.poolManager()), POOL_MANAGER);
    }

    function test_fork_initializeOnTheRealPoolManager() public {
        manager.initialize(key, SQRT_PRICE_1_1);
        assertEq(hook.openedAt(), block.timestamp);
        assertEq(Currency.unwrap(hook.paired()), IMD);
        (uint160 price,,, uint24 fee) = manager.getSlot0(poolId);
        assertEq(price, SQRT_PRICE_1_1);
        assertEq(fee, 12_500);
    }

    function test_fork_buyExactInputThroughTheRealPoolManager() public {
        openAndSeed();
        uint256 x = 100 ether;
        uint256 bps = hook.feeNow();
        uint256 net = (x * BPS) / (BPS + bps);
        uint256 before = imd.balanceOf(address(this));
        swap(true, true, x, 0);
        assertEq(before - imd.balanceOf(address(this)), x);
        assertEq(hook.pending(), x - net);
    }

    function test_fork_buyExactOutputThroughTheRealPoolManager() public {
        openAndSeed();
        uint256 bps = hook.feeNow();
        uint256 before = imd.balanceOf(address(this));
        uint256 tokBefore = token.balanceOf(address(this));
        swap(true, false, 100 ether, 0);
        assertEq(token.balanceOf(address(this)) - tokBefore, 100 ether);
        uint256 paid = before - imd.balanceOf(address(this));
        uint256 fee = hook.pending();
        assertEq(fee, ((paid - fee) * bps) / BPS);
    }

    function test_fork_sellExactInputThroughTheRealPoolManager() public {
        openAndSeed();
        uint256 bps = hook.feeNow();
        uint256 before = imd.balanceOf(address(this));
        swap(false, true, 100 ether, 0);
        uint256 received = imd.balanceOf(address(this)) - before;
        uint256 fee = hook.pending();
        assertEq(fee, ((received + fee) * bps) / BPS);
    }

    function test_fork_sellExactOutputThroughTheRealPoolManager() public {
        openAndSeed();
        uint256 x = 100 ether;
        uint256 bps = hook.feeNow();
        uint256 d = BPS - bps;
        uint256 before = imd.balanceOf(address(this));
        swap(false, false, x, 0);
        assertEq(imd.balanceOf(address(this)) - before, x);
        assertEq(hook.pending(), (x * bps + d - 1) / d);
    }

    function test_fork_partialFillsRefundTheUnfilledFee() public {
        openAndSeed();
        uint256 id = Currency.wrap(IMD).toId();
        // Exact-input buy stopped by a price limit.
        swap(true, true, 10_000 ether, nearLimit(!tokenIs0, 5));
        uint256 refund = manager.balanceOf(address(this), id);
        assertGt(refund, 0, "exact-input partial fill refunded a claim");
        // Exact-output sell stopped by a price limit, back across the opening price.
        swap(false, false, 10_000 ether, nearLimit(tokenIs0, 5));
        assertGt(manager.balanceOf(address(this), id), refund, "exact-output partial fill refunded a claim");
    }

    function test_fork_sweepPaysTheTreasuryInImd() public {
        openAndSeed();
        vm.warp(block.timestamp + 61 minutes);
        assertEq(hook.feeNow(), 300);
        swap(true, true, 100 ether, 0);
        swap(false, true, 50 ether, 0);
        uint256 due = hook.pending();
        uint256 treasuryBefore = imd.balanceOf(TREASURY);
        hook.sweep();
        assertEq(imd.balanceOf(TREASURY) - treasuryBefore, due);
        assertEq(hook.pending(), 0);
        assertEq(hook.swept(), due);
    }

    function test_fork_directRefundsNeedNoRouterClaimsSupport() public {
        openAndSeed();
        DeltaSettlementRouter router = new DeltaSettlementRouter(manager);
        token.approve(address(router), type(uint256).max);
        imd.approve(address(router), type(uint256).max);
        uint256 id = Currency.wrap(IMD).toId();
        uint256 x = 10_000 ether;
        uint256 bps = hook.feeNow();
        uint256 before = imd.balanceOf(address(this));
        uint256 reserved = x - x * BPS / (BPS + bps);

        router.swap(
            key,
            SwapParams(!tokenIs0, -int256(x), nearLimit(!tokenIs0, 5)),
            abi.encode(address(this)),
            100_000 ether,
            100_000 ether
        );

        uint256 paid = before - imd.balanceOf(address(this));
        uint256 refund = manager.balanceOf(address(this), id);
        uint256 moved = paid - reserved;
        assertGt(refund, 0);
        assertEq(manager.balanceOf(address(router), id), 0);
        assertLe(paid - refund, moved + moved * bps / BPS + 2);

        before = imd.balanceOf(address(this));
        uint256 oldFee = hook.pending();
        reserved = (x * bps + BPS - bps - 1) / (BPS - bps);
        router.swap(
            key,
            SwapParams(tokenIs0, int256(x), nearLimit(tokenIs0, 5)),
            abi.encode(address(this)),
            100_000 ether,
            100_000 ether
        );

        uint256 newRefund = manager.balanceOf(address(this), id) - refund;
        int256 change = int256(imd.balanceOf(address(this))) - int256(before);
        moved = uint256(change + int256(reserved));
        uint256 fee = hook.pending() - oldFee;
        assertGt(newRefund, 0);
        assertEq(manager.balanceOf(address(router), id), 0);
        assertEq(newRefund + fee, reserved);
        assertLe(fee, moved * bps / BPS + 2);
        assertEq(change + int256(newRefund), int256(moved - fee));
        redeemRefundAfterSweep(refund + newRefund);
    }

    function redeemRefundAfterSweep(uint256 refund) internal {
        uint256 due = hook.pending();
        uint256 treasuryBefore = imd.balanceOf(TREASURY);
        hook.sweep();
        assertEq(imd.balanceOf(TREASURY) - treasuryBefore, due);
        assertEq(hook.pending(), 0);
        assertEq(manager.balanceOf(address(this), Currency.wrap(IMD).toId()), refund);

        RefundClaimRedeemer redeemer = new RefundClaimRedeemer(manager);
        uint256 before = imd.balanceOf(address(this));
        manager.approve(address(redeemer), Currency.wrap(IMD).toId(), refund);
        redeemer.redeem(Currency.wrap(IMD), refund);
        assertEq(imd.balanceOf(address(this)) - before, refund, "real IMD backs the direct refund");
        assertEq(manager.balanceOf(address(this), Currency.wrap(IMD).toId()), 0);
        assertEq(hook.collected(), due, "redeeming a user refund does not change fee accounting");
    }
}
