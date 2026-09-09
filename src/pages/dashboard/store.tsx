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
 * it is type-enforced: `price`, `supply`, `buffer`, `bufferPct`, `delta`, `deltaBps`,
 * `change24h`, `funding8h`, `ageSec`, `hotBuffer`, `bufferCapacity` and `backing` are all
 * nullable, so a component cannot render one without deciding what to show when it is
 * absent. Use `fmtOrDash` from `./format` — a greyed card with invented figures is worse
 * than the mock was, because it looks authoritative.
 *
 * THE FIVE VAULTS. Only uTSLA (market 16) and uSPY (market 26) are deployed on chain
 * 46630. uNVDA, uSPX and uQQQ have no vault, no certificate token and no oracle. They are
 * kept in the UI, greyed, non-interactive, and carrying no numbers at all:
 *
 *   utsla  LIVE       routed, real chain data
 *   uspy   LIVE       routed, real chain data (added to `VaultId` in this stage)
 *   uspx   SOON       on the roadmap for a later phase
 *   uqqq   SOON       on the roadmap for a later phase
 *   unvda  UNPLANNED  not deployed and not currently planned — do not imply otherwise
 *
 * `status: "SOON"` is reused for uSPX/uQQQ because the roadmap does list them. uNVDA gets
 * `"UNPLANNED"` ("NOT PLANNED") because promising it would be a commitment the project has
 * not made.
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
 * bars, and none for a 24h change, an 8h funding rate, or the flow list. `historyUnavailable`
 * / `change24hUnavailable` / `funding8hUnavailable` / `flowsUnavailable` are on, the arrays
 * are empty, and the views render an honest empty state. Nothing is interpolated.
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
  useLiveVaults,
  useUserBalances,
  useVaultConfigs,
  type ChainVaultId,
  type LiveVault,
  type VaultConfigView,
} from "@/chain/useVaults";

/* ------------------------------------------------------------------ types */

/**
 * `uspy` is deployed (market 26) and was missing from this union; the other three are in
 * the union and are NOT deployed. Both halves of that mismatch are represented here on
 * purpose — see the file header.
 */
export type VaultId = "utsla" | "uspy" | "unvda" | "uspx" | "uqqq";
/**
 * `staking` and `keepers` are deliberately absent: neither an insurance-staking contract
 * nor a keeper-rewards mechanism is deployed on chain 46630, and the views that used to
 * render them ran entirely on invented figures.
 */
export type ViewId = "overview" | "vaults" | "mint" | "activity" | "risk";
export type FlowType = "MINT" | "REDEEM" | "CLAIM";
export type Timeframe = "1H" | "24H" | "7D" | "ALL";

/**
 * `LIVE` — a vault, certificate and oracle exist on chain 46630 and the figures are read
 * from them. `SOON` — on the published roadmap for a later phase. `UNPLANNED` — no
 * contracts and no announced plan.
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
  /** `bufferHeld / bufferCapacity18`, as a percent. See the mapping note in the report. */
  bufferPct: number | null;
  /** `1 + deltaBps/10_000`. Do NOT render this as a signed drift — see `deltaBps`. */
  delta: number | null;
  /** `solvency.deltaBps` in percent. UNSIGNED on-chain: magnitude only, no direction. */
  deltaBps: number | null;

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
 * `VaultId` has five members and only two of them exist on chain 46630, so anything
 * heading for `useCertActions`, `useVaultConfig` or an address lookup has to pass through
 * here first. That is the point: the write path cannot be handed `uqqq` by accident.
 */
export function isChainVaultId(id: VaultId): id is ChainVaultId {
  return id === "utsla" || id === "uspy";
}

export interface Flow {
  id: number;
  type: FlowType;
  vault: VaultId | "token";
  amount: number;
  usdc: number;
  price: number;
  feeBps: number;
  time: number;
  tx: string;
}

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
  ratio: number;
  delta: number;
  /** The worst (largest) attestation age across routed vaults, not an average. */
  worstAgeSec: number;
  anyStale: boolean;
  anyPriceUnavailable: boolean;
}

/* -------------------------------------------------------- vault assembly */

/** The three vaults with no contracts. Figures are `null`, not `0`. */
const UNROUTED: { id: VaultId; name: string; full: string; img: string; status: VaultStatus }[] = [
  {
    id: "uspx",
    name: "uSPX",
    full: "S&P 500 Index Certificate",
    img: "/cert-plate-uspx.jpg",
    status: "SOON",
  },
  {
    id: "uqqq",
    name: "uQQQ",
    full: "Nasdaq 100 Certificate",
    img: "/cert-plate-uqqq.jpg",
    status: "SOON",
  },
  {
    id: "unvda",
    name: "uNVDA",
    full: "Nvidia Certificate",
    img: "/cert-plate-unvda.jpg",
    status: "UNPLANNED",
  },
];

/** Every numeric field absent. The single most important object in this file. */
function emptyFigures(): Omit<Vault, "id" | "name" | "full" | "img" | "imgPlaceholder" | "status"> {
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
    bufferPct: null,
    delta: null,
    deltaBps: null,
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
  /** All five, routed first. Greyed vaults carry no figures. */
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
  /** Documented `maxAttestationAgeSec`: past this, capacity is 0 and minting is off. */
  maxAttestationAgeSec: number;

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

  /* ---- flows (absent) ----------------------------------------------- */
  flows: Flow[];
  /** Always true: receipt ids are not enumerable on-chain and there is no indexer. */
  flowsUnavailable: boolean;
  loadMoreFlows: () => void;

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

  const positions = useMemo<Record<VaultId, number | null>>(
    () => ({
      utsla: connected ? balances.certificates.utsla : null,
      uspy: connected ? balances.certificates.uspy : null,
      // No certificate token exists for these three, so there is nothing to hold.
      unvda: null,
      uspx: null,
      uqqq: null,
    }),
    [connected, balances.certificates],
  );

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

  const switchToUseCert = useCallback(
    () => switchChain({ chainId: CHAIN_ID }),
    [switchChain],
  );

  const disconnect = useCallback(() => disconnectWallet(), [disconnectWallet]);

  /* ---------------------------------------------------------------- flows */

  // Receipt ids are not enumerable on-chain and there is no `receiptsOf(user)`; a flow
  // list can only come from indexed events. None are indexed yet, so this is empty rather
  // than invented, and `flowsUnavailable` tells the views to say why.
  const flows = useMemo<Flow[]>(() => [], []);
  const loadMoreFlows = useCallback(() => {}, []);

  /* --------------------------------------------------------------- value */

  const value: DashboardCtx = {
    chainId: CHAIN_ID,
    walletChainId: connection.chainId,
    wrongNetwork: connected && !isSupportedChain(connection.chainId),
    switchToUseCert,
    isSwitchingChain,
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

    flows,
    flowsUnavailable: true,
    loadMoreFlows,

    toasts,
    pushToast,
    settleToast,
    dismissToast,
    pauseToast,
    resumeToast,
  };

  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}
