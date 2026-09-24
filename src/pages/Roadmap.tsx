import { useCallback, useEffect, useState } from "react";
import { motion } from "framer-motion";
import { ChevronLeft, ChevronRight } from "lucide-react";
import { Link } from "@/lib/router-compat";
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
 * Every SHIPPED item is checkable by the reader against chain 46630 or against the
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
    title: "Four mirrors live",
    copy: "uTSLA, uSPY, uQQQ and uNVDA on Robinhood Chain testnet. Mint, redeem, and force-exit all work against the deployed contracts.",
    verify: "Every address is in the dashboard and on the explorer.",
    shot: {
      src: "/roadmap/mirrors.jpg",
      alt: "Dashboard table listing uTSLA, uSPY, uQQQ and uNVDA, each marked live, with oracle price, supply, attested notional and margin, buffer held and hedge ratio.",
      caption: "The four routed vaults on the dashboard, read from chain 46630.",
    },
  },
  {
    title: "Solvency attested per batch, with its age published",
    copy: "Backing is posted on-chain per batch rather than asserted in copy. The dashboard shows how old the figure is, and says so plainly when it is stale.",
    verify: "The attestation age is on the dashboard, next to the figure it qualifies.",
    shot: {
      src: "/roadmap/attestation-age.jpg",
      alt: "Dashboard table with a Proven column showing each vault's attestation age and batch number, and a Minting column reading Allowed.",
      caption:
        "Every figure carries its age and batch number. The venue market column also marks which indices were read from the venue and which were chosen.",
    },
  },
  {
    title: "Redemption gated on nothing",
    copy: "Exiting reads no health state, needs no keeper and no fresh attestation. It is the one path with no preconditions, deliberately, so a holder can always leave.",
    verify: "forceExit takes no oracle and no capacity check.",
  },
  {
    title: "Minting pays for its own freshness",
    copy: "An idle protocol used to pay a keeper around the clock to stay open. Now the attester signs and whoever mints relays that signature inside their own transaction, so nobody funds an empty room.",
    verify: "Idle days cost the protocol nothing on-chain.",
    shot: {
      src: "/roadmap/mint-refresh.jpg",
      maxW: 660,
      alt: "Panel headed 'Attestation idle, your mint refreshes it', explaining that the mint ceiling reads zero while the protocol is idle and that the transaction relays a fresh attestation.",
      caption:
        "What the mint panel says between mints. The ceiling reads zero because nobody is paying to hold it open; the mint relays a fresh attestation itself.",
    },
  },
  {
    title: "A dashboard that refuses to invent data",
    copy: "Figures are read from the chain. Where a series would need an indexer that does not exist yet, the dashboard says that instead of drawing a plausible curve.",
    verify: "Look for the places it declines to plot something.",
    shot: {
      src: "/roadmap/no-invented-data.jpg",
      alt: "An empty chart area reading 'No solvency history yet: needs an indexer', explaining that no view function returns a time series so a curve would have to be invented.",
      caption: "Where a chart would go, when the data to draw one does not exist.",
    },
  },
  {
    title: "External security audit, criticals closed",
    copy: "The contracts were audited by an outside reviewer. Every critical finding is closed in code, and the proof-of-concept exploits are kept in the repository as executable evidence rather than summarised.",
  },
];

const BUILDING: Milestone[] = [
  {
    title: "History worth plotting",
    copy: "Solvency and funding over time need an indexer - no view function returns a series. Until one exists the dashboard shows a single proven point rather than a curve.",
  },
  {
    title: "Your receipts, enumerable",
    copy: "Mint and redeem receipts exist on-chain but cannot be listed by address from the contracts alone. Same dependency as the history above.",
  },
  {
    title: "Wallets beyond browser extensions",
    copy: "Extension wallets already work. Mobile wallets are wired and waiting on one piece of configuration.",
  },
];

const BEFORE_MAINNET: Milestone[] = [
  {
    title: "Re-audit the path that changed",
    copy: "Moving attestation from a keeper to a signature is new since the audit, and it sits directly on the gate that admits minting. Closed criticals do not transfer to a path that did not exist when they were closed.",
  },
  {
    title: "A real venue",
    copy: "Today the perp venue is a simulator this project runs. Every margin and position figure on the dashboard describes a simulated position, and the independence check between price sources cannot mean anything until there are two real ones.",
  },
  {
    title: "Verified market indices on every mirror",
    copy: "Two of the four mirrors carry a market index that was chosen rather than read from the venue. On a simulator that deploys cleanly; against a real order book it would hedge the wrong market. This is recorded per mirror in the public address book.",
  },
  {
    title: "Real collateral",
    copy: "Mainnet uses USDG. The test token and its faucet disappear, and with them the ability to mint without buying anything.",
  },
  {
    title: "Key custody and rotation, in the open",
    copy: "Rotation already exists on-chain with a published notice period. What has to be settled before mainnet is the operational half: where the signing key lives and who can move it.",
  },
  {
    title: "Releases you can verify",
    copy: "Signed releases and an address book a reader can check against the explorer, so the site you are reading and the contracts it talks to can be tied together by someone who trusts neither.",
  },
];

/**
 * One flat sequence, so a reader can walk the whole set without first choosing a section.
 * The section a milestone belongs to travels with it as a label instead.
 */
const PAGES: { m: Milestone; status: Status; label: string }[] = [
  ...SHIPPED.map((m) => ({ m, status: "shipped" as Status, label: "Shipped" })),
  ...BUILDING.map((m) => ({ m, status: "building" as Status, label: "Building" })),
  ...BEFORE_MAINNET.map((m) => ({ m, status: "planned" as Status, label: "Before mainnet" })),
];

const DOT: Record<Status, string> = {
  shipped: "bg-green-bright",
  building: "bg-warn",
  planned: "bg-white-60",
};

export default function RoadmapPage() {
  const [i, setI] = useState(0);
  const { m, status, label } = PAGES[i];

  const go = useCallback((next: number) => {
    setI(Math.max(0, Math.min(PAGES.length - 1, next)));
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
        <p className="mt-8 max-w-[62ch] text-[16px] leading-[1.55] text-silver">
          UseCert runs on Robinhood Chain <strong className="text-white">testnet</strong>. Nothing
          here holds real-world value, the collateral is a test token, and the perp venue is a
          simulator this project runs — so every margin and position figure describes a simulated
          position, not a market.
        </p>
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
            {PAGES.map((p, n) => (
              <button
                key={p.m.title}
                type="button"
                onClick={() => go(n)}
                aria-label={`${n + 1}. ${p.m.title}`}
                aria-current={n === i ? "step" : undefined}
                title={`${p.label} — ${p.m.title}`}
                className={cn(
                  "h-1 w-7 transition-colors md:w-9",
                  n === i ? DOT[p.status] : "bg-white/15 hover:bg-white/40",
                )}
              />
            ))}
          </div>

          <div className="mt-6 flex flex-wrap items-center justify-between gap-4">
            <p className="flex items-center gap-2 font-mono text-[11px] uppercase tracking-[0.08em] text-white-60">
              <span className={cn("h-1.5 w-1.5 rounded-full", DOT[status])} aria-hidden />
              {label}
              <span className="text-white-60/60">
                · {i + 1} of {PAGES.length}
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
                disabled={i === PAGES.length - 1}
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
            <motion.article
              key={m.title}
              initial={{ opacity: 0, y: 12 }}
              animate={{ opacity: 1, y: 0 }}
              transition={{ duration: 0.28, ease: EASE }}
            >
                <h2 className="max-w-[26ch] text-[28px] font-semibold uppercase leading-[1.05] tracking-[-0.03em] text-white md:text-[38px]">
                  {m.title}
                </h2>
                <p className="mt-5 max-w-[64ch] text-[15px] leading-[1.65] text-white-60 md:text-[16px]">
                  {m.copy}
                </p>
                {m.verify && (
                  <p className="mt-4 max-w-[64ch] font-mono text-[11px] leading-[1.6] text-green-bright/80">
                    Check it: {m.verify}
                  </p>
                )}
                {m.shot && (
                  <figure className="mt-8">
                    <a
                      href={m.shot.src}
                      target="_blank"
                      rel="noreferrer"
                      className="block"
                      aria-label={`Open full-size: ${m.shot.caption}`}
                    >
                      <img
                        src={m.shot.src}
                        alt={m.shot.alt}
                        loading="lazy"
                        decoding="async"
                        style={m.shot.maxW ? { maxWidth: m.shot.maxW } : undefined}
                        className="w-full border hairline-dark bg-[#0d0f0d] transition-opacity hover:opacity-90"
                      />
                    </a>
                    <figcaption className="mt-2 max-w-[80ch] font-mono text-[10px] leading-[1.6] text-white-60/70">
                      {m.shot.caption} <span className="text-white-60/50">Tap to enlarge.</span>
                    </figcaption>
                  </figure>
                )}
            </motion.article>
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
