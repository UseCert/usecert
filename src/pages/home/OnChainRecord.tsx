import { useMemo } from "react";
import { ArrowUpRight } from "lucide-react";
import LetterReveal from "@/components/LetterReveal";
import { useFlows, type FlowEvent } from "@/chain/useFlows";

/**
 * §11 "ON-CHAIN RECORD." - replaces "What holders say."
 *
 * That section quoted a "Holder since C1", a "DeFi Builder" and an "Arbitrageur", and one quote
 * said the certificate was listed as collateral the week the vault opened. None of it happened;
 * nobody was quoting anyone. This shows what did happen instead: every mint and redemption on
 * the deployed vaults, joined request to settlement, each step a link to its transaction. It
 * reads the same flows as the dashboard (UseCert indexer first, explorer fallback) and states
 * which answered. Nothing here is a claim the chain does not make.
 */
type Row = {
  key: string;
  vault: string;
  kind: "Mint" | "Redeem";
  receipt: string | null;
  input: string;
  output: string;
  status: string;
  steps: { label: string; url: string }[];
  timeMs: number | null;
};

const fmt = (n: number | null, dp: number) =>
  n === null ? "—" : n.toLocaleString("en-US", { maximumFractionDigits: dp, minimumFractionDigits: Math.min(dp, 2) });

function rowsFrom(flows: FlowEvent[]): Row[] {
  const by = (v: string, k: string, r: string | null) =>
    flows.find((f) => f.vaultSymbol === v && f.kind === k && f.receiptId === r);
  const rows: Row[] = [];
  for (const f of flows) {
    if (f.kind === "MINT_REQUESTED") {
      const s = by(f.vaultSymbol, "MINT_SETTLED", f.receiptId);
      const refund = by(f.vaultSymbol, "MINT_REFUNDED", f.receiptId);
      rows.push({
        key: f.id, vault: f.vaultSymbol, kind: "Mint", receipt: f.receiptId,
        input: `${fmt(f.collateral, 2)} USDG`,
        output: s ? `${fmt(s.cert, 4)} ${f.vaultSymbol}` : refund ? `${fmt(refund.collateral, 2)} USDG refunded` : "—",
        status: s ? "issued" : refund ? "refunded" : "awaiting hedge",
        steps: [{ label: "request", url: f.txUrl }, ...(s ? [{ label: "settle", url: s.txUrl }] : []), ...(refund ? [{ label: "refund", url: refund.txUrl }] : [])],
        timeMs: f.timeMs,
      });
    } else if (f.kind === "REDEEM_REQUESTED" || f.kind === "FORCE_EXITED") {
      const c = by(f.vaultSymbol, "REDEEM_CLAIMED", f.receiptId);
      rows.push({
        key: f.id, vault: f.vaultSymbol, kind: "Redeem", receipt: f.receiptId,
        input: `${fmt(f.cert, 4)} ${f.vaultSymbol}`,
        output: c ? `${fmt(c.collateral, 2)} USDG` : "—",
        status: c ? "claimed" : "awaiting claim",
        steps: [{ label: "request", url: f.txUrl }, ...(c ? [{ label: "claim", url: c.txUrl }] : [])],
        timeMs: f.timeMs,
      });
    } else if (f.kind === "MINT" || f.kind === "REDEEM") {
      rows.push({
        key: f.id, vault: f.vaultSymbol, kind: f.kind === "MINT" ? "Mint" : "Redeem", receipt: null,
        input: f.kind === "MINT" ? `${fmt(f.collateral, 2)} USDG` : `${fmt(f.cert, 4)} ${f.vaultSymbol}`,
        output: f.kind === "MINT" ? `${fmt(f.cert, 4)} ${f.vaultSymbol}` : `${fmt(f.collateral, 2)} USDG`,
        status: f.kind === "MINT" ? "issued" : "paid",
        steps: [{ label: "tx", url: f.txUrl }],
        timeMs: f.timeMs,
      });
    }
  }
  return rows.sort((a, b) => (b.timeMs ?? 0) - (a.timeMs ?? 0));
}

export default function OnChainRecord() {
  const history = useFlows();
  const rows = useMemo(() => rowsFrom(history.flows), [history.flows]);
  const mints = rows.filter((r) => r.kind === "Mint").length;
  const redeems = rows.filter((r) => r.kind === "Redeem").length;
  const open = rows.filter((r) => r.status.startsWith("awaiting")).length;

  return (
    <section id="signals" className="bg-paper text-ink">
      <div className="mx-auto max-w-[1440px] px-4 py-16 md:px-6 md:py-24 lg:px-12 lg:py-32">
        <div className="flex items-start justify-between gap-6">
          <h2 className="lg:whitespace-nowrap text-[44px] font-semibold uppercase leading-[0.85] tracking-[-0.05em] md:text-[60px] lg:text-[78px]">
            <LetterReveal text="On-chain record." byWord stagger={0.05} />
          </h2>
          <p className="font-mono text-[11px] uppercase tracking-[0.08em] text-ink-60">Signals</p>
        </div>

        <p className="mt-8 max-w-[70ch] text-[16px] leading-[1.55]">
          No quotes. Every certificate issued and redeemed on mainnet so far, joined from request to
          settlement, each step a link to its transaction.
        </p>

        <p className="mt-4 font-mono text-[11px] uppercase tracking-[0.08em] text-ink-60">
          {history.indexUnavailable
            ? "The index could not be read right now; every transaction is on the explorer."
            : history.isLoading
              ? "Reading the chain…"
              : `${mints} mints · ${redeems} redemptions · ${open === 0 ? "none awaiting" : `${open} awaiting`} · source: ${history.source}`}
        </p>

        {rows.length > 0 && (
          <div className="mt-10 overflow-x-auto">
            <table className="w-full min-w-[720px] border-collapse text-left font-mono text-[12px]">
              <thead>
                <tr className="border-b border-ink/15 uppercase tracking-[0.08em] text-ink-60">
                  <th className="py-3 pr-4 font-normal">Vault</th>
                  <th className="py-3 pr-4 font-normal">Flow</th>
                  <th className="py-3 pr-4 font-normal">In</th>
                  <th className="py-3 pr-4 font-normal">Out</th>
                  <th className="py-3 pr-4 font-normal">Status</th>
                  <th className="py-3 font-normal">Transactions</th>
                </tr>
              </thead>
              <tbody>
                {rows.map((r) => (
                  <tr key={r.key} className="border-b border-ink/10">
                    <td className="py-3 pr-4 font-semibold">{r.vault}</td>
                    <td className="py-3 pr-4">{r.kind}{r.receipt !== null ? ` #${r.receipt}` : ""}</td>
                    <td className="py-3 pr-4 tabular-nums">{r.input}</td>
                    <td className="py-3 pr-4 tabular-nums">{r.output}</td>
                    <td className="py-3 pr-4 uppercase tracking-[0.06em]">{r.status}</td>
                    <td className="py-3">
                      <span className="flex flex-wrap gap-3">
                        {r.steps.map((s) => (
                          <a key={s.label} href={s.url} target="_blank" rel="noreferrer noopener"
                             className="inline-flex items-center gap-1 underline decoration-ink/25 underline-offset-2 hover:text-green-deep">
                            {s.label}<ArrowUpRight size={11} />
                          </a>
                        ))}
                      </span>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}

        <p className="mt-6 max-w-[80ch] font-mono text-[10px] uppercase leading-[1.7] tracking-[0.06em] text-ink-60">
          These are the transactions, not an assessment of them. The hedge a keeper opens on the venue
          is off chain and is not proven by this table.
        </p>
      </div>
    </section>
  );
}
