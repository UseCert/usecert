import { useCallback, useMemo, useState } from "react";
import { formatUnits, parseUnits } from "viem";
import { usePublicClient, useReadContracts, useWriteContract } from "wagmi";
import { ArrowUpRight, Loader2 } from "lucide-react";
import { CHAIN_ID, IS_STACK5 } from "@/chain/deployment";
import { SHARED, TestUSDGABI } from "@/chain/contracts";
import { Stack5InsuranceStakingABI } from "@/chain/contracts.stack5";
import { explorerAddressUrl, explorerTxUrl } from "@/chain/config";
import { INSURANCE_SHARE_DECIMALS } from "@/chain/insurance";
import { decodeRevert } from "@/chain/useActions";
import { useDashboard } from "./store";
import { MicroLabel, Panel, Stagger, ViewHeader } from "./ui";
import { cn } from "@/lib/utils";
import CertStakePanel from "./CertStakePanel";

/**
 * The insurance pool, STACK 5: InsuranceStaking v2. Rendered by StakeView only on a stack-5
 * bundle AND once the v2 address is recorded in insurance.ts; every other build shows v1.
 *
 * What v2 changes for a staker, and what this screen therefore shows differently:
 *  - requestWithdraw MOVES the shares into escrow (H-9). The wallet's share balance drops by the
 *    amount requested, so "your stake" is wallet shares PLUS escrowed shares, shown apart.
 *    cancelWithdraw returns them, at any time - which is also how an expired request is reclaimed.
 *  - income vests over 7 days before it counts in the share price (M-14): `unvestedIncome()` and
 *    `vestingEnd()` are shown, and `totalAssets()` already excludes what has not vested.
 *  - the deposit cap is on `netPrincipal` (L-16), so income never uses up room; `maxDeposit()`
 *    already reflects it and is what the form checks against.
 * Every figure is a chain read of the pool; nothing is computed from a model.
 */
const USDG = { address: SHARED.collateral, abi: TestUSDGABI, chainId: CHAIN_ID } as const;
const ZERO = "0x0000000000000000000000000000000000000000" as const;
/** OZ ERC4626 virtual shares: 10 ** _decimalsOffset(), the offset being 6 (12-decimal shares over 6-decimal USDG). */
const VIRTUAL_SHARES = 1_000_000n;

const usd = (v: bigint | undefined, dp = 2) =>
  v === undefined ? "—" : Number(formatUnits(v, 6)).toLocaleString("en-US", { minimumFractionDigits: dp, maximumFractionDigits: dp });
const when = (sec: number) => new Date(sec * 1000).toISOString().slice(0, 16).replace("T", " ") + " UTC";
const days = (sec: bigint | undefined) => (sec === undefined ? "—" : `${Number(sec) / 86400} days`);
const sharesFmt = (v: bigint | undefined) =>
  v === undefined ? "—" : Number(formatUnits(v, INSURANCE_SHARE_DECIMALS)).toLocaleString("en-US", { maximumFractionDigits: 4 });

/** v2 `draws(i)`: vault, amount, executableAt, executed, cancelled, executedAt, paid. */
type DrawV2 = readonly [string, bigint, bigint, boolean, boolean, bigint, bigint];

export default function StakeViewV2({ pool, deployTx }: { pool: `0x${string}`; deployTx: `0x${string}` | undefined }) {
  const { address, connected, wrongNetwork, setWalletModalOpen, switchToUseCert, pushToast, settleToast, dismissToast, now } = useDashboard();
  const me = address ?? ZERO;
  const publicClient = usePublicClient({ chainId: CHAIN_ID });
  const { mutateAsync } = useWriteContract();
  const [amount, setAmount] = useState("");
  const [reqAmt, setReqAmt] = useState("");
  const [busy, setBusy] = useState<string | null>(null);
  const [note, setNote] = useState<{ tone: "ok" | "warn"; text: string } | null>(null);

  const POOL = { address: pool, abi: Stack5InsuranceStakingABI, chainId: CHAIN_ID } as const;

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
      { ...USDG, functionName: "allowance", args: [me, pool] },
      { ...POOL, functionName: "unvestedIncome" },
      { ...POOL, functionName: "vestingEnd" },
      { ...POOL, functionName: "netPrincipal" },
      { ...POOL, functionName: "registrationDelay" },
      { ...POOL, functionName: "drawCap" },
      { ...POOL, functionName: "drawnInPeriod" },
    ],
    query: { refetchInterval: 15_000 },
  });
  const r = reads.data;
  const v = <T,>(i: number) => (r?.[i]?.status === "success" ? (r[i].result as T) : undefined);
  const totalAssets = v<bigint>(0), totalSupply = v<bigint>(1), cap = v<bigint>(2), pricePerShare = v<bigint>(3);
  const drawPending = v<boolean>(4), drawCount = v<bigint>(5), cooldown = v<bigint>(6), window_ = v<bigint>(7);
  const drawDelay = v<bigint>(8), maxDrawBps = v<bigint>(9), room = v<bigint>(10), walletShares = v<bigint>(11);
  const req = v<readonly [bigint, bigint]>(12), redeemable = v<bigint>(13), wallet = v<bigint>(14), allowance = v<bigint>(15);
  const unvested = v<bigint>(16), vestingEnd = v<bigint>(17), netPrincipal = v<bigint>(18), registrationDelay = v<bigint>(19);
  const drawCap = v<bigint>(20), drawnInPeriod = v<bigint>(21);

  const drawReads = useReadContracts({
    contracts: Array.from({ length: Number(drawCount ?? 0n) }, (_, i) => ({ ...POOL, functionName: "draws" as const, args: [BigInt(i)] as const })),
    query: { enabled: (drawCount ?? 0n) > 0n, refetchInterval: 30_000 },
  });

  // Escrowed shares are held by the pool, not the wallet, and still belong to the staker.
  const escrowed = req?.[0] ?? 0n;
  const ownShares = walletShares === undefined ? undefined : walletShares + escrowed;
  // The contract's own conversion (OZ ERC4626 with a 6-decimal virtual offset), not a plain ratio:
  // assets = shares * (totalAssets + 1) / (totalSupply + 1e6), floored. Staking v2 review I-07.
  const assetsOf = (sh: bigint | undefined): bigint | undefined =>
    sh === undefined || totalAssets === undefined || totalSupply === undefined ? undefined : (sh * (totalAssets + 1n)) / (totalSupply + VIRTUAL_SHARES);
  const sharesOf = (a: bigint): bigint | undefined =>
    totalAssets === undefined || totalSupply === undefined ? undefined : (a * (totalSupply + VIRTUAL_SHARES)) / (totalAssets + 1n);
  const myValue = assetsOf(ownShares);
  // A partial request (I-07): an amount of USDG, converted to shares and capped at what the staker
  // holds. Empty means every share, as before.
  const reqAssets6 = useMemo(() => {
    try {
      return reqAmt.trim() === "" ? 0n : parseUnits(reqAmt.trim(), 6);
    } catch {
      return -1n;
    }
  }, [reqAmt]);
  const reqShares = (() => {
    if (ownShares === undefined || reqAssets6 < 0n) return undefined;
    if (reqAssets6 === 0n) return ownShares;
    const s = sharesOf(reqAssets6);
    return s === undefined ? undefined : s > ownShares ? ownShares : s;
  })();
  const amount6 = useMemo(() => {
    try {
      return amount.trim() === "" ? 0n : parseUnits(amount.trim(), 6);
    } catch {
      return -1n;
    }
  }, [amount]);

  const nowSec = Math.floor(now / 1000);
  const readyAt = Number(req?.[1] ?? 0n);
  const closesAt = readyAt + Number(window_ ?? 0n);
  const reqState =
    escrowed === 0n ? "none" : nowSec < readyAt ? "cooling" : nowSec < closesAt ? "open" : "expired";
  const vestingUntil = Number(vestingEnd ?? 0n);

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
        // Stack 5 errors are in the v2 ABI, so a revert decodes into a sentence rather than a code.
        setNote({ tone: "warn", text: decodeRevert(e).message });
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
      const ok = await confirmed("Approve USDG for the pool", { ...USDG, functionName: "approve", args: [pool, amount6] });
      if (!ok) return;
    }
    if (await confirmed(`Deposit ${amount} USDG`, { ...POOL, functionName: "deposit", args: [amount6, address] })) setAmount("");
  };
  /** Escrows `reqShares` (every share when the amount is empty). A new request replaces the old one. */
  const onRequest = async () => {
    if (!reqShares || reqShares <= 0n) return;
    if (await confirmed("Request withdrawal", { ...POOL, functionName: "requestWithdraw", args: [reqShares] })) setReqAmt("");
  };
  const onCancel = () => confirmed("Cancel withdrawal request", { ...POOL, functionName: "cancelWithdraw" });
  const onReclaim = () => confirmed("Reclaim escrowed shares", { ...POOL, functionName: "cancelWithdraw" });
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
            <span className="border border-warn/40 px-2 py-1 text-warn">{`unaudited · principal capped at ${usd(cap, 0)} USDG`}</span>
          </p>
        }
      />

      <p className="mt-6 max-w-[80ch] text-[14px] leading-[1.6] text-silver">
        Stake USDG as the first-loss layer behind the vaults. If a vault's own buffer is ever not enough, the 2-of-3 Safe
        can propose a draw: after a public delay the USDG moves into that vault, where it backs holders, and every
        staker shares the loss in proportion to their stake. Holders are never behind stakers.
      </p>

      <div className="mt-6 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <Stagger index={0}><Stat label="Pool assets" value={`${usd(totalAssets)} USDG`} sub={`principal ${usd(netPrincipal)} of ${usd(cap, 0)} USDG · room ${usd(room)} USDG`} /></Stagger>
        <Stagger index={1}><Stat label="Value per share" value={pricePerShare === undefined ? "—" : Number(formatUnits(pricePerShare, 6)).toFixed(6)} sub="USDG per share · rises as income vests, falls with a draw" /></Stagger>
        <Stagger index={2}><Stat label="Your stake" value={`${usd(myValue)} USDG`} sub={walletShares === undefined || !address ? "connect a wallet" : `${sharesFmt(walletShares)} shares in wallet · ${sharesFmt(escrowed)} in escrow`} /></Stagger>
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
              {drawPending
                ? "Deposits are paused while a draw is pending, so nobody walks into an announced loss."
                : `Room under the cap: ${usd(room)} USDG. The cap counts deposited principal only; income never uses it up.`}
            </p>
          </Panel>
        </Stagger>

        <Stagger index={5}>
          <Panel className="p-5">
            <MicroLabel>Withdraw</MicroLabel>
            <p className="mt-3 font-mono text-[11px] leading-[1.7] text-silver">
              {reqState === "none" &&
                `No withdrawal requested. Requesting moves your shares into escrow for a ${days(cooldown)} cooldown, then a ${days(window_)} window to complete it. Escrowed shares keep earning and keep sharing any draw, and cannot be transferred.`}
              {reqState === "cooling" &&
                `Requested: ${sharesFmt(escrowed)} shares are in escrow. Your window opens ${when(readyAt)} and closes ${when(closesAt)}. Cancel at any time to get them back in your wallet.`}
              {reqState === "open" && `Your window is open until ${when(closesAt)}.${drawPending ? " Paused: a draw is pending." : ""}`}
              {reqState === "expired" &&
                `Your window closed ${when(closesAt)} without a withdrawal. Your ${sharesFmt(escrowed)} shares are still in escrow: reclaim them to your wallet, or request again to restart the cooldown.`}
            </p>
            <div className="mt-3 flex flex-wrap gap-2">
              {(reqState === "none" || reqState === "expired") && (
                <input
                  value={reqAmt}
                  onChange={(e) => setReqAmt(e.target.value.replace(/[^\d.]/g, ""))}
                  inputMode="decimal"
                  placeholder="USDG, empty = all"
                  className="min-w-0 flex-1 border hairline-dark bg-[#0d0f0d] px-3 py-2 font-mono text-[12px] tabular-nums text-white outline-none placeholder:text-white-60/40 focus:border-green-bright"
                />
              )}
              {reqState === "none" && (
                <Btn
                  id="Request withdrawal"
                  label={reqAmt.trim() === "" ? "Request withdrawal (all shares)" : "Request withdrawal"}
                  onClick={() => void onRequest()}
                  disabled={gate !== null || !reqShares}
                />
              )}
              {(reqState === "cooling" || reqState === "open") && <Btn id="Cancel withdrawal request" label="Cancel request" onClick={() => void onCancel()} disabled={gate !== null} />}
              {reqState === "open" && (
                <Btn id="Withdraw from the pool" label={`Withdraw ${usd(assetsOf(redeemable ?? 0n) ?? 0n)} USDG`} onClick={() => void onRedeem()} disabled={gate !== null || !redeemable} />
              )}
              {reqState === "expired" && (
                <>
                  <Btn id="Reclaim escrowed shares" label="Reclaim shares" onClick={() => void onReclaim()} disabled={gate !== null} />
                  <Btn id="Request withdrawal" label="Request again" onClick={() => void onRequest()} disabled={gate !== null || !reqShares} />
                </>
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
            <li>{`Draws in any 30 days total at most ${maxDrawBps === undefined ? "—" : Number(maxDrawBps) / 100}% of the pool, and each pays at most the vault's shortfall.`}</li>
            <li>{`Only to a UseCert vault registered for at least ${days(registrationDelay)} and not retired, so every staker can leave first.`}</li>
            <li>At least 7 days between two draw proposals, so stakers are never held in place.</li>
            <li>While a draw is pending, deposits and withdrawals pause.</li>
            <li>{`Deposit cap ${usd(cap, 0)} USDG of principal. No owner, no upgrade: every parameter is immutable.`}</li>
            <li>{`Drawn in the last 30 days: ${usd(drawnInPeriod)} USDG · a draw now could take at most ${usd(drawCap)} USDG.`}</li>
          </ul>
        </Panel>
      </Stagger>

      <Stagger index={7}>
        <Panel className="mt-3 p-5">
          <MicroLabel>Income, stated plainly</MicroLabel>
          <p className="mt-3 max-w-[90ch] text-[13px] leading-[1.6] text-silver">
            The pool&apos;s income is its 70% share of the vaults&apos; fees, paid in through the fee vault. Income vests over 7
            days before it counts in the value per share, so nobody can deposit just before a payment and leave with it. There
            are no token emissions. The pool&apos;s return is only real income, minus any draw.
            {IS_STACK5 ? "" : " The six vaults that pay these fees are deployed and registered but take no mints yet; until they do, income is zero."}
          </p>
          <p className="mt-3 font-mono text-[11px] leading-[1.6] text-silver">
            {unvested === undefined
              ? "—"
              : unvested === 0n
                ? "Nothing is vesting right now."
                : `Vesting now: ${usd(unvested)} USDG, fully counted by ${when(vestingUntil)}.`}
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
                const x = d.status === "success" ? (d.result as unknown as DrawV2) : null;
                if (!x) return null;
                const execAt = Number(x[2]);
                const st = x[3] ? `executed, paid ${usd(x[6])} USDG` : x[4] ? "cancelled" : nowSec >= execAt + 3 * 86400 ? "expired" : nowSec >= execAt ? "executable" : "in delay";
                return <li key={i}>{`#${i} · up to ${usd(x[1])} USDG to ${x[0].slice(0, 10)}… · executable ${when(execAt)} · ${st}`}</li>;
              })}
            </ul>
          )}
        </Panel>
      </Stagger>

      <p className="mt-6 flex flex-wrap gap-x-4 gap-y-1 font-mono text-[10px] uppercase tracking-[0.06em] text-white-60">
        <a href={explorerAddressUrl(pool)} target="_blank" rel="noreferrer noopener" className="inline-flex items-center gap-1 underline decoration-white/20 underline-offset-2 hover:text-green-bright">
          pool contract {pool.slice(0, 10)}… <ArrowUpRight size={10} />
        </a>
        <a href={`https://sourcify.dev/#/lookup/${pool}`} target="_blank" rel="noreferrer noopener" className="inline-flex items-center gap-1 underline decoration-white/20 underline-offset-2 hover:text-green-bright">
          Sourcify lookup <ArrowUpRight size={10} />
        </a>
        {deployTx && (
          <a href={explorerTxUrl(deployTx)} target="_blank" rel="noreferrer noopener" className="inline-flex items-center gap-1 underline decoration-white/20 underline-offset-2 hover:text-green-bright">
            deployment tx <ArrowUpRight size={10} />
          </a>
        )}
        <span>{`Updated ${reads.dataUpdatedAt ? Math.round((now - reads.dataUpdatedAt) / 1000) : "—"}s ago`}</span>
      </p>

      <CertStakePanel />
    </div>
  );
}
