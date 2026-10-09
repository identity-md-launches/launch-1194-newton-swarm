// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Newton Swarm (SNEWT)
/// @notice Fixed-supply ERC-20 for the Newton Swarm launch. The whole supply of
///         1,000,000,000 tokens (1e27 minor units, 18 decimals) is minted once to the
///         deployer, which is the IMD launch factory. The factory then seeds the pool,
///         sends the swarm's 10% through its Merkle distributor and forwards any remainder.
/// @dev No owner, no mint, no burn, no pause, no blocklist, no fee on transfer and no
///      upgrade path. Launch fees live in `SNEWTHook`, never in the token.
contract SNEWT {
    string public constant name = "Newton Swarm";
    string public constant symbol = "SNEWT";
    uint8 public constant decimals = 18;

    /// @notice The only supply this token will ever have.
    uint256 public constant totalSupply = 1_000_000_000 ether;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    error InsufficientBalance(uint256 available, uint256 requested);
    error InsufficientAllowance(uint256 available, uint256 requested);
    error ZeroAddress();

    constructor() {
        balanceOf[msg.sender] = totalSupply;
        emit Transfer(address(0), msg.sender, totalSupply);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        if (spender == address(0)) revert ZeroAddress();
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) revert InsufficientAllowance(allowed, amount);
            unchecked {
                allowance[from][msg.sender] = allowed - amount;
            }
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        if (to == address(0)) revert ZeroAddress();
        uint256 available = balanceOf[from];
        if (available < amount) revert InsufficientBalance(available, amount);
        unchecked {
            balanceOf[from] = available - amount;
            // Cannot overflow: the sum of all balances is the fixed supply.
            balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
    }
}
