/**
 * Can a mint refresh the on-chain attestation right now?
 *
 * WHY THIS EXISTS. The dashboard used to read a single fact - `ageSec` past
 * `maxAttestationAgeSec` - and conclude "minting is off". That was true while a
 * keeper broadcast on a timer: a stale attestation then meant the keeper had
 * failed, and minting really had stopped.
 *
 * On-demand attestation inverted it. The attester signs; the minter relays. Nobody
 * pays to keep the registry fresh while the protocol is idle, so a large `ageSec`
 * is now the NORMAL resting state - at the time of writing the on-chain figure was
 * 230,019s old while the signer was serving a signature 11s old, and minting worked
 * throughout. The dashboard reported "Degraded" for a healthy system, which is the
 * worse of the two failure directions: it teaches a reader to ignore the warning.
 *
 * So staleness alone no longer decides anything. The question is whether a mint
 * COULD refresh, and that depends on the signer, not on the registry. This hook
 * answers only that. It deliberately does NOT decide whether minting is allowed -
 * the oracle's health is a separate gate, and the caller combines them.
 *
 * WHAT A FALSE ANSWER COSTS, in each direction. Saying the signer is up when it is
 * down sends someone into a mint that reverts `CertVault_AtCapacity` and costs them
 * gas. Saying it is down when it is up tells them the protocol is broken when it is
 * not. Neither is free, so this reports `unknown` until it has actually looked, and
 * `unknown` renders as neither claim.
 */

import { useEffect, useState } from "react";

import { SHARED } from "./contracts";

const ENDPOINT = "/api/attestations";

/** How often to re-ask. Signatures are valid for 60s, so this cannot drift far behind. */
const POLL_MS = 30_000;

export interface SignerFreshness {
  /**
   * `null` before the first answer lands, and after a failure that leaves us with no
   * usable information. NOT `false` - "we have not looked" and "we looked and the
   * signer is down" are different statements and only one of them accuses anything.
   */
  available: boolean | null;
  /** Lowercased vault addresses the current batch actually covers. Empty when unknown. */
  vaults: Set<string>;
  /** Age of the served batch in seconds, or `null` when unknown. */
  batchAgeSec: number | null;
}

interface SignerResponse {
  generatedAt: number;
  ageSec: number | null;
  validitySec: number;
  stale: boolean;
  error: string | null;
  attestations: { vault: string; registry: string }[];
}

const UNKNOWN: SignerFreshness = { available: null, vaults: new Set(), batchAgeSec: null };

/** Down, and we know it: a definite negative, distinct from `UNKNOWN`. */
const DOWN: SignerFreshness = { available: false, vaults: new Set(), batchAgeSec: null };

export function useSignerFreshness(): SignerFreshness {
  const [state, setState] = useState<SignerFreshness>(UNKNOWN);

  useEffect(() => {
    let cancelled = false;

    async function look() {
      try {
        const res = await fetch(ENDPOINT, { cache: "no-store" });
        // A 5xx is the signer telling us it is unwell, which is information. A network
        // throw below is not - it could equally be the reader's own connection.
        if (!res.ok) {
          if (!cancelled) setState(DOWN);
          return;
        }
        const body = (await res.json()) as SignerResponse;
        if (cancelled) return;

        if (body.stale || body.error || !body.attestations?.length) {
          setState({ available: false, vaults: new Set(), batchAgeSec: body.ageSec ?? null });
          return;
        }

        // Same rule as the relay path in `attestation.ts`: a payload naming a registry
        // other than the bundled one is not a routing hint. Those signatures cannot be
        // relayed into this deployment, so they do not count towards freshness here
        // either - counting them would promise a refresh that would revert.
        const wanted = SHARED.solvencyRegistry.toLowerCase();
        const vaults = new Set(
          body.attestations
            .filter((a) => a.registry?.toLowerCase() === wanted)
            .map((a) => a.vault.toLowerCase()),
        );
        setState({ available: vaults.size > 0, vaults, batchAgeSec: body.ageSec ?? null });
      } catch {
        // Could not reach it. That is not evidence the signer is down, so claim nothing.
        if (!cancelled) setState(UNKNOWN);
      }
    }

    void look();
    const t = setInterval(() => void look(), POLL_MS);
    return () => {
      cancelled = true;
      clearInterval(t);
    };
  }, []);

  return state;
}

/**
 * Can this particular vault's attestation be refreshed by a mint?
 *
 * Per-vault rather than protocol-wide because the signer serves a batch and a batch
 * can be short one mirror. Telling someone minting is fine because three OTHER
 * vaults are covered is the same false positive in a smaller box.
 */
export function signerCovers(f: SignerFreshness, vault: `0x${string}` | undefined): boolean | null {
  if (f.available === null) return null;
  if (!f.available) return false;
  if (!vault) return null;
  return f.vaults.has(vault.toLowerCase());
}
