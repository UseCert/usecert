import { motion } from "framer-motion";
import LetterReveal from "@/components/LetterReveal";
import SwapButton from "@/components/SwapButton";
import Faq from "./home/Faq";

const EASE = [0.16, 1, 0.3, 1] as [number, number, number, number];

/**
 * 404 (/404): 1:1 replica of the template /404. Black page, centered stack
 * (micro label, giant headline, copy, back button), then shared FAQ + footer.
 */
export default function NotFound() {
  return (
    <>
      <section className="grain relative -mt-16 flex min-h-[100dvh] items-center overflow-hidden bg-ink text-white md:-mt-20">
        {/* Optional dimmed 404 plate backdrop, grain sits above via .grain */}
        <img
          src="/404-plate.jpg"
          alt=""
          aria-hidden
          className="pointer-events-none absolute inset-0 h-full w-full object-cover opacity-20"
        />
        <div className="relative z-[2] mx-auto flex w-full max-w-[1440px] flex-col items-center px-4 py-24 text-center md:px-6 lg:px-12">
          <motion.p
            className="font-mono text-[11px] uppercase tracking-[0.08em] text-white-60"
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            transition={{ duration: 0.5 }}
          >
            404 Error
          </motion.p>
          <h1 className="mt-6 text-[52px] font-semibold uppercase leading-[0.82] tracking-[-0.05em] md:text-[68px] lg:text-[92px]">
            <LetterReveal text="Page not found" stagger={0.03} immediate />
          </h1>
          <motion.p
            className="mt-8 max-w-[46ch] text-[16px] leading-[1.55] text-white-60"
            initial={{ opacity: 0, y: 16 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ delay: 0.4, duration: 0.6, ease: EASE }}
          >
            The link you followed doesn't lead anywhere. The vault, however, is exactly where you
            left it.
          </motion.p>
          <motion.div
            className="mt-10"
            initial={{ opacity: 0, y: 16 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ delay: 0.5, duration: 0.6, ease: EASE }}
          >
            <SwapButton label="Back to homepage" to="/" variant="primary" />
          </motion.div>
        </div>
      </section>

      {/* Below the fold: shared FAQ (identical to home) + footer via Layout */}
      <Faq />
    </>
  );
}
