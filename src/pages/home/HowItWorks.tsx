import { motion } from "framer-motion";
import Accordion from "@/components/Accordion";
import type { AccordionRow } from "@/components/Accordion";

const EASE = [0.16, 1, 0.3, 1] as [number, number, number, number];

export const HOW_IT_WORKS_ROWS: AccordionRow[] = [
  {
    title: "Mint",
    meta: "Delta: 1.0",
    body: [
      "Deposit USDC into a per-asset vault. The vault opens an equivalent long on the corresponding equity perp on Robinhood Chain, and your certificate mints to your wallet at oracle price. uTSLA in, uTSLA out, at the stock's price, any hour of any day.",
      "The delta target is 1.0 at all times. Every certificate in circulation is backed by exactly one token's worth of perp exposure plus USDC margin, and the backing math is public every block.",
    ],
    image: "/hiw-mint.jpg",
    imageAlt: "Steel vault door with locking wheel",
  },
  {
    title: "Hold & Use",
    meta: "Form: plain token",
    body: [
      "Certificates are plain tokens on Robinhood Chain. Hold the stock 24/7, LP uTSLA against USDC, post it as collateral on lending markets, or send it like any token. No funding tabs, no liquidation price, nothing to babysit.",
      "This is the missing primitive: equity-shaped exposure that finally behaves like an asset. The stock, finally composable.",
    ],
    image: "/hiw-hold.jpg",
    imageAlt: "Wall of numbered safe deposit boxes",
  },
  {
    title: "Redeem, Always",
    meta: "Gating: never",
    body: [
      "Burn your certificate and the vault closes the matching perp exposure. USDC at oracle price returns to you in the same transaction. Redemption is never gated, never queued, never paused for convenience.",
      "Even if minting halts on a stale or deviant oracle, redemption continues at the last good price. The vault's solvency math is public every block, so you never have to trust a dashboard screenshot.",
    ],
    image: "/hiw-redeem.jpg",
    imageAlt: "Stack of US dollar bills",
  },
  {
    title: "Funding, Handled Honestly",
    meta: "Buffer: on chain",
    body: [
      "Perp funding accrues to and from a per-asset buffer. Positive funding fattens the buffer. Sustained negative funding draws it down, and past a published threshold it passes through as a transparent holding fee.",
      "Never a silent depeg. Every parameter, every threshold, and the live buffer balance are on chain and visible on the public solvency dashboard.",
    ],
    image: "/hiw-funding.jpg",
    imageAlt: "Brass balance scale",
  },
  {
    title: "Honest Boundaries",
    meta: "Risk: named plainly",
    body: [
      "Certificates are synthetic: price exposure backed by perp positions and USDC margin, not custody of shares. No dividends, no shareholder rights, no claim on an issuer.",
      "Risks are named plainly: sustained negative funding (buffered, then fee'd, never hidden), market and operator dependency, and oracle or liquidation tail risk in extreme gaps. UseCert is infrastructure, not investment advice.",
    ],
    image: "/hiw-boundaries.jpg",
    imageAlt: "Industrial pressure gauge dial macro",
  },
];

/** §6 HOW IT WORKS (black, accordion) — #how-it-works */
export default function HowItWorks() {
  return (
    <section id="how-it-works" className="grain bg-ink text-white">
      <div className="relative z-[2] mx-auto max-w-[1440px] px-4 py-16 md:px-6 md:py-24 lg:px-12 lg:py-32">
        <div className="grid gap-8 lg:grid-cols-2 lg:gap-16">
          <p className="font-mono text-[11px] uppercase tracking-[0.08em] text-white-60">How it works</p>
          <motion.p
            className="text-[26px] font-medium leading-[1.05] tracking-[-0.03em] md:text-[32px] lg:text-[40px]"
            initial={{ opacity: 0, y: 24 }}
            whileInView={{ opacity: 1, y: 0 }}
            viewport={{ once: true, amount: 0.3 }}
            transition={{ duration: 0.8, ease: EASE }}
          >
            The perps are the engine. UseCert is the asset. Every certificate is backed by exactly one token's worth
            of perp exposure plus USDC margin.
          </motion.p>
        </div>
        <motion.div
          className="mt-14"
          initial={{ opacity: 0, y: 24 }}
          whileInView={{ opacity: 1, y: 0 }}
          viewport={{ once: true, amount: 0.1 }}
          transition={{ duration: 0.7, ease: EASE }}
        >
          <Accordion rows={HOW_IT_WORKS_ROWS} dark />
        </motion.div>
      </div>
    </section>
  );
}
