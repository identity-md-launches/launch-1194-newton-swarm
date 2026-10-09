// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "../../vendor/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "../../vendor/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "../../vendor/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "../../vendor/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "../../vendor/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "../../vendor/v4-core/src/types/PoolOperation.sol";

interface IERC20Minimal {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice Shared settlement for the minimal test routers: pays what the caller owes from the
///         caller's balance (pulled with transferFrom) and takes what the caller is owed to them.
///         Any ERC-6909 claims the router received during the action (a hook refund) are forwarded
///         to the caller, which is what a well-behaved router would do.
abstract contract BaseRouter is IUnlockCallback {
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    IPoolManager public immutable manager;

    error NotManager();

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function _settleAll(address payer, PoolKey memory key, BalanceDelta delta) internal {
        _settleOne(payer, key.currency0, delta.amount0());
        _settleOne(payer, key.currency1, delta.amount1());
        _forwardClaims(payer, key.currency0);
        _forwardClaims(payer, key.currency1);
    }

    function _settleOne(address payer, Currency currency, int128 amount) internal {
        if (amount < 0) {
            uint256 owed = uint256(uint128(-amount));
            manager.sync(currency);
            if (currency.isAddressZero()) {
                manager.settle{value: owed}();
            } else {
                IERC20Minimal(Currency.unwrap(currency)).transferFrom(payer, address(manager), owed);
                manager.settle();
            }
        } else if (amount > 0) {
            manager.take(currency, payer, uint256(uint128(amount)));
        }
    }

    function _forwardClaims(address payer, Currency currency) internal {
        uint256 id = currency.toId();
        uint256 claims = manager.balanceOf(address(this), id);
        if (claims != 0) manager.transfer(payer, id, claims);
    }

    receive() external payable {}
}

/// @notice Swaps through the PoolManager on behalf of msg.sender and returns the swapper's final
///         delta (pool delta net of hook deltas), as the PoolManager reports it.
contract SwapRouter is BaseRouter {
    struct Data {
        address payer;
        PoolKey key;
        SwapParams params;
    }

    constructor(IPoolManager manager_) BaseRouter(manager_) {}

    function swap(PoolKey memory key, SwapParams memory params) external payable returns (BalanceDelta delta) {
        bytes memory result = manager.unlock(abi.encode(Data({payer: msg.sender, key: key, params: params})));
        delta = abi.decode(result, (BalanceDelta));
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert NotManager();
        Data memory data = abi.decode(raw, (Data));
        BalanceDelta delta = manager.swap(data.key, data.params, "");
        _settleAll(data.payer, data.key, delta);
        return abi.encode(delta);
    }
}

/// @notice Adds or removes liquidity on behalf of msg.sender.
contract LiquidityRouter is BaseRouter {
    struct Data {
        address payer;
        PoolKey key;
        ModifyLiquidityParams params;
    }

    constructor(IPoolManager manager_) BaseRouter(manager_) {}

    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params)
        external
        payable
        returns (BalanceDelta delta)
    {
        bytes memory result = manager.unlock(abi.encode(Data({payer: msg.sender, key: key, params: params})));
        delta = abi.decode(result, (BalanceDelta));
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert NotManager();
        Data memory data = abi.decode(raw, (Data));
        (BalanceDelta delta,) = manager.modifyLiquidity(data.key, data.params, "");
        _settleAll(data.payer, data.key, delta);
        return abi.encode(delta);
    }
}
