import { useState } from "react";
import { fundingBars, solvencySeries, useHistory } from "@/chain/useHistory";
import { FundingChart, SolvencyChart } from "./charts";
import { useDashboard } from "./store";
import { EmptyState } from "./ui";
import { fmtAge } from "./format";
import { cn } from "@/lib/utils";

/** Server-recorded, not a live read: see src/chain/useHistory.ts for what that trusts. */
export function RecordedTag({ className, label = "Recorded by UseCert" }: { className?: string; label?: string }) {
  return (
    <span
      className={cn(
        "inline-flex items-center gap-1 border border-silver/40 px-1.5 py-px font-mono text-[9px] uppercase tracking-[0.08em] text-silver",
        className,
      )}
      title="Sampled every 5 minutes by the UseCert server from the same chain reads this dashboard makes (vault.solvency(), oracle.px()). The values are chain reads; the recording time is the server's word."
    >
      {label}
    </span>
  );
}

function Note({ children }: { children: React.ReactNode }) {
  return (
    <p className="mt-2 font-mono text-[10px] leading-[1.6] uppercase tracking-[0.06em] text-white-60/70">{children}</p>
  );
}

/**
 * Backing and obligation over time, for the given vault symbols summed (the recorder samples
 * every vault in one pass, so their timestamps line up; a timestamp missing a vault is dropped).
 */
export function SolvencyHistory({ symbols: only, height = 260 }: { symbols?: string[]; height?: number }) {
  const { now, liveVaults } = useDashboard();
  const symbols = only ?? liveVaults.map((v) => v.name);
  const q = useHistory();
  const d = q.data;
  const series = d ? symbols.map((s) => d.solvency[s]).filter(Boolean) : [];
  const res = d && series.length === symbols.length ? solvencySeries(series) : null;

  if (q.isError && !d)
    return (
      <EmptyState
        height={height}
        title="Solvency history unavailable"
        detail="The recorder's file could not be read. The figures above are live chain reads and are unaffected."
      />
    );
  if (!res)
    return (
      <EmptyState
        height={height}
        title={d ? "Solvency history: recording" : "Reading the recorded history…"}
        detail="Backing and obligation are sampled every 5 minutes from vault.solvency() and oracle.px(). A curve is drawn once there are two samples; nothing is interpolated."
      />
    );
  return (
    <div>
      <div className="mb-2 flex flex-wrap items-center gap-2">
        <RecordedTag />
        <span className="font-mono text-[10px] uppercase tracking-[0.06em] text-white-60">
          {`${res.points.length} points · every ${res.tf === "24H" ? "24 min" : "4 min"} · file written ${fmtAge(now / 1000 - d!.generatedAt)}`}
        </span>
      </div>
      <SolvencyChart points={res.points} tf={res.tf} height={height} />
      <Note>
        Each point is the latest 5-minute sample at or before its slot. Margin is the attested
        figure as last relayed, so it moves when a mint relays a new attestation, not between.
        {res.anyPxFallback ? " Some points use the attested notional because oracle.px() reverted at that sample." : ""}
      </Note>
    </div>
  );
}

/** The venue's last 48 hourly funding rates for one vault's market, or a picker across several. */
export function FundingHistory({ symbols, height = 220 }: { symbols: string[]; height?: number }) {
  const q = useHistory();
  const [pick, setPick] = useState(symbols[0]);
  const sym = symbols.includes(pick) ? pick : symbols[0];
  const f = q.data?.funding[sym];
  const bars = fundingBars(f);

  if (q.isError && !q.data)
    return <EmptyState height={height} title="Funding history unavailable" detail="The recorder's file could not be read." />;
  return (
    <div>
      <div className="mb-2 flex flex-wrap items-center gap-2">
        <RecordedTag label="Venue data" />
        {symbols.length > 1 &&
          symbols.map((s) => (
            <button
              key={s}
              type="button"
              onClick={() => setPick(s)}
              className={cn(
                "border px-2 py-0.5 font-mono text-[10px] uppercase tracking-[0.06em]",
                s === sym ? "border-green-bright text-green-bright" : "hairline-dark text-white-60 hover:text-white",
              )}
            >
              {s}
            </button>
          ))}
        {f?.stale && <span className="font-mono text-[10px] uppercase text-warn">last read failed · showing the previous one</span>}
      </div>
      {bars.length === 0 ? (
        <EmptyState height={height} title="Reading the venue's funding history…" />
      ) : (
        <FundingChart bars={bars} height={height} />
      )}
      <Note>
        {`Robinhood Chain Lighter, market ${f?.market ?? "—"}, the last ${bars.length} hourly rates as the venue publishes them, in percent per hour. The vaults hold longs, so a bar below zero is funding the vault pays (longs pay while the rate is positive) and above zero is funding it receives.`}
      </Note>
    </div>
  );
}
