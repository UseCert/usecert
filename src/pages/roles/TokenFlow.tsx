import { motion } from "framer-motion";
import { ArrowUpRight } from "lucide-react";
import Counter from "@/components/Counter";
import { useReveal } from "@/i18n";
import { explorerAddressUrl } from "@/chain/config";
import { CERT_TOKEN_ADDRESS, HAS_CERT_TOKEN } from "@/chain/deployment";

const EASE = [0.16, 1, 0.3, 1] as [number, number, number, number];

/**
 * THE INTENDED SPLIT, FOR A TOKEN THAT NOW EXISTS AND A FEE FLOW THAT DOES NOT.
 *
 * These read as present-tense facts about money moving. On mainnet the CERT token is
 * deployed (`CERT_TOKEN_ADDRESS`), but no fee split is implemented, no staking contract
 * exists and nothing on chain routes a buyback. The token existing is not the design
 * existing, so the badge and the paragraph say both halves. On a bundle without the token
 * they still say there is none.
 *
 * The numbers stay because the design is real and worth publishing. The framing changes,
 * because "of protocol fees go to buyback" and "is what we intend to do with protocol fees"
 * are different claims and only one of them is true today.
 */
// The split the owner set on 2026-09-26 (70/20/5/5). It replaced three different versions this
// site, the whitepaper and the Learn page had been publishing at once.
const STATS = [
  { end: 70, suffix: "%", caption: "Intended for stakers in the insurance pool, as pay for taking the first loss" },
  { end: 20, suffix: "%", caption: "Intended for a buyback fund, held in USDG until there is a CERT market to buy on" },
  { end: 5, suffix: "+5%", caption: "Intended for the keepers' gas and operations, and for the treasury (the 2-of-3 Safe)" },
];

/** §3 TOKEN FLOW (full-bleed section-deep): counters left, metallic statement right. */
export default function TokenFlow() {
  const R = useReveal();
  return (
    <section className="grain section-glow relative bg-section-deep text-white">
      <div className="relative z-[2] mx-auto max-w-[1440px] px-4 py-16 md:px-6 md:py-24 lg:px-12 lg:py-32">
        <p className="font-mono text-[11px] uppercase tracking-[0.08em] text-white-60">The token</p>
        {/* Stated before the numbers, not after them. A reader who takes in the counters and
            leaves should not have been misled by the time they go. */}
        <p className="mt-3 inline-block border border-warn/40 px-3 py-1 font-mono text-[10px] uppercase tracking-[0.08em] text-warn">
          {HAS_CERT_TOKEN ? "Token and insurance pool deployed · fee split and buyback design only" : "Not deployed — design only"}
        </p>
        {CERT_TOKEN_ADDRESS && (
          <p className="mt-3 flex flex-wrap items-center gap-x-3 gap-y-1 font-mono text-[11px] uppercase tracking-[0.06em] text-white-60">
            <span>CERT · 18 decimals · 1,000,000,000 supply</span>
            <a
              href={explorerAddressUrl(CERT_TOKEN_ADDRESS)}
              target="_blank"
              rel="noreferrer"
              className="group inline-flex items-center gap-1.5 normal-case transition-colors hover:text-green-bright"
            >
              <span className="break-all">{CERT_TOKEN_ADDRESS}</span>
              <ArrowUpRight
                size={12}
                className="shrink-0 transition-transform group-hover:-translate-y-0.5 group-hover:translate-x-0.5"
              />
            </a>
          </p>
        )}

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
                    end={s.end}
                    suffix={s.suffix}
                    className="block text-[44px] font-semibold leading-[0.9] tracking-[-0.07em] text-green-bright md:text-[60px]"
                  />
                  <p className="mt-3 max-w-[40ch] text-[13px] leading-[1.5] text-white-60">{s.caption}</p>
                </div>
              </motion.div>
            ))}
          </div>

          {/* Right: giant metallic statement + copy */}
          <div>
            <motion.h2
              className="text-metallic text-[32px] font-semibold uppercase leading-[0.95] tracking-[-0.04em] md:text-[44px] lg:text-[52px]"
              initial="hidden"
              whileInView="show"
              viewport={{ once: true, amount: 0.3 }}
              variants={{ hidden: {}, show: { transition: { staggerChildren: 0.05 } } }}
            >
              {R("Fees flow to the people who keep the peg honest.").map((w, i) => (
                <motion.span
                  key={i}
                  className="inline-block whitespace-pre"
                  variants={{ hidden: { y: 24, opacity: 0 }, show: { y: 0, opacity: 1, transition: { duration: 0.6, ease: EASE } } }}
                >
                  {w}{R.sep}
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
              {HAS_CERT_TOKEN ? (
                <>
                  The design: mint and redeem fees, plus the funding-surplus share, would fund buybacks and staker
                  pay — stakers paid because they are first in line when the buffer breaks. No emissions games, no
                  hidden dilution. The CERT token is deployed, and so is the insurance pool (USDG, unaudited, capped at 10,000).
                  There is no buyback and no fee split on chain today: routing fees to the pool and the buyback fund
                  is written and tested and needs a new vault version. Published so it can be argued with early.
                </>
              ) : (
                <>
                  The design: mint and redeem fees, plus the funding-surplus share, would fund buybacks and staker
                  pay — stakers paid because they are first in line when the buffer breaks. No emissions games, no
                  hidden dilution. None of it is deployed. There is no token, no staking contract and no fee split
                  on chain today; this is the intent the contracts are being built toward, published so it can be
                  argued with early.
                </>
              )}
            </motion.p>
          </div>
        </div>
      </div>
    </section>
  );
}
