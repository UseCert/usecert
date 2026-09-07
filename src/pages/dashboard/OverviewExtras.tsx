import { useMemo } from "react";
import { useDashboard } from "./store";
import { MicroLabel, Panel, PulseDot, Flash } from "./ui";
import { fmtCompactUSD, fmtUSD, fmtNum } from "./format";
import { cn } from "@/lib/utils";

/* --------------------------------------------------------- live ticker */

/** Bloomberg-style live ticker strip: every live vault, price, 24h delta, funding. */
export function TickerStrip() {
  const { vaults } = useDashboard();
  const live = vaults.filter((v) => v.status === "LIVE");
  const items = [...live, ...live]; // duplicate for seamless loop
  return (
    <div className="group relative mt-4 overflow-hidden border hairline-dark bg-section-deep-2">
      <div className="flex w-max animate-[ticker_28s_linear_infinite] group-hover:[animation-play-state:paused]">
        {items.map((v, i) => (
          <span
            key={`${v.id}-${i}`}
            className="flex items-center gap-3 border-r hairline-dark px-6 py-2.5 font-mono text-[11px] uppercase tracking-[0.08em]"
          >
            <span className="font-semibold text-white">{v.name}</span>
            <span className="tabular-nums text-white">
              <Flash value={v.price} format={(n) => fmtUSD(n)} />
            </span>
            <span className={cn("tabular-nums", v.change24h >= 0 ? "text-green-bright" : "text-silver")}>
              {v.change24h >= 0 ? "▲" : "▼"} {Math.abs(v.change24h).toFixed(2)}%
            </span>
            <span className="text-white-60/60">FUND {v.funding8h >= 0 ? "+" : ""}{v.funding8h.toFixed(4)}%/8H</span>
          </span>
        ))}
      </div>
    </div>
  );
}

/* -------------------------------------------------- backing composition */

/** Stacked composition bars: perp position notional vs USDC margin vs buffer, per vault + protocol. */
export function BackingComposition() {
  const { vaults, totals } = useDashboard();
  const live = vaults.filter((v) => v.status === "LIVE");

  const rows = useMemo(() => {
    const rs = live.map((v) => {
      const notional = v.supply * v.price;
      const margin = notional * 1.0002;
      return { label: v.name, notional, margin: margin - notional, buffer: v.buffer, total: margin + v.buffer };
    });
    const total = rs.reduce((s, r) => s + r.total, 0);
    return { rs, total };
  }, [live]);

  return (
    <Panel className="flex h-full flex-col p-5">
      <div className="flex items-center justify-between">
        <MicroLabel>Backing Composition</MicroLabel>
        <span className="font-mono text-[10px] uppercase tracking-[0.08em] text-white-60/50">/05</span>
      </div>
      <p className="mt-3 font-mono text-[26px] leading-none tracking-[-0.03em] text-white tabular-nums">
        {fmtCompactUSD(totals.margin + totals.buffer)}
      </p>
      <p className="mt-1 font-mono text-[10px] uppercase tracking-[0.08em] text-white-60">
        Total collateral + buffer
      </p>

      <div className="mt-5 flex flex-col gap-4">
        {rows.rs.map((r) => (
          <div key={r.label}>
            <div className="mb-1.5 flex items-baseline justify-between font-mono text-[10px] uppercase tracking-[0.08em]">
              <span className="text-white">{r.label}</span>
              <span className="tabular-nums text-white-60">{fmtCompactUSD(r.total)}</span>
            </div>
            <div className="flex h-[10px] w-full overflow-hidden bg-white/5">
              <span className="h-full bg-silver/80" style={{ width: `${(r.notional / rows.total) * 100}%` }} />
              <span className="h-full bg-white/30" style={{ width: `${(r.margin / rows.total) * 100}%` }} />
              <span className="h-full bg-green-bright" style={{ width: `${(r.buffer / rows.total) * 100}%` }} />
            </div>
          </div>
        ))}
      </div>

      <div className="mt-auto flex flex-wrap gap-x-5 gap-y-1.5 pt-5 font-mono text-[10px] uppercase tracking-[0.08em] text-white-60">
        <span className="flex items-center gap-2"><span className="h-2 w-2 bg-silver/80" /> Perp notional</span>
        <span className="flex items-center gap-2"><span className="h-2 w-2 bg-white/30" /> USDC margin</span>
        <span className="flex items-center gap-2"><span className="h-2 w-2 bg-green-bright" /> Buffer</span>
      </div>
    </Panel>
  );
}

/* ------------------------------------------------------- funding monitor */

function MiniFundingBars({ rates }: { rates: number[] }) {
  const maxAbs = Math.max(...rates.map((r) => Math.abs(r))) || 1;
  return (
    <span className="flex h-[26px] items-center gap-[2px]" aria-hidden>
      {rates.map((r, i) => (
        <span
          key={i}
          className={cn("w-[3px]", r >= 0 ? "bg-green-bright/70" : "bg-warn/70")}
          style={{ height: `${Math.max(8, (Math.abs(r) / maxAbs) * 100)}%` }}
        />
      ))}
    </span>
  );
}

/** Per-vault funding: current hourly rate, 8h rate, annualized, 24h mini bars, buffer flow. */
export function FundingMonitor() {
  const { vaults, keepers } = useDashboard();
  const live = vaults.filter((v) => v.status === "LIVE");
  const sweep = keepers.find((k) => k.id === "funding");
  const nextIn = sweep?.nextInSec ?? 0;
  const mm = Math.floor(nextIn / 60);
  const ss = String(nextIn % 60).padStart(2, "0");

  return (
    <Panel className="flex h-full flex-col p-5">
      <div className="flex items-center justify-between">
        <MicroLabel>Funding Monitor</MicroLabel>
        <span className="flex items-center gap-2 font-mono text-[10px] uppercase tracking-[0.08em] text-white-60">
          <PulseDot /> Next sweep {mm}:{ss}
        </span>
      </div>

      <div className="mt-4 flex flex-col divide-y divide-white/5">
        {live.map((v) => {
          const hourly = v.funding[v.funding.length - 1]?.rate ?? 0;
          const annualized = v.funding8h * 3 * 365;
          const last24 = v.funding.slice(-24).map((b) => b.rate);
          const accrued24 = v.funding.slice(-24).reduce((s, b) => s + b.accrued, 0);
          return (
            <div key={v.id} className="flex items-center justify-between gap-4 py-3">
              <div className="w-[90px]">
                <p className="font-sans text-[13px] font-semibold uppercase text-white">{v.name}</p>
                <p className="font-mono text-[10px] uppercase tracking-[0.08em] text-white-60/60">1H rate</p>
              </div>
              <div className="hidden flex-1 md:block">
                <MiniFundingBars rates={last24} />
              </div>
              <div className="text-right font-mono text-[11px] leading-[1.6]">
                <p className={cn("tabular-nums", hourly >= 0 ? "text-green-bright" : "text-warn")}>
                  {hourly >= 0 ? "+" : ""}{hourly.toFixed(4)}%
                </p>
                <p className="tabular-nums text-white-60/70">{annualized.toFixed(1)}% ann.</p>
              </div>
              <div className="w-[86px] text-right font-mono text-[11px] leading-[1.6]">
                <p className="tabular-nums text-silver">{accrued24 >= 0 ? "+" : ""}{fmtUSD(accrued24, 0)}</p>
                <p className="text-white-60/70">24H to buffer</p>
              </div>
            </div>
          );
        })}
      </div>

      <p className="mt-auto pt-4 font-mono text-[10px] leading-[1.6] uppercase tracking-[0.06em] text-white-60">
        Positive funding fattens the buffer. Negative funding draws it down before any fee ever activates.
      </p>
    </Panel>
  );
}

/* --------------------------------------------------------- network strip */

/** Chain vitals strip: block, block time, oracle latency, keepers, indexer. */
export function NetworkStrip() {
  const { block, vaults, keepers } = useDashboard();
  const live = vaults.filter((v) => v.status === "LIVE").length;
  const stats = [
    { label: "Block height", value: block.toLocaleString("en-US"), mono: true },
    { label: "Block time", value: "0.40s" },
    { label: "Oracle latency", value: "38ms" },
    { label: "Vaults live", value: `${live}/4` },
    { label: "Keepers online", value: `${keepers.length}/${keepers.length}` },
    { label: "Indexer lag", value: "0 blocks" },
  ];
  return (
    <div className="mt-3 grid grid-cols-2 gap-px border hairline-dark bg-white/5 sm:grid-cols-3 xl:grid-cols-6">
      {stats.map((s) => (
        <div key={s.label} className="bg-abyss px-4 py-3">
          <p className="font-mono text-[9px] uppercase tracking-[0.1em] text-white-60/70">{s.label}</p>
          <p className="mt-1 font-mono text-[14px] tabular-nums text-white">{s.value}</p>
        </div>
      ))}
    </div>
  );
}

/* ----------------------------------------------------------- peg monitor */

/** Oracle vs certificate market price: spread in bps with deviation sparkline per vault. */
export function PegMonitor() {
  const { vaults } = useDashboard();
  const live = vaults.filter((v) => v.status === "LIVE");

  return (
    <Panel className="mt-3 overflow-x-auto">
      <div className="flex items-center justify-between border-b hairline-dark px-5 py-4">
        <MicroLabel>Peg Monitor · Oracle vs Market</MicroLabel>
        <span className="font-mono text-[10px] uppercase tracking-[0.08em] text-white-60/50">Band ±25 bps</span>
      </div>
      <table className="w-full min-w-[640px] font-mono text-[12px]">
        <thead>
          <tr className="border-b hairline-dark text-left text-[10px] uppercase tracking-[0.08em] text-white-60">
            <th className="px-5 py-3 font-medium">Vault</th>
            <th className="px-3 py-3 text-right font-medium">Oracle</th>
            <th className="px-3 py-3 text-right font-medium">Market</th>
            <th className="px-3 py-3 text-right font-medium">Spread</th>
            <th className="hidden px-3 py-3 text-right font-medium md:table-cell">24H volume</th>
            <th className="hidden px-3 py-3 text-right font-medium lg:table-cell">Mint/Redeem fee</th>
            <th className="px-3 py-3 text-right font-medium">Peg</th>
          </tr>
        </thead>
        <tbody>
          {live.map((v, i) => {
            const spreadBps = [3.2, -1.8, 1.1][i % 3];
            const market = v.price * (1 + spreadBps / 10000);
            const vol = v.supply * v.price * [0.061, 0.048, 0.022][i % 3];
            const inBand = Math.abs(spreadBps) <= 25;
            return (
              <tr key={v.id} className="border-b hairline-dark last:border-b-0">
                <td className="px-5 py-3.5">
                  <span className="font-sans text-[14px] font-semibold uppercase text-white">{v.name}</span>
                </td>
                <td className="px-3 py-3.5 text-right tabular-nums text-white">
                  <Flash value={v.price} format={(n) => fmtUSD(n)} />
                </td>
                <td className="px-3 py-3.5 text-right tabular-nums text-silver">{fmtUSD(market)}</td>
                <td className={cn("px-3 py-3.5 text-right tabular-nums", inBand ? "text-green-bright" : "text-warn")}>
                  {spreadBps >= 0 ? "+" : ""}{spreadBps.toFixed(1)} bps
                </td>
                <td className="hidden px-3 py-3.5 text-right tabular-nums text-white-60 md:table-cell">{fmtCompactUSD(vol)}</td>
                <td className="hidden px-3 py-3.5 text-right tabular-nums text-white-60 lg:table-cell">10 bps</td>
                <td className="px-3 py-3.5 text-right">
                  <span className={cn(
                    "rounded-full border px-2.5 py-0.5 text-[10px] uppercase tracking-[0.08em]",
                    inBand ? "border-green-bright/40 text-green-bright" : "border-warn/40 text-warn",
                  )}>
                    {inBand ? "In band" : "Watch"}
                  </span>
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>
      <p className="border-t hairline-dark px-5 py-3 font-mono text-[10px] leading-[1.6] uppercase tracking-[0.06em] text-white-60">
        Arbitrageurs close any spread beyond the mint/redeem fee. Redemption at oracle price is never gated, so the peg has a hard floor. Supply across vaults: {fmtNum(live.reduce((s, v) => s + v.supply, 0), 0)} certificates.
      </p>
    </Panel>
  );
}
