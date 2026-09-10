/**
 * Decimal-domain conversions for the UseCert contracts.
 *
 * ─────────────────────────────────────────────────────────────────────────────────────
 * WHY THIS FILE EXISTS
 * ─────────────────────────────────────────────────────────────────────────────────────
 * There are FOUR decimal domains in this system and they are not interchangeable
 * (INTEGRATION-NOTES.md §0.4):
 *
 *   collateral   6 dp   amountIn, amountOut, hotBuffer(), TestUSDG balances
 *   certificate 18 dp   certIn, certOut, every certificate balance, solvency.supply
 *   price / *18 18 dp   px(), fillPx18, notional18, margin18, buffer18, accrual18,
 *                       instantCap18, bufferCapacity18
 *   feed answer  8 dp   ReplayAggregator.latestRoundData().answer
 *   basis points 10_000 = 100%   deltaBps, mintFeeBps, redeemFeeBps, basisBps
 *
 * The trap: `mintInstant(amountIn)` takes SIX-decimal collateral and returns
 * EIGHTEEN-decimal certificates. `redeemInstant(certIn)` is the reverse. A single shared
 * `formatUnits(v, 18)` helper is wrong on roughly half the numbers in this app.
 *
 * So there is deliberately **no generic `format(value, decimals)` export here**. Every
 * domain gets its own named function, so a caller cannot pick the wrong decimal count by
 * accident — the wrong choice has to be spelled out to be made.
 *
 * ─────────────────────────────────────────────────────────────────────────────────────
 * PRECISION — READ THIS
 * ─────────────────────────────────────────────────────────────────────────────────────
 * The `from*` functions return a JS `number`, because the existing UI works in `number`.
 * A double holds ~15-17 significant digits; an 18-decimal value CANNOT be represented
 * exactly. Therefore:
 *
 *   *  `from*` results are **DISPLAY ONLY**. Never send one back to a contract.
 *   *  Every value that goes into a transaction must be built with `to*` (i.e. `parseUnits`)
 *      straight from the user's input **string**, never round-tripped through a float.
 *      `toCert(String(fromCert(v)))` is a bug: it silently truncates.
 *   *  Arithmetic that must be exact (fee maths, cap comparisons, quotes) stays in
 *      `bigint`. See `quoteCertOut18` / `quoteCollateralOut6` below.
 */
import { formatUnits, parseUnits } from "viem";

import { DECIMALS } from "./contracts";

/* ────────────────────────────────────────────────────────────── domain constants */

export const COLLATERAL_DECIMALS = DECIMALS.collateral; // 6
export const CERT_DECIMALS = DECIMALS.certificate; // 18
export const PRICE_DECIMALS = DECIMALS.price; // 18
export const FEED_DECIMALS = DECIMALS.feed; // 8

/** 10_000 basis points = 100%. */
export const BPS_ONE = 10_000n;

/** 10 ** 18, as a bigint. Fixed-point one for the 18-decimal domain. */
export const ONE_18 = 10n ** 18n;
/** 10 ** 6, as a bigint. Fixed-point one for the collateral domain. */
export const ONE_6 = 10n ** 6n;
/** The 10 ** 12 factor between the collateral (6 dp) and certificate/price (18 dp) domains. */
export const COLLATERAL_TO_18 = 10n ** BigInt(CERT_DECIMALS - COLLATERAL_DECIMALS);

/* ─────────────────────────────────────────────────── collateral domain — 6 decimals */

/**
 * Collateral (tUSDG / USDG, 6 dp) → display number.
 * Use for: `hotBuffer()`, `TestUSDG.balanceOf`, `amountOut`, faucet drip amounts.
 * DISPLAY ONLY.
 */
export function fromCollateral(value: bigint): number {
  return Number(formatUnits(value, COLLATERAL_DECIMALS));
}

/**
 * User input string → collateral `bigint` (6 dp), ready to send to a contract.
 * Use for: `approve(value)`, `mintInstant(amountIn)`, `requestMint(amountIn)`.
 * Pass the raw input string ("1234.56"), never a float.
 */
export function toCollateral(input: string): bigint {
  return parseUnits(normaliseInput(input), COLLATERAL_DECIMALS);
}

/* ───────────────────────────────────────────────── certificate domain — 18 decimals */

/**
 * Certificate units (uTSLA / uSPY / uQQQ / uNVDA, 18 dp) → display number.
 * Use for: `certificate.totalSupply()`, `certificate.balanceOf`, `certOut`,
 * `solvency.supply`.
 * DISPLAY ONLY.
 */
export function fromCert(value: bigint): number {
  return Number(formatUnits(value, CERT_DECIMALS));
}

/**
 * User input string → certificate `bigint` (18 dp), ready to send to a contract.
 * Use for: `redeemInstant(certIn)`, `requestRedeem(certIn)`, `forceExit(certIn)`.
 */
export function toCert(input: string): bigint {
  return parseUnits(normaliseInput(input), CERT_DECIMALS);
}

/* ──────────────────────────────────────────── price / *18 domain — 18 decimals, signed */

/**
 * Any 18-decimal figure → display number.
 * Use for: `px()`, `fillPx18`, `notional18`, `margin18`, `instantCap18`,
 * `bufferCapacity18`.
 *
 * Handles negative inputs, which matters: `solvency.buffer18` and `solvency.accrual18`
 * are `int256` and `accrual18` genuinely goes negative.
 * DISPLAY ONLY.
 */
export function fromPrice18(value: bigint): number {
  return Number(formatUnits(value, PRICE_DECIMALS));
}

/**
 * User/quote input string → 18-decimal `bigint`.
 * Use for anything named `*18` or `*Px18` that has to be sent on-chain.
 */
export function toPrice18(input: string): bigint {
  return parseUnits(normaliseInput(input), PRICE_DECIMALS);
}

/* ────────────────────────────────────────────────────── feed domain — 8 decimals */

/**
 * Chainlink/ReplayAggregator answer (8 dp) → display number.
 *
 * Note: you should not normally need this. Read prices through `CertOracle.px()`, which
 * applies the staleness, deviation and basis guards; reading the aggregator directly
 * bypasses all three (INTEGRATION-NOTES.md §2). Kept here so that if a debug view ever
 * does show a raw answer, it is not scaled with the wrong helper.
 * DISPLAY ONLY.
 */
export function fromFeed8(value: bigint): number {
  return Number(formatUnits(value, FEED_DECIMALS));
}

/* ───────────────────────────────────────────────────────────────── basis points */

/**
 * Basis points → **percent**. 10 bps → 0.1 (i.e. 0.10%).
 * Use for: `mintFeeBps`, `redeemFeeBps`, `deltaBps`, `basisBps`, `basisBandBps`.
 */
export function fromBps(bps: bigint): number {
  return Number(bps) / 100;
}

/**
 * Basis points → **fraction**. 10 bps → 0.001.
 * Separate from `fromBps` because "0.1" and "0.001" for the same input is exactly the
 * kind of factor-of-100 slip this file exists to stop.
 */
export function fromBpsFraction(bps: bigint): number {
  return Number(bps) / Number(BPS_ONE);
}

/** Percent → basis points. 0.1 (%) → 10n. */
export function toBps(percent: number): bigint {
  return BigInt(Math.round(percent * 100));
}

/* ────────────────────────────────────────── cross-domain scaling (exact, bigint only) */

/**
 * Collateral (6 dp) → the 18-decimal domain, exactly. Multiplies by 10**12.
 *
 * Needed because the mint size fork compares a **6-decimal** `amountIn` against an
 * **18-decimal** `instantCap18`. Comparing them without this scale is off by 10**12.
 */
export function scaleCollateralTo18(amount6: bigint): bigint {
  return amount6 * COLLATERAL_TO_18;
}

/**
 * The 18-decimal domain → collateral (6 dp), truncating. Divides by 10**12.
 * Truncation is deliberate: it rounds in the vault's favour, never the user's.
 */
export function scale18ToCollateral(amount18: bigint): bigint {
  return amount18 / COLLATERAL_TO_18;
}

/* ───────────────────────────────────────────────────────────── quotes (exact maths) */

/**
 * Indicative certificates out for a mint, computed entirely in `bigint`.
 *
 *   certOut ≈ amountIn × (10_000 − mintFeeBps) / 10_000 / px      (then 6 dp → 18 dp)
 *
 * Returns an 18-decimal `bigint`. Indicative only: the vault applies venue quantisation,
 * and on the `requestMint` path the real number depends on the keeper's fill price.
 * Show the fee separately — do not fold it silently into the rate.
 */
export function quoteCertOut18(params: {
  /** 6-decimal collateral in. */
  amountIn6: bigint;
  /** 18-decimal oracle price. */
  px18: bigint;
  /** Mint fee in basis points, from `vault.cfg()`. */
  mintFeeBps: bigint;
}): bigint {
  const { amountIn6, px18, mintFeeBps } = params;
  if (px18 <= 0n || amountIn6 <= 0n) return 0n;
  const net18 = (scaleCollateralTo18(amountIn6) * (BPS_ONE - mintFeeBps)) / BPS_ONE;
  return (net18 * ONE_18) / px18;
}

/**
 * Indicative collateral out for a redemption, computed entirely in `bigint`.
 *
 *   amountOut ≈ certIn × px × (10_000 − redeemFeeBps) / 10_000    (then 18 dp → 6 dp)
 *
 * Returns a 6-decimal `bigint`. Indicative only.
 */
export function quoteCollateralOut6(params: {
  /** 18-decimal certificates in. */
  certIn18: bigint;
  /** 18-decimal oracle price. */
  px18: bigint;
  /** Redeem fee in basis points, from `vault.cfg()`. */
  redeemFeeBps: bigint;
}): bigint {
  const { certIn18, px18, redeemFeeBps } = params;
  if (px18 <= 0n || certIn18 <= 0n) return 0n;
  const gross18 = (certIn18 * px18) / ONE_18;
  const net18 = (gross18 * (BPS_ONE - redeemFeeBps)) / BPS_ONE;
  return scale18ToCollateral(net18);
}

/**
 * The fee itself, in the 18-decimal domain, so the UI can show it rather than bury it.
 */
export function feeAmount18(notional18: bigint, feeBps: bigint): bigint {
  return (notional18 * feeBps) / BPS_ONE;
}

/* ──────────────────────────────────────────────────────────────────────── internals */

/**
 * Make a user-typed amount safe for `parseUnits`, which throws on "", ".", "1." etc.
 * Not exported: callers should think in domains, not in string hygiene.
 */
function normaliseInput(input: string): string {
  const trimmed = input.trim().replace(/,/g, "");
  if (trimmed === "" || trimmed === "." || trimmed === "-") return "0";
  if (trimmed.endsWith(".")) return `${trimmed}0`;
  if (trimmed.startsWith(".")) return `0${trimmed}`;
  return trimmed;
}
