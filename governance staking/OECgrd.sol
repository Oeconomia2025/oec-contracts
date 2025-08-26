// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

interface IERC20Extended {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);
}

/**
 * @title OECgrd - Governance Token Wrapper for OEC
 * @dev ERC20 token that wraps OEC tokens for governance participation
 * Compatible with Tally governance standards including ERC20Votes
 */
contract OECgrd is ERC20, ERC20Permit, ERC20Votes, ReentrancyGuard, Ownable, Pausable {
    IERC20Extended public immutable oecToken;
    
    // Events
    event Wrapped(address indexed user, uint256 oecAmount, uint256 grdAmount);
    event Unwrapped(address indexed user, uint256 grdAmount, uint256 oecAmount);
    event EmergencyWithdraw(address indexed owner, uint256 amount);
    
    // Errors
    error ZeroAmount();
    error InsufficientBalance();
    error TransferFailed();
    error InvalidToken();
    
    /**
     * @dev Constructor
     * @param _oecToken Address of the OEC token to wrap
     */
    constructor(
        address _oecToken
    ) 
        ERC20("OEC Governance Token", "OECgrd") 
        ERC20Permit("OEC Governance Token")
        Ownable(msg.sender)
    {
        if (_oecToken == address(0)) revert InvalidToken();
        oecToken = IERC20Extended(_oecToken);
    }
    
    /**
     * @dev Wrap OEC tokens to get OECgrd governance tokens
     * @param amount Amount of OEC tokens to wrap
     */
    function wrap(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        
        // Transfer OEC tokens from user to this contract
        bool success = oecToken.transferFrom(msg.sender, address(this), amount);
        if (!success) revert TransferFailed();
        
        // Mint equivalent OECgrd tokens to user
        _mint(msg.sender, amount);
        
        emit Wrapped(msg.sender, amount, amount);
    }
    
    /**
     * @dev Unwrap OECgrd tokens to get back OEC tokens
     * @param amount Amount of OECgrd tokens to unwrap
     */
    function unwrap(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (balanceOf(msg.sender) < amount) revert InsufficientBalance();
        
        // Burn OECgrd tokens from user
        _burn(msg.sender, amount);
        
        // Transfer equivalent OEC tokens back to user
        bool success = oecToken.transfer(msg.sender, amount);
        if (!success) revert TransferFailed();
        
        emit Unwrapped(msg.sender, amount, amount);
    }
    
    /**
     * @dev Get the total amount of OEC tokens held by this contract
     */
    function totalOECBalance() external view returns (uint256) {
        return oecToken.balanceOf(address(this));
    }
    
    /**
     * @dev Emergency function to withdraw OEC tokens (only owner)
     * @param amount Amount to withdraw
     */
    function emergencyWithdraw(uint256 amount) external onlyOwner {
        bool success = oecToken.transfer(msg.sender, amount);
        if (!success) revert TransferFailed();
        
        emit EmergencyWithdraw(msg.sender, amount);
    }
    
    /**
     * @dev Pause the contract (only owner)
     */
    function pause() external onlyOwner {
        _pause();
    }
    
    /**
     * @dev Unpause the contract (only owner)
     */
    function unpause() external onlyOwner {
        _unpause();
    }
    
    // Required overrides for multiple inheritance
    
    function _update(address from, address to, uint256 value)
        internal
        override(ERC20, ERC20Votes)
    {
        super._update(from, to, value);
    }
    
    function nonces(address owner)
        public
        view
        override(ERC20Permit, Nonces)
        returns (uint256)
    {
        return super.nonces(owner);
    }
    
    /**
     * @dev Returns the number of decimals used to get its user representation
     * Matches OEC token decimals for 1:1 wrapping ratio
     */
    function decimals() public view virtual override returns (uint8) {
        try oecToken.decimals() returns (uint8 dec) {
            return dec;
        } catch {
            return 18; // Default fallback
        }
    }
    
    /**
     * @dev Delegate votes to a delegatee
     * @param delegatee Address to delegate votes to
     */
    function delegate(address delegatee) public virtual override {
        _delegate(_msgSender(), delegatee);
    }
    
    /**
     * @dev Delegate votes by signature
     */
    function delegateBySig(
        address delegatee,
        uint256 nonce,
        uint256 expiry,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public virtual override {
        super.delegateBySig(delegatee, nonce, expiry, v, r, s);
    }
}

/**
 * @title Deployment Script Interface
 * @dev Helper interface for deployment parameters
 */
interface IDeploymentHelper {
    struct DeployParams {
        address oecTokenAddress;
        address initialOwner;
    }
}

/**
 * @title OECgrd Factory
 * @dev Factory contract to deploy OECgrd tokens
 */
contract OECgrdFactory {
    event TokenDeployed(address indexed token, address indexed oecToken, address indexed owner);
    
    function deployOECgrd(address oecToken, address owner) external returns (address) {
        OECgrd token = new OECgrd(oecToken);
        if (owner != msg.sender) {
            token.transferOwnership(owner);
        }
        
        emit TokenDeployed(address(token), oecToken, owner);
        return address(token);
    }
}