import { motion } from "framer-motion";
import { useReveal } from "@/i18n";

const EASE = [0.16, 1, 0.3, 1] as [number, number, number, number];

/** §4 QUOTE (black): photo + scribble + attribution, large quote, micro caption. */
export default function Quote() {
  const R = useReveal();
  return (
    <section className="grain bg-ink text-white">
      <div className="relative z-[2] mx-auto max-w-[1440px] px-4 py-16 md:px-6 md:py-24 lg:px-12 lg:py-32">
        <p className="font-mono text-[11px] uppercase tracking-[0.08em] text-white-60">Named risk, named reward</p>

        <div className="mt-12 grid gap-12 lg:grid-cols-[320px_1fr] lg:gap-20">
          {/* Left: photo + scribble + attribution */}
          <motion.div
            initial={{ opacity: 0, y: 24 }}
            whileInView={{ opacity: 1, y: 0 }}
            viewport={{ once: true, amount: 0.3 }}
            transition={{ duration: 0.8, ease: EASE }}
          >
            <div className="relative">
              <img
                src="/think-portrait.jpg"
                alt="Sealed certificate"
                className="aspect-[4/5] w-full object-cover"
              />
            </div>
            <div className="mt-8">
              <p className="text-[14px] font-semibold text-white">The Risk Framework</p>
              <p className="font-mono text-[12px] uppercase tracking-[0.08em] text-white-60">
                Published by UseCert®
              </p>
            </div>
          </motion.div>

          {/* Right: large quote + micro caption */}
          <div className="flex flex-col justify-center">
            <motion.blockquote
              className="max-w-[26ch] text-[26px] font-medium leading-[1.05] tracking-[-0.03em] md:text-[32px] lg:text-[40px]"
              initial="hidden"
              whileInView="show"
              viewport={{ once: true, amount: 0.4 }}
              variants={{ hidden: {}, show: { transition: { staggerChildren: 0.02 } } }}
            >
              {R("Every role has a named risk and a named reward. Holders are senior. Stakers are paid to be junior. Arbitrageurs are paid to care about the peg. Nothing here is free, and that is exactly why it works.")
                .map((w, i) => (
                  <motion.span
                    key={i}
                    className="inline-block whitespace-pre"
                    variants={{ hidden: { opacity: 0, y: 12 }, show: { opacity: 1, y: 0, transition: { duration: 0.4 } } }}
                  >
                    {w}{R.sep}
                  </motion.span>
                ))}
            </motion.blockquote>
            <motion.p
              className="mt-8 font-mono text-[11px] uppercase tracking-[0.08em] text-white-60"
              initial={{ opacity: 0 }}
              whileInView={{ opacity: 1 }}
              viewport={{ once: true }}
              transition={{ delay: 0.6, duration: 0.6 }}
            >
              "Named risk, named reward. That is the whole design."
            </motion.p>
          </div>
        </div>
      </div>
    </section>
  );
}
