/**
 * Live vault reads for the UseCert deployment on Robinhood Chain testnet.
 *
 * Shapes its output to the interfaces the existing dashboard already consumes
 * (`src/pages/dashboard/store.tsx`: `Vault`, `SeriesPoint`, `FundingBar`) so that stage 2
 * can swap the mock provider for these hooks with minimal component change. `LiveVault`
 * is `Omit<Vault, "id">` plus the fields the chain forces us to be honest about, so the
 * compiler fails here — not in a component — if the store's shape drifts.
 *
 * Four things this file is deliberate about (INTEGRATION-NOTES.md §0):
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
 *     ON THIS DEPLOYMENT `known` is `true` and `bps` is `0` on every mirror, and neither
 *     half is a measurement: see `BASIS_ON_THIS_DEPLOYMENT`, which is the sentence the UI
 *     must render next to the number.
 *
 *  4. `marketIndex` is not equally trustworthy across mirrors. `MARKET_INDEX_VERIFIED`
 *     records which indices were read back from the venue (TSLA 16, NVDA 15) and which were
 *     chosen (uSPY 26, uQQQ 27). It is hand-maintained because the generator drops the
 *     field; it is published because on a real venue a wrong index hedges a wrong market.
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
  BufferBookABI,
  CapacityOracleABI,
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
import { FAUCET_ADDRESS, HAS_FAUCET } from "./deployment";
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
 * The vaults that actually exist in this deployment — DERIVED FROM THE ADDRESS BOOK.
 *
 * Not a hand-written union any more. `MIRRORS` is generated from the deployment, so
 * `Lowercase<Mirror["symbol"]>` is the set of ids that provably have a vault, a certificate
 * token and an oracle on chain 46630, and it cannot fall behind the address book. Adding a
 * mirror to `contracts.ts` therefore widens this type immediately, which is what makes the
 * compiler — rather than a reader — find every site that has to learn about it:
 * `MIRROR_META` and `MARKET_INDEX_VERIFIED` are `Record<Mirror["symbol"], …>` and stop
 * compiling until the new mirror has an entry in each.
 *
 * The store's `VaultId` is this type plus whatever ids the UI shows WITHOUT contracts.
 * That second set is currently empty (see `store.tsx`), so anything crossing from the UI
 * into this layer still goes through `isChainVaultId` — the door stays, and re-arms the
 * moment an unrouted id is added back.
 */
export type ChainVaultId = Lowercase<Mirror["symbol"]>;

/**
 * Every deployed mirror's id, IN `MIRRORS` ORDER.
 *
 * The order matters beyond presentation: `useLiveVaults` decodes its multicall by index
 * against `MIRRORS`, so a separately maintained literal list could put a routed vault's
 * figures under another vault's name. Derived, so it cannot.
 */
export const CHAIN_VAULT_IDS: readonly ChainVaultId[] = MIRRORS.map(
  (m) => m.symbol.toLowerCase() as ChainVaultId,
);

/** Past this age the vault reports zero capacity and minting is off. */
export const MAX_ATTESTATION_AGE_SEC = 300;

/**
 * What a basis reading MEANS on chain 46630. One sentence, rendered wherever basis is.
 *
 * `basisBpsChecked()` compares the `CertOracle`'s feed against the venue's mark, and
 * `singleSource: false` on every mirror here declares those two independent. On this
 * deployment they are not economically independent: there is no Chainlink on chain 46630,
 * so every `CertOracle.feed` is a `ReplayAggregator` this project writes, and the keeper
 * that writes it sets the simulator's mark in the SAME TRANSACTION. The two numbers are
 * therefore equal by construction and the basis is 0 bps on every mirror at all times.
 *
 * That makes a green basis here a plumbing check — the guard is wired and reading — and not
 * a second source confirming the price. It is the exact failure the deployment checklist
 * warns about (`singleSource: false` against a feed that is not independent yields
 * `known = true, bps = 0`: a healthy basis asserted, never computed), and the UI must not
 * let a reader take it for the other thing. Zero here is also weaker than zero on a real
 * feed pair in a second way: how much of a genuine reference price sits behind the replayed
 * value differs per market, and this deployment publishes nothing about that either.
 */
export const BASIS_ON_THIS_DEPLOYMENT =
  "Basis reads 0 bps on every mirror by construction, not by agreement: chain 46630 has no " +
  "Chainlink, so each CertOracle reads a ReplayAggregator this project writes, and the same " +
  "keeper sets the simulator's mark in the same transaction. Treat it as proof the guard is " +
  "wired, never as an independent source confirming the price.";

/**
 * `deltaBps === 10_000` means the hedge-to-obligation ratio is EXACTLY 1.0 — at target.
 *
 * This is the single easiest number on these contracts to render backwards, and stage 3 did:
 * `deltaBps` is a RATIO in basis points (`a.notional18 * 10_000 / required`,
 * `CertVault.sol:1600`), not a drift. 10_000 is dead centre; 0 means the obligation is
 * completely UNHEDGED. Printing the raw bps as "% from target" turns the healthiest reading
 * into "100% off" and the worst reading into a reassuring "0.00%".
 */
export const DELTA_TARGET_BPS = 10_000n;

/**
 * `CertVault.DELTA_UNBOUNDED_BPS` — `type(uint256).max` (`CertVault.sol:1508`).
 *
 * Published when `required == 0` (no supply, or px 0) while the attested notional is NOT zero:
 * a live directional position against a zero obligation. It is a SENTINEL for "this ratio's
 * denominator is zero", chosen precisely so a reader can tell it from a measurement
 * (`CertVault.sol:1494-1508`). It must never reach a `toFixed()`.
 */
export const DELTA_UNBOUNDED_BPS = (1n << 256n) - 1n;

export interface MirrorMeta {
  id: ChainVaultId;
  name: string;
  full: string;
  img: string;
  /**
   * True when `img` is a stand-in rather than this certificate's own plate. There is no
   * `cert-plate-uspy.jpg` in `public/`, and uSPY must not borrow another certificate's
   * plate, so it gets the neutral logo instead. Asset work belongs to the copy stage.
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
  uQQQ: {
    id: "uqqq",
    name: "uQQQ",
    full: "Nasdaq 100 Certificate",
    img: "/cert-plate-uqqq.jpg",
    imgPlaceholder: false,
  },
  uNVDA: {
    id: "unvda",
    name: "uNVDA",
    full: "Nvidia Certificate",
    img: "/cert-plate-unvda.jpg",
    imgPlaceholder: false,
  },
};

/**
 * Was this mirror's `marketIndex` READ from the venue, or CHOSEN?
 *
 * HAND-MAINTAINED, and it mirrors `marketIndexVerified` in `deployments/46630.json` — one
 * entry per vault in that file, copied here. It is not read from `contracts.ts` because it
 * is not in `contracts.ts`: `scripts/gen-frontend-abi.py` emits a fixed key list per mirror
 * (symbol, marketIndex and the five addresses) and drops everything else in the address
 * book, so there is nothing generated to read. Keep the two in step by hand until the
 * generator carries the field; `Record<Mirror["symbol"], boolean>` at least guarantees that
 * a new mirror cannot compile without someone deciding which value it gets.
 *
 * `true` means the index was read from the venue's `api/v1/orderBookDetails`
 * (WHITEPAPER.md §4.4, measured 2026-09-07), which is TSLA 16 and NVDA 15 and nothing else.
 * uSPY's 26 and uQQQ's 27 are PLACEHOLDERS — a work item, not a disclaimer.
 *
 * Why it is worth publishing rather than filing: on the testnet simulator
 * `setMarkPrice(marketIndex, px)` creates the market implicitly, so an unverified index
 * deploys, bootstraps, attests and reads back completely clean — there is no symptom. On a
 * real venue the same index would hedge against the WRONG MARKET. The address book's own
 * instruction is to re-read `market_id` and redeploy the mirror before pointing it at one.
 */
/**
 * ALL FOUR ARE FALSE as of 2026-09-25, and two of them changed from true.
 *
 * uTSLA 16 and uNVDA 15 were recorded as venue-verified, read from the venue's market list
 * on 2026-09-07. Checked against Lighter's LIVE market list on Robinhood Chain mainnet
 * (`mainnet.zklighter.elliot.ai/api/v1/orderBookDetails`, 235 active markets), every one of
 * the four is wrong:
 *
 *     mirror   deployed   real market_id on the live venue
 *     uTSLA          16   112
 *     uSPY           26   128
 *     uQQQ           27   129
 *     uNVDA          15   110
 *
 * So the earlier reading has either gone stale or came from a different venue instance.
 * Either way "verified" no longer describes it, and a true here would be the most expensive
 * kind of wrong: it is the flag that tells a reader this mirror hedges the market it names.
 *
 * Nothing misbehaves on testnet, where LighterSim's setMarkPrice() creates any index
 * implicitly. Against the real venue index 16 is not TSLA.
 */
const MARKET_INDEX_VERIFIED: Record<Mirror["symbol"], boolean> = {
  uTSLA: false,
  uSPY: false,
  uQQQ: false,
  uNVDA: false,
};

/**
 * Whether this mirror's `marketIndex` was venue-verified. See `MARKET_INDEX_VERIFIED`.
 *
 * Exported so a consumer holding only a vault id — a loading placeholder, or the store
 * assembling its `Vault` rows — can publish the provenance of the market index it is about
 * to show next to a price, without duplicating the map.
 */
export function isMarketIndexVerified(id: ChainVaultId): boolean {
  return MARKET_INDEX_VERIFIED[mirrorFor(id).symbol];
}

/**
 * One sentence for an unverified market index, so every consumer says the same thing.
 *
 * Deliberately short and deliberately not alarming: on this testnet an unverified index is
 * harmless, and the honest statement is what it would be elsewhere, not what it is here.
 */
export const MARKET_INDEX_UNVERIFIED_NOTE =
  "This mirror's venue market index does not match the live venue's market list. Checked " +
  "2026-09-25 against Lighter on Robinhood Chain mainnet: the real ids are 112 for TSLA, " +
  "128 for SPY, 129 for QQQ and 110 for NVDA. On the testnet simulator setMarkPrice() " +
  "creates any index implicitly, so nothing here misbehaves; against the real venue these " +
  "would hedge the wrong market, and every mirror must be redeployed with the real id " +
  "before it points at one.";

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
 * there is no `cert-plate-uspy.jpg`, and uSPY must not borrow another certificate's plate.
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

/**
 * Which of `CapacityOracle.maxNotional18`'s legs is the one actually holding minting back.
 *
 * `maxNotional18` (`CapacityOracle.sol:89-98`) is
 * `min(openInterest18 * depthBps / 10_000, absoluteCap18[asset], bufferCapacity18)` with two
 * early returns to zero ahead of it. Every value below is named after the term it comes from,
 * because "at capacity" with no leg named is the least actionable message this app can print.
 */
export type CapacityLeg =
  /** `registry.ageSec(asset) > maxAttestationAgeSec` → 0 (`CapacityOracle.sol:90`). */
  | "stale-attestation"
  /** `openInterest18 == 0` → 0 (`CapacityOracle.sol:92-93`). */
  | "no-open-interest"
  /**
   * `BufferBook.capacity18` returns 0 whenever `balance18 <= 0` (`BufferBook.sol:183-187`),
   * which forces `bufferCapacity18()` to 0 and `maxNotional18` with it. THE SILENT HALT: the
   * vault can be sitting on six figures of collateral and still refuse every mint.
   */
  | "buffer-ledger-nonpositive"
  /**
   * `freeCollateral18() == 0` → the own-capital term of `bufferCapacity18()` is 0
   * (`CertVault.sol:563-569`, `CertVault.sol:529-533`). The float is fully committed to
   * outstanding redemption obligations.
   */
  | "no-free-collateral"
  /** `openInterest18 * depthBps / 10_000` is the smallest term — venue depth. */
  | "depth"
  /** `absoluteCap18[asset]` is the smallest term — the governance cap. */
  | "absolute-cap"
  /** `bufferCapacity18()` is the smallest term — the vault's own collateral. */
  | "buffer";

/**
 * The one BOUNDED capacity indicator: how much of the mint ceiling is used.
 *
 * Mirrors `CertVault._requireCapacity` (`CertVault.sol:1755-1771`) exactly, so it reaches 1.0
 * at the same moment `CertVault_AtCapacity` fires and cannot be read as anything else.
 *
 * This replaced `bufferHeld / bufferCapacity18()`, which was not an indicator at all.
 * `bufferCapacity18()` is a NOTIONAL-EXPOSURE CEILING (`freeCollateral18() * 100` capped by the
 * ledger's own claim, `CertVault.sol:563-569`), so that ratio is pinned within rounding of
 * `1/BUFFER_COVERAGE_MULTIPLE = 1%` at every fill level by construction, RISES as the vault
 * mints (`_postMargin` retains `1 - targetMarginBps` of every mint as float,
 * `CertVault.sol:1925-1931`), and is the loosest of the three legs anyway — it read
 * $10,000,003 against a binding $90,000 on uTSLA. It carried no information and reached 100%
 * at no fill level at all.
 */
export interface CapacityView {
  /**
   * `max((totalSupply + pendingMintCerts) * px / 1e18, registry.latest().notional18)`, the
   * `current` term of `_requireCapacity` (`CertVault.sol:1763-1767`). `null` only while the
   * first read is in flight.
   */
  used: number | null;
  used18: bigint | null;
  /**
   * `capacityOracle.maxNotional18(vault, vault.bufferCapacity18())` — read on-chain, not
   * re-derived, so it cannot drift from the value the contract gates on. `null` until the
   * dependent read lands (it needs `bufferCapacity18()` as an argument, so it cannot share the
   * first batch).
   */
  cap: number | null;
  cap18: bigint | null;
  /** `used / cap` as a percent. `null` when `cap` is unknown OR zero — zero is a real state. */
  utilisationPct: number | null;
  /**
   * `cap18 === 0n`: EVERY mint reverts `CertVault_AtCapacity`, whatever the collateral held and
   * whatever `oracle.mintAllowed()` says. `false` while `cap18` is still unknown — an unknown
   * cap must never present as a halt.
   */
  capIsZero: boolean;
  /** `used >= cap` with a non-zero cap: the next mint of any size reverts. */
  atCapacity: boolean;
  /**
   * EVERY term sitting at the binding value, not just one.
   *
   * Every mirror is seeded so that its depth and governance legs TIE: `seedOpenInterest18 ×
   * depthBps(1000) == absoluteCap18` by construction on all four ($90,000 on uTSLA,
   * $5,000,000 on uSPY, $3,050,000 on uQQQ, $311,000 on uNVDA). Naming one of them and
   * calling the other slack would be wrong — raising either alone moves the ceiling nowhere.
   * Empty until `cap18` is known.
   */
  bindingLegs: CapacityLeg[];
  /** The first binding leg, for the single-name callers. `null` until `cap18` is known. */
  bindingLeg: CapacityLeg | null;
  /** The three legs of the min(), in dollars. `null` where the input has not been read. */
  legs: { depth: number | null; absoluteCap: number | null; buffer: number | null };
  /**
   * `BufferBook.balance18(vault)` — the accrual ledger, SIGNED. At or below zero,
   * `BufferBook.capacity18` returns 0 (`BufferBook.sol:183-187`) and minting stops dead. This
   * is the number that explains that halt.
   *
   * It is the SAME QUANTITY as `backing.accrualClaimedUnverified`: `_solvency` sets
   * `s.accrual18 = buffer.balance18(address(this))` (`CertVault.sol:1570`), so the two agree by
   * construction — read here from `BufferBook` directly because it is the capacity input, and
   * there because it is the published solvency field. Read live they match to the wei
   * ($100,000.034292 on uTSLA). Two names for one number, never two numbers.
   *
   * NEVER added to `backing.bufferHeld`: `seedBuffer` writes the same dollars to the vault's
   * ERC-20 balance AND to this ledger (`CertVault.sol:595-598`), so a sum double-counts the
   * $100,000 seeding that makes both read about $100,000 per mirror.
   */
  bufferLedger: number | null;
  bufferLedger18: bigint | null;
  /** `freeCollateral18()` — the own-capital input to `bufferCapacity18()`. */
  freeCollateral: number | null;
}

/**
 * `solvency.deltaBps`, decoded into the three states the contract can actually publish.
 *
 * A bare number cannot represent this field honestly: two of its three states are sentinels
 * for a division by zero, not measurements (`CertVault.sol:1587-1600`).
 */
export type DeltaView =
  /**
   * `a.notional18 * 10_000 / required` with a non-zero obligation. `hedgeRatioPct` is 100 when
   * the attested position exactly covers the obligation; `driftPct` is SIGNED — negative is
   * under-hedged, positive over-hedged. The direction IS recoverable, contrary to what stage 2
   * asserted on screen: it is the side of 10_000 the ratio falls on.
   */
  | { kind: "measured"; hedgeRatioPct: number; driftPct: number }
  /**
   * `required == 0` and the attested notional is 0 too: nothing outstanding and nothing hedged.
   * The contract publishes 10_000 here so `rebalance()` reverts `CertVault_InBand`
   * (`CertVault.sol:1597`). It is a sentinel, not a reading of a position — there is no
   * position — so it must render as "no position", never as "at target" and never as "100%".
   */
  | { kind: "no-obligation" }
  /**
   * `DELTA_UNBOUNDED_BPS`: a live attested position against a ZERO obligation. The worst state
   * the vault can be in — pure unhedged directional risk (`CertVault.sol:1491-1508`).
   */
  | { kind: "unbounded" };

export interface LiveVault extends Omit<Vault, "id" | "price"> {
  id: ChainVaultId;

  /* ---------------------------------------------------------------- addresses */
  vaultAddress: `0x${string}`;
  certificateAddress: `0x${string}`;
  oracleAddress: `0x${string}`;
  marketIndex: number;
  /**
   * Whether `marketIndex` was read back from the venue or chosen. See
   * `MARKET_INDEX_VERIFIED`. It travels with `marketIndex` for the same reason `ageSec`
   * travels with `backing`: four indices presented identically read as four equally
   * confirmed indices, and only two of them are.
   */
  marketIndexVerified: boolean;
  imgPlaceholder: boolean;

  /* ------------------------------------------------------------- non-null figures */
  /**
   * Every figure on the store's `Vault` is nullable, because `VaultId` admits ids with no
   * contracts at all, which must render nothing. A DEPLOYED mirror always has these, so
   * they are narrowed back to `number` here — `price` stays the one genuine exception,
   * because `oracle.px()` really does revert.
   */
  supply: number;
  buffer: number;
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

  /**
   * The guard thresholds this mirror’s oracle actually enforces, read from it.
   *
   * `px()` reverts past `stalenessSeconds`; `mintAllowed()` goes false on a deviation
   * beyond `deviationBps` or a basis outside `basisBandBps`. Published so the risk table
   * can name a number a reader can check against the oracle, instead of quoting one from
   * a document that nothing keeps in sync with the deployment.
   */
  guards: { stalenessSeconds: number; deviationBps: number; basisBandBps: number };

  /* -------------------------------------------------------------------- basis */
  /**
   * `known` from `oracle.basisBpsChecked()`. False means there is no independent basis to
   * compute at all — the feed and the venue mark are declared the same source.
   *
   * On chain 46630 this is `true` on every mirror, because every `CertOracle` was deployed
   * with `singleSource: false`. Read `BASIS_ON_THIS_DEPLOYMENT` before rendering the number
   * that comes with it: `known === true` here is a CONFIGURATION FLAG, not a measurement.
   */
  basisKnown: boolean;
  /**
   * `bps` from `oracle.basisBpsChecked()`, in percent, or `null` when `basisKnown` is
   * false. Deliberately nullable: collapsing "unverifiable" to `0` silently turns it into
   * "perfect".
   *
   * It reads 0.00% on every mirror of this deployment and that is not evidence of
   * agreement — see `BASIS_ON_THIS_DEPLOYMENT`.
   */
  basisBps: number | null;

  /* ------------------------------------------------------------------ capacity */
  /** `vault.hotBuffer()`, 6 dp → display number. The instant-redeem float. */
  hotBuffer: number;
  /**
   * `vault.bufferCapacity18()`, 18 dp → display number.
   *
   * NOT headroom, NOT total buffer capacity and NOT the value that blocks a mint: it is one
   * of three legs of a notional-exposure ceiling (`CertVault.sol:563-569`) and the loosest of
   * them. Kept because it is the argument `maxNotional18` takes and worth publishing as such;
   * use `capacity.utilisationPct` for anything a reader is meant to act on.
   */
  bufferCapacity: number;
  /** The bounded mint-ceiling indicator, mirroring `_requireCapacity`. */
  capacity: CapacityView;
  /** `solvency.deltaBps`, decoded. See `DeltaView` — a bare percent cannot say this. */
  deltaView: DeltaView;

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
    /** RAW bps. 10_000 = at target; `DELTA_UNBOUNDED_BPS` is a sentinel. Decode, do not divide. */
    deltaBps: bigint;
    ageSec: bigint;
    provenAtBatch: bigint;
    px18: bigint | null;
    hotBuffer6: bigint;
    bufferCapacity18: bigint;
    basisBps: bigint | null;
    /** `vault.pendingMintCerts()` — certificates reserved by unsettled mint requests. */
    pendingMintCerts18: bigint;
    /** `registry.latest(vault).openInterest18` — the depth leg's input. */
    openInterest18: bigint;
    /** `capacityOracle.depthBps()`. Shared across mirrors. */
    depthBps: bigint | null;
    /** `capacityOracle.absoluteCap18(vault)`. */
    absoluteCap18: bigint | null;
    /** `bufferBook.balance18(vault)`, SIGNED. */
    bufferLedger18: bigint | null;
    /** `vault.freeCollateral18()`. */
    freeCollateral18: bigint | null;
    /** `capacityOracle.maxNotional18(vault, bufferCapacity18)`. `null` until the 2nd read lands. */
    maxNotional18: bigint | null;
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
  /**
   * `vault.keeperHedging()`. On Robinhood Chain Lighter an order sent through the L1 contract
   * is reduce-only, so a keeper-mode vault cannot open its own hedge: every mint is
   * `requestMint`, the keeper opens the hedge off chain and settles it, and `mintInstant`
   * reverts. The router has to know which kind of vault it is talking to.
   */
  keeperHedging: boolean;
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
const CALLS_PER_MIRROR = 16;

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
    // ---- the capacity legs. `_requireCapacity` values `totalSupply + pendingMintCerts`,
    // not `totalSupply` alone (CertVault.sol:1763), so the reservation held by unsettled
    // mint requests has to be read or the utilisation understates itself.
    call(mirror.vault, CertVaultABI, "pendingMintCerts"),
    // openInterest18 feeds the depth leg; the same attestation also gives the notional18
    // floor that `_requireCapacity` takes the max against (CertVault.sol:1765).
    call(SHARED.solvencyRegistry, SolvencyRegistryABI, "latest", [mirror.vault]),
    call(SHARED.capacityOracle, CapacityOracleABI, "absoluteCap18", [mirror.vault]),
    // BufferBook is keyed by the VAULT address: CertVault passes address(this) into both
    // buffer.capacity18 and buffer.accrue (CertVault.sol:566, 597).
    call(mirror.bufferBook, BufferBookABI, "balance18", [mirror.vault]),
    // The own-capital input to bufferCapacity18() (CertVault.sol:564). Read so a zero
    // ceiling can be attributed to an empty float rather than to the ledger.
    call(mirror.vault, CertVaultABI, "freeCollateral18"),
    // ---- the oracle's own guard thresholds.
    //
    // These decide when px() reverts and when mintAllowed() goes false. Until now the
    // dashboard discussed them only in comments while the risk table named them in prose.
    // A threshold a reader cannot check is indistinguishable from one that was made up, so
    // they are read from the oracle that enforces them rather than copied from a document.
    call(mirror.certOracle, CertOracleABI, "stalenessSeconds"),
    call(mirror.certOracle, CertOracleABI, "deviationBps"),
    call(mirror.certOracle, CertOracleABI, "basisBandBps"),
  ];
}

/**
 * Calls that are one-per-deployment rather than one-per-mirror, appended AFTER every
 * mirror's block so `CALLS_PER_MIRROR` indexing stays valid.
 */
const SHARED_CALL_BASE = MIRRORS.length * CALLS_PER_MIRROR;
const SHARED_CALLS: ContractCall[] = [
  call(SHARED.capacityOracle, CapacityOracleABI, "depthBps"),
];

/** Stable empty array: a fresh `[]` each render would re-key wagmi's query every time. */
const NO_CALLS: ContractCall[] = [];

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

/**
 * `SolvencyRegistry.latest(asset)` → `openInterest18`, the input to the depth leg.
 *
 * viem decodes a named-tuple output as an object; the positional fallback mirrors
 * `asSolvency`'s, for the same reason. `null` rather than `0n` on a failed decode, because a
 * zero open interest is itself a hard mint stop (`CapacityOracle.sol:92-93`) and must not be
 * manufactured by a decode miss.
 */
function asOpenInterest18(entry: ReadResult | undefined): bigint | null {
  if (!entry || entry.status !== "success") return null;
  const raw = entry.result;
  if (!raw || typeof raw !== "object") return null;
  const value = Array.isArray(raw)
    ? (raw as unknown[])[2]
    : (raw as Record<string, unknown>).openInterest18;
  return typeof value === "bigint" ? value : null;
}

/** The smaller of two, ignoring `null`. `null` only when both are unknown. */
function minKnown(a: bigint | null, b: bigint | null): bigint | null {
  if (a === null) return b;
  if (b === null) return a;
  return a < b ? a : b;
}

/**
 * Decode `solvency.deltaBps` into the state it actually represents.
 *
 * The two sentinel branches are distinguishable without re-deriving `required`, which is what
 * makes this safe: `_solvency`'s measured branch is `a.notional18 * 10_000 / required`
 * (`CertVault.sol:1600`), so a zero attested notional there yields 0 and can NEVER yield
 * 10_000. `deltaBps === 10_000` with `notional18 === 0` is therefore the sentinel branch and
 * nothing else — no dependence on `px`, which matters because `_solvency` prices off
 * `pxUnguarded()` and so still computes `required` when `px()` itself reverts
 * (`CertVault.sol:1539`).
 */
function decodeDelta(deltaBps: bigint, notional18: bigint): DeltaView {
  if (deltaBps === DELTA_UNBOUNDED_BPS) return { kind: "unbounded" };
  if (deltaBps === DELTA_TARGET_BPS && notional18 === 0n) return { kind: "no-obligation" };
  return {
    kind: "measured",
    hedgeRatioPct: fromBps(deltaBps),
    driftPct: fromBps(deltaBps) - 100,
  };
}

/**
 * Assemble the bounded capacity indicator for one mirror.
 *
 * `cap18` is the value read from `CapacityOracle.maxNotional18` — never re-derived here. The
 * legs are read too, but only to NAME which term binds; a wrong label is cosmetic, whereas a
 * re-derived ceiling that drifts from the contract's own would be a lie about admission
 * control. That matters concretely: `CapacityOracle.maxAttestationAgeSec` is an immutable with
 * no getter in the generated ABI, so the staleness early return cannot be reproduced faithfully
 * off-chain at all.
 */
function buildCapacity(input: {
  supply18: bigint;
  pendingMintCerts18: bigint;
  px18: bigint | null;
  attestedNotional18: bigint;
  cap18: bigint | null;
  openInterest18: bigint | null;
  depthBps: bigint | null;
  absoluteCap18: bigint | null;
  bufferCapacity18: bigint;
  bufferLedger18: bigint | null;
  freeCollateral18: bigint | null;
  ageSec: number;
}): CapacityView {
  const {
    supply18,
    pendingMintCerts18,
    px18,
    attestedNotional18,
    cap18,
    openInterest18,
    depthBps,
    absoluteCap18,
    bufferCapacity18,
    bufferLedger18,
    freeCollateral18,
    ageSec,
  } = input;

  // `current` from _requireCapacity (CertVault.sol:1763-1767): the obligation measure valued
  // at the live price, floored by the attested notional. The attested floor is kept for the
  // reason the contract keeps it — it is the only term that sees a position the vault's own
  // books have lost track of.
  const own18 = px18 !== null ? ((supply18 + pendingMintCerts18) * px18) / ONE_18 : null;
  const used18 =
    own18 === null ? null : own18 > attestedNotional18 ? own18 : attestedNotional18;

  const byDepth18 =
    openInterest18 !== null && depthBps !== null ? (openInterest18 * depthBps) / BPS_ONE : null;

  // The min() legs, in the oracle's own order (CapacityOracle.sol:94-97).
  const tightest = minKnown(minKnown(byDepth18, absoluteCap18), bufferCapacity18);

  const bindingLegs: CapacityLeg[] = [];

  if (cap18 !== null) {
    if (ageSec > MAX_ATTESTATION_AGE_SEC) {
      bindingLegs.push("stale-attestation");
    } else if (openInterest18 === 0n) {
      bindingLegs.push("no-open-interest");
    } else if (bufferLedger18 !== null && bufferLedger18 <= 0n) {
      // BufferBook.sol:183-187 — the silent halt. Checked before the generic buffer leg so
      // the message can name the ledger rather than the collateral.
      bindingLegs.push("buffer-ledger-nonpositive");
    } else if (bufferCapacity18 === 0n) {
      bindingLegs.push(freeCollateral18 === 0n ? "no-free-collateral" : "buffer");
    } else if (tightest !== null) {
      if (byDepth18 !== null && byDepth18 === tightest) bindingLegs.push("depth");
      if (absoluteCap18 !== null && absoluteCap18 === tightest) bindingLegs.push("absolute-cap");
      if (bufferCapacity18 === tightest) bindingLegs.push("buffer");
    }
  }

  const capIsZero = cap18 !== null && cap18 === 0n;
  const utilisationPct =
    used18 !== null && cap18 !== null && cap18 > 0n
      ? // Kept in bigint to the last step: an 18-decimal ratio through a double loses the
        // low digits, and this number decides whether a warning shows.
        Number((used18 * 1_000_000n) / cap18) / 10_000
      : null;

  return {
    used: used18 === null ? null : fromPrice18(used18),
    used18,
    cap: cap18 === null ? null : fromPrice18(cap18),
    cap18,
    utilisationPct,
    capIsZero,
    atCapacity: used18 !== null && cap18 !== null && cap18 > 0n && used18 >= cap18,
    bindingLegs,
    bindingLeg: bindingLegs[0] ?? null,
    legs: {
      depth: byDepth18 === null ? null : fromPrice18(byDepth18),
      absoluteCap: absoluteCap18 === null ? null : fromPrice18(absoluteCap18),
      buffer: fromPrice18(bufferCapacity18),
    },
    bufferLedger: bufferLedger18 === null ? null : fromPrice18(bufferLedger18),
    bufferLedger18,
    freeCollateral: freeCollateral18 === null ? null : fromPrice18(freeCollateral18),
  };
}

/**
 * Human sentence for the set of binding legs, so every consumer says the same thing.
 *
 * Joined rather than reduced to one name because ties are the live case on every mirror, and
 * "bound by the governance cap" alone would invite someone to raise the cap and see nothing
 * move.
 */
export function capacityLegsLabel(legs: CapacityLeg[]): string {
  if (legs.length === 0) return "";
  if (legs.length === 1) return capacityLegLabel(legs[0]);
  const parts = legs.map(capacityLegLabel);
  return `${parts.slice(0, -1).join(", ")} and ${parts[parts.length - 1]} — tied, so raising either alone moves nothing`;
}

/** Human sentence for a binding leg, so every consumer says the same thing. */
export function capacityLegLabel(leg: CapacityLeg): string {
  switch (leg) {
    case "stale-attestation":
      return `the attestation is older than ${MAX_ATTESTATION_AGE_SEC}s, so CapacityOracle returns a cap of zero`;
    case "no-open-interest":
      return "the attested venue open interest is zero, so the depth leg is zero";
    case "buffer-ledger-nonpositive":
      return "the BufferBook accrual ledger is at or below zero, which forces the whole ceiling to zero";
    case "no-free-collateral":
      return "freeCollateral18() is zero — the float is fully committed to outstanding redemption obligations";
    case "depth":
      return "venue depth: openInterest18 × depthBps";
    case "absolute-cap":
      return "the governance absoluteCap18 for this vault";
    case "buffer":
      return "bufferCapacity18() — the vault's own collateral leg";
  }
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
  const refetchInterval = options?.refetchIntervalMs ?? 15_000;
  const contracts = useMemo(
    () => [...MIRRORS.flatMap((m) => vaultCalls(m)), ...SHARED_CALLS],
    [],
  );

  const query = useReadContracts({
    contracts,
    query: {
      refetchInterval,
      // A revert on px() is information; keep the rest of the batch.
      retry: 1,
    },
  });

  const results = (query.data ?? []) as ReadResult[];

  /**
   * `maxNotional18(asset, bufferCapacity18)` takes the buffer ceiling as an ARGUMENT
   * (`CapacityOracle.sol:89`), so it cannot ride in the batch that reads that ceiling. It gets
   * its own dependent batch rather than being re-derived off-chain, because this is the number
   * `_requireCapacity` actually gates on and a re-derivation cannot see the oracle's own
   * `maxAttestationAgeSec` immutable at all (no getter in the generated ABI).
   *
   * The cost is that `cap` trails `bufferCapacity18` by one round trip. That is acceptable and
   * bounded: both batches share `refetchInterval`, and the consequence of a one-tick-old cap on
   * a utilisation bar is a stale percentage, not a wrong action — the mint path reads capacity
   * on-chain again inside the transaction.
   */
  const bufferCaps = useMemo(
    () => MIRRORS.map((_, i) => asBigint(results[i * CALLS_PER_MIRROR + 2])),
    [results],
  );

  const capacityContracts = useMemo<ContractCall[]>(() => {
    // All-or-nothing so decoding stays index-aligned with MIRRORS.
    if (!bufferCaps.every((b) => b !== null)) return NO_CALLS;
    return MIRRORS.map((m, i) =>
      call(SHARED.capacityOracle, CapacityOracleABI, "maxNotional18", [
        m.vault,
        bufferCaps[i] as bigint,
      ]),
    );
  }, [bufferCaps]);

  const capacityQuery = useReadContracts({
    contracts: capacityContracts,
    query: { enabled: capacityContracts.length > 0, refetchInterval, retry: 1 },
  });

  const capacityResults = (capacityQuery.data ?? []) as ReadResult[];

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
      const pendingMintCerts18 = asBigint(results[base + 8]) ?? 0n;
      const openInterest18 = asOpenInterest18(results[base + 9]);
      const absoluteCap18 = asBigint(results[base + 10]);
      const bufferLedger18 = asBigint(results[base + 11]);
      const freeCollateral18 = asBigint(results[base + 12]);
      const depthBps = asBigint(results[SHARED_CALL_BASE]);
      const maxNotional18 = asBigint(capacityResults[i]);

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
      const bufferCapacity = fromPrice18(bufferCapacity18);

      const capacity = buildCapacity({
        supply18,
        pendingMintCerts18,
        px18,
        attestedNotional18: solvency.notional18,
        cap18: maxNotional18,
        openInterest18,
        depthBps,
        absoluteCap18,
        bufferCapacity18,
        bufferLedger18,
        freeCollateral18,
        ageSec,
      });

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
        marketIndexVerified: MARKET_INDEX_VERIFIED[mirror.symbol],

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

        // `bufferPct` is gone, not renamed. It was `bufferHeld / bufferCapacity18()`, a
        // constant near 1% at every fill level by construction (see `CapacityView`), and
        // deleting the field is the only way to be sure no component renders it again.
        deltaView: decodeDelta(solvency.deltaBps, solvency.notional18),

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

        // Read from the oracle, never from a constant: these are what it actually enforces.
        guards: {
          stalenessSeconds: Number(asBigint(results[base + 13]) ?? 0n),
          deviationBps: Number(asBigint(results[base + 14]) ?? 0n),
          basisBandBps: Number(asBigint(results[base + 15]) ?? 0n),
        },

        basisKnown: basis.known,
        basisBps: basis.bps !== null ? fromBps(basis.bps) : null,

        hotBuffer: fromCollateral(hotBuffer6),
        bufferCapacity,
        capacity,

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
          pendingMintCerts18,
          openInterest18: openInterest18 ?? 0n,
          depthBps,
          absoluteCap18,
          bufferLedger18,
          freeCollateral18,
          maxNotional18,
        },
      };
      return vault;
    });
  }, [results, capacityResults]);

  return {
    vaults,
    isLoading: query.isLoading,
    isFetching: query.isFetching,
    isError: query.isError,
    error: (query.error as Error | null) ?? null,
    dataUpdatedAt: query.dataUpdatedAt,
    refetch: () => {
      void query.refetch();
      void capacityQuery.refetch();
    },
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
    () => MIRRORS.flatMap((m) => [
      call(m.vault, CertVaultABI, "cfg"),
      call(m.vault, CertVaultABI, "keeperHedging"),
    ]),
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
      const entry = results[i * 2];
      const keeper = results[i * 2 + 1];
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
        keeperHedging: keeper?.status === "success" && keeper.result === true,
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
      // The three faucet reads only exist where a faucet does. On mainnet they are omitted
      // rather than reverting three times per poll against an address that is not there.
      ...(FAUCET_ADDRESS
        ? [
            call(FAUCET_ADDRESS, TestFaucetABI, "nextAvailableAt", [address]),
            call(SHARED.collateral, TestUSDGABI, "balanceOf", [FAUCET_ADDRESS]),
            call(FAUCET_ADDRESS, TestFaucetABI, "dripAmount"),
          ]
        : []),
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
      // Zero without a faucet, which is exactly what the UI already renders for an empty one.
      faucetNextAvailableAt: HAS_FAUCET ? Number(asBigint(results[tail]) ?? 0n) : 0,
      faucetBalance: HAS_FAUCET ? fromCollateral(asBigint(results[tail + 1]) ?? 0n) : 0,
      faucetDrip: HAS_FAUCET ? fromCollateral(asBigint(results[tail + 2]) ?? 0n) : 0,
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
  /**
   * `margin / notional` as a percent, or `null` when the attested notional is ZERO.
   *
   * It used to be `(margin / Math.max(1, notional)) * 100`, which does not guard the divide —
   * it replaces a zero denominator with ONE DOLLAR. A freshly bootstrapped mirror attests
   * `notional18 == 0` (zero supply, nothing hedged), so that clamp published the attested
   * margin as a percentage: $460.54 of margin rendered as "46,054.10%" of a position that
   * does not exist. A ratio with no denominator is undefined and must be an em-dash, not an
   * artefact. uQQQ and uNVDA are in exactly that state on arrival, so this guard is the one
   * standing between them and a five-figure percentage.
   */
  ratio: number | null;
  /**
   * Backing (attested margin + collateral held) over obligation (supply x oracle price), as a
   * percent. `null` when no mirror published a point.
   *
   * THIS, NOT `ratio`, IS THE SOLVENCY TEST. `ratio` is margin over the hedge notional, which
   * sits at `targetMarginBps` BY DESIGN - 90% on this deployment, because `_postMargin` posts
   * only the target and retains the rest as float (`CertVault.sol:1925-1931`). Gating health on
   * `ratio >= 100` therefore condemns a correctly configured vault: the live mirrors read
   * 91.11% and the header published "Degraded - check age and oracle" while basis was 0 bps,
   * minting was allowed on both mirrors and the hedge sat exactly at target. Solvency is
   * whether backing covers what holders are owed, and that is this number.
   */
  backingRatio: number | null;
  /** Sum of `capacity.used` across mirrors, `null` if any is unknown. */
  capacityUsed: number | null;
  /** Sum of `capacity.cap` across mirrors, `null` if any is unknown. */
  capacityCap: number | null;
  /** Protocol-wide `used / cap` as a percent. `null` when either side is unknown or the cap is 0. */
  capacityUtilisationPct: number | null;
  /** True when ANY routed vault has a cap of exactly zero: that vault refuses every mint. */
  anyCapacityHalted: boolean;
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

  // `null` propagates: a partial sum across mirrors would understate the total and read as a
  // measurement. Both are still in the exact 18-decimal domain at this point.
  const used18 = sum18(live.map((v) => v.capacity.used18));
  const cap18 = sum18(live.map((v) => v.capacity.cap18));

  return {
    notional,
    margin,
    buffer,
    accrualClaimedUnverified,
    ratio: notional > 0 ? (margin / notional) * 100 : null,
    backingRatio: (() => {
      // Same provenance the Overview strip uses: the per-vault point, which values the
      // obligation at the live guarded price and excludes the unverified accrual claim.
      const pts = live.map((v) => v.solvency[0] ?? null);
      if (pts.length === 0 || pts.some((pt) => pt === null)) return null;
      const ob = pts.reduce((t, pt) => t + pt!.obligation, 0);
      const bk = pts.reduce((t, pt) => t + pt!.backing, 0);
      // A zero obligation is not a solvency failure - nothing is owed. Report fully covered.
      if (ob <= 0) return bk >= 0 ? Number.POSITIVE_INFINITY : 0;
      return (bk / ob) * 100;
    })(),
    capacityUsed: used18 === null ? null : fromPrice18(used18),
    capacityCap: cap18 === null ? null : fromPrice18(cap18),
    capacityUtilisationPct:
      used18 !== null && cap18 !== null && cap18 > 0n
        ? Number((used18 * 1_000_000n) / cap18) / 10_000
        : null,
    anyCapacityHalted: live.some((v) => v.capacity.capIsZero),
    worstAgeSec: live.reduce((s, v) => Math.max(s, v.ageSec), 0),
    anyStale: live.some((v) => v.attestationStale),
    anyPriceUnavailable: live.some((v) => v.priceUnavailable),
  };
}

/** Sum 18-decimal bigints, returning `null` if any term is unknown. */
function sum18(values: (bigint | null)[]): bigint | null {
  let total = 0n;
  for (const v of values) {
    if (v === null) return null;
    total += v;
  }
  return total;
}

/** Addresses for a mirror, for the write hooks and for explorer links. */
export function vaultAddresses(id: ChainVaultId): Mirror {
  return mirrorFor(id);
}

/* `clampPct` is gone with `bufferPct`. It clamped a ratio into [0, 100] for a bar, which is
 * the right thing to do to a BAR and the wrong thing to do to a FIGURE: capacity utilisation
 * can legitimately exceed 100% (`_requireCapacity` compares `current > max`, so an existing
 * position can sit above a cap that governance has since lowered) and clamping it would hide
 * exactly that. Clamp at the point of drawing the bar instead — see `CapacityBar`. */
