// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Hooks} from "../../vendor/v4-core/src/libraries/Hooks.sol";

/// @notice Mines a CREATE2 salt so that a hook lands on an address carrying exactly `flags`,
///         the way the launch deployer does. Local copy of v4-periphery's HookMiner.
library HookMiner {
    uint160 internal constant FLAG_MASK = Hooks.ALL_HOOK_MASK;
    uint256 internal constant MAX_LOOP = 200_000;

    /// @param deployer The address that will CREATE2 the hook.
    /// @param flags The hook flags the address must carry (all 14 bits are compared).
    /// @param creationCode The contract's creation code.
    /// @param constructorArgs ABI-encoded constructor arguments.
    /// @return hookAddress The mined address.
    /// @return salt The salt that produces it.
    function find(address deployer, uint160 flags, bytes memory creationCode, bytes memory constructorArgs)
        internal
        pure
        returns (address hookAddress, bytes32 salt)
    {
        flags = flags & FLAG_MASK;
        bytes32 initCodeHash = keccak256(abi.encodePacked(creationCode, constructorArgs));
        for (uint256 i = 0; i < MAX_LOOP; i++) {
            hookAddress = computeAddress(deployer, bytes32(i), initCodeHash);
            if (uint160(hookAddress) & FLAG_MASK == flags) return (hookAddress, bytes32(i));
        }
        revert("HookMiner: no salt found");
    }

    function computeAddress(address deployer, bytes32 salt, bytes32 initCodeHash) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
    }
}
