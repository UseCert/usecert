import { useState } from "react";
import { motion } from "framer-motion";
import LetterReveal from "@/components/LetterReveal";
import ShowreelModal from "@/components/ShowreelModal";
import { scrollToHash } from "@/lib/scroll";

const EASE = [0.16, 1, 0.3, 1] as [number, number, number, number];

/** §3 "WE MINT CERTIFICATES." (light grey paper) — #mint */
export default function Mint() {
  const [showreelOpen, setShowreelOpen] = useState(false);

  return (
    <section id="mint" className="bg-paper text-ink">
      <div className="mx-auto max-w-[1440px] px-4 py-16 md:px-6 md:py-24 lg:px-12 lg:py-32">
        <div className="flex items-start justify-between gap-6">
          <span aria-hidden />
          <p className="font-mono text-[11px] uppercase tracking-[0.08em] text-ink-60">2026©</p>
        </div>

        {/* Centered headline block, lines flush right (template layout) */}
        <h2 className="mx-auto w-fit text-right text-[44px] font-semibold uppercase leading-[0.85] tracking-[-0.05em] md:text-[60px] lg:text-[78px]">
          {["We", "mint", "certificates."].map((line, i) => (
            <span key={line} className="block">
              <LetterReveal text={line} byWord stagger={0.08} delay={i * 0.15} />
            </span>
          ))}
        </h2>

        {/* Centered mono caption */}
        <motion.p
          className="mx-auto mt-10 max-w-[38ch] text-center font-mono text-[11px] uppercase leading-[1.7] tracking-[0.08em] text-ink-60"
          initial="hidden"
          whileInView="show"
          viewport={{ once: true, amount: 0.4 }}
          variants={{ hidden: {}, show: { transition: { staggerChildren: 0.03 } } }}
        >
          {[
            { t: "Where holding a stock on chain feels " },
            { t: "obvious, natural", b: true },
            { t: ", and " },
            { t: "impossible to overthink", b: true },
          ].map((seg, i) => (
            <motion.span
              key={i}
              className={seg.b ? "font-semibold text-ink" : undefined}
              variants={{ hidden: { opacity: 0, y: 10 }, show: { opacity: 1, y: 0, transition: { duration: 0.4 } } }}
            >
              {seg.t}
            </motion.span>
          ))}
        </motion.p>

        {/* Centered image, overlapping downward like the template */}
        <motion.div
          className="mx-auto mt-12 max-w-[520px]"
          initial={{ opacity: 0, y: 24 }}
          whileInView={{ opacity: 1, y: 0 }}
          viewport={{ once: true, amount: 0.3 }}
          transition={{ duration: 0.8, ease: EASE }}
        >
          <img src="/websites-silhouette.jpg" alt="Dark trading-floor tower silhouette" className="aspect-[4/5] w-full object-cover" />
        </motion.div>

        <div className="mt-10 flex flex-wrap items-center justify-between gap-6">
          <button
            type="button"
            onClick={() => scrollToHash("#vaults")}
            className="group flex items-center gap-2 text-[13px] font-semibold uppercase tracking-[0.08em] text-ink transition-colors hover:text-green-deep"
          >
            <span className="transition-transform group-hover:translate-y-0.5">↓</span> See the certificates
          </button>
          <motion.button
            type="button"
            onClick={() => setShowreelOpen(true)}
            className="flex items-center gap-2 text-[13px] font-semibold uppercase tracking-[0.08em] text-ink"
            whileHover={{ scale: 1.05 }}
            transition={{ duration: 0.2 }}
          >
            Showreel
            <span className="inline-block h-0 w-0 border-y-[6px] border-l-[12px] border-y-transparent border-l-ink" aria-hidden />
          </motion.button>
        </div>
      </div>
      <ShowreelModal open={showreelOpen} onClose={() => setShowreelOpen(false)} />
    </section>
  );
}
