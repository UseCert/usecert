import { useCallback, useEffect, useState } from "react";
import { motion } from "framer-motion";
import { ChevronLeft, ChevronRight } from "lucide-react";
import { Link } from "@/lib/router-compat";
import { VALUE_DISCLOSURE } from "@/chain/deployment";
import { cn } from "@/lib/utils";

const EASE = [0.16, 1, 0.3, 1] as [number, number, number, number];

/**
 * PUBLIC MILESTONES (/roadmap).
 *
 * WHAT THIS PAGE IS FOR, AND WHAT IT DELIBERATELY IS NOT.
 *
 * The C1-C4 strip on /roles is the PRODUCT roadmap - what the protocol intends to
 * become. This is the DELIVERY one: what works today, what is being built, and what
 * has to be true before any of it touches mainnet. The two are kept apart because
 * they answer different questions, and a reader asking "can I use this yet" is badly
 * served by a page about token genesis.
 *
 * Every SHIPPED item is checkable by the reader on chain or against the
 * dashboard, which is the only reason to claim them. Nothing here is a promise about
 * a date: the internal roadmap this is derived from sizes work in hours and days, and
 * turning that into public dates would be inventing a confidence nobody has.
 *
 * WHAT IS LEFT OUT, on purpose:
 *   - specific unfixed defects and the internals that would locate them. A public
 *     roadmap should not double as a map of where to push.
 *   - internal copy and QA work. "Some wording on this site is wrong" is a task, not
 *     a milestone, and publishing it beside the wording would be incoherent rather
 *     than honest - the fix is to correct it.
 * What is NOT left out is anything a reader could be harmed by not knowing: that the
 * venue is simulated, that two mirrors carry unverified market indices, and that an
 * audit finding closed in code still needs re-auditing on the path that changed.
 */

type Status = "shipped" | "building" | "planned";

interface Milestone {
  title: string;
  copy: string;
  /** How a reader can check it themselves. Only on shipped items - a claim nobody can verify is just a claim. */
  verify?: string;
  /**
   * A screenshot of the thing itself, in `public/roadmap/`.
   *
   * Captured from the LIVE site by `capture.mjs`, with no wallet shim and no patched RPC -
   * unlike the demo recorder, which fakes attestation freshness and is labelled a
   * simulation for that reason. These sit beside the word SHIPPED, so a staged image would
   * make the page evidence of nothing.
   *
   * ABSENT ON PURPOSE for two items. "Redemption is gated on nothing" is a claim about the
   * ABSENCE of preconditions, which no screen can show - a picture of the redeem panel
   * would prove only that a panel exists. The external audit has no UI at all. Illustrating
   * either would be decoration borrowing the authority of evidence, so they carry none.
   */
  shot?: {
    src: string;
    alt: string;
    caption: string;
    /**
     * Cap in CSS px, for a capture narrower than the row. Stretching a 596px panel across
     * 1297px upscales it 2.2x and it goes soft - a blurry screenshot reads as a careless
     * one. The wide table captures need no cap; they are still being downscaled.
     */
    maxW?: number;
  };
}

const SHIPPED: Milestone[] = [
  {
    title: "Six mirrors live on mainnet",
    copy: "uTSLA, uSPY, uQQQ, uNVDA, uAAPL and uMSFT on Robinhood Chain mainnet, collateralised in USDG and hedged on Robinhood Chain Lighter. Each one has been through a full mint and redemption on the live venue.",
    verify: "Every address is on /contracts, each linking to the chain explorer.",
    shot: {
      src: "/roadmap/site-contracts.jpg",
      alt: "The contracts page listing the six mainnet mirrors with their vault, certificate and oracle addresses.",
      caption: "The mainnet address book, generated from the same file the app transacts against.",
    },
  },
  {
    title: "Every certificate is hedged before it exists",
    copy: "A mint escrows your USDG and asks for a hedge. The position is opened on Robinhood Chain Lighter, and only once the venue confirms the full fill are certificates issued, at the price it actually filled at. If the hedge cannot be opened, nothing is issued and the escrow is refunded.",
    verify: "Open any settle transaction on the explorer: the certificates are minted in the same transaction that records the fill.",
    shot: {
      src: "/roadmap/bs-tx-settle-s3.jpg",
      alt: "Explorer page of a successful settle transaction minting 0.0335 uTSLA.",
      caption: "A mainnet settle: the hedge filled on the venue, then 0.0335 uTSLA was minted.",
    },
  },
  {
    title: "Exits close on chain, with no key involved",
    copy: "Redeeming makes the vault send its own reduce-only order to the venue through the chain. No operator, API key or keeper is needed to close a position, which is the part of the design that has to work when nothing else does.",
    verify: "The redemption transaction on the explorer is sent by the holder, to the vault, and carries the close.",
    shot: {
      src: "/roadmap/bs-tx-redeem-611.jpg",
      alt: "Explorer page of a successful redemption transaction.",
      caption: "A mainnet redemption. The venue position was flat within ten seconds.",
    },
  },
  {
    title: "Solvency attested per batch, with its age published",
    copy: "Backing is posted on-chain per batch rather than asserted in copy. On mainnet the figures are the vaults' own venue accounts, read from the venue and signed by the attester. The dashboard shows how old they are.",
    verify: "The attestation age is on the dashboard, next to the figure it qualifies.",
    shot: {
      src: "/roadmap/site-dashboard.jpg",
      alt: "The mainnet dashboard overview with position notional, margin, buffer held and the attestation age.",
      caption: "The dashboard on mainnet. Each figure carries the age of the attestation behind it.",
    },
  },
  {
    title: "Minting pays for its own freshness",
    copy: "The attester signs and whoever mints relays that signature inside their own transaction, so nobody funds an idle protocol to stay open. On mainnet the signer reads the venue itself and hands out signatures with almost their whole minute of validity left.",
    verify: "use-cert.com/api/attestations serves the current signatures.",
  },
  {
    title: "Protocol capital can be recovered from an empty vault",
    copy: "A vault only releases collateral by redeeming certificates, which is what stops anyone taking it from under holders. A retired vault is the one exception, and retiring refuses unless no certificates, open mints, unpaid redemptions or hedge remain. After that it never mints again.",
    verify: "test/CertVaultRetire.t.sol is in the repository: four of its seven cases are ways retiring could hurt someone, and each must fail.",
  },
  {
    title: "Source verified for every contract",
    copy: "All 27 mainnet contracts publish their source on Sourcify, with the runtime bytecode matching exactly.",
    verify: "Look any address up on sourcify.dev.",
    shot: {
      src: "/roadmap/sourcify-vault-s3.jpg",
      alt: "Sourcify page showing a verified CertVault on Robinhood Chain.",
      caption: "The uTSLA vault on Sourcify.",
    },
  },
  {
    title: "A dashboard that refuses to invent data",
    copy: "Figures are read from the chain. Where a series would need an indexer that does not exist yet, the dashboard says that instead of drawing a plausible curve.",
    verify: "Look for the places it declines to plot something.",
  },
  {
    title: "Risk thresholds read from the contracts",
    copy: "Each row of the failure-mode table prints the number the contract actually enforces, including staleness, deviation, basis band, attestation age and instant cap, read live from the oracle and the vault.",
    verify: "Compare the risk table against the same values on the explorer.",
  },
  {
    title: "External security audit, criticals closed",
    copy: "The contracts were audited by an outside reviewer. The reported Critical is fixed, as is a blocker that would have left one contract undeployable. The auditor's proof-of-concept exploits are kept in the repository as executable evidence rather than summarised.",
    verify: "test/AuditPoC.t.sol and test/AttackSuite.t.sol are in the repository and runnable.",
  },
  {
    title: "The site reads its claims off the chain it is on",
    copy: "Which network this is, what the collateral is called, whether the venue is simulated and whether a faucet exists are all read from the deployed address book, so the page cannot describe a deployment it is not talking to.",
    verify: "Every address on /contracts comes from that same address book.",
  },
];

const BUILDING: Milestone[] = [
  {
    title: "Alerting on the keepers and the signer",
    copy: "The hedge keepers and the attestation signer run, retry and journal what they do. Nothing yet pages a person when one stops, and that has to exist before larger amounts are minted.",
  },
  {
    title: "History worth plotting",
    copy: "Solvency and funding over time need an indexer, since no view function returns a series. Until one exists the dashboard shows a single proven point rather than a curve.",
  },
  {
    title: "Your receipts, enumerable",
    copy: "Mint and redeem receipts exist on-chain but cannot be listed by address from the contracts alone. Same dependency as the history above.",
  },
];

const BEFORE_MAINNET: Milestone[] = [
  {
    title: "Governance and attester custody",
    copy: "Governance and the attester are each a single key today. Moving them to threshold custody, with a rotation that has actually been rehearsed, is the largest open risk and is not done.",
  },
  {
    title: "Re-audit what changed",
    copy: "Signed attestations, keeper-opened hedges and vault retirement are all newer than the audit. Closed findings do not carry over to code that did not exist when they were closed.",
  },
  {
    title: "Exact bookkeeping of venue payouts",
    copy: "The venue pays withdrawals straight to the vault, which the vault's recall counter does not see, so that counter can overstate. Holders are paid regardless, because payouts are sized from the vault's real balance, but the published counter should be exact.",
  },
  {
    title: "Releases you can verify",
    copy: "Signed releases, so that the site you are reading and the contracts it talks to can be tied together by someone who trusts neither.",
  },
];

/**
 * One flat sequence, so a reader can walk the whole set without first choosing a section.
 * The section a milestone belongs to travels with it as a label instead.
 */
const PAGES: { m: Milestone; status: Status; label: string }[] = [
  ...SHIPPED.map((m) => ({ m, status: "shipped" as Status, label: "Shipped" })),
  ...BUILDING.map((m) => ({ m, status: "building" as Status, label: "Building" })),
  ...BEFORE_MAINNET.map((m) => ({ m, status: "planned" as Status, label: "Still open" })),
];

const DOT: Record<Status, string> = {
  shipped: "bg-green-bright",
  building: "bg-warn",
  planned: "bg-white-60",
};

/** Page 0 is the summary; milestone n sits at index n + 1. */
const TOTAL_PAGES = PAGES.length + 1;

const GROUPS: { label: string; status: Status; items: Milestone[] }[] = [
  { label: "Shipped", status: "shipped", items: SHIPPED },
  { label: "Building", status: "building", items: BUILDING },
  { label: "Still open", status: "planned", items: BEFORE_MAINNET },
];

export default function RoadmapPage() {
  const [i, setI] = useState(0);
  const summary = i === 0;
  const page = summary ? null : PAGES[i - 1];

  const go = useCallback((next: number) => {
    setI(Math.max(0, Math.min(TOTAL_PAGES - 1, next)));
  }, []);

  // Arrow keys. A paged view that answers only the mouse is a worse version of the
  // scrolling page it replaced.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "ArrowRight") go(i + 1);
      if (e.key === "ArrowLeft") go(i - 1);
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [i, go]);

  /** Jump straight to a milestone from the summary. */
  const openMilestone = (title: string) => {
    const n = PAGES.findIndex((p) => p.m.title === title);
    if (n >= 0) go(n + 1);
  };

  return (
    <section className="grain bg-ink text-white">
      <div className="relative z-[2] mx-auto max-w-[1440px] px-4 py-24 md:px-6 md:py-32 lg:px-12">
        <p className="font-mono text-[11px] uppercase tracking-[0.08em] text-white-60">Milestones</p>
        <h1 className="mt-4 max-w-[18ch] text-[44px] font-semibold uppercase leading-[0.85] tracking-[-0.05em] md:text-[60px] lg:text-[78px]">
          What works<span className="text-green-bright">,</span> and what does not yet
        </h1>

        {/* The disclosure a reader needs before anything below means what it appears to mean.
            It stays above the pager rather than living on page one, because a paged view is
            one a reader can arrive in the middle of. */}
        {/* Derived, not typed. On mainnet VALUE_DISCLOSURE is empty and this renders nothing,
            because the sentence would be false there and a disclosure that is false is worse
            than none. */}
        {VALUE_DISCLOSURE && (
          <p className="mt-8 max-w-[62ch] text-[16px] leading-[1.55] text-silver">
            {VALUE_DISCLOSURE}
          </p>
        )}
        <p className="mt-4 max-w-[62ch] text-[16px] leading-[1.55] text-silver">
          There are no dates on this page. The work below is sized internally in hours and days,
          and publishing that as a calendar would be inventing a confidence nobody has.
        </p>

        {/* ------------------------------------------------------------------ pager */}
        <div className="mt-16 border-t hairline-dark pt-8 md:mt-24">
          {/* Every milestone as a tick, so a reader sees the shape of the whole set and can
              jump, instead of only stepping one at a time. Coloured by status, so the
              proportion of shipped to planned is readable at a glance. */}
          <div className="flex flex-wrap items-center gap-x-1.5 gap-y-2">
            <button
              type="button"
              onClick={() => go(0)}
              aria-label="Overview"
              aria-current={summary ? "step" : undefined}
              title="Overview"
              className={cn(
                "h-1 w-7 transition-colors md:w-9",
                summary ? "bg-white" : "bg-white/15 hover:bg-white/40",
              )}
            />
            {PAGES.map((p, n) => (
              <button
                key={p.m.title}
                type="button"
                onClick={() => go(n + 1)}
                aria-label={`${n + 1}. ${p.m.title}`}
                aria-current={n + 1 === i ? "step" : undefined}
                title={`${p.label} — ${p.m.title}`}
                className={cn(
                  "h-1 w-7 transition-colors md:w-9",
                  n + 1 === i ? DOT[p.status] : "bg-white/15 hover:bg-white/40",
                )}
              />
            ))}
          </div>

          <div className="mt-6 flex flex-wrap items-center justify-between gap-4">
            <p className="flex items-center gap-2 font-mono text-[11px] uppercase tracking-[0.08em] text-white-60">
              <span
                className={cn("h-1.5 w-1.5 rounded-full", page ? DOT[page.status] : "bg-white")}
                aria-hidden
              />
              {page ? page.label : "Overview"}
              <span className="text-white-60/60">
                · {i + 1} of {TOTAL_PAGES}
              </span>
            </p>
            <div className="flex items-center gap-2">
              <button
                type="button"
                onClick={() => go(i - 1)}
                disabled={i === 0}
                className="flex items-center gap-1.5 border border-white/20 px-3 py-2 font-mono text-[10px] uppercase tracking-[0.08em] text-white transition-colors hover:border-green-bright/50 hover:text-green-bright disabled:opacity-30 disabled:hover:border-white/20 disabled:hover:text-white"
              >
                <ChevronLeft size={13} /> Prev
              </button>
              <button
                type="button"
                onClick={() => go(i + 1)}
                disabled={i === TOTAL_PAGES - 1}
                className="flex items-center gap-1.5 border border-white/20 px-3 py-2 font-mono text-[10px] uppercase tracking-[0.08em] text-white transition-colors hover:border-green-bright/50 hover:text-green-bright disabled:opacity-30 disabled:hover:border-white/20 disabled:hover:text-white"
              >
                Next <ChevronRight size={13} />
              </button>
            </div>
          </div>

          {/* A floor under the panel so the controls above do not jump as pages of very
              different lengths swap in - the buttons have to stay where the cursor left them. */}
          <div className="mt-8 min-h-[460px] border-t hairline-dark pt-10">
            {/* A plain keyed remount, NOT AnimatePresence mode="wait". With the wait mode
                the exit never completed here, so the incoming article never mounted and
                the page counter advanced over frozen content - fifteen pages all showing
                the first milestone. Changing the key remounts and replays the entrance,
                which is the whole effect that was wanted. */}
            {summary ? (
              <motion.div
                key="overview"
                initial={{ opacity: 0, y: 12 }}
                animate={{ opacity: 1, y: 0 }}
                transition={{ duration: 0.28, ease: EASE }}
              >
                <h2 className="max-w-[26ch] text-[28px] font-semibold uppercase leading-[1.05] tracking-[-0.03em] text-white md:text-[38px]">
                  Where this stands
                </h2>
                <p className="mt-5 max-w-[64ch] text-[15px] leading-[1.65] text-white-60 md:text-[16px]">
                  {SHIPPED.length} shipped, {BUILDING.length} being built, and{" "}
                  {BEFORE_MAINNET.length} things still open before this should carry
                  size. Open any one for what it means and how to check it.
                </p>

                <div className="mt-10 grid gap-10 md:grid-cols-3 md:gap-6">
                  {GROUPS.map((g) => (
                    <div key={g.label}>
                      <p className="flex items-center gap-2 border-b hairline-dark pb-3 font-mono text-[11px] uppercase tracking-[0.08em] text-white-60">
                        <span className={cn("h-1.5 w-1.5 rounded-full", DOT[g.status])} aria-hidden />
                        {g.label}
                        <span className="text-white-60/60">· {g.items.length}</span>
                      </p>
                      <ul className="mt-1">
                        {g.items.map((it) => (
                          <li key={it.title}>
                            <button
                              type="button"
                              onClick={() => openMilestone(it.title)}
                              className="w-full border-b hairline-dark py-3 text-left text-[13px] leading-[1.45] text-silver transition-colors hover:text-green-bright"
                            >
                              {it.title}
                            </button>
                          </li>
                        ))}
                      </ul>
                    </div>
                  ))}
                </div>
              </motion.div>
            ) : (
            <motion.article
                key={page!.m.title}
                initial={{ opacity: 0, y: 12 }}
                animate={{ opacity: 1, y: 0 }}
                transition={{ duration: 0.28, ease: EASE }}
              >
                  <h2 className="max-w-[26ch] text-[28px] font-semibold uppercase leading-[1.05] tracking-[-0.03em] text-white md:text-[38px]">
                    {page!.m.title}
                  </h2>
                  <p className="mt-5 max-w-[64ch] text-[15px] leading-[1.65] text-white-60 md:text-[16px]">
                    {page!.m.copy}
                  </p>
                  {page!.m.verify && (
                    <p className="mt-4 max-w-[64ch] font-mono text-[11px] leading-[1.6] text-green-bright/80">
                      Check it: {page!.m.verify}
                    </p>
                  )}
                  {page!.m.shot && (
                    <figure className="mt-8">
                      <a
                        href={page!.m.shot.src}
                        target="_blank"
                        rel="noreferrer"
                        className="block"
                        aria-label={`Open full-size: ${page!.m.shot.caption}`}
                      >
                        <img
                          src={page!.m.shot.src}
                          alt={page!.m.shot.alt}
                          loading="lazy"
                          decoding="async"
                          style={page!.m.shot.maxW ? { maxWidth: page!.m.shot.maxW } : undefined}
                          className="w-full border hairline-dark bg-[#0d0f0d] transition-opacity hover:opacity-90"
                        />
                      </a>
                      <figcaption className="mt-2 max-w-[80ch] font-mono text-[10px] leading-[1.6] text-white-60/70">
                        {page!.m.shot.caption} <span className="text-white-60/50">Tap to enlarge.</span>
                      </figcaption>
                    </figure>
                  )}
              </motion.article>
            )}
          </div>
        </div>

        <div className="mt-16 border hairline-dark bg-section-deep p-6 md:mt-24 md:p-8">
          <p className="font-mono text-[11px] uppercase tracking-[0.08em] text-green-bright">
            Where the product is going
          </p>
          <p className="mt-3 max-w-[62ch] text-[14px] leading-[1.6] text-white-60">
            This page is about delivery — what is built and what has to be true before mainnet. For
            what the protocol intends to <em>become</em> — further mirrors, the insurance buffer,
            structured wrappers — see the phase roadmap on the{" "}
            <Link to="/roles" className="text-white underline underline-offset-4 hover:text-green-bright">
              roles page
            </Link>
            .
          </p>
        </div>
      </div>
    </section>
  );
}
