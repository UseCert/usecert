import { motion } from "framer-motion";
import Accordion from "@/components/Accordion";
import type { AccordionRow } from "@/components/Accordion";
import LetterReveal from "@/components/LetterReveal";
import SwapButton from "@/components/SwapButton";

const EASE = [0.16, 1, 0.3, 1] as [number, number, number, number];

export const FAQ_ROWS: AccordionRow[] = [
  {
    title: "Are certificates real shares?",
    body: [
      "No. Certificates are synthetic: price exposure backed by perp positions and tUSDG margin on Robinhood Chain, not custody of shares. There are no dividends and no shareholder rights. What you get is the stock's price, holdable as a plain token, redeemable at oracle price any time.",
    ],
  },
  {
    title: "What happens in sustained negative funding?",
    body: [
      "Funding accrues to a per-asset buffer first. Positive funding grows it; sustained negative funding draws it down. Past a published threshold, the remainder passes through as a transparent holding fee. It is buffered, then fee'd, never hidden, and every parameter is on chain.",
    ],
  },
  {
    title: "Can redemption ever be paused?",
    body: [
      "No. Redemption is never gated. If the oracle goes stale or deviates beyond guard bands, minting pauses automatically while redemption continues at the last good price. An operator halt triggers a wind down procedure designed to keep holders whole.",
    ],
  },
  {
    title: "Who takes the loss if the buffer runs out?",
    body: [
      "Stakers. Staked tokens underwrite the insurance buffer and are slashed before holder backing is ever touched. Holders are senior, always. In exchange, stakers earn a share of mint and redeem fees plus funding-surplus fees.",
    ],
  },
];

/** §8 FAQ (light grey paper) - #faq */
export default function Faq() {
  return (
    <section id="faq" className="bg-paper text-ink">
      <div className="mx-auto max-w-[1440px] px-4 py-16 md:px-6 md:py-24 lg:px-12 lg:py-32">
        <p className="font-mono text-[11px] uppercase tracking-[0.08em] text-ink-60">FAQ</p>
        <div className="mt-4 grid gap-12 lg:grid-cols-2 lg:gap-20">
          <div>
            <h2 className="whitespace-nowrap text-[44px] font-semibold uppercase leading-[0.85] tracking-[-0.05em] md:text-[60px] lg:text-[78px]">
              <LetterReveal text="Before you mint." byWord stagger={0.05} />
            </h2>
            <motion.div
              className="mt-10"
              initial={{ opacity: 0, y: 20 }}
              whileInView={{ opacity: 1, y: 0 }}
              viewport={{ once: true }}
              transition={{ duration: 0.6, ease: EASE }}
            >
              <SwapButton label="Ask on Telegram" href="https://t.me/usecertonchain" variant="black" />
            </motion.div>
          </div>
          <motion.div
            initial={{ opacity: 0, y: 24 }}
            whileInView={{ opacity: 1, y: 0 }}
            viewport={{ once: true, amount: 0.1 }}
            transition={{ duration: 0.7, ease: EASE }}
          >
            <Accordion rows={FAQ_ROWS} dark={false} />
          </motion.div>
        </div>
      </div>
    </section>
  );
}
