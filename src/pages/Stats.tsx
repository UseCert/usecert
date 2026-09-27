import { useState } from "react";
import { ArrowUpRight } from "lucide-react";
import { STATS_CSV_URL, STATS_URL, useStats, type GapRow, type StatsAsset } from "@/chain/useStats";
import { EM_DASH, fmtAge } from "@/pages/dashboard/format";
import { cn } from "@/lib/utils";

/**
 * PUBLIC STATS (/stats, roadmap A16).
 *
 * WHY THIS PAGE EXISTS. Every certificate is priced by a Chainlink feed that stops outside US
 * market hours and hedged on a venue that trades around the clock. How far apart those two are,
 * what the hedge has paid in funding, and how far the venue moved while the feed was frozen are
 * the numbers a holder needs to judge the weekend risk, and until now none was published.
 *
 * WHAT IT IS NOT. No yield, no APY, no forecast: every figure is a past observation, computed
 * on UseCert's server by deploy/bin/usecert-history and shown here as written in stats.json.
 * stats.csv carries the same numbers with every recorded digit; this page rounds for display
 * and says so. The venue figures are Lighter's and are labelled as third-party data.
 */

const px = (n: number | null | undefined) =>
  n === null || n === undefined
    ? EM_DASH
    : n.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 4 });
const signedFixed = (n: number | null | undefined, dp: number) =>
  n === null || n === undefined ? EM_DASH : `${n > 0 ? "+" : ""}${n.toFixed(dp)}`;
/** Seconds since epoch → "2026-09-25 20:22" (UTC; the column header says so). */
const utc = (t: number | null | undefined) =>
  t === null || t === undefined ? EM_DASH : new Date(t * 1000).toISOString().slice(0, 16).replace("T", " ");
const duration = (sec: number) => `${Math.floor(sec / 3600)}h ${Math.floor((sec % 3600) / 60)}m`;
const tone = (n: number | null | undefined) =>
  n === null || n === undefined ? "text-white-60" : n < 0 ? "text-warn" : "text-white";

function Eyebrow({ children }: { children: React.ReactNode }) {
  return <p className="font-mono text-[11px] uppercase tracking-[0.08em] text-white-60">{children}</p>;
}

function Tag({ children, third }: { children: React.ReactNode; third?: boolean }) {
  return (
    <span
      className={cn(
        "inline-flex items-center border px-1.5 py-px font-mono text-[9px] uppercase tracking-[0.08em]",
        third ? "border-warn/40 text-warn" : "border-silver/40 text-silver",
      )}
    >
      {children}
    </span>
  );
}

function Note({ children }: { children: React.ReactNode }) {
  return <p className="mt-4 max-w-[80ch] text-[13px] leading-[1.6] text-white-60">{children}</p>;
}

const TH = "py-3 pr-4 font-normal";
const TD = "py-3 pr-4 tabular-nums";

function BasisTable({ assets }: { assets: StatsAsset[] }) {
  return (
    <div className="mt-6 overflow-x-auto">
      <table className="w-full min-w-[860px] border-collapse text-left font-mono text-[12px]">
        <thead>
          <tr className="border-b hairline-dark uppercase tracking-[0.08em] text-white-60">
            <th className={TH}>Asset</th>
            <th className={TH}>Feed price</th>
            <th className={TH}>Feed updated (UTC)</th>
            <th className={TH}>Feed</th>
            <th className={TH}>Venue mark</th>
            <th className={TH}>Venue index</th>
            <th className={TH}>Basis (bps)</th>
            <th className="py-3 font-normal">Sampled (UTC)</th>
          </tr>
        </thead>
        <tbody>
          {assets.map((a) => (
            <tr key={a.symbol} className="border-b hairline-dark">
              <td className="py-3 pr-4 font-semibold text-white">{a.symbol}</td>
              <td className={TD}>{px(a.now?.feed)}</td>
              <td className={TD}>{utc(a.now?.feedUpdatedAt)}</td>
              <td className="py-3 pr-4 uppercase tracking-[0.06em]">
                {a.now ? (
                  a.now.feedFrozen ? (
                    <span className="text-warn">Frozen</span>
                  ) : (
                    <span className="text-green-bright">Updating</span>
                  )
                ) : (
                  EM_DASH
                )}
              </td>
              <td className={TD}>{px(a.now?.mark)}</td>
              <td className={TD}>{px(a.now?.index)}</td>
              <td className={cn(TD, "font-semibold", tone(a.now?.basisBps))}>{signedFixed(a.now?.basisBps, 2)}</td>
              <td className="py-3 tabular-nums text-white-60">{utc(a.now?.t)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

function FundingTable({ assets }: { assets: StatsAsset[] }) {
  return (
    <div className="mt-6 overflow-x-auto">
      <table className="w-full min-w-[860px] border-collapse text-left font-mono text-[12px]">
        <thead>
          <tr className="border-b hairline-dark uppercase tracking-[0.08em] text-white-60">
            <th className={TH}>Asset</th>
            <th className={TH}>Venue market</th>
            <th className={TH}>7-day mean (% per hour)</th>
            <th className={TH}>Hours</th>
            <th className={TH}>30-day mean (% per hour)</th>
            <th className={TH}>Hours</th>
            <th className="py-3 font-normal">30-day total (%)</th>
          </tr>
        </thead>
        <tbody>
          {assets.map((a) => (
            <tr key={a.symbol} className="border-b hairline-dark">
              <td className="py-3 pr-4 font-semibold text-white">{a.symbol}</td>
              <td className={TD}>{a.market}</td>
              <td className={cn(TD, tone(a.funding.d7.avgPctPerHour))}>{signedFixed(a.funding.d7.avgPctPerHour, 6)}</td>
              <td className={cn(TD, "text-white-60")}>{`${a.funding.d7.hours} / ${a.funding.d7.expectedHours}`}</td>
              <td className={cn(TD, tone(a.funding.d30.avgPctPerHour))}>{signedFixed(a.funding.d30.avgPctPerHour, 6)}</td>
              <td className={cn(TD, "text-white-60")}>{`${a.funding.d30.hours} / ${a.funding.d30.expectedHours}`}</td>
              <td className={cn("py-3 tabular-nums", tone(a.funding.d30.sumPct))}>{signedFixed(a.funding.d30.sumPct, 4)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

function GapLine({ g }: { g: GapRow }) {
  const open = g.status === "open";
  return (
    <tr className="border-b hairline-dark align-top">
      <td className={TD}>{utc(g.freezeUpdatedAt)}</td>
      <td className={TD}>{px(g.feedAtFreeze)}</td>
      <td className={TD}>
        <span className="block">{px(g.markBeforeResume)}</span>
        {open && <span className="block text-[10px] uppercase tracking-[0.06em] text-white-60">Latest sample</span>}
        {g.recordingGapAtResume && (
          <span className="block text-[10px] uppercase tracking-[0.06em] text-warn">Samples missing before resume</span>
        )}
      </td>
      <td className={cn(TD, "font-semibold", tone(g.gapBps))}>{signedFixed(g.gapBps, 2)}</td>
      <td className={TD}>{open ? <span className="uppercase tracking-[0.06em] text-warn">Still frozen</span> : utc(g.resumeUpdatedAt)}</td>
      <td className={TD}>{px(g.feedAfterResume)}</td>
      <td className={cn(TD, tone(g.reopenMoveBps))}>{signedFixed(g.reopenMoveBps, 2)}</td>
      <td className="py-3 tabular-nums text-white-60">{duration(g.durationSec)}</td>
    </tr>
  );
}

function GapTable({ assets }: { assets: StatsAsset[] }) {
  const [pick, setPick] = useState(assets[0]?.symbol ?? "");
  const a = assets.find((x) => x.symbol === pick) ?? assets[0];
  if (!a) return null;
  return (
    <div className="mt-6">
      <div className="flex flex-wrap gap-2">
        {assets.map((x) => (
          <button
            key={x.symbol}
            type="button"
            onClick={() => setPick(x.symbol)}
            className={cn(
              "border px-2 py-0.5 font-mono text-[10px] uppercase tracking-[0.06em]",
              x.symbol === a.symbol ? "border-green-bright text-green-bright" : "hairline-dark text-white-60 hover:text-white",
            )}
          >
            {x.symbol}
          </button>
        ))}
      </div>
      {a.gaps.length === 0 ? (
        <p className="mt-6 font-mono text-[11px] uppercase tracking-[0.08em] text-white-60">
          No frozen window recorded for this asset yet.
        </p>
      ) : (
        <div className="mt-4 overflow-x-auto">
          <table className="w-full min-w-[1020px] border-collapse text-left font-mono text-[12px]">
            <thead>
              <tr className="border-b hairline-dark uppercase tracking-[0.08em] text-white-60">
                <th className={TH}>Feed froze (UTC)</th>
                <th className={TH}>Feed at freeze</th>
                <th className={TH}>Venue mark before resume</th>
                <th className={TH}>Gap (bps)</th>
                <th className={TH}>Feed resumed (UTC)</th>
                <th className={TH}>First feed price after</th>
                <th className={TH}>Feed move at reopen (bps)</th>
                <th className="py-3 font-normal">Frozen for</th>
              </tr>
            </thead>
            <tbody>
              {a.gaps.map((g) => (
                <GapLine key={g.freezeUpdatedAt} g={g} />
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}

export default function StatsPage() {
  const q = useStats();
  const d = q.data;

  return (
    <section className="grain bg-ink text-white">
      <div className="relative z-[2] mx-auto max-w-[1440px] px-4 py-24 md:px-6 md:py-32 lg:px-12">
        <Eyebrow>Public data</Eyebrow>
        <h1 className="mt-4 max-w-[22ch] text-[44px] font-semibold uppercase leading-[0.85] tracking-[-0.05em] md:text-[60px] lg:text-[78px]">
          The feed<span className="text-green-bright">,</span> the venue and the gap between them
        </h1>

        <p className="mt-8 max-w-[64ch] text-[16px] leading-[1.55] text-silver">
          Each certificate is priced by a Chainlink feed that stops updating outside US market hours,
          and hedged on Lighter, which trades around the clock. These tables show how far apart the two
          are now, what the hedge has paid or received in funding, and how far the venue moved while the
          feed was frozen.
        </p>
        <p className="mt-4 max-w-[64ch] text-[14px] leading-[1.6] text-white-60">
          Data: Chainlink price feeds on Robinhood Chain, read at a recorded block, and the public API of
          Lighter on Robinhood Chain (third-party data). Sampled by UseCert's server every 5 minutes; your
          browser reads the recorded file, not the chain or the venue.
        </p>

        <div className="mt-6 flex flex-wrap items-center gap-x-4 gap-y-2 font-mono text-[11px] uppercase tracking-[0.08em]">
          <Tag>Recorded by UseCert</Tag>
          <Tag third>Third-party data</Tag>
          <a
            href={STATS_CSV_URL}
            download="usecert-stats.csv"
            className="inline-flex items-center gap-1 text-white underline decoration-white/25 underline-offset-4 hover:text-green-bright"
          >
            Download stats.csv <ArrowUpRight size={12} />
          </a>
          <a
            href={STATS_URL}
            target="_blank"
            rel="noreferrer"
            className="inline-flex items-center gap-1 text-white-60 underline decoration-white/20 underline-offset-4 hover:text-green-bright"
          >
            stats.json <ArrowUpRight size={12} />
          </a>
          {d && (
            <span className="text-white-60">
              <span>Last updated</span> <span>{fmtAge(Date.now() / 1000 - d.generatedAt)}</span>{" "}
              <span className="tabular-nums">{`(${utc(d.generatedAt)} UTC)`}</span>
            </span>
          )}
        </div>

        {q.isLoading && (
          <p className="mt-16 font-mono text-[11px] uppercase tracking-[0.08em] text-white-60">Reading the recorded stats…</p>
        )}
        {q.isError && !d && (
          <div className="mt-16 border hairline-dark bg-section-deep p-6 md:p-8">
            <p className="font-mono text-[11px] uppercase tracking-[0.08em] text-warn">The stats file could not be read.</p>
            <p className="mt-3 max-w-[70ch] text-[14px] leading-[1.6] text-white-60">
              It is written by UseCert's server every 5 minutes. Nothing is shown in its place: no figure on
              this page is estimated when the file is missing.
            </p>
          </div>
        )}

        {d && (
          <>
            <div className="mt-16 md:mt-24">
              <Eyebrow>Basis now</Eyebrow>
              <h2 className="mt-3 text-[28px] font-semibold uppercase leading-[1] tracking-[-0.03em] md:text-[36px]">
                Venue mark against the feed
              </h2>
              <BasisTable assets={d.assets} />
              <Note>
                Basis = (venue mark − feed price) ÷ feed price × 10,000, at the latest sample. While the feed
                is frozen, the basis is measured against its last price, so it mostly shows how far the venue
                has moved since the feed stopped. A feed counts as frozen when its last update is more than an
                hour older than the block it was read at.
              </Note>
            </div>

            <div className="mt-16 md:mt-24">
              <Eyebrow>Funding</Eyebrow>
              <h2 className="mt-3 text-[28px] font-semibold uppercase leading-[1] tracking-[-0.03em] md:text-[36px]">
                What the hedge paid or received
              </h2>
              <FundingTable assets={d.assets} />
              <Note>
                The venue's hourly funding rates, signed from the vault's side: negative means the vault paid,
                positive means it received. The mean is taken over the hours the venue returned, shown next to
                the hours in the window. These are past rates, not a forecast and not a yield.
              </Note>
            </div>

            <div className="mt-16 md:mt-24">
              <Eyebrow>Weekend and after-hours gaps</Eyebrow>
              <h2 className="mt-3 text-[28px] font-semibold uppercase leading-[1] tracking-[-0.03em] md:text-[36px]">
                How far the venue moved while the feed was frozen
              </h2>
              <GapTable assets={d.assets} />
              <Note>
                A window starts at the feed's last update before it stopped and ends at its first update after.
                Gap = (venue mark at the last sample before the feed resumed − feed price at freeze) ÷ feed price
                at freeze × 10,000. The feed move at reopen is the same ratio for the feed's first price after
                resuming. Where more than 15 minutes of samples are missing before the resume, the row says so.
                Windows are kept for 90 days.
              </Note>
            </div>
          </>
        )}

        <div className="mt-16 border hairline-dark bg-section-deep p-6 md:mt-24 md:p-8">
          <p className="font-mono text-[11px] uppercase tracking-[0.08em] text-green-bright">
            What these numbers are, and are not
          </p>
          <p className="mt-3 max-w-[70ch] text-[14px] leading-[1.6] text-white-60">
            Every figure is a past observation. The feed values can be re-read with latestRoundData() at the
            recorded block on an archive node. The venue's mark, index and funding are Lighter's own figures;
            UseCert records them and does not verify them. The recording times are UseCert's server's word.
            Prices are rounded on this page; stats.csv and stats.json carry the recorded values in full.
          </p>
        </div>
      </div>
    </section>
  );
}
