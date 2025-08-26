// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/**
 * @title LiquidityZapETH v1.2 (Uniswap V2)
 * @notice Deposit ETH: 10% -> treasury, ~90% zapped into OEC/ETH LP. LP goes to caller.
 * Security: nonReentrant entrypoint, router/WETH-only receive(), slippage/deadline params, timelocked treasury updates, pause, custom errors.
 */
interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IUniswapV2Router02 {
    function WETH() external view returns (address);
    function factory() external view returns (address);
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin, address[] calldata path, address to, uint deadline
    ) external payable;
    function addLiquidityETH(
        address token, uint amountTokenDesired, uint amountTokenMin, uint amountETHMin, address to, uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);
}

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface IUniswapV2Pair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 r0, uint112 r1, uint32);
}

contract LiquidityZapETH {
    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/
    error ZeroDeposit();
    error InsufficientAmount();
    error DeadlineExpired();
    error Paused();
    error NoPool();
    error InsufficientOutput();
    error LPNotMinted();
    error Unauthorized();
    error TooHighSlippage();
    error BadRouterRefund();
    error TimelockPending();
    error NothingPending();
    error InvalidTreasury();

    /*//////////////////////////////////////////////////////////////
                               IMMUTABLES
    //////////////////////////////////////////////////////////////*/
    IUniswapV2Router02 public immutable router;
    IUniswapV2Factory public immutable factory;
    address public immutable token;
    address public immutable WETH;

    /*//////////////////////////////////////////////////////////////
                                OWNER
    //////////////////////////////////////////////////////////////*/
    address public owner;
    address public pendingOwner;
    modifier onlyOwner() { if (msg.sender != owner) revert Unauthorized(); _; }

    /* simple nonReentrant */
    uint256 private _locked = 1;
    modifier nonReentrant() {
        if (_locked != 1) revert Unauthorized();
        _locked = 2;
        _;
        _locked = 1;
    }

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/
    uint256 public constant BPS = 10_000;
    uint256 public constant TREASURY_BPS = 1_000;         // 10%
    uint256 public constant ZAP_BPS = BPS - TREASURY_BPS; // 90%

    // Uniswap V2 (0.30% fee) constants for optimal one-sided add
    uint256 private constant FEE_NUM = 997;
    uint256 private constant FEE_DEN = 1000;
    uint256 private constant A_NUM = 3988000;
    uint256 private constant B_NUM = 3988009;
    uint256 private constant C1 = 1997;
    uint256 private constant C2 = 1994;

    // Minimal ETH needed for a meaningful zap (prevents 1-wei corner cases)
    uint256 public constant MIN_ETH_FOR_ZAP = 2; // wei; keep tiny to avoid surprising users

    // Timelock for treasury updates
    uint64 public constant MIN_DELAY = 12 hours;
    struct PendingAddress { address value; uint64 applyAfter; }
    PendingAddress public pendingTreasury;

    address payable public treasury;
    bool public paused;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/
    event OwnerUpdate(address indexed oldOwner, address indexed newOwner);
    event TreasuryQueued(address indexed newTreasury, uint64 applyAfter);
    event TreasuryApplied(address indexed newTreasury);
    event PausedSet(bool isPaused);
    event Zapped(
        address indexed user,
        uint256 ethDeposited,
        uint256 ethSwapped,
        uint256 tokensBought,
        uint256 ethAdded,
        uint256 tokenAdded,
        uint256 lpMinted,
        uint256 treasuryPaid
    );

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/
    constructor(address _router, address _token, address payable _treasury) {
        owner = msg.sender;
        router = IUniswapV2Router02(_router);
        factory = IUniswapV2Factory(IUniswapV2Router02(_router).factory());
        token = _token;
        WETH = IUniswapV2Router02(_router).WETH();
        treasury = _treasury;

        // Approve router once (reset to 0 first for safety on non-standard ERC20s)
        IERC20(_token).approve(_router, 0);
        IERC20(_token).approve(_router, type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                           OWNERSHIP + TIMELOCK
    //////////////////////////////////////////////////////////////*/
    function transferOwnership(address newOwner) external onlyOwner { pendingOwner = newOwner; }
    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert Unauthorized();
        emit OwnerUpdate(owner, pendingOwner);
        owner = pendingOwner;
        pendingOwner = address(0);
    }
    function renounceOwnership() external onlyOwner {
        emit OwnerUpdate(owner, address(0));
        owner = address(0);
        pendingOwner = address(0);
    }

    function queueTreasury(address payable newTreasury) external onlyOwner {
        if (newTreasury == treasury || newTreasury == address(0)) revert InvalidTreasury();
        pendingTreasury = PendingAddress({ value: newTreasury, applyAfter: uint64(block.timestamp) + MIN_DELAY });
        emit TreasuryQueued(newTreasury, pendingTreasury.applyAfter);
    }
    function applyTreasury() external {
        PendingAddress memory p = pendingTreasury;
        if (p.value == address(0)) revert NothingPending();
        if (block.timestamp < p.applyAfter) revert TimelockPending();
        treasury = payable(p.value);
        delete pendingTreasury;
        emit TreasuryApplied(treasury);
    }
    function setPaused(bool _paused) external onlyOwner { paused = _paused; emit PausedSet(_paused); }

    /*//////////////////////////////////////////////////////////////
                              USER ENTRYPOINT
    //////////////////////////////////////////////////////////////*/
    /**
     * @param swapSlippageBps Max swap slippage in BPS (cap 5%)
     * @param addLpSlippageBps Max LP-leg slippage in BPS (cap 5%)
     * @param deadline Unix timestamp; must be >= now
     * @param minLPMinted Minimum acceptable LP tokens (extra safety)
     */
    function zapETH(
        uint256 swapSlippageBps,
        uint256 addLpSlippageBps,
        uint256 deadline,
        uint256 minLPMinted
    ) external payable nonReentrant returns (uint256 lpMinted) {
        if (paused) revert Paused();
        if (msg.value == 0) revert ZeroDeposit();
        if (deadline < block.timestamp) revert DeadlineExpired();
        if (swapSlippageBps > 500 || addLpSlippageBps > 500) revert TooHighSlippage();

        address self = address(this);
        address theRouter = address(router);

        uint256 totalETH = msg.value;
        uint256 treasuryDue = (totalETH * TREASURY_BPS) / BPS;
        uint256 ethForZap = totalETH - treasuryDue;
        if (ethForZap < MIN_ETH_FOR_ZAP) revert InsufficientAmount();

        // Pair + reserves
        address pair = factory.getPair(token, WETH);
        if (pair == address(0)) revert NoPool();
        (uint112 r0, uint112 r1, ) = IUniswapV2Pair(pair).getReserves();
        (uint256 rETH, uint256 rTOKEN) = IUniswapV2Pair(pair).token0() == WETH
            ? (uint256(r0), uint256(r1))
            : (uint256(r1), uint256(r0));

        // Optimal swap amount (fallback to 50/50 if too small)
        uint256 ethToSwap = _optimalSwapAmt(ethForZap, rETH);
        if (ethToSwap == 0) {
            ethToSwap = ethForZap / 2; // safe due to MIN_ETH_FOR_ZAP
        }

        // Compute swap minOut against current reserves
        uint256 expectedOut = _getAmountOut(ethToSwap, rETH, rTOKEN);
        uint256 minOut = expectedOut * (BPS - swapSlippageBps) / BPS;

        // Swap ETH -> token
        uint256 tokenBefore = IERC20(token).balanceOf(self);
        if (ethToSwap > 0) {
            address;
            path[0] = WETH;
            path[1] = token;

            router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: ethToSwap}(
                minOut,
                path,
                self,
                deadline
            );
        }
        uint256 tokensBought = IERC20(token).balanceOf(self) - tokenBefore;

        // Add liquidity with remaining ETH + bought tokens
        uint256 ethForLP = ethForZap - ethToSwap;
        uint256 tokenMin = tokensBought * (BPS - addLpSlippageBps) / BPS;
        uint256 ethMin   = ethForLP   * (BPS - addLpSlippageBps) / BPS;

        (uint256 amountToken, uint256 amountETH, uint256 liquidity) = router.addLiquidityETH{value: ethForLP}(
            token,
            tokensBought,
            tokenMin,
            ethMin,
            msg.sender,
            deadline
        );

        if (liquidity == 0) revert LPNotMinted();
        if (amountToken < tokenMin || amountETH < ethMin) revert InsufficientOutput();
        if (liquidity < minLPMinted) revert InsufficientOutput();

        // Send 10% + any leftover ETH (router refunds) to treasury
        uint256 leftover = self.balance;
        uint256 payout = treasuryDue + leftover;
        if (payout > 0) {
            (bool ok, ) = treasury.call{value: payout}("");
            if (!ok) revert BadRouterRefund();
        }

        emit Zapped(msg.sender, totalETH, ethToSwap, tokensBought, amountETH, amountToken, liquidity, payout);
        return liquidity;
    }

    /*//////////////////////////////////////////////////////////////
                              VIEW HELPERS
    //////////////////////////////////////////////////////////////*/
    function quoteOptimalSwap(uint256 ethIn) external view returns (uint256 swapEth, uint256 expectedTokenOut) {
        address pair = factory.getPair(token, WETH);
        if (pair == address(0)) revert NoPool();
        (uint112 r0, uint112 r1, ) = IUniswapV2Pair(pair).getReserves();
        (uint256 rETH, uint256 rTOKEN) = IUniswapV2Pair(pair).token0() == WETH
            ? (uint256(r0), uint256(r1))
            : (uint256(r1), uint256(r0));
        uint256 ethForZap = ethIn * ZAP_BPS / BPS;
        if (ethForZap < MIN_ETH_FOR_ZAP) return (0, 0);
        swapEth = _optimalSwapAmt(ethForZap, rETH);
        if (swapEth == 0) swapEth = ethForZap / 2;
        expectedTokenOut = _getAmountOut(swapEth, rETH, rTOKEN);
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL MATH
    //////////////////////////////////////////////////////////////*/
    function _getAmountOut(uint256 amountIn, uint256 rIn, uint256 rOut) internal pure returns (uint256) {
        uint256 amountInWithFee = amountIn * FEE_NUM;
        return (amountInWithFee * rOut) / (rIn * FEE_DEN + amountInWithFee);
    }

    function _optimalSwapAmt(uint256 amountIn, uint256 rIn) internal pure returns (uint256) {
        // s = (sqrt(r*(A*amountIn + B*r)) - C1*r) / C2
        uint256 a = A_NUM * amountIn + B_NUM * rIn;
        uint256 b = _sqrt(rIn * a);
        uint256 c = C1 * rIn;
        if (b <= c) return 0;
        return (b - c) / C2;
    }

    function _sqrt(uint256 x) private pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) { y = z; z = (x / z + z) / 2; }
    }

    /*//////////////////////////////////////////////////////////////
                           RECEIVE: ROUTER or WETH
    //////////////////////////////////////////////////////////////*/
    receive() external payable {
        if (msg.sender != address(router) && msg.sender != WETH) revert BadRouterRefund();
    }
}
