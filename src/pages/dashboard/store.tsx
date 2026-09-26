/* eslint-disable react-refresh/only-export-components */
/**
 * Dashboard state, fed by the live UseCert deployment on Robinhood Chain testnet
 * (chain 46630) through the stage-1 chain layer in `src/chain/`.
 *
 * ─────────────────────────────────────────────────────────────────────────────────────
 * WHAT CHANGED FROM THE MOCK STORE
 * ─────────────────────────────────────────────────────────────────────────────────────
 * The `Vault` / `SeriesPoint` / `FundingBar` shapes the components already consume are
 * kept, so the component library did not have to be rewritten. What changed is where the
 * numbers come from and — more importantly — what happens when there is no number.
 *
 * Every figure that has no on-chain source is `null`, never `0`. That is deliberate and
 * it is type-enforced: `price`, `supply`, `buffer`, `deltaView`, `capacity`, `change24h`,
 * `funding8h`, `ageSec`, `hotBuffer`, `bufferCapacity` and `backing` are all nullable, so a
 * component cannot render one without deciding what to show when it is absent. Use
 * `fmtOrDash` from `./format` — a greyed card with invented figures is worse than the mock
 * was, because it looks authoritative.
 *
 * DERIVED RATIOS OBEY THE SAME RULE, which stage 2 did not enforce. Nulling the INPUTS is
 * only half the job: `margin / notional` and `solvency.deltaBps` both had real inputs and
 * still printed nonsense, because the first divides by a zero the old code clamped to $1 and
 * the second is a ratio whose 10_000-bps centre was being read as "100% off target". Any
 * quotient reaching the screen must be `null` where its denominator is zero or absent, and
 * any on-chain sentinel must be decoded before it is formatted — see `Totals.ratio` and
 * `DeltaView`.
 *
 * THE VAULTS. All four mirrors in the address book are deployed on chain 46630 and routed
 * here, and there is nothing else in the list:
 *
 *   utsla  LIVE  market 16, venue-verified
 *   uspy   LIVE  market 26, index NOT venue-verified
 *   uqqq   LIVE  market 27, index NOT venue-verified
 *   unvda  LIVE  market 15, venue-verified
 *
 * uSPX IS GONE, and its removal is a correction rather than a tidy-up. The row said
 * "uSPX · SOON", and that promised a vault that cannot be built: the venue has no SPX
 * perpetual, so a uSPX mirror would have nothing to hedge against. The live RWA perp
 * markets are TSLA, NVDA, SPY, QQQ, AAPL, AMZN, MSFT, GOOGL, META, HOOD, PLTR, COIN, MSTR,
 * AMD, INTC, MU, MRVL, CRCL and SNDK. SPY is the instrument that tracks that index and it
 * is already live here, so the exposure the row implied is available under a name that
 * exists. Do not reinstate uSPX, or any other id, without a perp market behind it.
 *
 * `UNROUTED` is therefore empty, and `VaultStatus` keeps `SOON` / `UNPLANNED` on purpose:
 * the greyed, non-interactive, figure-free rendering path is still the correct answer for
 * the next id the roadmap adds ahead of its contracts, and deleting it would mean rebuilding
 * it under deadline. What must not come back is a status on an id the protocol cannot ship.
 *
 * MARKET INDEX PROVENANCE. Two of the four indices were read back from the venue and two
 * were chosen (`marketIndexVerified` in `deployments/46630.json`, mirrored in
 * `MARKET_INDEX_VERIFIED`). `Vault.marketIndexVerified` carries that per row so four indices
 * cannot be presented as four equally confirmed indices.
 *
 * BUFFER vs ACCRUAL. `backing.bufferHeld` (a real ERC-20 balance) and
 * `backing.accrualClaimedUnverified` (an attester's claim that nothing on-chain verifies)
 * must never be summed or shown as one figure. They were one field once, published as
 * "the buffer", and it was the ledger: 100,000.01 published against 91,028.00 actually
 * held. `totals` sums them separately for the same reason.
 *
 * AGE. `ageSec` travels with backing everywhere; `attestationStale` is the documented
 * 300 s limit past which capacity is zero and minting is off.
 *
 * HISTORY. There is no on-chain source for the 60-point solvency series or the 48 funding
 * bars, and none for a 24h change or an 8h funding rate. `historyUnavailable` /
 * `change24hUnavailable` / `funding8hUnavailable` are on, the arrays are empty, and the
 * views render an honest empty state. Nothing is interpolated.
 *
 * FLOWS ARE NO LONGER HERE, AND NO LONGER ABSENT. `flows` / `flowsUnavailable` /
 * `loadMoreFlows` and the `Flow` / `FlowType` shapes are gone from this provider. The flow
 * list is not a contract read, so it does not belong in a provider whose contract is "every
 * number published here came from a contract read": it comes from the chain's public
 * Blockscout index over HTTP — a THIRD provenance class, neither a chain read nor an
 * attester claim. It lives in `src/chain/useFlows.ts`, is consumed directly by the views
 * through react-query (one shared cache entry, no prop threading), and is rendered under
 * `ExplorerSourcedTag` / `ExplorerSourceNote`. Do not re-export it from here: keeping it
 * out is what stops an explorer-sourced figure sharing a register with a `useReadContracts`
 * one.
 *
 * NOTHING IS MOCKED ANY MORE. The staking state (`tokenLiquid`, `tokenStaked`,
 * `totalStaked`, `rewards`, `cooldowns`) and the keeper list (`keepers`, `runKeeper`) were
 * the last invented numbers in this app, and they are gone along with the two views that
 * rendered them. `InsuranceStaking` and `CERT` are C3 and are not deployed, and four of
 * the five advertised keepers never existed — only `recallMargin()` and `rebalance()` are
 * real, and both are already exposed on `useCertActions`. Do not reintroduce a generator
 * here: every number this provider publishes must come from a contract read.
 */
import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState } from "react";
import type { ReactNode } from "react";
import { useBlockNumber, useConnection, useDisconnect, useSwitchChain } from "wagmi";

import { CHAIN_ID, isSupportedChain } from "@/chain/config";
import {
  CHAIN_VAULT_IDS,
  MAX_ATTESTATION_AGE_SEC,
  aggregateTotals,
  chainVaultMeta,
  isMarketIndexVerified,
  useLiveVaults,
  useUserBalances,
  useVaultConfigs,
  type CapacityView,
  type ChainVaultId,
  type DeltaView,
  type LiveVault,
  type VaultConfigView,
} from "@/chain/useVaults";
import { explainChainFailure } from "@/chain/walletSupport";
import {
  signerCovers,
  useSignerFreshness,
  type SignerFreshness,
} from "@/chain/useSignerFreshness";

/* ------------------------------------------------------------------ types */

/**
 * Ids with no contracts on chain 46630 that the UI nevertheless shows.
 *
 * `never` today: every id in the list is deployed. It is a named type rather than nothing at
 * all because that is the seam — widen this, not `VaultId`, when the roadmap gets a row
 * before it gets a vault, and the compiler will walk you through `UNROUTED`, `positions`
 * and every consumer that has to decide what to render without figures.
 *
 * The id that used to live here was `uspx`, and it was removed because no SPX perpetual
 * exists on the venue — see the file header. An id belongs here only if a perp market
 * behind it plausibly will.
 */
export type UnroutedVaultId = never;

/**
 * Every id the dashboard knows: the deployed mirrors, plus the unrouted ids above.
 *
 * `ChainVaultId` is derived from the generated address book, so this union widens on its own
 * when a mirror is added to `contracts.ts` — and `isChainVaultId` stays the only door from
 * here into the write path, whether or not it currently rejects anything.
 */
export type VaultId = ChainVaultId | UnroutedVaultId;
/**
 * `staking` and `keepers` are deliberately absent: neither an insurance-staking contract
 * nor a keeper-rewards mechanism is deployed on chain 46630, and the views that used to
 * render them ran entirely on invented figures.
 */
export type ViewId = "overview" | "vaults" | "mint" | "activity" | "risk";
/* `FlowType` ("MINT" | "REDEEM" | "CLAIM") is gone. Three values cannot describe these
 * contracts: the two-step paths have a request, a settle and a refund, and `ForceExited`
 * is a fourth outcome. The eight real event kinds live in `FlowKind`
 * (`src/chain/useFlows.ts`), next to the code that decodes them. */
export type Timeframe = "1H" | "24H" | "7D" | "ALL";

/**
 * `LIVE` — a vault, certificate and oracle exist on chain 46630 and the figures are read
 * from them. `SOON` — on the published roadmap for a later phase. `UNPLANNED` — no
 * contracts and no announced plan.
 *
 * Every vault is `LIVE` today; the other two are kept for the reason given in the file
 * header. Neither may be applied to an asset the venue has no perp market for.
 */
export type VaultStatus = "LIVE" | "SOON" | "UNPLANNED";

/** Badge text per status. Only `LIVE` may ever sit next to a number. */
export const STATUS_LABEL: Record<VaultStatus, string> = {
  LIVE: "LIVE",
  SOON: "SOON",
  UNPLANNED: "NOT PLANNED",
};

/** Why a vault shows no figures. Used as the title/tooltip on greyed rows. */
export const STATUS_HINT: Record<VaultStatus, string> = {
  LIVE: "Deployed and routed on Robinhood Chain testnet (chain 46630).",
  SOON: "On the roadmap for a later phase. No contracts are deployed, so no figures are shown.",
  UNPLANNED:
    "Not deployed and not currently planned. No contracts are deployed, so no figures are shown.",
};

export interface SeriesPoint {
  backing: number;
  obligation: number;
}

export interface FundingBar {
  rate: number; // percent, hourly
  accrued: number; // USD to buffer that hour
  bufferAfter: number; // USD
}

/**
 * The two solvency numbers that must never be conflated, kept apart by name.
 * Structurally identical to `BackingBreakdown` in `src/chain/useVaults.ts`, which is
 * where the on-chain provenance of each field is documented.
 */
export interface VaultBacking {
  /** `solvency.buffer18` — the vault's OWN ERC-20 collateral balance. Ground truth. */
  bufferHeld: number;
  /**
   * `solvency.accrual18` — attester-relayed cumulative P&L. NOT money, nothing on-chain
   * verifies it, and it genuinely goes negative. Never add it to `bufferHeld`.
   */
  accrualClaimedUnverified: number;
  /** Always `false`, so no consumer can render the accrual without its status in hand. */
  accrualIsVerified: false;
  /** `solvency.margin18` — margin at the venue, FROM THE ATTESTATION. */
  margin: number;
  /** `solvency.notional18` — perp position notional, FROM THE ATTESTATION. */
  notional: number;
  /** `solvency.provenAtBatch` — the venue batch all of the above rests on. */
  provenAtBatch: number;
}

/**
 * One row of the dashboard's vault model.
 *
 * Kept assignment-compatible with `LiveVault` in `src/chain/useVaults.ts`
 * (`LiveVault extends Omit<Vault, "id" | "price">`), so a live vault IS a `Vault` and the
 * compiler fails in the chain layer if these two drift apart.
 */
export interface Vault {
  id: VaultId;
  name: string;
  full: string;
  img: string;
  /** True when `img` is a stand-in rather than this certificate's own plate. */
  imgPlaceholder: boolean;
  status: VaultStatus;
  /** True while a routed vault's first multicall is still in flight. */
  loading?: boolean;

  /**
   * Was this mirror's venue `marketIndex` READ from the venue, or CHOSEN? `null` when the
   * vault is not routed, because an undeployed vault has no index at all.
   *
   * Nullable and non-optional so that every construction site has to answer it, exactly
   * like the figures below. Wherever the market index is rendered, this has to be rendered
   * with it: uTSLA 16 and uNVDA 15 were read from the venue's `api/v1/orderBookDetails`,
   * uSPY 26 and uQQQ 27 were placeholders, and showing all four the same way asserts a
   * confirmation that only half of them have. See `MARKET_INDEX_VERIFIED`.
   */
  marketIndexVerified: boolean | null;

  /** `oracle.px()`. `null` when it reverted (see `priceUnavailable`) or is not routed. */
  price: number | null;
  /** `oracle.px()` reverted: the oracle is stale, deviant or badly fed. A state, not an error. */
  priceUnavailable: boolean;
  /** `oracle.mintAllowed()`. False means new mints are refused; redemption still works. */
  mintAllowed: boolean;

  /** No on-chain source. Always `null` with `change24hUnavailable` set. */
  change24h: number | null;
  change24hUnavailable: boolean;

  supply: number | null; // certificate units, 18 dp
  /** Collateral the vault actually holds — `backing.bufferHeld` and nothing else. */
  buffer: number | null; // USD
  /**
   * `solvency.deltaBps`, DECODED. `null` when the vault is not routed.
   *
   * `bufferPct`, `delta` and `deltaBps` are all gone from this shape on purpose:
   *
   *  *  `bufferPct` was `bufferHeld / bufferCapacity18()`, which is pinned near 1% at every
   *     fill level by construction and reached 100% at none. See `CapacityView`.
   *  *  `deltaBps` was `solvency.deltaBps / 100` rendered as "% from target". The field is a
   *     hedge-to-obligation RATIO in bps (`CertVault.sol:1600`) where 10_000 is dead centre,
   *     so that label inverted it: a perfectly hedged vault read "100.00% from target" and a
   *     completely unhedged one reads a reassuring "0.00%".
   *  *  `delta` was `1 + deltaBps/10_000`, which makes an at-target vault 2.0. Nothing
   *     rendered it, and it is not being kept for something to.
   */
  deltaView: DeltaView | null;
  /** The bounded mint-ceiling indicator. `null` when the vault is not routed. */
  capacity: CapacityView | null;

  /** No on-chain source (accrual is a cumulative claim, not a rate). Always `null`. */
  funding8h: number | null;
  funding8hUnavailable: boolean;

  /** Split solvency. `null` when the vault is not routed. */
  backing: VaultBacking | null;
  /** Seconds since the attestation this backing rests on. Show it wherever backing shows. */
  ageSec: number | null;
  /** `ageSec > 300`: capacity is zero and minting is off. The likeliest "looks broken". */
  attestationStale: boolean;

  /** `known` from `oracle.basisBpsChecked()`. False means there is NO basis to compute. */
  basisKnown: boolean;
  /** `bps` in percent, or `null` when unknown — `null` is not `0`. */
  basisBps: number | null;

  hotBuffer: number | null; // `vault.hotBuffer()`, 6 dp — the instant-redeem float
  bufferCapacity: number | null; // `vault.bufferCapacity18()` — headroom for new mints

  /** One real point for a routed vault, empty otherwise. Never an invented curve. */
  solvency: SeriesPoint[];
  /** Always empty: no view function returns funding history. */
  funding: FundingBar[];
  historyUnavailable: boolean;
}

/** True when this vault has contracts on chain 46630 and may show figures. */
export function isRouted(v: Vault): boolean {
  return v.status === "LIVE";
}

/**
 * Narrows a UI vault id to one the chain layer will accept.
 *
 * Anything heading for `useCertActions`, `useVaultConfig` or an address lookup passes
 * through here, so the write path cannot be handed an id with no vault behind it. Every id
 * happens to pass today — `UnroutedVaultId` is `never` — and the guard is kept anyway,
 * checked against the generated `CHAIN_VAULT_IDS` rather than a literal pair, so it is
 * correct by construction for whatever the address book holds next.
 */
export function isChainVaultId(id: VaultId): id is ChainVaultId {
  return (CHAIN_VAULT_IDS as readonly string[]).includes(id);
}

/** How many mirrors the generated address book routes. Never write this number by hand. */
export const ROUTED_VAULT_COUNT = CHAIN_VAULT_IDS.length;

/* The `Flow` shape is gone too, and would have been wrong for real data: it required a
 * non-null `price` on every row (`RedeemClaimed` carries none), carried `feeBps` when the
 * events emit a fee AMOUNT in 6-decimal collateral, and had a numeric `id` with no relation
 * to a log. `FlowEvent` in `src/chain/useFlows.ts` replaces it, with every optional leg
 * nullable and the decimal domain of each field named. */

export interface Toast {
  id: number;
  state: "pending" | "success";
  title: string;
  desc?: string;
}

export interface MintPreset {
  tab: "mint" | "redeem";
  asset: VaultId;
  nonce: number;
}

/** Protocol-wide sums. `null` until the first multicall succeeds — never zeroes. */
export interface Totals {
  /** Attested perp position notional across routed vaults. */
  notional: number;
  /** Attested margin at the venue. */
  margin: number;
  /** Collateral actually held (sum of `bufferHeld`). */
  buffer: number;
  /** Attester's cumulative P&L claim. Summed SEPARATELY; never folded into `buffer`. */
  accrualClaimedUnverified: number;
  /**
   * `margin / notional` as a percent — `null` when the attested notional is ZERO, which is
   * the arrival state of every mirror with no supply. A zero denominator is undefined, not
   * 46,054%.
   */
  ratio: number | null;
  /** Backing over obligation, percent. The solvency test - see `aggregateTotals`. */
  backingRatio: number | null;
  /** Protocol-wide mint-ceiling utilisation. `null` when unknown or the cap is zero. */
  capacityUsed: number | null;
  capacityCap: number | null;
  capacityUtilisationPct: number | null;
  /** True when any routed vault's cap is exactly zero: that vault refuses every mint. */
  anyCapacityHalted: boolean;
  /** The worst (largest) attestation age across routed vaults, not an average. */
  worstAgeSec: number;
  anyStale: boolean;
  anyPriceUnavailable: boolean;
}

/* -------------------------------------------------------- vault assembly */

/**
 * Vaults shown with no contracts behind them. Figures would be `null`, not `0`.
 *
 * EMPTY. uQQQ and uNVDA left it by being deployed; uSPX left it by being impossible — the
 * venue has no SPX perp, so the row was advertising a vault with nothing to hedge against
 * (file header). Nothing is rendered in its place: a placeholder row for an asset the
 * protocol cannot ship would carry the same promise under a vaguer name.
 *
 * `UnroutedVaultId` is `never`, so this array's element type has an unsatisfiable `id` and
 * the compiler will refuse any entry until that type is widened. Widen it deliberately.
 */
const UNROUTED: { id: UnroutedVaultId; name: string; full: string; img: string; status: VaultStatus }[] =
  [];

/** Every numeric field absent. The single most important object in this file. */
function emptyFigures(): Omit<
  Vault,
  "id" | "name" | "full" | "img" | "imgPlaceholder" | "status" | "marketIndexVerified"
> {
  return {
    price: null,
    // Not "unavailable": there is no oracle for this vault at all, which is a different
    // statement from "the oracle refused to answer". Callers key off `isRouted`.
    priceUnavailable: false,
    mintAllowed: false,
    change24h: null,
    change24hUnavailable: true,
    supply: null,
    buffer: null,
    deltaView: null,
    capacity: null,
    funding8h: null,
    funding8hUnavailable: true,
    backing: null,
    ageSec: null,
    attestationStale: false,
    basisKnown: false,
    basisBps: null,
    hotBuffer: null,
    bufferCapacity: null,
    solvency: [],
    funding: [],
    historyUnavailable: true,
  };
}

function unroutedVault(d: (typeof UNROUTED)[number]): Vault {
  return {
    id: d.id,
    name: d.name,
    full: d.full,
    img: d.img,
    imgPlaceholder: false,
    status: d.status,
    // No vault, so no venue market index to have verified or chosen.
    marketIndexVerified: null,
    ...emptyFigures(),
  };
}

/** A routed vault whose first read has not landed yet. Also carries no figures. */
function loadingVault(id: ChainVaultId): Vault {
  const meta = chainVaultMeta(id);
  return {
    id: meta.id,
    name: meta.name,
    full: meta.full,
    img: meta.img,
    imgPlaceholder: meta.imgPlaceholder,
    status: "LIVE",
    // Known from the address book before any read lands — unlike every figure below.
    marketIndexVerified: isMarketIndexVerified(id),
    ...emptyFigures(),
    loading: true,
  };
}

/* ---------------------------------------------------------------- context */

interface DashboardCtx {
  /* ---- chain -------------------------------------------------------- */
  /** 46630. The only chain this app talks to. */
  chainId: number;
  /** The connected wallet's chain, when connected. */
  walletChainId: number | undefined;
  /** True when a wallet is connected to something other than chain 46630. */
  wrongNetwork: boolean;
  switchToUseCert: () => void;
  isSwitchingChain: boolean;
  /** Why the wallet refused to switch to 46630, or null. Empty is not "it worked". */
  switchError: string | null;
  /** Real chain head. `0` until the first read lands — check `blockKnown` before showing it. */
  block: number;
  blockKnown: boolean;
  /** Wall clock, for age and countdown labels. */
  now: number;
  /** First multicall still in flight. */
  isLoading: boolean;
  isFetching: boolean;
  isError: boolean;
  error: Error | null;
  /** ms epoch of the last successful multicall, for an "as of" label. */
  dataUpdatedAt: number;
  refetch: () => void;

  /* ---- vaults ------------------------------------------------------- */
  /**
   * Every vault the dashboard shows, routed first. Greyed vaults carry no figures.
   * Length is `MIRRORS.length + UNROUTED.length` — read it, never hardcode a count from it.
   */
  vaults: Vault[];
  /** Only the routed ones, with the raw bigints for exact maths. */
  liveVaults: LiveVault[];
  liveVault: (id: VaultId) => LiveVault | undefined;
  /** `vault.cfg()` per routed vault: instant cap and fee bps. Read, never hardcoded. */
  configs: Partial<Record<ChainVaultId, VaultConfigView>>;
  /** `cfg()` for one vault, `undefined` for the three that have no contracts. */
  vaultConfig: (id: VaultId) => VaultConfigView | undefined;
  /** `null` until real data lands. */
  totals: Totals | null;
  /**
   * Documented `maxAttestationAgeSec`: past this the registry reports zero capacity.
   *
   * This is NOT "minting is off" any more. Under on-demand attestation a mint relays a
   * fresh signature inside its own transaction, so an aged registry is the idle state
   * rather than a fault. Read it together with `signer` before telling anyone that
   * minting has stopped.
   */
  maxAttestationAgeSec: number;
  /** Whether the attester is currently serving relayable signatures. See the hook. */
  signer: SignerFreshness;
  /**
   * Can a mint refresh THIS vault's attestation right now? `null` when not yet known.
   *
   * Every view that shows an attestation age needs this, and none of them should have to
   * know that the answer comes from an HTTP endpoint keyed by vault address. Per vault,
   * not protocol-wide: the signer serves a batch and a batch can be short one mirror.
   */
  attestationRefreshable: (id: VaultId) => boolean | null;
  /** The same question across every routed vault: true only when the batch covers them all. */
  allAttestationsRefreshable: boolean | null;

  /* ---- history (absent) --------------------------------------------- */
  agg: Record<Timeframe, SeriesPoint[]>;
  /** Always true: nothing on-chain returns a time series. Render an empty state. */
  historyUnavailable: boolean;

  /* ---- navigation --------------------------------------------------- */
  view: ViewId;
  setView: (v: ViewId) => void;
  selectedVault: VaultId;
  goVault: (id: VaultId) => void;
  mintPreset: MintPreset;
  goMint: (tab: "mint" | "redeem", asset: VaultId) => void;

  /* ---- wallet ------------------------------------------------------- */
  connected: boolean;
  isConnecting: boolean;
  address: `0x${string}` | undefined;
  walletModalOpen: boolean;
  setWalletModalOpen: (open: boolean) => void;
  disconnect: () => void;
  /** tUSDG balance, 6 dp. `null` when no wallet is connected. */
  usdc: number | null;
  /** The collateral actually transacted here. Not USDC. */
  collateralSymbol: string;
  /** Certificate balance per vault. `null` where unknown or not routed. */
  positions: Record<VaultId, number | null>;
  /** `TestFaucet` is the ONLY way a tester gets collateral. `null` until known. */
  faucet: { nextAvailableAt: number; balance: number; drip: number } | null;
  refetchBalances: () => void;

  /* ---- flows -------------------------------------------------------- */
  /* Deliberately absent. Flow history is not a contract read; call `useFlows()` from
   * `src/chain/useFlows.ts` directly. See the file header. */

  /* ---- toasts ------------------------------------------------------- */
  toasts: Toast[];
  pushToast: (toast: Omit<Toast, "id">) => number;
  settleToast: (id: number, title: string, desc?: string) => void;
  dismissToast: (id: number) => void;
  pauseToast: (id: number) => void;
  resumeToast: (id: number) => void;
}

const Ctx = createContext<DashboardCtx | null>(null);

export function useDashboard(): DashboardCtx {
  const ctx = useContext(Ctx);
  if (!ctx) throw new Error("useDashboard must be used within DashboardProvider");
  return ctx;
}

const EMPTY_AGG: Record<Timeframe, SeriesPoint[]> = { "1H": [], "24H": [], "7D": [], ALL: [] };

let idCounter = 5000;
const nextId = () => ++idCounter;

export function DashboardProvider({ children }: { children: ReactNode }) {
  /* ------------------------------------------------------------- chain */

  const connection = useConnection();
  const { mutate: disconnectWallet } = useDisconnect();
  const { mutate: switchChain, isPending: isSwitchingChain } = useSwitchChain();
  /** Why the last switch attempt failed, or null. Rendered beside the wrong-network banner. */
  const [switchError, setSwitchError] = useState<string | null>(null);

  const address = connection.address;
  const connected = connection.isConnected;

  const live = useLiveVaults();
  const { configs } = useVaultConfigs();
  const balances = useUserBalances(address);

  const { data: blockNumber } = useBlockNumber({
    chainId: CHAIN_ID,
    query: { refetchInterval: 12_000 },
  });

  const [now, setNow] = useState(() => Date.now());

  /* --------------------------------------------------------- navigation */

  const [view, setView] = useState<ViewId>("overview");
  const [selectedVault, setSelectedVault] = useState<VaultId>("utsla");
  const [mintPreset, setMintPreset] = useState<MintPreset>({ tab: "mint", asset: "utsla", nonce: 0 });
  const [walletModalOpen, setWalletModalOpen] = useState(false);

  const [toasts, setToasts] = useState<Toast[]>([]);
  const toastTimers = useRef(new Map<number, ReturnType<typeof setTimeout>>());

  /* ------------------------------------------------------------- toasts */

  const dismissToast = useCallback((id: number) => {
    const timer = toastTimers.current.get(id);
    if (timer) clearTimeout(timer);
    toastTimers.current.delete(id);
    setToasts((ts) => ts.filter((t) => t.id !== id));
  }, []);

  const scheduleDismiss = useCallback(
    (id: number, ms: number) => {
      const prev = toastTimers.current.get(id);
      if (prev) clearTimeout(prev);
      toastTimers.current.set(
        id,
        setTimeout(() => dismissToast(id), ms),
      );
    },
    [dismissToast],
  );

  const pauseToast = useCallback((id: number) => {
    const timer = toastTimers.current.get(id);
    if (timer) clearTimeout(timer);
    toastTimers.current.delete(id);
  }, []);

  const resumeToast = useCallback((id: number) => scheduleDismiss(id, 5000), [scheduleDismiss]);

  const pushToast = useCallback(
    (toast: Omit<Toast, "id">): number => {
      const id = nextId();
      setToasts((ts) => [...ts.slice(-2), { ...toast, id }]);
      if (toast.state === "success") scheduleDismiss(id, 5000);
      return id;
    },
    [scheduleDismiss],
  );

  /** Flip a pending toast to confirmed. Only ever called on a real receipt. */
  const settleToast = useCallback(
    (id: number, title: string, desc?: string) => {
      setToasts((ts) => ts.map((t) => (t.id === id ? { ...t, state: "success", title, desc } : t)));
      scheduleDismiss(id, 5000);
    },
    [scheduleDismiss],
  );

  /* -------------------------------------------------------------- clock */

  // One-second clock for age and countdown labels. The vault figures are NOT driven from
  // here any more — they come from wagmi's refetch of the multicall.
  useEffect(() => {
    const clock = window.setInterval(() => setNow(Date.now()), 1000);
    return () => window.clearInterval(clock);
  }, []);

  /* ------------------------------------------------------------- vaults */

  const vaults = useMemo<Vault[]>(() => {
    const byId = new Map<VaultId, Vault>();
    // A LiveVault IS a Vault (LiveVault extends Omit<Vault, "id" | "price">).
    for (const v of live.vaults) byId.set(v.id, v);
    const routed = CHAIN_VAULT_IDS.map((id) => byId.get(id) ?? loadingVault(id));
    return [...routed, ...UNROUTED.map(unroutedVault)];
  }, [live.vaults]);

  const liveVault = useCallback(
    (id: VaultId) => live.vaults.find((v) => v.id === id),
    [live.vaults],
  );

  const vaultConfig = useCallback(
    (id: VaultId) => (isChainVaultId(id) ? configs[id] : undefined),
    [configs],
  );

  const totals = useMemo<Totals | null>(
    () => (live.vaults.length > 0 ? aggregateTotals(live.vaults) : null),
    [live.vaults],
  );

  /* -------------------------------------------------------- user state */

  /**
   * Certificate balance per vault. Built from `CHAIN_VAULT_IDS` rather than written out, so
   * a new mirror's balance appears without an edit here and an id can never be silently
   * omitted (it would read as `undefined`, which no consumer expects). An id with no
   * certificate token would be `null` — the `Record<VaultId, …>` type is what forces one of
   * the two to be chosen for every id.
   */
  const positions = useMemo<Record<VaultId, number | null>>(() => {
    const out = {} as Record<VaultId, number | null>;
    for (const id of CHAIN_VAULT_IDS) {
      out[id] = connected ? balances.certificates[id] : null;
    }
    return out;
  }, [connected, balances.certificates]);

  const faucet = useMemo(
    () =>
      connected
        ? {
            nextAvailableAt: balances.faucetNextAvailableAt,
            balance: balances.faucetBalance,
            drip: balances.faucetDrip,
          }
        : null,
    [connected, balances.faucetNextAvailableAt, balances.faucetBalance, balances.faucetDrip],
  );

  /* --------------------------------------------------------- navigation */

  const goVault = useCallback((id: VaultId) => {
    setSelectedVault(id);
    setView("vaults");
  }, []);

  const goMint = useCallback((tab: "mint" | "redeem", asset: VaultId) => {
    setMintPreset((p) => ({ tab, asset, nonce: p.nonce + 1 }));
    setView("mint");
  }, []);

  /**
   * Switch the wallet to 46630, and SAY SO when it will not go.
   *
   * This was `switchChain({ chainId })` and nothing else - a fire-and-forget mutate with
   * no error handler. A wallet that refuses the chain (Phantom cannot be given one at all)
   * left the user pressing "Switch network" against a button that did nothing, with no
   * message, forever. A control that cannot report its own failure is worse than no
   * control: it reads as a broken app rather than an unsupported wallet.
   */
  const switchToUseCert = useCallback(() => {
    setSwitchError(null);
    switchChain(
      { chainId: CHAIN_ID },
      {
        onError: (err) => {
          const active = connection.connector
            ? { id: connection.connector.id, name: connection.connector.name }
            : null;
          // A user who pressed Cancel gets nothing: they know what they did, and an error
          // banner blaming their wallet would be a lie.
          const explained = explainChainFailure(err, active);
          if (explained) setSwitchError(explained);
          else if (!/user rejected|user denied/i.test(String(err?.message ?? ""))) {
            setSwitchError(err?.message ?? "The wallet would not switch network.");
          }
        },
      },
    );
  }, [switchChain, connection.connector]);

  const disconnect = useCallback(() => {
    setSwitchError(null);
    disconnectWallet();
  }, [disconnectWallet]);

  /* ---------------------------------------------------------------- flows */

  // Nothing here. Receipt ids are still not enumerable on-chain and there is still no
  // `receiptsOf(user)` — that half of the old caveat was always true — but the chain's
  // Blockscout instance indexes and decodes the events, so the list exists. It is fetched
  // by `useFlows()` in the views, not published from this provider, because it is a
  // third-party HTTP index and not a contract read. See the file header.

  /* -------------------------------------------------------------- signer */

  // Polled over HTTP, not read from chain: whether a mint can refresh the attestation
  // depends on the attester being up, and no contract knows that.
  const signer = useSignerFreshness();

  const attestationRefreshable = useCallback(
    (id: VaultId) => signerCovers(signer, liveVault(id)?.vaultAddress),
    [signer, liveVault],
  );

  // `every` over an EMPTY list is true, which would claim a refresh is available before any
  // vault has loaded. The length guard keeps that from becoming a green light.
  const allAttestationsRefreshable =
    signer.available === null
      ? null
      : !signer.available
        ? false
        : live.vaults.length === 0
          ? null
          : live.vaults.every((v) => signer.vaults.has(v.vaultAddress.toLowerCase()));

  /* --------------------------------------------------------------- value */

  const value: DashboardCtx = {
    chainId: CHAIN_ID,
    walletChainId: connection.chainId,
    wrongNetwork: connected && !isSupportedChain(connection.chainId),
    switchToUseCert,
    isSwitchingChain,
    switchError,
    block: blockNumber !== undefined ? Number(blockNumber) : 0,
    blockKnown: blockNumber !== undefined,
    now,
    isLoading: live.isLoading,
    isFetching: live.isFetching,
    isError: live.isError,
    error: live.error,
    dataUpdatedAt: live.dataUpdatedAt,
    refetch: live.refetch,

    vaults,
    liveVaults: live.vaults,
    liveVault,
    configs,
    vaultConfig,
    totals,
    maxAttestationAgeSec: MAX_ATTESTATION_AGE_SEC,
    signer,
    attestationRefreshable,
    allAttestationsRefreshable,

    agg: EMPTY_AGG,
    historyUnavailable: true,

    view,
    setView,
    selectedVault,
    goVault,
    mintPreset,
    goMint,

    connected,
    isConnecting: connection.isConnecting || connection.isReconnecting,
    address,
    walletModalOpen,
    setWalletModalOpen,
    disconnect,
    usdc: connected ? balances.collateral : null,
    collateralSymbol: "tUSDG",
    positions,
    faucet,
    refetchBalances: balances.refetch,

    toasts,
    pushToast,
    settleToast,
    dismissToast,
    pauseToast,
    resumeToast,
  };

  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}
