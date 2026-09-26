/**
 * Solvency and funding history, from the UseCert server's recorder (/data/history.json).
 *
 * PROVENANCE — a fourth class, next to the three in useFlows.ts:
 *
 *   4. SERVER RECORDING   chain reads (vault.solvency(), oracle.px()) sampled every 5 minutes
 *                         by deploy/bin/usecert-history on the France host, and the venue's
 *                         own hourly funding history. The values are the same reads the
 *                         dashboard makes; what is trusted is the recorder's word about WHEN
 *                         each was read. Rendered under `RecordedTag`, never beside a live read
 *                         without it.
 *
 * Resampling never invents a value. A chart point is the latest recorded sample at or before
 * its slot, and a slot with no sample within 1.5 spacings ends the series there: a gap in the
 * recording is drawn as a shorter curve, not bridged.
 */
import { useQuery } from "@tanstack/react-query";
import type { FundingBar, SeriesPoint, Timeframe } from "@/pages/dashboard/store";

interface VaultSeries {
  t: number[];
  backing: number[];
  obligation: number[];
  pxUnavailable: number[];
}

interface VaultFunding {
  market: number;
  hours: number[];
  /** Percent per hour, signed from the long vault's side: negative = the vault pays. */
  ratePctPerHour: number[];
  /** USD per unit of base, same sign convention. */
  usdPerUnit: number[];
  stale?: boolean;
}

export interface HistoryFile {
  generatedAt: number;
  chainId: number;
  intervalSec: number;
  solvencySource: string;
  fundingSource: string;
  solvency: Record<string, VaultSeries>;
  funding: Record<string, VaultFunding>;
}

export const HISTORY_URL = "/data/history.json";

export function useHistory() {
  return useQuery<HistoryFile, Error>({
    queryKey: ["usecert", "history"],
    queryFn: async ({ signal }) => {
      const r = await fetch(HISTORY_URL, { signal, cache: "no-store" });
      if (!r.ok) throw new Error(`history ${r.status}`);
      return (await r.json()) as HistoryFile;
    },
    refetchInterval: 60_000,
    staleTime: 55_000,
    retry: 1,
  });
}

const SPACING_MS: Record<Timeframe, number> = {
  "1H": 4 * 60 * 1000,
  "24H": 24 * 60 * 1000,
  "7D": 2 * 3600 * 1000,
  ALL: 2 * 86400 * 1000,
};

/**
 * Up to 60 evenly spaced points ending at the latest sample, for SolvencyChart's axis (which
 * labels point i as (n-1-i) spacings before now). Picks the widest window the recording fills.
 */
export function solvencySeries(
  seriesList: VaultSeries[],
): { points: SeriesPoint[]; tf: Timeframe; spanSec: number; anyPxFallback: boolean } | null {
  // One timeline: the recorder samples every vault in the same pass, so the t values line up.
  const byT = new Map<number, { backing: number; obligation: number; n: number; fallback: boolean }>();
  for (const s of seriesList) {
    s.t.forEach((t, i) => {
      const cur = byT.get(t) ?? { backing: 0, obligation: 0, n: 0, fallback: false };
      cur.backing += s.backing[i];
      cur.obligation += s.obligation[i];
      cur.n += 1;
      cur.fallback ||= s.pxUnavailable[i] === 1;
      byT.set(t, cur);
    });
  }
  // A timestamp missing any vault would drop that vault's money from the total: not a total.
  const ts = [...byT.entries()]
    .filter(([, v]) => v.n === seriesList.length)
    .sort((a, b) => a[0] - b[0]);
  if (ts.length < 2) return null;
  const span = (ts[ts.length - 1][0] - ts[0][0]) * 1000;
  const tf: Timeframe = span >= 12 * 3600 * 1000 ? "24H" : "1H";
  const spacing = SPACING_MS[tf];
  const out: SeriesPoint[] = [];
  let anyPxFallback = false;
  let j = ts.length - 1;
  const last = ts[j][0] * 1000;
  for (let k = 0; k < 60; k++) {
    const slot = last - k * spacing;
    while (j > 0 && ts[j][0] * 1000 > slot) j--;
    const [t, v] = ts[j];
    if (t * 1000 > slot || slot - t * 1000 > spacing * 1.5) break;
    out.push({ backing: v.backing, obligation: v.obligation });
    anyPxFallback ||= v.fallback;
  }
  out.reverse();
  if (out.length < 2) return null;
  return { points: out, tf, spanSec: Math.round(span / 1000), anyPxFallback };
}

/** The venue's last 48 hourly rates as FundingChart bars. accrued / bufferAfter are not known. */
export function fundingBars(f: VaultFunding | undefined): FundingBar[] {
  if (!f) return [];
  return f.ratePctPerHour.map((rate) => ({ rate, accrued: null, bufferAfter: null }));
}
