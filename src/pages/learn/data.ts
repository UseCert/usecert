export type ArticleCategory = "MECHANICS" | "MARKETS" | "RISK" | "DESIGN";

export interface ArticleSection {
  heading: string;
  paragraphs: string[];
}

export interface Article {
  slug: string;
  title: string;
  subtitle: string;
  author: string;
  role: string;
  category: ArticleCategory;
  date: string;
  readTime: string;
  image: string;
  /** minimal card variant: small circular image + arrow glyph, no thumb */
  minimal?: boolean;
  quote: string;
  intro: string[];
  sections: ArticleSection[];
}

export const CATEGORIES: Array<"ALL" | ArticleCategory> = [
  "ALL",
  "MECHANICS",
  "MARKETS",
  "RISK",
  "DESIGN",
];

export const ARTICLES: Article[] = [
  {
    slug: "rwa-perps-213b-none-holdable",
    title: "RWA perps did $213B in Q2. None of it is holdable.",
    subtitle:
      "The biggest equity market on chain is a market of positions, not assets. Here is what that costs you.",
    author: "UseCert Research",
    role: "Research Desk",
    category: "MARKETS",
    date: "JUL 20, 2026",
    readTime: "6 MIN READ",
    image: "/learn-1.jpg",
    quote: "Perps are the engine. The certificate is the asset.",
    intro: [
      "Robinhood Chain settled $213B of RWA perp volume in Q2 2026, 32.2% of everything the chain did. The week of July 13, tokenized stocks and commodities were 52% of weekly volume, ahead of every crypto category for the first time ever. Open interest in RWAs hit $3.6B, passing Bitcoin. Twenty-three of the top thirty pairs are tokenized stocks and commodities.",
      "And yet, if you want to simply hold Tesla on Robinhood Chain tonight, you cannot.",
    ],
    sections: [
      {
        heading: "A market of positions, not assets",
        paragraphs: [
          "Every dollar of that exposure is a leveraged perpetual. It tracks the stock beautifully, but it is a position you must manage: funding every eight hours, margin to maintain, a liquidation price that does not care about your thesis. A perp cannot sit in a cold wallet, cannot be LP'd against USDC, cannot be posted as collateral on a lending market.",
          "This is not a complaint about perps. Perps are the engine: the deepest, most liquid, oracle-priced equity book that has ever existed on chain, running 24/7 for TSLA, AAPL, NVDA, AMZN, and a synthetic Nasdaq index. The complaint is that the engine is all there is.",
        ],
      },
      {
        heading: "The missing asset",
        paragraphs: [
          "What the market forgot to build is the boring thing: a spot token that tracks the stock and behaves like an asset. Mint it, hold it, send it, LP it, lend it, redeem it. No funding tab. No liquidation price. The stock, finally composable.",
        ],
      },
      {
        heading: "The pattern is proven",
        paragraphs: [
          "Delta-backed synthetic assets are the most battle-tested design in DeFi. Synthetix ran synths for years. Ethena holds a delta-neutral reserve with an insurance buffer and prints it transparently. The design works when the backing is verifiable and the risks are named instead of hidden.",
        ],
      },
      {
        heading: "What a certificate changes",
        paragraphs: [
          "Deposit tUSDG, the vault opens a fully backed long on the equity perp underneath, and uTSLA mints to your wallet at oracle price. Delta target 1.0, proven on-chain at every attestation with the age of the proof published. Burn it and tUSDG comes back at oracle price, never gated. Funding is buffered, then fee'd, never hidden. Holders are senior to stakers, always.",
        ],
      },
      {
        heading: "The honest boundary",
        paragraphs: [
          "Certificates are synthetic. Backed by perp positions and tUSDG margin, not custody of shares. No dividends, no shareholder rights. The solvency dashboard is public and the stress parameters are published, because the point of putting it on chain is that you should never have to take our word for it.",
        ],
      },
    ],
  },
  {
    slug: "delta-backing-explained",
    title: "Delta backing, explained without the math",
    subtitle: "One token's worth of exposure behind every certificate. What that actually means.",
    author: "UseCert Research",
    role: "Research Desk",
    category: "MECHANICS",
    date: "JUL 20, 2026",
    readTime: "5 MIN READ",
    image: "/learn-2.jpg",
    minimal: true,
    quote: "One certificate, one token's worth of exposure. Nothing else.",
    intro: [
      "Every certificate is backed by exactly one token's worth of equity perp exposure plus tUSDG margin. Not a fraction, not a promise: a position you can inspect on chain, block by block.",
      "You do not need the Greeks to understand delta backing. You need one number, and it is 1.0.",
    ],
    sections: [
      {
        heading: "What delta 1.0 means",
        paragraphs: [
          "Delta is sensitivity. When the stock moves one dollar, a delta 1.0 position moves one dollar with it, in the same direction, at the same time. The vault holds exactly enough perp exposure that each uTSLA mirrors Tesla tick for tick. No leverage on the backing, no shortfall, no tranche math.",
          "You can verify this yourself. The vault's position size and the circulating certificate supply are both public, and their ratio is printed on the solvency dashboard at every attestation, next to the age of that attestation.",
        ],
      },
      {
        heading: "The vault's two legs",
        paragraphs: [
          "The first leg is the long position on the equity perp, opened at oracle price the moment you deposit tUSDG. The second leg is the tUSDG margin that collateralizes that position. Together they are the backing of your certificate: the position tracks the stock, the margin keeps the position alive.",
        ],
      },
      {
        heading: "Why it survives volatility",
        paragraphs: [
          "Because the exposure is linear and fully margined, a sharp move in the stock moves the certificate and its backing together. There is no moment where the asset is worth one thing and the backing another. Funding is the only slow leak, and funding is buffered first, which is a separate article.",
        ],
      },
      {
        heading: "Where it can break (named plainly)",
        paragraphs: [
          "Three ways. An oracle failure, which is why minting pauses on stale or deviant prices while redemption continues at the last good price. Sustained negative funding beyond the buffer, which passes through as a transparent holding fee instead of a quiet depeg. And an extreme market gap faster than keepers can rebalance, which is what the staked insurance buffer exists to absorb. The stress parameters for all three are published.",
        ],
      },
    ],
  },
  {
    slug: "funding-buffered-then-feed",
    title: "Funding: buffered, then fee'd, never hidden",
    subtitle: "How perp funding becomes a buffer, a fee, and never a silent depeg.",
    author: "UseCert Research",
    role: "Research Desk",
    category: "RISK",
    date: "JUL 18, 2026",
    readTime: "5 MIN READ",
    image: "/learn-3.jpg",
    quote: "Buffered, then fee'd, never hidden.",
    intro: [
      "Every perp pays or receives funding. Every synthetic asset built on perps has to answer one question: who absorbs it when it runs negative for a month. Most designs answer quietly. Ours answers on chain.",
    ],
    sections: [
      {
        heading: "What funding is",
        paragraphs: [
          "Funding is the periodic payment between longs and shorts that pins a perpetual to its index price. On the equity perp book it settles every eight hours, and it can run either sign for weeks. A certificate holder never opens a funding tab, but the vault underneath holds a real perp, so funding is a real cash flow that has to land somewhere.",
        ],
      },
      {
        heading: "The BufferBook thresholds",
        paragraphs: [
          "Positive funding accrues to a per-asset buffer. Sustained negative funding draws that buffer down first. Three published thresholds govern what happens next: past fee_on, the remainder passes through as a transparent holding fee; past mint_slow, new minting is throttled to protect the buffer; past insurance_draw, the staked insurance buffer covers the difference before holder backing is ever touched.",
        ],
      },
      {
        heading: "Who pays what, when",
        paragraphs: [
          "Holders pay nothing while the buffer is positive, and a published fee only after it is exhausted. Stakers underwrite the tail beyond that, and are compensated for it with a share of protocol fees. Keepers sweep accrued funding into the buffer every hour, so the balance the dashboard shows is always current.",
        ],
      },
      {
        heading: "Why transparency is the mechanism",
        paragraphs: [
          "Hidden funding is how synthetic assets quietly depeg: the cost builds up off balance sheet until it cannot. Publishing the buffer balance on-chain turns funding from a surprise into a signal. You never have to take our word for the state of the buffer, because the state of the buffer is the chain.",
        ],
      },
    ],
  },
  {
    slug: "holders-are-senior",
    title: "Why holders are senior to stakers",
    subtitle: "Someone is first in line when the buffer breaks. It is never you.",
    author: "UseCert Research",
    role: "Research Desk",
    category: "DESIGN",
    date: "JUL 14, 2026",
    readTime: "4 MIN READ",
    image: "/learn-4.jpg",
    quote: "Holders are senior, always. That is the whole product.",
    intro: [
      "Every system that pools risk has a seniority stack, whether it admits it or not. We would rather print ours on the front page: when something breaks, losses are absorbed in a fixed order, and holders are last in that order.",
    ],
    sections: [
      {
        heading: "The seniority stack",
        paragraphs: [
          "The order is fixed in the contracts. The per-asset funding buffer absorbs the first loss. The staked insurance buffer absorbs the second. Holder backing is never impaired by either. There is no governance vote that can reorder this, and no emergency mode that can touch holder margin to cover a staking shortfall.",
        ],
      },
      {
        heading: "What stakers earn and why",
        paragraphs: [
          "Stakers underwrite the insurance buffer, and underwriting is a job. For it they earn the majority share of mint and redeem fees plus funding-surplus fees. The yield is not magic; it is the price of standing behind holders in line.",
        ],
      },
      {
        heading: "Slashing, described honestly",
        paragraphs: [
          "If the funding buffer runs out and the insurance draw threshold is crossed, staked tokens are slashed pro rata to make holders whole. The sizing comes from the published stress parameters, not discretion. Stakers opt into this explicitly, and the expected loss distribution is printed next to the yield.",
        ],
      },
      {
        heading: "The 80/10/5/5 fee flow",
        paragraphs: [
          "Protocol fees split 80/10/5/5: 80% to stakers as underwriting compensation, 10% to top up the insurance buffer, 5% to keepers who run the peg infrastructure, and 5% to the treasury. Every flow is an on chain transfer you can audit, not an accounting line you have to trust.",
        ],
      },
    ],
  },
  {
    slug: "oracle-guards",
    title: "The oracle guards that keep minting honest",
    subtitle: "Staleness, deviation, halt: three guards between you and a bad price.",
    author: "UseCert Research",
    role: "Research Desk",
    category: "MECHANICS",
    date: "JUL 10, 2026",
    readTime: "5 MIN READ",
    image: "/learn-5.jpg",
    minimal: true,
    quote: "A bad price is worse than no price.",
    intro: [
      "Certificates mint and redeem at oracle price, which makes the oracle the single most important input in the system. CertOracle treats every price as guilty until proven innocent, and three guards do the proving.",
    ],
    sections: [
      {
        heading: "CertOracle's three guards",
        paragraphs: [
          "Staleness: any price older than its heartbeat is rejected outright. Deviation: any print outside the guard bands against reference venues is rejected, even if it is fresh. Halt: an operator circuit breaker that freezes minting system-wide if the first two guards trip together. Three independent checks, each fail-closed.",
        ],
      },
      {
        heading: "Why minting pauses but redemption does not",
        paragraphs: [
          "Minting at a bad price manufactures unbacked certificates, which harms every existing holder. Redemption at the last good price simply returns margin that is already in the vault. One direction creates risk, the other releases it, so the guards treat them differently by design.",
        ],
      },
      {
        heading: "Last-good-price redemption",
        paragraphs: [
          "When the feed goes stale, redemption does not stop and does not guess. It settles at the most recent price that passed all three guards, with the timestamp printed next to it. You always know which price you were paid at and why.",
        ],
      },
      {
        heading: "Timelocked upgrades",
        paragraphs: [
          "Oracle parameters, guard bands, and contract upgrades all sit behind a timelock. Every change is announced on chain before it can activate, so there is a public window to review, object, or exit. Infrastructure that asks for trust should never be able to change the rules overnight.",
        ],
      },
    ],
  },
  {
    slug: "what-keepers-do",
    title: "What keepers do while you sleep",
    subtitle: "Five permissionless jobs that hold the peg together.",
    author: "UseCert Research",
    role: "Research Desk",
    category: "DESIGN",
    date: "JUL 06, 2026",
    readTime: "4 MIN READ",
    image: "/learn-6.jpg",
    quote: "The peg is not a promise. It is jobs that run, and a proof with its age printed on it.",
    intro: [
      "No one at UseCert presses a button to keep certificates tracking. The peg is maintained by keepers: permissionless bots that anyone can run, paid from protocol fees, doing five small jobs around the clock.",
    ],
    sections: [
      {
        heading: "Delta-keeper and the band check",
        paragraphs: [
          "The delta-keeper watches each vault's exposure ratio. When drift from fees, funding, or price movement pushes delta outside its band, it rebalances the perp position back to 1.0. Small, frequent corrections instead of large, rare ones.",
        ],
      },
      {
        heading: "The hourly funding sweep",
        paragraphs: [
          "Every hour, a keeper settles accrued funding into the per-asset buffer. This is what keeps the BufferBook balance honest: the number on the dashboard is never more than an hour away from the number on the exchange.",
        ],
      },
      {
        heading: "Snapshots and the public dashboard",
        paragraphs: [
          "An attester publishes the solvency state each venue batch, roughly every 60 seconds, and the vault publishes how old that state is alongside it. The public dashboard is a read layer over those attestations, which is why solvency at UseCert is proven on a ~60-second cadence with its age on screen, rather than in a monthly report.",
        ],
      },
      {
        heading: "The watchdog and the indexer",
        paragraphs: [
          "The watchdog monitors the oracle guards and halt conditions and raises the alarm the block anything trips. The indexer serves positions, history, and fee flows to the interface so the app you use reads the same chain everyone else does.",
        ],
      },
      {
        heading: "Running one yourself for the bounty",
        paragraphs: [
          "Keeper software is open source and the jobs are permissionless. Run one, and you earn the keeper share of protocol fees, plus bounties on watchdog alerts that catch real faults. The system is designed so that its most paranoid participant is also its best paid one.",
        ],
      },
    ],
  },
];

export function getArticle(slug: string | undefined): Article | undefined {
  return ARTICLES.find((a) => a.slug === slug);
}
