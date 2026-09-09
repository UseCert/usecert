import { isChainVaultId, isRouted, STATUS_HINT, STATUS_LABEL, useDashboard } from "./store";
import {
  AgeLine,
  EmptyState,
  Flash,
  MicroLabel,
  Panel,
  PriceUnavailable,
  Stagger,
  UnverifiedTag,
  ViewHeader,
} from "./ui";
import { EM_DASH, fmtCompactUSD, fmtNum, fmtOrDash, fmtUSD } from "./format";
import { fromBps, fromPrice18 } from "@/chain/units";
import { cn } from "@/lib/utils";

function MiniStat({
  label,
  value,
  accent,
  tag,
}: {
  label: string;
  value: string;
  accent?: boolean;
  tag?: React.ReactNode;
}) {
  return (
    <div className="border hairline-dark bg-[#0d0f0d] p-4">
      <div className="flex items-start justify-between gap-2">
        <MicroLabel className="text-[10px]">{label}</MicroLabel>
        {tag}
      </div>
      <p
        className={cn(
          "mt-2 font-mono text-[18px] tabular-nums leading-none",
          accent ? "text-green-bright" : "text-white",
        )}
      >
        {value}
      </p>
    </div>
  );
}

/** Buffer held against the vault's own capacity figure, both read on-chain. */
function CapacityBar({ pct }: { pct: number }) {
  const clamped = Math.max(0, Math.min(100, pct));
  return (
    <div className="relative h-6 w-full border hairline-dark bg-white/5">
      <div
        className="h-full bg-green-bright/60 transition-all duration-500"
        style={{ width: `${clamped}%` }}
      />
      <span className="absolute inset-0 flex items-center justify-center font-mono text-[10px] uppercase tracking-[0.08em] text-white">
        buffer held / bufferCapacity18 = {clamped.toFixed(1)}%
      </span>
    </div>
  );
}

export default function VaultsView() {
  const { vaults, selectedVault, goVault, goMint, vaultConfig, maxAttestationAgeSec } = useDashboard();

  const vault = vaults.find((v) => v.id === selectedVault) ?? vaults[0];
  const routed = isRouted(vault);
  const cfg = vaultConfig(vault.id);
  const backing = vault.backing;

  return (
    <div>
      {/* Header + selector */}
      <ViewHeader
        label="Per-Asset Vaults"
        title={
          <>
            Every Certificate, <span className="text-metallic">Backed.</span>
          </>
        }
        right={
          <div className="flex flex-wrap border hairline-dark">
            {vaults.map((v) => {
              const disabled = !isRouted(v);
              const active = v.id === selectedVault;
              return (
                <button
                  key={v.id}
                  type="button"
                  disabled={disabled}
                  title={disabled ? STATUS_HINT[v.status] : v.full}
                  onClick={() => goVault(v.id)}
                  className={cn(
                    "flex items-center gap-2 px-4 py-2.5 font-mono text-[12px] uppercase tracking-[0.08em] transition-colors md:px-5",
                    active ? "bg-green-bright text-ink" : "text-white-60 hover:text-white",
                    disabled && "cursor-not-allowed opacity-40 grayscale hover:text-white-60",
                  )}
                >
                  {v.name}
                  {disabled && (
                    <span className="whitespace-nowrap rounded-full border border-white/20 px-1.5 py-px text-[9px] text-white-60">
                      {STATUS_LABEL[v.status]}
                    </span>
                  )}
                </button>
              );
            })}
          </div>
        }
      />

      {/* Vault hero */}
      <Stagger index={0}>
        <Panel className="mt-8 flex flex-col justify-between gap-6 p-5 md:flex-row md:items-center md:p-6">
          <div className="flex items-center gap-4">
            <img
              src={vault.img}
              alt={vault.imgPlaceholder ? "Placeholder mark" : `${vault.name} plate`}
              className={cn(
                "h-20 w-20 border hairline-dark object-cover md:h-24 md:w-24",
                vault.imgPlaceholder && "object-contain p-3 opacity-80",
              )}
            />
            <div>
              <div className="flex flex-wrap items-center gap-3">
                <h2 className="text-[32px] font-semibold uppercase leading-none tracking-[-0.03em] md:text-[40px]">
                  {vault.name}
                </h2>
                <span
                  title={STATUS_HINT[vault.status]}
                  className={cn(
                    "rounded-full border px-2.5 py-0.5 font-mono text-[10px] uppercase tracking-[0.08em]",
                    routed ? "border-green-bright/40 text-green-bright" : "border-white/20 text-white-60",
                  )}
                >
                  {STATUS_LABEL[vault.status]}
                </span>
              </div>
              <p className="mt-2 text-[14px] text-white-60">{vault.full}</p>
              {vault.imgPlaceholder && (
                <p className="mt-1 font-mono text-[10px] uppercase tracking-[0.06em] text-white-60/60">
                  No certificate plate for this mirror yet — neutral mark shown rather than another
                  certificate's artwork.
                </p>
              )}
            </div>
          </div>
          <div className="md:text-right">
            {!routed ? (
              <p className="font-mono text-[36px] leading-none tracking-[-0.04em] text-white-60/50 md:text-[44px]">
                {EM_DASH}
              </p>
            ) : vault.priceUnavailable || vault.price === null ? (
              <PriceUnavailable className="text-[13px]" />
            ) : (
              <p className="font-mono text-[36px] leading-none tracking-[-0.04em] text-white md:text-[44px]">
                <Flash value={vault.price} format={(n) => fmtUSD(n)} />
              </p>
            )}
            <p className="mt-2 font-mono text-[10px] uppercase tracking-[0.08em] text-white-60 md:justify-end">
              {routed ? "Oracle: CertOracle (guarded)" : STATUS_HINT[vault.status]}
            </p>
            {routed && (
              <AgeLine
                className="mt-1 block"
                ageSec={vault.ageSec}
                stale={vault.attestationStale}
                maxAgeSec={maxAttestationAgeSec}
                batch={backing ? backing.provenAtBatch : null}
              />
            )}
          </div>
        </Panel>
      </Stagger>

      {!routed ? (
        <Stagger index={1}>
          <Panel className="mt-3 p-0">
            <EmptyState
              className="border-0"
              height={240}
              title={`${vault.name} is not deployed on chain 46630`}
              detail={`${STATUS_HINT[vault.status]} There is no vault, no certificate token and no oracle for it, so no supply, backing, buffer or price can be shown — and none is invented here.`}
            />
          </Panel>
        </Stagger>
      ) : (
        <>
          {/* Stat grid */}
          <Stagger index={1}>
            <div className="mt-3 grid grid-cols-2 gap-3 md:grid-cols-3 xl:grid-cols-6">
              <MiniStat
                label="Supply"
                value={fmtOrDash(vault.supply, (n) => `${fmtNum(n, 2)} ${vault.name}`)}
              />
              <MiniStat
                label="Notional (attested)"
                value={fmtOrDash(backing ? backing.notional : null, (n) => fmtCompactUSD(n))}
              />
              <MiniStat
                label="Margin (attested)"
                value={fmtOrDash(backing ? backing.margin : null, (n) => fmtCompactUSD(n))}
              />
              <MiniStat
                label="Buffer held (ERC-20)"
                value={fmtOrDash(vault.buffer, (n) => fmtCompactUSD(n))}
                accent
              />
              {/* deltaBps is unsigned on-chain: magnitude only, no direction. */}
              <MiniStat
                label="Delta drift from 1.0"
                value={fmtOrDash(vault.deltaBps, (n) => `${n.toFixed(2)}%`)}
              />
              <MiniStat
                label="Accrual claimed"
                value={fmtOrDash(
                  backing ? backing.accrualClaimedUnverified : null,
                  (n) => fmtUSD(n, 2),
                )}
                tag={<UnverifiedTag />}
              />
            </div>
          </Stagger>

          {/* Where the charts were. Neither series exists on-chain. */}
          <div className="mt-3 grid gap-3 lg:grid-cols-2">
            <Stagger index={2}>
              <Panel className="p-5">
                <div className="mb-3 flex items-center justify-between">
                  <MicroLabel>Backing vs Obligation</MicroLabel>
                </div>
                <div className="grid gap-3 sm:grid-cols-2">
                  <div className="border hairline-dark bg-[#0d0f0d] p-4">
                    <MicroLabel className="text-[10px]">Backing now</MicroLabel>
                    <p className="mt-2 font-mono text-[20px] tabular-nums leading-none text-green-bright">
                      {fmtOrDash(vault.solvency[0]?.backing ?? null, (n) => fmtCompactUSD(n))}
                    </p>
                  </div>
                  <div className="border hairline-dark bg-[#0d0f0d] p-4">
                    <MicroLabel className="text-[10px]">Obligation now</MicroLabel>
                    <p className="mt-2 font-mono text-[20px] tabular-nums leading-none text-silver">
                      {fmtOrDash(vault.solvency[0]?.obligation ?? null, (n) => fmtCompactUSD(n))}
                    </p>
                  </div>
                </div>
                <EmptyState
                  className="mt-3"
                  height={140}
                  title="No solvency history yet: needs an indexer"
                  detail="One provable point, at the attestation age above. The 60-point curve has no on-chain source and is not drawn."
                />
              </Panel>
            </Stagger>
            <Stagger index={3}>
              <Panel className="p-5">
                <div className="mb-3 flex items-center justify-between">
                  <MicroLabel>Funding History</MicroLabel>
                  <UnverifiedTag />
                </div>
                <EmptyState
                  height={240}
                  title="No funding history yet: needs an indexer"
                  detail="The chain publishes a cumulative accrual claim, not a rate and not a series. The 48 hourly bars are not drawn rather than interpolated."
                />
              </Panel>
            </Stagger>
          </div>

          {/* Buffer against capacity — both figures read on-chain */}
          <Stagger index={4}>
            <Panel className="mt-3 p-5 md:p-6">
              <div className="flex flex-wrap items-center justify-between gap-3">
                <MicroLabel>Buffer vs Capacity</MicroLabel>
                <MicroLabel className="text-[10px]">
                  bufferCapacity18 · headroom for new mints
                </MicroLabel>
              </div>
              <div className="mt-4">
                {vault.bufferPct !== null ? (
                  <CapacityBar pct={vault.bufferPct} />
                ) : (
                  <p className="font-mono text-[12px] text-white-60">{EM_DASH}</p>
                )}
              </div>
              <div className="mt-4 grid gap-3 sm:grid-cols-3">
                <MiniStat
                  label="Buffer held"
                  value={fmtOrDash(vault.buffer, (n) => fmtUSD(n, 2))}
                  accent
                />
                <MiniStat
                  label="Buffer capacity"
                  value={fmtOrDash(vault.bufferCapacity, (n) => fmtUSD(n, 2))}
                />
                <MiniStat
                  label="Hot buffer (instant redeem float)"
                  value={fmtOrDash(vault.hotBuffer, (n) => fmtUSD(n, 2))}
                />
              </div>
              <p className="mt-3 font-mono text-[10px] leading-[1.7] uppercase tracking-[0.06em] text-white-60/70">
                The percentage is literally buffer held over bufferCapacity18 — it is not a "percent of
                target" health gauge, and no threshold behaviour (insurance draw, mint slow, fee on) is
                deployed on these contracts. Read the two absolute figures, not the bar.
              </p>
              <p className="mt-4 font-mono text-[10px] leading-[1.7] uppercase tracking-[0.06em] text-white-60">
                A thin hot buffer does not block redemption: the instant path declines with
                CertVault_UseQueuedRedeem and the redemption is routed through the queue instead.
                forceExit is never gated on any of these figures.
              </p>
            </Panel>
          </Stagger>

          {/* Parameters, read from vault.cfg() */}
          <Stagger index={5}>
            <Panel className="mt-3 p-5 md:p-6">
              <div className="flex items-center justify-between gap-3">
                <MicroLabel>Vault Parameters · vault.cfg()</MicroLabel>
                <MicroLabel className="text-[10px]">read on-chain, not hardcoded</MicroLabel>
              </div>
              {!cfg ? (
                <EmptyState className="mt-4" title="Reading vault.cfg()…" />
              ) : (
                <div className="mt-4 grid gap-x-10 md:grid-cols-2">
                  {(
                    [
                      ["Mint fee", `${fromBps(cfg.mintFeeBps).toFixed(2)}% (${cfg.mintFeeBps} bps)`],
                      [
                        "Redeem fee",
                        `${fromBps(cfg.redeemFeeBps).toFixed(2)}% (${cfg.redeemFeeBps} bps)`,
                      ],
                      ["Instant cap (mint/redeem fork)", fmtUSD(fromPrice18(cfg.instantCap18), 2)],
                      ["Settle band", `${fromBps(cfg.settleBandBps).toFixed(2)}%`],
                      ["Target margin", `${fromBps(cfg.targetMarginBps).toFixed(2)}%`],
                      ["Venue market index", String(cfg.marketIndex)],
                      ["Collateral decimals", "6 (tUSDG)"],
                      [
                        "Max attestation age",
                        `${maxAttestationAgeSec}s · past this, capacity is 0 and minting is off`,
                      ],
                    ] as [string, string][]
                  ).map(([k, v]) => (
                    <div
                      key={k}
                      className="flex items-baseline justify-between gap-4 border-b hairline-dark py-3 font-mono text-[12px]"
                    >
                      <span className="text-[11px] uppercase tracking-[0.08em] text-white-60">{k}</span>
                      <span className="text-right text-white">{v}</span>
                    </div>
                  ))}
                </div>
              )}
            </Panel>
          </Stagger>

          {/* CTA row */}
          <Stagger index={6}>
            <div className="mt-6 grid gap-3 sm:grid-cols-2">
              <button
                type="button"
                disabled={!isChainVaultId(vault.id)}
                onClick={() => goMint("mint", vault.id)}
                className="bg-green-bright px-8 py-[18px] text-[12px] font-semibold uppercase tracking-[0.08em] text-ink transition-all hover:bg-[#b8d4b4] active:scale-[0.98] disabled:pointer-events-none disabled:opacity-40"
              >
                Mint {vault.name}
              </button>
              <button
                type="button"
                disabled={!isChainVaultId(vault.id)}
                onClick={() => goMint("redeem", vault.id)}
                className="border hairline-dark px-8 py-[18px] text-[12px] font-semibold uppercase tracking-[0.08em] text-white transition-all hover:bg-section-deep-2 active:scale-[0.98] disabled:pointer-events-none disabled:opacity-40"
              >
                Redeem {vault.name}
              </button>
            </div>
          </Stagger>
        </>
      )}
    </div>
  );
}
