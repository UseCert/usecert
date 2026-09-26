export type VaultStatus = "LIVE" | "SOON";

export interface VaultStat {
  value: number;
  prefix?: string;
  suffix?: string;
  decimals?: number;
  caption: string;
}

export interface VaultData {
  slug: string;
  /** Display name, e.g. "uTSLA" (rendered uppercase in headlines) */
  name: string;
  tagline: string;
  intro: string;
  image: string;
  /** Bottom meta row tags on index cards + next-vault card */
  tags: string;
  /** Filter categories: "stock" | "index" */
  category: "stock" | "index";
  status: VaultStatus;
  year: string;
  problem: [string, string];
  approach: [string, string];
  stats: [VaultStat, VaultStat];
  resultsCopy: string;
  quote: { text: string; name: string; role: string; image: string };
  /* The `snapshot` field (a hardcoded price and circulating supply, rendered as a live
   * feed on the detail page) was removed: no number on a public page may come from here
   * rather than from a contract read. The dashboard reads those figures on chain. */
  /** SOON vaults only: roadmap media copy */
  roadmapCopy?: string;
}

const FUNDING_PARA =
  "Funding accrues to a per-asset buffer: positive funding grows it, sustained negative funding draws it down, and past a published threshold the remainder becomes a transparent holding fee. Buffered, then fee'd, never hidden.";

export const VAULTS: VaultData[] = [
  {
    slug: "utsla",
    name: "uTSLA",
    tagline: "Tesla, as a holdable certificate. Mint it, LP it, lend it, redeem it.",
    intro:
      "The uTSLA vault holds a fully backed long on the Tesla equity perp on Robinhood Chain and mints certificates against it, one token's worth of exposure plus USDG margin behind every certificate in circulation.",
    image: "/vault-utsla.jpg",
    tags: "Single Stock, Mint + Redeem",
    category: "stock",
    status: "LIVE",
    year: "2026",
    problem: [
      "Tesla is one of the deepest books on Robinhood Chain, and every dollar of it is a leveraged perp. If you want TSLA exposure today, you are managing funding, margin, and a liquidation price around the clock.",
      "A perp is a position, not an asset. You cannot LP it, post it as collateral, or hold it and walk away. The most traded stock on chain was also the least ownable.",
    ],
    approach: [
      "The vault opens an equivalent long on the Tesla equity perp the moment you deposit. Delta target 1.0, enforced by a band check on each attested batch and rebalanced permissionlessly: rebalance() is callable by anyone.",
      FUNDING_PARA,
    ],
    stats: [
      {
        value: 100,
        suffix: "%",
        decimals: 2,
        caption: "Backing ratio target, enforced in the vault's solvency math at each attestation",
      },
      { value: 0, caption: "Conditions that can refuse a redemption — forceExit is gated on nothing. Above the instant cap redemption is queued, not refused." },
    ],
    resultsCopy:
      "Deposit USDG, receive uTSLA at oracle price in the same transaction. Burn uTSLA, receive USDG back the same way. The vault's solvency math is proven on-chain at every attestation and published with the age of that proof, so none of this requires trusting us.",
    quote: {
      text: "I stopped checking funding rates the day I minted. It tracks Tesla, it sits in my wallet, and I can leave whenever I want. That did not exist before.",
      name: "",
      role: "Holder",
      image: "/testimonial-1.jpg",
    },
  },
  {
    slug: "unvda",
    name: "uNVDA",
    tagline: "Nvidia, as a holdable certificate. Mint it, LP it, lend it, redeem it.",
    intro:
      "The uNVDA vault holds a fully backed long on the Nvidia equity perp on Robinhood Chain and mints certificates against it, one token's worth of exposure plus USDG margin behind every certificate in circulation.",
    image: "/vault-unvda.jpg",
    tags: "Single Stock, Mint + Redeem",
    category: "stock",
    status: "LIVE",
    year: "2026",
    problem: [
      "Nvidia prints the loudest candles on Robinhood Chain, and all of that flow sits in leveraged perps. Holding the AI trade through the week means babysitting funding, margin, and a liquidation price while the market never sleeps.",
      "A perp is a position, not an asset. You cannot LP it, post it as collateral, or set it down and walk away. The most wanted exposure on chain was the hardest to actually own.",
    ],
    approach: [
      "The vault opens an equivalent long on the Nvidia equity perp the moment you deposit. Delta target 1.0, enforced by a band check on each attested batch and rebalanced permissionlessly: rebalance() is callable by anyone.",
      FUNDING_PARA,
    ],
    stats: [
      {
        value: 100,
        suffix: "%",
        decimals: 2,
        caption: "Backing ratio target, enforced in the vault's solvency math at each attestation",
      },
      { value: 0, caption: "Conditions that can refuse a redemption — forceExit is gated on nothing. Above the instant cap redemption is queued, not refused." },
    ],
    resultsCopy:
      "Deposit USDG, receive uNVDA at oracle price in the same transaction. Burn uNVDA, receive USDG back the same way. The vault's solvency math is proven on-chain at every attestation and published with the age of that proof, so none of this requires trusting us.",
    quote: {
      text: "It is the first AI-shaped asset on chain that behaves like an asset. We listed uNVDA as collateral the same week the vault opened.",
      name: "",
      role: "DeFi Builder",
      image: "/testimonial-2.jpg",
    },
  },
  /* uSPX IS GONE, and it is not coming back.
   *
   * The entry here promised a vault that cannot be built: the venue has no SPX perpetual,
   * so a uSPX mirror would have nothing to hedge against. The live RWA perp markets are
   * TSLA, NVDA, SPY, QQQ, AAPL, AMZN, MSFT, GOOGL, META, HOOD, PLTR, COIN, MSTR, AMD, INTC,
   * MU, MRVL, CRCL and SNDK. SPY is the instrument that tracks that index, and uSPY is
   * deployed and live on chain 46630 — so the exposure this page advertised is available
   * under a name that exists. No placeholder is left in its place, because a vaguer
   * placeholder would carry the same promise. Do not add an entry for any asset without a
   * perp market behind it. */
  {
    slug: "uqqq",
    name: "uQQQ",
    tagline: "The Nasdaq, as a holdable certificate. Mint it, LP it, lend it, redeem it.",
    intro:
      "The uQQQ vault holds a fully backed long on the Nasdaq 100 perp on Robinhood Chain and mints certificates against it, one token's worth of exposure plus USDG margin behind every certificate in circulation.",
    image: "/vault-uqqq.jpg",
    tags: "Index, Mint + Redeem",
    category: "index",
    status: "LIVE",
    year: "2026",
    problem: [
      "The Nasdaq 100 is where on chain traders go for tech beta, and every unit of it is a leveraged perp position. Holding it means funding, margin, and a liquidation price on what should be a long term allocation.",
      "Tech beta is a portfolio decision, not an intraday position. On Robinhood Chain it was locked inside an instrument that forces you to trade it like one.",
    ],
    approach: [
      "The vault opens an equivalent long on the Nasdaq 100 perp the moment you deposit. Delta target 1.0, enforced by a band check on each attested batch and rebalanced permissionlessly: rebalance() is callable by anyone.",
      FUNDING_PARA,
    ],
    stats: [
      {
        value: 100,
        suffix: "%",
        decimals: 2,
        caption: "Backing ratio target, enforced in the vault's solvency math at each attestation",
      },
      { value: 0, caption: "Conditions that can refuse a redemption — forceExit is gated on nothing. Above the instant cap redemption is queued, not refused." },
    ],
    resultsCopy:
      "Deposit USDG, receive uQQQ at oracle price in the same transaction. Burn uQQQ, receive USDG back the same way. The vault's solvency math is proven on-chain at every attestation and published with the age of that proof, so none of this requires trusting us.",
    quote: {
      text: "The whole desk runs tech beta through perps today. A certificate turns that trade into inventory we can actually hold.",
      name: "",
      role: "DeFi Builder",
      image: "/testimonial-2.jpg",
    },
  },
  {
    slug: "uaapl",
    name: "uAAPL",
    tagline: "Apple, as a holdable certificate. Mint it, LP it, lend it, redeem it.",
    intro:
      "The uAAPL vault will hold a fully backed long on the Apple equity perp on Robinhood Chain and mint certificates against it, one token's worth of exposure plus USDG margin behind every certificate in circulation.",
    image: "/vault-uaapl.jpg",
    tags: "Single Stock, Roadmap C2",
    category: "stock",
    status: "SOON",
    year: "2026",
    problem: [
      "Apple is the benchmark equity of public markets, and on Robinhood Chain it trades only as a leveraged perp. If you want AAPL exposure today, you are running a position with funding and a liquidation price instead of holding the stock.",
      "The most widely held stock in the world was unownable on chain. You could trade it around the clock, but you could not hold it, LP it, or post it as collateral.",
    ],
    approach: [
      "When the vault deploys, it opens an equivalent long on the Apple equity perp the moment you deposit. Delta target 1.0, enforced by a band check on each attested batch and rebalanced permissionlessly: rebalance() is callable by anyone.",
      FUNDING_PARA,
    ],
    stats: [
      {
        value: 100,
        suffix: "%",
        decimals: 2,
        caption: "Backing ratio target, hard-coded into the vault's solvency math",
      },
      { value: 0, caption: "Conditions that can refuse a redemption — forceExit is gated on nothing. Above the instant cap redemption is queued, not refused." },
    ],
    resultsCopy:
      "Deposit USDG, receive uAAPL at oracle price in the same transaction. Burn uAAPL, receive USDG back the same way. Solvency math will be proven on-chain at every attestation from deployment, published with the age of each proof, so none of this requires trusting us.",
    quote: {
      text: "AAPL is the asset every newcomer asks for first. Giving them a certificate instead of a perp is the right front door.",
      name: "",
      role: "Holder",
      image: "/testimonial-1.jpg",
    },
    roadmapCopy: "This vault deploys in phase C2.",
  },
];

export function getVault(slug: string | undefined): VaultData {
  return VAULTS.find((v) => v.slug === slug) ?? VAULTS[0];
}

export function nextVault(slug: string): VaultData {
  const i = VAULTS.findIndex((v) => v.slug === slug);
  return VAULTS[(i + 1) % VAULTS.length];
}
