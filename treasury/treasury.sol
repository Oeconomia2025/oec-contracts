// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/// @title Oeconomia Treasury (Timelocked)
/// @notice Holds ETH & ERC20 funds; withdrawals are queued and executed after a delay.
/// @dev Single-file, no external imports. Safe for Remix. Includes:
///      - ERC20-safe transfers (handles non-standard returns)
///      - Timelock queue/execute/cancel
///      - Proposer / Executor role-gating (+ Owner)
///      - Two-step ownership, Pausable, ReentrancyGuard
///      - Events for full off-chain auditability
contract OeconomiaTreasury {
    /*//////////////////////////////////////////////////////////////
                               ERC20 + SAFES
    //////////////////////////////////////////////////////////////*/
    interface IERC20 {
        function totalSupply() external view returns (uint256);
        function balanceOf(address account) external view returns (uint256);
        function transfer(address recipient, uint256 amount) external returns (bool);
        function allowance(address owner, address spender) external view returns (uint256);
        function approve(address spender, uint256 amount) external returns (bool);
        function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
        event Transfer(address indexed from, address indexed to, uint256 value);
        event Approval(address indexed owner, address indexed spender, uint256 value);
    }

    library SafeERC20 {
        function safeTransfer(IERC20 token, address to, uint256 value) internal {
            (bool ok, bytes memory data) = address(token).call(
                abi.encodeWithSelector(token.transfer.selector, to, value)
            );
            require(ok && (data.length == 0 || abi.decode(data, (bool))), "ERC20_TRANSFER_FAIL");
        }

        function safeTransferFrom(IERC20 token, address from, address to, uint256 value) internal {
            (bool ok, bytes memory data) = address(token).call(
                abi.encodeWithSelector(token.transferFrom.selector, from, to, value)
            );
            require(ok && (data.length == 0 || abi.decode(data, (bool))), "ERC20_TF_FROM_FAIL");
        }
    }

    /*//////////////////////////////////////////////////////////////
                        OWNERSHIP (TWO-STEP) + ROLES
    //////////////////////////////////////////////////////////////*/
    event OwnershipTransferRequested(address indexed currentOwner, address indexed pendingOwner);
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);

    address public owner;
    address public pendingOwner;

    modifier onlyOwner() {
        require(msg.sender == owner, "NOT_OWNER");
        _;
    }

    function transferOwnership(address _pendingOwner) external onlyOwner {
        require(_pendingOwner != address(0), "ZERO_ADDR");
        pendingOwner = _pendingOwner;
        emit OwnershipTransferRequested(owner, _pendingOwner);
    }

    function acceptOwnership() external {
        require(msg.sender == pendingOwner, "NOT_PENDING_OWNER");
        address old = owner;
        owner = pendingOwner;
        pendingOwner = address(0);
        emit OwnershipTransferred(old, owner);
    }

    // Light-weight role system
    mapping(address => bool) public proposers;  // can queue withdrawals
    mapping(address => bool) public executors;  // can execute matured withdrawals

    event ProposerUpdated(address indexed who, bool enabled);
    event ExecutorUpdated(address indexed who, bool enabled);

    modifier onlyProposer() {
        require(proposers[msg.sender] || msg.sender == owner, "NOT_PROPOSER");
        _;
    }

    modifier onlyExecutor() {
        require(executors[msg.sender] || msg.sender == owner, "NOT_EXECUTOR");
        _;
    }

    function setProposer(address who, bool enabled) external onlyOwner {
        proposers[who] = enabled;
        emit ProposerUpdated(who, enabled);
    }

    function setExecutor(address who, bool enabled) external onlyOwner {
        executors[who] = enabled;
        emit ExecutorUpdated(who, enabled);
    }

    /*//////////////////////////////////////////////////////////////
                           PAUSABLE + REENTRANCY
    //////////////////////////////////////////////////////////////*/
    event Paused(address indexed by);
    event Unpaused(address indexed by);

    bool public paused;

    modifier whenNotPaused() {
        require(!paused, "PAUSED");
        _;
    }

    modifier whenPaused() {
        require(paused, "NOT_PAUSED");
        _;
    }

    function pause() external onlyOwner whenNotPaused {
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwner whenPaused {
        paused = false;
        emit Unpaused(msg.sender);
    }

    bool private _entered;
    modifier nonReentrant() {
        require(!_entered, "REENTRANT");
        _entered = true;
        _;
        _entered = false;
    }

    /*//////////////////////////////////////////////////////////////
                                  TIMELOCK
    //////////////////////////////////////////////////////////////*/
    using SafeERC20 for IERC20;

    struct Withdrawal {
        address token;        // address(0) == native ETH
        address to;
        uint256 amount;
        uint256 executeAfter; // unix time when it can be executed
        bool executed;
        bool canceled;
    }

    // id => Withdrawal
    mapping(bytes32 => Withdrawal) public withdrawals;

    // global, monotonic nonce included in hash to prevent collisions
    uint256 public nonce;

    // Timelock config
    uint256 public delay;                 // current required delay
    uint256 public constant MIN_DELAY = 1 hours;
    uint256 public constant MAX_DELAY = 30 days;

    event DelayUpdated(uint256 oldDelay, uint256 newDelay);
    event WithdrawalQueued(
        bytes32 indexed id,
        address indexed proposer,
        address indexed token,
        address to,
        uint256 amount,
        uint256 executeAfter
    );
    event WithdrawalExecuted(bytes32 indexed id, address indexed executor);
    event WithdrawalCanceled(bytes32 indexed id, address indexed by);

    function setDelay(uint256 newDelay) external onlyOwner {
        require(newDelay >= MIN_DELAY && newDelay <= MAX_DELAY, "DELAY_BOUNDS");
        uint256 old = delay;
        delay = newDelay;
        emit DelayUpdated(old, newDelay);
    }

    /// @notice Computes an id for a prospective withdrawal (for frontend/off-chain use).
    function computeId(
        address token,
        address to,
        uint256 amount,
        uint256 _nonce
    ) public view returns (bytes32) {
        return keccak256(abi.encodePacked(
            token,
            to,
            amount,
            _nonce,
            block.chainid,
            address(this)
        ));
    }

    /// @notice Queue a withdrawal that becomes executable after `delay`.
    function queueWithdrawal(
        address token,      // address(0) for ETH
        address to,
        uint256 amount
    ) external whenNotPaused onlyProposer returns (bytes32 id, uint256 executeAfter) {
        require(to != address(0), "BAD_TO");
        require(amount > 0, "ZERO_AMOUNT");

        uint256 _n = ++nonce;
        id = computeId(token, to, amount, _n);
        require(withdrawals[id].executeAfter == 0, "ALREADY_EXISTS");

        executeAfter = block.timestamp + delay;

        withdrawals[id] = Withdrawal({
            token: token,
            to: to,
            amount: amount,
            executeAfter: executeAfter,
            executed: false,
            canceled: false
        });

        emit WithdrawalQueued(id, msg.sender, token, to, amount, executeAfter);
    }

    /// @notice Execute a matured, not-canceled withdrawal.
    function executeWithdrawal(bytes32 id)
        external
        whenNotPaused
        onlyExecutor
        nonReentrant
    {
        Withdrawal storage w = withdrawals[id];
        require(w.executeAfter != 0, "NOT_FOUND");
        require(!w.executed, "ALREADY_EXECUTED");
        require(!w.canceled, "CANCELED");
        require(block.timestamp >= w.executeAfter, "TOO_EARLY");

        w.executed = true;

        if (w.token == address(0)) {
            // native ETH
            (bool ok, ) = w.to.call{value: w.amount}("");
            require(ok, "ETH_SEND_FAIL");
        } else {
            IERC20(w.token).safeTransfer(w.to, w.amount);
        }

        emit WithdrawalExecuted(id, msg.sender);
    }

    /// @notice Cancel a queued withdrawal (owner-only).
    function cancelWithdrawal(bytes32 id) external onlyOwner {
        Withdrawal storage w = withdrawals[id];
        require(w.executeAfter != 0, "NOT_FOUND");
        require(!w.executed, "ALREADY_EXECUTED");
        require(!w.canceled, "ALREADY_CANCELED");

        w.canceled = true;
        emit WithdrawalCanceled(id, msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                               DEPOSITS & VIEWS
    //////////////////////////////////////////////////////////////*/
    event DepositETH(address indexed from, uint256 amount, string memo);
    event DepositERC20(address indexed token, address indexed from, uint256 amount, string memo);

    /// @notice Accept native ETH.
    receive() external payable {
        emit DepositETH(msg.sender, msg.value, "");
    }

    /// @notice Accept native ETH with a memo.
    function depositETH(string calldata memo) external payable {
        emit DepositETH(msg.sender, msg.value, memo);
    }

    /// @notice Pull ERC20 into treasury (requires prior approve).
    function depositERC20(address token, uint256 amount, string calldata memo) external whenNotPaused {
        require(token != address(0), "BAD_TOKEN");
        require(amount > 0, "ZERO_AMOUNT");
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit DepositERC20(token, msg.sender, amount, memo);
    }

    /// @notice Current native ETH balance.
    function ethBalance() external view returns (uint256) {
        return address(this).balance;
    }

    /// @notice Current ERC20 balance for a token.
    function tokenBalance(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    /*//////////////////////////////////////////////////////////////
                                  SETUP
    //////////////////////////////////////////////////////////////*/
    constructor(
        uint256 initialDelay,
        address[] memory initialProposers,
        address[] memory initialExecutors
    ) {
        require(initialDelay >= MIN_DELAY && initialDelay <= MAX_DELAY, "DELAY_BOUNDS");
        owner = msg.sender;
        delay = initialDelay;

        // Owner is implicitly both roles; also seed extra roles if provided
        proposers[msg.sender] = true;
        executors[msg.sender] = true;

        for (uint256 i = 0; i < initialProposers.length; i++) {
            proposers[initialProposers[i]] = true;
            emit ProposerUpdated(initialProposers[i], true);
        }
        for (uint256 j = 0; j < initialExecutors.length; j++) {
            executors[initialExecutors[j]] = true;
            emit ExecutorUpdated(initialExecutors[j], true);
        }

        emit OwnershipTransferred(address(0), msg.sender);
    }
}
