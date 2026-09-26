import { ArrowUpRight, ChevronRight } from "lucide-react";
import { isRouted, STATUS_HINT, STATUS_LABEL, useDashboard } from "./store";
import type { Vault } from "./store";
import {
  AgeLine,
  EmptyState,
  Flash,
  HedgeRatio,
  MicroLabel,
  Panel,
  PulseDot,
  Stagger,
  UnverifiedTag,
  ViewHeader,
} from "./ui";
import { RecentFlows } from "./flows";
import { useCountUp } from "./hooks";
import { EM_DASH, NO_POSITION, fmtCompactUSD, fmtNum, fmtOrDash, fmtUSD } from "./format";
import { TickerStrip, BackingComposition, FundingMonitor, NetworkStrip, PegMonitor } from "./OverviewExtras";
import { capacityLegsLabel, type CapacityView } from "@/chain/useVaults";
import { CHAIN } from "@/chain/contracts";
import { IS_TESTNET } from "@/chain/deployment";
import { cn } from "@/lib/utils";

/**
 * Mint-ceiling utilisation for one row of the vault table.
 *
 * The bar this replaced was `bufferHeld / bufferCapacity18()`, which rendered
 * "$100K · 1% of capacity18" on both mirrors — a constant. `bufferCapacity18()` is a
 * notional-exposure ceiling of `freeCollateral18() × 100` capped by the ledger's claim
 * (`CertVault.sol:563-569`), so the quotient is pinned within rounding of 1/100 at every fill
 * level, RISES as the vault mints (`CertVault.sol:1925-1931`), and reached 100% at no fill
 * level at all. This one is `used / cap` from `_requireCapacity` (`CertVault.sol:1755-1771`)
 * and hits 100% exactly when `CertVault_AtCapacity` fires.
 */
function CapacityCell({
  view,
  refreshable,
}: {
  view: CapacityView;
  /** Can a mint refresh this vault's attestation? `null` when not yet known. */
  refreshable?: boolean | null;
}) {
  if (view.capIsZero) {
    // The same distinction `CapacityHalt` draws, which this cell was missing: a ceiling of
    // zero whose ONLY cause is an aged attestation is the idle state of a working vault,
    // because the mint relays a fresh attestation before the ceiling is read. Printing
    // "halted" over that told every reader the protocol was refusing mints while it was
    // not - and did it in amber, four rows at a time.
    const onlyStale =
      view.bindingLegs.length === 1 && view.bindingLegs[0] === "stale-attestation";
    if (onlyStale && refreshable === true) {
      return (
        <span
          className="text-white-60"
          title="Mint ceiling reads 0 because the on-chain attestation has aged out, which is what an idle protocol looks like. A mint relays a fresh attestation in the same transaction, so the ceiling is non-zero by the time it is checked."
        >
          idle · refreshes on mint
        </span>
      );
    }
    return (
      <span
        className="text-warn"
        title={
          view.bindingLegs.length > 0
            ? `Mint ceiling is 0 — every mint is refused. Cause: ${capacityLegsLabel(view.bindingLegs)}.`
            : "Mint ceiling is 0 — every mint is refused."
        }
      >
        halted · cap 0
      </span>
    );
  }
  if (view.utilisationPct === null || view.cap === null || view.used === null) {
    // `used` needs the oracle price to value the outstanding supply, so a reverted `px()`
    // is a different absence from a read still in flight and says so.
    return (
      <span className={view.cap !== null ? "text-warn" : "text-white-60"}>
        {view.cap !== null ? "used not measurable · px() reverts" : "reading…"}
      </span>
    );
  }
  return (
    <span
      className="flex items-center justify-end gap-2"
      title={
        `used ${fmtUSD(view.used, 2)} of cap ${fmtUSD(view.cap, 2)}. ` +
        `used = max((totalSupply + pendingMintCerts) × oracle price, attested notional18); ` +
        `cap = capacityOracle.maxNotional18(vault, bufferCapacity18()).` +
        (view.bindingLegs.length > 0 ? ` Binding: ${capacityLegsLabel(view.bindingLegs)}.` : "")
      }
    >
      <span className="relative hidden h-[6px] w-[52px] shrink-0 bg-white/10 align-middle lg:inline-block">
        <span
          className={cn(
            "absolute left-0 top-0 h-full transition-all duration-500",
            view.atCapacity ? "bg-warn" : "bg-green-bright",
          )}
          style={{ width: `${Math.max(0, Math.min(100, view.utilisationPct))}%` }}
        />
      </span>
      <span className={cn("tabular-nums", view.atCapacity ? "text-warn" : "text-white-60")}>
        {fmtNum(view.utilisationPct, 2)}% of {fmtCompactUSD(view.cap)}
      </span>
    </span>
  );
}

/**
 * One headline figure.
 *
 * `value` is nullable on purpose: until the first multicall lands there is no figure, and
 * a count-up animating to zero would read as "the protocol holds nothing". There is no
 * sparkline any more either — a 24-point series would have to be invented.
 */
function StatCard({
  index,
  caption,
  value,
  format,
  note,
  fallback,
  register = "primary",
}: {
  index: number;
  caption: string;
  value: number | null;
  format: (n: number) => string;
  note: React.ReactNode;
  /**
   * What to print instead of the em-dash when the figure is absent for a KNOWN reason —
   * a ratio whose denominator is zero, say, where a bare dash reads as a load failure.
   */
  fallback?: string;
  /** `claim` renders in a different visual register: it is not a measured balance. */
  register?: "primary" | "claim";
}) {
  const animated = useCountUp(value ?? 0, 1.2);
  return (
    <Stagger index={index}>
      <Panel
        className={cn(
          "group flex h-full flex-col gap-2 p-5 transition-colors hover:bg-section-deep",
          register === "claim" && "border-warn/25 bg-[#12120d]",
        )}
      >
        <div className="flex items-center justify-between gap-2">
          <MicroLabel className={register === "claim" ? "text-warn/80" : undefined}>{caption}</MicroLabel>
          {register === "claim" ? (
            <UnverifiedTag />
          ) : (
            <span className="font-mono text-[10px] uppercase tracking-[0.08em] text-white-60/50 transition-colors group-hover:text-green-bright">
              /{String(index + 1).padStart(2, "0")}
            </span>
          )}
        </div>
        <p
          className={cn(
            "font-mono leading-none tracking-[-0.04em]",
            value === null && fallback
              ? "text-[20px] md:text-[22px]"
              : "text-[34px] md:text-[40px]",
            register === "claim" ? "text-silver" : "text-white",
          )}
        >
          {value === null ? (
            <span className="text-white-60/60">{fallback ?? EM_DASH}</span>
          ) : (
            <Flash value={animated} format={format} />
          )}
        </p>
        <div className="mt-auto font-mono text-[11px]">{note}</div>
      </Panel>
    </Stagger>
  );
}

/** A cell that only ever shows a figure for a routed vault. */
function Cell({
  vault,
  value,
  format,
  className,
}: {
  vault: Vault;
  value: number | null;
  format: (n: number) => string;
  className?: string;
}) {
  return (
    <td className={cn("px-3 py-3.5 text-right tabular-nums", className)}>
      {isRouted(vault) ? fmtOrDash(value, format) : EM_DASH}
    </td>
  );
}

export default function Overview() {
  const {
    totals,
    liveVaults,
    vaults,
    goVault,
    setView,
    block,
    blockKnown,
    maxAttestationAgeSec,
    isLoading,
    isError,
    attestationRefreshable,
  allAttestationsRefreshable,
} = useDashboard();

  // The one solvency point we can prove right now, summed across routed vaults. Stage 1
  // computes obligation as supply × oracle price, falling back to the attested notional18
  // when px() reverted — different provenance, so the caveat below says so.
  const hasPoint = liveVaults.length > 0;
  const obligationNow = hasPoint
    ? liveVaults.reduce((s, v) => s + (v.solvency[0]?.obligation ?? 0), 0)
    : null;
  const backingNow = hasPoint
    ? liveVaults.reduce((s, v) => s + (v.solvency[0]?.backing ?? 0), 0)
    : null;

  return (
    <div className="relative">
      {/* Top mono stat row, same rhythm as the landing deep-green section.
          "C1 Live" is gone: C1 is the identifier of an audit, not a release badge, so the
          string could only ever be read as a certification the project does not have. When that
          was written the audit still had open criticals; it no longer does — the reported
          Critical is fixed, and five of the auditor's eight proof-of-concept exploits now pass
          where all eight were written to fail. The badge stays gone for the first reason: an
          audit identifier is not a release state. What is factually true is which chain
          this is reading and how solvency is proven, so that is what it says.
          "Solvency public / every block" is gone for the same reason: solvency is proven
          per attestation, on roughly a 60-second cadence, and the AgeLine below publishes
          the real age of the current proof. */}
      <div className="flex flex-wrap items-center justify-between gap-3 border-b hairline-dark pb-4 font-mono text-[11px] uppercase tracking-[0.08em] text-white-60">
        <span className="flex items-center gap-2">
          <PulseDot /> {IS_TESTNET ? `Testnet ${CHAIN.id}` : CHAIN.name}
        </span>
        <span className="hidden md:block">Robinhood Chain</span>
        <span>Solvency proven per attestation · age published</span>
      </div>

      {/* The one line about the venue. The site is openly a testnet, so this is stated
          plainly and once, without a banner. */}
      <p className="mt-3 font-mono text-[10px] uppercase leading-[1.7] tracking-[0.06em] text-white-60/70">
        {IS_TESTNET
          ? "On testnet the perp venue is simulated, so the attested margin and notional below describe a simulated position."
          : "The perp venue is Robinhood Chain Lighter. Margin and notional below are the vaults' own venue accounts, read from the venue and signed by the attester."}
      </p>

      <TickerStrip />

      {/* Header */}
      <ViewHeader
        className="mt-8"
        label="Protocol Overview"
        title={
          <>
            Solvency, <span className="text-metallic">Live.</span>
          </>
        }
        right={
          <div className="self-end text-right">
            <AgeLine
              ageSec={totals?.worstAgeSec ?? null}
              stale={Boolean(totals?.anyStale)}
              maxAgeSec={maxAttestationAgeSec}
              refreshable={allAttestationsRefreshable}
            />
            <p className="mt-1 font-mono text-[10px] uppercase tracking-[0.06em] text-white-60/60">
              Worst attestation age across routed vaults
            </p>
          </div>
        }
      />

      {isError && (
        <p className="mt-6 border border-warn/40 bg-[#12120d] px-4 py-3 font-mono text-[11px] uppercase tracking-[0.06em] text-warn">
          Chain reads failed. Nothing below is current — no figures are shown rather than stale ones.
        </p>
      )}

      {/* Stat cards. buffer and accrual are two cards on purpose: they are not the same
          kind of number and must never be summed into one "buffer" figure. */}
      <div className="mt-8 grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
        <StatCard
          index={0}
          caption="Position Notional (attested)"
          value={totals ? totals.notional : null}
          format={(n) => fmtCompactUSD(n)}
          note={
            <AgeLine
              ageSec={totals?.worstAgeSec ?? null}
              stale={Boolean(totals?.anyStale)}
              maxAgeSec={maxAttestationAgeSec}
              refreshable={allAttestationsRefreshable}
            />
          }
        />
        {/* The denominator is the ATTESTED notional, which is 0 on any mirror with no supply.
            `totals.ratio` is null in that state rather than clamped to a $1 denominator, so
            this card shows the reason instead of publishing the margin as a percentage of
            nothing — it read "46,054.10%" before the guard. */}
        <StatCard
          index={1}
          caption="Margin / Notional (attested)"
          value={totals ? totals.ratio : null}
          format={(n) => `${n.toFixed(2)}%`}
          fallback={totals && totals.ratio === null ? NO_POSITION : undefined}
          note={
            <span className="text-white-60">
              {totals && totals.ratio === null
                ? "attested notional is $0 — the ratio has no denominator"
                : "both halves are attester-relayed figures"}
            </span>
          }
        />
        <StatCard
          index={2}
          caption="Buffer Held (ERC-20)"
          value={totals ? totals.buffer : null}
          format={(n) => fmtCompactUSD(n)}
          note={<span className="text-green-bright">collateral the vaults actually hold</span>}
        />
        <StatCard
          index={3}
          caption="Accrual Claimed"
          value={totals ? totals.accrualClaimedUnverified : null}
          format={(n) => fmtCompactUSD(n)}
          register="claim"
          note={
            <span className="text-warn/80">
              attester-relayed P&amp;L · not money · not added to the buffer
            </span>
          }
        />
      </div>

      {/* Solvency: one provable point, and an honest gap where the series would be */}
      <Stagger index={4}>
        <Panel className="section-glow relative mt-3 p-5 md:p-6">
          <div className="mb-4 flex flex-wrap items-center justify-between gap-3">
            <MicroLabel>Solvency Now</MicroLabel>
            <span className="flex items-center gap-2 rounded-full border hairline-dark px-3 py-1 font-mono text-[10px] uppercase tracking-[0.08em] text-white-60">
              <PulseDot /> Block{" "}
              <span className="tabular-nums text-white">
                {blockKnown ? block.toLocaleString("en-US") : EM_DASH}
              </span>
            </span>
          </div>

          <div className="grid gap-3 sm:grid-cols-2">
            <div className="border hairline-dark bg-[#0d0f0d] p-4">
              <MicroLabel className="text-[10px]">Backing · margin + buffer held</MicroLabel>
              <p className="mt-2 font-mono text-[26px] leading-none tabular-nums text-green-bright">
                {fmtOrDash(backingNow, (n) => fmtCompactUSD(n))}
              </p>
            </div>
            <div className="border hairline-dark bg-[#0d0f0d] p-4">
              <MicroLabel className="text-[10px]">Obligation · supply × oracle price</MicroLabel>
              <p className="mt-2 font-mono text-[26px] leading-none tabular-nums text-silver">
                {fmtOrDash(obligationNow, (n) => fmtCompactUSD(n))}
              </p>
            </div>
          </div>

          <p className="mt-3 font-mono text-[10px] leading-[1.7] uppercase tracking-[0.06em] text-white-60/70">
            Backing excludes the unverified accrual claim.
            {totals?.anyPriceUnavailable
              ? " One or more oracles reverted, so that vault's obligation falls back to the attested notional — different provenance."
              : ""}
          </p>

          <EmptyState
            className="mt-4"
            height={220}
            title="No solvency history yet: needs an indexer"
            detail="No view function on these contracts returns a time series, so there is no 60-point curve to draw. The figures above are a single point, proven at the attestation age shown. A curve would have to be invented."
          />
        </Panel>
      </Stagger>

      <NetworkStrip />

      {/* Composition + funding, two-up */}
      <div className="mt-3 grid gap-3 lg:grid-cols-2">
        <Stagger index={5}>
          <BackingComposition />
        </Stagger>
        <Stagger index={6}>
          <FundingMonitor />
        </Stagger>
      </div>

      <Stagger index={7}>
        <PegMonitor />
      </Stagger>

      {/* Vault summary table */}
      <Stagger index={5}>
        <Panel className="mt-3 overflow-x-auto">
          <div className="flex items-center justify-between border-b hairline-dark px-5 py-4">
            <MicroLabel>
              Vaults · {vaults.filter(isRouted).length} of {vaults.length} routed on chain 46630
            </MicroLabel>
            <button
              type="button"
              onClick={() => setView("vaults")}
              className="flex items-center gap-1 font-mono text-[11px] uppercase tracking-[0.08em] text-white-60 transition-colors hover:text-green-bright"
            >
              All vaults <ArrowUpRight size={13} />
            </button>
          </div>
          <table className="w-full min-w-[1020px] font-mono text-[12px]">
            <thead>
              <tr className="border-b hairline-dark text-left text-[10px] uppercase tracking-[0.08em] text-white-60">
                <th className="px-5 py-3 font-medium">Vault</th>
                <th className="px-3 py-3 font-medium">Status</th>
                <th className="px-3 py-3 text-right font-medium">Oracle Price</th>
                <th className="px-3 py-3 text-right font-medium">Supply</th>
                <th className="hidden px-3 py-3 text-right font-medium lg:table-cell">Notional (att.)</th>
                <th className="hidden px-3 py-3 text-right font-medium xl:table-cell">Margin (att.)</th>
                <th className="hidden px-3 py-3 text-right font-medium md:table-cell">Buffer held</th>
                <th
                  className="hidden px-3 py-3 text-right font-medium md:table-cell"
                  title="used / capacityOracle.maxNotional18 — the bound _requireCapacity actually enforces."
                >
                  Mint ceiling used
                </th>
                <th
                  className="px-3 py-3 text-right font-medium"
                  title="solvency.deltaBps as a hedge-to-obligation ratio: 100% is at target."
                >
                  Hedge / obligation
                </th>
                <th className="hidden px-3 py-3 text-right font-medium lg:table-cell">Proven</th>
                <th className="w-8" />
              </tr>
            </thead>
            <tbody>
              {vaults.map((v) => {
                const routed = isRouted(v);
                return (
                  <tr
                    key={v.id}
                    onClick={routed ? () => goVault(v.id) : undefined}
                    aria-disabled={!routed}
                    title={routed ? v.full : STATUS_HINT[v.status]}
                    className={cn(
                      "group relative border-b hairline-dark transition-colors last:border-b-0",
                      routed
                        ? "cursor-pointer hover:bg-section-deep"
                        : "pointer-events-none select-none opacity-40 grayscale",
                    )}
                  >
                    <td className="relative px-5 py-3.5">
                      <span
                        className="absolute left-0 top-0 h-full w-[2px] scale-y-0 bg-green-bright transition-transform group-hover:scale-y-100"
                        aria-hidden
                      />
                      <span className="flex items-center gap-3">
                        <span className="font-sans text-[14px] font-semibold uppercase tracking-[-0.01em] text-white">
                          {v.name}
                        </span>
                      </span>
                    </td>
                    <td className="px-3 py-3.5">
                      <span
                        className={cn(
                          "whitespace-nowrap rounded-full border px-2.5 py-0.5 text-[10px] uppercase tracking-[0.08em]",
                          routed
                            ? "border-green-bright/40 text-green-bright"
                            : "border-white/20 text-white-60",
                        )}
                      >
                        {STATUS_LABEL[v.status]}
                      </span>
                    </td>
                    <td className="px-3 py-3.5 text-right tabular-nums text-white">
                      {!routed ? (
                        EM_DASH
                      ) : v.priceUnavailable ? (
                        <span className="text-warn">unavailable</span>
                      ) : (
                        fmtOrDash(v.price, (n) => fmtUSD(n))
                      )}
                    </td>
                    <Cell vault={v} value={v.supply} format={(n) => fmtNum(n, 2)} className="text-white" />
                    <Cell
                      vault={v}
                      value={v.backing ? v.backing.notional : null}
                      format={(n) => fmtCompactUSD(n)}
                      className="hidden text-silver lg:table-cell"
                    />
                    <Cell
                      vault={v}
                      value={v.backing ? v.backing.margin : null}
                      format={(n) => fmtCompactUSD(n)}
                      className="hidden text-silver xl:table-cell"
                    />
                    {/* Buffer held, as an absolute and nothing else. The "% of capacity18"
                        that used to sit here was a constant — see `CapacityCell`. */}
                    <td className="hidden px-3 py-3.5 text-right tabular-nums text-white-60 md:table-cell">
                      {routed && v.buffer !== null ? (
                        <span title="solvency.buffer18 — the vault's own ERC-20 collateral balance.">
                          {fmtCompactUSD(v.buffer)}
                        </span>
                      ) : (
                        EM_DASH
                      )}
                    </td>
                    <td className="hidden px-3 py-3.5 text-right md:table-cell">
                      {routed && v.capacity !== null ? (
                        <CapacityCell view={v.capacity} refreshable={attestationRefreshable(v.id)} />
                      ) : (
                        <span className="text-white-60">{EM_DASH}</span>
                      )}
                    </td>
                    {/* A hedge-to-obligation RATIO, not a drift: 100% is at target. Two of
                        its three states are zero-denominator sentinels. See `HedgeRatio`. */}
                    <td className="px-3 py-3.5 text-right tabular-nums">
                      {routed ? (
                        <HedgeRatio view={v.deltaView} />
                      ) : (
                        <span className="text-white-60">{EM_DASH}</span>
                      )}
                    </td>
                    <td className="hidden px-3 py-3.5 text-right lg:table-cell">
                      {routed ? (
                        <AgeLine
                          ageSec={v.ageSec}
                          stale={v.attestationStale}
                          maxAgeSec={maxAttestationAgeSec}
                          batch={v.backing ? v.backing.provenAtBatch : null}
              refreshable={attestationRefreshable(v.id)}
            />
                      ) : (
                        <span className="text-white-60">{EM_DASH}</span>
                      )}
                    </td>
                    <td className="pr-4 text-white-60">
                      {routed && (
                        <ChevronRight
                          size={14}
                          className="transition-transform group-hover:translate-x-0.5 group-hover:text-green-bright"
                        />
                      )}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
          {isLoading && (
            <p className="border-t hairline-dark px-5 py-3 font-mono text-[10px] uppercase tracking-[0.08em] text-white-60">
              Reading chain 46630…
            </p>
          )}
        </Panel>
      </Stagger>

      {/* Recent activity strip.
       *
       * This panel used to say "No flow history yet: needs an indexer". The premise was
       * right — receipt ids are not enumerable on-chain and there is no `receiptsOf(user)`,
       * so a list can only come from logs — but the conclusion was not: the chain's own
       * Blockscout instance indexes and decodes these events and answers the browser
       * directly. `RecentFlows` reads it, and carries the provenance note that says the
       * rows are a third-party index rather than a chain read. */}
      <Stagger index={6}>
        <Panel className="mt-3">
          <div className="flex items-center justify-between border-b hairline-dark px-5 py-4">
            <MicroLabel>Recent Flows</MicroLabel>
            <button
              type="button"
              onClick={() => setView("activity")}
              className="flex items-center gap-1 font-mono text-[11px] uppercase tracking-[0.08em] text-white-60 transition-colors hover:text-green-bright"
            >
              View all <ArrowUpRight size={13} />
            </button>
          </div>
          <RecentFlows limit={5} onViewAll={() => setView("activity")} />
        </Panel>
      </Stagger>
    </div>
  );
}
