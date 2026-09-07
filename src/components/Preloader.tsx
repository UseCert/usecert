import { useEffect, useState } from "react";
import { motion } from "framer-motion";
import LetterReveal from "./LetterReveal";

const EASE = [0.16, 1, 0.3, 1] as [number, number, number, number];

/**
 * Dignified boot screen: near-black, grain, monogram + wordmark letter
 * reveal, mono percentage counter and a hairline progress line. The parent
 * unmounts it after ~1.7s; it exits by sliding up like a curtain, revealing
 * the freshly mounted page underneath (so hero animations play in full).
 */
export default function Preloader() {
  const [pct, setPct] = useState(0);

  useEffect(() => {
    const start = performance.now();
    const id = window.setInterval(() => {
      const t = Math.min(1, (performance.now() - start) / 1400);
      // ease-out so the counter decelerates like a real load
      setPct(Math.round((1 - Math.pow(1 - t, 2.2)) * 100));
      if (t >= 1) window.clearInterval(id);
    }, 24);
    return () => window.clearInterval(id);
  }, []);

  return (
    <motion.div
      className="grain fixed inset-0 z-[100] flex flex-col bg-abyss text-white"
      initial={{ y: 0 }}
      animate={{ y: exiting ? "-100%" : 0 }}
      exit={{ y: "-100%" }}
      transition={{ duration: 0.8, ease: EASE }}
    >
      {/* Top mono row */}
      <div className="relative z-[2] flex items-center justify-between px-4 pt-5 font-mono text-[11px] uppercase tracking-[0.08em] text-white-60 md:px-12 md:pt-6">
        <motion.span initial={{ opacity: 0 }} animate={{ opacity: 1 }} transition={{ delay: 0.3, duration: 0.5 }}>
          EST. 2026 · V1.0.0
        </motion.span>
        <motion.span initial={{ opacity: 0 }} animate={{ opacity: 1 }} transition={{ delay: 0.4, duration: 0.5 }}>
          Robinhood Chain
        </motion.span>
      </div>

      {/* Center: monogram + wordmark */}
      <div className="relative z-[2] flex flex-1 flex-col items-center justify-center px-4">
        <motion.img
          src="/logo.png"
          alt="UseCert monogram"
          className="h-16 w-16 object-contain md:h-20 md:w-20"
          initial={{ opacity: 0, scale: 0.85 }}
          animate={{ opacity: 1, scale: 1 }}
          transition={{ duration: 0.7, ease: EASE }}
        />
        <h1 className="mt-6 text-[40px] font-semibold uppercase leading-[0.82] tracking-[-0.05em] text-white md:text-[64px]">
          <LetterReveal text="USECERT®" immediate delay={0.2} stagger={0.045} />
        </h1>
        <motion.p
          className="mt-5 font-mono text-[11px] uppercase tracking-[0.08em] text-white-60"
          initial={{ opacity: 0, y: 8 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ delay: 0.7, duration: 0.5, ease: EASE }}
        >
          Stock certificates · Minted on Robinhood Chain
        </motion.p>

        {/* Hairline progress */}
        <div className="mt-10 h-px w-[220px] bg-white/15 md:w-[320px]">
          <motion.div
            className="h-px origin-left bg-gradient-to-r from-[#cad0ca] via-[#859885] to-[#4c5a4d]"
            initial={{ scaleX: 0 }}
            animate={{ scaleX: 1 }}
            transition={{ duration: 1.4, ease: "easeOut" }}
          />
        </div>
      </div>

      {/* Bottom row: counter */}
      <div className="relative z-[2] flex items-end justify-between px-4 pb-5 font-mono text-[11px] uppercase tracking-[0.08em] text-white-60 md:px-12 md:pb-6">
        <span>Loading vault</span>
        <span className="text-[28px] font-semibold leading-none tracking-[-0.03em] text-white md:text-[40px]">
          {pct}%
        </span>
      </div>
    </motion.div>
  );
}
