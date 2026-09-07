import { motion } from "framer-motion";
import LetterReveal from "@/components/LetterReveal";
import SwapButton from "@/components/SwapButton";

const EASE = [0.16, 1, 0.3, 1] as [number, number, number, number];

/** §6 CTA BAND (black, hairline top): giant text left, green LAUNCH APP right. */
export default function CtaBand() {
  return (
    <section className="grain bg-ink text-white">
      <div className="relative z-[2] mx-auto max-w-[1440px] px-4 md:px-6 lg:px-12">
        <div className="flex flex-col gap-8 border-t hairline-dark py-14 md:flex-row md:items-center md:justify-between md:py-20">
          <h2 className="text-[40px] font-semibold uppercase leading-[0.85] tracking-[-0.05em] text-white md:text-[56px] lg:text-[68px]">
            <LetterReveal text="Ready when you are." byWord stagger={0.05} />
          </h2>
          <motion.div
            className="w-full shrink-0 sm:w-auto"
            initial={{ opacity: 0, y: 24 }}
            whileInView={{ opacity: 1, y: 0 }}

            viewport={{ once: true, amount: 0.4 }}
            transition={{ delay: 0.2, duration: 0.7, ease: EASE }}
          >
            <SwapButton label="Launch App" to="/dashboard" variant="primary" />
          </motion.div>
        </div>
      </div>
    </section>
  );
}
