import { useState } from "react";
import { motion } from "framer-motion";
import LetterReveal from "@/components/LetterReveal";
import Faq from "./home/Faq";
import StackCards from "./vaults/StackCards";
import { VAULTS } from "./vaults/data";
import { cn } from "@/lib/utils";

const EASE = [0.16, 1, 0.3, 1] as [number, number, number, number];

type Filter = "all" | "stock" | "index" | "live" | "roadmap";

const TABS: { id: Filter; label: string }[] = [
  { id: "all", label: "All" },
  { id: "stock", label: "Single Stock" },
  { id: "index", label: "Index" },
  { id: "live", label: "Live" },
  { id: "roadmap", label: "Roadmap" },
];

function matches(filter: Filter, vault: (typeof VAULTS)[number]): boolean {
  switch (filter) {
    case "all":
      return true;
    case "stock":
      return vault.category === "stock";
    case "index":
      return vault.category === "index";
    case "live":
      return vault.status === "LIVE";
    case "roadmap":
      return vault.status === "SOON";
  }
}

function count(filter: Filter): number {
  return VAULTS.filter((v) => matches(filter, v)).length;
}

/** /vaults index: header + filter tabs + sticky-stacking vault cards + shared FAQ. */
export default function Vaults() {
  const [filter, setFilter] = useState<Filter>("all");
  const cards = VAULTS.filter((v) => matches(filter, v));

  return (
    <>
      {/* Section 1: header (black) */}
      <section className="grain bg-ink text-white">
        <div className="relative z-[2] mx-auto max-w-[1440px] px-4 pb-16 pt-16 md:px-6 md:pb-24 md:pt-24 lg:px-12 lg:pb-32 lg:pt-32">
          <div className="flex items-start justify-between gap-6">
            <p className="font-mono text-[11px] uppercase tracking-[0.08em] text-white-60">Certificates</p>
            <p className="font-mono text-[11px] uppercase tracking-[0.08em] text-white-60">2026&copy;</p>
          </div>

          <div className="mt-10 grid gap-10 lg:grid-cols-2 lg:gap-20">
            <h1 className="text-[44px] font-semibold uppercase leading-[0.85] tracking-[-0.05em] md:text-[60px] lg:text-[78px]">
              <LetterReveal text="Selected vaults" delay={0.3} immediate />
            </h1>
            <motion.p
              className="max-w-[52ch] self-end text-[26px] font-medium leading-[1.05] tracking-[-0.03em] text-white md:text-[32px] lg:text-[40px]"
              initial={{ opacity: 0, y: 20 }}
              animate={{ opacity: 1, y: 0 }}
              transition={{ delay: 0.5, duration: 0.7, ease: EASE }}
            >
              Per-asset vaults, factory-deployed on Robinhood Chain. Each one mints a certificate backed by exactly
              one token's worth of perp exposure plus tUSDG margin.
            </motion.p>
          </div>

          {/* Filter tabs */}
          <div className="mt-14 flex flex-wrap items-center gap-2 border-t hairline-dark pt-8 md:gap-3">
            {TABS.map((tab, i) => {
              const active = filter === tab.id;
              return (
                <motion.button
                  key={tab.id}
                  type="button"
                  onClick={() => setFilter(tab.id)}
                  aria-pressed={active}
                  className={cn(
                    "rounded-full border px-4 py-2 font-mono text-[11px] uppercase tracking-[0.08em] transition-colors",
                    active
                      ? "border-white bg-white text-ink"
                      : "hairline-dark text-white-60 hover:border-white/40 hover:text-white",
                  )}
                  initial={{ opacity: 0, x: -12 }}
                  animate={{ opacity: 1, x: 0 }}
                  transition={{ delay: 0.6 + i * 0.05, duration: 0.4, ease: EASE }}
                >
                  {tab.label}
                  <span className={cn("ml-2", active ? "text-ink-60" : "text-white-60")}>({count(tab.id)})</span>
                </motion.button>
              );
            })}
          </div>
        </div>
      </section>

      {/* Section 2: sticky-stacking vault cards (black) */}
      <section className="grain relative bg-ink text-white">
        <StackCards key={filter} cards={cards} />
      </section>

      {/* Section 3: shared FAQ (light grey paper) */}
      <Faq />
    </>
  );
}
