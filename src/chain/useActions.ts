/**
 * Write hooks for the UseCert deployment on Robinhood Chain testnet.
 *
 * Two contract reverts in here are NOT failures, and the whole design of this file is
 * built around not presenting them as such (INTEGRATION-NOTES.md §3.3 and §4):
 *
 *  *  `CertVault_UseQueuedRedeem` — the fast path DECLINING because the hot buffer cannot
 *     cover the payout. It is returned as `{ status: "needs-queued" }` so the caller can
 *     route to `requestRedeem`. Presenting it as an error is the single most likely way
 *     to make a working deployment look broken.
 *  *  `CertVault_AwaitingSettlement` on `claimRedeem` — the money has not arrived from the
 *     venue yet. Returned as `{ status: "awaiting-settlement", retryable: true }`. It is
 *     never terminal: the receipt stays claimable forever, and anyone may call
 *     `recallMargin()` to push it along. Never mark the receipt failed.
 *
 * The mint/redeem size fork is enforced HERE, before anything reaches the wallet.
 * `mintInstant` reverts `CertVault_AboveInstantCap` above the cap and `requestMint`
 * reverts `CertVault_BelowInstantCap` below it, so routing on the amount is not optional —
 * without it every large mint fails at the wallet. `instantCap18` is read from
 * `vault.cfg()`, never hardcoded.
 *
 * `forceExit` is deliberately gated on NOTHING. It reads no buffer level, no capacity, no
 * `mintAllowed` and no governance state. That is Design Law 2 and it is the product's
 * central promise — do not add a precondition to it.
 */
import { useCallback, useMemo } from "react";
import { usePublicClient, useWriteContract } from "wagmi";
import {
  BaseError,
  ContractFunctionRevertedError,
  UserRejectedRequestError,
} from "viem";

import { CHAIN_ID } from "./config";
import {
  attestationFor,
  fetchSignedAttestations,
  isRelayable,
  REFRESH_AT_AGE_SEC,
} from "./attestation";
import {
  CertVaultABI,
  CertificateABI,
  SHARED,
  SolvencyRegistryABI,
  TestFaucetABI,
  TestUSDGABI,
} from "./contracts";
import { scaleCollateralTo18, toCert, toCollateral } from "./units";
import { useVaultConfig, vaultAddresses, type ChainVaultId } from "./useVaults";

export type TxHash = `0x${string}`;

/* ───────────────────────────────────────────────────────────── revert decoding */

export type RevertKind =
  /** Not a failure at all — a state the UI should route on. */
  | "not-an-error"
  /** Failed now, will succeed later. Never terminal. */
  | "retryable"
  /** Normal "nothing to do" outcome for a permissionless keeper call. */
  | "no-op"
  /** The UI called the wrong function for the amount. Our bug, not the user's. */
  | "routing-bug"
  /** The UI called an operator-only function. Should be unreachable. */
  | "operator-only"
  /** Something the user can understand and act on. */
  | "user"
  /** The user dismissed the wallet prompt. */
  | "rejected"
  | "unknown";

export interface DecodedRevert {
  /** The custom error name from the ABI, e.g. `CertVault_UseQueuedRedeem`. */
  name: string | null;
  /** Decoded error arguments, where the error carries any. */
  args: readonly unknown[];
  /** A human sentence safe to show a user. */
  message: string;
  kind: RevertKind;
  /** The original error, for logging. Do not render this. */
  cause: unknown;
}

/**
 * Sentences for the errors a user can actually reach. The contracts use custom errors
 * only — there are no revert strings — and the generated module keeps every error in the
 * ABIs so viem can decode them.
 */
const REVERT_COPY: Record<string, { message: string; kind: RevertKind }> = {
  /* ---- not errors ------------------------------------------------------- */
  CertVault_UseQueuedRedeem: {
    message:
      "The instant buffer cannot cover this redemption right now, so the fast path declined. Your redemption will go through the queue instead.",
    kind: "not-an-error",
  },
  CertVault_AwaitingSettlement: {
    message:
      "Funds are still arriving from the venue. This is retryable and your receipt stays claimable — try again shortly, or call recallMargin to push it along.",
    kind: "retryable",
  },
  CertVault_RefundAwaitingSettlement: {
    message:
      "The refund is staged but the venue has not returned the margin yet. Retryable — try again shortly.",
    kind: "retryable",
  },

  /* ---- permissionless keeper no-ops ------------------------------------- */
  CertVault_InBand: {
    message: "Nothing to rebalance — the position is already inside its band.",
    kind: "no-op",
  },
  CertVault_AlreadyRebalancedThisBatch: {
    message: "Already rebalanced for this attested batch. Try again after the next batch.",
    kind: "no-op",
  },
  CloseAllSkippedFlat: { message: "Nothing to close — the position is flat.", kind: "no-op" },

  /* ---- routing bugs (ours, not the user's) ------------------------------ */
  CertVault_AboveInstantCap: {
    message:
      "This amount is above the instant cap and should have been routed to a mint request. Please report this — it is an app routing bug.",
    kind: "routing-bug",
  },
  CertVault_BelowInstantCap: {
    message:
      "This amount is below the instant cap and should have been routed to the instant path. Please report this — it is an app routing bug.",
    kind: "routing-bug",
  },

  /* ---- states the user can act on -------------------------------------- */
  CertVault_AtCapacity: {
    message:
      "This vault is at its mint ceiling. The ceiling is capacityOracle.maxNotional18 — the smallest of venue depth (openInterest18 × depthBps), the governance absoluteCap18 and bufferCapacity18 — and it is zero outright when the attestation is stale, the attested open interest is zero, or the BufferBook accrual ledger has gone to zero or below. The vault page shows which of those is binding right now. Redemption is unaffected.",
    kind: "user",
  },
  CertVault_MintPaused: {
    message:
      "Minting is paused because the oracle is unhealthy. Redemption is unaffected and still works.",
    kind: "user",
  },
  CertVault_SettleWindowExpired: {
    message:
      "The settlement window has expired without a fill. You can recover your full escrow: stage the refund, then claim it.",
    kind: "user",
  },
  CertVault_RefundNotStaged: {
    message: "The refund has to be staged first. Staging is permissionless — you can do it yourself.",
    kind: "user",
  },
  CertVault_SettleWindowNotExpired: {
    message: "The settlement window has not expired yet, so this mint cannot be refunded.",
    kind: "user",
  },
  CertVault_ZeroAmount: {
    message: "That amount rounds to zero after fees and venue quantisation. Try a larger amount.",
    kind: "user",
  },
  CertVault_NothingToClaim: {
    message: "There is nothing to claim on this receipt — it has already been paid.",
    kind: "user",
  },
  CertVault_BadReceipt: { message: "That receipt does not belong to this vault.", kind: "user" },
  CertVault_NoPrice: {
    message: "The oracle has no usable price right now, so this action is unavailable.",
    kind: "user",
  },
  CertVault_NotBootstrapped: {
    message: "This vault has not been bootstrapped yet.",
    kind: "user",
  },
  CertVault_FillPriceOutOfBand: {
    message: "The venue fill price landed outside the allowed band, so the mint was not settled.",
    kind: "user",
  },
  TestFaucet_TooSoon: {
    message: "The faucet is still in its cooldown for this address.",
    kind: "user",
  },
  TestFaucet_Empty: {
    message:
      "The faucet is out of test collateral and needs topping up. This is a faucet problem, not a minting problem.",
    kind: "user",
  },
  CertOracle_StalePrice: {
    message: "The price feed is stale, so the oracle is refusing to answer.",
    kind: "user",
  },
  CertOracle_NonPositivePrice: {
    message: "The price feed returned a non-positive price, so the oracle is refusing to answer.",
    kind: "user",
  },
  CertOracle_NoIndependentBasis: {
    message:
      "There is no independent basis to compute — the feed and the venue mark are the same source. That is not the same as a basis of zero.",
    kind: "user",
  },
  ERC20InsufficientAllowance: {
    message: "Approve the vault to spend your collateral first.",
    kind: "user",
  },
  ERC20InsufficientBalance: { message: "Insufficient balance for this amount.", kind: "user" },
  SafeERC20FailedOperation: { message: "The token transfer failed.", kind: "user" },

  /* ---- should be unreachable from a UI ---------------------------------- */
  CertVault_OnlyGovernance: {
    message: "That is a governance-only action and cannot be called from a wallet.",
    kind: "operator-only",
  },
  CertVault_OnlyAttester: {
    message: "That is an attester-only action and cannot be called from a wallet.",
    kind: "operator-only",
  },
  CertOracle_OnlyAttester: {
    message: "That is an attester-only action and cannot be called from a wallet.",
    kind: "operator-only",
  },
  CertOracle_OnlyGovernance: {
    message: "That is a governance-only action and cannot be called from a wallet.",
    kind: "operator-only",
  },
};

function revertedError(err: unknown): ContractFunctionRevertedError | null {
  if (err instanceof ContractFunctionRevertedError) return err;
  if (err instanceof BaseError) {
    const found = err.walk((e) => e instanceof ContractFunctionRevertedError);
    if (found instanceof ContractFunctionRevertedError) return found;
  }
  return null;
}

function isRejection(err: unknown): boolean {
  if (err instanceof UserRejectedRequestError) return true;
  if (err instanceof BaseError) {
    return Boolean(err.walk((e) => e instanceof UserRejectedRequestError));
  }
  return false;
}

/** The custom error name a revert carries, or `null`. */
export function revertName(err: unknown): string | null {
  return revertedError(err)?.data?.errorName ?? null;
}

/**
 * Turn any thrown value into a human sentence plus a machine-readable classification,
 * using the custom errors already present in the generated ABIs.
 */
export function decodeRevert(err: unknown): DecodedRevert {
  if (isRejection(err)) {
    return {
      name: "UserRejectedRequest",
      args: [],
      message: "You dismissed the wallet prompt. Nothing was submitted.",
      kind: "rejected",
      cause: err,
    };
  }

  const reverted = revertedError(err);
  const name = reverted?.data?.errorName ?? null;
  const args = (reverted?.data?.args ?? []) as readonly unknown[];

  if (name && REVERT_COPY[name]) {
    const entry = REVERT_COPY[name];
    return { name, args, message: withArgs(name, entry.message, args), kind: entry.kind, cause: err };
  }

  if (name) {
    return {
      name,
      args,
      message: `The contract rejected this action (${name}).`,
      kind: "unknown",
      cause: err,
    };
  }

  const shortMessage =
    err instanceof BaseError ? err.shortMessage : err instanceof Error ? err.message : String(err);
  return {
    name: null,
    args: [],
    message: shortMessage || "The transaction could not be completed.",
    kind: "unknown",
    cause: err,
  };
}

/** Enrich the two faucet errors, which carry useful arguments. */
function withArgs(name: string, message: string, args: readonly unknown[]): string {
  if (name === "TestFaucet_TooSoon" && typeof args[0] === "bigint") {
    const at = new Date(Number(args[0]) * 1000);
    return `${message} Next claim available at ${at.toISOString().replace("T", " ").slice(0, 19)} UTC.`;
  }
  return message;
}

/** `true` when the fast redeem path declined because the hot buffer is thin. Not an error. */
export function isUseQueuedRedeem(err: unknown): boolean {
  return revertName(err) === "CertVault_UseQueuedRedeem";
}

/** `true` when a claim is waiting on venue settlement. Retryable, never terminal. */
export function isAwaitingSettlement(err: unknown): boolean {
  const name = revertName(err);
  return name === "CertVault_AwaitingSettlement" || name === "CertVault_RefundAwaitingSettlement";
}

/* ──────────────────────────────────────────────────────────────── size routing */

export type SizeRoute = "instant" | "request";

/**
 * Which mint function to call.
 *
 * `amountIn` is SIX-decimal collateral; `instantCap18` is EIGHTEEN-decimal. Scaling is
 * mandatory — comparing them directly is off by 10**12.
 */
export function routeMint(amountIn6: bigint, instantCap18: bigint): SizeRoute {
  return scaleCollateralTo18(amountIn6) <= instantCap18 ? "instant" : "request";
}

/** Which redeem function to call. `certIn` is already 18-decimal, like the cap. */
export function routeRedeem(certIn18: bigint, instantCap18: bigint): SizeRoute {
  return certIn18 <= instantCap18 ? "instant" : "request";
}

/* ─────────────────────────────────────────────────────────────── result shapes */

export type MintResult =
  | { status: "instant"; hash: TxHash }
  | { status: "requested"; hash: TxHash };

export type RedeemResult =
  | { status: "instant"; hash: TxHash }
  /** Submitted through the queue. Two batch round-trips, then `claimRedeem`. */
  | { status: "queued"; hash: TxHash }
  /**
   * The fast path declined (`CertVault_UseQueuedRedeem`). NOT a failure. Call
   * `requestRedeem`, or use `redeemWithFallback` to have it done for you.
   */
  | { status: "needs-queued"; reason: DecodedRevert };

export type ClaimResult =
  | { status: "claimed"; hash: TxHash }
  /** Retryable and never terminal — the receipt stays claimable forever. */
  | { status: "awaiting-settlement"; retryable: true; reason: DecodedRevert };

/* ──────────────────────────────────────────────────────────────────── the hook */

export interface CertActions {
  /** `TestUSDG.approve(vault, amount)`. SIX decimals. Required before either mint path. */
  approve: (amountInput: string) => Promise<TxHash>;
  /** `certificate.approve(vault, amount)`. Eighteen decimals. */
  approveCertificate: (amountInput: string) => Promise<TxHash>;

  /** `vault.mintInstant(amountIn)` — 6 dp in, 18 dp certificates out. Below the cap only. */
  mintInstant: (amountInput: string) => Promise<TxHash>;
  /** `vault.requestMint(amountIn)` — escrow plus a receipt. Above the cap only. */
  requestMint: (amountInput: string) => Promise<TxHash>;
  /**
   * Reads `cfg().instantCap18` and picks the correct mint function before submitting.
   * Use this rather than the two above unless you have a reason not to.
   */
  mint: (amountInput: string) => Promise<MintResult>;

  /** `vault.redeemInstant(certIn)`. Returns `needs-queued` when the fast path declines. */
  redeemInstant: (certInput: string) => Promise<RedeemResult>;
  /** `vault.requestRedeem(certIn)` — burns now, pays by claim. */
  requestRedeem: (certInput: string) => Promise<TxHash>;
  /** Routes on size, and on a thin hot buffer reports `needs-queued` rather than failing. */
  redeem: (certInput: string) => Promise<RedeemResult>;
  /** As `redeem`, but on `needs-queued` submits `requestRedeem` itself. Two prompts. */
  redeemWithFallback: (certInput: string) => Promise<RedeemResult>;
  /**
   * `vault.forceExit(certIn)` — permissionless, any size, any state. Reads no health
   * signal. Never gate this in the UI.
   */
  forceExit: (certInput: string) => Promise<TxHash>;

  /** `vault.claimRedeem(receiptId)`. `awaiting-settlement` is retryable, never terminal. */
  claimRedeem: (receiptId: bigint) => Promise<ClaimResult>;

  /** `vault.stageRefund(receiptId)` — permissionless, arms an expired mint's refund. */
  stageRefund: (receiptId: bigint) => Promise<TxHash>;
  /** `vault.refundMint(receiptId)` — permissionless, returns the full escrow. */
  refundMint: (receiptId: bigint) => Promise<TxHash>;

  /** `vault.recallMargin()` — permissionless. Reaches freed margin in two calls, a batch apart. */
  recallMargin: () => Promise<TxHash>;
  /** `vault.rebalance()` — permissionless. `InBand` / `AlreadyRebalancedThisBatch` are no-ops. */
  rebalance: () => Promise<TxHash>;

  /** True while a wallet prompt or submission is in flight. */
  isPending: boolean;
  /** The last error, already decoded into a sentence. */
  error: DecodedRevert | null;
  reset: () => void;
  /** `instantCap18` from `cfg()`, or `undefined` until it loads. */
  instantCap18: bigint | undefined;
  /** The size fork cannot be evaluated until `cfg()` has loaded. */
  isRoutable: boolean;
}

export function useCertActions(id: ChainVaultId): CertActions {
  const mirror = useMemo(() => vaultAddresses(id), [id]);
  const cfg = useVaultConfig(id);
  const { mutateAsync, isPending, error, reset } = useWriteContract();
  const publicClient = usePublicClient({ chainId: CHAIN_ID });

  const approve = useCallback(
    async (amountInput: string): Promise<TxHash> =>
      mutateAsync({
        chainId: CHAIN_ID,
        address: SHARED.collateral,
        abi: TestUSDGABI,
        functionName: "approve",
        // SIX decimals. Using toCert here would over-approve by 10**12.
        args: [mirror.vault, toCollateral(amountInput)],
      }),
    [mutateAsync, mirror.vault],
  );

  const approveCertificate = useCallback(
    async (amountInput: string): Promise<TxHash> =>
      mutateAsync({
        chainId: CHAIN_ID,
        address: mirror.certificate,
        abi: CertificateABI,
        functionName: "approve",
        args: [mirror.vault, toCert(amountInput)],
      }),
    [mutateAsync, mirror.certificate, mirror.vault],
  );

  const mintInstant = useCallback(
    async (amountInput: string): Promise<TxHash> =>
      mutateAsync({
        chainId: CHAIN_ID,
        address: mirror.vault,
        abi: CertVaultABI,
        functionName: "mintInstant",
        args: [toCollateral(amountInput)],
      }),
    [mutateAsync, mirror.vault],
  );

  const requestMint = useCallback(
    async (amountInput: string): Promise<TxHash> =>
      mutateAsync({
        chainId: CHAIN_ID,
        address: mirror.vault,
        abi: CertVaultABI,
        functionName: "requestMint",
        args: [toCollateral(amountInput)],
      }),
    [mutateAsync, mirror.vault],
  );

  /**
   * Relay the attester's signature so this vault's attestation is fresh enough to
   * mint against. Returns the tx hash if a relay was needed, or null if it was not.
   *
   * Called by `mint` rather than exposed as a button: refreshing an attestation is
   * plumbing, not a user intention, and the only reason a user would ever click it
   * is to make the next action work.
   */
  const refreshAttestationIfStale = useCallback(async (): Promise<TxHash | null> => {
    if (!publicClient) return null;

    // Read the age first. Most mints need no relay at all - any other user's mint
    // in the last four minutes already paid for this one's freshness - and a
    // needless relay is a wallet prompt and a gas charge for nothing.
    const age = (await publicClient.readContract({
      address: SHARED.solvencyRegistry,
      abi: SolvencyRegistryABI,
      functionName: "ageSec",
      args: [mirror.vault],
    })) as bigint;
    if (age < BigInt(REFRESH_AT_AGE_SEC)) return null;

    const batch = await fetchSignedAttestations();
    const a = attestationFor(batch, mirror.vault);
    // No signature available: say nothing here and let the mint revert with the
    // contract's own `CertVault_AtCapacity`, which is the accurate reason. Inventing
    // a different error would describe a cause we have not established.
    if (!a || !isRelayable(a)) return null;

    return mutateAsync({
      chainId: CHAIN_ID,
      // PINNED, not taken from the payload. The signer tells us which registry it
      // signed for, and attestationFor() now refuses a payload that disagrees with
      // the bundled address - but the transaction itself is addressed from the
      // constant regardless. Whoever controls that endpoint should not be able to
      // aim a user's signed transaction at a contract of their choosing, even
      // though the calldata is fixed to a nonpayable attestSigned and no user holds
      // an allowance to the registry.
      address: SHARED.solvencyRegistry,
      abi: SolvencyRegistryABI,
      functionName: "attestSigned",
      args: [
        a.vault,
        BigInt(a.batchId),
        BigInt(a.notional18),
        BigInt(a.margin18),
        BigInt(a.openInterest18),
        BigInt(a.observedAt),
        BigInt(a.deadline),
        a.attestSig,
      ],
    });
  }, [mutateAsync, mirror.vault, publicClient]);

  const mint = useCallback(
    async (amountInput: string): Promise<MintResult> => {
      const cap = cfg?.instantCap18;
      if (cap === undefined) {
        // Refuse rather than guess: submitting the wrong path reverts at the wallet.
        throw new Error(
          "Cannot route this mint: vault.cfg() has not loaded, so instantCap18 is unknown.",
        );
      }
      // Refresh BEFORE routing, and WAIT for it: sending the mint while the relay
      // is still pending means the mint reads the old attestation and reverts
      // CertVault_AtCapacity, having charged the user for both.
      const relayHash = await refreshAttestationIfStale();
      if (relayHash && publicClient) {
        await publicClient.waitForTransactionReceipt({ hash: relayHash });
      }

      const amountIn6 = toCollateral(amountInput);
      if (routeMint(amountIn6, cap) === "instant") {
        return { status: "instant", hash: await mintInstant(amountInput) };
      }
      return { status: "requested", hash: await requestMint(amountInput) };
    },
    [cfg?.instantCap18, mintInstant, publicClient, refreshAttestationIfStale, requestMint],
  );

  const redeemInstant = useCallback(
    async (certInput: string): Promise<RedeemResult> => {
      try {
        const hash = await mutateAsync({
          chainId: CHAIN_ID,
          address: mirror.vault,
          abi: CertVaultABI,
          functionName: "redeemInstant",
          args: [toCert(certInput)],
        });
        return { status: "instant", hash };
      } catch (err) {
        // The fast path declining is a state, not a failure.
        if (isUseQueuedRedeem(err)) {
          return { status: "needs-queued", reason: decodeRevert(err) };
        }
        throw err;
      }
    },
    [mutateAsync, mirror.vault],
  );

  const requestRedeem = useCallback(
    async (certInput: string): Promise<TxHash> =>
      mutateAsync({
        chainId: CHAIN_ID,
        address: mirror.vault,
        abi: CertVaultABI,
        functionName: "requestRedeem",
        args: [toCert(certInput)],
      }),
    [mutateAsync, mirror.vault],
  );

  const redeem = useCallback(
    async (certInput: string): Promise<RedeemResult> => {
      const cap = cfg?.instantCap18;
      if (cap === undefined) {
        throw new Error(
          "Cannot route this redemption: vault.cfg() has not loaded, so instantCap18 is unknown.",
        );
      }
      if (routeRedeem(toCert(certInput), cap) === "instant") {
        return redeemInstant(certInput);
      }
      return { status: "queued", hash: await requestRedeem(certInput) };
    },
    [cfg?.instantCap18, redeemInstant, requestRedeem],
  );

  const redeemWithFallback = useCallback(
    async (certInput: string): Promise<RedeemResult> => {
      const first = await redeem(certInput);
      if (first.status !== "needs-queued") return first;
      return { status: "queued", hash: await requestRedeem(certInput) };
    },
    [redeem, requestRedeem],
  );

  const forceExit = useCallback(
    async (certInput: string): Promise<TxHash> =>
      // No precondition. Design Law 2: forceExit reads no health signal, so the UI adds none.
      mutateAsync({
        chainId: CHAIN_ID,
        address: mirror.vault,
        abi: CertVaultABI,
        functionName: "forceExit",
        args: [toCert(certInput)],
      }),
    [mutateAsync, mirror.vault],
  );

  const claimRedeem = useCallback(
    async (receiptId: bigint): Promise<ClaimResult> => {
      try {
        const hash = await mutateAsync({
          chainId: CHAIN_ID,
          address: mirror.vault,
          abi: CertVaultABI,
          functionName: "claimRedeem",
          args: [receiptId],
        });
        return { status: "claimed", hash };
      } catch (err) {
        // Retryable, never terminal. Do not mark the receipt failed.
        if (isAwaitingSettlement(err)) {
          return { status: "awaiting-settlement", retryable: true, reason: decodeRevert(err) };
        }
        throw err;
      }
    },
    [mutateAsync, mirror.vault],
  );

  const stageRefund = useCallback(
    async (receiptId: bigint): Promise<TxHash> =>
      mutateAsync({
        chainId: CHAIN_ID,
        address: mirror.vault,
        abi: CertVaultABI,
        functionName: "stageRefund",
        args: [receiptId],
      }),
    [mutateAsync, mirror.vault],
  );

  const refundMint = useCallback(
    async (receiptId: bigint): Promise<TxHash> =>
      mutateAsync({
        chainId: CHAIN_ID,
        address: mirror.vault,
        abi: CertVaultABI,
        functionName: "refundMint",
        args: [receiptId],
      }),
    [mutateAsync, mirror.vault],
  );

  const recallMargin = useCallback(
    async (): Promise<TxHash> =>
      mutateAsync({
        chainId: CHAIN_ID,
        address: mirror.vault,
        abi: CertVaultABI,
        functionName: "recallMargin",
        args: [],
      }),
    [mutateAsync, mirror.vault],
  );

  const rebalance = useCallback(
    async (): Promise<TxHash> =>
      mutateAsync({
        chainId: CHAIN_ID,
        address: mirror.vault,
        abi: CertVaultABI,
        functionName: "rebalance",
        args: [],
      }),
    [mutateAsync, mirror.vault],
  );

  return {
    approve,
    approveCertificate,
    mintInstant,
    requestMint,
    mint,
    redeemInstant,
    requestRedeem,
    redeem,
    redeemWithFallback,
    forceExit,
    claimRedeem,
    stageRefund,
    refundMint,
    recallMargin,
    rebalance,
    isPending,
    error: error ? decodeRevert(error) : null,
    reset,
    instantCap18: cfg?.instantCap18,
    isRoutable: cfg?.instantCap18 !== undefined,
  };
}

/* ───────────────────────────────────────────────────────────────────── faucet */

export interface FaucetActions {
  /**
   * `TestFaucet.claim()`. `TestUSDG.mint` is owner-gated to the deployer, so this is the
   * ONLY way a tester obtains collateral — wire it prominently. 10 000 tUSDG per claim,
   * 86 400 s cooldown per address.
   */
  claim: () => Promise<TxHash>;
  isPending: boolean;
  error: DecodedRevert | null;
  reset: () => void;
}

export function useFaucetActions(): FaucetActions {
  const { mutateAsync, isPending, error, reset } = useWriteContract();

  const claim = useCallback(
    async (): Promise<TxHash> =>
      mutateAsync({
        chainId: CHAIN_ID,
        address: SHARED.testFaucet,
        abi: TestFaucetABI,
        functionName: "claim",
        args: [],
      }),
    [mutateAsync],
  );

  return { claim, isPending, error: error ? decodeRevert(error) : null, reset };
}
