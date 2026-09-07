import { motion } from "framer-motion";
import LetterReveal from "@/components/LetterReveal";
import SwapButton from "@/components/SwapButton";

const EASE = [0.16, 1, 0.3, 1] as [number, number, number, number];

const COPY_SEGMENTS: { text: string; bold?: boolean }[] = [
  { text: "UseCert is not one product. It is " },
  { text: "four ways", bold: true },
  { text: " to hold, build, backstop, and balance the first stock certificates on Robinhood Chain. Every role " },
  { text: "earns its keep", bold: true },
  { text: "." },
];

/** Sub-copy with word-fade stagger (0.03s) and bold spans, uppercase render. */
function RevealCopy() {
  const words: { word: string; bold?: boolean }[] = [];
  COPY_SEGMENTS.forEach((seg) => {
    seg.text.split(" ").forEach((w, i, arr) => {
      if (w) words.push({ word: w + (i < arr.length - 1 ? " " : ""), bold: seg.bold });
      else if (i < arr.length - 1) words.push({ word: " " });
    });
  });
  return (
    <motion.p
      className="uppercase-render mt-8 max-w-[56ch] text-[14px] leading-[1.6] text-white-60 md:text-[16px]"
      initial="hidden"
      animate="show"
      variants={{ hidden: {}, show: { transition: { staggerChildren: 0.03, delayChildren: 0.5 } } }}
    >
      {words.map((w, i) => (
        <motion.span
          key={i}
          className={w.bold ? "inline-block font-semibold text-white" : "inline-block"}
          variants={{
            hidden: { y: 14, opacity: 0 },
            show: { y: 0, opacity: 1, transition: { duration: 0.5, ease: EASE } },
          }}
        >
          {w.word.replace(/ $/, "\u00A0")}
        </motion.span>
      ))}
    </motion.p>
  );
}

/** §1 ROLES HERO (black, full-bleed): label, headline, sub-copy, pill CTA, tall image. */
export default function RolesHero() {
  return (
    <section className="grain relative -mt-16 overflow-hidden bg-ink text-white md:-mt-20">
      <div className="relative z-[2] mx-auto grid max-w-[1440px] items-center gap-12 px-4 pb-16 pt-32 md:px-6 md:pb-24 md:pt-40 lg:grid-cols-[1fr_400px] lg:gap-20 lg:px-12">
        <div>
          <motion.p
            className="font-mono text-[11px] uppercase tracking-[0.08em] text-white-60"
            initial={{ opacity: 0, y: 16 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.6, ease: EASE }}
          >
            A role for everyone
          </motion.p>
          <h1 className="mt-6 text-[44px] font-semibold uppercase leading-[0.85] tracking-[-0.05em] text-white md:text-[60px] lg:text-[78px]">
            <LetterReveal text="Pick your position." immediate delay={0.15} stagger={0.025} />
          </h1>
          <RevealCopy />
          <motion.div
            className="mt-10"
            initial={{ opacity: 0, y: 16 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ delay: 0.6, duration: 0.6, ease: EASE }}
          >
            <SwapButton label="Open Dashboard" to="/dashboard" variant="black" className="border hairline-dark" />
          </motion.div>
        </div>

        {/* Right: tall 4:5 image, clip reveal from bottom (1s) */}
        <motion.div
          className="overflow-hidden"
          initial={{ clipPath: "inset(100% 0 0 0)" }}
          animate={{ clipPath: "inset(0% 0 0 0)" }}
          transition={{ duration: 1, delay: 0.3, ease: EASE }}
        >
          <img
            src="/roles-holder.jpg"
            alt="Hand holding an engraved certificate plate"
            className="aspect-[4/5] w-full object-cover"
          />
        </motion.div>
      </div>
    </section>
  );
}
