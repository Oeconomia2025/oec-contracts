// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/**
 * @title LiquidityZapETH
 * @notice Deposit ETH only: 10% to treasury, 90% is zapped into OEC/ETH LP on Uniswap V2.
 * - Swaps optimal portion of ETH -> OEC
 * - Adds liquidity with OEC + remaining ETH
 * - LP tokens go to lpRecipient
 * - Any leftover ETH after addLiquidity is forwarded to treasury
 *
 * Requirements:
 * - OEC/WETH pair must already exist with non-zero reserves (this is NOT an initial LP creator)
 * - OEC is a fee-on-transfer token; adding LP from this contract will incur token-side tax per your token logic
 */

interface IUniswapV2Router02 {
    function WETH() external pure returns (address);
    function factory() external pure returns (address);

    // swap (supporting fee-on-transfer for OEC buys)
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable;

    // add liquidity with ETH
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
    function getPair(address tokenA, address tokenB) external view returns (address);
}

interface IUniswapV2Pair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 r0, uint112 r1, uint32 blockTimestampLast);
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

contract LiquidityZapETH {
    error NoPool();
    error Reentrancy();
    error ZeroDeposit();
    error TooHighSlippage();

    // Immutable core
    address public immutable token;          // OEC token
    IUniswapV2Router02 public immutable router;
    address public immutable WETH;

    // Admin
    address public owner;
    address payable public treasury;         // receives 10% and any leftover ETH
    address public lpRecipient;              // where LP tokens are minted to (treasury or locker)

    // Config
    uint256 public slippageBps = 500;        // 5% min-out slippage guard on addLiquidity amounts
    uint256 private locked;

    event Zapped(address indexed sender, uint256 ethIn, uint256 ethToTreasury, uint256 ethSwap, uint256 tokenBought, uint256 lpMinted);
    event OwnerChanged(address indexed newOwner);
    event TreasuryChanged(address indexed newTreasury);
    event LPRecipientChanged(address indexed newRecipient);
    event SlippageUpdated(uint256 bps);

    modifier nonReentrant() {
        if (locked == 1) revert Reentrancy();
        locked = 1; _;
        locked = 0;
    }
    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    constructor(
        address _token,
        address _router,
        address payable _treasury,
        address _lpRecipient
    ) {
        token = _token;
        router = IUniswapV2Router02(_router);
        WETH = router.WETH();

        owner = msg.sender;
        treasury = _treasury;
        lpRecipient = _lpRecipient;

        // Unlimited approval for router to spend OEC from this zap
        IERC20(_token).approve(_router, type(uint256).max);

        emit OwnerChanged(owner);
        emit TreasuryChanged(_treasury);
        emit LPRecipientChanged(_lpRecipient);
    }

    /**
     * @notice Main entry: send ETH, it will:
     *  - forward 10% to treasury,
     *  - use 90% to swap optimal portion of ETH->OEC and add LP with remainder ETH
     */
    function zapAndAddLiquidity() external payable nonReentrant {
        if (msg.value == 0) revert ZeroDeposit();

        // 10% to treasury immediately
        uint256 ethToTreasury = (msg.value * 10) / 100;
        _safeSendETH(treasury, ethToTreasury);

        uint256 ethBudget = msg.value - ethToTreasury; // 90% for zap

        // Ensure pool exists and has reserves
        address pair = IUniswapV2Factory(router.factory()).getPair(WETH, token);
        if (pair == address(0)) revert NoPool();
        (uint112 r0, uint112 r1,) = IUniswapV2Pair(pair).getReserves();
        (uint112 rWETH, uint112 rTOKEN) = IUniswapV2Pair(pair).token0() == WETH ? (r0, r1) : (r1, r0);
        require(rWETH > 0 && rTOKEN > 0, "empty reserves");

        // Compute optimal ETH to swap -> OEC
        uint256 ethToSwap = _optimalSwapAmt(ethBudget, uint256(rWETH));

        // Buy OEC (supports fee-on-transfer on buy)
        uint256 tokenBefore = IERC20(token).balanceOf(address(this));
        if (ethToSwap > 0) {
            address;
            path[0] = WETH;
            path[1] = token;

            router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: ethToSwap}(
                0,                  // amountOutMin set to 0 to tolerate token buy tax; adjust if you want tighter control
                path,
                address(this),
                block.timestamp + 900
            );
        }
        uint256 tokenBought = IERC20(token).balanceOf(address(this)) - tokenBefore;

        // Remaining ETH for LP
        uint256 ethForLP = ethBudget - ethToSwap;

        // Add liquidity; router refunds any unused ETH back to this contract
        uint256 tokenMin = (tokenBought * (10_000 - slippageBps)) / 10_000;
        uint256 ethMin   = (ethForLP   * (10_000 - slippageBps)) / 10_000;

        (,, uint256 lpMinted) = router.addLiquidityETH{value: ethForLP}(
            token,
            tokenBought,
            tokenMin,
            ethMin,
            lpRecipient,
            block.timestamp + 900
        );

        // Forward any ETH left on this contract (refunds from router) to treasury
        uint256 leftover = address(this).balance;
        if (leftover > 0) {
            _safeSendETH(treasury, leftover);
        }

        emit Zapped(msg.sender, msg.value, ethToTreasury, ethToSwap, tokenBought, lpMinted);
    }

    /// -----------------------------------------------------------------------
    /// Admin
    /// -----------------------------------------------------------------------

    function setOwner(address _new) external onlyOwner {
        owner = _new;
        emit OwnerChanged(_new);
    }

    function setTreasury(address payable _new) external onlyOwner {
        treasury = _new;
        emit TreasuryChanged(_new);
    }

    function setLPRecipient(address _new) external onlyOwner {
        lpRecipient = _new;
        emit LPRecipientChanged(_new);
    }

    function setSlippageBps(uint256 _bps) external onlyOwner {
        if (_bps > 3000) revert TooHighSlippage(); // cap at 30%
        slippageBps = _bps;
        emit SlippageUpdated(_bps);
    }

    /// -----------------------------------------------------------------------
    /// Internals
    /// -----------------------------------------------------------------------

    // Babylonian sqrt
    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) { z = x; x = (y / x + x) / 2; }
        } else if (y != 0) { z = 1; }
    }

    /**
     * @dev Optimal one-sided supply (Uniswap V2 0.3% fee)
     * amountToSwap = (sqrt(rIn * (rIn*3988009 + amountIn*3988000)) - rIn*1997) / 1994
     * where rIn is WETH reserve and amountIn is ETH budget for LP.
     */
    function _optimalSwapAmt(uint256 amountIn, uint256 rIn) internal pure returns (uint256) {
        // constants for 0.3% fee: 997/1000
        uint256 a = 3988000 * amountIn + 3988009 * rIn;
        uint256 b = _sqrt(rIn * a);
        uint256 c = 1997 * rIn;
        if (b <= c) return 0;
        return (b - c) / 1994;
    }

    function _safeSendETH(address payable to, uint256 amt) internal {
        (bool ok, ) = to.call{value: amt}("");
        require(ok, "ETH send failed");
    }

    receive() external payable {}
}
