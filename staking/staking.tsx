import React, { useEffect, useMemo, useState } from "react";
import { Address, Hex, formatUnits, parseUnits, maxUint256 } from "viem";
import { useAccount, useReadContract, useWriteContract, useWaitForTransactionReceipt } from "wagmi";
import {
  CONTRACT_ADDRESS,
  OEC_STAKING_ABI,
  UI_POOLS,
  type PoolId,
  usePendingRewards,
  usePoolInfo,
  useUserInfo,
  useStakeWrite,
  useUnstakeWrite,
  useClaimWrite,
  useTxStatus,
} from "./staking-web3"; // adjust path as needed

// Minimal ERC20 ABI for decimals/symbol/allowance/approve/balance
const ERC20_ABI = [
  { "type": "function", "name": "decimals", "stateMutability": "view", "inputs": [], "outputs": [{ "type": "uint8" }] },
  { "type": "function", "name": "symbol", "stateMutability": "view", "inputs": [], "outputs": [{ "type": "string" }] },
  { "type": "function", "name": "balanceOf", "stateMutability": "view", "inputs": [{ "name": "owner", "type": "address" }], "outputs": [{ "type": "uint256" }] },
  { "type": "function", "name": "allowance", "stateMutability": "view", "inputs": [{ "name": "owner", "type": "address" }, { "name": "spender", "type": "address" }], "outputs": [{ "type": "uint256" }] },
  { "type": "function", "name": "approve", "stateMutability": "nonpayable", "inputs": [{ "name": "spender", "type": "address" }, { "name": "amount", "type": "uint256" }], "outputs": [{ "type": "bool" }] },
] as const;

// Helper: pretty format BigInt with decimals
const fmt = (v?: bigint | null, decimals = 18, fallback = "0") => {
  if (v === undefined || v === null) return fallback;
  try { return formatUnits(v, decimals); } catch { return fallback; }
};

const TABS: { id: PoolId; label: string }[] = [
  { id: 1, label: UI_POOLS[1].label },
  { id: 2, label: UI_POOLS[2].label },
  { id: 3, label: UI_POOLS[3].label },
  { id: 4, label: UI_POOLS[4].label },
];

export default function StakingPage() {
  const { address } = useAccount();
  const [selected, setSelected] = useState<PoolId>(1);
  const [amount, setAmount] = useState<string>("");
  const [approveUnlimited, setApproveUnlimited] = useState<boolean>(true);

  // ----- Contract views -----
  const { data: pool } = usePoolInfo(selected);
  const { data: uinfo } = useUserInfo(address as Address | undefined, selected);
  const { data: pending } = usePendingRewards(address as Address | undefined, selected);

  // stakingToken address
  const { data: stakingTokenAddr } = useReadContract({
    address: CONTRACT_ADDRESS,
    abi: OEC_STAKING_ABI,
    functionName: "stakingToken",
  });

  // token metadata + balances + allowance
  const tokenAddress = stakingTokenAddr as Address | undefined;
  const { data: tokenDecimals } = useReadContract({ address: tokenAddress, abi: ERC20_ABI, functionName: "decimals", query: { enabled: !!tokenAddress } });
  const decimals = (tokenDecimals as number) ?? 18;
  const { data: tokenSymbol } = useReadContract({ address: tokenAddress, abi: ERC20_ABI, functionName: "symbol", query: { enabled: !!tokenAddress } });
  const { data: myBal } = useReadContract({ address: tokenAddress, abi: ERC20_ABI, functionName: "balanceOf", args: address ? [address] : undefined, query: { enabled: !!tokenAddress && !!address } });
  const { data: allowance } = useReadContract({ address: tokenAddress, abi: ERC20_ABI, functionName: "allowance", args: address ? [address, CONTRACT_ADDRESS] : undefined, query: { enabled: !!tokenAddress && !!address } });

  // Writes: approve (ERC20) + stake/unstake/claim (staking)
  const approveWrite = useWriteContract();
  const { stake, data: stakeHash, isPending: isStakeWriting } = useStakeWrite();
  const { unstake, data: unstakeHash, isPending: isUnstakeWriting } = useUnstakeWrite();
  const { claim, data: claimHash, isPending: isClaimWriting } = useClaimWrite();

  const { isLoading: stakeConfirming, isSuccess: stakeSuccess } = useTxStatus(stakeHash as Hex | undefined);
  const { isLoading: unstakeConfirming, isSuccess: unstakeSuccess } = useTxStatus(unstakeHash as Hex | undefined);
  const { isLoading: claimConfirming, isSuccess: claimSuccess } = useTxStatus(claimHash as Hex | undefined);

  // Derived UI
  const apyPct = UI_POOLS[selected].apyPct;
  const lockDays = UI_POOLS[selected].lockDays;
  const minStake = pool ? (pool as any)[4] as bigint : 0n; // minStake
  const maxStake = pool ? (pool as any)[5] as bigint : 0n; // maxStake
  const userTotalStaked = uinfo ? (uinfo as any)[0] as bigint : 0n;
  const userUnclaimed = uinfo ? (uinfo as any)[1] as bigint : 0n;

  const amountBN = useMemo(() => {
    if (!amount) return 0n;
    try { return parseUnits(amount, decimals); } catch { return 0n; }
  }, [amount, decimals]);

  const needsApproval = useMemo(() => {
    if (!amountBN) return false;
    const a = (allowance as bigint) ?? 0n;
    return a < amountBN;
  }, [allowance, amountBN]);

  const canStake = useMemo(() => {
    if (!amountBN) return false;
    if (minStake && amountBN < (minStake as bigint)) return false;
    if (maxStake && amountBN > (maxStake as bigint)) return false;
    const bal = (myBal as bigint) ?? 0n;
    return bal >= amountBN;
  }, [amountBN, minStake, maxStake, myBal]);

  // Handlers
  const onApprove = async () => {
    if (!tokenAddress || !amountBN) return;
    try {
      const value = approveUnlimited ? maxUint256 : amountBN;
      const hash = await approveWrite.writeContractAsync?.({ address: tokenAddress, abi: ERC20_ABI, functionName: "approve", args: [CONTRACT_ADDRESS, value] });
      if (!hash) return;
      await new Promise((resolve) => setTimeout(resolve, 1000)); // small delay before reading allowance again
    } catch (e) { console.error(e); }
  };

  const onStake = async () => {
    try { await stake(selected, amount, decimals); setAmount(""); } catch (e) { console.error(e); }
  };
  const onUnstake = async () => {
    try { await unstake(selected, amount, decimals); setAmount(""); } catch (e) { console.error(e); }
  };
  const onClaim = async () => {
    try { await claim(selected); } catch (e) { console.error(e); }
  };

  // Simple ROI preview to match UI calculator: linear APR, no compounding
  const roiPreview = useMemo(() => {
    const principal = Number(amount || 0);
    const daily = principal * (apyPct / 100) / 365;
    const days = lockDays || 30; // for flexible, show 30d preview
    return {
      daily,
      total: daily * days,
      days,
    };
  }, [amount, apyPct, lockDays]);

  return (
    <div className="mx-auto max-w-4xl p-4 text-white">
      <h1 className="text-3xl font-bold mb-4">Staking</h1>

      {/* Pool tabs */}
      <div className="mb-6 grid grid-cols-2 md:grid-cols-4 gap-2">
        {TABS.map((t) => (
          <button
            key={t.id}
            onClick={() => setSelected(t.id)}
            className={`rounded-2xl px-3 py-2 border ${selected === t.id ? "bg-white/10 border-white" : "bg-white/5 border-white/20"}`}
          >
            <div className="text-sm">{t.label}</div>
            <div className="text-xs opacity-70">APY {UI_POOLS[t.id].apyPct}%</div>
          </button>
        ))}
      </div>

      {/* Pool info card */}
      <div className="rounded-2xl border border-white/20 bg-white/5 p-4 mb-6">
        <div className="flex flex-wrap items-center justify-between gap-3">
          <div>
            <div className="text-lg font-semibold">{UI_POOLS[selected].label}</div>
            <div className="text-sm opacity-80">APY: {apyPct}% • Lock: {lockDays ? `${lockDays} days` : "Flexible"}</div>
          </div>
          <div className="text-sm">
            <div>Min / Max per stake:</div>
            <div className="opacity-80">{fmt(minStake as bigint, decimals)} / {fmt(maxStake as bigint, decimals)} {tokenSymbol as string || "TOKEN"}</div>
          </div>
        </div>
      </div>

      {/* Balances */}
      <div className="rounded-2xl border border-white/20 bg-white/5 p-4 mb-6 grid md:grid-cols-3 gap-4">
        <div>
          <div className="text-sm opacity-80">Your Balance</div>
          <div className="text-xl">{fmt(myBal as bigint, decimals)} {tokenSymbol as string || "TOKEN"}</div>
        </div>
        <div>
          <div className="text-sm opacity-80">Staked (this pool)</div>
          <div className="text-xl">{fmt(userTotalStaked, decimals)} {tokenSymbol as string || "TOKEN"}</div>
        </div>
        <div>
          <div className="text-sm opacity-80">Pending Rewards</div>
          <div className="text-xl">{fmt((pending as bigint) ?? 0n, decimals)} {tokenSymbol as string || "TOKEN"}</div>
        </div>
      </div>

      {/* Input + actions */}
      <div className="rounded-2xl border border-white/20 bg-white/5 p-4 mb-6">
        <label className="text-sm opacity-80">Amount</label>
        <div className="flex gap-2 mt-2">
          <input
            className="flex-1 rounded-xl bg-black/40 border border-white/20 px-3 py-2 focus:outline-none"
            placeholder={`0.0 ${tokenSymbol || "TOKEN"}`}
            value={amount}
            onChange={(e) => setAmount(e.target.value)}
          />
          <button className="rounded-xl px-3 py-2 bg-white/10 border border-white/20" onClick={() => setAmount(fmt(myBal as bigint, decimals))}>Max</button>
        </div>
        {/* ROI preview */}
        <div className="mt-2 text-xs opacity-75">Est. daily: {roiPreview.daily.toFixed(6)} {tokenSymbol as string || "TOKEN"} • ~{roiPreview.days}d reward: {roiPreview.total.toFixed(6)}
        </div>

        {/* Approval notice */}
        {needsApproval && (
          <div className="mt-4 rounded-xl bg-yellow-500/10 border border-yellow-500/40 p-3 text-sm">
            <div className="mb-2">Approval required to stake. Approve once, then you can stake freely.</div>
            <label className="inline-flex items-center gap-2 text-xs opacity-80">
              <input type="checkbox" checked={approveUnlimited} onChange={(e) => setApproveUnlimited(e.target.checked)} />
              Approve unlimited (recommended)
            </label>
            <div className="mt-2 flex gap-2">
              <button onClick={onApprove} className="rounded-xl px-4 py-2 bg-white text-black font-semibold">Approve</button>
            </div>
          </div>
        )}

        {/* Action buttons */}
        <div className="mt-4 flex flex-wrap gap-2">
          <button disabled={!canStake || needsApproval || isStakeWriting || stakeConfirming} onClick={onStake} className="rounded-xl px-4 py-2 bg-white/90 text-black font-semibold disabled:opacity-40">{isStakeWriting || stakeConfirming ? "Staking…" : "Stake"}</button>
          <button disabled={!amountBN || isUnstakeWriting || unstakeConfirming} onClick={onUnstake} className="rounded-xl px-4 py-2 bg-white/10 border border-white/20 disabled:opacity-40">{isUnstakeWriting || unstakeConfirming ? "Unstaking…" : "Unstake"}</button>
          <button disabled={((pending as bigint) ?? 0n) === 0n || isClaimWriting || claimConfirming} onClick={onClaim} className="rounded-xl px-4 py-2 bg-white/10 border border-white/20 disabled:opacity-40">{isClaimWriting || claimConfirming ? "Claiming…" : "Claim Rewards"}</button>
        </div>

        {/* Hints */}
        <div className="mt-3 text-xs opacity-70">
          {lockDays ? (
            <div>Locked pool: early unstake may incur a penalty on the early portion. Matured deposits withdraw penalty-free.</div>
          ) : (
            <div>Flexible pool: no lock, no penalty. Rewards accrue continuously.</div>
          )}
        </div>
      </div>

      {/* Tx toasts (very simple) */}
      <TxToast label="Stake" success={stakeSuccess} />
      <TxToast label="Unstake" success={unstakeSuccess} />
      <TxToast label="Claim" success={claimSuccess} />
    </div>
  );
}

function TxToast({ label, success }: { label: string; success?: boolean }) {
  const [visible, setVisible] = useState(false);
  useEffect(() => { if (success) { setVisible(true); const t = setTimeout(() => setVisible(false), 4000); return () => clearTimeout(t); } }, [success]);
  if (!visible) return null;
  return (
    <div className="fixed bottom-4 right-4 rounded-2xl bg-emerald-500 text-white px-4 py-2 shadow-xl">
      {label} confirmed ✅
    </div>
  );
}
