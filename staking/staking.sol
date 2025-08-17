// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/**
 * @title Multi-Pool Staking (Fixed APR + Early Withdraw Penalties)
 * @notice Each pool pays a fixed APR (basis points) per staked token, independent of TVL.
 *         Pools also enforce a lock period; users may:
 *           - withdraw() after lock (no penalty, rewards paid)
 *           - earlyWithdraw() before lock (penalty on principal, rewards forfeited)
 *           - emergencyWithdraw() anytime (no penalty, rewards forfeited; true break-glass)
 *         Owner can add pools with (stakingToken, rewardsToken, aprBps, lockPeriod).
 *         APR accrual per token per second = (aprBps/10000)/SECONDS_PER_YEAR * 1e18.
 *         Contract must hold enough rewardsToken or getReward() will revert.
 *
 *         Assumes 18-decimal ERC-20s for sensible reward math. If your token uses different
 *         decimals, adapt the math accordingly.
 */

import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v5.0.2/contracts/token/ERC20/IERC20.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v5.0.2/contracts/access/Ownable.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v5.0.2/contracts/utils/ReentrancyGuard.sol";

contract MultiPoolStakingAPR is ReentrancyGuard, Ownable {
    uint256 private constant SECONDS_PER_YEAR = 365 days;
    uint256 private constant WAD = 1e18;

    struct Pool {
        IERC20 stakingToken;                 // token users deposit
        IERC20 rewardsToken;                 // token paid as rewards
        uint256 aprBps;                      // APR in basis points (e.g., 1000 = 10%)
        uint256 lockPeriod;                  // seconds user must wait since last deposit before normal withdraw
        uint256 totalSupply;                 // total staked
        uint256 lastUpdateTime;              // last time rewardPerTokenStored updated
        uint256 rewardPerTokenStored;        // per-token accumulator (scaled by 1e18)

        mapping(address => uint256) balances;                // user => staked amount
        mapping(address => uint256) userRewardPerTokenPaid;  // user => snapshot of RPT
        mapping(address => uint256) rewards;                 // user => accrued but unclaimed
        mapping(address => uint256) depositTimestamps;       // user => last deposit ts (for lock)
    }

    uint256 public poolCount;
    mapping(uint256 => Pool) private pools;

    // ---- Early-withdraw penalties ----
    address public penaltyRecipient;                 // where principal penalties are sent
    mapping(uint256 => uint256) public earlyPenaltyBps; // per-pool penalty (basis points)

    // -------- Events --------
    event PoolCreated(uint256 indexed poolId, address stakingToken, address rewardsToken, uint256 aprBps, uint256 lockPeriod);
    event PoolUpdated(uint256 indexed poolId, uint256 aprBps, uint256 lockPeriod);
    event Staked(uint256 indexed poolId, address indexed user, uint256 amount);
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

    // -------- Owner: Pool management --------

    function addPool(
        address _stakingToken,
        address _rewardsToken,
        uint256 _aprBps,
        uint256 _lockPeriod
    ) external onlyOwner {
        require(_stakingToken != address(0), "Invalid staking token");
        require(_rewardsToken != address(0), "Invalid rewards token");

        uint256 poolId = poolCount++;
        Pool storage p = pools[poolId];
        p.stakingToken    = IERC20(_stakingToken);
        p.rewardsToken    = IERC20(_rewardsToken);
        p.aprBps          = _aprBps;
        p.lockPeriod      = _lockPeriod;
        p.lastUpdateTime  = block.timestamp;

        emit PoolCreated(poolId, _stakingToken, _rewardsToken, _aprBps, _lockPeriod);
    }

    function setAprBps(uint256 poolId, uint256 _aprBps) external onlyOwner {
        require(poolId < poolCount, "Invalid pool");
        _updateReward(poolId, address(0));
        pools[poolId].aprBps = _aprBps;
        emit PoolUpdated(poolId, _aprBps, pools[poolId].lockPeriod);
    }

    function setLockPeriod(uint256 poolId, uint256 _lockPeriod) external onlyOwner {
        require(poolId < poolCount, "Invalid pool");
        pools[poolId].lockPeriod = _lockPeriod;
        emit PoolUpdated(poolId, pools[poolId].aprBps, _lockPeriod);
    }

    // ---- Penalty config ----

    function setPenaltyRecipient(address _to) external onlyOwner {
        require(_to != address(0), "bad recipient");
        penaltyRecipient = _to;
        emit PenaltyRecipientUpdated(_to);
    }

    function setEarlyPenaltyBps(uint256 poolId, uint256 bps) external onlyOwner {
        require(poolId < poolCount, "Invalid pool");
        require(bps <= 5000, "max 50%"); // adjust cap as desired
        earlyPenaltyBps[poolId] = bps;
        emit EarlyPenaltyBpsUpdated(poolId, bps);
    }

    // -------- Views --------

    function getPoolInfo(uint256 poolId)
        external
        view
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
        require(poolId < poolCount, "Invalid pool");
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

    function balanceOf(uint256 poolId, address account) external view returns (uint256) {
        require(poolId < poolCount, "Invalid pool");
        return pools[poolId].balances[account];
    }

    function rewardPerToken(uint256 poolId) public view returns (uint256) {
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

    function earned(uint256 poolId, address account) public view returns (uint256) {
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

    // -------- User actions --------

    function stake(uint256 poolId, uint256 amount) external nonReentrant {
        require(poolId < poolCount, "Invalid pool");
        require(amount > 0, "Cannot stake 0");

        Pool storage p = pools[poolId];
        _updateReward(poolId, msg.sender);

        p.totalSupply += amount;
        p.balances[msg.sender] += amount;
        p.depositTimestamps[msg.sender] = block.timestamp; // reset lock window on each deposit

        require(p.stakingToken.transferFrom(msg.sender, address(this), amount), "Stake transfer failed");
        emit Staked(poolId, msg.sender, amount);
    }

    function withdraw(uint256 poolId, uint256 amount) public nonReentrant {
        require(poolId < poolCount, "Invalid pool");
        require(amount > 0, "Cannot withdraw 0");

        Pool storage p = pools[poolId];
        require(p.balances[msg.sender] >= amount, "Withdraw exceeds balance");
        require(block.timestamp >= p.depositTimestamps[msg.sender] + p.lockPeriod, "Lock not over");

        _updateReward(poolId, msg.sender);

        p.totalSupply -= amount;
        p.balances[msg.sender] -= amount;

        require(p.stakingToken.transfer(msg.sender, amount), "Withdraw transfer failed");
        emit Withdrawn(poolId, msg.sender, amount);
    }

    function earlyWithdraw(uint256 poolId, uint256 amount) external nonReentrant {
        require(poolId < poolCount, "Invalid pool");
        require(amount > 0, "Cannot withdraw 0");

        Pool storage p = pools[poolId];
        require(p.balances[msg.sender] >= amount, "Exceeds balance");
        require(block.timestamp < p.depositTimestamps[msg.sender] + p.lockPeriod, "Lock over; use withdraw()");

        _updateReward(poolId, msg.sender); // keep accounting in sync

        // compute penalty on principal
        uint256 bps = earlyPenaltyBps[poolId];
        uint256 penalty = (amount * bps) / 10000;
        uint256 payout = amount - penalty;

        // update state BEFORE transfers
        p.totalSupply -= amount;
        p.balances[msg.sender] -= amount;

        // forfeit any accrued rewards on early exit
        p.rewards[msg.sender] = 0;

        // transfers
        require(p.stakingToken.transfer(msg.sender, payout), "payout failed");
        if (penalty > 0) {
            require(p.stakingToken.transfer(penaltyRecipient, penalty), "penalty transfer failed");
        }

        emit EarlyWithdrawWithPenalty(poolId, msg.sender, amount, penalty);
    }

    function getReward(uint256 poolId) public nonReentrant {
        require(poolId < poolCount, "Invalid pool");
        _updateReward(poolId, msg.sender);

        Pool storage p = pools[poolId];
        uint256 reward = p.rewards[msg.sender];
        if (reward > 0) {
            p.rewards[msg.sender] = 0;
            require(p.rewardsToken.transfer(msg.sender, reward), "Reward transfer failed");
            emit RewardPaid(poolId, msg.sender, reward);
        }
    }

    function exit(uint256 poolId) external {
        withdraw(poolId, pools[poolId].balances[msg.sender]);
        getReward(poolId);
    }

    /**
     * @notice Emergency exit for stakers: returns staked tokens immediately, forfeits rewards.
     *         Ignores lock period. True break-glass path.
     */
    function emergencyWithdraw(uint256 poolId) external nonReentrant {
        require(poolId < poolCount, "Invalid pool");

        Pool storage p = pools[poolId];
        uint256 staked = p.balances[msg.sender];
        require(staked > 0, "Nothing to withdraw");

        // Reset before external call
        p.totalSupply -= staked;
        p.balances[msg.sender] = 0;
        p.rewards[msg.sender] = 0;

        require(p.stakingToken.transfer(msg.sender, staked), "Emergency transfer failed");
        emit EmergencyWithdraw(poolId, msg.sender, staked);
    }

    /**
     * @notice Owner can recover tokens that are NOT used as a staking token in any pool.
     *         Cannot withdraw users' staked funds.
     */
    function recoverERC20(address tokenAddress, uint256 tokenAmount) external onlyOwner {
        for (uint256 i = 0; i < poolCount; i++) {
            require(tokenAddress != address(pools[i].stakingToken), "Cannot recover staking token");
        }
        require(IERC20(tokenAddress).transfer(owner(), tokenAmount), "Recover transfer failed");
        emit Recovered(tokenAddress, tokenAmount);
    }
}
