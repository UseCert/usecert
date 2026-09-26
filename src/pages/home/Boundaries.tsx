import { motion } from "framer-motion";
import { ArrowUpRight } from "lucide-react";
import { Link } from "@/lib/router-compat";
import Scribble from "@/components/Scribble";

const EASE = [0.16, 1, 0.3, 1] as [number, number, number, number];

/** §9 "HONEST BOUNDARIES" (black) - #boundaries */
export default function Boundaries() {
  return (
    <section id="boundaries" className="grain bg-ink text-white">
      <div className="relative z-[2] mx-auto max-w-[1440px] px-4 py-16 md:px-6 md:py-24 lg:px-12 lg:py-32">
        <p className="font-mono text-[11px] uppercase tracking-[0.08em] text-white-60">Honest boundaries</p>

        <div className="mt-12 grid gap-12 lg:grid-cols-[320px_1fr] lg:gap-20">
          {/* Left: photo + scribble + attribution */}
          <motion.div
            initial={{ opacity: 0, y: 24 }}
            whileInView={{ opacity: 1, y: 0 }}
            viewport={{ once: true, amount: 0.3 }}
            transition={{ duration: 0.8, ease: EASE }}
          >
            <div className="relative">
              <img src="/think-portrait.jpg" alt="Sealed certificate" className="aspect-[4/5] w-full object-cover" />
              <Scribble className="absolute -bottom-6 -right-2 w-[60%] sm:-right-8 sm:w-[70%]" onScroll delay={0.3} />
            </div>
            <div className="mt-8">
              <p className="text-[14px] font-semibold text-white">The Risk Framework</p>
              <p className="font-mono text-[12px] uppercase tracking-[0.08em] text-white-60">
                Published by UseCert®
              </p>
            </div>
          </motion.div>

          {/* Center: large quote + micro caption */}
          <div className="flex flex-col justify-center">
            <motion.blockquote
              className="max-w-[24ch] text-[26px] font-medium leading-[1.05] tracking-[-0.03em] md:text-[32px] lg:text-[40px]"
              initial="hidden"
              whileInView="show"
              viewport={{ once: true, amount: 0.4 }}
              variants={{ hidden: {}, show: { transition: { staggerChildren: 0.02 } } }}
            >
              {"Certificates are synthetic, and we say that first. Backed by perp positions and tUSDG margin, not custody of shares. No dividends, no shareholder rights. The solvency dashboard is public and the stress parameters are published, because trust here should never require trusting us."
                .split(" ")
                .map((w, i) => (
                  <motion.span
                    key={i}
                    className="inline-block whitespace-pre"
                    variants={{ hidden: { opacity: 0, y: 12 }, show: { opacity: 1, y: 0, transition: { duration: 0.4 } } }}
                  >
                    {w}{" "}
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
              "Solvency is public. Risks are named. Infrastructure, not advice."
            </motion.p>

            {/* The milestones page belongs HERE rather than in a feature strip: this is the
                section that says what the project does not claim, and "what does not work
                yet" is the same statement continued. A reader who has just read the
                boundaries is exactly the one who wants the list. */}
            <motion.div
              initial={{ opacity: 0, y: 12 }}
              whileInView={{ opacity: 1, y: 0 }}
              viewport={{ once: true }}
              transition={{ delay: 0.7, duration: 0.6, ease: EASE }}
              className="mt-10 border-t hairline-dark pt-8"
            >
              <p className="max-w-[46ch] text-[15px] leading-[1.6] text-white-60">
                The same applies to the build itself. What works today, what is being built,
                and what has to be true before mainnet is published in full — with no dates,
                and a way to check every claim.
              </p>
              <Link
                to="/roadmap"
                className="group mt-5 inline-flex items-center gap-2 border border-white/20 px-5 py-3 font-mono text-[11px] uppercase tracking-[0.08em] text-white transition-colors hover:border-green-bright/50 hover:text-green-bright"
              >
                See the milestones
                <ArrowUpRight
                  size={14}
                  className="transition-transform group-hover:-translate-y-0.5 group-hover:translate-x-0.5"
                />
              </Link>
            </motion.div>
          </div>
        </div>
      </div>
    </section>
  );
}
