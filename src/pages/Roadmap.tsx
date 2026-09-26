import { motion } from "framer-motion";
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

function Section({
  label,
  status,
  items,
}: {
  label: string;
  status: Status;
  items: Milestone[];
}) {
  const dot =
    status === "shipped" ? "bg-green-bright" : status === "building" ? "bg-warn" : "bg-white-60";
  return (
    <div className="mt-16 first:mt-0 md:mt-24">
      <p className="flex items-center gap-2 font-mono text-[11px] uppercase tracking-[0.08em] text-white-60">
        <span className={cn("h-1.5 w-1.5 rounded-full", dot)} aria-hidden />
        {label}
        <span className="text-white-60/60">· {items.length}</span>
      </p>
      <div className="mt-8 grid border-t hairline-dark md:grid-cols-2">
        {items.map((m, i) => (
          <motion.div
            key={m.title}
            className={cn(
              "border-b hairline-dark py-8 md:px-8 md:first:pl-0",
              "md:[&:nth-child(odd)]:pl-0 md:[&:nth-child(even)]:border-l",
              // A card carrying a screenshot takes the whole row. In a half-width column
              // these images render around 600px against a 2324px natural - the table text
              // lands near six pixels and cannot be read, which makes the screenshot
              // decoration. Full width puts it back at roughly its original size.
              m.shot && "md:col-span-2 md:!border-l-0 md:!pl-0",
            )}
            initial={{ opacity: 0, y: 20 }}
            whileInView={{ opacity: 1, y: 0 }}
            viewport={{ once: true, amount: 0.2 }}
            transition={{ delay: Math.min(i, 4) * 0.06, duration: 0.5, ease: EASE }}
          >
            <p className="text-[19px] font-semibold uppercase leading-[1.1] tracking-[-0.03em] text-white lg:text-[22px]">
              {m.title}
            </p>
            <p className="mt-3 max-w-[52ch] text-[13px] leading-[1.6] text-white-60">{m.copy}</p>
            {m.verify && (
              <p className="mt-3 font-mono text-[11px] leading-[1.6] text-green-bright/80">
                Check it: {m.verify}
              </p>
            )}
            {/* Lazy, and with width and height declared, so four screenshots below the fold
                cost nothing on arrival and reserve their space instead of shifting the
                text as they load. */}
            {m.shot && (
              <figure className="mt-5">
                {/* Opens the file itself. On a phone these captures sit at 343px - a 1134px
                    table is unreadable there and no amount of layout fixes that, so the
                    honest remedy is a way to see it full size rather than pretending the
                    thumbnail is legible. */}
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
          </motion.div>
        ))}
      </div>
    </div>
  );
}

export default function RoadmapPage() {
  return (
    <section className="grain bg-ink text-white">
      <div className="relative z-[2] mx-auto max-w-[1440px] px-4 py-24 md:px-6 md:py-32 lg:px-12">
        <p className="font-mono text-[11px] uppercase tracking-[0.08em] text-white-60">Milestones</p>
        <h1 className="mt-4 max-w-[18ch] text-[44px] font-semibold uppercase leading-[0.85] tracking-[-0.05em] md:text-[60px] lg:text-[78px]">
          What works<span className="text-green-bright">,</span> and what does not yet
        </h1>

        {/* The disclosure a reader needs before anything below means what it appears to
            mean. It leads rather than sits in a footnote, because someone who reads only
            the first paragraph should still leave with the correct impression. */}
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

        <Section label="Shipped" status="shipped" items={SHIPPED} />
        <Section label="Building" status="building" items={BUILDING} />
        <Section label="Before mainnet" status="planned" items={BEFORE_MAINNET} />

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
