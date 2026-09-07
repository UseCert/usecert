import { motion } from "framer-motion";
import { ArrowUpRight } from "lucide-react";
import { Link } from "@/lib/router-compat";
import Counter from "@/components/Counter";
import LetterReveal from "@/components/LetterReveal";

const EASE = [0.16, 1, 0.3, 1] as [number, number, number, number];

/** §5 "WHY USECERT?" (light grey paper) - #why-usecert */
export default function WhyUseCert() {
  return (
    <section id="why-usecert" className="bg-paper text-ink">
      <div className="mx-auto max-w-[1440px] px-4 py-16 md:px-6 md:py-24 lg:px-12 lg:py-32">
        <p className="font-mono text-[11px] uppercase tracking-[0.08em] text-ink-60">Why UseCert?</p>
        <h2 className="mt-4 max-w-[14ch] text-[44px] font-semibold uppercase leading-[0.85] tracking-[-0.05em] md:text-[60px] lg:text-[78px]">
          <LetterReveal text="Backed every block" byWord stagger={0.05} />
        </h2>

        <div className="mt-14 grid gap-10 lg:grid-cols-2 lg:gap-16">
          {/* Photo with monogram overlay */}
          <motion.div
            className="relative overflow-hidden"
            initial={{ clipPath: "inset(0 100% 0 0)" }}
            whileInView={{ clipPath: "inset(0 0% 0 0)" }}
            viewport={{ once: true, amount: 0.3 }}
            transition={{ duration: 1, ease: EASE }}
          >
            <img src="/why-us-bars.jpg" alt="Engraved silver bars stamped uTSLA 1.0" className="aspect-[14/9] w-full object-cover" />
            <img src="/logo.png" alt="" aria-hidden className="absolute bottom-4 left-4 h-10 w-10 object-contain" />
          </motion.div>

          {/* Stat cards, overlapping offset */}
          <div className="flex flex-col justify-center gap-6">
            <motion.div
              className="bg-ink p-8 text-white transition-all duration-300 hover:-translate-y-1 hover:shadow-2xl md:mr-16"
              initial={{ opacity: 0, y: 32 }}
              whileInView={{ opacity: 1, y: 0 }}
              viewport={{ once: true, amount: 0.4 }}
              transition={{ duration: 0.7, ease: EASE }}
            >
              <p className="font-mono text-[11px] uppercase tracking-[0.08em] text-white-60">
                Delta target per vault, provable on chain every block
              </p>
              <Counter end={1} prefix="/" suffix=".0" decimals={0} className="mt-4 block text-[60px] font-semibold leading-[0.9] tracking-[-0.07em] text-green-bright lg:text-[78px]" />
              <Link to="/dashboard" className="group mt-6 inline-flex items-center gap-2 text-[13px] font-semibold uppercase tracking-[0.08em] text-white transition-colors hover:text-green-bright">
                Solvency
                <ArrowUpRight size={16} className="transition-transform group-hover:translate-x-0.5 group-hover:-translate-y-0.5" />
              </Link>
            </motion.div>

            <motion.div
              className="bg-white p-8 text-ink transition-all duration-300 hover:-translate-y-1 hover:shadow-2xl md:ml-16"
              initial={{ opacity: 0, y: 32 }}
              whileInView={{ opacity: 1, y: 0 }}
              viewport={{ once: true, amount: 0.4 }}
              transition={{ duration: 0.7, delay: 0.15, ease: EASE }}
            >
              <p className="font-mono text-[11px] uppercase tracking-[0.08em] text-ink-60">
                Mint and redeem at oracle price, redemption is never gated
              </p>
              <Counter end={24} prefix="/" suffix="/7" className="mt-4 block text-[60px] font-semibold leading-[0.9] tracking-[-0.07em] lg:text-[78px]" />
              <Link to="/dashboard" className="group mt-6 inline-flex items-center gap-2 text-[13px] font-semibold uppercase tracking-[0.08em] text-ink transition-colors hover:text-green-deep">
                Launch App
                <ArrowUpRight size={16} className="transition-transform group-hover:translate-x-0.5 group-hover:-translate-y-0.5" />
              </Link>
            </motion.div>
          </div>
        </div>
      </div>
    </section>
  );
}
