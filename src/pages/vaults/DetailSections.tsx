import { Link } from "@/lib/router-compat";
import { motion } from "framer-motion";
import { ArrowUpRight } from "lucide-react";
import LetterReveal from "@/components/LetterReveal";
import type { VaultData } from "./data";
import { StatusPill } from "./StackCards";
import { CHAIN_ID, IS_TESTNET } from "@/chain/deployment";

const EASE = [0.16, 1, 0.3, 1] as [number, number, number, number];

const rise = {
  initial: { opacity: 0, y: 24 },
  whileInView: { opacity: 1, y: 0 },
  viewport: { once: true, amount: 0.3 },
} as const;

/** Section 2: intro paragraph + 4-cell meta grid (Scope/Timeline/Client/Year rhythm). */
export function IntroMeta({ vault }: { vault: VaultData }) {
  const live = vault.status === "LIVE";
  const cells = [
    { label: "Vault", value: "CertVault (factory-deployed)" },
    { label: "Delta target", value: "1.0, checked each attested batch" },
    { label: "Chain", value: "Robinhood Chain" },
  ];

  return (
    <section className="bg-ink text-white">
      <div className="mx-auto max-w-[1440px] px-4 py-16 md:px-6 md:py-24 lg:px-12 lg:py-32">
        <motion.p
          {...rise}
          transition={{ duration: 0.7, ease: EASE }}
          className="max-w-[70ch] text-[26px] font-medium leading-[1.05] tracking-[-0.03em] md:text-[32px] lg:text-[40px]"
        >
          {vault.intro}
        </motion.p>

        <div className="mt-16 grid gap-px border hairline-dark bg-hairline-dark sm:grid-cols-2 lg:grid-cols-4">
          {cells.map((cell, i) => (
            <motion.div
              key={cell.label}
              className="bg-ink p-6 md:p-8"
              initial={{ opacity: 0, y: 20 }}
              whileInView={{ opacity: 1, y: 0 }}
              viewport={{ once: true, amount: 0.4 }}
              transition={{ delay: i * 0.08, duration: 0.6, ease: EASE }}
            >
              <p className="font-mono text-[11px] uppercase tracking-[0.08em] text-white-60">{cell.label}</p>
              <p className="mt-4 text-[16px] font-medium leading-[1.3] md:text-[18px]">{cell.value}</p>
            </motion.div>
          ))}
          <motion.div
            className="bg-ink p-6 md:p-8"
            initial={{ opacity: 0, y: 20 }}
            whileInView={{ opacity: 1, y: 0 }}
            viewport={{ once: true, amount: 0.4 }}
            transition={{ delay: 3 * 0.08, duration: 0.6, ease: EASE }}
          >
            <p className="font-mono text-[11px] uppercase tracking-[0.08em] text-white-60">Status</p>
            <div className="mt-4">
              <StatusPill status={vault.status} />
            </div>
            {live ? (
              <Link
                to="/dashboard"
                className="group mt-4 inline-flex items-center gap-1.5 text-[13px] font-semibold uppercase tracking-[0.08em] text-white transition-colors hover:text-green-bright"
              >
                Open dashboard
                <ArrowUpRight size={14} className="transition-transform group-hover:translate-x-0.5 group-hover:-translate-y-0.5" />
              </Link>
            ) : (
              <a
                href="https://t.me/usecertonchain"
                target="_blank"
                rel="noreferrer"
                className="group mt-4 inline-flex items-center gap-1.5 text-[13px] font-semibold uppercase tracking-[0.08em] text-white transition-colors hover:text-green-bright"
              >
                Join Telegram
                <ArrowUpRight size={14} className="transition-transform group-hover:translate-x-0.5 group-hover:-translate-y-0.5" />
              </a>
            )}
          </motion.div>
        </div>
      </div>
    </section>
  );
}

/** Sections 3 + 6: giant letter-split heading + two-column paragraphs + optional link. */
export function TextBlock({
  heading,
  paragraphs,
  link,
}: {
  heading: string;
  paragraphs: [string, string];
  link?: { label: string; to: string };
}) {
  return (
    <section className="bg-ink text-white">
      <div className="mx-auto max-w-[1440px] border-t hairline-dark px-4 py-16 md:px-6 md:py-24 lg:px-12 lg:py-32">
        <h2 className="text-[44px] font-semibold uppercase leading-[0.85] tracking-[-0.05em] md:text-[60px] lg:text-[78px]">
          <LetterReveal text={heading} byWord stagger={0.05} />
        </h2>
        <div className="mt-12 grid gap-8 md:grid-cols-2 md:gap-10 lg:mt-16">
          {paragraphs.map((p, i) => (
            <motion.p
              key={i}
              initial={{ opacity: 0, y: 24 }}
              whileInView={{ opacity: 1, y: 0 }}
              viewport={{ once: true, amount: 0.4 }}
              transition={{ delay: i * 0.15, duration: 0.7, ease: EASE }}
              className="max-w-[52ch] text-[15px] leading-[1.55] text-white-60 md:text-[16px]"
            >
              {p}
            </motion.p>
          ))}
        </div>
        {link && (
          <motion.div {...rise} transition={{ delay: 0.3, duration: 0.6, ease: EASE }} className="mt-10">
            <Link
              to={link.to}
              className="group inline-flex items-center gap-2 text-[13px] font-semibold uppercase tracking-[0.08em] text-white transition-colors hover:text-green-bright"
            >
              {link.label}
              <ArrowUpRight size={16} className="transition-transform group-hover:translate-x-0.5 group-hover:-translate-y-0.5" />
            </Link>
          </motion.div>
        )}
      </div>
    </section>
  );
}

/* `TickingPrice` used to live here: it took a hardcoded base price and jittered it with
 * Math.random() every 1.6 s so the panel below looked like a live oracle feed. Together
 * with a hardcoded supply, a hardcoded "100.00%" backing ratio and a hardcoded "1.000"
 * delta, it made a marketing page look like a solvency read. All of it is gone — the
 * dashboard reads those four figures from the contracts, and this page links to it. */

/** Corner-dot frame device (echoes the hero): 1px rect with 4 filled corner dots. */
function CornerDots() {
  return (
    <>
      <span className="absolute -left-[3px] -top-[3px] h-[6px] w-[6px] bg-silver" aria-hidden />
      <span className="absolute -right-[3px] -top-[3px] h-[6px] w-[6px] bg-silver" aria-hidden />
      <span className="absolute -bottom-[3px] -left-[3px] h-[6px] w-[6px] bg-silver" aria-hidden />
      <span className="absolute -bottom-[3px] -right-[3px] h-[6px] w-[6px] bg-silver" aria-hidden />
    </>
  );
}

/**
 * Section 4: the certificate plate, plus a pointer to where the figures actually live.
 *
 * This used to be a "Live vault snapshot · Powers the public dashboard" panel showing an
 * oracle price, a circulating supply, a backing ratio and a delta. None of the four came
 * from a contract: they were literals in `data.ts` with a `Math.random()` jitter on the
 * price and a pulsing "Live" dot next to them, and the same panel rendered for every
 * vault on the roadmap, deployed or not. A number on a public page has to trace to a chain
 * read, so the figures are gone and the dashboard is linked instead.
 */
export function MediaBlock({ vault }: { vault: VaultData }) {
  const live = vault.status === "LIVE";

  return (
    <section className="bg-ink text-white">
      <div className="mx-auto max-w-[1440px] px-4 pb-16 md:px-6 md:pb-24 lg:px-12 lg:pb-32">
        <motion.div
          {...rise}
          viewport={{ once: true, amount: 0.2 }}
          transition={{ duration: 0.7, ease: EASE }}
          className="relative border hairline-dark"
        >
          <CornerDots />
          <div>
            <div className="relative overflow-hidden">
              <img
                src={vault.image}
                alt={`${vault.name} certificate plate`}
                className="aspect-[16/10] w-full object-cover"
              />
              {live ? (
                <span className="absolute left-4 top-4 inline-flex items-center gap-1.5 rounded-full border border-green-bright/40 bg-ink/70 px-3 py-1 font-mono text-[10px] uppercase tracking-[0.08em] text-green-bright backdrop-blur-sm md:left-6 md:top-6">
                  <span className="h-[6px] w-[6px] rounded-full bg-green-bright" aria-hidden />
                  {IS_TESTNET ? `Deployed on testnet ${CHAIN_ID}` : `Deployed on mainnet ${CHAIN_ID}`}
                </span>
              ) : (
                <span className="absolute left-4 top-4 inline-flex items-center gap-1.5 rounded-full border border-warn/40 bg-ink/70 px-3 py-1 font-mono text-[10px] uppercase tracking-[0.08em] text-warn backdrop-blur-sm md:left-6 md:top-6">
                  <span className="h-[6px] w-[6px] rounded-full bg-warn" aria-hidden />
                  Roadmap C2
                </span>
              )}
            </div>
            <div className="flex flex-wrap items-center justify-between gap-6 p-6 md:p-10">
              {live ? (
                <p className="max-w-[48ch] text-[16px] leading-[1.55] text-white-60">
                  Price, supply, buffer and delta drift are read from the vault, the certificate and the
                  oracle on the dashboard, each one shown with the age of the attestation it rests on. No
                  figure for this vault is published here, because nothing on this page reads the chain.
                </p>
              ) : (
                <p className="max-w-[48ch] text-[16px] leading-[1.55] text-white-60">
                  {vault.roadmapCopy ?? "This vault deploys in phase C2."} Minting opens the day the vault
                  contract is factory-deployed on Robinhood Chain.
                </p>
              )}
              {live ? (
                <Link
                  to="/dashboard"
                  className="group inline-flex items-center gap-2 text-[13px] font-semibold uppercase tracking-[0.08em] text-white transition-colors hover:text-green-bright"
                >
                  Full solvency view
                  <ArrowUpRight size={16} className="transition-transform group-hover:translate-x-0.5 group-hover:-translate-y-0.5" />
                </Link>
              ) : (
                <a
                  href="https://t.me/usecertonchain"
                  target="_blank"
                  rel="noreferrer"
                  className="group inline-flex items-center gap-2 text-[13px] font-semibold uppercase tracking-[0.08em] text-white transition-colors hover:text-green-bright"
                >
                  Join Telegram
                  <ArrowUpRight size={16} className="transition-transform group-hover:translate-x-0.5 group-hover:-translate-y-0.5" />
                </a>
              )}
            </div>
          </div>
        </motion.div>
      </div>
    </section>
  );
}

export { EASE };
