import { motion } from "framer-motion";
import Counter from "@/components/Counter";

const EASE = [0.16, 1, 0.3, 1] as [number, number, number, number];

const STATS = [
  { end: 213, prefix: "$", suffix: "B", caption: "RWA perp volume, Q2 2026" },
  { end: 52, prefix: "", suffix: "%", caption: "Of weekly volume was RWAs, week of July 13" },
  { end: 3.6, prefix: "$", suffix: "B", decimals: 1, caption: "Record RWA open interest, passing Bitcoin" },
  { end: 23, prefix: "", suffix: "/30", caption: "Top pairs that are tokenized stocks and commodities" },
];

/** §3 COUNTER STATS (black, hairline-divided row): 4 animated counters. */
export default function Stats() {
  return (
    <section className="grain bg-ink text-white">
      <div className="relative z-[2] mx-auto max-w-[1440px] px-4 pb-16 md:px-6 md:pb-24 lg:px-12 lg:pb-32">
        <div className="grid border-t hairline-dark sm:grid-cols-2 lg:grid-cols-4">
          {STATS.map((s, i) => (
            <motion.div
              key={s.caption}
              className="border-b hairline-dark py-10 sm:px-8 sm:first:pl-0 lg:border-b-0 lg:py-12 lg:[&:not(:first-child)]:border-l"
              initial={{ opacity: 0, y: 24 }}
              whileInView={{ opacity: 1, y: 0 }}
              viewport={{ once: true, amount: 0.4 }}
              transition={{ delay: i * 0.15, duration: 0.7, ease: EASE }}
            >
              <Counter
                end={s.end}
                prefix={s.prefix}
                suffix={s.suffix}
                decimals={s.decimals ?? 0}
                className="block text-[44px] font-semibold leading-[0.9] tracking-[-0.07em] text-green-bright md:text-[60px] lg:text-[56px]"
              />
              <p className="mt-4 max-w-[28ch] text-[13px] leading-[1.5] text-white-60">{s.caption}</p>
            </motion.div>
          ))}
        </div>
      </div>
    </section>
  );
}
