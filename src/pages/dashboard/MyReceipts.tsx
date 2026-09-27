import { useMemo, useState } from "react";
import { useReadContracts } from "wagmi";
import { Loader2 } from "lucide-react";
import { CertVaultABI } from "@/chain/contracts";
import { Stack5CertVaultABI } from "@/chain/contracts.stack5";
import { CHAIN_ID, IS_STACK5 } from "@/chain/deployment";
import { fromCollateral } from "@/chain/units";
import { useStack5VaultTimes } from "@/chain/useStack5";
import { useFlows, type FlowEvent } from "@/chain/useFlows";
import { vaultAddresses, type ChainVaultId } from "@/chain/useVaults";
import { useDashboard } from "./store";
import { ExplorerSourcedTag, MicroLabel } from "./ui";
import { fmtAge, fmtNum } from "./format";

/**
 * The connected wallet's receipts on one vault, with the action each one needs.
 *
 * Two provenance classes, kept apart on purpose. WHICH receipts exist comes from the explorer
 * index (there is no receiptsOf(user) on chain), so the list carries the explorer tag. WHAT
 * STATE each one is in is a chain read of mintReceipts / redeemReceipts, so a stale or lagging
 * index can hide a receipt but can never show a paid one as claimable or the reverse.
 *
 * A mint whose hedge never fills is refunded by the keeper once the settle window passes; the
 * Refund button is the same two permissionless calls, for when a holder would rather not wait.
 */
export type ReceiptAction = {
  kind: "claim" | "refund";
  id: bigint;
  staged: boolean;
  /** Button text where it is not the kind's default (stack 5: "Claim rest" on a part-paid receipt). */
  label?: string;
};

type Row = {
  kind: "mint" | "redeem";
  id: bigint;
  timeMs: number | null;
  amount: string;
  status: string;
  tone: "open" | "done" | "wait";
  action: ReceiptAction | null;
  /** Every indexed event for this receipt, oldest first: the evidence timeline. */
  events: FlowEvent[];
};

const STEP_LABEL: Record<string, string> = {
  MINT_REQUESTED: "Mint request confirmed on chain",
  MINT_SETTLED: "Settlement observed: certificates issued",
  MINT_REFUNDED: "Refund observed: escrow returned",
  REDEEM_REQUESTED: "Redemption request confirmed on chain",
  FORCE_EXITED: "Force exit confirmed on chain",
  REDEEM_CLAIMED: "Claim observed: collateral paid",
};

/** A hedge normally fills in under a minute; before this, a refund would only revert. */
const REFUND_OFFER_AFTER_SEC = 15 * 60;

/** Unix seconds as "YYYY-MM-DD HH:MM UTC". */
const utcMinute = (sec: number) => new Date(sec * 1000).toISOString().slice(0, 16).replace("T", " ") + " UTC";

export function MyReceipts({
  asset,
  busy,
  disabled,
  onAction,
}: {
  asset: ChainVaultId;
  busy: bigint | null;
  disabled: boolean;
  onAction: (a: ReceiptAction) => void;
}) {
  const { address, now } = useDashboard();
  const history = useFlows({ address });
  const vault = vaultAddresses(asset).vault as `0x${string}`;

  const requests = useMemo(
    () =>
      (history.mine ?? []).filter(
        (f) =>
          f.vaultId === asset &&
          f.receiptId !== null &&
          (f.kind === "MINT_REQUESTED" || f.kind === "REDEEM_REQUESTED" || f.kind === "FORCE_EXITED"),
      ),
    [history.mine, asset],
  );

  const reads = useReadContracts({
    contracts: requests.map((f) => ({
      address: vault,
      abi: CertVaultABI,
      chainId: CHAIN_ID,
      functionName: f.kind === "MINT_REQUESTED" ? ("mintReceipts" as const) : ("redeemReceipts" as const),
      args: [BigInt(f.receiptId as string)] as const,
    })),
    query: { enabled: requests.length > 0, refetchInterval: 15_000 },
  });

  /**
   * STACK 5 ONLY, one read per receipt: `mintFee(id)` for a mint (a refund now returns the fee as
   * well as the escrow) and `redeemPaid(id)` for a redemption (a claim can be an instalment).
   * Disabled on stack 4, whose vault has neither mapping.
   */
  const reads5 = useReadContracts({
    contracts: requests.map((f) => ({
      address: vault,
      abi: Stack5CertVaultABI,
      chainId: CHAIN_ID,
      functionName: f.kind === "MINT_REQUESTED" ? ("mintFee" as const) : ("redeemPaid" as const),
      args: [BigInt(f.receiptId as string)] as const,
    })),
    query: { enabled: IS_STACK5 && requests.length > 0, refetchInterval: 15_000 },
  });
  const times5 = useStack5VaultTimes(asset);

  const rows = useMemo<Row[]>(() => {
    return requests.map((f, i) => {
      const id = BigInt(f.receiptId as string);
      const r = reads.data?.[i];
      const mint = f.kind === "MINT_REQUESTED";
      const amount = mint
        ? f.collateral !== null ? `${fmtNum(f.collateral, 2)} USDG in` : "—"
        : f.cert !== null ? `${fmtNum(f.cert, 4)} burned` : "—";
      const kinds = mint ? ["MINT_REQUESTED", "MINT_SETTLED", "MINT_REFUNDED"] : ["REDEEM_REQUESTED", "FORCE_EXITED", "REDEEM_CLAIMED"];
      const events = (history.mine ?? [])
        .filter((e) => e.vaultId === asset && e.receiptId === f.receiptId && kinds.includes(e.kind))
        .sort((a, b) => a.blockNumber - b.blockNumber || a.logIndex - b.logIndex);
      const base = { kind: mint ? ("mint" as const) : ("redeem" as const), id, timeMs: f.timeMs, amount, events };
      if (!r || r.status !== "success") return { ...base, status: "reading chain…", tone: "wait", action: null };
      const r5 = reads5.data?.[i];
      const extra5 = IS_STACK5 && r5?.status === "success" ? (r5.result as bigint) : null;
      if (mint) {
        const [, escrow, settled, , requestedAt, refundStaged] = r.result as readonly [string, bigint, boolean, bigint, bigint, boolean, bigint];
        const refunded = (history.mine ?? []).some((e) => e.kind === "MINT_REFUNDED" && e.vaultId === asset && e.receiptId === f.receiptId);
        if (settled) return { ...base, status: refunded ? "refunded to your wallet" : "certificates issued", tone: "done", action: null };
        const age = now / 1000 - Number(requestedAt);
        if (age < REFUND_OFFER_AFTER_SEC)
          return { ...base, status: "hedge opening · escrowed", tone: "wait", action: null };
        if (IS_STACK5 && extra5 !== null) {
          // STACK 5 (L-10): refundMint pays escrow + mintFee(id), i.e. everything deposited.
          const back = fmtNum(fromCollateral(escrow + extra5), 2);
          return {
            ...base,
            status: refundStaged
              ? `refund staged · pays ${back} USDG back, fee included`
              : `not filled · the keeper refunds ${back} USDG, fee included`,
            tone: "open",
            action: { kind: "refund", id, staged: refundStaged },
          };
        }
        return {
          ...base,
          status: refundStaged ? "refund staged · the keeper pays it back" : "not filled · the keeper refunds it",
          tone: "open",
          action: { kind: "refund", id, staged: refundStaged },
        };
      }
      const [, owed18, enqueuedAt, , paid] = r.result as readonly [string, bigint, bigint, bigint, boolean];
      if (paid) return { ...base, status: "claimed", tone: "done", action: null };
      if (IS_STACK5) {
        // STACK 5 (H-7): a claim pays what the vault holds and keeps the rest on the receipt.
        // `owed18` is what the receipt was written for; the price cap can lower what is due, so the
        // remainder is an upper bound and is labelled as one.
        const paidSoFar = extra5 ?? 0n;
        if (paidSoFar > 0n) {
          const owed6 = owed18 / 10n ** 12n;
          const rest = owed6 > paidSoFar ? owed6 - paidSoFar : 0n;
          return {
            ...base,
            status: `part-paid · ${fmtNum(fromCollateral(paidSoFar), 2)} USDG paid, up to ${fmtNum(fromCollateral(rest), 2)} USDG outstanding`,
            tone: "open",
            action: { kind: "claim", id, staged: false, label: "Claim rest" },
          };
        }
        // STACK 5 (H-1): no price observed since the request yet. The claim waits, and pays in
        // full once QUEUED_PRICE_TIMEOUT has passed from the request, whatever the feed does.
        const req = Number(enqueuedAt);
        if (
          times5.priceObservedAt !== null &&
          times5.queuedPriceTimeout !== null &&
          times5.priceObservedAt < req &&
          now / 1000 < req + times5.queuedPriceTimeout
        ) {
          return {
            ...base,
            status: `waiting for a fresh price · pays in full from ${utcMinute(req + times5.queuedPriceTimeout)} at the latest`,
            tone: "wait",
            action: { kind: "claim", id, staged: false },
          };
        }
      }
      return { ...base, status: "ready to claim once the collateral is back", tone: "open", action: { kind: "claim", id, staged: false } };
    });
  }, [requests, reads.data, reads5.data, times5.priceObservedAt, times5.queuedPriceTimeout, now, history.mine, asset]);

  const [open, setOpen] = useState<string | null>(null);

  if (!address) return null;

  return (
    <div className="mt-5 border-t hairline-dark pt-4">
      <div className="flex flex-wrap items-center gap-2">
        <MicroLabel>My receipts · this vault</MicroLabel>
        <ExplorerSourcedTag source={history.source} />
        {history.isFetching && <Loader2 size={11} className="animate-spin text-white-60" />}
      </div>
      {history.indexUnavailable ? (
        <p className="mt-2 font-mono text-[10px] uppercase tracking-[0.06em] text-warn">
          Neither the UseCert indexer nor the explorer index could be read, so your receipts cannot
          be listed right now. This is not "no receipts": enter an id above, or try again shortly.
        </p>
      ) : history.isLoading ? (
        <p className="mt-2 font-mono text-[10px] uppercase tracking-[0.06em] text-white-60">reading the index…</p>
      ) : rows.length === 0 ? (
        <p className="mt-2 font-mono text-[10px] uppercase tracking-[0.06em] text-white-60">
          No mint or redemption receipts for this wallet on this vault in the indexed history.
        </p>
      ) : (
        <ul className="mt-2 divide-y divide-white/5">
          {rows.map((row) => (
            <li key={`${row.kind}-${row.id}`} className="flex flex-wrap items-center gap-x-3 gap-y-1 py-2 font-mono text-[11px]">
              <span className="w-16 uppercase tracking-[0.06em] text-white-60">{row.kind === "mint" ? "Mint" : "Redeem"}</span>
              <span className="tabular-nums text-white">#{String(row.id)}</span>
              <span className="tabular-nums text-white-60">{row.amount}</span>
              <span className="text-white-60/70">{row.timeMs ? fmtAge((now - row.timeMs) / 1000) : ""}</span>
              <span
                className={
                  row.tone === "open" ? "text-green-bright" : row.tone === "done" ? "text-white-60/70" : "text-silver"
                }
              >
                {row.status}
              </span>
              <button
                type="button"
                onClick={() => setOpen(open === `${row.kind}-${row.id}` ? null : `${row.kind}-${row.id}`)}
                className="font-mono text-[10px] uppercase tracking-[0.06em] text-white-60 underline decoration-white/20 underline-offset-2 hover:text-green-bright"
              >
                {open === `${row.kind}-${row.id}` ? "hide evidence" : "evidence"}
              </button>
              {row.action && (
                <button
                  type="button"
                  disabled={disabled || busy !== null}
                  onClick={() => onAction(row.action as ReceiptAction)}
                  className="ml-auto flex items-center gap-2 border hairline-dark px-3 py-1.5 font-mono text-[10px] uppercase tracking-[0.08em] text-white transition-colors hover:bg-section-deep-2 disabled:pointer-events-none disabled:opacity-40"
                >
                  {busy === row.id && <Loader2 size={11} className="animate-spin" />}
                  {row.action.label ?? (row.action.kind === "claim" ? "Claim" : "Refund now")}
                </button>
              )}
              {open === `${row.kind}-${row.id}` && (
                <ol className="mt-1 w-full border-l hairline-dark pl-3">
                  {row.events.map((e) => (
                    <li key={e.id} className="py-1 text-[10px] uppercase tracking-[0.05em] text-white-60">
                      <span className="text-white">{STEP_LABEL[e.kind] ?? e.kind}</span>
                      {` · block ${e.blockNumber.toLocaleString("en-US")} · log ${e.logIndex}`}
                      {e.timeMs ? ` · ${new Date(e.timeMs).toISOString().slice(0, 16).replace("T", " ")} UTC` : ""}
                      {" · "}
                      <a href={e.txUrl} target="_blank" rel="noreferrer noopener" className="underline decoration-white/20 underline-offset-2 hover:text-green-bright">
                        {e.txHash.slice(0, 10)}…
                      </a>
                    </li>
                  ))}
                  {row.status.startsWith("refund staged") && (
                    <li className="py-1 text-[10px] uppercase tracking-[0.05em] text-white-60">Refund staged (read from the contract)</li>
                  )}
                  <li className="py-1 text-[10px] normal-case leading-[1.5] text-white-60/70">
                    On-chain evidence only. The keeper's hedge on the venue is off chain and is not proven here, and a confirmed
                    request is not a completed mint or redemption until its settlement or claim appears above.
                  </li>
                </ol>
              )}
            </li>
          ))}
        </ul>
      )}
      {history.hiddenFromMine > 0 && (
        <p className="mt-1 font-mono text-[10px] uppercase tracking-[0.06em] text-white-60/60">
          {`${history.hiddenFromMine} settlements in the index could not be tied to a wallet and are not listed.`}
        </p>
      )}
    </div>
  );
}
