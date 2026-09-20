import { motion } from "framer-motion";
import { Link } from "@/lib/router-compat";
import LetterReveal from "@/components/LetterReveal";
import SwapButton from "@/components/SwapButton";

const EASE = [0.16, 1, 0.3, 1] as [number, number, number, number];

const CARDS = [
  {
    title: "RWA perps did $213B in Q2. None of it is holdable.",
    date: "Jul 20, 2026",
    image: "/learn-1.jpg",
    to: "/learn/rwa-perps-213b-none-holdable",
  },
  {
    title: "Delta backing, explained without the math",
    date: "Jul 20, 2026",
    image: "/learn-2.jpg",
    to: "/learn/delta-backing-explained",
  },
  {
    title: "Funding: buffered, then fee'd, never hidden",
    date: "Jul 18, 2026",
    image: "/learn-3.jpg",
    to: "/learn/funding-buffered-then-feed",
  },
  {
    title: "Why holders are senior to stakers",
    date: "Jul 14, 2026",
    image: "/learn-4.jpg",
    to: "/learn/holders-are-senior",
  },
];

/** §13 RESEARCH PREVIEW "RESEARCH AND UPDATES." (light grey paper) - #research */
export default function Research() {
  return (
    <section id="research" className="border-t hairline-light bg-paper text-ink">
      <div className="mx-auto max-w-[1440px] px-4 py-16 md:px-6 md:py-24 lg:px-12 lg:py-32">
        <div className="flex flex-wrap items-end justify-between gap-8">
          <SwapButton label="See More" to="/learn" variant="black" />
          <h2 className="text-right text-[44px] font-semibold uppercase leading-[0.85] tracking-[-0.05em] md:text-[60px] lg:text-[78px]">
            <LetterReveal text="Research and updates." byWord stagger={0.05} />
          </h2>
        </div>

        <div className="mt-14 grid gap-8 sm:grid-cols-2 lg:grid-cols-4 lg:gap-6">
          {CARDS.map((card, i) => (
            <motion.div
              key={card.title}
              initial={{ opacity: 0, y: 24 }}
              whileInView={{ opacity: 1, y: 0 }}
              viewport={{ once: true, amount: 0.2 }}
              transition={{ delay: i * 0.1, duration: 0.7, ease: EASE }}
            >
              <Link to={card.to} className="group block">
                <div className="relative aspect-[16/10] overflow-hidden">
                  <img
                    src={card.image}
                    alt=""
                    className="h-full w-full object-cover transition-transform duration-500 group-hover:scale-105"
                  />
                  <span
                    className="pointer-events-none absolute inset-0 bg-green-deep/0 transition-colors duration-500 group-hover:bg-green-deep/20"
                    aria-hidden
                  />
                </div>
                <h3 className="relative mt-4 inline text-[16px] font-semibold leading-[1.3] tracking-[-0.01em]">
                  {card.title}
                  <span className="absolute bottom-0 left-0 h-px w-0 bg-green-deep transition-all duration-300 group-hover:w-full" aria-hidden />
                </h3>
                <p className="mt-2 font-mono text-[11px] uppercase tracking-[0.08em] text-ink-60">{card.date}</p>
              </Link>
            </motion.div>
          ))}
        </div>
      </div>
    </section>
  );
}
