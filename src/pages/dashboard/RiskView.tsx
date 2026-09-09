import { AlertTriangle, Check, FileText, Layers, Lock, Radio } from "lucide-react";
import { useDashboard } from "./store";
import { AgeLine, EmptyState, MicroLabel, Panel, PulseDot, Stagger, UnverifiedTag, ViewHeader } from "./ui";
import { EM_DASH, fmtCompactUSD, fmtOrDash } from "./format";
import { fromBps, fromPrice18 } from "@/chain/units";
import { cn } from "@/lib/utils";

/* --------------------------------------------------------------- content */

const DESIGN_LAWS: { n: string; title: string; body: string }[] = [
  {
    n: "01",
    title: "Fully delta-backed",
    body: "Each vault targets delta 1.0: certificate supply × oracle price ≤ perp notional + collateral margin. Proven on-chain per attestation, with the age of that attestation published next to every figure — not proven every block.",
  },
  {
    n: "02",
    title: "Redemption is never gated",
    body: "Burn → close matching exposure → collateral at oracle price. A thin buffer routes redemption through the queue and stops minting; it never stops redemption, and forceExit is gated on nothing.",
  },
  {
    n: "03",
    title: "Funding buffered, never hidden",
    body: "Funding accrues to and from the buffer the vault holds, and the balance is readable on-chain. The fee-passthrough threshold this law was written around is NOT deployed on chain 46630 — nothing takes over when the buffer is exhausted.",
  },
  {
    n: "04",
    title: "Holders are senior",
    body: "By design the junior tranche absorbs buffer exhaustion before holder backing. That tranche does not exist here: InsuranceStaking and CERT are C3 and are not deployed, so there is nothing junior to holders on this deployment.",
  },
  {
    n: "05",
    title: "Mirror the market honestly",
    body: "Certificates are synthetic price exposure - no custody of shares, no dividends, no shareholder rights. Corporate actions follow the underlying market spec.",
  },
];

/**
 * Failure modes and the behaviour the deployed contracts are designed to produce.
 *
 * There are deliberately NO magnitudes in this table. The buffer-draw figures that used to
 * sit here — "−41% of buffer", "−12%", "−9%", against shocks of "−30% annualised funding"
 * and "45% of supply redeemed in 24h" — were invented: no model was run against this
 * deployment and nothing on-chain publishes a stress result. Every row below names a
 * mechanism that exists on chain 46630 instead of quantifying an outcome that does not.
 */
const SCENARIOS: { name: string; shock: string; behaviour: string; severity: "ok" | "warn" }[] = [
  {
    name: "Sustained negative funding",
    shock: "Funding runs against the vault's long for an extended period",
    behaviour:
      "Draws down the buffer the vault holds. No fee passthrough and no insurance tranche is deployed to take over once it is exhausted.",
    severity: "warn",
  },
  {
    name: "Gap in the underlying",
    shock: "The underlying moves faster than a rebalance can follow",
    behaviour: "Delta drift widens against the attested perp position. Redemption is not gated on it.",
    severity: "ok",
  },
  {
    name: "Redemption run",
    shock: "Redemptions exceed the instant float (hotBuffer)",
    behaviour:
      "The instant path declines with CertVault_UseQueuedRedeem and redemptions route through the queue. forceExit is gated on nothing.",
    severity: "ok",
  },
  {
    name: "Oracle stale or deviant",
    shock: "px() reverts and mintAllowed() returns false",
    behaviour: "Minting is refused; redemption is unaffected. Both states are read live on this page.",
    severity: "warn",
  },
  {
    name: "Attestation goes stale",
    shock: "ageSec passes maxAttestationAgeSec",
    behaviour:
      "Capacity falls to zero and minting is off until a fresh attestation lands — the likeliest reason a healthy deployment refuses to mint.",
    severity: "warn",
  },
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

/**
 * The loss waterfall, with the legs that exist and the leg that does not.
 *
 * `InsuranceStaking` and `CERT` are C3 and are not deployed, so the junior tranche has no
 * size on chain 46630. It is shown as a named-but-unsized leg rather than the previous
 * `4_820_000 × 0.42`, which was a figure with no source at all.
 */
function Waterfall({
  bufferHeld,
  holderBacking,
}: {
  bufferHeld: number | null;
  holderBacking: number | null;
}) {
  const legs: { label: string; sub: string; value: number | null; tone: string }[] = [
    { label: "Funding buffer", sub: "First loss · ERC-20 balance held", value: bufferHeld, tone: "bg-green-bright" },
    {
      label: "Staked CERT",
      sub: "Junior tranche · not deployed (C3)",
      value: null,
      tone: "bg-green-bright/45",
    },
    {
      label: "Holder backing",
      sub: "Senior · attested margin + buffer held",
      value: holderBacking,
      tone: "bg-white/15",
    },
  ];
  const max = legs.reduce((s, l) => Math.max(s, l.value ?? 0), 0);
  return (
    <Panel className="p-5 md:p-6">
      <div className="flex items-center justify-between gap-3">
        <MicroLabel>Loss Waterfall</MicroLabel>
        <span className="font-mono text-[10px] uppercase tracking-[0.08em] text-green-bright">Holders senior</span>
      </div>
      <div className="mt-5 flex flex-col gap-4">
        {legs.map((l, i) => (
          <div key={l.label} className={cn(l.value === null && "opacity-50")}>
            <div className="flex items-baseline justify-between gap-3 font-mono text-[11px] uppercase tracking-[0.06em]">
              <span className="min-w-0 truncate text-white">
                <span className="text-white-60">{i + 1}.</span> {l.label}
              </span>
              <span className="shrink-0 tabular-nums text-silver">
                {fmtOrDash(l.value, (n) => fmtCompactUSD(n))}
              </span>
            </div>
            <div className="mt-2 h-[7px] w-full bg-white/8">
              {l.value !== null && max > 0 && (
                <div
                  className={cn("h-full transition-all duration-700", l.tone)}
                  style={{ width: `${(l.value / max) * 100}%` }}
                />
              )}
            </div>
            <p className="mt-1.5 font-mono text-[10px] uppercase tracking-[0.08em] text-white-60/70">{l.sub}</p>
          </div>
        ))}
      </div>
      <p className="mt-6 border-t hairline-dark pt-4 font-mono text-[10px] uppercase leading-[1.7] tracking-[0.06em] text-white-60">
        Losses consume the buffer first. The insurance tranche it would consume next does not exist on
        this deployment, so no size is shown for it.
      </p>
    </Panel>
  );
}

/* ------------------------------------------------------------------ view */

export default function RiskView() {
  const { totals, liveVaults, vaults, vaultConfig, maxAttestationAgeSec, flowsUnavailable } =
    useDashboard();

  // Buffer coverage against the vaults' own capacity figure, both read on-chain. The old
  // "2.0% of notional" target has no on-chain analogue on this deployment.
  const bufferHeld = totals ? totals.buffer : null;
  const capacity = liveVaults.length
    ? liveVaults.reduce((s, v) => s + (v.bufferCapacity ?? 0), 0)
    : null;
  const coverage = bufferHeld !== null && capacity !== null && capacity > 0 ? (bufferHeld / capacity) * 100 : null;
  const worstDriftBps = liveVaults.length
    ? liveVaults.reduce((s, v) => Math.max(s, v.deltaBps ?? 0), 0)
    : null;

  const posture: { label: string; value: string; note: string; icon: typeof Layers; muted?: boolean }[] = [
    {
      label: "Buffer vs capacity",
      value: fmtOrDash(coverage, (n) => `${n.toFixed(0)}%`),
      note: "buffer held / bufferCapacity18",
      icon: Layers,
    },
    {
      label: "Holding fee",
      value: EM_DASH,
      note: "no fee-passthrough mechanism is deployed",
      icon: Check,
      muted: true,
    },
    {
      label: "Worst delta drift",
      value: fmtOrDash(worstDriftBps, (n) => `${n.toFixed(2)}%`),
      note: "magnitude only — deltaBps is unsigned on-chain",
      icon: Radio,
    },
    {
      label: "Junior tranche",
      value: EM_DASH,
      note: "InsuranceStaking / CERT are C3 and not deployed",
      icon: Lock,
      muted: true,
    },
  ];

  /* Parameters: read where a read exists, blank where none does. */
  const cfgRows = liveVaults.map((v) => ({ id: v.id, name: v.name, cfg: vaultConfig(v.id) }));

  const attestations: { label: string; value: string; state: "ok" | "warn" | "unknown" }[] = [
    {
      label: "Solvency attestation age",
      value: totals ? `${Math.round(totals.worstAgeSec)}s · max ${maxAttestationAgeSec}s` : EM_DASH,
      state: totals === null ? "unknown" : totals.anyStale ? "warn" : "ok",
    },
    {
      label: "Oracle price available",
      value: totals === null ? EM_DASH : totals.anyPriceUnavailable ? "one or more reverted" : "all routed vaults",
      state: totals === null ? "unknown" : totals.anyPriceUnavailable ? "warn" : "ok",
    },
    {
      label: "Minting allowed",
      value: liveVaults.length
        ? `${liveVaults.filter((v) => v.mintAllowed).length} / ${liveVaults.length} routed vaults`
        : EM_DASH,
      state: liveVaults.length && liveVaults.every((v) => v.mintAllowed) ? "ok" : "warn",
    },
    {
      label: "Independent basis",
      value: liveVaults.length
        ? `${liveVaults.filter((v) => v.basisKnown).length} / ${liveVaults.length} report a basis`
        : EM_DASH,
      state: liveVaults.length && liveVaults.every((v) => v.basisKnown) ? "ok" : "warn",
    },
    {
      label: "Vaults routed on chain 46630",
      value: `${liveVaults.length} / ${vaults.length}`,
      state: "warn",
    },
    {
      label: "Event indexer",
      value: flowsUnavailable ? "none — no receipt or flow history" : "connected",
      state: "warn",
    },
  ];

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
            Every parameter the deployed contracts publish, read live. Where a parameter has no on-chain
            source it is left blank rather than filled in.
          </p>
        }
      />

      {/* Headline risk posture */}
      <div className="mt-8 grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
        {posture.map((s, i) => {
          const Icon = s.icon;
          return (
            <Stagger key={s.label} index={i}>
              <Panel className={cn("flex h-full flex-col p-5", s.muted && "opacity-70")}>
                <div className="flex items-center justify-between gap-3">
                  <MicroLabel>{s.label}</MicroLabel>
                  <Icon size={14} className={cn("shrink-0", s.muted ? "text-white-60" : "text-green-bright")} />
                </div>
                <p className="mt-3 font-mono text-[28px] leading-none tracking-[-0.04em] text-white sm:text-[32px]">
                  {s.value}
                </p>
                <p className="mt-2 font-mono text-[10px] uppercase tracking-[0.08em] text-white-60">{s.note}</p>
              </Panel>
            </Stagger>
          );
        })}
      </div>

      <div className="mt-3">
        <AgeLine
          ageSec={totals?.worstAgeSec ?? null}
          stale={Boolean(totals?.anyStale)}
          maxAgeSec={maxAttestationAgeSec}
        />
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
            <MicroLabel>Live Parameters · vault.cfg()</MicroLabel>
            <span className="flex items-center gap-2 font-mono text-[10px] uppercase tracking-[0.08em] text-white-60">
              <PulseDot /> On-chain
            </span>
          </div>

          {cfgRows.length === 0 ? (
            <EmptyState className="border-0" title="Reading chain 46630…" />
          ) : (
            cfgRows.map((row) => (
              <div key={row.id}>
                <p className="bg-section-deep px-5 py-2 font-mono text-[10px] uppercase tracking-[0.1em] text-white-60">
                  {row.name}
                </p>
                {!row.cfg ? (
                  <p className="px-5 py-3 font-mono text-[11px] uppercase tracking-[0.06em] text-white-60">
                    cfg() not loaded
                  </p>
                ) : (
                  (
                    [
                      ["Mint fee", `${fromBps(row.cfg.mintFeeBps).toFixed(2)}%`, `${row.cfg.mintFeeBps} bps`],
                      ["Redeem fee", `${fromBps(row.cfg.redeemFeeBps).toFixed(2)}%`, `${row.cfg.redeemFeeBps} bps`],
                      [
                        "Instant cap",
                        fmtCompactUSD(fromPrice18(row.cfg.instantCap18)),
                        "the mint / redeem size fork",
                      ],
                      ["Settle band", `${fromBps(row.cfg.settleBandBps).toFixed(2)}%`, "fill vs request price"],
                      ["Target margin", `${fromBps(row.cfg.targetMarginBps).toFixed(2)}%`, "rebalance target"],
                      ["Venue market index", String(row.cfg.marketIndex), "simulated venue on testnet"],
                    ] as [string, string, string][]
                  ).map(([k, v, note]) => (
                    <div
                      key={k}
                      className="grid grid-cols-[minmax(0,1fr)_auto] items-baseline gap-3 border-b hairline-dark px-5 py-3 last:border-b-0 font-mono text-[12px]"
                    >
                      <span className="min-w-0 text-[11px] uppercase tracking-[0.06em] text-white-60">{k}</span>
                      <span className="text-right">
                        <span className="tabular-nums text-white">{v}</span>
                        <span className="block text-[10px] uppercase tracking-[0.06em] text-white-60/70">
                          {note}
                        </span>
                      </span>
                    </div>
                  ))
                )}
              </div>
            ))
          )}

          <div>
            <p className="bg-section-deep px-5 py-2 font-mono text-[10px] uppercase tracking-[0.1em] text-white-60">
              Deployment constants
            </p>
            {(
              [
                [
                  "Max attestation age",
                  `${maxAttestationAgeSec}s`,
                  "past this, capacity is 0 and minting is off",
                ],
                ["Redemption cap", "none", "forceExit reads no health signal at all"],
                ["Collateral", "tUSDG · 6 decimals", "read once into an immutable at construction"],
                ["Certificate", "18 decimals", "6 dp in, 18 dp out on mint"],
              ] as [string, string, string][]
            ).map(([k, v, note]) => (
              <div
                key={k}
                className="grid grid-cols-[minmax(0,1fr)_auto] items-baseline gap-3 border-b hairline-dark px-5 py-3 last:border-b-0 font-mono text-[12px]"
              >
                <span className="min-w-0 text-[11px] uppercase tracking-[0.06em] text-white-60">{k}</span>
                <span className="text-right">
                  <span className="tabular-nums text-white">{v}</span>
                  <span className="block text-[10px] uppercase tracking-[0.06em] text-white-60/70">{note}</span>
                </span>
              </div>
            ))}
          </div>

          <div>
            <p className="bg-section-deep px-5 py-2 font-mono text-[10px] uppercase tracking-[0.1em] text-white-60">
              No on-chain source on this deployment
            </p>
            {["Buffer target as % of notional", "Fee passthrough threshold", "Max holding fee", "Junior tranche size", "Keeper bounty"].map(
              (k) => (
                <div
                  key={k}
                  className="grid grid-cols-[minmax(0,1fr)_auto] items-baseline gap-3 border-b hairline-dark px-5 py-3 last:border-b-0 font-mono text-[12px] opacity-60"
                >
                  <span className="min-w-0 text-[11px] uppercase tracking-[0.06em] text-white-60">{k}</span>
                  <span className="text-right tabular-nums text-white-60">{EM_DASH}</span>
                </div>
              ),
            )}
          </div>
        </Panel>

        <Waterfall
          bufferHeld={bufferHeld}
          holderBacking={totals ? totals.margin + totals.buffer : null}
        />
      </div>

      {/* The accrual claim, in its own register, next to the real balances */}
      <Panel className="mt-3 p-5 md:p-6">
        <div className="flex flex-wrap items-center justify-between gap-3">
          <MicroLabel>Accrual claimed vs buffer held</MicroLabel>
          <UnverifiedTag />
        </div>
        <div className="mt-4 grid gap-3 sm:grid-cols-2">
          <div className="border hairline-dark bg-[#0d0f0d] p-4">
            <MicroLabel className="text-[10px]">Buffer held · ERC-20 balance</MicroLabel>
            <p className="mt-2 font-mono text-[22px] tabular-nums leading-none text-green-bright">
              {fmtOrDash(bufferHeld, (n) => fmtCompactUSD(n))}
            </p>
            <p className="mt-2 font-mono text-[10px] uppercase tracking-[0.06em] text-white-60/70">
              Measured. This is collateral the vaults hold.
            </p>
          </div>
          <div className="border border-warn/25 bg-[#12120d] p-4">
            <MicroLabel className="text-[10px] text-warn/80">Accrual claimed · attester-relayed</MicroLabel>
            <p className="mt-2 font-mono text-[22px] tabular-nums leading-none text-silver">
              {fmtOrDash(totals ? totals.accrualClaimedUnverified : null, (n) => fmtCompactUSD(n))}
            </p>
            <p className="mt-2 font-mono text-[10px] uppercase tracking-[0.06em] text-white-60/70">
              Unverified. Nothing on-chain checks it, it goes negative, and it is never added to the
              figure on the left. These were one field once and it was the ledger.
            </p>
          </div>
        </div>
      </Panel>

      {/* Stress scenarios */}
      <Panel className="mt-3 overflow-x-auto">
        <div className="flex items-center justify-between gap-3 border-b hairline-dark px-5 py-4">
          <MicroLabel>Failure Modes</MicroLabel>
          <span className="font-mono text-[10px] uppercase tracking-[0.08em] text-white-60">
            Designed behaviour · no magnitudes published
          </span>
        </div>
        <table className="w-full min-w-[720px] font-mono text-[12px]">
          <thead>
            <tr className="border-b hairline-dark text-left text-[10px] uppercase tracking-[0.08em] text-white-60">
              <th className="px-5 py-3 font-medium">Scenario</th>
              <th className="px-3 py-3 font-medium">Shock</th>
              <th className="px-3 py-3 font-medium">What the contracts do</th>
            </tr>
          </thead>
          <tbody>
            {SCENARIOS.map((s) => (
              <tr key={s.name} className="border-b hairline-dark last:border-b-0">
                <td className="px-5 py-3.5 text-white">{s.name}</td>
                <td className="px-3 py-3.5 text-silver">{s.shock}</td>
                <td className={cn("px-3 py-3.5", s.severity === "ok" ? "text-green-bright" : "text-warn")}>
                  <span className="flex items-start gap-2">
                    {s.severity === "ok" ? (
                      <Check size={13} className="mt-[2px] shrink-0" />
                    ) : (
                      <AlertTriangle size={13} className="mt-[2px] shrink-0" />
                    )}
                    {s.behaviour}
                  </span>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
        <p className="border-t hairline-dark px-5 py-3 font-mono text-[10px] uppercase leading-[1.7] tracking-[0.06em] text-white-60/70">
          No stress model has been run against this deployment, so no buffer-draw or loss figure is
          published here. The rows describe mechanisms, not outcomes.
        </p>
      </Panel>

      {/* Attestations + boundaries */}
      <div className="mt-3 grid gap-3 lg:grid-cols-2">
        <Panel className="p-0">
          <div className="border-b hairline-dark px-5 py-4">
            <MicroLabel>Controls & Attestations</MicroLabel>
          </div>
          {attestations.map((a) => (
            <div
              key={a.label}
              className="grid grid-cols-[minmax(0,1fr)_auto] items-baseline gap-3 border-b hairline-dark px-5 py-3.5 last:border-b-0 font-mono text-[12px]"
            >
              <span className="min-w-0 text-[11px] uppercase tracking-[0.06em] text-white-60">{a.label}</span>
              <span
                className={cn(
                  "text-right text-[11px]",
                  a.state === "ok" ? "text-green-bright" : a.state === "warn" ? "text-warn" : "text-white-60",
                )}
              >
                {a.value}
              </span>
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
              Certificates are <span className="text-white">synthetic</span>: price exposure backed by a perp position
              and collateral margin - not custody of shares, no dividends, no shareholder rights.
            </li>
            <li>
              Solvency is <span className="text-white">not instantaneous</span>: margin and notional come from an
              attestation, so every figure here is as old as the age printed beside it and goes stale at{" "}
              {maxAttestationAgeSec}s.
            </li>
            <li>
              <span className="text-white">Basis risk</span>: the oracle price and the venue's mark are different
              numbers. basisBpsChecked() reports the gap when it can compute one, and reports that it cannot when it
              cannot.
            </li>
            <li>
              <span className="text-white">Single-venue dependency</span>: all exposure sits on one perp venue and its
              operator. On this testnet that venue is a simulator, not a live exchange.
            </li>
            <li>
              Named risks: sustained negative funding drawing the buffer down with no fee passthrough or insurance
              tranche deployed to take over, oracle failure, and liquidation tail risk in extreme gaps.
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
