import {
  ArrowDown,
  ArrowUp,
  CheckCheck,
  CircleQuestionMark,
  Coins,
  ExternalLink,
  Hourglass,
  LogOut,
  RotateCcw,
} from "lucide-react";
import { cn } from "@/lib/utils";
import { flowKindLabel, useFlows, type FlowAttribution, type FlowKind } from "@/chain/useFlows";
import { EM_DASH, fmtNum, fmtUSD, timeAgo, truncHash } from "./format";
import { ROUTED_VAULT_COUNT, useDashboard } from "./store";
import { EmptyState, ExplorerSourceNote, IndexStaleNotice, IndexUnavailable } from "./ui";

/*
 * Badges for the eight `CertVault` flow events.
 *
 * This replaces a three-value `MINT | REDEEM | CLAIM` badge that predated a real history.
 * Three labels cannot describe these contracts: the two-step paths have a REQUEST, a
 * SETTLE and, when the keeper does not fill, a REFUND, and `ForceExited` is a fourth
 * outcome again — the user leaving past the settle window. Collapsing "mint requested"
 * and "mint settled" into one "MINT" row would tell a user their mint completed when the
 * only thing on chain is a request. Every kind therefore gets its own label.
 *
 * Stakes, unstakes and staking withdrawals are still absent: no staking contract exists
 * on this deployment.
 */
const KIND_ICON: Record<FlowKind, typeof ArrowUp> = {
  MINT: ArrowUp,
  MINT_REQUESTED: Hourglass,
  MINT_SETTLED: CheckCheck,
  MINT_REFUNDED: RotateCcw,
  REDEEM: ArrowDown,
  REDEEM_REQUESTED: Hourglass,
  REDEEM_CLAIMED: Coins,
  FORCE_EXITED: LogOut,
};

/**
 * Colour register per kind.
 *
 * `green` is reserved for a flow that COMPLETED in the user's favour — collateral in and
 * certificates out, or a claim paid. A pending request is `silver` however healthy it
 * looks, because nothing has settled yet. `warn` is for the two exits from the unhappy
 * path (`MINT_REFUNDED`, `FORCE_EXITED`): neither is an error, both are states a user
 * should notice rather than read as a normal redemption.
 */
const KIND_TONE: Record<FlowKind, "green" | "silver" | "warn"> = {
  MINT: "green",
  MINT_REQUESTED: "silver",
  MINT_SETTLED: "green",
  MINT_REFUNDED: "warn",
  REDEEM: "silver",
  REDEEM_REQUESTED: "silver",
  REDEEM_CLAIMED: "green",
  FORCE_EXITED: "warn",
};

const TONE_BORDER: Record<"green" | "silver" | "warn", string> = {
  green: "border-green-bright/40 text-green-bright",
  silver: "border-silver/30 text-silver",
  warn: "border-warn/40 text-warn",
};

const TONE_TEXT: Record<"green" | "silver" | "warn", string> = {
  green: "text-green-bright",
  silver: "text-silver",
  warn: "text-warn",
};

export function FlowKindBadge({ kind, className }: { kind: FlowKind; className?: string }) {
  const Icon = KIND_ICON[kind];
  const tone = KIND_TONE[kind];
  return (
    <span
      className={cn(
        "inline-flex items-center gap-2 whitespace-nowrap font-mono text-[11px] uppercase tracking-[0.06em]",
        className,
      )}
    >
      <span
        className={cn("flex h-6 w-6 shrink-0 items-center justify-center border", TONE_BORDER[tone])}
      >
        <Icon size={12} />
      </span>
      <span className={TONE_TEXT[tone]}>{flowKindLabel(kind)}</span>
    </span>
  );
}

/**
 * How a row's wallet was determined — shown only when it was NOT the event's own topic.
 *
 * `MintSettled` and `RedeemClaimed` carry no user topic, only a `receiptId`. A wallet on
 * those rows is a JOIN this app performed against the matching request event, and an
 * unmatched receipt is nobody's. Both facts are on screen rather than folded away,
 * because "we worked out whose this is" and "the event says whose this is" are different
 * claims and only one of them can be wrong.
 */
export function AttributionTag({
  attribution,
  receiptId,
  className,
}: {
  attribution: FlowAttribution;
  receiptId: string | null;
  className?: string;
}) {
  if (attribution === "direct") return null;

  if (attribution === "joined") {
    return (
      <span
        className={cn(
          "inline-flex items-center gap-1 font-mono text-[9px] uppercase tracking-[0.08em] text-white-60",
          className,
        )}
        title={`This event carries no user topic — only receipt id ${receiptId ?? "?"}. The wallet was matched to the request event that opened the same receipt on this vault.`}
      >
        joined · receipt {receiptId ?? "?"}
      </span>
    );
  }

  return (
    <span
      className={cn(
        "inline-flex items-center gap-1 font-mono text-[9px] uppercase tracking-[0.08em] text-warn",
        className,
      )}
      title={`Receipt ${receiptId ?? "?"} settled, but the request event that names its owner is not in the fetched window. No wallet is guessed, so this row is excluded from per-wallet views.`}
    >
      <CircleQuestionMark size={10} />
      unattributed
    </span>
  );
}

/* ─────────────────────────────────────────────────────── the overview strip */

/**
 * The dashboard's "Recent Flows" body.
 *
 * Lives here rather than in `Overview.tsx` so the overview strip and the full
 * `ActivityView` cannot drift on the three states that matter — index unavailable, no
 * wallet, genuinely empty — or on which provenance class the rows belong to. Both call
 * `useFlows`, which is one react-query cache entry, so this is one HTTP request shared
 * between the two views, not two.
 */
export function RecentFlows({ limit = 5, onViewAll }: { limit?: number; onViewAll?: () => void }) {
  const { address, connected, now } = useDashboard();
  const history = useFlows({ address });

  /* The overview shows the WALLET's flows when there is a wallet, and the protocol's when
   * there is not. The alternative — an empty personal list for a visitor who has not
   * connected — is the reading this whole feature exists to avoid. The caption says which
   * of the two is on screen, so the switch is never silent. */
  const personal = connected && history.mine !== null;
  const rows = (personal ? (history.mine ?? []) : history.flows).slice(0, limit);

  if (history.indexUnavailable) {
    return (
      <IndexUnavailable
        className="border-0"
        message={history.indexError ?? "The explorer index could not be read."}
        rateLimited={history.rateLimited}
        onRetry={history.refetch}
      />
    );
  }

  if (history.isLoading) {
    return (
      <p className="py-10 text-center font-mono text-[10px] uppercase tracking-[0.08em] text-white-60">
        Reading the explorer index…
      </p>
    );
  }

  return (
    <div>
      {history.indexStale && (
        <IndexStaleNotice
          className="mx-5 mt-3"
          message={history.indexError ?? "The explorer index could not be re-read."}
          onRetry={history.refetch}
        />
      )}

      <div className="border-b hairline-dark px-5 py-3">
        <ExplorerSourceNote
          /* Leads with provenance, then says whose flows are on screen. The provenance
             half is not optional copy: these rows are a third-party HTTP index, and the
             note is the only thing on the overview that says so. */
          /* The vault count comes from the address book, never from a literal: "two"
             was still on screen after the deployment grew to four. */
          detail={`${history.sourceDetail} ${
            personal
              ? `Showing your flows on the ${ROUTED_VAULT_COUNT} routed vaults, newest first.`
              : `Showing flows across the ${ROUTED_VAULT_COUNT} routed vaults, newest first — connect a wallet to filter this to your own.`
          }`}
          url={history.sourceUrl}
          fetchedAt={history.fetchedAt}
          now={now}
        />
      </div>

      {rows.length === 0 ? (
        <EmptyState
          className="border-0"
          title={
            personal
              ? "No flows for this wallet yet"
              : "No flows on the routed vaults yet"
          }
          detail="The index answered and returned nothing. This is a real empty result, not a failed read: mint or redeem on this deployment and the flow appears here."
        />
      ) : (
        <ul className="divide-y hairline-dark">
          {rows.map((f) => (
            <li key={f.id} className="flex flex-wrap items-center gap-x-4 gap-y-1 px-5 py-3">
              <FlowKindBadge kind={f.kind} className="min-w-[150px]" />
              <span className="font-mono text-[12px] text-white">{f.vaultSymbol}</span>
              {/* 18-decimal certificate leg and 6-decimal collateral leg, side by side and
                  each through its own converter — never one shared formatter. */}
              <span className="font-mono text-[12px] tabular-nums text-silver">
                {f.cert === null ? EM_DASH : `${fmtNum(f.cert, 4)} ${f.vaultSymbol}`}
              </span>
              <span className="font-mono text-[12px] tabular-nums text-white-60">
                {f.collateral === null ? EM_DASH : fmtUSD(f.collateral, 2)}
              </span>
              <AttributionTag attribution={f.attribution} receiptId={f.receiptId} />
              <span className="ml-auto flex items-center gap-4">
                <span className="font-mono text-[11px] text-white-60">
                  {f.timeMs === null ? `block ${f.blockNumber.toLocaleString("en-US")}` : timeAgo(f.timeMs, now)}
                </span>
                <a
                  href={f.txUrl}
                  target="_blank"
                  rel="noreferrer noopener"
                  title={`${f.txHash} — open on the block explorer`}
                  className="inline-flex items-center gap-1.5 font-mono text-[11px] text-white-60 transition-colors hover:text-green-bright"
                >
                  {truncHash(f.txHash)}
                  <ExternalLink size={10} />
                </a>
              </span>
            </li>
          ))}
        </ul>
      )}

      {onViewAll && rows.length > 0 && (
        <button
          type="button"
          onClick={onViewAll}
          className="w-full border-t hairline-dark px-5 py-3 text-left font-mono text-[10px] uppercase tracking-[0.08em] text-white-60 transition-colors hover:text-green-bright"
        >
          {personal ? "See every flow, including all vaults" : "Open the full flow history"}
        </button>
      )}
    </div>
  );
}
