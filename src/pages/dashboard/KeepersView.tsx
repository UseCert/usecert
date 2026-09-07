import { useState } from "react";
import { Loader2, Play } from "lucide-react";
import { useDashboard } from "./store";
import type { Keeper } from "./store";
import { Panel, PulseDot, Stagger, ViewHeader } from "./ui";
import { fmtNum, timeAgo } from "./format";

function fmtCountdown(sec: number): string {
  const m = Math.floor(sec / 60);
  const s = sec % 60;
  if (m >= 60) return `${Math.floor(m / 60)}h ${m % 60}m`;
  return `${m}m ${s.toString().padStart(2, "0")}s`;
}

function KeeperCard({ keeper, index }: { keeper: Keeper; index: number }) {
  const { runKeeper, now, block } = useDashboard();
  const [running, setRunning] = useState(false);

  const run = () => {
    setRunning(true);
    window.setTimeout(() => {
      runKeeper(keeper.id);
      setRunning(false);
    }, 1000);
  };

  const detail =
    keeper.id === "indexer"
      ? `Indexed through BLOCK ${block.toLocaleString("en-US")}`
      : keeper.id === "funding" && keeper.nextInSec !== undefined
        ? `Next sweep in ${fmtCountdown(keeper.nextInSec)}`
        : keeper.detail;

  return (
    <Stagger index={index}>
      <Panel className="flex h-full flex-col p-5 md:p-6">
        <div className="flex items-start justify-between gap-3">
          <div>
            <h3 className="font-mono text-[14px] font-medium uppercase tracking-[0.06em] text-white">{keeper.name}</h3>
            <p className="mt-1.5 text-[13px] leading-[1.5] text-white-60">{keeper.desc}</p>
          </div>
          <span className="flex shrink-0 items-center gap-1.5 rounded-full border border-green-bright/40 px-2.5 py-1 font-mono text-[10px] uppercase tracking-[0.08em] text-green-bright">
            <PulseDot /> Active
          </span>
        </div>

        <div className="mt-5 flex flex-col font-mono text-[12px]">
          <div className="flex items-center justify-between border-t hairline-dark py-2.5">
            <span className="text-[10px] uppercase tracking-[0.08em] text-white-60">Last run</span>
            <span className="tabular-nums text-silver">{timeAgo(keeper.lastRun, now)}</span>
          </div>
          <div className="flex items-center justify-between border-t hairline-dark py-2.5">
            <span className="text-[10px] uppercase tracking-[0.08em] text-white-60">{keeper.runsLabel}</span>
            <span className="tabular-nums text-silver">{fmtNum(keeper.runsToday, 0)}</span>
          </div>
          <div className="flex items-center justify-between gap-4 border-t hairline-dark py-2.5">
            <span className="text-[10px] uppercase tracking-[0.08em] text-white-60">State</span>
            <span className="text-right text-[11px] uppercase tracking-[0.04em] text-green-bright">{detail}</span>
          </div>
          <div className="flex items-center justify-between border-t border-b hairline-dark py-2.5">
            <span className="text-[10px] uppercase tracking-[0.08em] text-white-60">Bounty</span>
            <span className="text-silver">5 bps of rebalance</span>
          </div>
        </div>

        <button
          type="button"
          onClick={run}
          disabled={running}
          className="mt-5 flex items-center justify-center gap-2 border hairline-dark px-4 py-3 text-[11px] font-semibold uppercase tracking-[0.08em] text-white transition-all hover:bg-section-deep-2 active:scale-[0.98] disabled:opacity-60"
        >
          {running ? <Loader2 size={13} className="animate-spin" /> : <Play size={13} />}
          {running ? "Running…" : "Run Now (Demo)"}
        </button>
      </Panel>
    </Stagger>
  );
}

export default function KeepersView() {
  const { keepers } = useDashboard();
  return (
    <div>
      <ViewHeader
        className="grid gap-8 lg:grid-cols-2"
        label="Keeper Network"
        title={<>Always <span className="text-metallic">Watching.</span></>}
        right={
        <p className="max-w-[46ch] self-end text-[18px] leading-[1.4] tracking-[-0.02em] text-silver md:text-[20px]">
          Keepers are permissionless. Anyone can run one and earn the bounty.
        </p>
        }
      />

      <div className="mt-8 grid gap-3 lg:grid-cols-2">
        {keepers.map((k, i) => (
          <KeeperCard key={k.id} keeper={k} index={i} />
        ))}
      </div>
    </div>
  );
}
