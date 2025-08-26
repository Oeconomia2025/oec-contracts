// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/**
 * @title Multi-Pool Staking (Fixed APR + Early Withdraw Penalties) — FOT-friendly
 * @notice Each pool pays a fixed APR (basis points) per staked token, independent of TVL.
 *         Pools enforce a lock period; users may:
 *           - withdraw() after lock (no penalty, rewards paid)
 *           - earlyWithdraw() before lock (penalty on principal, rewards forfeited)
 *           - emergencyWithdraw() anytime (no penalty, rewards forfeited; true break-glass)
 *         Owner can add pools with (stakingToken, rewardsToken, aprBps, lockPeriod).
 *         APR accrual per token per second = (aprBps/10000)/SECONDS_PER_YEAR * 1e18.
 *         Contract must hold enough rewardsToken or getReward() will revert.
 *
 *         Security hardening:
 *           - SafeERC20 for robust token interactions
 *           - Pausable (stake/withdraw/getReward can be paused; emergencyWithdraw stays open)
 *           - Caps on APR and lock period
 *           - Cannot recover any pool's staking/reward tokens
 *           - Enforces 18-decimal tokens (both stake & reward) — simplifies math
 *
 *         Fee-on-transfer (FOT) support:
 *           - On stake: user credited by net tokens actually received by the contract
 *           - On withdraw/early/emergency: contract transfers the requested amount; recipient
 *             may receive less due to token fees (expected behavior for FOT tokens)
 */

import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v5.0.2/contracts/token/ERC20/IERC20.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v5.0.2/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v5.0.2/contracts/token/ERC20/utils/SafeERC20.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v5.0.2/contracts/access/Ownable.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v5.0.2/contracts/utils/ReentrancyGuard.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v5.0.2/contracts/utils/Pausable.sol";

contract MultiPoolStakingAPR is ReentrancyGuard, Ownable, Pausable {
    using SafeERC20 for IERC20;

    uint256 private constant SECONDS_PER_YEAR = 365 days;
    uint256 private constant WAD = 1e18;

    // Admin-configurable safety caps (tune as desired)
    uint256 private constant MAX_APR_BPS  = 5000;     // 50% APR cap
    uint256 private constant MAX_LOCK_SEC = 365 days; // 1 year cap

    struct Pool {
        IERC20 stakingToken;                 // token users deposit
        IERC20 rewardsToken;                 // token paid as rewards
        uint256 aprBps;                      // APR in basis points (e.g., 1000 = 10%)
        uint256 lockPeriod;                  // seconds user must wait since last deposit before normal withdraw
        uint256 totalSupply;                 // total staked (credited amount, net of FOT on deposit)
        uint256 lastUpdateTime;              // last time rewardPerTokenStored updated
        uint256 rewardPerTokenStored;        // per-token accumulator (scaled by 1e18)

        mapping(address => uint256) balances;                // user => staked amount (credited)
        mapping(address => uint256) userRewardPerTokenPaid;  // user => snapshot of RPT
        mapping(address => uint256) rewards;                 // user => accrued but unclaimed
        mapping(address => uint256) depositTimestamps;       // user => last deposit ts (for lock)
    }

    uint256 public poolCount;
    mapping(uint256 => Pool) private pools;

    // ---- Early-withdraw penalties ----
    address public penaltyRecipient;                         // where principal penalties are sent
    mapping(uint256 => uint256) public earlyPenaltyBps;      // per-pool penalty (basis points); capped <= 50%

    // -------- Events --------
    event PoolCreated(uint256 indexed poolId, address stakingToken, address rewardsToken, uint256 aprBps, uint256 lockPeriod);
    event PoolUpdated(uint256 indexed poolId, uint256 aprBps, uint256 lockPeriod);
    event Staked(uint256 indexed poolId, address indexed user, uint256 creditedAmount);
    event Withdrawn(uint256 indexed poolId, address indexed user, uint256 amount);
    event RewardPaid(uint256 indexed poolId, address indexed user, uint256 reward);
    event EmergencyWithdraw(uint256 indexed poolId, address indexed user, uint256 amount);
    event EarlyWithdrawWithPenalty(uint256 indexed poolId, address indexed user, uint256 amount, uint256 penalty);
    event Recovered(address token, uint256 amount);
    event PenaltyRecipientUpdated(address to);
    event EarlyPenaltyBpsUpdated(uint256 indexed poolId, uint256 bps);

    constructor() Ownable(msg.sender) {
        penaltyRecipient = msg.sender;
    }

    // -------- Modifiers --------
    modifier poolExists(uint256 poolId) {
        require(poolId < poolCount, "Invalid pool");
        _;
    }

    // -------- Owner: Pool management --------
    function addPool(
        address _stakingToken,
        address _rewardsToken,
        uint256 _aprBps,
        uint256 _lockPeriod
    ) external onlyOwner {
        require(_stakingToken != address(0) && _rewardsToken != address(0), "Invalid token");
        require(_aprBps <= MAX_APR_BPS, "APR too high");
        require(_lockPeriod <= MAX_LOCK_SEC, "Lock too long");

        // enforce 18 decimals (simplifies math)
        require(IERC20Metadata(_stakingToken).decimals() == 18, "stake token not 18d");
        require(IERC20Metadata(_rewardsToken).decimals() == 18, "reward token not 18d");

        uint256 poolId = poolCount++;
        Pool storage p = pools[poolId];
        p.stakingToken    = IERC20(_stakingToken);
        p.rewardsToken    = IERC20(_rewardsToken);
        p.aprBps          = _aprBps;
        p.lockPeriod      = _lockPeriod;
        p.lastUpdateTime  = block.timestamp;

        emit PoolCreated(poolId, _stakingToken, _rewardsToken, _aprBps, _lockPeriod);
    }

    function setAprBps(uint256 poolId, uint256 _aprBps) external onlyOwner poolExists(poolId) {
        require(_aprBps <= MAX_APR_BPS, "APR too high");
        _updateReward(poolId, address(0));
        pools[poolId].aprBps = _aprBps;
        emit PoolUpdated(poolId, _aprBps, pools[poolId].lockPeriod);
    }

    function setLockPeriod(uint256 poolId, uint256 _lockPeriod) external onlyOwner poolExists(poolId) {
        require(_lockPeriod <= MAX_LOCK_SEC, "Lock too long");
        pools[poolId].lockPeriod = _lockPeriod;
        emit PoolUpdated(poolId, pools[poolId].aprBps, _lockPeriod);
    }

    // ---- Penalty config ----
    function setPenaltyRecipient(address _to) external onlyOwner {
        require(_to != address(0), "bad recipient");
        penaltyRecipient = _to;
        emit PenaltyRecipientUpdated(_to);
    }

    function setEarlyPenaltyBps(uint256 poolId, uint256 bps) external onlyOwner poolExists(poolId) {
        require(bps <= 5000, "max 50%");
        earlyPenaltyBps[poolId] = bps;
        emit EarlyPenaltyBpsUpdated(poolId, bps);
    }

    // -------- Views --------
    function getPoolInfo(uint256 poolId)
        external
        view
        poolExists(poolId)
        returns (
            address stakingToken,
            address rewardsToken,
            uint256 aprBps,
            uint256 lockPeriod,
            uint256 totalSupply,
            uint256 lastUpdateTime,
            uint256 rewardPerTokenStored
        )
    {
        Pool storage p = pools[poolId];
        return (
            address(p.stakingToken),
            address(p.rewardsToken),
            p.aprBps,
            p.lockPeriod,
            p.totalSupply,
            p.lastUpdateTime,
            p.rewardPerTokenStored
        );
    }

    function balanceOf(uint256 poolId, address account) external view poolExists(poolId) returns (uint256) {
        return pools[poolId].balances[account];
    }

    function rewardPerToken(uint256 poolId) public view poolExists(poolId) returns (uint256) {
        Pool storage p = pools[poolId];
        uint256 rpt = p.rewardPerTokenStored;
        if (p.lastUpdateTime == 0) return rpt;
        uint256 timeDelta = block.timestamp - p.lastUpdateTime;
        if (timeDelta == 0) return rpt;

        // Fixed APR per token:
        // per-token-per-second rate (WAD) = (aprBps / 10000) / SECONDS_PER_YEAR * 1e18
        uint256 aprPerSecondWad = (p.aprBps * WAD) / 10000 / SECONDS_PER_YEAR;
        return rpt + (timeDelta * aprPerSecondWad);
    }

    function earned(uint256 poolId, address account) public view poolExists(poolId) returns (uint256) {
        Pool storage p = pools[poolId];
        uint256 rpt = rewardPerToken(poolId);
        return ((p.balances[account] * (rpt - p.userRewardPerTokenPaid[account])) / WAD) + p.rewards[account];
    }

    // -------- Core accounting --------
    function _updateReward(uint256 poolId, address account) internal {
        Pool storage p = pools[poolId];
        p.rewardPerTokenStored = rewardPerToken(poolId);
        p.lastUpdateTime = block.timestamp;
        if (account != address(0)) {
            p.rewards[account] = earned(poolId, account);
            p.userRewardPerTokenPaid[account] = p.rewardPerTokenStored;
        }
    }

    // -------- User actions (FOT-friendly) --------
    function stake(uint256 poolId, uint256 amount) external nonReentrant whenNotPaused poolExists(poolId) {
        require(amount > 0, "Cannot stake 0");
        Pool storage p = pools[poolId];

        _updateReward(poolId, msg.sender);

        // Credit by actual tokens received (supports fee-on-transfer)
        uint256 beforeBal = p.stakingToken.balanceOf(address(this));
        p.stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = p.stakingToken.balanceOf(address(this)) - beforeBal;
        require(received > 0, "No tokens received");

        p.totalSupply += received;
        p.balances[msg.sender] += received;
        p.depositTimestamps[msg.sender] = block.timestamp; // resets lock for entire position

        emit Staked(poolId, msg.sender, received);
    }

    function withdraw(uint256 poolId, uint256 amount) public nonReentrant whenNotPaused poolExists(poolId) {
        require(amount > 0, "Cannot withdraw 0");
        Pool storage p = pools[poolId];

        require(p.balances[msg.sender] >= amount, "Withdraw exceeds balance");
        require(block.timestamp >= p.depositTimestamps[msg.sender] + p.lockPeriod, "Lock not over");

        _updateReward(poolId, msg.sender);

        p.totalSupply -= amount;
        p.balances[msg.sender] -= amount;

        // Recipient may receive less due to token's transfer fee
        p.stakingToken.safeTransfer(msg.sender, amount);

        emit Withdrawn(poolId, msg.sender, amount);
    }

    function earlyWithdraw(uint256 poolId, uint256 amount) external nonReentrant whenNotPaused poolExists(poolId) {
        require(amount > 0, "Cannot withdraw 0");
        Pool storage p = pools[poolId];

        require(p.balances[msg.sender] >= amount, "Exceeds balance");
        require(block.timestamp < p.depositTimestamps[msg.sender] + p.lockPeriod, "Lock over; use withdraw()");

        _updateReward(poolId, msg.sender); // sync accounting

        uint256 bps = earlyPenaltyBps[poolId];
        uint256 penalty = (amount * bps) / 10000;
        uint256 payout = amount - penalty;

        // Update state before external calls
        p.totalSupply -= amount;
        p.balances[msg.sender] -= amount;

        // Forfeit accrued rewards on early exit (after update)
        p.rewards[msg.sender] = 0;

        // Transfers: both subject to token fees, which is expected behavior
        if (payout > 0) p.stakingToken.safeTransfer(msg.sender, payout);
        if (penalty > 0) p.stakingToken.safeTransfer(penaltyRecipient, penalty);

        emit EarlyWithdrawWithPenalty(poolId, msg.sender, amount, penalty);
    }

    function getReward(uint256 poolId) public nonReentrant whenNotPaused poolExists(poolId) {
        _updateReward(poolId, msg.sender);

        Pool storage p = pools[poolId];
        uint256 reward = p.rewards[msg.sender];
        if (reward > 0) {
            p.rewards[msg.sender] = 0;
            // If rewardsToken is FOT, user may receive net-of-fee. We pay the full booked reward amount.
            p.rewardsToken.safeTransfer(msg.sender, reward);
            emit RewardPaid(poolId, msg.sender, reward);
        }
    }

    function exit(uint256 poolId) external nonReentrant {
        withdraw(poolId, pools[poolId].balances[msg.sender]);
        getReward(poolId);
    }

    /**
     * @notice Emergency exit: returns staked tokens immediately, forfeits rewards. Ignores lock.
     *         Always available even if paused. Recipient may receive net-of-fee for FOT tokens.
     */
    function emergencyWithdraw(uint256 poolId) external nonReentrant poolExists(poolId) {
        Pool storage p = pools[poolId];
        uint256 staked = p.balances[msg.sender];
        require(staked > 0, "Nothing to withdraw");

        // Reset before external call
        p.totalSupply -= staked;
        p.balances[msg.sender] = 0;
        p.rewards[msg.sender] = 0;

        p.stakingToken.safeTransfer(msg.sender, staked);

        emit EmergencyWithdraw(poolId, msg.sender, staked);
    }

    // -------- Admin pause controls --------
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    /**
     * @notice Owner can recover tokens that are NOT used as a staking or rewards token in any pool.
     *         Cannot withdraw users' staked funds or pool reward funds.
     */
    function recoverERC20(address tokenAddress, uint256 tokenAmount) external onlyOwner {
        for (uint256 i = 0; i < poolCount; i++) {
            require(
                tokenAddress != address(pools[i].stakingToken) &&
                tokenAddress != address(pools[i].rewardsToken),
                "Cannot recover pool tokens"
            );
        }
        IERC20(tokenAddress).safeTransfer(owner(), tokenAmount);
        emit Recovered(tokenAddress, tokenAmount);
    }
}
