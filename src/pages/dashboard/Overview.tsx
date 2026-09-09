import { ArrowUpRight, ChevronRight } from "lucide-react";
import { isRouted, STATUS_HINT, STATUS_LABEL, useDashboard } from "./store";
import type { Vault } from "./store";
import {
  AgeLine,
  EmptyState,
  Flash,
  GhostWord,
  MicroLabel,
  Panel,
  PulseDot,
  Stagger,
  UnverifiedTag,
  ViewHeader,
} from "./ui";
import { useCountUp } from "./hooks";
import { EM_DASH, fmtCompactUSD, fmtNum, fmtOrDash, fmtUSD } from "./format";
import { TickerStrip, BackingComposition, FundingMonitor, NetworkStrip, PegMonitor } from "./OverviewExtras";
import { cn } from "@/lib/utils";

function BufferMiniBar({ pct }: { pct: number }) {
  return (
    <span className="relative inline-block h-[6px] w-[60px] bg-white/10 align-middle">
      <span
        className="absolute left-0 top-0 h-full bg-green-bright transition-all duration-500"
        style={{ width: `${Math.max(0, Math.min(100, pct))}%` }}
      />
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
  register = "primary",
}: {
  index: number;
  caption: string;
  value: number | null;
  format: (n: number) => string;
  note: React.ReactNode;
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
            "font-mono text-[34px] leading-none tracking-[-0.04em] md:text-[40px]",
            register === "claim" ? "text-silver" : "text-white",
          )}
        >
          {value === null ? (
            <span className="text-white-60/60">{EM_DASH}</span>
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
    flowsUnavailable,
    isLoading,
    isError,
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
      <GhostWord className="-top-10 right-0 hidden text-[180px] xl:block">Live</GhostWord>

      {/* Top mono stat row, same rhythm as the landing deep-green section.
          "C1 Live" is gone: C1 is the identifier of an audit, not a release badge, and
          that audit reported open criticals — so the string could only ever be read as a
          certification the project does not have. What is factually true is which chain
          this is reading and how solvency is proven, so that is what it says.
          "Solvency public / every block" is gone for the same reason: solvency is proven
          per attestation, on roughly a 60-second cadence, and the AgeLine below publishes
          the real age of the current proof. */}
      <div className="flex flex-wrap items-center justify-between gap-3 border-b hairline-dark pb-4 font-mono text-[11px] uppercase tracking-[0.08em] text-white-60">
        <span className="flex items-center gap-2">
          <PulseDot /> Testnet 46630
        </span>
        <span className="hidden md:block">Robinhood Chain©</span>
        <span>Solvency proven per attestation · age published</span>
      </div>

      {/* The one line about the venue. The site is openly a testnet, so this is stated
          plainly and once, without a banner. */}
      <p className="mt-3 font-mono text-[10px] uppercase leading-[1.7] tracking-[0.06em] text-white-60/70">
        On testnet the perp venue is simulated, so the attested margin and notional below describe a
        simulated position.
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
            />
          }
        />
        <StatCard
          index={1}
          caption="Margin / Notional (attested)"
          value={totals ? totals.ratio : null}
          format={(n) => `${n.toFixed(2)}%`}
          note={<span className="text-white-60">both halves are attester-relayed figures</span>}
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
          <table className="w-full min-w-[900px] font-mono text-[12px]">
            <thead>
              <tr className="border-b hairline-dark text-left text-[10px] uppercase tracking-[0.08em] text-white-60">
                <th className="px-5 py-3 font-medium">Vault</th>
                <th className="px-3 py-3 font-medium">Status</th>
                <th className="px-3 py-3 text-right font-medium">Oracle Price</th>
                <th className="px-3 py-3 text-right font-medium">Supply</th>
                <th className="hidden px-3 py-3 text-right font-medium lg:table-cell">Notional (att.)</th>
                <th className="hidden px-3 py-3 text-right font-medium xl:table-cell">Margin (att.)</th>
                <th className="hidden px-3 py-3 font-medium md:table-cell">Buffer held</th>
                <th className="px-3 py-3 text-right font-medium">Delta drift</th>
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
                        <img
                          src={v.img}
                          alt=""
                          className={cn(
                            "h-8 w-8 border hairline-dark object-cover",
                            v.imgPlaceholder && "object-contain p-1 opacity-80",
                          )}
                        />
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
                    <td className="hidden px-3 py-3.5 md:table-cell">
                      {routed && v.buffer !== null ? (
                        <span className="flex items-center gap-2">
                          {v.bufferPct !== null && <BufferMiniBar pct={v.bufferPct} />}
                          {/* Ratio of the held balance to bufferCapacity18 — NOT a
                              "percent of target": see INTEGRATION-STAGE2.md. */}
                          <span
                            className="tabular-nums text-white-60"
                            title="Buffer held (ERC-20 balance) over bufferCapacity18, both read on-chain."
                          >
                            {fmtCompactUSD(v.buffer)}
                            {v.bufferPct !== null ? ` · ${v.bufferPct.toFixed(0)}% of capacity18` : ""}
                          </span>
                        </span>
                      ) : (
                        EM_DASH
                      )}
                    </td>
                    {/* deltaBps is UNSIGNED on-chain: magnitude only, never a direction. */}
                    <td className="px-3 py-3.5 text-right tabular-nums text-white">
                      {routed ? fmtOrDash(v.deltaBps, (n) => `${n.toFixed(2)}% from target`) : EM_DASH}
                    </td>
                    <td className="hidden px-3 py-3.5 text-right lg:table-cell">
                      {routed ? (
                        <AgeLine
                          ageSec={v.ageSec}
                          stale={v.attestationStale}
                          maxAgeSec={maxAttestationAgeSec}
                          batch={v.backing ? v.backing.provenAtBatch : null}
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

      {/* Recent activity strip: nothing to show without an indexer */}
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
          {flowsUnavailable && (
            <EmptyState
              className="border-0"
              title="No flow history yet: needs an indexer"
              detail="Receipt ids are not enumerable on-chain and there is no receiptsOf(user); a flow list can only be built from indexed events. None are indexed yet."
            />
          )}
        </Panel>
      </Stagger>
    </div>
  );
}
