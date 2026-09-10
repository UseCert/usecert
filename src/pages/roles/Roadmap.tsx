import { motion } from "framer-motion";
import { cn } from "@/lib/utils";

const EASE = [0.16, 1, 0.3, 1] as [number, number, number, number];

const PHASES = [
  {
    tag: "C1",
    status: "Live",
    live: true,
    title: "uTSLA, uSPY, uQQQ + uNVDA vaults",
    copy: "Four mirrors live on testnet. Mint, redeem, and the public solvency dashboard.",
  },
  {
    tag: "C2",
    status: "Next",
    live: false,
    title: "More single-stock mirrors",
    copy: "LP incentives and lending-market integrations. Only assets with a live perp market on the venue.",
  },
  {
    tag: "C3",
    status: null,
    live: false,
    title: "Token genesis",
    copy: "Staked insurance buffer and the funding-surplus flywheel.",
  },
  {
    tag: "C4",
    status: null,
    live: false,
    title: "Structured wrappers",
    copy: "Auto-roll DCA vaults and covered-call-style vaults on top of certificates.",
  },
];

/** §5 ROADMAP STRIP (black, hairline-separated): C1-C4 columns. */
export default function Roadmap() {
  return (
    <section className="grain bg-ink text-white">
      <div className="relative z-[2] mx-auto max-w-[1440px] px-4 pb-16 md:px-6 md:pb-24 lg:px-12 lg:pb-32">
        <p className="font-mono text-[11px] uppercase tracking-[0.08em] text-white-60">Roadmap</p>
        <div className="mt-8 grid border-t hairline-dark sm:grid-cols-2 lg:grid-cols-4">
          {PHASES.map((p, i) => (
            <motion.div
              key={p.tag}
              className={cn(
                "group border-b hairline-dark py-8 transition-colors duration-300 hover:bg-section-deep-2",
                "sm:px-6 sm:first:pl-0 lg:border-b-0 lg:py-10 lg:[&:not(:first-child)]:border-l",
              )}
              initial={{ opacity: 0, y: 24 }}
              whileInView={{ opacity: 1, y: 0 }}
              viewport={{ once: true, amount: 0.3 }}
              transition={{ delay: i * 0.1, duration: 0.6, ease: EASE }}
            >
              <p className="flex items-center gap-2 font-mono text-[11px] uppercase tracking-[0.08em] text-white-60">
                {p.tag}
                {p.status && (
                  <span
                    className={cn(
                      "inline-flex items-center gap-1.5",
                      p.live ? "text-green-bright" : "text-white-60",
                    )}
                  >
                    · {p.status}
                    {p.live && (
                      <motion.span
                        className="h-1.5 w-1.5 rounded-full bg-green-bright"
                        animate={{ opacity: [1, 0.3, 1] }}
                        transition={{ duration: 1.6, repeat: Infinity, ease: "easeInOut" }}
                        aria-hidden
                      />
                    )}
                  </span>
                )}
              </p>
              <p className="mt-4 text-[20px] font-semibold uppercase tracking-[-0.03em] text-white">{p.title}</p>
              <p className="mt-3 text-[13px] leading-[1.5] text-white-60">{p.copy}</p>
            </motion.div>
          ))}
        </div>
      </div>
    </section>
  );
}
