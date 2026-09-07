import { useState } from "react";
import { AnimatePresence, motion } from "framer-motion";
import { ArrowLeft, ArrowRight } from "lucide-react";
import LetterReveal from "@/components/LetterReveal";
import SwapButton from "@/components/SwapButton";
import { cn } from "@/lib/utils";

const EASE = [0.16, 1, 0.3, 1] as [number, number, number, number];

const SLIDES = [
  {
    quote:
      "Perps are a job. A certificate is an asset. I minted uTSLA, LP'd it against USDC, and stopped babysitting funding.",
    role: "Holder since C1",
    image: "/testimonial-1.jpg",
  },
  {
    quote:
      "It is the first equity-shaped asset on Robinhood Chain. We listed it as collateral the same week the vault opened.",
    role: "DeFi Builder",
    image: "/testimonial-2.jpg",
  },
  {
    quote:
      "Mint and redeem against the DEX price keeps the peg tight. The buffer math is public, so the trade is honest.",
    role: "Arbitrageur",
    image: "/testimonial-3.jpg",
  },
];

/** §11 TESTIMONIALS "WHAT HOLDERS SAY." (light grey paper) - #signals */
export default function Testimonials() {
  const [index, setIndex] = useState(0);
  const prev = () => setIndex((i) => (i - 1 + SLIDES.length) % SLIDES.length);
  const next = () => setIndex((i) => (i + 1) % SLIDES.length);
  const slide = SLIDES[index];

  return (
    <section id="signals" className="bg-paper text-ink">
      <div className="mx-auto max-w-[1440px] px-4 py-16 md:px-6 md:py-24 lg:px-12 lg:py-32">
        <div className="flex items-start justify-between gap-6">
          <h2 className="max-w-[12ch] text-[44px] font-semibold uppercase leading-[0.85] tracking-[-0.05em] md:text-[60px] lg:text-[78px]">
            <LetterReveal text="What holders say." byWord stagger={0.05} />
          </h2>
          <p className="font-mono text-[11px] uppercase tracking-[0.08em] text-ink-60">Signals</p>
        </div>

        <p className="mt-8 max-w-[52ch] text-[16px] leading-[1.55]">
          We let the <strong>math speak</strong>. But sometimes the people using it have{" "}
          <strong>something to add</strong>.
        </p>

        <div className="relative mt-14">
          {/* Giant quote glyph */}
          <motion.span
            className="pointer-events-none absolute -top-16 left-0 select-none text-[220px] font-semibold leading-none text-ink/10"
            animate={{ y: [ -10, 10, -10 ] }}
            transition={{ duration: 8, repeat: Infinity, ease: "easeInOut" }}
            aria-hidden
          >
            "
          </motion.span>

          <div className="relative grid items-center gap-10 lg:grid-cols-[1fr_360px] lg:gap-20">
            <AnimatePresence mode="wait">
              <motion.blockquote
                key={index}
                initial={{ opacity: 0, x: 24 }}
                animate={{ opacity: 1, x: 0 }}
                exit={{ opacity: 0, x: -24 }}
                transition={{ duration: 0.5, ease: EASE }}
                className="text-[22px] font-medium leading-[1.2] tracking-[-0.02em] md:text-[28px]"
              >
                "{slide.quote}"
                <footer className="mt-6 flex items-center gap-3">
                  <span className="h-[8px] w-[8px] bg-green-deep" aria-hidden />
                  <p className="font-mono text-[12px] uppercase tracking-[0.08em] text-ink-60">{slide.role}</p>
                </footer>
              </motion.blockquote>
            </AnimatePresence>

            <AnimatePresence mode="wait">
              <motion.img
                key={index}
                src={slide.image}
                alt={slide.role}
                className="aspect-[4/5] w-full max-w-[360px] object-cover"
                initial={{ opacity: 0, x: 24 }}
                animate={{ opacity: 1, x: 0 }}
                exit={{ opacity: 0, x: -24 }}
                transition={{ duration: 0.5, ease: EASE }}
              />
            </AnimatePresence>
          </div>

          {/* Arrows + dots */}
          <div className="mt-10 flex items-center gap-4">
            <button
              type="button"
              onClick={prev}
              aria-label="Previous testimonial"
              className="flex h-11 w-11 items-center justify-center border hairline-light text-ink transition-colors hover:bg-ink hover:text-white"
            >
              <ArrowLeft size={16} />
            </button>
            <button
              type="button"
              onClick={next}
              aria-label="Next testimonial"
              className="flex h-11 w-11 items-center justify-center border hairline-light text-ink transition-colors hover:bg-ink hover:text-white"
            >
              <ArrowRight size={16} />
            </button>
            <div className="ml-2 flex gap-2">
              {SLIDES.map((_, i) => (
                <span key={i} className={cn("h-[6px] w-[6px]", i === index ? "bg-green-deep" : "bg-ink/20")} aria-hidden />
              ))}
            </div>
          </div>
        </div>

        <div className="mt-12">
          <SwapButton label="See More" to="/learn" variant="black" />
        </div>
      </div>
    </section>
  );
}
