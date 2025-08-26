// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/**
 * @title LiquidityZapETH (hardened)
 * @notice Deposit ETH only: 10% to treasury, 90% is zapped into OEC/ETH LP on Uniswap V2.
 * Security improvements vs. original:
 *  - Fixed swap path syntax
 *  - ReentrancyGuard on entry-points; receive() restricted to router/WETH
 *  - Explicit slippage & deadline parameters
 *  - Checks-Effects-Interactions order; robust return validations
 *  - No owner-controlled LP recipient (LP goes to the caller)
 *  - Two-step, delayed admin changes (timelocked) for treasury
 *  - Emergency pause; events + custom errors; named constants
 */
interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IUniswapV2Router02 {
    function WETH() external view returns (address);
    function factory() external view returns (address);
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable;
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);
}

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface IUniswapV2Pair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}

contract LiquidityZapETH {
    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/
    error ZeroDeposit();
    error Paused();
    error DeadlineExpired();
    error NoPool();
    error BadRouterRefund();
    error InsufficientOutput();
    error LPNotMinted();
    error Unauthorized();
    error TooHighSlippage();
    error TimelockPending();
    error NothingPending();

    /*//////////////////////////////////////////////////////////////
                              IMMUTABLES
    //////////////////////////////////////////////////////////////*/
    IUniswapV2Router02 public immutable router;
    IUniswapV2Factory public immutable factory;
    address public immutable token;     // OEC token
    address public immutable WETH;      // from router

    /*//////////////////////////////////////////////////////////////
                               OWNERSHIP
    //////////////////////////////////////////////////////////////*/
    address public owner;
    address public pendingOwner;

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                          SIMPLE REENTRANCY GUARD
    //////////////////////////////////////////////////////////////*/
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
    // Basis points constants
    uint256 public constant BPS = 10_000;
    uint256 public constant TREASURY_BPS = 1_000; // 10%
    uint256 public constant ZAP_BPS = BPS - TREASURY_BPS; // 90%

    // Uniswap V2 constants used in optimal one-sided liquidity formula (0.30% fee)
    uint256 private constant FEE_NUM = 997;   // 1000 - 3
    uint256 private constant FEE_DEN = 1000;
    uint256 private constant A_NUM = 3988000; // 2 * FEE_NUM * 1000
    uint256 private constant B_NUM = 3988009; // (1000 + FEE_NUM)^2
    uint256 private constant C1 = 1997;       // 2*FEE_NUM+3
    uint256 private constant C2 = 1994;       // 2*(1000-3)

    // Timelock configuration
    uint64 public constant MIN_DELAY = 12 hours;
    struct PendingAddress {
        address value;
        uint64 applyAfter;
    }
    PendingAddress public pendingTreasury;

    // Treasury that receives the 10% + leftovers
    address payable public treasury;

    // Global pause
    bool public paused;
    event PausedSet(bool isPaused);

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/
    event OwnerUpdate(address indexed oldOwner, address indexed newOwner);
    event TreasuryQueued(address indexed newTreasury, uint64 applyAfter);
    event TreasuryApplied(address indexed newTreasury);
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

    constructor(address _router, address _token, address payable _treasury) {
        owner = msg.sender;
        router = IUniswapV2Router02(_router);
        factory = IUniswapV2Factory(IUniswapV2Router02(_router).factory());
        token = _token;
        WETH = IUniswapV2Router02(_router).WETH();
        treasury = _treasury;
    }

    /*//////////////////////////////////////////////////////////////
                            OWNERSHIP + TIMELOCK
    //////////////////////////////////////////////////////////////*/
    function renounceOwnership() external onlyOwner {
        emit OwnerUpdate(owner, address(0));
        owner = address(0);
        pendingOwner = address(0);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        pendingOwner = newOwner;
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert Unauthorized();
        emit OwnerUpdate(owner, pendingOwner);
        owner = pendingOwner;
        pendingOwner = address(0);
    }

    function queueTreasury(address payable newTreasury) external onlyOwner {
        pendingTreasury = PendingAddress({value: newTreasury, applyAfter: uint64(block.timestamp) + MIN_DELAY});
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

    /*//////////////////////////////////////////////////////////////
                           EMERGENCY PAUSE
    //////////////////////////////////////////////////////////////*/
    function setPaused(bool _paused) external onlyOwner { paused = _paused; emit PausedSet(_paused); }

    /*//////////////////////////////////////////////////////////////
                              USER ENTRYPOINT
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice Zaps ETH into token/ETH LP on Uniswap V2 (LP sent to caller). 10% of msg.value goes to treasury.
     * @param swapSlippageBps Max slippage in BPS for the swap leg (against constant-product quote)
     * @param addLpSlippageBps Min % of our token/ETH we demand router to use when minting LP (each leg)
     * @param deadline Unix timestamp; must be >= now
     * @param minLPMinted Minimum LP tokens the user is willing to receive (extra safety)
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
        if (swapSlippageBps > 500 || addLpSlippageBps > 500) revert TooHighSlippage(); // cap at 5%

        uint256 totalETH = msg.value;
        uint256 treasuryDue = (totalETH * TREASURY_BPS) / BPS;
        uint256 ethForZap = totalETH - treasuryDue;

        // Find pair + reserves
        address pair = factory.getPair(token, WETH);
        if (pair == address(0)) revert NoPool();
        (uint112 r0, uint112 r1, ) = IUniswapV2Pair(pair).getReserves();
        (uint256 rETH, uint256 rTOKEN) = IUniswapV2Pair(pair).token0() == WETH ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));

        // Compute optimal ETH to swap to tokens
        uint256 ethToSwap = _optimalSwapAmt(ethForZap, rETH);

        // Compute minOut for swap using Uniswap V2 formula
        uint256 expectedOut = _getAmountOut(ethToSwap, rETH, rTOKEN);
        uint256 minOut = expectedOut * (BPS - swapSlippageBps) / BPS;

        // Effects: record token balance before (for fee-on-transfer tokens)
        uint256 tokenBefore = IERC20(token).balanceOf(address(this));

        // Interactions: do the swap (ETH -> token)
        {
            address;
            path[0] = WETH;
            path[1] = token;
            router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: ethToSwap}(
                minOut,
                path,
                address(this),
                deadline
            );
        }

        // Effects: measure tokens actually received
        uint256 tokensBought = IERC20(token).balanceOf(address(this)) - tokenBefore;

        // Prepare to add liquidity with remaining ETH + all tokens we just got
        uint256 ethForLP = ethForZap - ethToSwap;
        // Token/ETH minimums for LP (protect against extreme price move)
        uint256 tokenMin = tokensBought * (BPS - addLpSlippageBps) / BPS;
        uint256 ethMin   = ethForLP   * (BPS - addLpSlippageBps) / BPS;

        // Approve router once for token spend (infinite)
        IERC20(token).approve(address(router), type(uint256).max);

        // Interactions: add liquidity
        (uint256 amountToken, uint256 amountETH, uint256 liquidity) = router.addLiquidityETH{value: ethForLP}(
            token,
            tokensBought,
            tokenMin,
            ethMin,
            msg.sender,   // LP tokens go straight to the caller (no centralization risk)
            deadline
        );

        if (liquidity == 0) revert LPNotMinted();
        if (amountToken < tokenMin || amountETH < ethMin) revert InsufficientOutput();
        if (liquidity < minLPMinted) revert InsufficientOutput();

        // ANY leftover ETH in this contract (refunds from router + the 10% fee) goes to treasury
        uint256 leftover = address(this).balance;
        uint256 payout = leftover + treasuryDue;
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
        (uint256 rETH, uint256 rTOKEN) = IUniswapV2Pair(pair).token0() == WETH ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        uint256 ethForZap = ethIn * ZAP_BPS / BPS;
        swapEth = _optimalSwapAmt(ethForZap, rETH);
        expectedTokenOut = _getAmountOut(swapEth, rETH, rTOKEN);
    }

    /*//////////////////////////////////////////////////////////////
                             INTERNAL MATH
    //////////////////////////////////////////////////////////////*/
    function _getAmountOut(uint256 amountIn, uint256 rIn, uint256 rOut) internal pure returns (uint256) {
        // Standard Uniswap V2 formula with 0.30% fee
        uint256 amountInWithFee = amountIn * FEE_NUM;
        return (amountInWithFee * rOut) / (rIn * FEE_DEN + amountInWithFee);
    }

    /// @dev Optimal one-sided add amount to swap when adding liquidity with only ETH leg
    function _optimalSwapAmt(uint256 amountIn, uint256 rIn) internal pure returns (uint256) {
        // Derivation from Alpha Finance's formula with fee 0.30%
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
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    /*//////////////////////////////////////////////////////////////
                               RECEIVE/FALLBACK
    //////////////////////////////////////////////////////////////*/
    // Only accept ETH from router/WETH (refunds). Prevents accidental sends & limits reentrancy surface.
    receive() external payable {
        if (msg.sender != address(router) && msg.sender != WETH) revert BadRouterRefund();
    }
}
