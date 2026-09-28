import { useCallback, useMemo, useState } from "react";
import { formatUnits, parseUnits } from "viem";
import { usePublicClient, useReadContracts, useWriteContract } from "wagmi";
import { ArrowUpRight, Loader2 } from "lucide-react";
import { CHAIN_ID, IS_STACK5 } from "@/chain/deployment";
import { CertificateABI, SHARED, TestUSDGABI } from "@/chain/contracts";
import { Stack5CertStakingABI } from "@/chain/contracts.stack5";
import { explorerAddressUrl, explorerTxUrl } from "@/chain/config";
import { CERT_TOKEN } from "@/chain/certStaking";
import { decodeRevert } from "@/chain/useActions";
import { useDashboard } from "./store";
import { MicroLabel, Panel, Stagger } from "./ui";
import { cn } from "@/lib/utils";

/**
 * CERT staking, STACK 5: CertStaking v2. Rendered by CertStakePanel whenever the v2 address is
 * recorded in certStaking.ts (the address alone decides); v1 stays reachable for its stakers to leave.
 *
 * What v2 changes on this screen:
 *  - no funding form: the staking v2 review (M-01) showed a large funding late in a period is
 *    captured by whoever stakes just before it; rewards arrive through the hourly-pushed forwarder;
 *  - `exit()` with nothing staked just claims, so it is offered whenever there is a stake OR a
 *    reward, as one transaction;
 *  - `unallocated()` is a view that includes any stretch nobody was staked for.
 * Still not insurance: staked CERT is never drawn. Every figure is a chain read of the contract.
 */
const CERT = { address: CERT_TOKEN, abi: CertificateABI, chainId: CHAIN_ID } as const;
const USDG = { address: SHARED.collateral, abi: TestUSDGABI, chainId: CHAIN_ID } as const;
const ZERO = "0x0000000000000000000000000000000000000000" as const;

const cert = (v: bigint | undefined, dp = 2) =>
  v === undefined ? "—" : Number(formatUnits(v, 18)).toLocaleString("en-US", { maximumFractionDigits: dp });
const usd = (v: bigint | undefined, dp = 2) =>
  v === undefined ? "—" : Number(formatUnits(v, 6)).toLocaleString("en-US", { minimumFractionDigits: dp, maximumFractionDigits: Math.max(dp, 2) });
const when = (sec: number) => new Date(sec * 1000).toISOString().slice(0, 16).replace("T", " ") + " UTC";

export default function CertStakePanelV2({ pool, deployTx }: { pool: `0x${string}`; deployTx: `0x${string}` | undefined }) {
  const { address, connected, wrongNetwork, setWalletModalOpen, switchToUseCert, pushToast, settleToast, dismissToast, now } = useDashboard();
  const me = address ?? ZERO;
  const publicClient = usePublicClient({ chainId: CHAIN_ID });
  const { mutateAsync } = useWriteContract();
  const [amount, setAmount] = useState("");
  const [busy, setBusy] = useState<string | null>(null);
  const [note, setNote] = useState<{ tone: "ok" | "warn"; text: string } | null>(null);

  const POOL = { address: pool, abi: Stack5CertStakingABI, chainId: CHAIN_ID } as const;

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
      { ...CERT, functionName: "allowance", args: [me, pool] },
      { ...POOL, functionName: "minNotify" },
      { ...USDG, functionName: "balanceOf", args: [me] },
      { ...USDG, functionName: "allowance", args: [me, pool] },
    ],
    query: { refetchInterval: 15_000 },
  });
  const r = reads.data;
  const v = <T,>(i: number) => (r?.[i]?.status === "success" ? (r[i].result as T) : undefined);
  const total = v<bigint>(0), cap = v<bigint>(1), rate = v<bigint>(2), finish = v<bigint>(3);
  const remaining = v<bigint>(4), unallocated = v<bigint>(5), mine = v<bigint>(6), earned = v<bigint>(7);
  const wallet = v<bigint>(8), allowance = v<bigint>(9), minNotify = v<bigint>(10);
  const usdgWallet = v<bigint>(11), usdgAllowance = v<bigint>(12);

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
        setNote({ tone: "warn", text: decodeRevert(e).message });
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
      if (!(await send("Approve CERT for staking", { ...CERT, functionName: "approve", args: [pool, amount18] }))) return;
    }
    if (await send(`Stake ${amount} CERT`, { ...POOL, functionName: "stake", args: [amount18] })) setAmount("");
  };
  const onWithdraw = () => mine && send("Withdraw all staked CERT", { ...POOL, functionName: "withdraw", args: [mine] });
  const onClaim = () => send("Claim USDG reward", { ...POOL, functionName: "getReward" });
  const onExit = () => send("Withdraw all and claim", { ...POOL, functionName: "exit" });

  const gate = !connected ? "connect" : wrongNetwork ? "network" : null;
  const room = cap !== undefined && total !== undefined ? (cap > total ? cap - total : 0n) : undefined;
  const stakeBlocked = gate !== null || amount18 <= 0n || (room !== undefined && amount18 > room) || (wallet !== undefined && amount18 > wallet);
  const canExit = (mine ?? 0n) > 0n || (earned ?? 0n) > 0n;

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
          <span className="border border-warn/40 px-2 py-1 text-warn">{`unaudited · capped at ${cert(cap, 0)} CERT`}</span>
        </p>
      </div>
      <p className="mt-5 max-w-[82ch] text-[14px] leading-[1.6] text-silver">
        Stake CERT and receive a share of the buyback fund&apos;s income: the 20% of protocol fees in the 70/20/5/5 split,
        paid in USDG and streamed to stakers pro rata. This is not insurance: staked CERT is never drawn to cover a loss,
        and you can withdraw at any time.
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
              <Btn id="Withdraw all and claim" label="Exit: withdraw all and claim" onClick={() => void onExit()} disabled={gate !== null || !canExit} />
            </div>
            <p className="mt-2 font-mono text-[10px] uppercase leading-[1.6] tracking-[0.06em] text-white-60/80">
              No cooldown: withdrawing keeps what you have already earned, and it stays claimable. Exit does both in one transaction; with nothing staked it just claims.
            </p>
          </Panel>
        </Stagger>
      </div>

      <Stagger index={15}>
        <Panel className="mt-3 p-5">
          <MicroLabel>How rewards arrive</MicroLabel>
          <p className="mt-3 max-w-[90ch] font-mono text-[11px] leading-[1.7] text-silver">
            {`The buyback fund's share of the fees reaches this pool through the forwarder, which UseCert pushes every hour, so no large payment builds up for one moment. A funding during a running stream is spread over the time left and never moves its end; the contract refuses one below ${usd(minNotify)} USDG.`}
          </p>
        </Panel>
      </Stagger>

      {note && <p className={cn("mt-3 break-all font-mono text-[11px]", note.tone === "ok" ? "text-green-bright" : "text-warn")}>{note.text}</p>}

      <Stagger index={16}>
        <Panel className="mt-3 p-5">
          <MicroLabel>Rewards, stated plainly</MicroLabel>
          <p className="mt-3 max-w-[90ch] text-[13px] leading-[1.6] text-silver">
            Rewards exist only when someone pays them in: the buyback fund&apos;s share of the vaults&apos; fees is forwarded here,
            and anyone can add to it. No annual rate is shown, because it would be a forecast, not a fact. There are no token
            emissions. Reward funded while nobody is staked is not lost: it is carried into the next stream
            {unallocated !== undefined && unallocated > 0n ? ` (${usd(unallocated, 4)} USDG carried now)` : ""}.
            {IS_STACK5 ? "" : " The six vaults that pay these fees are deployed and registered but take no mints yet; until they do, income is zero."}
          </p>
        </Panel>
      </Stagger>

      <p className="mt-6 flex flex-wrap gap-x-4 gap-y-1 font-mono text-[10px] uppercase tracking-[0.06em] text-white-60">
        <a href={explorerAddressUrl(pool)} target="_blank" rel="noreferrer noopener" className="inline-flex items-center gap-1 underline decoration-white/20 underline-offset-2 hover:text-green-bright">
          staking contract {pool.slice(0, 10)}… <ArrowUpRight size={10} />
        </a>
        <a href={`https://sourcify.dev/#/lookup/${pool}`} target="_blank" rel="noreferrer noopener" className="inline-flex items-center gap-1 underline decoration-white/20 underline-offset-2 hover:text-green-bright">
          Sourcify lookup <ArrowUpRight size={10} />
        </a>
        {deployTx && (
          <a href={explorerTxUrl(deployTx)} target="_blank" rel="noreferrer noopener" className="inline-flex items-center gap-1 underline decoration-white/20 underline-offset-2 hover:text-green-bright">
            deployment tx <ArrowUpRight size={10} />
          </a>
        )}
      </p>
    </section>
  );
}
