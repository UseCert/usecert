import { useCallback, useMemo, useState } from "react";
import { formatUnits, parseUnits } from "viem";
import { usePublicClient, useReadContracts, useWriteContract } from "wagmi";
import { ArrowUpRight, Loader2 } from "lucide-react";
import { CHAIN_ID } from "@/chain/deployment";
import { CertificateABI } from "@/chain/contracts";
import { explorerAddressUrl, explorerTxUrl } from "@/chain/config";
import { CERT_STAKING_ADDRESS, CERT_STAKING_DEPLOY_TX, CERT_TOKEN, CertStakingABI } from "@/chain/certStaking";
import { useDashboard } from "./store";
import { MicroLabel, Panel, Stagger } from "./ui";
import { cn } from "@/lib/utils";

/**
 * CERT staking: a share of the buyback fund's fee income, streamed in USDG. Not insurance -
 * staked CERT is never drawn. Every figure is a chain read of CertStaking. No APR is shown:
 * with rewards funded by hand and no fee routing live, an annualised rate would be a forecast
 * dressed as a fact.
 */
const POOL = { address: CERT_STAKING_ADDRESS, abi: CertStakingABI, chainId: CHAIN_ID } as const;
// Any ERC-20 ABI serves for CERT's balanceOf / allowance / approve; the certificate ABI is one.
const CERT = { address: CERT_TOKEN, abi: CertificateABI, chainId: CHAIN_ID } as const;
const ZERO = "0x0000000000000000000000000000000000000000" as const;

const cert = (v: bigint | undefined, dp = 2) =>
  v === undefined ? "—" : Number(formatUnits(v, 18)).toLocaleString("en-US", { maximumFractionDigits: dp });
const usd = (v: bigint | undefined, dp = 2) =>
  v === undefined ? "—" : Number(formatUnits(v, 6)).toLocaleString("en-US", { minimumFractionDigits: dp, maximumFractionDigits: Math.max(dp, 2) });
const when = (sec: number) => new Date(sec * 1000).toISOString().slice(0, 16).replace("T", " ") + " UTC";

export default function CertStakePanel() {
  const { address, connected, wrongNetwork, setWalletModalOpen, switchToUseCert, pushToast, settleToast, dismissToast, now } = useDashboard();
  const me = address ?? ZERO;
  const publicClient = usePublicClient({ chainId: CHAIN_ID });
  const { mutateAsync } = useWriteContract();
  const [amount, setAmount] = useState("");
  const [busy, setBusy] = useState<string | null>(null);
  const [note, setNote] = useState<{ tone: "ok" | "warn"; text: string } | null>(null);

  const reads = useReadContracts({
    contracts: [
      { ...POOL, functionName: "totalStaked" },
      { ...POOL, functionName: "stakeCap" },
      { ...POOL, functionName: "rewardRate" },
      { ...POOL, functionName: "periodFinish" },
      { ...POOL, functionName: "remainingReward" },
      { ...POOL, functionName: "unallocated" },
      { ...POOL, functionName: "balanceOf", args: [me] },
      { ...POOL, functionName: "earned", args: [me] },
      { ...CERT, functionName: "balanceOf", args: [me] },
      { ...CERT, functionName: "allowance", args: [me, CERT_STAKING_ADDRESS] },
    ],
    query: { refetchInterval: 15_000 },
  });
  const r = reads.data;
  const v = <T,>(i: number) => (r?.[i]?.status === "success" ? (r[i].result as T) : undefined);
  const total = v<bigint>(0), cap = v<bigint>(1), rate = v<bigint>(2), finish = v<bigint>(3);
  const remaining = v<bigint>(4), unallocated = v<bigint>(5), mine = v<bigint>(6), earned = v<bigint>(7);
  const wallet = v<bigint>(8), allowance = v<bigint>(9);

  const nowSec = Math.floor(now / 1000);
  const streaming = finish !== undefined && Number(finish) > nowSec && (rate ?? 0n) > 0n;
  const perDay = rate === undefined ? undefined : (rate * 86_400n) / 10n ** 18n;
  const amount18 = useMemo(() => {
    try {
      return amount.trim() === "" ? 0n : parseUnits(amount.trim(), 18);
    } catch {
      return -1n;
    }
  }, [amount]);

  const send = useCallback(
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

  const onStake = async () => {
    if (amount18 <= 0n) return;
    if ((allowance ?? 0n) < amount18) {
      if (!(await send("Approve CERT for staking", { ...CERT, functionName: "approve", args: [CERT_STAKING_ADDRESS, amount18] }))) return;
    }
    if (await send(`Stake ${amount} CERT`, { ...POOL, functionName: "stake", args: [amount18] })) setAmount("");
  };
  const onWithdraw = () => mine && send("Withdraw all staked CERT", { ...POOL, functionName: "withdraw", args: [mine] });
  const onClaim = () => send("Claim USDG reward", { ...POOL, functionName: "getReward" });

  const gate = !connected ? "connect" : wrongNetwork ? "network" : null;
  const room = cap !== undefined && total !== undefined ? (cap > total ? cap - total : 0n) : undefined;
  const stakeBlocked = gate !== null || amount18 <= 0n || (room !== undefined && amount18 > room) || (wallet !== undefined && amount18 > wallet);

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
      <p className="mt-3 font-mono text-[24px] leading-none tabular-nums text-white">{value}</p>
      {sub && <p className="mt-2 font-mono text-[10px] uppercase tracking-[0.06em] text-white-60">{sub}</p>}
    </Panel>
  );

  return (
    <section className="mt-14 border-t hairline-dark pt-10">
      <div className="flex flex-wrap items-end justify-between gap-4">
        <div>
          <MicroLabel>CERT staking · share of the buyback fund</MicroLabel>
          <h2 className="mt-3 text-[28px] font-semibold uppercase leading-[0.95] tracking-[-0.04em] md:text-[40px]">
            Stake CERT, <span className="text-metallic">share the fees.</span>
          </h2>
        </div>
        <p className="flex flex-wrap gap-2 font-mono text-[10px] uppercase tracking-[0.08em]">
          <span className="border border-green-bright/40 px-2 py-1 text-green-bright">live on mainnet</span>
          <span className="border border-warn/40 px-2 py-1 text-warn">unaudited · capped at {cert(cap, 0)} CERT</span>
        </p>
      </div>
      <p className="mt-5 max-w-[82ch] text-[14px] leading-[1.6] text-silver">
        Stake CERT and receive a share of the buyback fund&apos;s income: the 20% of protocol fees in the 70/20/5/5 split,
        paid in USDG and streamed to stakers pro rata over 7 days. This is not insurance: staked CERT is never drawn to
        cover a loss, and you can withdraw at any time.
      </p>

      <div className="mt-6 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <Stagger index={9}><Stat label="Total staked" value={`${cert(total, 0)} CERT`} sub={`cap ${cert(cap, 0)} · room ${cert(room, 0)}`} /></Stagger>
        <Stagger index={10}><Stat label="Streaming now" value={streaming ? `${usd(perDay)} USDG/day` : "nothing"} sub={streaming ? `until ${when(Number(finish))} · ${usd(remaining)} left` : "no reward is being streamed"} /></Stagger>
        <Stagger index={11}><Stat label="Your stake" value={`${cert(mine)} CERT`} sub={address ? `wallet ${cert(wallet)} CERT` : "connect a wallet"} /></Stagger>
        <Stagger index={12}><Stat label="Your reward" value={`${usd(earned, 4)} USDG`} sub="earned, claimable any time" /></Stagger>
      </div>

      <div className="mt-3 grid gap-3 lg:grid-cols-2">
        <Stagger index={13}>
          <Panel className="p-5">
            <MicroLabel>Stake</MicroLabel>
            <div className="mt-3 flex flex-wrap items-center gap-2">
              <input
                value={amount}
                onChange={(e) => setAmount(e.target.value.replace(/[^\d.]/g, ""))}
                inputMode="decimal"
                placeholder="CERT"
                className="min-w-0 flex-1 border hairline-dark bg-[#0d0f0d] px-3 py-2 font-mono text-[12px] tabular-nums text-white outline-none placeholder:text-white-60/40 focus:border-green-bright"
              />
              {gate === "connect" ? (
                <Btn id="c2" label="Connect wallet" onClick={() => setWalletModalOpen(true)} />
              ) : gate === "network" ? (
                <Btn id="n2" label="Switch network" onClick={switchToUseCert} />
              ) : (
                <Btn id={`Stake ${amount} CERT`} label={(allowance ?? 0n) < amount18 && amount18 > 0n ? "Approve & stake" : "Stake"} onClick={() => void onStake()} disabled={stakeBlocked} />
              )}
            </div>
          </Panel>
        </Stagger>
        <Stagger index={14}>
          <Panel className="p-5">
            <MicroLabel>Withdraw and claim</MicroLabel>
            <div className="mt-3 flex flex-wrap gap-2">
              <Btn id="Claim USDG reward" label={`Claim ${usd(earned, 4)} USDG`} onClick={() => void onClaim()} disabled={gate !== null || !earned} />
              <Btn id="Withdraw all staked CERT" label="Withdraw all CERT" onClick={() => void onWithdraw()} disabled={gate !== null || !mine} />
            </div>
            <p className="mt-2 font-mono text-[10px] uppercase leading-[1.6] tracking-[0.06em] text-white-60/80">
              No cooldown: withdrawing keeps what you have already earned, and it stays claimable.
            </p>
          </Panel>
        </Stagger>
      </div>

      {note && <p className={cn("mt-3 break-all font-mono text-[11px]", note.tone === "ok" ? "text-green-bright" : "text-warn")}>{note.text}</p>}

      <Stagger index={15}>
        <Panel className="mt-3 p-5">
          <MicroLabel>Rewards, stated plainly</MicroLabel>
          <p className="mt-3 max-w-[90ch] text-[13px] leading-[1.6] text-silver">
            Rewards exist only when someone pays them in. Anyone can fund the pool, and the buyback fund&apos;s share of fees
            will once fee routing (K2, a new vault version) is live; until then there is no automatic income. No annual rate is
            shown, because with rewards funded by hand any such figure would be a forecast, not a fact. There are no token
            emissions. Reward funded while nobody is staked is not lost: it is carried into the next stream
            {unallocated !== undefined && unallocated > 0n ? ` (${usd(unallocated, 4)} USDG carried now)` : ""}.
          </p>
        </Panel>
      </Stagger>

      <p className="mt-6 flex flex-wrap gap-x-4 gap-y-1 font-mono text-[10px] uppercase tracking-[0.06em] text-white-60">
        <a href={explorerAddressUrl(CERT_STAKING_ADDRESS)} target="_blank" rel="noreferrer noopener" className="inline-flex items-center gap-1 underline decoration-white/20 underline-offset-2 hover:text-green-bright">
          staking contract {CERT_STAKING_ADDRESS.slice(0, 10)}… <ArrowUpRight size={10} />
        </a>
        <a href={`https://sourcify.dev/#/lookup/${CERT_STAKING_ADDRESS}`} target="_blank" rel="noreferrer noopener" className="inline-flex items-center gap-1 underline decoration-white/20 underline-offset-2 hover:text-green-bright">
          Sourcify: exact match <ArrowUpRight size={10} />
        </a>
        <a href={explorerTxUrl(CERT_STAKING_DEPLOY_TX)} target="_blank" rel="noreferrer noopener" className="inline-flex items-center gap-1 underline decoration-white/20 underline-offset-2 hover:text-green-bright">
          deployment tx <ArrowUpRight size={10} />
        </a>
      </p>
    </section>
  );
}
