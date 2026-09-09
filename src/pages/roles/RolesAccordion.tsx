import { useState } from "react";
import { AnimatePresence, motion } from "framer-motion";
import { Plus } from "lucide-react";
import SwapButton from "@/components/SwapButton";

const EASE = [0.16, 1, 0.3, 1] as [number, number, number, number];

interface RoleRow {
  title: string;
  meta: string;
  body: string[];
  image: string;
  imageAlt: string;
  cta: { label: string; to?: string; href?: string; variant: "primary" | "outline" };
}

const ROWS: RoleRow[] = [
  {
    title: "Holder",
    meta: "The missing primitive",
    body: [
      "Mint certificates and hold them. That is the whole job. Your uTSLA sits in your wallet, tracks the stock 24/7, and redeems to USDC at oracle price whenever you want out. No funding tabs, no liquidation price, nothing to manage.",
      "Reward: stock exposure that just sits there. The asset Robinhood Chain was missing, finally holdable.",
    ],
    image: "/roles-holder.jpg",
    imageAlt: "Hand holding an engraved certificate plate",
    cta: { label: "Mint a Certificate", to: "/dashboard", variant: "primary" },
  },
  {
    title: "DeFi Builder",
    meta: "Equity-shaped lego",
    body: [
      "List certificates as collateral on lending markets, build uTSLA/USDC pairs, structure products on top of a spot asset that never needed to exist off chain. Certificates are plain tokens: permissionless to integrate, oracle-priced from the same feed the vaults use.",
      "Reward: the first equity-shaped asset on Robinhood Chain, in your protocol, before everyone else's.",
    ],
    image: "/roles-builder.jpg",
    imageAlt: "Certificate plates assembled into a mechanical lattice",
    cta: { label: "Read the Docs ↗", href: "https://github.com/usecert", variant: "outline" },
  },
  {
    title: "Staker",
    meta: "Backstop the buffer",
    body: [
      "Stake the token to underwrite the insurance buffer. If sustained negative funding draws the buffer past its threshold, staked tokens absorb the loss before holder backing is ever touched. Holders are senior, always. That is the deal, and it is priced in.",
      "Reward: a share of mint and redeem fees plus funding-surplus fees. Paid for real risk, named plainly.",
    ],
    image: "/roles-staker.jpg",
    imageAlt: "Steel vault door wheel with certificate plates behind glass",
    cta: { label: "Stake Token", to: "/dashboard", variant: "primary" },
  },
  {
    title: "Arbitrageur",
    meta: "Keep the peg tight",
    body: [
      "Mint at oracle price when the DEX trades rich, redeem at oracle price when it trades cheap. The vault is always open on one side of the trade, so the peg is a business, not a promise.",
      "Reward: the spread, every time the market wanders. You keep certificates pegged tight and get paid for it.",
    ],
    image: "/roles-arb.jpg",
    imageAlt: "Balance scales with certificate plates perfectly level",
    cta: { label: "See Live Spreads", to: "/dashboard", variant: "outline" },
  },
];

/** §2 ROLES ACCORDION (black): same pattern as home accordion, plus a CTA row. */
export default function RolesAccordion() {
  const [openIndex, setOpenIndex] = useState<number>(0);

  return (
    <section className="grain bg-ink text-white">
      <div className="relative z-[2] mx-auto max-w-[1440px] px-4 pb-16 md:px-6 md:pb-24 lg:px-12 lg:pb-32">
        <motion.div
          className="border-t hairline-dark"
          initial={{ opacity: 0, y: 24 }}
          whileInView={{ opacity: 1, y: 0 }}
          viewport={{ once: true, amount: 0.1 }}
          transition={{ duration: 0.7, ease: EASE }}
        >
          {ROWS.map((row, i) => {
            const open = openIndex === i;
            return (
              <motion.div
                key={row.title}
                className="border-b hairline-dark"
                initial={{ opacity: 0, y: 24 }}
                whileInView={{ opacity: 1, y: 0 }}
                viewport={{ once: true, amount: 0.3 }}
                transition={{ delay: i * 0.08, duration: 0.6, ease: EASE }}
              >
                <button
                  type="button"
                  onClick={() => setOpenIndex(open ? -1 : i)}
                  aria-expanded={open}
                  className="group flex w-full items-center gap-4 py-5 text-left md:gap-8 md:py-6"
                >
                  <span
                    className={
                      "font-mono text-[13px] transition-colors group-hover:text-green-bright " +
                      (open ? "text-green-bright" : "text-white-60")
                    }
                  >
                    {String(i + 1).padStart(2, "0")}
                  </span>
                  <span className="flex-1 text-[18px] font-semibold uppercase tracking-[-0.02em] text-white transition-transform duration-300 group-hover:translate-x-2 md:text-[22px]">
                    {row.title}
                  </span>
                  <span className="hidden font-mono text-[11px] uppercase tracking-[0.08em] text-white-60 sm:block">
                    {row.meta}
                  </span>
                  <span
                    className={
                      "flex h-9 w-9 shrink-0 items-center justify-center border hairline-dark transition-transform duration-300 " +
                      (open ? "rotate-45 text-green-bright" : "text-white")
                    }
                  >
                    <Plus size={16} />
                  </span>
                </button>
                <AnimatePresence initial={false}>
                  {open && (
                    <motion.div
                      initial={{ height: 0, opacity: 0 }}
                      animate={{ height: "auto", opacity: 1 }}
                      exit={{ height: 0, opacity: 0 }}
                      transition={{ duration: 0.4, ease: "easeInOut" }}
                      className="overflow-hidden"
                    >
                      <div className="grid gap-6 pb-8 md:grid-cols-2 md:gap-10 md:pl-[52px]">
                        {row.body.map((p, bi) => (
                          <p key={bi} className="text-[15px] leading-[1.55] text-white-60 md:text-[16px]">
                            {p}
                          </p>
                        ))}
                      </div>
                      <motion.img
                        src={row.image}
                        alt={row.imageAlt}
                        className="mb-8 aspect-[16/10] w-full object-cover md:ml-[52px] md:w-[calc(100%-52px)]"
                        initial={{ opacity: 0, y: 16 }}
                        animate={{ opacity: 1, y: 0 }}
                        transition={{ duration: 0.5 }}
                      />
                      {/* CTA row: slides up 12px after the text columns */}
                      <motion.div
                        className="pb-8 md:pl-[52px]"
                        initial={{ opacity: 0, y: 12 }}
                        animate={{ opacity: 1, y: 0 }}
                        transition={{ delay: 0.2, duration: 0.5, ease: EASE }}
                      >
                        <SwapButton
                          label={row.cta.label}
                          to={row.cta.to}
                          href={row.cta.href}
                          variant={row.cta.variant}
                        />
                      </motion.div>
                    </motion.div>
                  )}
                </AnimatePresence>
              </motion.div>
            );
          })}
        </motion.div>
      </div>
    </section>
  );
}
