import { useQuery } from "@tanstack/react-query";
import { ArrowUpRight } from "lucide-react";
import { cn } from "@/lib/utils";

/**
 * Sourcify verification evidence, per address, from /data/sourcify.json.
 *
 * The file is written hourly on the UseCert host by deploy/bin/usecert-sourcify, from the LIVE
 * address book (never a typed list: the retired stacks are verified too). The browser never calls
 * Sourcify itself, so no visitor data reaches a third party. Each state says exactly what was
 * returned; nothing here is a claim about safety, audit, or the keeper's hedge.
 */
type Entry = {
  address: string;
  state: "exact" | "runtime" | "partial" | "none" | "unavailable";
  external: boolean;
  verifiedAt?: string | null;
  contractName?: string | null;
  compiler?: string | null;
};
type Doc = { generatedAt: number; counts: { ours: Record<string, number>; external: Record<string, number> }; contracts: Entry[] };

export function useSourcify() {
  return useQuery<Doc, Error>({
    queryKey: ["usecert", "sourcify"],
    queryFn: async ({ signal }) => {
      const r = await fetch("/data/sourcify.json", { signal, cache: "no-store" });
      if (!r.ok) throw new Error(`sourcify ${r.status}`);
      return (await r.json()) as Doc;
    },
    staleTime: 5 * 60_000,
    retry: 1,
  });
}

const LABEL: Record<Entry["state"], string> = {
  exact: "Exact source/bytecode match",
  runtime: "Runtime bytecode exact match",
  partial: "Partial match",
  none: "No verification returned",
  unavailable: "Verification evidence unavailable",
};

export const lookupUrl = (a: string) => `https://sourcify.dev/#/lookup/${a}`;

/** One address's evidence line, under its row on /contracts. */
export function SourcifyEvidence({ address }: { address: string }) {
  const q = useSourcify();
  const e = q.data?.contracts.find((c) => c.address.toLowerCase() === address.toLowerCase());
  const state: Entry["state"] = q.isError ? "unavailable" : e?.state ?? (q.data ? "none" : "unavailable");
  if (q.isLoading) return null;
  return (
    <p className="mt-1.5 flex flex-wrap items-center gap-x-2 gap-y-1 font-mono text-[10px] uppercase tracking-[0.06em]">
      <span
        className={cn(
          "border px-1.5 py-px",
          state === "exact" || state === "runtime" ? "border-green-bright/40 text-green-bright" : "border-white/15 text-white-60",
        )}
      >
        Sourcify · {LABEL[state]}
      </span>
      {e?.external && <span className="text-white-60/70">not UseCert code</span>}
      {e?.verifiedAt && <span className="text-white-60/70">verified {e.verifiedAt.slice(0, 10)}</span>}
      {e?.compiler && <span className="text-white-60/70">{e.compiler.split("+")[0]}</span>}
      <a href={lookupUrl(address)} target="_blank" rel="noreferrer noopener" className="inline-flex items-center gap-1 text-white-60 underline decoration-white/20 underline-offset-2 hover:text-green-bright">
        evidence <ArrowUpRight size={10} />
      </a>
    </p>
  );
}

/** The summary above the lists: counts, freshness and the limits of what this shows. */
export function SourcifySummary() {
  const q = useSourcify();
  const d = q.data;
  const ours = d?.counts.ours ?? {};
  const ext = d?.counts.external ?? {};
  const n = (o: Record<string, number>) => Object.values(o).reduce((a, b) => a + b, 0);
  const ageMin = d ? Math.max(0, Math.round((Date.now() / 1000 - d.generatedAt) / 60)) : null;
  return (
    <div className="mt-10 max-w-[86ch] border hairline-dark bg-[#0d0f0d] p-5">
      <p className="font-mono text-[11px] uppercase tracking-[0.08em] text-white">Verified code evidence · Sourcify</p>
      <p className="mt-3 font-mono text-[12px] leading-[1.7] text-silver">
        {q.isError || !d
          ? "Verification evidence unavailable right now. Every address below links to its Sourcify lookup."
          : `${n(ours)} UseCert contracts: ${ours.exact ?? 0} exact source/bytecode match (creation and runtime), ${ours.runtime ?? 0} runtime bytecode exact match with no creation match recorded (normal for a contract created by another contract)${ours.partial ? `, ${ours.partial} partial` : ""}${ours.none ? `, ${ours.none} with no verification returned` : ""}. ${n(ext)} external contracts (collateral, venue, price feeds) are shown too and marked as not UseCert code. Checked ${ageMin} min ago.`}
      </p>
      <p className="mt-3 text-[12px] leading-[1.6] text-white-60/80">
        This shows public source/bytecode verification status for these addresses on Robinhood Chain. It does not prove a
        signed release, an audit, the website build, the keeper's or attester's behaviour, a hedge or fill on the venue,
        collateral sufficiency, settlement, redemption, custody, dividends or voting rights. Certificates are synthetic
        exposure, not shares.
      </p>
    </div>
  );
}
