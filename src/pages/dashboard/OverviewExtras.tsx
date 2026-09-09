import { useMemo } from "react";
import { useDashboard } from "./store";
import { AgeLine, EmptyState, Flash, MicroLabel, Panel, PulseDot, UnverifiedTag } from "./ui";
import { EM_DASH, fmtCompactUSD, fmtNum, fmtOrDash, fmtUSD } from "./format";
import { fromBps, fromPrice18 } from "@/chain/units";
import { cn } from "@/lib/utils";

/* --------------------------------------------------------- live ticker */

/**
 * Ticker strip: the routed vaults, their oracle price, and how old the attestation behind
 * them is. No 24h change and no funding rate — neither has an on-chain source, and a
 * scrolling "▲ 1.4%" that nothing produced is the most casually dishonest thing a ticker
 * can do.
 */
export function TickerStrip() {
  const { liveVaults, maxAttestationAgeSec } = useDashboard();
  const items = [...liveVaults, ...liveVaults]; // duplicate for seamless loop

  if (liveVaults.length === 0) {
    return (
      <div className="mt-4 border hairline-dark bg-section-deep-2 px-6 py-2.5 font-mono text-[11px] uppercase tracking-[0.08em] text-white-60">
        Reading chain 46630…
      </div>
    );
  }

  return (
    <div className="group relative mt-4 overflow-hidden border hairline-dark bg-section-deep-2">
      <div className="flex w-max animate-[ticker_28s_linear_infinite] group-hover:[animation-play-state:paused]">
        {items.map((v, i) => (
          <span
            key={`${v.id}-${i}`}
            className="flex items-center gap-3 border-r hairline-dark px-6 py-2.5 font-mono text-[11px] uppercase tracking-[0.08em]"
          >
            <span className="font-semibold text-white">{v.name}</span>
            {v.priceUnavailable || v.price === null ? (
              <span className="text-warn">price unavailable · minting paused</span>
            ) : (
              <span className="tabular-nums text-white">
                <Flash value={v.price} format={(n) => fmtUSD(n)} />
              </span>
            )}
            <AgeLine ageSec={v.ageSec} stale={v.attestationStale} maxAgeSec={maxAttestationAgeSec} />
          </span>
        ))}
      </div>
    </div>
  );
}

/* -------------------------------------------------- backing composition */

/**
 * What actually backs the certificates: attested margin at the venue plus the collateral
 * the vault holds itself.
 *
 * The attester's accrual claim is shown BELOW the total, in its own register, and is not
 * part of any sum here. Those two were one field once and it was the ledger.
 */
export function BackingComposition() {
  const { liveVaults, totals, maxAttestationAgeSec } = useDashboard();

  const rows = useMemo(() => {
    const rs = liveVaults.map((v) => ({
      id: v.id,
      label: v.name,
      margin: v.backing.margin,
      buffer: v.backing.bufferHeld,
      accrual: v.backing.accrualClaimedUnverified,
      total: v.backing.margin + v.backing.bufferHeld,
      ageSec: v.ageSec,
      stale: v.attestationStale,
    }));
    const max = rs.reduce((s, r) => Math.max(s, r.total), 0);
    return { rs, max };
  }, [liveVaults]);

  return (
    <Panel className="flex h-full flex-col p-5">
      <div className="flex items-center justify-between">
        <MicroLabel>Backing Composition</MicroLabel>
        <span className="font-mono text-[10px] uppercase tracking-[0.08em] text-white-60/50">/05</span>
      </div>
      <p className="mt-3 font-mono text-[26px] leading-none tracking-[-0.03em] text-white tabular-nums">
        {fmtOrDash(totals ? totals.margin + totals.buffer : null, (n) => fmtCompactUSD(n))}
      </p>
      <p className="mt-1 font-mono text-[10px] uppercase tracking-[0.08em] text-white-60">
        Attested margin + buffer held
      </p>
      <AgeLine
        className="mt-1"
        ageSec={totals?.worstAgeSec ?? null}
        stale={Boolean(totals?.anyStale)}
        maxAgeSec={maxAttestationAgeSec}
      />

      {rows.rs.length === 0 ? (
        <EmptyState className="mt-5" title="No chain data yet" detail="Reading chain 46630…" />
      ) : (
        <div className="mt-5 flex flex-col gap-4">
          {rows.rs.map((r) => (
            <div key={r.id}>
              <div className="mb-1.5 flex items-baseline justify-between font-mono text-[10px] uppercase tracking-[0.08em]">
                <span className="text-white">{r.label}</span>
                <span className="tabular-nums text-white-60">{fmtCompactUSD(r.total)}</span>
              </div>
              <div className="flex h-[10px] w-full overflow-hidden bg-white/5">
                <span
                  className="h-full bg-white/30"
                  style={{ width: `${rows.max > 0 ? (r.margin / rows.max) * 100 : 0}%` }}
                />
                <span
                  className="h-full bg-green-bright"
                  style={{ width: `${rows.max > 0 ? (r.buffer / rows.max) * 100 : 0}%` }}
                />
              </div>
            </div>
          ))}
        </div>
      )}

      <div className="mt-5 flex flex-wrap gap-x-5 gap-y-1.5 font-mono text-[10px] uppercase tracking-[0.08em] text-white-60">
        <span className="flex items-center gap-2">
          <span className="h-2 w-2 bg-white/30" /> Margin at venue (attested)
        </span>
        <span className="flex items-center gap-2">
          <span className="h-2 w-2 bg-green-bright" /> Buffer held (ERC-20)
        </span>
      </div>

      {/* Separate register, below the total, never added to it. */}
      <div className="mt-auto border-t hairline-dark pt-4">
        <div className="flex items-center justify-between gap-3">
          <MicroLabel className="text-[10px] text-warn/80">Accrual claimed</MicroLabel>
          <UnverifiedTag />
        </div>
        <p className="mt-2 font-mono text-[16px] tabular-nums leading-none text-silver">
          {fmtOrDash(totals ? totals.accrualClaimedUnverified : null, (n) => fmtCompactUSD(n))}
        </p>
        <p className="mt-2 font-mono text-[10px] leading-[1.7] uppercase tracking-[0.06em] text-white-60/70">
          Attester-relayed cumulative P&amp;L. Nothing on-chain verifies it and it goes negative. It is
          not collateral and it is not in the figure above.
        </p>
      </div>
    </Panel>
  );
}

/* ------------------------------------------------------- funding monitor */

/**
 * There is no funding history and no funding rate on these contracts.
 *
 * `accrual18` is a cumulative claim, not a rate; deriving an hourly or 8-hourly figure
 * from it would be arithmetic on top of an unverified number. So this panel shows the
 * claim per vault, labelled, and says plainly that the 48-bar history needs an indexer.
 */
export function FundingMonitor() {
  const { liveVaults, maxAttestationAgeSec } = useDashboard();

  return (
    <Panel className="flex h-full flex-col p-5">
      <div className="flex items-center justify-between">
        <MicroLabel>Funding &amp; Accrual</MicroLabel>
        <UnverifiedTag />
      </div>

      <div className="mt-4 flex flex-col divide-y divide-white/5">
        {liveVaults.map((v) => (
          <div key={v.id} className="flex items-center justify-between gap-4 py-3">
            <div className="min-w-0">
              <p className="font-sans text-[13px] font-semibold uppercase text-white">{v.name}</p>
              <AgeLine ageSec={v.ageSec} stale={v.attestationStale} maxAgeSec={maxAttestationAgeSec} />
            </div>
            <div className="text-right">
              <p className="font-mono text-[15px] tabular-nums leading-none text-silver">
                {fmtUSD(v.backing.accrualClaimedUnverified, 2)}
              </p>
              <p className="mt-1 font-mono text-[10px] uppercase tracking-[0.06em] text-white-60/70">
                cumulative claim, not a rate
              </p>
            </div>
          </div>
        ))}
      </div>

      <EmptyState
        className="mt-4"
        title="No funding history yet: needs an indexer"
        detail="No view function returns a funding series, and there is no 8-hour rate to publish — the only figure the chain gives is the cumulative accrual claim above. The 48 hourly bars are not drawn rather than guessed."
      />

      <p className="mt-auto pt-4 font-mono text-[10px] leading-[1.6] uppercase tracking-[0.06em] text-white-60">
        Funding lands in the buffer, which is a real ERC-20 balance. The claim above is the attester's
        account of it and is not the same thing.
      </p>
    </Panel>
  );
}

/* --------------------------------------------------------- network strip */

/** Chain vitals. Every cell is either a read or a documented deployment constant. */
export function NetworkStrip() {
  const { block, blockKnown, liveVaults, vaults, totals, maxAttestationAgeSec, flowsUnavailable } =
    useDashboard();

  const mintable = liveVaults.filter((v) => v.mintAllowed).length;
  const basisKnownCount = liveVaults.filter((v) => v.basisKnown).length;

  const stats: { label: string; value: string; tone?: "warn" }[] = [
    { label: "Block height", value: blockKnown ? block.toLocaleString("en-US") : EM_DASH },
    { label: "Chain", value: "46630 · testnet" },
    { label: "Vaults routed", value: `${liveVaults.length}/${vaults.length}` },
    {
      label: `Attestation age (max ${maxAttestationAgeSec}s)`,
      value: totals ? `${Math.round(totals.worstAgeSec)}s` : EM_DASH,
      ...(totals?.anyStale ? { tone: "warn" as const } : {}),
    },
    {
      label: "Minting allowed",
      value: liveVaults.length ? `${mintable}/${liveVaults.length}` : EM_DASH,
      ...(liveVaults.length && mintable < liveVaults.length ? { tone: "warn" as const } : {}),
    },
    {
      label: "Independent basis",
      value: liveVaults.length ? `${basisKnownCount}/${liveVaults.length}` : EM_DASH,
    },
    { label: "Indexer", value: flowsUnavailable ? "none" : "connected", tone: "warn" },
  ];

  return (
    <div className="mt-3 grid grid-cols-2 gap-px border hairline-dark bg-white/5 sm:grid-cols-3 xl:grid-cols-7">
      {stats.map((s) => (
        <div key={s.label} className="bg-abyss px-4 py-3">
          <p className="font-mono text-[9px] uppercase tracking-[0.1em] text-white-60/70">{s.label}</p>
          <p
            className={cn(
              "mt-1 font-mono text-[14px] tabular-nums",
              s.tone === "warn" ? "text-warn" : "text-white",
            )}
          >
            {s.value}
          </p>
        </div>
      ))}
    </div>
  );
}

/* ----------------------------------------------------------- peg monitor */

/**
 * Oracle health per vault, replacing the old "oracle vs market" table.
 *
 * There is no market price for these certificates on chain 46630 and no volume figure, so
 * neither is shown. What the oracle does publish is `basisBpsChecked()`, and the boolean
 * half is the point: `known === false` means there is NO independent basis to compute,
 * which is categorically different from a basis of zero. Rendering only the number would
 * turn "unverifiable" into "perfect".
 */
export function PegMonitor() {
  const { liveVaults, vaultConfig, maxAttestationAgeSec } = useDashboard();

  return (
    <Panel className="mt-3 overflow-x-auto">
      <div className="flex items-center justify-between border-b hairline-dark px-5 py-4">
        <MicroLabel>Oracle Monitor · CertOracle</MicroLabel>
        <span className="flex items-center gap-2 font-mono text-[10px] uppercase tracking-[0.08em] text-white-60">
          <PulseDot /> Guarded reads only
        </span>
      </div>
      {liveVaults.length === 0 ? (
        <EmptyState className="border-0" title="No chain data yet" detail="Reading chain 46630…" />
      ) : (
        <table className="w-full min-w-[760px] font-mono text-[12px]">
          <thead>
            <tr className="border-b hairline-dark text-left text-[10px] uppercase tracking-[0.08em] text-white-60">
              <th className="px-5 py-3 font-medium">Vault</th>
              <th className="px-3 py-3 text-right font-medium">Oracle price</th>
              <th className="px-3 py-3 text-right font-medium">Basis (checked)</th>
              <th className="px-3 py-3 text-right font-medium">Mint / redeem fee</th>
              <th className="hidden px-3 py-3 text-right font-medium md:table-cell">Instant cap</th>
              <th className="hidden px-3 py-3 text-right font-medium lg:table-cell">Proven</th>
              <th className="px-3 py-3 text-right font-medium">Minting</th>
            </tr>
          </thead>
          <tbody>
            {liveVaults.map((v) => {
              const cfg = vaultConfig(v.id);
              return (
                <tr key={v.id} className="border-b hairline-dark last:border-b-0">
                  <td className="px-5 py-3.5">
                    <span className="font-sans text-[14px] font-semibold uppercase text-white">{v.name}</span>
                  </td>
                  <td className="px-3 py-3.5 text-right tabular-nums text-white">
                    {v.priceUnavailable || v.price === null ? (
                      <span className="text-warn">unavailable</span>
                    ) : (
                      <Flash value={v.price} format={(n) => fmtUSD(n)} />
                    )}
                  </td>
                  {/* known === false is NOT a basis of zero. */}
                  <td className="px-3 py-3.5 text-right tabular-nums">
                    {v.basisKnown && v.basisBps !== null ? (
                      <span className="text-white">{v.basisBps.toFixed(2)}%</span>
                    ) : (
                      <span
                        className="text-warn"
                        title="The oracle reports no independent basis: the feed and the venue mark are declared the same source. This is not a basis of zero."
                      >
                        no independent basis
                      </span>
                    )}
                  </td>
                  <td className="px-3 py-3.5 text-right tabular-nums text-white-60">
                    {cfg
                      ? `${fromBps(cfg.mintFeeBps).toFixed(2)}% / ${fromBps(cfg.redeemFeeBps).toFixed(2)}%`
                      : EM_DASH}
                  </td>
                  <td className="hidden px-3 py-3.5 text-right tabular-nums text-white-60 md:table-cell">
                    {cfg ? fmtUSD(fromPrice18(cfg.instantCap18), 0) : EM_DASH}
                  </td>
                  <td className="hidden px-3 py-3.5 text-right lg:table-cell">
                    <AgeLine
                      ageSec={v.ageSec}
                      stale={v.attestationStale}
                      maxAgeSec={maxAttestationAgeSec}
                      batch={v.backing.provenAtBatch}
                    />
                  </td>
                  <td className="px-3 py-3.5 text-right">
                    <span
                      className={cn(
                        "whitespace-nowrap rounded-full border px-2.5 py-0.5 text-[10px] uppercase tracking-[0.08em]",
                        v.mintAllowed
                          ? "border-green-bright/40 text-green-bright"
                          : "border-warn/40 text-warn",
                      )}
                    >
                      {v.mintAllowed ? "Allowed" : "Paused"}
                    </span>
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      )}
      <p className="border-t hairline-dark px-5 py-3 font-mono text-[10px] leading-[1.6] uppercase tracking-[0.06em] text-white-60">
        Prices are read through CertOracle, which applies the staleness, deviation and basis guards; the
        aggregator is never read directly. Minting paused means the oracle is unhealthy — redemption is
        unaffected. Supply across routed vaults:{" "}
        {fmtNum(
          liveVaults.reduce((s, v) => s + (v.supply ?? 0), 0),
          2,
        )}{" "}
        certificates.
      </p>
    </Panel>
  );
}
