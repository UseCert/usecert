import { motion } from "framer-motion";
import Accordion from "@/components/Accordion";
import type { AccordionRow } from "@/components/Accordion";
import LetterReveal from "@/components/LetterReveal";
import SwapButton from "@/components/SwapButton";
import { HAS_CERT_TOKEN } from "@/chain/deployment";
import { IS_TESTNET } from "@/chain/deployment";

const EASE = [0.16, 1, 0.3, 1] as [number, number, number, number];

export const FAQ_ROWS: AccordionRow[] = [
  {
    title: "Are certificates real shares?",
    body: [
      IS_TESTNET
        ? "No. Certificates are synthetic: price exposure backed by perp positions and USDG margin on Robinhood Chain, not custody of shares. There are no dividends and no shareholder rights. What you get is the stock’s price, holdable as a plain token, redeemable at oracle price any time — in the same transaction below the vault’s instant cap, and queued and paid by claim above it."
        : "No. Certificates are synthetic: price exposure backed by perp positions and USDG margin on Robinhood Chain, not custody of shares. There are no dividends and no shareholder rights. What you get is the stock’s price, holdable as a plain token, redeemable any time: the vault closes its hedge on chain at once, and the collateral comes back from the venue within minutes, paid by claim.",
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
      HAS_CERT_TOKEN
        ? "The insurance pool, after the vault's own buffer. InsuranceStaking is live on Robinhood Chain: stakers deposit USDG, and if a vault's buffer is ever not enough, the 2-of-3 Safe can propose a public, capped draw that moves pool USDG into that vault. Stakers share that loss pro rata; holders are senior, always. The pool is unaudited and capped at 10,000 USDG, so it is small. It has no automatic income yet: routing fees to it is the next vault version."
        : "In the design, stakers — staked tokens would underwrite the insurance buffer and be slashed before holder backing is ever touched, with holders senior always, and stakers earning a share of mint and redeem fees plus funding-surplus fees in exchange. None of that is deployed: there is no token, no staking contract and no insurance buffer on chain today. Until there is, the per-asset funding buffer is the only thing absorbing this loss, and after it is exhausted the loss reaches holders.",
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
            <h2 className="lg:whitespace-nowrap text-[44px] font-semibold uppercase leading-[0.85] tracking-[-0.05em] md:text-[60px] lg:text-[78px]">
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
