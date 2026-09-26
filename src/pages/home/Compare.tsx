import { motion } from "framer-motion";
import { Check, Minus } from "lucide-react";
import LetterReveal from "@/components/LetterReveal";
import SwapButton from "@/components/SwapButton";
import { cn } from "@/lib/utils";

const EASE = [0.16, 1, 0.3, 1] as [number, number, number, number];

type Cell = string | "check" | "dash" | "cross";

interface Row {
  feature: string;
  tooltip?: string;
  cells: [Cell, Cell, Cell];
}

const TIERS = [
  { name: "Equity Perps", descriptor: "Leveraged exposure you must manage yourself.", tag: "PERP" },
  { name: "Custodial Stock Tokens", descriptor: "Spot tokens issued through custodians on other chains.", tag: "CUSTODIAL" },
  { name: "UseCert", descriptor: "Holdable certificates backed by on chain perps.", tag: "CERTIFICATE", highlight: true },
];

const ROWS: Row[] = [
  {
    feature: "Exposure",
    tooltip:
      "Perps track the stock through funding and leverage. Certificates track it through a fully backed long held by the vault.",
    cells: ["Leveraged, funded, must manage", "Spot", "Spot"],
  },
  { feature: "Holdable & composable", cells: ["cross", "Doesn't exist here", "✓ plain token"] },
  { feature: "Custodian & geo-gate", cells: ["n/a", "Custodied, geo-blocked, KYC rails", "None, fully synthetic"] },
  { feature: "Liquidity source", cells: ["Deepest equity book on chain", "Off-chain issuance", "That same book, wrapped"] },
  {
    feature: "Backing",
    tooltip:
      "What actually sits behind your position: margin you manage, a custodian's claim, or on chain perp exposure plus collateral margin you can verify at every attestation.",
    cells: ["Your own margin", "Custodian claim", "On chain perps + USDG margin"],
  },
  { feature: "Funding", cells: ["Paid directly by you", "dash", "Buffered, then fee'd, never hidden"] },
  { feature: "Redemption", cells: ["Close your own position", "Issuer dependent", "Always, at oracle price — instant under the cap, queued above it"] },
  { feature: "Transparency", cells: ["Exchange dashboard", "Periodic attestations", "Solvency proven every attestation"] },
  { feature: "Availability", cells: ["24/7", "Market hours, restricted", "24/7"] },
];

function CellValue({ cell, highlight }: { cell: Cell; highlight?: boolean }) {
  if (cell === "check") return <Check size={16} className={highlight ? "text-green-bright" : "text-white-60"} />;
  if (cell === "dash") return <Minus size={16} className="text-white-60" />;
  if (cell === "cross") return <span className="text-white-60">✗</span>;
  const isCheck = cell.startsWith("✓");
  return (
    <span className={cn("text-[13px] leading-[1.4]", highlight ? "text-white" : "text-white-60")}>
      {isCheck && <Check size={14} className="mr-1 inline text-green-bright" />}
      {isCheck ? cell.slice(1).trim() : cell}
    </span>
  );
}

/** §10 "BEATING THE FIELD." (black, pricing-table replica) - #compare */
export default function Compare() {
  return (
    <section id="compare" className="grain bg-ink text-white">
      <div className="relative z-[2] mx-auto max-w-[1440px] px-4 py-16 md:px-6 md:py-24 lg:px-12 lg:py-32">
        <h2 className="text-[44px] font-semibold uppercase leading-[0.85] tracking-[-0.05em] md:text-[60px] lg:text-[78px]">
          <LetterReveal text="Beating the field." byWord stagger={0.05} />
        </h2>

        <motion.div
          className="mt-14 overflow-x-auto"
          initial={{ opacity: 0, y: 24 }}
          whileInView={{ opacity: 1, y: 0 }}
          viewport={{ once: true, amount: 0.1 }}
          transition={{ duration: 0.7, ease: EASE }}
        >
          <div className="min-w-[820px]">
            {/* Tier header */}
            <div className="grid grid-cols-[1.2fr_1fr_1fr_1fr]">
              <div />
              {TIERS.map((t, i) => (
                <motion.div
                  key={t.name}
                  className={cn(
                    "p-5 md:p-6",
                    t.highlight && "border-t border-green-bright bg-section-deep-2/60 shadow-[0_0_40px_rgba(168,201,164,0.08)]",
                  )}
                  initial={{ opacity: 0, y: 24 }}
                  whileInView={{ opacity: 1, y: 0 }}
                  viewport={{ once: true }}
                  transition={{ delay: i * 0.1, duration: 0.6, ease: EASE }}
                >
                  <p className="text-[20px] font-semibold uppercase tracking-[-0.03em] md:text-[24px]">{t.name}</p>
                  <p className="mt-2 text-[13px] uppercase leading-[1.4] text-white-60">{t.descriptor}</p>
                  <p className={cn("mt-3 font-mono text-[11px] uppercase tracking-[0.08em]", t.highlight ? "text-green-bright" : "text-white-60")}>
                    {t.tag}
                  </p>
                </motion.div>
              ))}
            </div>

            {/* Comparison rows */}
            <div className="border-t hairline-dark">
              <div className="grid grid-cols-[1.2fr_1fr_1fr_1fr] border-b hairline-dark">
                <p className="p-4 font-mono text-[11px] uppercase tracking-[0.08em] text-white-60 md:p-5">Feature</p>
                <div className="p-4 md:p-5" />
                <div className="p-4 md:p-5" />
                <div className="bg-section-deep-2/60 p-4 md:p-5" />
              </div>
              {ROWS.map((row, ri) => (
                <motion.div
                  key={row.feature + ri}
                  className="grid grid-cols-[1.2fr_1fr_1fr_1fr] border-b hairline-dark"
                  initial={{ opacity: 0 }}
                  whileInView={{ opacity: 1 }}
                  viewport={{ once: true, amount: 0.6 }}
                  transition={{ delay: ri * 0.04, duration: 0.4 }}
                >
                  <div className="flex items-center gap-2 p-4 md:p-5">
                    <span className="text-[13px] font-medium uppercase tracking-[0.04em] text-white">{row.feature}</span>
                    {row.tooltip && (
                      <span className="group relative flex h-4 w-4 cursor-help items-center justify-center rounded-full border hairline-dark font-mono text-[9px] text-white-60">
                        ?
                        <span className="pointer-events-none absolute bottom-full left-0 z-10 mb-2 w-[260px] translate-y-2 border hairline-dark bg-[#0d0f0d] p-3 font-mono text-[11px] normal-case leading-[1.5] tracking-normal text-white-60 opacity-0 transition-all duration-200 group-hover:translate-y-0 group-hover:opacity-100">
                          {row.tooltip}
                        </span>
                      </span>
                    )}
                  </div>
                  {row.cells.map((cell, ci) => (
                    <div key={ci} className={cn("flex items-center p-4 md:p-5", ci === 2 && "bg-section-deep-2/60")}>
                      <CellValue cell={cell} highlight={ci === 2} />
                    </div>
                  ))}
                </motion.div>
              ))}

              {/* CTA row */}
              <div className="grid grid-cols-[1.2fr_1fr_1fr_1fr]">
                <div />
                <div className="p-4 md:p-5">
                  <SwapButton label="Trade Perps ↗" href="https://robinhood.com" variant="outline" className="w-full [&>span]:w-full [&_span]:px-4" />
                </div>
                <div className="p-4 md:p-5">
                  <SwapButton
                    label="Not Here"
                    variant="outline"
                    disabled
                    title="Custodial stock tokens do not exist on Robinhood Chain"
                    className="w-full [&>span]:w-full [&_span]:px-4"
                  />
                </div>
                <div className="bg-section-deep-2/60 p-4 md:p-5">
                  <SwapButton label="Launch App" to="/dashboard" variant="primary" className="w-full [&>span]:w-full [&_span]:px-4" />
                </div>
              </div>
            </div>
          </div>
        </motion.div>
      </div>
    </section>
  );
}
