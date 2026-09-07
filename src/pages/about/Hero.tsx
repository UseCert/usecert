import { motion } from "framer-motion";
import LetterReveal from "@/components/LetterReveal";
import SwapButton from "@/components/SwapButton";

const EASE = [0.16, 1, 0.3, 1] as [number, number, number, number];

/** §1 ABOUT HERO (black, full-bleed): label, giant headline, pill CTA, tall portrait. */
export default function AboutHero() {
  return (
    <section className="grain relative -mt-16 overflow-hidden bg-ink text-white md:-mt-20">
      <div className="relative z-[2] mx-auto grid max-w-[1440px] items-center gap-12 px-4 pb-16 pt-32 md:px-6 md:pb-24 md:pt-40 lg:grid-cols-[1fr_400px] lg:gap-20 lg:px-12">
        <div>
          <motion.p
            className="font-mono text-[11px] uppercase tracking-[0.08em] text-white-60"
            initial={{ opacity: 0, y: 16 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.6, ease: EASE }}
          >
            Why UseCert.
          </motion.p>
          <h1 className="mt-6 max-w-[14ch] text-[44px] font-semibold uppercase leading-[0.85] tracking-[-0.05em] text-white md:text-[60px] lg:text-[78px]">
            <LetterReveal text="We mint the asset the market forgot to build." immediate byWord delay={0.15} stagger={0.05} />
          </h1>
          <motion.div
            className="mt-10"
            initial={{ opacity: 0, y: 16 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ delay: 0.5, duration: 0.6, ease: EASE }}
          >
            <SwapButton label="Launch App" to="/dashboard" variant="black" className="border hairline-dark" />
          </motion.div>
        </div>

        {/* Right: tall 4:5 portrait, clip reveal from bottom (1s) */}
        <motion.div
          className="overflow-hidden"
          initial={{ clipPath: "inset(100% 0 0 0)" }}
          animate={{ clipPath: "inset(0% 0 0 0)" }}
          transition={{ duration: 1, delay: 0.3, ease: EASE }}
        >
          <img
            src="/think-portrait.jpg"
            alt="Sealed certificate, silver-green grade"
            className="aspect-[4/5] w-full object-cover"
          />
        </motion.div>
      </div>
    </section>
  );
}
