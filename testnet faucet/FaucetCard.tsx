"use client";
import { useEffect, useMemo, useState } from "react";
import { BrowserProvider, Contract, JsonRpcProvider, formatUnits } from "ethers";
import faucetAbi from "@/abi/DDBFaucet.json";

const FAUCET = process.env.NEXT_PUBLIC_FAUCET_ADDRESS!;
const SEPOLIA_RPC = process.env.NEXT_PUBLIC_SEPOLIA_RPC || "https://sepolia.rpc.thirdweb.com";

function short(a?: string){ return a ? `${a.slice(0,6)}…${a.slice(-4)}` : ""; }
function hhmmss(s:number){
  const h = Math.floor(s/3600), m = Math.floor((s%3600)/60), sec = s%60;
  return `${h.toString().padStart(2,"0")}:${m.toString().padStart(2,"0")}:${sec.toString().padStart(2,"0")}`;
}

export default function FaucetCard(){
  const [connected,setConnected] = useState(false);
  const [addr,setAddr] = useState<string>("");
  const [cooldown,setCooldown] = useState<number>(86400);
  const [amount,setAmount] = useState<string>("1000 DDB");
  const [left,setLeft] = useState<number>(0);
  const [busy,setBusy] = useState<string>("");

  const ro = useMemo(()=> new JsonRpcProvider(SEPOLIA_RPC),[]);
  const rFaucet = useMemo(()=> new Contract(FAUCET, faucetAbi, ro),[ro]);

  // read static info
  useEffect(()=>{ (async()=>{
    try{
      const [amt, cd] = await Promise.all([rFaucet.amountPerClaim(), rFaucet.cooldown()]);
      // Display as whole tokens (assumes 18 decimals; adjust if different)
      setAmount(`${Number(formatUnits(amt, 18)).toLocaleString()} DDB`);
      setCooldown(Number(cd));
    }catch(e){ /* ignore */ }
  })(); },[rFaucet]);

  // wallet connect
  async function connect(){
    const eth:any = (window as any).ethereum;
    if(!eth) return alert("Install MetaMask");
    const provider = new BrowserProvider(eth);
    const [a] = await eth.request({ method: "eth_requestAccounts" });
    setAddr(a); setConnected(true);
    tick(a);
  }
  async function disconnect(){ setConnected(false); setAddr(""); }

  // poll seconds-left every second when connected
  useEffect(()=>{
    if(!connected || !addr) return;
    const id = setInterval(()=> tick(addr), 1000);
    return ()=> clearInterval(id);
  },[connected, addr]);

  async function tick(a:string){
    try{
      const s:number = Number(await rFaucet.secondsUntilNextClaim(a));
      setLeft(s);
    }catch{}
  }

  async function claim(){
    const eth:any = (window as any).ethereum;
    if(!eth) return alert("Install MetaMask");
    const provider = new BrowserProvider(eth);
    const signer = await provider.getSigner();
    const wFaucet = new Contract(FAUCET, faucetAbi, signer);
    try{
      setBusy("Claiming…");
      const tx = await wFaucet.claim();
      await tx.wait();
      setBusy("Claimed!");
      await tick(await signer.getAddress());
      setTimeout(()=> setBusy(""), 1200);
    }catch(e:any){
      setBusy("");
      alert(e?.reason || e?.message || "Failed");
    }
  }

  return (
    <div className="panel" style={{maxWidth: 760}}>
      <div style={{display:"flex",justifyContent:"space-between",alignItems:"center",gap:12, marginBottom:12}}>
        <div className="neo-head-title" style={{fontSize:20}}>DooDoo Butt Faucet</div>
        {connected ? (
          <div style={{display:"flex",gap:8,alignItems:"center"}}>
            <span className="oec-addr">{short(addr)}</span>
            <button className="btn ghost" onClick={disconnect}>Disconnect</button>
          </div>
        ) : (
          <button className="btn primary" onClick={connect}>Connect Wallet</button>
        )}
      </div>

      <div className="neo-content">
        <div className="neo-col">
          <div className="neo-label">Amount Per Claim</div>
          <div className="large">{amount}</div>

          <div className="neo-label" style={{marginTop:12}}>Cooldown</div>
          <div>{(cooldown/3600).toFixed(0)} hours</div>

          <div className="neo-label" style={{marginTop:12}}>Next Claim</div>
          <div className="large">{left===0 ? "Now" : hhmmss(left)}</div>
          <div className="small">Resets 24h after each claim.</div>
        </div>

        <div className="neo-col">
          <div className="panel">
            <div className="neo-label">Get test tokens</div>
            <div className="kv" style={{marginTop:8}}>
              <span>Daily allowance</span><strong>{amount}</strong>
            </div>
            <button
              className="btn primary cta"
              style={{marginTop:12, width:"100%"}}
              disabled={!connected || left > 0 || !!busy}
              onClick={claim}
            >
              {busy || (left>0 ? `Wait ${hhmmss(left)}` : `Claim ${amount}`)}
            </button>
            <div className="small" style={{marginTop:8}}>One claim per wallet per 24h.</div>
          </div>
        </div>
      </div>
    </div>
  );
}
