import { motion } from "framer-motion";

const EASE = [0.16, 1, 0.3, 1] as [number, number, number, number];

interface Paragraph {
  lead: string;
  rest: string;
}

const PARAGRAPHS: Paragraph[] = [
  {
    lead: "Robinhood Chain did $213B of RWA perp volume in Q2 2026 alone, out-trading Bitcoin.",
    rest: "The week of July 13, tokenized assets were 52% of weekly volume, the first time they out-traded every crypto category. And none of it was holdable.",
  },
  {
    lead: "When we decide whether a mechanism stays or goes, the question is never 'does it sound clever?'",
    rest: "It is 'does the solvency math hold at every attestation, in public, with the age of the proof next to it?' If the answer is no, it goes.",
  },
  {
    lead: "The pattern is proven. Delta-backed synthetic assets are the most battle-tested design in DeFi:",
    rest: "Synthetix synths, Ethena's delta-neutral reserve with an insurance buffer. UseCert applies that pattern to the deepest equity book on chain, and names its risks plainly.",
  },
];

/** §2 STORY (black): three paragraphs, white lead sentences on white-60 body. */
export default function Story() {
  return (
    <section className="grain bg-ink text-white">
      <div className="relative z-[2] mx-auto max-w-[1440px] px-4 py-16 md:px-6 md:py-24 lg:px-12 lg:py-32">
        <p className="font-mono text-[11px] uppercase tracking-[0.08em] text-white-60">The story</p>
        <div className="mt-10 flex max-w-[68ch] flex-col gap-8">
          {PARAGRAPHS.map((p, i) => (
            <motion.p
              key={p.lead}
              className="text-[16px] leading-[1.55] text-white-60 md:text-[18px]"
              initial={{ opacity: 0, y: 24 }}
              whileInView={{ opacity: 1, y: 0 }}
              viewport={{ once: true, amount: 0.3 }}
              transition={{ delay: i * 0.15, duration: 0.7, ease: EASE }}
            >
              <span className="text-white">{p.lead} </span>
              {p.rest}
            </motion.p>
          ))}
        </div>
      </div>
    </section>
  );
}
