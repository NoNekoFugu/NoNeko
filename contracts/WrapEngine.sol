// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title WrapEngine v1.3
/// @notice Wraps arbitrary ERC20 tokens, turning noise into meaning.
/// @dev Production-ready minimal implementation with SafeERC20 and DAO recovery lock.

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract WrapEngine is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    mapping(address => uint256) public totalWrapped;
    mapping(address => mapping(address => uint256)) public userBalances;

    bool public recoverLock;

    event Wrapped(address indexed token, address indexed user, uint256 amountIn, uint256 received);
    event Unwrapped(address indexed token, address indexed user, uint256 amount);
    event Recovered(address indexed token, uint256 amount, address indexed to);
    event RecoveryLocked();

    modifier onlyWhenUnlocked() {
        require(!recoverLock, "Recovery locked");
        _;
    }

    /// @notice Wrap any ERC20 token safely
    function wrap(address _token, uint256 _amount) external nonReentrant {
        require(_token != address(0), "Invalid token");
        require(_token.code.length > 0, "Not a contract");
        require(_amount > 0, "Zero amount");

        IERC20 token = IERC20(_token);
        uint256 beforeBal = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), _amount);
        uint256 received = token.balanceOf(address(this)) - beforeBal;

        userBalances[_token][msg.sender] += received;
        totalWrapped[_token] += received;

        emit Wrapped(_token, msg.sender, _amount, received);
    }

    /// @notice Unwrap previously wrapped tokens
    function unwrap(address _token, uint256 _amount) external nonReentrant {
        require(_amount > 0, "Zero amount");
        require(userBalances[_token][msg.sender] >= _amount, "Insufficient balance");

        userBalances[_token][msg.sender] -= _amount;
        totalWrapped[_token] -= _amount;

        IERC20(_token).safeTransfer(msg.sender, _amount);
        emit Unwrapped(_token, msg.sender, _amount);
    }

    /// @notice Optional DAO/owner can recover non-user tokens
    function recover(address _token, address _to) external onlyOwner onlyWhenUnlocked {
        require(_token != address(0), "Invalid token");
        require(_to != address(0), "Invalid address");

        uint256 bal = IERC20(_token).balanceOf(address(this));
        uint256 total = totalWrapped[_token];
        require(bal > total, "No excess to recover");

        uint256 excess = bal - total;
        IERC20(_token).safeTransfer(_to, excess);

        emit Recovered(_token, excess, _to);
    }

    /// @notice Permanently lock recovery for trustless phase
    function lockRecovery() external onlyOwner {
        recoverLock = true;
        emit RecoveryLocked();
    }

    /// @notice Read-only balance check
    function balanceOf(address _token, address _user) external view returns (uint256) {
        return userBalances[_token][_user];
    }
}

Add WrapEngine.sol (core contract)
