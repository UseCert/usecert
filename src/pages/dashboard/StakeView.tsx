import { useCallback, useMemo, useState } from "react";
import { formatUnits, parseUnits } from "viem";
import { usePublicClient, useReadContracts, useWriteContract } from "wagmi";
import { ArrowUpRight, Loader2 } from "lucide-react";
import { CHAIN_ID } from "@/chain/deployment";
import { SHARED, TestUSDGABI } from "@/chain/contracts";
import { explorerAddressUrl, explorerTxUrl } from "@/chain/config";
import { INSURANCE_ADDRESS, INSURANCE_DEPLOY_TX, INSURANCE_SHARE_DECIMALS, InsuranceStakingABI } from "@/chain/insurance";
import { useDashboard } from "./store";
import { MicroLabel, Panel, Stagger, ViewHeader } from "./ui";
import { cn } from "@/lib/utils";
import CertStakePanel from "./CertStakePanel";

/**
 * The insurance pool (InsuranceStaking, K1): stake USDG as the first-loss layer behind the
 * vaults' own buffers. Every figure is a chain read of the deployed pool; nothing here is
 * computed from a model. Stated on screen, not hidden in a tooltip: the contract is unaudited
 * and capped, and the pool has no automatic income (fee routing is K2, a new vault stack).
 */
const POOL = { address: INSURANCE_ADDRESS, abi: InsuranceStakingABI, chainId: CHAIN_ID } as const;
const USDG = { address: SHARED.collateral, abi: TestUSDGABI, chainId: CHAIN_ID } as const;
const ZERO = "0x0000000000000000000000000000000000000000" as const;

const usd = (v: bigint | undefined, dp = 2) =>
  v === undefined ? "—" : Number(formatUnits(v, 6)).toLocaleString("en-US", { minimumFractionDigits: dp, maximumFractionDigits: dp });
const when = (sec: number) => new Date(sec * 1000).toISOString().slice(0, 16).replace("T", " ") + " UTC";
const days = (sec: bigint | undefined) => (sec === undefined ? "—" : `${Number(sec) / 86400} days`);

type Draw = readonly [string, bigint, bigint, boolean, boolean];

export default function StakeView() {
  const { address, connected, wrongNetwork, setWalletModalOpen, switchToUseCert, pushToast, settleToast, dismissToast, now } = useDashboard();
  const me = address ?? ZERO;
  const publicClient = usePublicClient({ chainId: CHAIN_ID });
  const { mutateAsync } = useWriteContract();
  const [amount, setAmount] = useState("");
  const [busy, setBusy] = useState<string | null>(null);
  const [note, setNote] = useState<{ tone: "ok" | "warn"; text: string } | null>(null);

  const reads = useReadContracts({
    contracts: [
      { ...POOL, functionName: "totalAssets" },
      { ...POOL, functionName: "totalSupply" },
      { ...POOL, functionName: "depositCap" },
      { ...POOL, functionName: "convertToAssets", args: [10n ** BigInt(INSURANCE_SHARE_DECIMALS)] },
      { ...POOL, functionName: "drawPending" },
      { ...POOL, functionName: "drawCount" },
      { ...POOL, functionName: "cooldown" },
      { ...POOL, functionName: "withdrawWindow" },
      { ...POOL, functionName: "drawDelay" },
      { ...POOL, functionName: "maxDrawBps" },
      { ...POOL, functionName: "maxDeposit", args: [me] },
      { ...POOL, functionName: "balanceOf", args: [me] },
      { ...POOL, functionName: "withdrawRequests", args: [me] },
      { ...POOL, functionName: "maxRedeem", args: [me] },
      { ...USDG, functionName: "balanceOf", args: [me] },
      { ...USDG, functionName: "allowance", args: [me, INSURANCE_ADDRESS] },
    ],
    query: { refetchInterval: 15_000 },
  });
  const r = reads.data;
  const v = <T,>(i: number) => (r?.[i]?.status === "success" ? (r[i].result as T) : undefined);
  const totalAssets = v<bigint>(0), totalSupply = v<bigint>(1), cap = v<bigint>(2), pricePerShare = v<bigint>(3);
  const drawPending = v<boolean>(4), drawCount = v<bigint>(5), cooldown = v<bigint>(6), window_ = v<bigint>(7);
  const drawDelay = v<bigint>(8), maxDrawBps = v<bigint>(9), room = v<bigint>(10), shares = v<bigint>(11);
  const req = v<readonly [bigint, bigint]>(12), redeemable = v<bigint>(13), wallet = v<bigint>(14), allowance = v<bigint>(15);

  const drawReads = useReadContracts({
    contracts: Array.from({ length: Number(drawCount ?? 0n) }, (_, i) => ({ ...POOL, functionName: "draws" as const, args: [BigInt(i)] as const })),
    query: { enabled: (drawCount ?? 0n) > 0n, refetchInterval: 30_000 },
  });

  const myValue = useMemo(
    () => (shares !== undefined && totalSupply && totalAssets !== undefined && totalSupply > 0n ? (shares * totalAssets) / totalSupply : shares === 0n ? 0n : undefined),
    [shares, totalSupply, totalAssets],
  );
  const amount6 = useMemo(() => {
    try {
      return amount.trim() === "" ? 0n : parseUnits(amount.trim(), 6);
    } catch {
      return -1n;
    }
  }, [amount]);

  const nowSec = Math.floor(now / 1000);
  const reqShares = req?.[0] ?? 0n;
  const readyAt = Number(req?.[1] ?? 0n);
  const closesAt = readyAt + Number(window_ ?? 0n);
  const reqState =
    reqShares === 0n ? "none" : nowSec < readyAt ? "cooling" : nowSec < closesAt ? "open" : "expired";

  const confirmed = useCallback(
    async (label: string, request: Parameters<typeof mutateAsync>[0]) => {
      setBusy(label);
      setNote(null);
      const t = pushToast({ state: "pending", title: label });
      try {
        const hash = await mutateAsync(request);
        const rc = await publicClient!.waitForTransactionReceipt({ hash });
        if (rc.status !== "success") throw new Error(`The transaction was mined but reverted on chain (${hash}). Nothing changed.`);
        settleToast(t, label, `${hash.slice(0, 10)}…`);
        setNote({ tone: "ok", text: `${label}: confirmed on chain. ${explorerTxUrl(hash)}` });
        void reads.refetch();
        return true;
      } catch (e) {
        dismissToast(t);
        setNote({ tone: "warn", text: e instanceof Error ? e.message.split("\n")[0] : String(e) });
        return false;
      } finally {
        setBusy(null);
      }
    },
    [mutateAsync, publicClient, pushToast, settleToast, dismissToast, reads],
  );

  const onDeposit = async () => {
    if (amount6 <= 0n || !address) return;
    if ((allowance ?? 0n) < amount6) {
      const ok = await confirmed("Approve USDG for the pool", { ...USDG, functionName: "approve", args: [INSURANCE_ADDRESS, amount6] });
      if (!ok) return;
    }
    if (await confirmed(`Deposit ${amount} USDG`, { ...POOL, functionName: "deposit", args: [amount6, address] })) setAmount("");
  };
  const onRequest = () => shares && confirmed("Request withdrawal", { ...POOL, functionName: "requestWithdraw", args: [shares] });
  const onCancel = () => confirmed("Cancel withdrawal request", { ...POOL, functionName: "cancelWithdraw" });
  const onRedeem = () =>
    redeemable && address && confirmed("Withdraw from the pool", { ...POOL, functionName: "redeem", args: [redeemable, address, address] });

  const gate = !connected ? "connect" : wrongNetwork ? "network" : null;
  const depositBlocked =
    gate !== null || drawPending === true || amount6 <= 0n || (room !== undefined && amount6 > room) || (wallet !== undefined && amount6 > wallet);

  const Btn = ({ label, onClick, disabled, id }: { label: string; onClick: () => void; disabled?: boolean; id: string }) => (
    <button
      type="button"
      onClick={onClick}
      disabled={disabled || busy !== null}
      className="flex items-center gap-2 border hairline-dark px-3 py-2 font-mono text-[10px] uppercase tracking-[0.08em] text-white transition-colors hover:bg-section-deep-2 disabled:pointer-events-none disabled:opacity-40"
    >
      {busy === id && <Loader2 size={11} className="animate-spin" />}
      {label}
    </button>
  );

  const Stat = ({ label, value, sub }: { label: string; value: string; sub?: string }) => (
    <Panel className="p-5">
      <MicroLabel className="text-[10px]">{label}</MicroLabel>
      <p className="mt-3 font-mono text-[26px] leading-none tabular-nums text-white">{value}</p>
      {sub && <p className="mt-2 font-mono text-[10px] uppercase tracking-[0.06em] text-white-60">{sub}</p>}
    </Panel>
  );

  return (
    <div className="mx-auto max-w-[1180px] px-4 py-8 md:px-8">
      <ViewHeader
        label="Staking · insurance pool"
        title={
          <>
            Insure the <span className="text-metallic">certificates.</span>
          </>
        }
        right={
          <p className="flex flex-wrap gap-2 font-mono text-[10px] uppercase tracking-[0.08em]">
            <span className="border border-green-bright/40 px-2 py-1 text-green-bright">live on mainnet</span>
            <span className="border border-warn/40 px-2 py-1 text-warn">unaudited · capped at {usd(cap, 0)} USDG</span>
          </p>
        }
      />

      <p className="mt-6 max-w-[80ch] text-[14px] leading-[1.6] text-silver">
        Stake USDG as the first-loss layer behind the vaults. If a vault's own buffer is ever not enough, the 2-of-3 Safe
        can propose a draw: after a public delay the USDG moves into that vault, where it backs holders, and every
        staker shares the loss in proportion to their stake. Holders are never behind stakers.
      </p>

      <div className="mt-6 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <Stagger index={0}><Stat label="Pool assets" value={`${usd(totalAssets)} USDG`} sub={`cap ${usd(cap, 0)} USDG · room ${usd(room)} USDG`} /></Stagger>
        <Stagger index={1}><Stat label="Value per share" value={pricePerShare === undefined ? "—" : Number(formatUnits(pricePerShare, 6)).toFixed(6)} sub="USDG per share · rises with income, falls with a draw" /></Stagger>
        <Stagger index={2}><Stat label="Your stake" value={`${usd(myValue)} USDG`} sub={shares === undefined || !address ? "connect a wallet" : `${Number(formatUnits(shares, INSURANCE_SHARE_DECIMALS)).toLocaleString("en-US", { maximumFractionDigits: 4 })} shares`} /></Stagger>
        <Stagger index={3}><Stat label="Draws" value={drawPending ? "PENDING" : "none pending"} sub={`${drawCount ?? "—"} proposed ever`} /></Stagger>
      </div>

      <div className="mt-3 grid gap-3 lg:grid-cols-2">
        <Stagger index={4}>
          <Panel className="p-5">
            <MicroLabel>Deposit</MicroLabel>
            <div className="mt-3 flex flex-wrap items-center gap-2">
              <input
                value={amount}
                onChange={(e) => setAmount(e.target.value.replace(/[^\d.]/g, ""))}
                inputMode="decimal"
                placeholder="USDG"
                className="min-w-0 flex-1 border hairline-dark bg-[#0d0f0d] px-3 py-2 font-mono text-[12px] tabular-nums text-white outline-none placeholder:text-white-60/40 focus:border-green-bright"
              />
              {gate === "connect" ? (
                <Btn id="c" label="Connect wallet" onClick={() => setWalletModalOpen(true)} />
              ) : gate === "network" ? (
                <Btn id="n" label="Switch network" onClick={switchToUseCert} />
              ) : (
                <Btn id={`Deposit ${amount} USDG`} label={(allowance ?? 0n) < amount6 && amount6 > 0n ? "Approve & deposit" : "Deposit"} onClick={() => void onDeposit()} disabled={depositBlocked} />
              )}
            </div>
            <p className="mt-2 font-mono text-[10px] uppercase leading-[1.6] tracking-[0.06em] text-white-60/80">
              {`Wallet ${usd(wallet)} USDG. `}
              {drawPending ? "Deposits are paused while a draw is pending, so nobody walks into an announced loss." : `Room under the cap: ${usd(room)} USDG.`}
            </p>
          </Panel>
        </Stagger>

        <Stagger index={5}>
          <Panel className="p-5">
            <MicroLabel>Withdraw</MicroLabel>
            <p className="mt-3 font-mono text-[11px] leading-[1.7] text-silver">
              {reqState === "none" && `No withdrawal requested. Withdrawing takes a ${days(cooldown)} cooldown, then a ${days(window_)} window to complete it.`}
              {reqState === "cooling" && `Requested. Your window opens ${when(readyAt)} and closes ${when(closesAt)}. The shares keep earning and keep sharing any draw until you withdraw.`}
              {reqState === "open" && `Your window is open until ${when(closesAt)}.${drawPending ? " Paused: a draw is pending." : ""}`}
              {reqState === "expired" && `Your window closed ${when(closesAt)} without a withdrawal. Request again to restart the cooldown.`}
            </p>
            <div className="mt-3 flex flex-wrap gap-2">
              {(reqState === "none" || reqState === "expired") && (
                <Btn id="Request withdrawal" label="Request withdrawal (all shares)" onClick={() => void onRequest()} disabled={gate !== null || !shares} />
              )}
              {(reqState === "cooling" || reqState === "open") && <Btn id="Cancel withdrawal request" label="Cancel request" onClick={() => void onCancel()} disabled={gate !== null} />}
              {reqState === "open" && (
                <Btn id="Withdraw from the pool" label={`Withdraw ${usd(redeemable && totalSupply ? (redeemable * (totalAssets ?? 0n)) / totalSupply : 0n)} USDG`} onClick={() => void onRedeem()} disabled={gate !== null || !redeemable} />
              )}
            </div>
          </Panel>
        </Stagger>
      </div>

      {note && (
        <p className={cn("mt-3 break-all font-mono text-[11px]", note.tone === "ok" ? "text-green-bright" : "text-warn")}>{note.text}</p>
      )}

      <Stagger index={6}>
        <Panel className="mt-3 p-5">
          <MicroLabel>The rules, fixed in the contract</MicroLabel>
          <ul className="mt-3 grid gap-2 font-mono text-[11px] leading-[1.6] text-silver md:grid-cols-2">
            <li>Loss order: vault buffer → this pool → never holder backing.</li>
            <li>{`Draws: proposed by the 2-of-3 Safe, executable after ${days(drawDelay)}, expire 3 days later.`}</li>
            <li>{`Each draw at most ${maxDrawBps === undefined ? "—" : Number(maxDrawBps) / 100}% of the pool, and only to a registered UseCert vault.`}</li>
            <li>At least 7 days between two draw proposals, so stakers are never held in place.</li>
            <li>While a draw is pending, deposits and withdrawals pause.</li>
            <li>{`Deposit cap ${usd(cap, 0)} USDG. No owner, no upgrade: every parameter is immutable.`}</li>
          </ul>
        </Panel>
      </Stagger>

      <Stagger index={7}>
        <Panel className="mt-3 p-5">
          <MicroLabel>Income, stated plainly</MicroLabel>
          <p className="mt-3 max-w-[90ch] text-[13px] leading-[1.6] text-silver">
            There is no automatic income today. Anything sent to the pool raises the value per share for every staker, but
            nothing sends anything yet: routing 70% of the vaults' fees to this pool is written and tested (K2) and needs a
            new vault version before it can go live. There are no token emissions. The pool's return is only real income,
            minus any draw.
          </p>
        </Panel>
      </Stagger>

      <Stagger index={8}>
        <Panel className="mt-3 p-5">
          <MicroLabel>Draw history</MicroLabel>
          {(drawCount ?? 0n) === 0n ? (
            <p className="mt-3 font-mono text-[11px] uppercase tracking-[0.06em] text-white-60">No draw has ever been proposed.</p>
          ) : (
            <ul className="mt-3 font-mono text-[11px] text-silver">
              {(drawReads.data ?? []).map((d, i) => {
                const x = d.status === "success" ? (d.result as unknown as Draw) : null;
                if (!x) return null;
                const execAt = Number(x[2]);
                const st = x[3] ? "executed" : x[4] ? "cancelled" : nowSec >= execAt + 3 * 86400 ? "expired" : nowSec >= execAt ? "executable" : "in delay";
                return <li key={i}>{`#${i} · ${usd(x[1])} USDG to ${x[0].slice(0, 10)}… · executable ${when(execAt)} · ${st}`}</li>;
              })}
            </ul>
          )}
        </Panel>
      </Stagger>

      <p className="mt-6 flex flex-wrap gap-x-4 gap-y-1 font-mono text-[10px] uppercase tracking-[0.06em] text-white-60">
        <a href={explorerAddressUrl(INSURANCE_ADDRESS)} target="_blank" rel="noreferrer noopener" className="inline-flex items-center gap-1 underline decoration-white/20 underline-offset-2 hover:text-green-bright">
          pool contract {INSURANCE_ADDRESS.slice(0, 10)}… <ArrowUpRight size={10} />
        </a>
        <a href={`https://sourcify.dev/#/lookup/${INSURANCE_ADDRESS}`} target="_blank" rel="noreferrer noopener" className="inline-flex items-center gap-1 underline decoration-white/20 underline-offset-2 hover:text-green-bright">
          Sourcify: exact match <ArrowUpRight size={10} />
        </a>
        <a href={explorerTxUrl(INSURANCE_DEPLOY_TX)} target="_blank" rel="noreferrer noopener" className="inline-flex items-center gap-1 underline decoration-white/20 underline-offset-2 hover:text-green-bright">
          deployment tx <ArrowUpRight size={10} />
        </a>
        <span>{`Updated ${reads.dataUpdatedAt ? Math.round((now - reads.dataUpdatedAt) / 1000) : "—"}s ago`}</span>
      </p>

      <CertStakePanel />
    </div>
  );
}
