// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*
 * DooDoo Butt (DDB) Faucet
 * - 1,000 tokens per wallet per day by default
 * - Uses SafeERC20, Pausable, ReentrancyGuard, Ownable
 * - “EOA only” toggle to reject contract calls (basic anti-bot)
 * - Owner can change amount/cooldown, pause, rescue tokens
 * - Optional fund() helper (pull) or just transfer tokens in
 */

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IERC20Metadata is IERC20 {
    function decimals() external view returns (uint8);
}

contract DDBFaucet is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    IERC20 public immutable token;
    uint8  public immutable tokenDecimals;

    // Amount sent per claim (in smallest units of the token)
    uint256 public amountPerClaim;

    // Cooldown between claims (default: 1 day)
    uint256 public cooldown = 1 days;

    // If true, rejects calls from contracts (basic anti-bot)
    bool public eoaOnly = true;

    // Next eligible claim timestamp per wallet
    mapping(address => uint256) public nextClaimAt;

    event Claimed(address indexed user, uint256 amount, uint256 nextClaimAt);
    event Funded(address indexed from, uint256 amount);
    event AmountUpdated(uint256 newAmount);
    event CooldownUpdated(uint256 newCooldown);
    event EoaOnlyUpdated(bool enabled);

    constructor(address _token, uint256 _amountPerDay) {
        require(_token != address(0), "token=0");
        token = IERC20(_token);
        tokenDecimals = IERC20Metadata(_token).decimals();

        // If _amountPerDay == 0, default to 1,000 * 10^decimals
        amountPerClaim = _amountPerDay == 0
            ? 1000 * (10 ** tokenDecimals)
            : _amountPerDay;

        // Optional: initialize owner as deployer (Ownable default)
    }

    /* ---------------------------- Public actions --------------------------- */

    /// @notice Claim the faucet amount (once per cooldown window)
    function claim() external nonReentrant whenNotPaused {
        if (eoaOnly) {
            // soft protection; not bulletproof but keeps simple bots away
            require(msg.sender == tx.origin, "EOA only");
        }

        uint256 _now = block.timestamp;
        require(_now >= nextClaimAt[msg.sender], "Too soon");

        require(
            token.balanceOf(address(this)) >= amountPerClaim,
            "Faucet empty"
        );

        // set the next time this user can claim again
        nextClaimAt[msg.sender] = _now + cooldown;

        token.safeTransfer(msg.sender, amountPerClaim);
        emit Claimed(msg.sender, amountPerClaim, nextClaimAt[msg.sender]);
    }

    /// @notice Optional pull-based funding (approve + fund)
    function fund(uint256 amount) external nonReentrant {
        require(amount > 0, "amount=0");
        token.safeTransferFrom(msg.sender, address(this), amount);
        emit Funded(msg.sender, amount);
    }

    /* ------------------------------ Owner ops ------------------------------ */

    function setAmountPerClaim(uint256 newAmount) external onlyOwner {
        require(newAmount > 0, "amount=0");
        amountPerClaim = newAmount;
        emit AmountUpdated(newAmount);
    }

    function setCooldown(uint256 newCooldown) external onlyOwner {
        require(newCooldown >= 1 hours && newCooldown <= 7 days, "range");
        cooldown = newCooldown;
        emit CooldownUpdated(newCooldown);
    }

    function setEoaOnly(bool enabled) external onlyOwner {
        eoaOnly = enabled;
        emit EoaOnlyUpdated(enabled);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    /// @notice Rescue tokens stuck in the faucet
    function withdrawTokens(address to, uint256 amount) external onlyOwner {
        require(to != address(0), "to=0");
        token.safeTransfer(to, amount);
    }

    /// @notice Rescue ETH (if any ever sent)
    function withdrawETH(address payable to) external onlyOwner {
        require(to != address(0), "to=0");
        to.transfer(address(this).balance);
    }

    /* ------------------------------- Views -------------------------------- */

    /// @return remaining seconds until the user can claim again (0 if ready)
    function secondsUntilNextClaim(address user) external view returns (uint256) {
        if (block.timestamp >= nextClaimAt[user]) return 0;
        return nextClaimAt[user] - block.timestamp;
    }

    /// @return amount currently claimable by `user`
    function claimable(address user) external view returns (uint256) {
        return block.timestamp >= nextClaimAt[user] ? amountPerClaim : 0;
    }
}
