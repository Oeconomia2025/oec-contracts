// Slippage caps (BPS): 300 = 3% is a reasonable start on both legs
const swapSlippageBps = 300;
const addLpSlippageBps = 300;
const deadline = Math.floor(Date.now()/1000) + 15 * 60; // 15 minutes
const minLPMinted = 0; // optionally set a floor

await zapETHContract.connect(user).zapETH(
  swapSlippageBps,
  addLpSlippageBps,
  deadline,
  minLPMinted,
  { value: ethers.utils.parseEther("1.0") }
);
