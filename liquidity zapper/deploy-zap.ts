import { ethers } from "hardhat";

async function main() {
  const ROUTER = "0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D";
  const TOKEN  = "0xb62870F6861BF065F5a6782996AB070EB9385d05";
  const TREAS  = "0x28B1B5D29FDfC712162ca1dcbe2F977A9D5F963f";

  const Zap = await ethers.getContractFactory("LiquidityZapETH");
  const zap = await Zap.deploy(ROUTER, TOKEN, TREAS);
  await zap.deployed();
  console.log("LiquidityZapETH:", zap.address);

  // Optional: Etherscan verify
  // npx hardhat verify --network mainnet <zap.address> %s %s %s
  //   ROUTER TOKEN TREAS
}

main().catch((e) => { console.error(e); process.exit(1); });
