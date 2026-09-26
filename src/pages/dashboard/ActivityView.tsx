/**
 * The flow history view.
 *
 * ─────────────────────────────────────────────────────────────────────────────────────
 * WHAT THIS PAGE USED TO SAY, AND WHY IT WAS HALF WRONG
 * ─────────────────────────────────────────────────────────────────────────────────────
 * "No flow history yet: needs an indexer — receipt ids are not enumerable on-chain and
 * there is no `receiptsOf(user)`, so a flow list can only be built from indexed events.
 * None are indexed yet."
 *
 * The premise was right: there is no `receiptsOf(address)` on `CertVault`, so a wallet's
 * receipts cannot be walked from a view function and a list can only come from logs. The
 * conclusion was wrong. Robinhood Chain testnet's Blockscout instance indexes AND decodes
 * these events, and its API answers the browser directly. The history was there the whole
 * time; the app just was not asking. See `src/chain/useFlows.ts`.
 *
 * ─────────────────────────────────────────────────────────────────────────────────────
 * THE THREE STATES THIS VIEW MUST KEEP APART
 * ─────────────────────────────────────────────────────────────────────────────────────
 * They look identical if you are careless, and they mean completely different things:
 *
 *   1. INDEX UNAVAILABLE   the explorer failed, timed out or rate-limited. Renders
 *                          `IndexUnavailable`, in `warn`, naming the failure. NEVER an
 *                          empty table — that would tell somebody they have no activity
 *                          because a third party is down.
 *   2. NO WALLET           "My activity" with nothing connected. There is no wallet to
 *                          filter by, so there is no answer to give, empty or otherwise.
 *   3. GENUINELY EMPTY     the index answered and this wallet/filter really has no flows.
 *                          The only one of the three that may render as "nothing here".
 *
 * Provenance sits above the table in every case: everything below it is class 3
 * (third-party index), not a chain read. `ExplorerSourceNote` says so.
 */
import { useMemo, useState } from "react";
import { AnimatePresence, motion } from "framer-motion";
import { ExternalLink, RefreshCw } from "lucide-react";

import { useFlows, type FlowEvent, type FlowKind } from "@/chain/useFlows";
import { cn } from "@/lib/utils";
import { ROUTED_VAULT_COUNT, useDashboard } from "./store";
import type { VaultId } from "./store";
import {
  Dropdown,
  EmptyState,
  ExplorerSourceNote,
  IndexStaleNotice,
  IndexUnavailable,
  Panel,
  SegmentedTabs,
  UnderlineTabs,
  ViewHeader,
} from "./ui";
import { EM_DASH, fmtNum, fmtOrDash, fmtUSD, timeAgo, truncHash } from "./format";
import { AttributionTag, FlowKindBadge } from "./flows";

/* No "Stakes" tab: there is no staking contract on this deployment, so a filter for it
 * could only ever match nothing while implying the mechanism exists. */
type KindFilter = "ALL" | "MINT" | "REDEEM" | "CLAIM";

const KIND_TABS: { value: KindFilter; label: string }[] = [
  { value: "ALL", label: "All" },
  { value: "MINT", label: "Mints" },
  { value: "REDEEM", label: "Redeems" },
  { value: "CLAIM", label: "Claims & exits" },
];

/**
 * Which event kinds each tab admits.
 *
 * `MINT_REFUNDED` sits under Mints because it is the mint path's other ending, and
 * `FORCE_EXITED` under "Claims & exits" because it is how a user gets out when the keeper
 * did not settle — grouping it with ordinary redemptions would hide the distinction.
 */
const KIND_MATCH: Record<KindFilter, FlowKind[]> = {
  ALL: [
    "MINT",
    "MINT_REQUESTED",
    "MINT_SETTLED",
    "MINT_REFUNDED",
    "REDEEM",
    "REDEEM_REQUESTED",
    "REDEEM_CLAIMED",
    "FORCE_EXITED",
  ],
  MINT: ["MINT", "MINT_REQUESTED", "MINT_SETTLED", "MINT_REFUNDED"],
  REDEEM: ["REDEEM", "REDEEM_REQUESTED"],
  CLAIM: ["REDEEM_CLAIMED", "FORCE_EXITED"],
};

type Scope = "MINE" | "ALL";

/** A transaction hash as a link to the explorer, which is where the row came from anyway. */
function TxLink({ hash, url }: { hash: string; url: string }) {
  return (
    <a
      href={url}
      target="_blank"
      rel="noreferrer noopener"
      title={`${hash} — open on the block explorer`}
      className="inline-flex items-center gap-1.5 font-mono text-[12px] text-white-60 transition-colors hover:text-green-bright"
    >
      {truncHash(hash)}
      <ExternalLink size={11} />
    </a>
  );
}

function FlowRow({ flow, collateralSymbol }: { flow: FlowEvent; collateralSymbol: string }) {
  return (
    <motion.tr
      layout="position"
      initial={{ opacity: 0, y: -12 }}
      animate={{ opacity: 1, y: 0 }}
      transition={{ duration: 0.35 }}
      className="border-b hairline-dark transition-colors last:border-b-0 hover:bg-section-deep"
    >
      <td className="px-5 py-3">
        <div className="flex flex-col gap-1">
          <FlowKindBadge kind={flow.kind} />
          <AttributionTag attribution={flow.attribution} receiptId={flow.receiptId} />
        </div>
      </td>
      <td className="px-3 py-3 text-white">{flow.vaultSymbol}</td>
      {/* CERTIFICATE domain, 18 dp — `certIn` / `certOut`. */}
      <td className="px-3 py-3 text-right tabular-nums text-silver">
        {fmtOrDash(flow.cert, (n) => fmtNum(n, 4))}
      </td>
      {/* COLLATERAL domain, 6 dp — `amountIn` / `amountOut`. */}
      <td className="px-3 py-3 text-right tabular-nums text-white">
        {fmtOrDash(flow.collateral, (n) => fmtUSD(n, 2))}
      </td>
      {/* PRICE domain, 18 dp — `px18` / `fillPx18`. Four decimals: the live mirrors quote
          $366.6204, and two would round the fill price away. */}
      <td className="hidden px-3 py-3 text-right tabular-nums text-silver lg:table-cell">
        {fmtOrDash(flow.price, (n) => fmtUSD(n, 4))}
      </td>
      {/* Fee is COLLATERAL, 6 dp. Only `Minted` carries one; an em-dash elsewhere is the
          truth, and a "0 bps" there would not be. */}
      <td className="hidden px-3 py-3 text-right tabular-nums text-white-60 md:table-cell">
        {fmtOrDash(flow.fee, (n) => fmtUSD(n, 2))}
      </td>
      <td className="hidden px-3 py-3 text-right tabular-nums text-white-60 xl:table-cell">
        {flow.blockNumber.toLocaleString("en-US")}
      </td>
      <td className="px-3 py-3 text-right text-white-60">
        {flow.timeMs === null ? EM_DASH : timeAgo(flow.timeMs)}
      </td>
      <td className="px-5 py-3">
        <span className="flex justify-end">
          <TxLink hash={flow.txHash} url={flow.txUrl} />
        </span>
      </td>
    </motion.tr>
  );
}

export default function ActivityView() {
  const { vaults, collateralSymbol, connected, address, now, setWalletModalOpen } = useDashboard();
  const history = useFlows({ address });

  /* Defaults to the protocol-wide view: this page is headed "Protocol Flows", and a
   * visitor who has not connected should land on real history rather than on a prompt.
   * "My activity" is one click away and carries its own no-wallet state. */
  const [scope, setScope] = useState<Scope>("ALL");
  const [kindFilter, setKindFilter] = useState<KindFilter>("ALL");
  const [assetFilter, setAssetFilter] = useState<string>("all");

  // "My activity" with no wallet is state 2, not an empty list — see the header. The
  // address is checked as well as `connected`: a connection mid-handshake has no address
  // to filter by either, and an empty table is the wrong answer in both cases.
  const noWallet = scope === "MINE" && (!connected || !address);
  const base = scope === "MINE" ? (history.mine ?? []) : history.flows;

  const filtered = useMemo(
    () =>
      base.filter((f) => {
        if (!KIND_MATCH[kindFilter].includes(f.kind)) return false;
        if (assetFilter === "all") return true;
        return f.vaultId === (assetFilter as VaultId);
      }),
    [base, kindFilter, assetFilter],
  );

  /* How many rows the per-wallet view is holding back, and why. Stated rather than
   * silently shortening the list: an unattributed settlement is a real event whose owner
   * this app cannot prove, so it is excluded from "mine" but the exclusion is published. */
  const withheld = scope === "MINE" ? history.hiddenFromMine : 0;

  return (
    <div>
      <ViewHeader
        label="Protocol Flows"
        title={
          <>
            Every Flow, <span className="text-metallic">On Chain.</span>
          </>
        }
        right={
          <button
            type="button"
            onClick={history.refetch}
            disabled={history.isFetching}
            className="flex items-center gap-2 self-end border hairline-dark px-4 py-2.5 font-mono text-[11px] uppercase tracking-[0.08em] text-white-60 transition-colors hover:text-white disabled:opacity-40"
          >
            <RefreshCw size={12} className={cn(history.isFetching && "animate-spin")} />
            {history.isFetching ? "Reading index" : "Refresh"}
          </button>
        }
      />

      <div className="mt-8 flex flex-wrap items-center justify-between gap-4">
        <SegmentedTabs
          options={[
            { value: "MINE" as Scope, label: "My activity" },
            { value: "ALL" as Scope, label: "All vaults" },
          ]}
          value={scope}
          onChange={setScope}
        />
        <Dropdown
          className="w-[190px]"
          options={[
            { value: "all", label: "All assets" },
            ...vaults.map((v) => ({
              value: v.id,
              label: v.name,
              disabled: v.status !== "LIVE",
              hint: v.status !== "LIVE" ? "not deployed" : undefined,
            })),
          ]}
          value={assetFilter}
          onChange={setAssetFilter}
        />
      </div>

      <div className="mt-5 flex flex-wrap items-end justify-between gap-4 border-b hairline-dark pb-4">
        <UnderlineTabs options={KIND_TABS} value={kindFilter} onChange={setKindFilter} />
      </div>

      {/* Provenance, above the data it describes and on screen in every state. */}
      <ExplorerSourceNote
        className="mt-4"
        detail={history.sourceDetail}
        source={history.source}
        url={history.sourceUrl}
        fetchedAt={history.fetchedAt}
        now={now}
      />

      {history.indexStale && (
        <IndexStaleNotice
          className="mt-4"
          message={history.indexError ?? "The explorer index could not be re-read."}
          onRetry={history.refetch}
        />
      )}

      <Panel className="mt-4 overflow-x-auto">
        {history.indexUnavailable ? (
          <IndexUnavailable
            className="border-0"
            message={history.indexError ?? "The explorer index could not be read."}
            rateLimited={history.rateLimited}
            onRetry={history.refetch}
          />
        ) : noWallet ? (
          <EmptyState
            className="border-0"
            height={220}
            title="No wallet connected — nothing to filter by"
            detail={
              <>
                A per-wallet history needs a wallet. Connect one to see your own mints,
                redemptions, claims and exits, or switch to “All vaults” for every flow on
                the {ROUTED_VAULT_COUNT} routed vaults. This is not an empty history — no
                address has been asked for yet.
              </>
            }
          />
        ) : history.isLoading ? (
          <p className="py-20 text-center font-mono text-[11px] uppercase tracking-[0.08em] text-white-60">
            Reading the explorer index…
          </p>
        ) : filtered.length === 0 ? (
          <EmptyState
            className="border-0"
            height={200}
            title={
              scope === "MINE"
                ? "No flows for this wallet on the routed vaults"
                : "No flows match this filter"
            }
            detail={
              withheld > 0 ? (
                <>
                  The index answered — this wallet simply has no matching mints or
                  redemptions. {withheld} settlement
                  {withheld === 1 ? "" : "s"} could not be tied to any wallet and are
                  excluded from this view; they are listed under “All vaults”.
                </>
              ) : (
                "The index answered and returned no events matching this filter. This is a real empty result, not a failed read."
              )
            }
          />
        ) : (
          <table className="w-full min-w-[980px] font-mono text-[12px]">
            <thead>
              <tr className="border-b hairline-dark text-left text-[10px] uppercase tracking-[0.08em] text-white-60">
                <th className="px-5 py-3 font-medium">Event</th>
                <th className="px-3 py-3 font-medium">Vault</th>
                <th className="px-3 py-3 text-right font-medium">Certificate</th>
                <th className="px-3 py-3 text-right font-medium">{collateralSymbol}</th>
                <th className="hidden px-3 py-3 text-right font-medium lg:table-cell">Price</th>
                <th className="hidden px-3 py-3 text-right font-medium md:table-cell">Fee</th>
                <th className="hidden px-3 py-3 text-right font-medium xl:table-cell">Block</th>
                <th className="px-3 py-3 text-right font-medium">Time</th>
                <th className="px-5 py-3 text-right font-medium">Tx</th>
              </tr>
            </thead>
            <tbody>
              <AnimatePresence initial={false}>
                {filtered.map((f) => (
                  <FlowRow key={f.id} flow={f} collateralSymbol={collateralSymbol} />
                ))}
              </AnimatePresence>
            </tbody>
          </table>
        )}
      </Panel>

      {/* Footnotes, all of them about what is NOT in the table above. */}
      {!history.indexUnavailable && !noWallet && (
        <div className="mt-4 flex flex-col gap-1.5 font-mono text-[10px] leading-[1.7] tracking-[0.04em] text-white-60/70">
          <p>
            Certificate amounts are 18-decimal ({collateralSymbol} legs and fees are
            6-decimal); prices are the 18-decimal px18 / fillPx18 the event carried.
            Events that carry no price or no fee show an em-dash rather than a zero.
          </p>
          {withheld > 0 && (
            <p>
              {withheld} settlement{withheld === 1 ? "" : "s"} (MintSettled / RedeemClaimed)
              carry only a receipt id, and the request event naming the owner is not in the
              fetched window — so no wallet is guessed and they are excluded from “My
              activity”. They appear under “All vaults”, marked unattributed.
            </p>
          )}
          {scope === "ALL" && history.unattributed > 0 && (
            <p>
              {history.unattributed} row{history.unattributed === 1 ? " is" : "s are"} marked
              unattributed: MintSettled and RedeemClaimed carry no user topic, only a receipt
              id, and the matching request is outside the fetched window.
            </p>
          )}
          {history.ignored > 0 && (
            <p>
              {history.ignored} further vault log{history.ignored === 1 ? "" : "s"} in the
              fetched window {history.ignored === 1 ? "is" : "are"} not a user flow
              (MarginPosted and other venue plumbing) and {history.ignored === 1 ? "is" : "are"}{" "}
              not listed.
            </p>
          )}
        </div>
      )}

      {!history.indexUnavailable && !noWallet && history.hasMore && (
        <div className="mt-6 flex justify-center">
          <button
            type="button"
            onClick={history.loadMore}
            disabled={history.isFetching || history.atPageCeiling}
            title={
              history.atPageCeiling
                ? "Page ceiling reached — use the block explorer for deeper history."
                : "Fetch further pages of logs from the explorer index."
            }
            className="border hairline-dark px-8 py-3.5 text-[12px] font-semibold uppercase tracking-[0.08em] text-white transition-all hover:bg-section-deep-2 active:scale-[0.98] disabled:opacity-40"
          >
            {history.atPageCeiling ? "Page ceiling reached" : "Load older flows"}
          </button>
        </div>
      )}

      {!history.indexUnavailable && !noWallet && !history.hasMore && filtered.length > 0 && (
        <p className="mt-6 text-center font-mono text-[10px] uppercase tracking-[0.08em] text-white-60/70">
          End of the index for all {ROUTED_VAULT_COUNT} routed vaults
        </p>
      )}

      {noWallet && (
        <div className="mt-6 flex justify-center">
          <button
            type="button"
            onClick={() => setWalletModalOpen(true)}
            className="border hairline-dark px-8 py-3.5 text-[12px] font-semibold uppercase tracking-[0.08em] text-white transition-all hover:bg-section-deep-2 active:scale-[0.98]"
          >
            Connect wallet
          </button>
        </div>
      )}
    </div>
  );
}
