import { AlertTriangle, Check, FileText, Layers, Lock, Radio } from "lucide-react";
import { useDashboard } from "./store";
import { MicroLabel, Panel, PulseDot, Stagger, ViewHeader } from "./ui";
import { fmtCompactUSD } from "./format";
import { cn } from "@/lib/utils";

/* --------------------------------------------------------------- content */

const DESIGN_LAWS: { n: string; title: string; body: string }[] = [
  {
    n: "01",
    title: "Fully delta-backed",
    body: "Each vault targets delta 1.0: certificate supply × oracle price ≤ perp notional + USDC margin, provable on-chain every block.",
  },
  {
    n: "02",
    title: "Redemption is never gated",
    body: "Burn → close matching exposure → USDC at oracle price. Buffer stress slows minting, never redemption.",
  },
  {
    n: "03",
    title: "Funding buffered, then fee'd, never hidden",
    body: "Positive funding fattens the buffer. Sustained negative funding draws it down and, past the published threshold, passes through as a transparent holding fee.",
  },
  {
    n: "04",
    title: "Holders are senior",
    body: "Staked CERT is the junior tranche and absorbs buffer exhaustion before holder backing is ever touched.",
  },
  {
    n: "05",
    title: "Mirror the market honestly",
    body: "Certificates are synthetic price exposure — no custody of shares, no dividends, no shareholder rights. Corporate actions follow the underlying market spec.",
  },
];

const PARAMETERS: { group: string; rows: { k: string; v: string; note?: string }[] }[] = [
  {
    group: "Vault engine",
    rows: [
      { k: "Delta target", v: "1.000", note: "rebalance band ±0.20%" },
      { k: "Rebalance trigger", v: "Band breach or 8h elapsed" },
      { k: "Mint fee", v: "10 bps", note: "to fee vault" },
      { k: "Redeem fee", v: "10 bps", note: "to fee vault" },
      { k: "Max mint / block", v: "$2.50M notional", note: "per vault" },
      { k: "Redemption cap", v: "None", note: "law 02" },
    ],
  },
  {
    group: "Oracle & venue",
    rows: [
      { k: "Price source", v: "Robinhood Chain equity perp oracle" },
      { k: "Staleness guard", v: "60s", note: "mint paused beyond" },
      { k: "Deviation guard", v: "±3.0%", note: "vs 5-min TWAP" },
      { k: "Settlement asset", v: "USDC" },
      { k: "Venue dependency", v: "HIP-3 style equity perp book" },
    ],
  },
  {
    group: "Buffer & insurance",
    rows: [
      { k: "Buffer target", v: "2.0% of notional" },
      { k: "Fee passthrough threshold", v: "Buffer < 25% of target" },
      { k: "Max holding fee", v: "50 bps / yr", note: "published, never silent" },
      { k: "Junior tranche", v: "Staked CERT" },
      { k: "Slash order", v: "Buffer → staked CERT → never holders" },
    ],
  },
];

const SCENARIOS: { name: string; shock: string; draw: string; holder: string; severity: "ok" | "warn" }[] = [
  { name: "Funding inversion", shock: "−30% annualised funding, 30 days", draw: "−41% of buffer", holder: "None · buffer absorbs", severity: "ok" },
  { name: "Equity gap down", shock: "−20% overnight gap on the underlying", draw: "−12% of buffer", holder: "None · delta re-marks 1:1", severity: "ok" },
  { name: "Redemption run", shock: "45% of supply redeemed in 24h", draw: "−9% of buffer", holder: "None · slippage inside fee", severity: "ok" },
  { name: "Oracle outage", shock: "Price feed stale > 60s", draw: "0%", holder: "Minting paused · redemption at last valid TWAP", severity: "warn" },
  { name: "Venue halt", shock: "Perp market operator halts the book", draw: "Frozen", holder: "Positions marked, redemption queued to reopen", severity: "warn" },
];

const ATTESTATIONS: { label: string; value: string; state: "ok" | "warn" }[] = [
  { label: "Solvency snapshot", value: "Pinned to chain state · every block", state: "ok" },
  { label: "Keeper heartbeat", value: "5 / 5 keepers reporting", state: "ok" },
  { label: "Contract upgradeability", value: "Vaults immutable · params behind 48h timelock", state: "ok" },
  { label: "Admin keys", value: "3 / 5 multisig · fresh deployer", state: "ok" },
  { label: "External audit", value: "Scheduled pre-C3 · reports published", state: "warn" },
];

/* ----------------------------------------------------------------- pieces */

function LawCard({ law, index }: { law: (typeof DESIGN_LAWS)[number]; index: number }) {
  return (
    <Stagger index={index}>
      <Panel className="flex h-full flex-col p-5">
        <span className="font-mono text-[10px] uppercase tracking-[0.08em] text-green-bright">/{law.n}</span>
        <h3 className="mt-3 text-[17px] font-semibold uppercase leading-[1.05] tracking-[-0.03em] text-white sm:text-[19px]">
          {law.title}
        </h3>
        <p className="mt-2.5 text-[13px] leading-[1.55] text-white-60">{law.body}</p>
      </Panel>
    </Stagger>
  );
}

function Waterfall({ buffer, notional }: { buffer: number; notional: number }) {
  const junior = 4_820_000 * 0.42; // staked CERT notional backing the junior tranche
  const legs = [
    { label: "Funding buffer", sub: "First loss", value: buffer, tone: "bg-green-bright" },
    { label: "Staked CERT", sub: "Junior tranche", value: junior, tone: "bg-green-bright/45" },
    { label: "Holder backing", sub: "Senior · untouched", value: notional, tone: "bg-white/15" },
  ];
  const max = Math.max(...legs.map((l) => l.value));
  return (
    <Panel className="p-5 md:p-6">
      <div className="flex items-center justify-between gap-3">
        <MicroLabel>Loss Waterfall</MicroLabel>
        <span className="font-mono text-[10px] uppercase tracking-[0.08em] text-green-bright">Holders senior</span>
      </div>
      <div className="mt-5 flex flex-col gap-4">
        {legs.map((l, i) => (
          <div key={l.label}>
            <div className="flex items-baseline justify-between gap-3 font-mono text-[11px] uppercase tracking-[0.06em]">
              <span className="min-w-0 truncate text-white">
                <span className="text-white-60">{i + 1}.</span> {l.label}
              </span>
              <span className="shrink-0 tabular-nums text-silver">{fmtCompactUSD(l.value)}</span>
            </div>
            <div className="mt-2 h-[7px] w-full bg-white/8">
              <div className={cn("h-full transition-all duration-700", l.tone)} style={{ width: `${(l.value / max) * 100}%` }} />
            </div>
            <p className="mt-1.5 font-mono text-[10px] uppercase tracking-[0.08em] text-white-60/70">{l.sub}</p>
          </div>
        ))}
      </div>
      <p className="mt-6 border-t hairline-dark pt-4 font-mono text-[10px] uppercase leading-[1.7] tracking-[0.06em] text-white-60">
        Losses consume the buffer first, then the staked insurance tranche. Holder backing is only reachable after both
        are exhausted — and the invariant is published every block.
      </p>
    </Panel>
  );
}

/* ------------------------------------------------------------------ view */

export default function RiskView() {
  const { totals, vaults } = useDashboard();
  const live = vaults.filter((v) => v.status === "LIVE");
  const coverage = (totals.buffer / (totals.notional * 0.02)) * 100;

  return (
    <div>
      <ViewHeader
        className="gap-6 lg:grid lg:grid-cols-2"
        label="Risk & Parameters"
        title={
          <>
            Nothing <span className="text-metallic">Hidden.</span>
          </>
        }
        right={
          <p className="max-w-[46ch] self-end text-[16px] leading-[1.4] tracking-[-0.02em] text-silver sm:text-[18px] md:text-[20px]">
            Every parameter that governs the vaults, the buffer and the insurance tranche — published, live, and
            stress-tested.
          </p>
        }
      />

      {/* Headline risk posture */}
      <div className="mt-8 grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
        {[
          { label: "Buffer coverage", value: `${coverage.toFixed(0)}%`, note: "of 2.0% target", icon: Layers },
          { label: "Holding fee active", value: "No", note: "buffer above threshold", icon: Check },
          { label: "Vaults in band", value: `${live.length} / ${live.length}`, note: "delta within ±0.20%", icon: Radio },
          { label: "Junior tranche", value: fmtCompactUSD(4_820_000 * 0.42), note: "staked CERT at risk first", icon: Lock },
        ].map((s, i) => {
          const Icon = s.icon;
          return (
            <Stagger key={s.label} index={i}>
              <Panel className="flex h-full flex-col p-5">
                <div className="flex items-center justify-between gap-3">
                  <MicroLabel>{s.label}</MicroLabel>
                  <Icon size={14} className="shrink-0 text-green-bright" />
                </div>
                <p className="mt-3 font-mono text-[28px] leading-none tracking-[-0.04em] text-white sm:text-[32px]">{s.value}</p>
                <p className="mt-2 font-mono text-[10px] uppercase tracking-[0.08em] text-white-60">{s.note}</p>
              </Panel>
            </Stagger>
          );
        })}
      </div>

      {/* Design laws */}
      <div className="mt-10">
        <MicroLabel>Design Laws</MicroLabel>
        <div className="mt-4 grid gap-3 sm:grid-cols-2 xl:grid-cols-3">
          {DESIGN_LAWS.map((l, i) => (
            <LawCard key={l.n} law={l} index={i} />
          ))}
        </div>
      </div>

      {/* Parameters + waterfall */}
      <div className="mt-10 grid gap-3 lg:grid-cols-[1.35fr_1fr]">
        <Panel className="p-0">
          <div className="flex items-center justify-between gap-3 border-b hairline-dark px-5 py-4">
            <MicroLabel>Live Parameters</MicroLabel>
            <span className="flex items-center gap-2 font-mono text-[10px] uppercase tracking-[0.08em] text-white-60">
              <PulseDot /> On-chain
            </span>
          </div>
          {PARAMETERS.map((group) => (
            <div key={group.group}>
              <p className="bg-section-deep px-5 py-2 font-mono text-[10px] uppercase tracking-[0.1em] text-white-60">
                {group.group}
              </p>
              {group.rows.map((r) => (
                <div
                  key={r.k}
                  className="grid grid-cols-[minmax(0,1fr)_auto] items-baseline gap-3 border-b hairline-dark px-5 py-3 last:border-b-0 font-mono text-[12px]"
                >
                  <span className="min-w-0 text-[11px] uppercase tracking-[0.06em] text-white-60">{r.k}</span>
                  <span className="text-right">
                    <span className="tabular-nums text-white">{r.v}</span>
                    {r.note && <span className="block text-[10px] uppercase tracking-[0.06em] text-white-60/70">{r.note}</span>}
                  </span>
                </div>
              ))}
            </div>
          ))}
        </Panel>

        <Waterfall buffer={totals.buffer} notional={totals.notional} />
      </div>

      {/* Stress scenarios */}
      <Panel className="mt-3 overflow-x-auto">
        <div className="flex items-center justify-between gap-3 border-b hairline-dark px-5 py-4">
          <MicroLabel>Stress Scenarios</MicroLabel>
          <span className="font-mono text-[10px] uppercase tracking-[0.08em] text-white-60">Re-run each epoch</span>
        </div>
        <table className="w-full min-w-[720px] font-mono text-[12px]">
          <thead>
            <tr className="border-b hairline-dark text-left text-[10px] uppercase tracking-[0.08em] text-white-60">
              <th className="px-5 py-3 font-medium">Scenario</th>
              <th className="px-3 py-3 font-medium">Shock</th>
              <th className="px-3 py-3 font-medium">Buffer impact</th>
              <th className="px-3 py-3 font-medium">Holder impact</th>
            </tr>
          </thead>
          <tbody>
            {SCENARIOS.map((s) => (
              <tr key={s.name} className="border-b hairline-dark last:border-b-0">
                <td className="px-5 py-3.5 text-white">{s.name}</td>
                <td className="px-3 py-3.5 text-silver">{s.shock}</td>
                <td className="px-3 py-3.5 tabular-nums text-white">{s.draw}</td>
                <td className={cn("px-3 py-3.5", s.severity === "ok" ? "text-green-bright" : "text-warn")}>
                  <span className="flex items-start gap-2">
                    {s.severity === "ok" ? (
                      <Check size={13} className="mt-[2px] shrink-0" />
                    ) : (
                      <AlertTriangle size={13} className="mt-[2px] shrink-0" />
                    )}
                    {s.holder}
                  </span>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </Panel>

      {/* Attestations + boundaries */}
      <div className="mt-3 grid gap-3 lg:grid-cols-2">
        <Panel className="p-0">
          <div className="border-b hairline-dark px-5 py-4">
            <MicroLabel>Controls & Attestations</MicroLabel>
          </div>
          {ATTESTATIONS.map((a) => (
            <div
              key={a.label}
              className="grid grid-cols-[minmax(0,1fr)_auto] items-baseline gap-3 border-b hairline-dark px-5 py-3.5 last:border-b-0 font-mono text-[12px]"
            >
              <span className="min-w-0 text-[11px] uppercase tracking-[0.06em] text-white-60">{a.label}</span>
              <span className={cn("text-right text-[11px]", a.state === "ok" ? "text-green-bright" : "text-warn")}>{a.value}</span>
            </div>
          ))}
        </Panel>

        <Panel className="p-5 md:p-6">
          <div className="flex items-center justify-between gap-3">
            <MicroLabel>Honest Boundaries</MicroLabel>
            <FileText size={14} className="shrink-0 text-white-60" />
          </div>
          <ul className="mt-5 flex flex-col gap-4 text-[13px] leading-[1.55] text-white-60">
            <li>
              Certificates are <span className="text-white">synthetic</span>: price exposure backed by perp positions and
              USDC margin — not custody of shares, no dividends, no shareholder rights.
            </li>
            <li>
              Named risks: sustained negative funding (buffered, then fee'd), dependency on the underlying equity perp
              market and its operator, oracle and liquidation tail risk in extreme gaps.
            </li>
            <li>
              Not available where synthetic equity exposure is restricted. Interface geo-gating applies. UseCert is
              infrastructure, not investment advice.
            </li>
          </ul>
        </Panel>
      </div>
    </div>
  );
}
