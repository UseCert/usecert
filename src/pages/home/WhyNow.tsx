import { motion } from "framer-motion";
import { ArrowUpRight } from "lucide-react";
import { Link } from "@/lib/router-compat";
import Counter from "@/components/Counter";

const EASE = [0.16, 1, 0.3, 1] as [number, number, number, number];

/** §2 "HOLD THE STOCK. NOT THE PERP." (full-bleed section-deep) - #why-now */
export default function WhyNow() {
  return (
    <section id="why-now" className="grain section-glow relative overflow-hidden bg-section-deep text-white">
      <div className="relative z-[2] mx-auto max-w-[1440px] px-4 py-16 md:px-6 md:py-24 lg:px-12 lg:py-32">
        {/* Top stat row */}
        <div className="flex flex-wrap items-center justify-between gap-3 font-mono text-[11px] uppercase tracking-[0.08em] text-white-60">
          {["Q2 2026", "$213B RWA perp volume", "Robinhood Chain©"].map((s, i) => (
            <motion.span
              key={s}
              initial={{ opacity: 0 }}
              whileInView={{ opacity: 1 }}
              viewport={{ once: true }}
              transition={{ delay: i * 0.1, duration: 0.5 }}
            >
              {s}
            </motion.span>
          ))}
        </div>

        {/* Paragraph top-left + giant headline top-right (template layout).
            whileInView lives on the h2: the translated child is fully clipped
            by its overflow-hidden parent, so IntersectionObserver would never
            fire on the child itself. */}
        <div className="mt-10 grid gap-10 lg:grid-cols-2 lg:gap-16">
          <motion.p
            className="max-w-[36ch] font-mono text-[11px] uppercase leading-[1.7] tracking-[0.08em] text-white-60"
            initial={{ opacity: 0, y: 24 }}
            whileInView={{ opacity: 1, y: 0 }}
            viewport={{ once: true, amount: 0.3 }}
            transition={{ duration: 0.7, ease: EASE }}
          >
            Robinhood Chain became a major venue for trading stocks on chain. But every dollar of that equity
            exposure is a leveraged perp you must manage: funding, margin, liquidations. You cannot simply hold a
            stock on Robinhood Chain. Until now.
          </motion.p>

          <motion.h2
            className="text-right text-[44px] font-semibold uppercase leading-[0.85] tracking-[-0.05em] md:text-[60px] lg:text-[78px]"
            initial="hidden"
            whileInView="show"
            viewport={{ once: true, amount: 0.25 }}
          >
            {["Hold the stock.", "Not the perp."].map((line, li) => (
              <span key={line} className="block overflow-hidden">
                <motion.span
                  className="text-metallic block"
                  variants={{
                    hidden: { y: "100%", opacity: 0 },
                    show: { y: 0, opacity: 1, transition: { delay: li * 0.12, duration: 0.8, ease: EASE } },
                  }}
                >
                  {line}
                </motion.span>
              </span>
            ))}
          </motion.h2>
        </div>

        {/* Centered vertical image (trigger on unclipped parent to avoid clip deadlock) */}
        <motion.div
          className="mx-auto mt-14 max-w-[540px]"
          initial="hidden"
          whileInView="show"
          viewport={{ once: true, amount: 0.3 }}
        >
          <motion.div
            className="overflow-hidden"
            variants={{
              hidden: { clipPath: "inset(100% 0 0 0)" },
              show: { clipPath: "inset(0% 0 0 0)", transition: { duration: 1, ease: EASE } },
            }}
          >
            <img src="/why-now-door.jpg" alt="Light cutting through a door left ajar" className="aspect-[4/5] w-full object-cover" />
          </motion.div>
        </motion.div>

        {/* Bottom row: arrow link + counter */}
        <div className="mt-10 flex flex-wrap items-end justify-between gap-8">
          <Link
            to="/about"
            className="group flex items-center gap-2 text-[13px] font-semibold uppercase tracking-[0.08em] text-white transition-colors hover:text-green-bright"
          >
            Why now
            <ArrowUpRight size={16} className="transition-transform group-hover:translate-x-0.5 group-hover:-translate-y-0.5" />
          </Link>
          <div className="max-w-[360px]">
            <Counter end={52} suffix="%" className="text-[60px] font-semibold leading-[0.9] tracking-[-0.07em] text-green-bright lg:text-[78px]" />
            <p className="mt-3 text-[13px] leading-[1.5] text-white-60">
              Of weekly volume was tokenized RWAs the week of July 13, the first time they out-traded every crypto
              category
            </p>
          </div>
        </div>
      </div>
    </section>
  );
}
