import { useState } from "react";
import { AnimatePresence, motion } from "framer-motion";
import { ArrowUpRight, ChevronRight } from "lucide-react";
import { useDashboard } from "./store";
import type { Timeframe } from "./store";
import { MicroLabel, Panel, PulseDot, Sparkline, Stagger, UnderlineTabs, Flash, ViewHeader, GhostWord } from "./ui";
import { useCountUp } from "./hooks";
import { SolvencyChart } from "./charts";
import { fmtCompactUSD, fmtNum, fmtUSD, timeAgo, truncHash } from "./format";
import { FlowTypeBadge } from "./flows";
import { flowVaultLabel } from "./flowMeta";
import { TickerStrip, BackingComposition, FundingMonitor, NetworkStrip, PegMonitor } from "./OverviewExtras";
import { cn } from "@/lib/utils";

const TF_OPTIONS: { value: Timeframe; label: string }[] = [
  { value: "1H", label: "1H" },
  { value: "24H", label: "24H" },
  { value: "7D", label: "7D" },
  { value: "ALL", label: "ALL" },
];

function BufferMiniBar({ pct }: { pct: number }) {
  return (
    <span className="relative inline-block h-[6px] w-[60px] bg-white/10 align-middle">
      <span className="absolute left-0 top-0 h-full bg-green-bright transition-all duration-500" style={{ width: `${pct}%` }} />
      {[20, 45, 70].map((t) => (
        <span key={t} className="absolute top-[-2px] h-[10px] w-px bg-white/40" style={{ left: `${t}%` }} aria-hidden />
      ))}
    </span>
  );
}

function StatCard({
  index,
  caption,
  value,
  format,
  delta,
  spark,
}: {
  index: number;
  caption: string;
  value: number;
  format: (n: number) => string;
  delta: React.ReactNode;
  spark: number[];
}) {
  const animated = useCountUp(value, 1.2);
  return (
    <Stagger index={index}>
      <Panel className="group flex h-full flex-col gap-2 p-5 transition-colors hover:bg-section-deep">
        <div className="flex items-center justify-between">
          <MicroLabel>{caption}</MicroLabel>
          <span className="font-mono text-[10px] uppercase tracking-[0.08em] text-white-60/50 transition-colors group-hover:text-green-bright">
            /{String(index + 1).padStart(2, "0")}
          </span>
        </div>
        <p className="font-mono text-[34px] leading-none tracking-[-0.04em] text-white md:text-[40px]">
          <Flash value={animated} format={format} />
        </p>
        <div className="font-mono text-[11px]">{delta}</div>
        <Sparkline data={spark} className="mt-auto" />
      </Panel>
    </Stagger>
  );
}

export default function Overview() {
  const { totals, agg, block, vaults, goVault, flows, setView } = useDashboard();
  const [tf, setTf] = useState<Timeframe>("24H");

  const series = agg[tf];
  const daySeries = agg["24H"];
  const supplyChange = (daySeries[daySeries.length - 1].obligation / daySeries[0].obligation - 1) * 100;
  const sparkBase = daySeries.slice(-24).map((p) => p.obligation);
  const sparkBacking = daySeries.slice(-24).map((p) => p.backing / p.obligation);
  const liveVaults = vaults.filter((v) => v.status === "LIVE");
  const bufferSeries = liveVaults[0].funding.map((_, i) =>
    liveVaults.reduce((s, v) => s + (v.funding[i]?.bufferAfter ?? 0), 0),
  );

  return (
    <div className="relative">
      <GhostWord className="-top-10 right-0 hidden text-[180px] xl:block">Live</GhostWord>

      {/* Top mono stat row, same rhythm as the landing deep-green section */}
      <div className="flex flex-wrap items-center justify-between gap-3 border-b hairline-dark pb-4 font-mono text-[11px] uppercase tracking-[0.08em] text-white-60">
        <span className="flex items-center gap-2">
          <PulseDot /> C1 Live
        </span>
        <span className="hidden md:block">Robinhood Chain©</span>
        <span>Solvency public / every block</span>
      </div>

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
        right={<UnderlineTabs options={TF_OPTIONS} value={tf} onChange={setTf} />}
      />

      {/* Stat cards */}
      <div className="mt-8 grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
        <StatCard
          index={0}
          caption="Total Certificate Supply"
          value={totals.notional}
          format={(n) => fmtCompactUSD(n)}
          delta={
            <span className={cn(supplyChange >= 0 ? "text-green-bright" : "text-silver")}>
              {supplyChange >= 0 ? "▲" : "▼"} {Math.abs(supplyChange).toFixed(1)}% / 24H
            </span>
          }
          spark={sparkBase}
        />
        <StatCard
          index={1}
          caption="Backing Ratio"
          value={totals.ratio}
          format={(n) => `${n.toFixed(2)}%`}
          delta={<span className="text-green-bright">✓ invariant holds, every block</span>}
          spark={sparkBacking}
        />
        <StatCard
          index={2}
          caption="Protocol Buffer"
          value={totals.buffer}
          format={(n) => fmtCompactUSD(n)}
          delta={<span className="text-green-bright">▲ 0.4% / 24H</span>}
          spark={bufferSeries.length > 1 ? bufferSeries : [1, 1]}
        />
        <StatCard
          index={3}
          caption="Weighted Delta"
          value={totals.delta}
          format={(n) => n.toFixed(3)}
          delta={<span className="text-white-60">target 1.0 across all vaults</span>}
          spark={sparkBacking.map((v) => v * 0.999 + 0.0005)}
        />
      </div>

      {/* Solvency chart */}
      <Stagger index={4}>
        <Panel className="section-glow relative mt-3 p-5 md:p-6">
          <div className="mb-4 flex flex-wrap items-center justify-between gap-3">
            <div className="flex items-center gap-5 font-mono text-[10px] uppercase tracking-[0.08em]">
              <span className="flex items-center gap-2 text-white-60">
                <span className="h-2 w-2 bg-green-bright" aria-hidden /> Backing
              </span>
              <span className="flex items-center gap-2 text-white-60">
                <span className="h-2 w-2 bg-silver" aria-hidden /> Supply × Price
              </span>
            </div>
            <span className="flex items-center gap-2 rounded-full border hairline-dark px-3 py-1 font-mono text-[10px] uppercase tracking-[0.08em] text-white-60">
              <PulseDot /> Live · Block <span className="tabular-nums text-white">{block.toLocaleString("en-US")}</span>
            </span>
          </div>
          <SolvencyChart points={series} tf={tf} height={380} />
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
            <MicroLabel>Vaults</MicroLabel>
            <button
              type="button"
              onClick={() => setView("vaults")}
              className="flex items-center gap-1 font-mono text-[11px] uppercase tracking-[0.08em] text-white-60 transition-colors hover:text-green-bright"
            >
              All vaults <ArrowUpRight size={13} />
            </button>
          </div>
          <table className="w-full min-w-[760px] font-mono text-[12px]">
            <thead>
              <tr className="border-b hairline-dark text-left text-[10px] uppercase tracking-[0.08em] text-white-60">
                <th className="px-5 py-3 font-medium">Vault</th>
                <th className="px-3 py-3 font-medium">Status</th>
                <th className="px-3 py-3 text-right font-medium">Price</th>
                <th className="px-3 py-3 text-right font-medium">Supply</th>
                <th className="hidden px-3 py-3 text-right font-medium lg:table-cell">Position Notional</th>
                <th className="hidden px-3 py-3 text-right font-medium xl:table-cell">Margin</th>
                <th className="hidden px-3 py-3 font-medium md:table-cell">Buffer</th>
                <th className="px-3 py-3 text-right font-medium">Delta</th>
                <th className="w-8" />
              </tr>
            </thead>
            <tbody>
              {vaults.map((v) => {
                const live = v.status === "LIVE";
                const notional = v.supply * v.price;
                return (
                  <tr
                    key={v.id}
                    onClick={() => live && goVault(v.id)}
                    className={cn(
                      "group relative border-b hairline-dark transition-colors last:border-b-0",
                      live ? "cursor-pointer hover:bg-section-deep" : "opacity-50",
                    )}
                  >
                    <td className="relative px-5 py-3.5">
                      <span className="absolute left-0 top-0 h-full w-[2px] scale-y-0 bg-green-bright transition-transform group-hover:scale-y-100" aria-hidden />
                      <span className="flex items-center gap-3">
                        <img src={v.img} alt="" className="h-8 w-8 border hairline-dark object-cover" />
                        <span className="font-sans text-[14px] font-semibold uppercase tracking-[-0.01em] text-white">{v.name}</span>
                      </span>
                    </td>
                    <td className="px-3 py-3.5">
                      <span
                        className={cn(
                          "rounded-full border px-2.5 py-0.5 text-[10px] uppercase tracking-[0.08em]",
                          live ? "border-green-bright/40 text-green-bright" : "border-warn/40 text-warn",
                        )}
                      >
                        {v.status}
                      </span>
                    </td>
                    <td className="px-3 py-3.5 text-right tabular-nums text-white">{live ? fmtUSD(v.price) : "–"}</td>
                    <td className="px-3 py-3.5 text-right tabular-nums text-white">{live ? fmtNum(v.supply, 0) : "–"}</td>
                    <td className="hidden px-3 py-3.5 text-right tabular-nums text-silver lg:table-cell">{live ? fmtCompactUSD(notional) : "–"}</td>
                    <td className="hidden px-3 py-3.5 text-right tabular-nums text-silver xl:table-cell">{live ? fmtCompactUSD(notional * 1.0002) : "–"}</td>
                    <td className="hidden px-3 py-3.5 md:table-cell">
                      {live ? (
                        <span className="flex items-center gap-2">
                          <BufferMiniBar pct={v.bufferPct} />
                          <span className="tabular-nums text-white-60">{v.bufferPct.toFixed(0)}%</span>
                        </span>
                      ) : (
                        "–"
                      )}
                    </td>
                    <td className="px-3 py-3.5 text-right tabular-nums text-white">{live ? v.delta.toFixed(3) : "–"}</td>
                    <td className="pr-4 text-white-60">
                      {live && <ChevronRight size={14} className="transition-transform group-hover:translate-x-0.5 group-hover:text-green-bright" />}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </Panel>
      </Stagger>

      {/* Recent activity strip */}
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
          <ul>
            <AnimatePresence initial={false}>
              {flows.slice(0, 5).map((f) => (
                <motion.li
                  key={f.id}
                  layout="position"
                  initial={{ opacity: 0, y: -14 }}
                  animate={{ opacity: 1, y: 0 }}
                  transition={{ duration: 0.4 }}
                  className="flex flex-wrap items-center gap-x-5 gap-y-1 border-b hairline-dark px-5 py-3 font-mono text-[12px] last:border-b-0"
                >
                  <FlowTypeBadge type={f.type} className="w-[110px]" />
                  <span className="w-[60px] text-white">{flowVaultLabel(f)}</span>
                  <span className="tabular-nums text-silver">{fmtNum(f.amount, f.vault === "token" ? 2 : 4)}</span>
                  <span className="tabular-nums text-white">{fmtUSD(f.usdc, 0)}</span>
                  <span className="hidden tabular-nums text-white-60 md:inline">{f.feeBps > 0 ? `${f.feeBps} bps` : "0 bps"}</span>
                  <span className="ml-auto text-white-60">{timeAgo(f.time)}</span>
                  <span className="hidden text-white-60 sm:inline">{truncHash(f.tx)}</span>
                </motion.li>
              ))}
            </AnimatePresence>
          </ul>
        </Panel>
      </Stagger>
    </div>
  );
}
