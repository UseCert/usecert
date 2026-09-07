import { useState } from "react";
import { Check, RotateCcw } from "lucide-react";
import { useDashboard } from "./store";
import { MicroLabel, Panel, PulseDot, Stagger, Flash, ViewHeader } from "./ui";
import { SolvencyChart, FundingChart } from "./charts";
import { fmtCompactUSD, fmtNum, fmtUSD } from "./format";
import { cn } from "@/lib/utils";

const PARAMS: [string, string][] = [
  ["Mint Fee", "10 bps"],
  ["Redeem Fee", "10 bps"],
  ["Fee Bound", "Bounded at deploy"],
  ["Delta Band", "±0.2%"],
  ["Oracle Staleness Guard", "30s"],
  ["Oracle Deviation Guard", "1.5%"],
  ["Upgrades", "Timelocked 48h"],
  ["Keeper Bounty", "5 bps of rebalance"],
];

function MiniStat({ label, value, accent }: { label: string; value: string; accent?: boolean }) {
  return (
    <div className="border hairline-dark bg-[#0d0f0d] p-4">
      <MicroLabel className="text-[10px]">{label}</MicroLabel>
      <p className={cn("mt-2 font-mono text-[18px] tabular-nums leading-none", accent ? "text-green-bright" : "text-white")}>{value}</p>
    </div>
  );
}

function ThresholdMeter({ pct }: { pct: number }) {
  return (
    <div className="pt-8">
      <div className="relative h-6 w-full" style={{ background: "linear-gradient(90deg, #d8c98a 0%, #859885 45%, #a8c9a4 100%)", opacity: 0.35 }}>
        {/* needle */}
        <div
          className="absolute top-[-6px] h-[36px] w-[2px] bg-white transition-all duration-300"
          style={{ left: `calc(${pct}% - 1px)` }}
        >
          <span className="absolute -top-7 left-1/2 -translate-x-1/2 whitespace-nowrap border hairline-dark bg-[#0d0f0d] px-2 py-0.5 font-mono text-[10px] uppercase tracking-[0.08em] text-white">
            Buffer {pct.toFixed(0)}%
          </span>
        </div>
        {[20, 45, 70].map((t) => (
          <span key={t} className="absolute top-0 h-full w-px bg-abyss/70" style={{ left: `${t}%` }} aria-hidden />
        ))}
      </div>
      <div className="relative mt-2 h-8 font-mono text-[10px] uppercase tracking-[0.06em] text-white-60">
        <span className="absolute -translate-x-1/2 text-center leading-[1.5]" style={{ left: "20%" }}>
          Insurance_Draw
          <br />
          20%
        </span>
        <span className="absolute -translate-x-1/2 text-center leading-[1.5]" style={{ left: "45%" }}>
          Mint_Slow
          <br />
          45%
        </span>
        <span className="absolute -translate-x-1/2 text-center leading-[1.5]" style={{ left: "70%" }}>
          Fee_On
          <br />
          70%
        </span>
      </div>
    </div>
  );
}

function bufferStatus(pct: number): { text: string; tone: "green" | "brass" | "red" } {
  if (pct >= 70) return { text: "Funding is accruing to the buffer. No holding fee active.", tone: "green" };
  if (pct >= 45) return { text: "Holding fee active: 2 bps/day, published on chain.", tone: "brass" };
  if (pct >= 20) return { text: "Mint slow zone: mints settle next block window.", tone: "brass" };
  return { text: "Insurance draw: staked tokens absorbing buffer deficit. Holders untouched.", tone: "red" };
}

export default function VaultsView() {
  const { vaults, selectedVault, goVault, goMint } = useDashboard();
  const [shock, setShock] = useState(0);
  const vault = vaults.find((v) => v.id === selectedVault) ?? vaults[0];
  const notional = vault.supply * vault.price;
  const effPct = Math.max(0, Math.min(100, vault.bufferPct - shock * 0.7));
  const status = bufferStatus(effPct);

  return (
    <div>
      {/* Header + selector */}
      <ViewHeader
        label="Per-Asset Vaults"
        title={<>Every Certificate, <span className="text-metallic">Backed.</span></>}
        right={
        <div className="flex border hairline-dark">
          {vaults.map((v) => {
            const disabled = v.status === "SOON";
            const active = v.id === selectedVault;
            return (
              <button
                key={v.id}
                type="button"
                disabled={disabled}
                title={disabled ? "Roadmap C2" : v.full}
                onClick={() => goVault(v.id)}
                className={cn(
                  "flex items-center gap-2 px-4 py-2.5 font-mono text-[12px] uppercase tracking-[0.08em] transition-colors md:px-5",
                  active ? "bg-green-bright text-ink" : "text-white-60 hover:text-white",
                  disabled && "cursor-not-allowed opacity-40",
                )}
              >
                {v.name}
                {disabled && (
                  <span className="rounded-full border border-warn/40 px-1.5 py-px text-[9px] text-warn">Soon</span>
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
            <img src={vault.img} alt={`${vault.name} plate`} className="h-20 w-20 border hairline-dark object-cover md:h-24 md:w-24" />
            <div>
              <div className="flex items-center gap-3">
                <h2 className="text-[32px] font-semibold uppercase leading-none tracking-[-0.03em] md:text-[40px]">{vault.name}</h2>
                <span className="rounded-full border border-green-bright/40 px-2.5 py-0.5 font-mono text-[10px] uppercase tracking-[0.08em] text-green-bright">
                  {vault.status}
                </span>
              </div>
              <p className="mt-2 text-[14px] text-white-60">{vault.full}</p>
            </div>
          </div>
          <div className="md:text-right">
            <p className="font-mono text-[36px] leading-none tracking-[-0.04em] text-white md:text-[44px]">
              <Flash value={vault.price} format={(n) => fmtUSD(n)} />
            </p>
            <p className="mt-2 flex items-center gap-2 font-mono text-[10px] uppercase tracking-[0.08em] text-white-60 md:justify-end">
              <PulseDot /> Oracle: CertOracle · 2s ago
            </p>
            <p className={cn("mt-1 font-mono text-[12px]", vault.change24h >= 0 ? "text-green-bright" : "text-silver")}>
              {vault.change24h >= 0 ? "▲" : "▼"} {Math.abs(vault.change24h).toFixed(2)}% / 24H
            </p>
          </div>
        </Panel>
      </Stagger>

      {/* Stat grid */}
      <Stagger index={1}>
        <div className="mt-3 grid grid-cols-2 gap-3 md:grid-cols-3 xl:grid-cols-6">
          <MiniStat label="Supply" value={`${fmtNum(vault.supply, 0)} ${vault.name}`} />
          <MiniStat label="Position Notional" value={fmtCompactUSD(notional)} />
          <MiniStat label="Margin (USDC)" value={fmtCompactUSD(notional * 1.0002)} />
          <MiniStat label="Buffer" value={fmtCompactUSD(vault.buffer)} accent />
          <MiniStat label="Delta" value={vault.delta.toFixed(3)} />
          <MiniStat label="Funding (8H)" value={`+${vault.funding8h.toFixed(4)}%`} accent={vault.funding8h >= 0} />
        </div>
      </Stagger>

      {/* Charts */}
      <div className="mt-3 grid gap-3 lg:grid-cols-2">
        <Stagger index={2}>
          <Panel className="p-5">
            <div className="mb-3 flex items-center justify-between">
              <MicroLabel>Backing vs Obligation</MicroLabel>
              <span className="flex items-center gap-3 font-mono text-[10px] uppercase tracking-[0.08em] text-white-60">
                <span className="flex items-center gap-1.5"><span className="h-1.5 w-1.5 bg-green-bright" /> Backing</span>
                <span className="flex items-center gap-1.5"><span className="h-1.5 w-1.5 bg-silver" /> Supply × Price</span>
              </span>
            </div>
            <SolvencyChart points={vault.solvency} tf="24H" height={260} />
          </Panel>
        </Stagger>
        <Stagger index={3}>
          <Panel className="p-5">
            <div className="mb-3 flex items-center justify-between">
              <MicroLabel>Funding History · 48H</MicroLabel>
              <span className="flex items-center gap-3 font-mono text-[10px] uppercase tracking-[0.08em] text-white-60">
                <span className="flex items-center gap-1.5"><span className="h-1.5 w-1.5 bg-green-bright" /> Positive</span>
                <span className="flex items-center gap-1.5"><span className="h-1.5 w-1.5 bg-warn" /> Negative</span>
              </span>
            </div>
            <FundingChart bars={vault.funding} height={260} />
          </Panel>
        </Stagger>
      </div>

      {/* Buffer health + simulator */}
      <Stagger index={4}>
        <Panel className="mt-3 p-5 md:p-6">
          <div className="flex flex-wrap items-center justify-between gap-3">
            <MicroLabel>Buffer Health</MicroLabel>
            <MicroLabel className="text-[10px]">Simulator · Does not affect protocol</MicroLabel>
          </div>
          <ThresholdMeter pct={effPct} />
          <p
            className={cn(
              "mt-4 flex items-center gap-2 font-mono text-[12px]",
              status.tone === "green" ? "text-green-bright" : "text-warn",
            )}
          >
            <Check size={14} /> {status.text}
          </p>
          <div className="mt-6 flex flex-col gap-3 border-t hairline-dark pt-5 md:flex-row md:items-center">
            <span className="w-[260px] shrink-0 font-mono text-[11px] uppercase tracking-[0.08em] text-white-60">
              Sustained negative funding shock
            </span>
            <input
              type="range"
              min={0}
              max={100}
              value={shock}
              onChange={(e) => setShock(Number(e.target.value))}
              className="h-1 w-full cursor-pointer accent-[#a8c9a4]"
              aria-label="Funding shock simulator"
            />
            <span className="w-12 font-mono text-[12px] tabular-nums text-white">{shock}%</span>
            <button
              type="button"
              onClick={() => setShock(0)}
              className="flex items-center gap-1.5 border hairline-dark px-3 py-1.5 font-mono text-[10px] uppercase tracking-[0.08em] text-white-60 transition-colors hover:text-white"
            >
              <RotateCcw size={12} /> Reset
            </button>
          </div>
        </Panel>
      </Stagger>

      {/* Parameters */}
      <Stagger index={5}>
        <Panel className="mt-3 p-5 md:p-6">
          <MicroLabel>Vault Parameters</MicroLabel>
          <div className="mt-4 grid gap-x-10 md:grid-cols-2">
            {PARAMS.map(([k, v]) => (
              <div key={k} className="flex items-center justify-between border-b hairline-dark py-3 font-mono text-[12px]">
                <span className="text-[11px] uppercase tracking-[0.08em] text-white-60">{k}</span>
                <span className="text-white">{v}</span>
              </div>
            ))}
          </div>
        </Panel>
      </Stagger>

      {/* CTA row */}
      <Stagger index={6}>
        <div className="mt-6 grid gap-3 sm:grid-cols-2">
          <button
            type="button"
            onClick={() => goMint("mint", vault.id)}
            className="bg-green-bright px-8 py-[18px] text-[12px] font-semibold uppercase tracking-[0.08em] text-ink transition-all hover:bg-[#b8d4b4] active:scale-[0.98]"
          >
            Mint {vault.name}
          </button>
          <button
            type="button"
            onClick={() => goMint("redeem", vault.id)}
            className="border hairline-dark px-8 py-[18px] text-[12px] font-semibold uppercase tracking-[0.08em] text-white transition-all hover:bg-section-deep-2 active:scale-[0.98]"
          >
            Redeem {vault.name}
          </button>
        </div>
      </Stagger>
    </div>
  );
}
