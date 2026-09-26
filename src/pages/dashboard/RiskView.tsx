import { AlertTriangle, Check, FileText, Layers, Lock, Radio } from "lucide-react";
import { useFlows } from "@/chain/useFlows";
import { useDashboard } from "./store";
import { AgeLine, EmptyState, MicroLabel, Panel, PulseDot, Stagger, UnverifiedTag, ViewHeader } from "./ui";
import { EM_DASH, NO_POSITION, fmtCompactUSD, fmtOrDash } from "./format";
import { fromBps, fromPrice18 } from "@/chain/units";
import { BASIS_ON_THIS_DEPLOYMENT } from "@/chain/useVaults";
import { cn } from "@/lib/utils";
import { CHAIN_ID, COLLATERAL_SYMBOL, VENUE_IS_SIMULATED } from "@/chain/deployment";

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
    body: "Funding accrues to and from the buffer the vault holds, and the balance is readable on-chain. The fee-passthrough threshold this law was written around is NOT deployed — nothing takes over when the buffer is exhausted.",
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
/**
 * `governedBy` names the on-chain value that decides each row, so the table can print a
 * threshold a reader can go and check rather than one quoted from a document. `null` means
 * the row is governed by a mechanism with no single published number - saying so beats
 * inventing one to fill the column.
 */
type GovernedBy = "staleness" | "deviation" | "basis" | "attestationAge" | "bufferLedger" | "instantCap" | null;

const SCENARIOS: {
  name: string;
  shock: string;
  behaviour: string;
  severity: "ok" | "warn";
  governedBy: GovernedBy;
}[] = [
  {
    name: "Sustained negative funding",
    shock: "Funding runs against the vault's long for an extended period",
    behaviour:
      "Draws down the buffer the vault holds. No fee passthrough and no insurance tranche is deployed to take over once it is exhausted.",
    severity: "warn",
    governedBy: "bufferLedger",
  },
  {
    name: "Gap in the underlying",
    shock: "The underlying moves faster than a rebalance can follow",
    behaviour: "Delta drift widens against the attested perp position. Redemption is not gated on it.",
    severity: "ok",
    governedBy: "basis",
  },
  {
    name: "Redemption run",
    shock: "Redemptions exceed the instant float (hotBuffer)",
    behaviour:
      "The instant path declines with CertVault_UseQueuedRedeem and redemptions route through the queue. forceExit is gated on nothing.",
    severity: "ok",
    governedBy: "instantCap",
  },
  {
    name: "Oracle stale or deviant",
    shock: "px() reverts and mintAllowed() returns false",
    behaviour: "Minting is refused; redemption is unaffected. Both states are read live on this page.",
    severity: "warn",
    governedBy: "staleness",
  },
  {
    name: "Attestation goes stale",
    shock: "ageSec passes maxAttestationAgeSec",
    behaviour:
      "Capacity falls to zero and minting is off until a fresh attestation lands — the likeliest reason a healthy deployment refuses to mint.",
    severity: "warn",
    governedBy: "attestationAge",
  },
  {
    name: "Accrual ledger goes non-positive",
    shock: "BufferBook.balance18 reaches zero or below",
    behaviour:
      "BufferBook.capacity18 returns 0, which zeroes bufferCapacity18 and maxNotional18 with it, and EVERY mint is refused regardless of the collateral held — a vault sitting on $100,000 of collateral rejects a $100 mint. Redemption is untouched. This deployment publishes the ledger balance on the vault page so the halt is not silent.",
    severity: "warn",
    governedBy: "bufferLedger",
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
  const {
    totals,
    liveVaults,
    vaults,
    vaultConfig,
    maxAttestationAgeSec,
    signer,
    allAttestationsRefreshable,
  } = useDashboard();
  // Flow history is a third-party HTTP index, not a contract read — see `useFlows`.
  const history = useFlows();

  // The worst (lowest) accrual ledger across mirrors: at or below zero it zeroes the mint
  // ceiling on its own, so the sign is the threshold and the balance is the distance to it.
  const bufferLedgerWorst = (() => {
    const vals = liveVaults
      .map((v) => v.capacity.bufferLedger)
      .filter((x): x is number => x !== null && x !== undefined);
    return vals.length === 0 ? null : Math.min(...vals);
  })();

  // cfg().instantCap18 per vault. Identical across mirrors on this deployment, but checked.
  const instantCapLabel = (() => {
    const caps = liveVaults
      .map((v) => vaultConfig(v.id))
      .filter((c): c is NonNullable<typeof c> => !!c)
      .map((c) => fromPrice18(c.instantCap18));
    if (caps.length === 0) return EM_DASH;
    const uniq = Array.from(new Set(caps));
    return uniq.length === 1 ? fmtCompactUSD(uniq[0]) : "varies by mirror";
  })();

  /**
   * The live threshold that decides a row, or a dash.
   *
   * Every mirror on this deployment is configured identically, so one number is honest
   * here - but that is a FACT ABOUT THIS DEPLOYMENT, not a guarantee, so it is checked
   * rather than assumed. If the mirrors ever disagree the cell says so instead of picking
   * one and presenting it as the threshold.
   */
  const governingThreshold = (g: (typeof SCENARIOS)[number]["governedBy"]): string => {
    if (g === null || liveVaults.length === 0) return EM_DASH;

    const pick = (f: (v: (typeof liveVaults)[number]) => number | null): string => {
      const vals = liveVaults.map(f).filter((x): x is number => x !== null);
      if (vals.length === 0) return EM_DASH;
      const uniq = Array.from(new Set(vals));
      return uniq.length === 1 ? String(uniq[0]) : "varies by mirror";
    };

    switch (g) {
      case "staleness":
        return pick((v) => v.guards.stalenessSeconds) + "s";
      case "deviation":
        return pick((v) => v.guards.deviationBps) + " bps";
      case "basis":
        return pick((v) => v.guards.basisBandBps) + " bps";
      case "attestationAge":
        return maxAttestationAgeSec + "s";
      case "bufferLedger":
        // The threshold is a sign, not a magnitude: at or below zero the ledger zeroes the
        // mint ceiling on its own. Showing the live worst balance is more use than "0".
        return bufferLedgerWorst === null ? "<= 0" : "<= 0 (now " + fmtCompactUSD(bufferLedgerWorst) + ")";
      case "instantCap":
        return instantCapLabel;
      default:
        return EM_DASH;
    }
  };

  const bufferHeld = totals ? totals.buffer : null;

  /**
   * The protocol-wide bounded capacity figure.
   *
   * This card used to be `sum(bufferHeld) / sum(bufferCapacity18)`, which is the same
   * information-free constant the per-vault bar carried: `bufferCapacity18()` is
   * `freeCollateral18() × 100` capped by the ledger's claim (`CertVault.sol:563-569`), so the
   * quotient sits within rounding of 1% at every fill level and reaches 100% at none. It is
   * now `used / cap` against `CapacityOracle.maxNotional18` — the bound `_requireCapacity`
   * enforces (`CertVault.sol:1755-1771`) — summed across mirrors, and `null` rather than a
   * clamped number when the cap is zero or a mirror's cap has not been read.
   */
  const capacityUtilisation = totals ? totals.capacityUtilisationPct : null;

  /**
   * The worst hedge shortfall across mirrors, in points below target.
   *
   * `deltaBps` is a hedge-to-obligation RATIO where 10_000 is at target
   * (`CertVault.sol:1600`), so the old `max(deltaBps)` maximised the HEALTHIEST reading and
   * labelled it the worst drift. The shortfall is `100 − hedgeRatioPct`, and the two sentinel
   * states are excluded from the max because they are not measurements — the unbounded one is
   * surfaced separately below, since a live position against a zero obligation outranks any
   * finite shortfall.
   */
  const worstShortfallPts = (() => {
    const measured = liveVaults
      .map((v) => v.deltaView)
      .filter((d): d is { kind: "measured"; hedgeRatioPct: number; driftPct: number } =>
        d.kind === "measured",
      );
    if (measured.length === 0) return null;
    return Math.max(...measured.map((d) => 100 - d.hedgeRatioPct));
  })();
  const anyUnbounded = liveVaults.some((v) => v.deltaView.kind === "unbounded");
  const anyNoObligation = liveVaults.some((v) => v.deltaView.kind === "no-obligation");

  const posture: { label: string; value: string; note: string; icon: typeof Layers; muted?: boolean }[] = [
    {
      label: "Mint ceiling used",
      value:
        totals === null
          ? EM_DASH
          : // A ceiling of zero that a mint would refresh is idle, not halted. Same
            // distinction as the overview table and the mint panel.
            totals.anyCapacityHalted && allAttestationsRefreshable === true
            ? "idle"
            : totals.anyCapacityHalted
              ? "halted"
              : fmtOrDash(capacityUtilisation, (n) => `${n.toFixed(2)}%`),
      note:
        !totals?.anyCapacityHalted
          ? "used / capacityOracle.maxNotional18"
          : allAttestationsRefreshable === true
            ? "maxNotional18 is 0 while the attestation is aged out — a mint refreshes it"
            : "a routed vault's maxNotional18 is 0 — it refuses every mint",
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
      label: "Worst hedge shortfall",
      value: anyUnbounded
        ? "unbounded"
        : worstShortfallPts === null
          ? anyNoObligation
            ? NO_POSITION
            : EM_DASH
          : `${worstShortfallPts.toFixed(2)} pts`,
      note: anyUnbounded
        ? "a live attested position against a zero obligation"
        : worstShortfallPts === null
          ? "no routed vault publishes a measurable hedge ratio"
          : "points below deltaBps 10_000 — at target is 0",
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

  /* Parameters: read where a read exists, blank where none does. `marketIndexVerified` is
     the one field here that is NOT a read — it is hand-maintained against the address book
     (see `MARKET_INDEX_VERIFIED`) — so it travels with the index rather than as a row of
     its own, and the row says which of the two it is. */
  const cfgRows = liveVaults.map((v) => ({
    id: v.id,
    name: v.name,
    cfg: vaultConfig(v.id),
    marketIndexVerified: v.marketIndexVerified,
  }));

  const verifiedIndexCount = liveVaults.filter((v) => v.marketIndexVerified).length;
  const unverifiedIndexNames = liveVaults.filter((v) => !v.marketIndexVerified).map((v) => v.name);

  const attestations: { label: string; value: string; state: "ok" | "warn" | "unknown" }[] = [
    {
      label: "Solvency attestation age",
      value: totals ? `${Math.round(totals.worstAgeSec)}s · max ${maxAttestationAgeSec}s` : EM_DASH,
      // Past the max is the normal idle state now, so age alone is not a warning. The
      // warning that replaces it is the attester row below: that is what actually breaks.
      state: totals === null ? "unknown" : "ok",
    },
    {
      label: "Attester serving signatures",
      value:
        signer.available === null
          ? EM_DASH
          : signer.available
            ? `yes · batch ${signer.batchAgeSec === null ? "age unknown" : `${signer.batchAgeSec}s old`}`
            : "no · nothing can refresh the attestation",
      state: signer.available === null ? "unknown" : signer.available ? "ok" : "warn",
    },
    {
      label: "Oracle price available",
      value: totals === null ? EM_DASH : totals.anyPriceUnavailable ? "one or more reverted" : "all routed vaults",
      state: totals === null ? "unknown" : totals.anyPriceUnavailable ? "warn" : "ok",
    },
    {
      label: "Minting allowed (oracle)",
      value: liveVaults.length
        ? `${liveVaults.filter((v) => v.mintAllowed).length} / ${liveVaults.length} routed vaults`
        : EM_DASH,
      state: liveVaults.length && liveVaults.every((v) => v.mintAllowed) ? "ok" : "warn",
    },
    /* `mintAllowed()` is only the ORACLE's half. A zero mint ceiling stops minting without
       touching it, so it needs its own row — that is exactly why the halt is silent. */
    {
      label: "Mint capacity non-zero",
      value: liveVaults.length
        ? `${liveVaults.filter((v) => !v.capacity.capIsZero).length} / ${liveVaults.length} routed vaults`
        : EM_DASH,
      state: liveVaults.length && liveVaults.every((v) => !v.capacity.capIsZero) ? "ok" : "warn",
    },
    {
      label: "Accrual ledger positive",
      value: liveVaults.length
        ? liveVaults
            .map(
              (v) =>
                `${v.name} ${
                  v.capacity.bufferLedger === null
                    ? EM_DASH
                    : fmtCompactUSD(v.capacity.bufferLedger)
                }`,
            )
            .join(" · ")
        : EM_DASH,
      state:
        liveVaults.length &&
        liveVaults.every(
          (v) => v.capacity.bufferLedger18 !== null && v.capacity.bufferLedger18 > 0n,
        )
          ? "ok"
          : "warn",
    },
    /* This row used to read "2 / 2 report a basis · ok", which took the oracle's
     * `singleSource: false` configuration flag as a finding. Every mirror here reports a
     * basis and every one of them reports 0 bps, because the feed is a ReplayAggregator
     * this project writes and the same keeper sets the simulator's mark in the same
     * transaction. It can never be `ok`, whatever the reading. */
    {
      label: "Basis independence",
      value: liveVaults.length
        ? `${liveVaults.filter((v) => v.basisKnown).length} / ${liveVaults.length} report a basis — asserted, not measured`
        : EM_DASH,
      state: "warn",
    },
    /* Hand-maintained against `deployments/46630.json`, not a chain read: the generated
     * bundle drops the field. Named vaults rather than a bare count, because the fix is
     * per mirror — re-read `market_id` and redeploy that one. */
    {
      label: "Venue market index read back from the venue",
      value: liveVaults.length
        ? `${verifiedIndexCount} / ${liveVaults.length}${
            unverifiedIndexNames.length > 0 ? ` — chosen on ${unverifiedIndexNames.join(", ")}` : ""
          }`
        : EM_DASH,
      state: liveVaults.length === 0 ? "unknown" : verifiedIndexCount === liveVaults.length ? "ok" : "warn",
    },
    {
      label: `Vaults routed on chain ${CHAIN_ID}`,
      value: `${liveVaults.length} / ${vaults.length}`,
      /* Derived, not a fixed `warn`: the row was pinned amber while two of five were
         routed and would have stayed amber with every vault live. */
      state: liveVaults.length === 0 ? "unknown" : liveVaults.length === vaults.length ? "ok" : "warn",
    },
    {
      /* Receipt ids are STILL not enumerable on-chain and there is STILL no
       * `receiptsOf(user)` — a flow list can only come from logs. What changed is that the
       * chain's own Blockscout instance indexes and decodes them and answers the browser
       * directly, so the history exists. It stays `warn` because it is a third-party HTTP
       * index, not a guarded chain read, and the row says which. */
      label: "Receipt & flow history",
      value: history.indexUnavailable
        ? "explorer index unavailable — history cannot be read right now"
        : "read from the chain's public explorer index (third party, not a chain read)",
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
            <EmptyState className="border-0" title={`Reading chain ${CHAIN_ID}…`} />
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
                      [
                        "Venue market index",
                        String(row.cfg.marketIndex),
                        row.marketIndexVerified
                          ? "read back from the venue's market list"
                          : "CHOSEN, not read back from the venue",
                      ],
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
                ["Collateral", `${COLLATERAL_SYMBOL} · 6 decimals`, "read once into an immutable at construction"],
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
            {/* The one MECHANICAL consequence this claim still has, and the reason it is not
                merely cosmetic: BufferBook.capacity18 returns 0 whenever balance18 <= 0
                (BufferBook.sol:183-187), which zeroes bufferCapacity18 and maxNotional18. */}
            <p className="mt-2 font-mono text-[10px] uppercase leading-[1.7] tracking-[0.06em] text-warn/70">
              It is also BufferBook.balance18 (solvency publishes the ledger as accrual18,
              CertVault.sol:1570), and at or below zero that halts minting on its own — every mint
              refused, whatever collateral is held. Redemption is untouched.
            </p>
          </div>
        </div>
      </Panel>

      {/* Stress scenarios */}
      <Panel className="mt-3 overflow-x-auto">
        <div className="flex items-center justify-between gap-3 border-b hairline-dark px-5 py-4">
          <MicroLabel>Failure Modes</MicroLabel>
          <span className="font-mono text-[10px] uppercase tracking-[0.08em] text-white-60">
            Designed behaviour · thresholds read from chain
          </span>
        </div>
        <table className="w-full min-w-[720px] font-mono text-[12px]">
          <thead>
            <tr className="border-b hairline-dark text-left text-[10px] uppercase tracking-[0.08em] text-white-60">
              <th className="px-5 py-3 font-medium">Scenario</th>
              <th className="px-3 py-3 font-medium">Shock</th>
              <th className="px-3 py-3 font-medium">What the contracts do</th>
              <th className="px-3 py-3 text-right font-medium">Threshold (live)</th>
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
                <td className="whitespace-nowrap px-3 py-3.5 text-right text-white-60">
                  {governingThreshold(s.governedBy)}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
        <p className="border-t hairline-dark px-5 py-3 font-mono text-[10px] uppercase leading-[1.7] tracking-[0.06em] text-white-60/70">
          No stress model has been run against this deployment, so no buffer-draw or loss figure is
          published here. The rows describe mechanisms, not outcomes. The thresholds are read from
          the contracts that enforce them — the oracle for staleness, deviation and basis, the
          registry for attestation age, the vault's cfg() for the instant cap — so a reader can
          check each one against the chain rather than against this page.
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
              cannot. {BASIS_ON_THIS_DEPLOYMENT}
            </li>
            <li>
              <span className="text-white">Venue market index</span>: the market a vault hedges on is a
              constructor immutable, and {unverifiedIndexNames.length} of the {liveVaults.length}{" "}
              indices here were chosen rather than read back from the venue's own market list
              {unverifiedIndexNames.length > 0 ? ` (${unverifiedIndexNames.join(", ")})` : ""}.{" "}
              {VENUE_IS_SIMULATED
                ? "The testnet simulator creates any index on first use, so nothing misbehaves; against a real venue an unverified index would hedge the wrong market, and the mirror would have to be redeployed rather than reconfigured."
                : "Every index on this deployment was read from the venue's market list before deploying, by a preflight that refuses unlisted markets; a wrong one would hedge the wrong market and need a redeploy."}
            </li>
            <li>
              <span className="text-white">Single-venue dependency</span>: all exposure sits on one perp venue and its
              operator.{" "}
              {VENUE_IS_SIMULATED
                ? "On this testnet that venue is a simulator, not a live exchange."
                : "Here that is Robinhood Chain Lighter. Hedges are opened by a keeper holding the vault's API key and closed by the vault on chain."}
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
