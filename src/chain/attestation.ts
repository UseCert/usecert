/**
 * Relaying the attester's signature, so a mint can pay for its own freshness.
 *
 * THE PROBLEM THIS SOLVES. `CapacityOracle.maxNotional18` returns zero once
 * `SolvencyRegistry.ageSec` passes 300s, and every mint then reverts
 * `CertVault_AtCapacity`. Keeping that from happening used to mean the attester
 * broadcasting on a timer whether or not anyone was minting — about 0.0071 ETH a
 * day to hold an idle protocol open, and on 2026-09-20 it failed silently for
 * 11.6 hours when that wallet ran dry.
 *
 * Now the attester SIGNS instead of sending. `/api/attestations` serves those
 * signatures, and whoever wants to mint relays one inside their own transaction.
 * An idle protocol costs nothing and the person who benefits pays.
 *
 * WHY THE TIMESTAMP IN THE PAYLOAD MATTERS TO A CLIENT. `observedAt` is part of
 * what the attester signed and is what the registry stores, so a signature held
 * for thirty seconds records data thirty seconds old — it cannot be relayed to
 * make stale figures look fresh. That is the registry's guarantee, not ours, but
 * it is why this module never invents or adjusts a timestamp: everything below is
 * passed through exactly as signed, or not sent at all.
 */

import { MIRRORS, SHARED } from "./contracts";

const ENDPOINT = "/api/attestations";

/** One mirror's signed attestation, exactly as the signer emitted it. */
export interface SignedAttestation {
  symbol: string;
  vault: `0x${string}`;
  certOracle: `0x${string}`;
  registry: `0x${string}`;
  batchId: number;
  notional18: string;
  margin18: string;
  openInterest18: string;
  markPx18: string;
  markNonce: number;
  observedAt: number;
  deadline: number;
  attestSig: `0x${string}`;
  markSig: `0x${string}`;
}

interface SignerResponse {
  generatedAt: number;
  ageSec: number | null;
  validitySec: number;
  stale: boolean;
  error: string | null;
  attestations: SignedAttestation[];
}

/**
 * Fetch the current batch of signatures.
 *
 * Returns null rather than throwing when the signer is down or its batch has
 * aged out: a missing signature is not an error the user caused, and the caller's
 * job is to explain that minting is closed, not to show a fetch failure.
 */
export async function fetchSignedAttestations(): Promise<SignerResponse | null> {
  try {
    const res = await fetch(ENDPOINT, { cache: "no-store" });
    if (!res.ok) return null;
    const body = (await res.json()) as SignerResponse;
    return body.stale || !body.attestations?.length ? null : body;
  } catch {
    return null;
  }
}

/** The signature for one vault, or null if this batch does not cover it. */
export function attestationFor(
  batch: SignerResponse | null,
  vault: `0x${string}`,
): SignedAttestation | null {
  if (!batch) return null;
  const lower = vault.toLowerCase();
  const found = batch.attestations.find((a) => a.vault.toLowerCase() === lower) ?? null;
  if (!found) return null;
  // The endpoint is trusted to say WHAT the attester signed, never WHERE to send it.
  // A payload naming a registry other than the bundled one is not a routing hint to
  // follow: it means the endpoint and this build disagree about which deployment is
  // current, and relaying it would either revert or reach a contract nobody here chose.
  if (found.registry.toLowerCase() !== SHARED.solvencyRegistry.toLowerCase()) return null;
  // Same rule for the oracle, for the same reason. The bundle carries a `certOracle` and
  // the mark half of the refresh is sent to one; the endpoint does not get to choose which.
  // The transaction is addressed from the bundled mirror regardless, so this check is not
  // what makes it safe - it is what makes the DISAGREEMENT visible instead of relaying a
  // signature that was produced for a different deployment and letting it revert.
  const mirror = MIRRORS.find((m) => m.vault.toLowerCase() === lower);
  if (!mirror) return null;
  if (found.certOracle.toLowerCase() !== mirror.certOracle.toLowerCase()) return null;
  return found;
}

/**
 * Is this signature still worth spending gas on?
 *
 * The registry refuses anything past `deadline`, and a transaction takes a block
 * or two to land. Treating a signature with only a couple of seconds left as
 * unusable costs one extra fetch; relaying it costs a failed transaction and the
 * gas that went with it.
 */
export function isRelayable(a: SignedAttestation, nowSec = Math.floor(Date.now() / 1000)): boolean {
  return a.deadline - nowSec >= 10;
}

/**
 * How stale the on-chain attestation may get before a mint needs to refresh it.
 *
 * The contract's own budget is 300s. Refreshing at 240 leaves a minute for the
 * relay and the mint to land — and if that window is missed the mint reverts
 * `CertVault_AtCapacity` rather than doing anything unsafe, so the cost of being
 * wrong here is a retry, not a loss.
 */
export const REFRESH_AT_AGE_SEC = 240;
