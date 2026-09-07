import { motion } from "framer-motion";
import Counter from "@/components/Counter";

const EASE = [0.16, 1, 0.3, 1] as [number, number, number, number];

const STATS = [
  { value: 213, prefix: "$", suffix: "B", caption: "RWA perp volume on Robinhood Chain in Q2 2026 alone, 32.2% of all chain volume" },
  { value: 3.6, prefix: "$", suffix: "B", decimals: 1, caption: "Record RWA open interest, passing Bitcoin for the first time" },
  { value: 23, prefix: "", suffix: "/30", caption: "Of the top trading pairs are tokenized stocks and commodities" },
];

/** §7 "THE GAP" (full-bleed section-deep) - #the-gap */
export default function TheGap() {
  return (
    <section id="the-gap" className="grain section-glow relative bg-section-deep text-white">
      <div className="relative z-[2] mx-auto max-w-[1440px] px-4 py-16 md:px-6 md:py-24 lg:px-12 lg:py-32">
        <p className="font-mono text-[11px] uppercase tracking-[0.08em] text-white-60">Why now</p>

        <div className="mt-10 grid gap-14 lg:grid-cols-2 lg:gap-20">
          {/* Left: counters with dot markers */}
          <div className="flex flex-col gap-12">
            {STATS.map((s, i) => (
              <motion.div
                key={s.caption}
                className="flex gap-4"
                initial={{ opacity: 0, y: 24 }}
                whileInView={{ opacity: 1, y: 0 }}
                viewport={{ once: true, amount: 0.4 }}
                transition={{ delay: i * 0.2, duration: 0.7, ease: EASE }}
              >
                <motion.span
                  className="mt-3 h-2 w-2 shrink-0 rounded-full bg-green-bright"
                  initial={{ scale: 0 }}
                  whileInView={{ scale: [0, 1.4, 1] }}
                  viewport={{ once: true }}
                  transition={{ delay: i * 0.2 + 0.2, duration: 0.5 }}
                  aria-hidden
                />
                <div>
                  <Counter
                    end={s.value}
                    prefix={s.prefix}
                    suffix={s.suffix}
                    decimals={s.decimals ?? 0}
                    className="block text-[44px] font-semibold leading-[0.9] tracking-[-0.07em] text-green-bright md:text-[60px]"
                  />
                  <p className="mt-3 max-w-[40ch] text-[13px] leading-[1.5] text-white-60">{s.caption}</p>
                </div>
              </motion.div>
            ))}
          </div>

          {/* Right: giant statement + copy + attribution */}
          <div>
            <motion.h2
              className="text-metallic text-[32px] font-semibold uppercase leading-[0.95] tracking-[-0.04em] md:text-[44px] lg:text-[52px]"
              initial="hidden"
              whileInView="show"
              viewport={{ once: true, amount: 0.3 }}
              variants={{ hidden: {}, show: { transition: { staggerChildren: 0.05 } } }}
            >
              {"Every dollar of stock exposure here is a perp you must manage.".split(" ").map((w, i) => (
                <motion.span
                  key={i}
                  className="inline-block whitespace-pre"
                  variants={{ hidden: { y: 24, opacity: 0 }, show: { y: 0, opacity: 1, transition: { duration: 0.6, ease: EASE } } }}
                >
                  {w}{" "}
                </motion.span>
              ))}
            </motion.h2>
            <motion.p
              className="uppercase-render mt-8 max-w-[48ch] text-[14px] leading-[1.6] text-white md:text-[16px]"
              initial={{ opacity: 0, y: 20 }}
              whileInView={{ opacity: 1, y: 0 }}
              viewport={{ once: true, amount: 0.4 }}
              transition={{ delay: 0.2, duration: 0.7, ease: EASE }}
            >
              Perps cannot be held, LP'd, or lent. No custodial stock token exists on Robinhood Chain. UseCert wraps
              the deepest equity book on chain into an asset you can actually own.
            </motion.p>
            <motion.div
              className="mt-8 flex items-center gap-3"
              initial={{ opacity: 0, y: 20 }}
              whileInView={{ opacity: 1, y: 0 }}
              viewport={{ once: true }}
              transition={{ delay: 0.3, duration: 0.6, ease: EASE }}
            >
              <img src="/logo.png" alt="UseCert monogram" className="h-10 w-10 object-contain" />
              <div>
                <p className="text-[14px] font-semibold text-white">UseCert®</p>
                <p className="font-mono text-[12px] uppercase tracking-[0.08em] text-white-60">
                  Stock certificates on Robinhood Chain
                </p>
              </div>
            </motion.div>
          </div>
        </div>
      </div>
    </section>
  );
}
