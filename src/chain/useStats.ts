/**
 * Feed-vs-venue statistics, from the UseCert server's recorder (/data/stats.json, A16).
 *
 * PROVENANCE — the same fourth class as useHistory.ts (SERVER RECORDING), with a third party in it:
 *
 *   feed        Chainlink latestRoundData() on each vault's feed, read by the recorder at a block
 *               it records. Re-checkable at that block with an archive node.
 *   mark/index  Lighter's mark_price / index_price (GET /api/v1/orderBookDetails). THIRD-PARTY
 *               data: this site does not and cannot verify it, and labels it so.
 *   funding     Lighter's hourly rates (GET /api/v1/fundings), percent per hour, signed from the
 *               long vault's side: negative = the vault paid.
 *
 * Everything derived (basis, frozen flag, gap table, means) is computed by deploy/bin/usecert-history
 * and written to stats.json and stats.csv with the same digits. This module only reads the file.
 */
import { useQuery } from "@tanstack/react-query";

export interface StatsNow {
  t: number;
  block: number;
  blockTime: number;
  feed: number;
  feedUpdatedAt: number;
  feedFrozen: boolean;
  mark: number | null;
  index: number | null;
  basisBps: number | null;
}

export interface FundingWindow {
  hours: number;
  expectedHours: number;
  /** Mean of the hourly rates, percent per hour, vault's side. Null when no hour was returned. */
  avgPctPerHour: number | null;
  sumPct: number | null;
}

export interface GapRow {
  status: "open" | "closed";
  freezeUpdatedAt: number;
  feedAtFreeze: number;
  frozenSeenT: number;
  markSampleT: number | null;
  markBeforeResume: number | null;
  gapBps: number | null;
  resumeUpdatedAt: number | null;
  resumeSeenT: number | null;
  feedAfterResume: number | null;
  reopenMoveBps: number | null;
  durationSec: number;
  recordingGapAtResume: boolean;
}

export interface StatsAsset {
  symbol: string;
  market: number;
  feedAddress: string;
  now: StatsNow | null;
  funding: { d7: FundingWindow; d30: FundingWindow };
  /** Newest first. */
  gaps: GapRow[];
}

export interface StatsFile {
  generatedAt: number;
  chainId: number;
  intervalSec: number;
  frozenAfterSec: number;
  sources: Record<string, string>;
  definitions: Record<string, string>;
  assets: StatsAsset[];
}

export const STATS_URL = "/data/stats.json";
export const STATS_CSV_URL = "/data/stats.csv";

export function useStats() {
  return useQuery<StatsFile, Error>({
    queryKey: ["usecert", "stats"],
    queryFn: async ({ signal }) => {
      const r = await fetch(STATS_URL, { signal, cache: "no-store" });
      if (!r.ok) throw new Error(`stats ${r.status}`);
      return (await r.json()) as StatsFile;
    },
    refetchInterval: 60_000,
    staleTime: 55_000,
    retry: 1,
  });
}
