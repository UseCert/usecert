import { useMemo } from "react";
import { useReadContracts } from "wagmi";
import { Loader2 } from "lucide-react";
import { CertVaultABI } from "@/chain/contracts";
import { CHAIN_ID } from "@/chain/deployment";
import { useFlows } from "@/chain/useFlows";
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
export type ReceiptAction = { kind: "claim" | "refund"; id: bigint; staged: boolean };

type Row = {
  kind: "mint" | "redeem";
  id: bigint;
  timeMs: number | null;
  amount: string;
  status: string;
  tone: "open" | "done" | "wait";
  action: ReceiptAction | null;
};

/** A hedge normally fills in under a minute; before this, a refund would only revert. */
const REFUND_OFFER_AFTER_SEC = 15 * 60;

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

  const rows = useMemo<Row[]>(() => {
    return requests.map((f, i) => {
      const id = BigInt(f.receiptId as string);
      const r = reads.data?.[i];
      const mint = f.kind === "MINT_REQUESTED";
      const amount = mint
        ? f.collateral !== null ? `${fmtNum(f.collateral, 2)} USDG in` : "—"
        : f.cert !== null ? `${fmtNum(f.cert, 4)} burned` : "—";
      const base = { kind: mint ? ("mint" as const) : ("redeem" as const), id, timeMs: f.timeMs, amount };
      if (!r || r.status !== "success") return { ...base, status: "reading chain…", tone: "wait", action: null };
      if (mint) {
        const [, , settled, , requestedAt, refundStaged] = r.result as readonly [string, bigint, boolean, bigint, bigint, boolean, bigint];
        const refunded = (history.mine ?? []).some((e) => e.kind === "MINT_REFUNDED" && e.vaultId === asset && e.receiptId === f.receiptId);
        if (settled) return { ...base, status: refunded ? "refunded to your wallet" : "certificates issued", tone: "done", action: null };
        const age = now / 1000 - Number(requestedAt);
        if (age < REFUND_OFFER_AFTER_SEC)
          return { ...base, status: "hedge opening · escrowed", tone: "wait", action: null };
        return {
          ...base,
          status: refundStaged ? "refund staged · the keeper pays it back" : "not filled · the keeper refunds it",
          tone: "open",
          action: { kind: "refund", id, staged: refundStaged },
        };
      }
      const [, , , , paid] = r.result as readonly [string, bigint, bigint, bigint, boolean];
      if (paid) return { ...base, status: "claimed", tone: "done", action: null };
      return { ...base, status: "ready to claim once the collateral is back", tone: "open", action: { kind: "claim", id, staged: false } };
    });
  }, [requests, reads.data, now, history.mine, asset]);

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
              {row.action && (
                <button
                  type="button"
                  disabled={disabled || busy !== null}
                  onClick={() => onAction(row.action as ReceiptAction)}
                  className="ml-auto flex items-center gap-2 border hairline-dark px-3 py-1.5 font-mono text-[10px] uppercase tracking-[0.08em] text-white transition-colors hover:bg-section-deep-2 disabled:pointer-events-none disabled:opacity-40"
                >
                  {busy === row.id && <Loader2 size={11} className="animate-spin" />}
                  {row.action.kind === "claim" ? "Claim" : "Refund now"}
                </button>
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
