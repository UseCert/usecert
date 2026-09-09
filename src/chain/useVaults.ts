/**
 * Live vault reads for the UseCert deployment on Robinhood Chain testnet.
 *
 * Shapes its output to the interfaces the existing dashboard already consumes
 * (`src/pages/dashboard/store.tsx`: `Vault`, `SeriesPoint`, `FundingBar`) so that stage 2
 * can swap the mock provider for these hooks with minimal component change. `LiveVault`
 * is `Omit<Vault, "id">` plus the fields the chain forces us to be honest about, so the
 * compiler fails here — not in a component — if the store's shape drifts.
 *
 * Three things this file is deliberate about (INTEGRATION-NOTES.md §0):
 *
 *  1. `solvency()` returns EIGHT fields, and two of them are not the same kind of number.
 *     `buffer18` is the vault's own ERC-20 balance — ground truth. `accrual18` is an
 *     attester-relayed claim about funding and execution variance that nothing on-chain
 *     verifies. They used to be one field, published as "the buffer", and it was the
 *     ledger: measured drifting 100,000.01 published against 91,028.00 actually held.
 *     They are surfaced here as `bufferHeld` and `accrualClaimedUnverified` — two names
 *     that cannot be mistaken for each other — never summed into one figure.
 *
 *  2. `ageSec` is always present on the returned shape. There is no code path here that
 *     hands a consumer backing without also handing it the age of that backing.
 *
 *  3. `basisBpsChecked()` returns `(bool known, uint256 bps)` and the boolean is the
 *     point. `basisKnown === false` means there is NO independent basis to compute, which
 *     is categorically different from `basisBps === 0` ("two independent sources agree
 *     exactly"). `basisBps` is therefore `number | null`, not `0`.
 *
 * And two things it refuses to do:
 *
 *  *  `price` is `number | null` with a `priceUnavailable` flag, because `oracle.px()`
 *     REVERTS when the oracle is unhealthy. That is designed behaviour, not an error.
 *  *  History is not fabricated. `Vault.solvency` wants 60 points and `Vault.funding` 48
 *     bars; no view function on these contracts returns history. We return one real point
 *     and an empty bar array with `historyUnavailable: true`. Inventing a curve would make
 *     the dashboard lie.
 */
import { useMemo } from "react";
import { useReadContracts } from "wagmi";
import type { Abi, ContractFunctionName } from "viem";

import {
  CertOracleABI,
  CertVaultABI,
  CertificateABI,
  MIRRORS,
  SHARED,
  SolvencyRegistryABI,
  TestFaucetABI,
  TestUSDGABI,
  type Mirror,
} from "./contracts";
import {
  BPS_ONE,
  ONE_18,
  fromBps,
  fromCert,
  fromCollateral,
  fromPrice18,
} from "./units";
import type { FundingBar, SeriesPoint, Vault } from "@/pages/dashboard/store";

/* ────────────────────────────────────────────────────────────────────────── ids */

/**
 * The vaults that actually exist in this deployment.
 *
 * This is the subset of the store's `VaultId` that has contracts. The store's union now
 * reads `"utsla" | "uspy" | "unvda" | "uspx" | "uqqq"`: `uspy` was added because it is
 * deployed (market 26), and `unvda` / `uspx` / `uqqq` were kept because the UI still shows
 * them — greyed, non-interactive and carrying no figures, since there is no vault, no
 * certificate token and no oracle for them on chain 46630. Anything crossing from the UI
 * into this layer goes through `isChainVaultId` in the store.
 */
export type ChainVaultId = "utsla" | "uspy";

export const CHAIN_VAULT_IDS: readonly ChainVaultId[] = ["utsla", "uspy"];

/** Past this age the vault reports zero capacity and minting is off. */
export const MAX_ATTESTATION_AGE_SEC = 300;

export interface MirrorMeta {
  id: ChainVaultId;
  name: string;
  full: string;
  img: string;
  /**
   * True when `img` is a stand-in rather than this certificate's own plate. There is no
   * `cert-plate-uspy.jpg` in `public/`; pointing uSPY at `cert-plate-uspx.jpg` would put
   * a uSPX plate under a uSPY heading, so it gets the neutral logo instead. Asset work
   * belongs to the copy stage.
   */
  imgPlaceholder: boolean;
}

const MIRROR_META: Record<Mirror["symbol"], MirrorMeta> = {
  uTSLA: {
    id: "utsla",
    name: "uTSLA",
    full: "Tesla Certificate",
    img: "/cert-plate-utsla.jpg",
    imgPlaceholder: false,
  },
  uSPY: {
    id: "uspy",
    name: "uSPY",
    full: "S&P 500 Certificate",
    img: "/logo.png",
    imgPlaceholder: true,
  },
};

function mirrorFor(id: ChainVaultId): Mirror {
  const mirror = MIRRORS.find((m) => MIRROR_META[m.symbol].id === id);
  if (!mirror) throw new Error(`No deployed mirror for vault id "${id}"`);
  return mirror;
}

/**
 * Presentation metadata for a deployed mirror, by vault id.
 *
 * Exported so that a consumer rendering a routed vault BEFORE the first multicall
 * returns (a loading placeholder) does not invent its own name, title or plate for it.
 * This file stays the single source of truth for those, including `imgPlaceholder`:
 * there is no `cert-plate-uspy.jpg`, and uSPY must not borrow the uSPX plate.
 */
export function chainVaultMeta(id: ChainVaultId): MirrorMeta {
  return MIRROR_META[mirrorFor(id).symbol];
}

/* ─────────────────────────────────────────────────────────────── returned shapes */

/** The two solvency numbers that must never be conflated, kept apart by name. */
export interface BackingBreakdown {
  /**
   * `solvency.buffer18` — the vault's OWN ERC-20 collateral balance, 18 dp, SIGNED.
   * Ground truth: this is money the vault holds.
   */
  bufferHeld: number;
  /**
   * `solvency.accrual18` — attester-relayed cumulative P&L, 18 dp, SIGNED, genuinely
   * negative at times. This is NOT money and nothing on-chain verifies it. Render it
   * labelled as unverified, in a different visual register from `bufferHeld`, and never
   * add the two together into a single "buffer" figure.
   */
  accrualClaimedUnverified: number;
  /**
   * Always `false`. Present so that any component destructuring the accrual has the
   * verification status in hand and cannot render the number bare.
   */
  accrualIsVerified: false;
  /** `solvency.margin18` — margin at the venue, FROM THE ATTESTATION. 18 dp. */
  margin: number;
  /** `solvency.notional18` — perp position notional, FROM THE ATTESTATION. 18 dp. */
  notional: number;
  /** `solvency.provenAtBatch` — which venue batch all of the above rests on. */
  provenAtBatch: number;
}

export interface LiveVault extends Omit<Vault, "id" | "price"> {
  id: ChainVaultId;

  /* ---------------------------------------------------------------- addresses */
  vaultAddress: `0x${string}`;
  certificateAddress: `0x${string}`;
  oracleAddress: `0x${string}`;
  marketIndex: number;
  imgPlaceholder: boolean;

  /* ------------------------------------------------------------- non-null figures */
  /**
   * Every figure on the store's `Vault` is nullable, because three of the five ids in
   * `VaultId` have no contracts at all and must render nothing. A DEPLOYED mirror always
   * has these, so they are narrowed back to `number` here — `price` stays the one genuine
   * exception, because `oracle.px()` really does revert.
   */
  supply: number;
  buffer: number;
  bufferPct: number;
  /** `1 + deltaBps/10_000`. Render magnitude only — see `deltaBps`. */
  delta: number;
  change24h: number;
  funding8h: number;

  /* -------------------------------------------------------------------- price */
  /**
   * `oracle.px()`, 18 dp → display number. `null` when the call reverted, which happens
   * when the oracle is stale, deviant or fed badly. Check `priceUnavailable` and say
   * "minting paused" — do not render a crash or a zero.
   */
  price: number | null;
  /** True when `oracle.px()` reverted. A state, not an error. */
  priceUnavailable: boolean;
  /** `oracle.mintAllowed()`. False means new mints are refused; redemption still works. */
  mintAllowed: boolean;

  /* ---------------------------------------------------------- solvency, split */
  backing: BackingBreakdown;

  /* ---------------------------------------------------------------------- age */
  /**
   * Seconds since the attestation this solvency figure rests on. ALWAYS present — a
   * backing number with no age is the claim this project spent the most effort not
   * making. Sourced from `registry.ageSec(vault)`.
   */
  ageSec: number;
  /** `ageSec` from `vault.solvency()`, for cross-checking against the registry. */
  ageSecFromVault: number;
  /** True when `ageSec > MAX_ATTESTATION_AGE_SEC` (300 s): capacity is zero, minting off. */
  attestationStale: boolean;

  /* -------------------------------------------------------------------- basis */
  /**
   * `known` from `oracle.basisBpsChecked()`. False means there is no independent basis to
   * compute at all — the feed and the venue mark are declared the same source.
   */
  basisKnown: boolean;
  /**
   * `bps` from `oracle.basisBpsChecked()`, in percent, or `null` when `basisKnown` is
   * false. Deliberately nullable: collapsing "unverifiable" to `0` silently turns it into
   * "perfect".
   */
  basisBps: number | null;

  /* ------------------------------------------------------------------ capacity */
  /** `vault.hotBuffer()`, 6 dp → display number. The instant-redeem float. */
  hotBuffer: number;
  /** `vault.bufferCapacity18()`, 18 dp → display number. Headroom for new mints. */
  bufferCapacity: number;
  /** `solvency.deltaBps` in percent. Unsigned: the DIRECTION of the drift is not published. */
  deltaBps: number;

  /* ------------------------------------------------------------------ honesty */
  /**
   * Always `true`. No view function on these contracts returns a time series, so
   * `solvency` holds a single real point and `funding` is empty. Stage 2 should render an
   * honest empty state off this flag rather than a chart with one dot.
   */
  historyUnavailable: true;
  /** Always `true`. There is no on-chain source for a 24h price change. `change24h` is 0. */
  change24hUnavailable: true;
  /**
   * Always `true`. `accrual18` is a cumulative claim, not a rate; nothing on-chain gives
   * an 8-hour funding rate. `funding8h` is 0.
   */
  funding8hUnavailable: true;

  /** Unconverted values, for maths that must stay exact (cap comparisons, quotes). */
  raw: {
    supply18: bigint;
    notional18: bigint;
    margin18: bigint;
    buffer18: bigint;
    accrual18: bigint;
    deltaBps: bigint;
    ageSec: bigint;
    provenAtBatch: bigint;
    px18: bigint | null;
    hotBuffer6: bigint;
    bufferCapacity18: bigint;
    basisBps: bigint | null;
  };
}

/** `vault.cfg()`, decoded. Read it — do not hardcode these. */
export interface VaultConfigView {
  id: ChainVaultId;
  collateral: `0x${string}`;
  collateralAssetIndex: number;
  routeType: number;
  marketIndex: number;
  sizeDecimals: number;
  mintFeeBps: bigint;
  redeemFeeBps: bigint;
  /** The mint/redeem size fork, 18 dp. Compare against a SCALED collateral amount. */
  instantCap18: bigint;
  settleBandBps: bigint;
  targetMarginBps: bigint;
}

/* ─────────────────────────────────────────────── multicall plumbing (type-safe edges) */

interface ContractCall {
  address: `0x${string}`;
  abi: Abi;
  functionName: string;
  args?: readonly unknown[];
}

/**
 * Build one multicall entry with the function name checked against its ABI.
 *
 * `useReadContracts` can only infer per-index result types for a literal tuple of calls.
 * We build the array dynamically from `MIRRORS`, so results are decoded by index through
 * the narrow helpers below instead. This helper keeps the half that inference would
 * otherwise silently drop: a typo in `functionName`, or a name that is not a view
 * function on that ABI, is a compile error.
 */
function call<const abi extends Abi | readonly unknown[]>(
  address: `0x${string}`,
  abi: abi,
  functionName: ContractFunctionName<abi, "view" | "pure">,
  args?: readonly unknown[],
): ContractCall {
  return { address, abi: abi as unknown as Abi, functionName: functionName as string, args };
}

type ReadResult =
  | { status: "success"; result: unknown; error?: undefined }
  | { status: "failure"; result?: undefined; error?: unknown };

/** Number of calls issued per mirror, in the order built by `vaultCalls`. */
const CALLS_PER_MIRROR = 8;

function vaultCalls(mirror: Mirror): ContractCall[] {
  // Order matters: `useLiveVaults` decodes by index against CALLS_PER_MIRROR.
  return [
    call(mirror.vault, CertVaultABI, "solvency"),
    call(mirror.vault, CertVaultABI, "hotBuffer"),
    call(mirror.vault, CertVaultABI, "bufferCapacity18"),
    // px() REVERTS when the oracle is unhealthy. allowFailure keeps the batch alive and
    // this entry becomes status: "failure" — that is how `priceUnavailable` is detected.
    call(mirror.certOracle, CertOracleABI, "px"),
    call(mirror.certOracle, CertOracleABI, "mintAllowed"),
    call(mirror.certOracle, CertOracleABI, "basisBpsChecked"),
    call(mirror.certificate, CertificateABI, "totalSupply"),
    call(SHARED.solvencyRegistry, SolvencyRegistryABI, "ageSec", [mirror.vault]),
  ];
}

function asBigint(entry: ReadResult | undefined): bigint | null {
  if (!entry || entry.status !== "success") return null;
  return typeof entry.result === "bigint" ? entry.result : null;
}

function asBool(entry: ReadResult | undefined): boolean | null {
  if (!entry || entry.status !== "success") return null;
  return typeof entry.result === "boolean" ? entry.result : null;
}

/** The eight-field `solvency()` struct, as viem decodes it. */
interface SolvencyStruct {
  supply: bigint;
  notional18: bigint;
  margin18: bigint;
  buffer18: bigint;
  deltaBps: bigint;
  provenAtBatch: bigint;
  ageSec: bigint;
  accrual18: bigint;
}

const ZERO_SOLVENCY: SolvencyStruct = {
  supply: 0n,
  notional18: 0n,
  margin18: 0n,
  buffer18: 0n,
  deltaBps: 0n,
  provenAtBatch: 0n,
  ageSec: 0n,
  accrual18: 0n,
};

/** Field order of the `Solvency` struct, for the positional fallback below. */
const SOLVENCY_FIELDS: readonly (keyof SolvencyStruct)[] = [
  "supply",
  "notional18",
  "margin18",
  "buffer18",
  "deltaBps",
  "provenAtBatch",
  "ageSec",
  "accrual18",
];

/**
 * Decode the eight-field `solvency()` struct.
 *
 * viem returns a single named-tuple output as an object, which is the path taken here.
 * The positional fallback exists because the alternative failure mode — quietly reporting
 * a solvency of all zeros — is far worse on this particular screen than showing nothing.
 * Returning `null` lets the caller keep the "no data yet" state instead.
 */
function asSolvency(entry: ReadResult | undefined): SolvencyStruct | null {
  if (!entry || entry.status !== "success") return null;
  const raw = entry.result;
  if (!raw || typeof raw !== "object") return null;

  const source = Array.isArray(raw)
    ? Object.fromEntries(SOLVENCY_FIELDS.map((k, i) => [k, (raw as unknown[])[i]]))
    : (raw as Record<string, unknown>);

  const out = {} as SolvencyStruct;
  for (const field of SOLVENCY_FIELDS) {
    const value = source[field];
    if (typeof value !== "bigint") return null;
    out[field] = value;
  }
  return out;
}

/** `basisBpsChecked()` → `[known, bps]`. Both halves are returned; neither is dropped. */
function asBasis(entry: ReadResult | undefined): { known: boolean; bps: bigint | null } {
  if (!entry || entry.status !== "success") return { known: false, bps: null };
  const tuple = entry.result as readonly unknown[] | undefined;
  if (!Array.isArray(tuple) || typeof tuple[0] !== "boolean") return { known: false, bps: null };
  const known = tuple[0];
  const bps = typeof tuple[1] === "bigint" ? tuple[1] : null;
  return { known, bps: known ? bps : null };
}

/* ──────────────────────────────────────────────────────────────────────── hooks */

export interface UseLiveVaultsResult {
  vaults: LiveVault[];
  isLoading: boolean;
  isFetching: boolean;
  isError: boolean;
  error: Error | null;
  /** ms epoch of the last successful multicall, for a "as of" label. */
  dataUpdatedAt: number;
  refetch: () => void;
}

/**
 * One batched `useReadContracts` covering every deployed mirror:
 * `solvency()`, `hotBuffer()`, `bufferCapacity18()`, `px()`, `mintAllowed()`,
 * `basisBpsChecked()`, `certificate.totalSupply()` and `registry.ageSec(vault)`.
 *
 * `allowFailure` stays on (wagmi's default) on purpose: `px()` reverting is a state we
 * need to read, not a batch failure.
 */
export function useLiveVaults(options?: { refetchIntervalMs?: number }): UseLiveVaultsResult {
  const contracts = useMemo(() => MIRRORS.flatMap((m) => vaultCalls(m)), []);

  const query = useReadContracts({
    contracts,
    query: {
      refetchInterval: options?.refetchIntervalMs ?? 15_000,
      // A revert on px() is information; keep the rest of the batch.
      retry: 1,
    },
  });

  const results = (query.data ?? []) as ReadResult[];

  const vaults = useMemo<LiveVault[]>(() => {
    if (results.length === 0) return [];
    return MIRRORS.map((mirror, i) => {
      const base = i * CALLS_PER_MIRROR;
      const meta = MIRROR_META[mirror.symbol];

      const solvency = asSolvency(results[base]) ?? ZERO_SOLVENCY;
      const hotBuffer6 = asBigint(results[base + 1]) ?? 0n;
      const bufferCapacity18 = asBigint(results[base + 2]) ?? 0n;
      const px18 = asBigint(results[base + 3]); // null ⇒ px() reverted
      const mintAllowed = asBool(results[base + 4]) ?? false;
      const basis = asBasis(results[base + 5]);
      const supply18 = asBigint(results[base + 6]) ?? solvency.supply;
      const registryAgeSec = asBigint(results[base + 7]);

      // ageSec is never optional. Prefer the registry's answer; fall back to the vault's
      // own, which the struct always carries alongside the backing.
      const ageSecRaw = registryAgeSec ?? solvency.ageSec;
      const ageSec = Number(ageSecRaw);

      // The one real solvency point we can prove right now.
      //   obligation — what holders are owed: supply × oracle price. If px() reverted we
      //                fall back to the attested notional18, which has different
      //                provenance (attester-relayed, not a live guarded read).
      //   backing    — margin at the venue plus collateral the vault actually holds.
      //                accrual18 is NOT included: it is an unverified claim.
      const obligation18 = px18 !== null ? (supply18 * px18) / ONE_18 : solvency.notional18;
      const backing18 = solvency.margin18 + solvency.buffer18;
      const nowPoint: SeriesPoint = {
        obligation: fromPrice18(obligation18),
        backing: fromPrice18(backing18),
      };

      const bufferHeld = fromPrice18(solvency.buffer18);
      const capacity = fromPrice18(bufferCapacity18);

      const vault: LiveVault = {
        id: meta.id,
        name: meta.name,
        full: meta.full,
        img: meta.img,
        imgPlaceholder: meta.imgPlaceholder,
        status: "LIVE",

        vaultAddress: mirror.vault,
        certificateAddress: mirror.certificate,
        oracleAddress: mirror.certOracle,
        marketIndex: mirror.marketIndex,

        price: px18 !== null ? fromPrice18(px18) : null,
        priceUnavailable: px18 === null,
        mintAllowed,

        // No on-chain source. Zeroed, and flagged so nobody reads the zero as a fact.
        change24h: 0,
        change24hUnavailable: true,
        funding8h: 0,
        funding8hUnavailable: true,

        supply: fromCert(supply18),

        // `Vault.buffer` in the store means "USD in the buffer". That is buffer18 — the
        // ERC-20 balance the vault holds — and nothing else.
        buffer: bufferHeld,
        // Percent of capacity, which is the closest on-chain analogue of the store's
        // "percent of target". Stage 2 should confirm the label matches this meaning.
        bufferPct: capacity > 0 ? clampPct((bufferHeld / capacity) * 100) : 0,

        // deltaBps is unsigned, so this reports the MAGNITUDE of the drift from delta 1.0
        // and not its direction. `deltaBps` is exposed raw so stage 2 can say so.
        delta: 1 + Number(solvency.deltaBps) / Number(BPS_ONE),
        deltaBps: fromBps(solvency.deltaBps),

        backing: {
          bufferHeld,
          accrualClaimedUnverified: fromPrice18(solvency.accrual18),
          accrualIsVerified: false,
          margin: fromPrice18(solvency.margin18),
          notional: fromPrice18(solvency.notional18),
          provenAtBatch: Number(solvency.provenAtBatch),
        },

        ageSec,
        ageSecFromVault: Number(solvency.ageSec),
        attestationStale: ageSec > MAX_ATTESTATION_AGE_SEC,

        basisKnown: basis.known,
        basisBps: basis.bps !== null ? fromBps(basis.bps) : null,

        hotBuffer: fromCollateral(hotBuffer6),
        bufferCapacity: capacity,

        // One real point, no invented curve. Empty bars.
        solvency: [nowPoint],
        funding: [] as FundingBar[],
        historyUnavailable: true,

        raw: {
          supply18,
          notional18: solvency.notional18,
          margin18: solvency.margin18,
          buffer18: solvency.buffer18,
          accrual18: solvency.accrual18,
          deltaBps: solvency.deltaBps,
          ageSec: ageSecRaw,
          provenAtBatch: solvency.provenAtBatch,
          px18,
          hotBuffer6,
          bufferCapacity18,
          basisBps: basis.bps,
        },
      };
      return vault;
    });
  }, [results]);

  return {
    vaults,
    isLoading: query.isLoading,
    isFetching: query.isFetching,
    isError: query.isError,
    error: (query.error as Error | null) ?? null,
    dataUpdatedAt: query.dataUpdatedAt,
    refetch: () => void query.refetch(),
  };
}

/** A single mirror, by id. Same batch underneath. */
export function useLiveVault(id: ChainVaultId): UseLiveVaultsResult & { vault: LiveVault | null } {
  const all = useLiveVaults();
  const vault = useMemo(() => all.vaults.find((v) => v.id === id) ?? null, [all.vaults, id]);
  return { ...all, vault };
}

/**
 * `vault.cfg()` for every mirror. Separate from the dashboard batch because the write
 * path needs `instantCap18` and the fee bps whether or not a dashboard is mounted, and
 * these values change rarely.
 */
export function useVaultConfigs(): {
  configs: Partial<Record<ChainVaultId, VaultConfigView>>;
  isLoading: boolean;
  isError: boolean;
} {
  const contracts = useMemo<ContractCall[]>(
    () => MIRRORS.map((m) => call(m.vault, CertVaultABI, "cfg")),
    [],
  );

  const query = useReadContracts({
    contracts,
    query: { staleTime: 5 * 60_000 },
  });

  const results = (query.data ?? []) as ReadResult[];

  const configs = useMemo<Partial<Record<ChainVaultId, VaultConfigView>>>(() => {
    const out: Partial<Record<ChainVaultId, VaultConfigView>> = {};
    MIRRORS.forEach((mirror, i) => {
      const entry = results[i];
      if (!entry || entry.status !== "success") return;
      const t = entry.result as readonly unknown[] | undefined;
      if (!Array.isArray(t) || t.length < 10) return;
      out[MIRROR_META[mirror.symbol].id] = {
        id: MIRROR_META[mirror.symbol].id,
        collateral: t[0] as `0x${string}`,
        collateralAssetIndex: Number(t[1]),
        routeType: Number(t[2]),
        marketIndex: Number(t[3]),
        sizeDecimals: Number(t[4]),
        mintFeeBps: t[5] as bigint,
        redeemFeeBps: t[6] as bigint,
        instantCap18: t[7] as bigint,
        settleBandBps: t[8] as bigint,
        targetMarginBps: t[9] as bigint,
      };
    });
    return out;
  }, [results]);

  return { configs, isLoading: query.isLoading, isError: query.isError };
}

/** One mirror's `cfg()`. */
export function useVaultConfig(id: ChainVaultId): VaultConfigView | undefined {
  return useVaultConfigs().configs[id];
}

export interface UserBalances {
  /** tUSDG, 6 dp → display number. */
  collateral: number;
  /** Certificate balance per deployed mirror, 18 dp → display number. */
  certificates: Record<ChainVaultId, number>;
  /** Unix seconds at which this address may claim from the faucet again. */
  faucetNextAvailableAt: number;
  /** The faucet's own tUSDG balance. An empty faucet must not present as "minting broken". */
  faucetBalance: number;
  /** The faucet drip, 6 dp → display number. 10 000 tUSDG here. */
  faucetDrip: number;
  raw: {
    collateral6: bigint;
    certificates18: Record<ChainVaultId, bigint>;
  };
  isLoading: boolean;
  refetch: () => void;
}

/**
 * Wallet-scoped reads: collateral balance, certificate balances, and the faucet state
 * (§3.5 — `TestFaucet.claim()` is the only way a tester obtains collateral).
 */
export function useUserBalances(address: `0x${string}` | undefined): UserBalances {
  const contracts = useMemo<ContractCall[]>(() => {
    if (!address) return [];
    return [
      call(SHARED.collateral, TestUSDGABI, "balanceOf", [address]),
      ...MIRRORS.map((m) => call(m.certificate, CertificateABI, "balanceOf", [address])),
      call(SHARED.testFaucet, TestFaucetABI, "nextAvailableAt", [address]),
      call(SHARED.collateral, TestUSDGABI, "balanceOf", [SHARED.testFaucet]),
      call(SHARED.testFaucet, TestFaucetABI, "dripAmount"),
    ];
  }, [address]);

  const query = useReadContracts({
    contracts,
    query: { enabled: Boolean(address), refetchInterval: 20_000 },
  });

  const results = (query.data ?? []) as ReadResult[];

  return useMemo<UserBalances>(() => {
    const collateral6 = asBigint(results[0]) ?? 0n;
    const certificates18 = {} as Record<ChainVaultId, bigint>;
    const certificates = {} as Record<ChainVaultId, number>;
    MIRRORS.forEach((mirror, i) => {
      const id = MIRROR_META[mirror.symbol].id;
      const raw = asBigint(results[1 + i]) ?? 0n;
      certificates18[id] = raw;
      certificates[id] = fromCert(raw);
    });
    const tail = 1 + MIRRORS.length;
    return {
      collateral: fromCollateral(collateral6),
      certificates,
      faucetNextAvailableAt: Number(asBigint(results[tail]) ?? 0n),
      faucetBalance: fromCollateral(asBigint(results[tail + 1]) ?? 0n),
      faucetDrip: fromCollateral(asBigint(results[tail + 2]) ?? 0n),
      raw: { collateral6, certificates18 },
      isLoading: query.isLoading,
      refetch: () => void query.refetch(),
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [results, query.isLoading]);
}

/* ────────────────────────────────────────────────────────────────────── helpers */

/**
 * The `totals` shape the dashboard store exposes, derived from live vaults.
 *
 * `buffer` is the sum of `bufferHeld` only — the collateral actually held. Unverified
 * accrual is summed separately as `accrualClaimedUnverified` so a total can never quietly
 * absorb it.
 */
export function aggregateTotals(vaults: LiveVault[]): {
  notional: number;
  margin: number;
  buffer: number;
  accrualClaimedUnverified: number;
  ratio: number;
  delta: number;
  /** The worst (largest) attestation age across mirrors. Publish this, not an average. */
  worstAgeSec: number;
  anyStale: boolean;
  anyPriceUnavailable: boolean;
} {
  const live = vaults.filter((v) => v.status === "LIVE");
  const notional = live.reduce((s, v) => s + v.backing.notional, 0);
  const margin = live.reduce((s, v) => s + v.backing.margin, 0);
  const buffer = live.reduce((s, v) => s + v.backing.bufferHeld, 0);
  const accrualClaimedUnverified = live.reduce(
    (s, v) => s + v.backing.accrualClaimedUnverified,
    0,
  );
  const delta = live.length ? live.reduce((s, v) => s + v.delta, 0) / live.length : 1;
  return {
    notional,
    margin,
    buffer,
    accrualClaimedUnverified,
    ratio: (margin / Math.max(1, notional)) * 100,
    delta,
    worstAgeSec: live.reduce((s, v) => Math.max(s, v.ageSec), 0),
    anyStale: live.some((v) => v.attestationStale),
    anyPriceUnavailable: live.some((v) => v.priceUnavailable),
  };
}

/** Addresses for a mirror, for the write hooks and for explorer links. */
export function vaultAddresses(id: ChainVaultId): Mirror {
  return mirrorFor(id);
}

function clampPct(n: number): number {
  if (!Number.isFinite(n)) return 0;
  return Math.min(100, Math.max(0, n));
}
