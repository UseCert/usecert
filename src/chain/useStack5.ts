/**
 * The stack-5 timing facts one vault's mint and redeem forms need, read from the chain.
 *
 * Stack 5 adds three clocks a holder can run into, and each is a routing decision the form has
 * to make BEFORE the wallet rather than explain after a revert:
 *
 *  - `CertOracle.markAt` against `maxMarkAge`: `mintAllowed()` is false once the venue mark is
 *    older than that. On an idle protocol that is the resting state, and a mint relays a fresh
 *    mark itself - so a stale mark must not disable the button that would refresh it.
 *  - `pxUnguarded()`'s observation time against `CertVault.INSTANT_MAX_PRICE_AGE` (1 h): past it
 *    `redeemInstant` refuses (every weekend, when the stock feeds stop) and the queue is the door.
 *  - `CertVault.QUEUED_PRICE_TIMEOUT` (4 days): a queued claim with no price observed since its
 *    request waits, and pays in full once this has passed from the request.
 *
 * Disabled on a stack-4 bundle: the stack-4 oracle has no `markAt`, so the reads would only fail.
 * Every field is null until read, and null is never treated as "fresh" or "stale" by a caller.
 */
import { useReadContracts } from "wagmi";

import { Stack5CertOracleABI, Stack5CertVaultABI } from "./contracts.stack5";
import { CHAIN_ID, IS_STACK5 } from "./deployment";
import { vaultAddresses, type ChainVaultId } from "./useVaults";

export interface Stack5VaultTimes {
  /** `CertOracle.markAt`, unix seconds: when the mark the oracle holds was observed. */
  markAt: number | null;
  /** `CertOracle.maxMarkAge`, seconds. */
  maxMarkAge: number | null;
  /** `CertOracle.pxUnguarded()`'s second value, unix seconds: when the redemption price was observed. */
  priceObservedAt: number | null;
  /** `CertVault.INSTANT_MAX_PRICE_AGE`, seconds (1 hour). */
  instantMaxPriceAge: number | null;
  /** `CertVault.QUEUED_PRICE_TIMEOUT`, seconds (4 days). */
  queuedPriceTimeout: number | null;
}

const NONE: Stack5VaultTimes = {
  markAt: null,
  maxMarkAge: null,
  priceObservedAt: null,
  instantMaxPriceAge: null,
  queuedPriceTimeout: null,
};

export function useStack5VaultTimes(id: ChainVaultId): Stack5VaultTimes {
  const m = vaultAddresses(id);
  const q = useReadContracts({
    contracts: [
      { address: m.certOracle, abi: Stack5CertOracleABI, chainId: CHAIN_ID, functionName: "markAt" },
      { address: m.certOracle, abi: Stack5CertOracleABI, chainId: CHAIN_ID, functionName: "maxMarkAge" },
      { address: m.certOracle, abi: Stack5CertOracleABI, chainId: CHAIN_ID, functionName: "pxUnguarded" },
      { address: m.vault, abi: Stack5CertVaultABI, chainId: CHAIN_ID, functionName: "INSTANT_MAX_PRICE_AGE" },
      { address: m.vault, abi: Stack5CertVaultABI, chainId: CHAIN_ID, functionName: "QUEUED_PRICE_TIMEOUT" },
    ],
    query: { enabled: IS_STACK5, refetchInterval: 15_000 },
  });
  if (!IS_STACK5) return NONE;
  const r = q.data;
  const num = (i: number): number | null =>
    r?.[i]?.status === "success" ? Number(r[i].result as bigint) : null;
  const px = r?.[2]?.status === "success" ? (r[2].result as readonly [bigint, bigint]) : null;
  return {
    markAt: num(0),
    maxMarkAge: num(1),
    priceObservedAt: px ? Number(px[1]) : null,
    instantMaxPriceAge: num(3),
    queuedPriceTimeout: num(4),
  };
}

/** Is the oracle's mark too old for `mintAllowed()`? Null while unknown. */
export function markIsStale(t: Stack5VaultTimes, nowSec: number): boolean | null {
  if (t.markAt === null || t.maxMarkAge === null) return null;
  return nowSec - t.markAt > t.maxMarkAge;
}

/** Would `redeemInstant` refuse the current price as too old? Null while unknown. */
export function instantPriceTooOld(t: Stack5VaultTimes, nowSec: number): boolean | null {
  if (t.priceObservedAt === null || t.instantMaxPriceAge === null) return null;
  return t.priceObservedAt + t.instantMaxPriceAge < nowSec;
}
