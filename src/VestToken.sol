// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title VestToken
/// @notice Plain, fixed-supply ERC-20 ("Vest Demo" / "VDEMO", 18 decimals).
/// @dev The whole supply (1,000,000,000 * 10^18) is minted once to the deployer in the
///      constructor. There is no mint, burn, pause, owner or any other admin function; the
///      supply is constant for the lifetime of the contract.
contract VestToken {
    string public constant name = "Vest Demo";
    string public constant symbol = "VDEMO";
    uint8 public constant decimals = 18;

    /// @notice Total supply minted at construction; never changes afterwards.
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 10 ** 18;

    uint256 public immutable totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    error ERC20InvalidReceiver(address receiver);
    error ERC20InvalidSpender(address spender);
    error ERC20InsufficientBalance(address sender, uint256 balance, uint256 needed);
    error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed);

    constructor() {
        totalSupply = INITIAL_SUPPLY;
        balanceOf[msg.sender] = INITIAL_SUPPLY;
        emit Transfer(address(0), msg.sender, INITIAL_SUPPLY);
    }

    function transfer(address to, uint256 value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        if (spender == address(0)) revert ERC20InvalidSpender(address(0));
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 current = allowance[from][msg.sender];
        if (current != type(uint256).max) {
            if (current < value) revert ERC20InsufficientAllowance(msg.sender, current, value);
            unchecked {
                allowance[from][msg.sender] = current - value;
            }
        }
        _transfer(from, to, value);
        return true;
    }

    function _transfer(address from, address to, uint256 value) internal {
        if (to == address(0)) revert ERC20InvalidReceiver(address(0));
        uint256 fromBalance = balanceOf[from];
        if (fromBalance < value) revert ERC20InsufficientBalance(from, fromBalance, value);
        unchecked {
            balanceOf[from] = fromBalance - value;
            // Cannot overflow: the sum of all balances never exceeds totalSupply.
            balanceOf[to] += value;
        }
        emit Transfer(from, to, value);
    }
}
