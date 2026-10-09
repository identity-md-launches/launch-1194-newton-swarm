// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "../../vendor/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "../../vendor/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IERC20Minimal} from "../../vendor/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {PoolKey} from "../../vendor/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "../../vendor/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "../../vendor/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "../../vendor/v4-core/src/types/PoolOperation.sol";

/// @dev Test fixture that only settles ERC-20 deltas and passes hookData through. It never reads,
///      burns or transfers ERC-6909 claims. Funds are pulled from msg.sender at entry, and unused
///      ERC-20s and swap outputs are returned after the unlock. Not a production router.
contract DeltaSettlementRouter is IUnlockCallback {
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function swap(PoolKey memory key, SwapParams memory params, bytes memory hookData, uint256 budget0, uint256 budget1)
        external
        returns (BalanceDelta delta)
    {
        _pull(key.currency0, budget0);
        _pull(key.currency1, budget1);
        delta = abi.decode(manager.unlock(abi.encode(key, params, hookData)), (BalanceDelta));
        _returnBalance(key.currency0);
        _returnBalance(key.currency1);
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        (PoolKey memory key, SwapParams memory params, bytes memory hookData) =
            abi.decode(raw, (PoolKey, SwapParams, bytes));
        BalanceDelta delta = manager.swap(key, params, hookData);
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return abi.encode(delta);
    }

    function _pull(Currency currency, uint256 amount) private {
        if (amount != 0) {
            require(IERC20Minimal(Currency.unwrap(currency)).transferFrom(msg.sender, address(this), amount));
        }
    }

    function _returnBalance(Currency currency) private {
        uint256 amount = currency.balanceOfSelf();
        if (amount != 0) currency.transfer(msg.sender, amount);
    }

    function _settle(Currency currency, int128 amount) private {
        if (amount < 0) {
            manager.sync(currency);
            currency.transfer(address(manager), uint256(-int256(amount)));
            manager.settle();
        } else if (amount > 0) {
            manager.take(currency, address(this), uint256(int256(amount)));
        }
    }
}

/// @dev A separate test fixture to show the holder can redeem a refund without the swap router.
contract RefundClaimRedeemer is IUnlockCallback {
    using CurrencyLibrary for Currency;

    IPoolManager immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function redeem(Currency currency, uint256 amount) external {
        manager.unlock(abi.encode(msg.sender, currency, amount));
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        (address holder, Currency currency, uint256 amount) = abi.decode(raw, (address, Currency, uint256));
        manager.burn(holder, currency.toId(), amount);
        manager.take(currency, holder, amount);
        return "";
    }
}
