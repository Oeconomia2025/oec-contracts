import 'dotenv/config';
import { ethers } from 'ethers';

const RPC_URL = process.env.RPC_URL;
const PRIVATE_KEY = process.env.PRIVATE_KEY;
const ZAP_ADDRESS = process.env.ZAP_ADDRESS;
const CHUNK_ETH = ethers.parseEther(process.env.CHUNK_ETH || '0.2');
const MIN_BAL_ETH = ethers.parseEther(process.env.MIN_BAL_ETH || '0.25');

const ZAP_ABI = [
  'function zapAndAddLiquidity() payable'
];

async function main() {
  const provider = new ethers.JsonRpcProvider(RPC_URL);
  const wallet = new ethers.Wallet(PRIVATE_KEY, provider);
  const zap = new ethers.Contract(ZAP_ADDRESS, ZAP_ABI, wallet);

  console.log('Bot:', await wallet.getAddress());
  console.log('Zap:', ZAP_ADDRESS);

  while (true) {
    try {
      const bal = await provider.getBalance(wallet.address);
      console.log(`[${new Date().toISOString()}] Balance: ${ethers.formatEther(bal)} ETH`);

      if (bal >= MIN_BAL_ETH) {
        console.log(`→ Zapping ${ethers.formatEther(CHUNK_ETH)} ETH...`);
        const tx = await zap.zapAndAddLiquidity({
          value: CHUNK_ETH,
          // You can set gas params if you want:
          // gasLimit: 350000,
        });
        console.log('Submitted:', tx.hash);
        const rcpt = await tx.wait();
        console.log('Confirmed in block', rcpt.blockNumber);
      } else {
        console.log('Balance below threshold; skipping.');
      }
    } catch (e) {
      console.error('Error:', e?.message || e);
    }

    // wait 10 minutes
    await new Promise(r => setTimeout(r, 10 * 60 * 1000));
  }
}

main().catch(console.error);
