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
  decodeEventLog,
} from "viem";

import { CHAIN_ID } from "./config";
import { CHAIN_LABEL, FAUCET_ADDRESS, IS_STACK5 } from "./deployment";
import {
  attestationFor,
  fetchSignedAttestations,
  isMarkRelayable,
  isRelayable,
  markV2Of,
  REFRESH_AT_AGE_SEC,
} from "./attestation";
import {
  Stack4MarkRelayABI,
  Stack5CertOracleABI,
  Stack5CertVaultABI,
  Stack5SolvencyRegistryABI,
} from "./contracts.stack5";
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

/**
 * The ABI every vault WRITE is sent with. Stack 5's where stack 5 is deployed: same functions and
 * arguments, but it carries the new custom errors (CertVault_InstantPriceTooOld,
 * CertVault_AwaitingFreshPrice, CertVault_OwnerGracePeriod, ...), and viem can only name a revert
 * that is in the ABI it was sent with. On stack 4 this is contracts.ts's ABI, exactly as before.
 */
const VAULT_WRITE_ABI = IS_STACK5 ? Stack5CertVaultABI : CertVaultABI;

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
  /* The relay races. All four mean the same thing to a user - somebody else's transaction
   * landed first, or the signature aged out before this one was mined - and none of them
   * mean anything is broken. `mint` handles these itself and does not surface them; they are
   * here so that one reaching a user any other way still reads like what it is. "no-op"
   * rather than "error" for the two stale cases, because the work was done, just not by
   * this transaction. */
  SolvencyRegistry_StaleBatch: {
    message:
      "Another transaction refreshed this vault's attestation first. Nothing was lost — the " +
      "backing is fresh, which is what your mint needed.",
    kind: "no-op",
  },
  SolvencyRegistry_ObservationWentBackwards: {
    message:
      "A newer attestation is already on chain, so this older one was refused. The backing " +
      "is fresh.",
    kind: "no-op",
  },
  CertOracle_StaleNonce: {
    message:
      "Another transaction set this mark price first. Nothing was lost — the oracle already " +
      "has the value this one carried.",
    kind: "no-op",
  },
  SolvencyRegistry_SignatureExpired: {
    message:
      "The attester's signature expired before this transaction was mined. A new one is " +
      "published every 30 seconds — try again.",
    kind: "retryable",
  },
  CertOracle_SignatureExpired: {
    message:
      "The attester's mark signature expired before this transaction was mined. A new one is " +
      "published every 30 seconds — try again.",
    kind: "retryable",
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

  /* ---- stack 5: vault ---------------------------------------------------- */
  /* Routing, not failure: the price is older than an hour (every weekend, when the stock feeds
   * stop), so the instant path refuses it and the queue - always open - is the way out. */
  CertVault_InstantPriceTooOld: {
    message:
      "The price is more than an hour old, which happens every weekend when the stock feeds stop, so instant redemption is closed. Your redemption can go through the queue instead: requestRedeem is always open, and so is force exit.",
    kind: "not-an-error",
  },
  CertVault_AwaitingFreshPrice: {
    message:
      "Waiting for a fresh price: no price has been observed since this redemption was requested. Retryable and never permanent. The claim pays as soon as a new price arrives, or in full once 4 days have passed since the request.",
    kind: "retryable",
  },
  CertVault_OwnerGracePeriod: {
    message:
      "The price cap would lower this payout, so for the first day after the request only the receipt's owner can claim it. The owner can claim now; anyone can after that day.",
    kind: "user",
  },
  CertVault_RebalanceTooSoon: {
    message: "The vault was rebalanced a moment ago. Nothing to do yet — try again later.",
    kind: "no-op",
  },
  CertVault_RebalanceBudgetSpent: {
    message: "The vault has used its rebalancing budget for the last 24 hours. Nothing to do until it refills.",
    kind: "no-op",
  },
  CertVault_AttestationPredatesLastOrder: {
    message:
      "The latest attestation predates the vault's last order, so a rebalance would act on old figures. Try again after the next attestation.",
    kind: "no-op",
  },

  /* ---- stack 5: relays -------------------------------------------------- */
  CertOracle_ObservationWentBackwards: {
    message:
      "A newer mark price is already on chain, so this older one was refused. Nothing was lost — the oracle already has a fresher mark.",
    kind: "no-op",
  },
  CertOracle_ObservationInFuture: {
    message:
      "The mark price signature is timestamped ahead of the chain's clock, so the oracle refused it. Try again in a few seconds.",
    kind: "retryable",
  },
  CertOracle_AttesterDisabled: {
    message:
      "The mark price attester has been switched off by governance, so no signed mark can be relayed and minting is closed. Redemption is unaffected and still works.",
    kind: "user",
  },
  SolvencyRegistry_BatchGap: {
    message:
      "The attestation's batch number does not follow the one on chain, so it was refused. A new batch is signed every few seconds — try again.",
    kind: "retryable",
  },
  SolvencyRegistry_ObservationNotAdvanced: {
    message:
      "An attestation at least as new is already on chain, so this one was refused. The backing is fresh.",
    kind: "no-op",
  },
  SolvencyRegistry_AttesterDisabled: {
    message:
      "The solvency attester has been switched off by governance, so no attestation can be relayed and minting is closed. Redemption is unaffected and still works.",
    kind: "user",
  },

  /* ---- stack 5: insurance pool (InsuranceStaking v2) --------------------- */
  InsuranceStaking_AboveDepositCap: {
    message:
      "This deposit would take the pool's principal above its cap. Deposit at most the room shown under the cap.",
    kind: "user",
  },
  InsuranceStaking_DrawPending: {
    message:
      "A draw is pending, so deposits and withdrawals are paused until it is executed, cancelled or expires.",
    kind: "user",
  },
  InsuranceStaking_CooldownNotReady: {
    message: "Your withdrawal is still in its cooldown. It can be completed once the window opens.",
    kind: "user",
  },
  InsuranceStaking_WithdrawWindowClosed: {
    message:
      "Your withdrawal window has closed. Cancel the request to get the shares back in your wallet, or request again to restart the cooldown.",
    kind: "user",
  },
  InsuranceStaking_ExceedsCooldownShares: {
    message: "That is more than the shares in your withdrawal request.",
    kind: "user",
  },
  InsuranceStaking_ExceedsBalance: {
    message: "That is more shares than you hold.",
    kind: "user",
  },
  InsuranceStaking_ZeroAmount: { message: "Enter an amount above zero.", kind: "user" },
  InsuranceStaking_EscrowedShares: {
    message:
      "Shares in a withdrawal request are held in escrow and cannot be transferred. Cancel the request to get them back.",
    kind: "user",
  },
  ERC4626ExceededMaxDeposit: {
    message: "This deposit is above what the pool accepts right now (its cap, or a pending draw).",
    kind: "user",
  },
  ERC4626ExceededMaxRedeem: {
    message: "Only the shares in an open withdrawal window can be withdrawn.",
    kind: "user",
  },

  /* ---- stack 5: CERT staking (CertStaking v2) ---------------------------- */
  CertStaking_BelowMinNotify: {
    message: "This funding is below the pool's minimum. Send at least the minimum shown.",
    kind: "user",
  },
  CertStaking_AboveStakeCap: {
    message: "This stake would take the pool above its cap. Stake at most the room shown.",
    kind: "user",
  },
  CertStaking_InsufficientStake: { message: "That is more CERT than you have staked.", kind: "user" },
  CertStaking_ZeroAmount: { message: "Enter an amount above zero.", kind: "user" },

  /* ---- should be unreachable from a UI ---------------------------------- */
  CertVault_OnlySettler: {
    message: "That is a settler-only action and cannot be called from a wallet.",
    kind: "operator-only",
  },
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
  | {
      status: "claimed";
      hash: TxHash;
      /** STACK 5: collateral this claim paid (6 dp), from its own `RedeemClaimed` event. */
      paid?: bigint | null;
      /**
       * STACK 5: still due after this claim (6 dp), from `RedeemClaimOutstanding`. Above zero means
       * the claim was an instalment: the receipt stays open and can be claimed again.
       */
      outstanding?: bigint | null;
    }
  /** Retryable and never terminal — the receipt stays claimable forever. */
  | { status: "awaiting-settlement"; retryable: true; reason: DecodedRevert }
  /**
   * STACK 5: `CertVault_AwaitingFreshPrice`. No price observed since the request yet. Retryable,
   * and bounded: from `paysInFullAt` (unix seconds, request + 4 days) the claim pays in full.
   */
  | { status: "awaiting-price"; retryable: true; reason: DecodedRevert; paysInFullAt: number | null };

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

  /**
   * Send, then WAIT for the receipt, and throw if it reverted. A hash is not a completed action:
   * the panel used to toast "Minted" / "Redeemed" / "Receipt claimed" the moment the wallet
   * returned one (external checkup, 2026-09-26). Every user-facing write goes through here, so
   * success is only ever reported for a transaction the chain confirmed.
   */
  const confirmed = useCallback(
    async (request: Parameters<typeof mutateAsync>[0]): Promise<TxHash> => {
      const hash = await mutateAsync(request);
      if (!publicClient) return hash;
      const rc = await publicClient.waitForTransactionReceipt({ hash });
      if (rc.status !== "success") {
        throw new Error(`The transaction was mined but reverted on chain (${hash}). Nothing changed.`);
      }
      return hash;
    },
    [mutateAsync, publicClient],
  );

  const approve = useCallback(
    async (amountInput: string): Promise<TxHash> =>
      confirmed({
        chainId: CHAIN_ID,
        address: SHARED.collateral,
        abi: TestUSDGABI,
        functionName: "approve",
        // SIX decimals. Using toCert here would over-approve by 10**12.
        args: [mirror.vault, toCollateral(amountInput)],
      }),
    [confirmed, mutateAsync, mirror.vault],
  );

  const approveCertificate = useCallback(
    async (amountInput: string): Promise<TxHash> =>
      confirmed({
        chainId: CHAIN_ID,
        address: mirror.certificate,
        abi: CertificateABI,
        functionName: "approve",
        args: [mirror.vault, toCert(amountInput)],
      }),
    [confirmed, mutateAsync, mirror.certificate, mirror.vault],
  );

  const mintInstant = useCallback(
    async (amountInput: string): Promise<TxHash> =>
      confirmed({
        chainId: CHAIN_ID,
        address: mirror.vault,
        abi: VAULT_WRITE_ABI,
        functionName: "mintInstant",
        args: [toCollateral(amountInput)],
      }),
    [confirmed, mutateAsync, mirror.vault],
  );

  const requestMint = useCallback(
    async (amountInput: string): Promise<TxHash> =>
      confirmed({
        chainId: CHAIN_ID,
        address: mirror.vault,
        abi: VAULT_WRITE_ABI,
        functionName: "requestMint",
        args: [toCollateral(amountInput)],
      }),
    [confirmed, mutateAsync, mirror.vault],
  );

  /**
   * Relay the attester's signed bundle so this vault can be minted against, and WAIT
   * for it. Returns the hashes it sent; a null half means that half needed no relay.
   *
   * BOTH HALVES OF THE BUNDLE, NOT ONE. The signer produces two signatures per vault
   * from a single observation - `attestSig` for `SolvencyRegistry.attestSigned` and
   * `markSig` for `CertOracle.setMarkPriceSigned` - and this function used to relay only
   * the first. The corrective re-audit of 2026-09-25 named that omission, and it is real:
   * the registry relay reopens capacity, but the oracle keeps the mark price it was last
   * given. With a feed that moves, the basis cross-check is then run against a stale
   * mark, and `mintAllowed()` can close on a divergence that does not exist. Refreshing
   * half a bundle buys freshness for the number the audit reads and not for the number
   * the mint gate uses.
   *
   * Called by `mint` rather than exposed as a button: refreshing is plumbing, not a user
   * intention, and the only reason anyone would click it is to make the next action work.
   */
  /**
   * Make this vault's backing fresh enough to mint against, and say what happened.
   *
   * BOTH HALVES OF THE BUNDLE. The signer produces two signatures per vault from a single
   * observation - `attestSig` for `SolvencyRegistry.attestSigned` and `markSig` for
   * `CertOracle.setMarkPriceSigned` - and this relayed only the first until 2026-09-25. The
   * registry relay reopens capacity; the oracle keeps the mark price it was last given, so
   * the basis cross-check runs against a stale mark and `mintAllowed()` can close on a
   * divergence that does not exist.
   *
   * WHY IT WATCHES RECEIPTS. `waitForTransactionReceipt` does not throw on a reverted
   * transaction - it returns a receipt whose `status` is `"reverted"`. So a relay that lost a
   * race used to be indistinguishable from one that worked, and the mint went out behind it
   * and reverted too: the user paid for both. Every send here is judged on its receipt.
   *
   * WHY LOSING A RACE IS NOT AN ERROR. Two people minting off one bundle is the ordinary
   * case. The second relay reverts `SolvencyRegistry_StaleBatch` or `CertOracle_StaleNonce`,
   * which means the first one landed - exactly what this mint wanted. So a failed relay asks
   * THE CHAIN whether it is fresh rather than parsing the revert: state is ground truth, the
   * error name is a report about it, and a receipt does not carry the reason anyway.
   *
   * AT MOST TWO ATTEMPTS, EVER. A retry loop here is a loop of wallet prompts, and a bundle
   * that cannot be relayed twice will not be relayed on the ninth try either.
   */
  const refreshAttestationIfStale = useCallback(async (): Promise<RefreshOutcome> => {
    if (!publicClient) return { status: "unavailable", reason: "no-bundle" };

    const registryIsFresh = async (): Promise<boolean> => {
      const age = (await publicClient.readContract({
        address: SHARED.solvencyRegistry,
        abi: SolvencyRegistryABI,
        functionName: "ageSec",
        args: [mirror.vault],
      })) as bigint;
      return age < BigInt(REFRESH_AT_AGE_SEC);
    };

    // Read the age first. Most mints need no relay at all - any other user's mint in the last
    // four minutes already paid for this one's freshness - and a needless relay is a wallet
    // prompt and a gas charge for nothing. (Stack 5 asks about the mark too; see below.)
    if (!IS_STACK5 && (await registryIsFresh())) return { status: "not-needed" };

    /**
     * Send one transaction and report whether the CHAIN accepted it.
     *
     * A dismissed wallet prompt is rethrown rather than reported as a failure: it is the one
     * outcome that must not be retried, because retrying it means prompting again.
     */
    const send = async (
      request: Parameters<typeof mutateAsync>[0],
    ): Promise<{ ok: boolean; hash: TxHash | null }> => {
      let hash: TxHash;
      try {
        hash = await mutateAsync(request);
      } catch (err) {
        if (isRejection(err)) throw err;
        // A failed gas estimate lands here, which is how a doomed relay usually presents:
        // the wallet simulates, the call reverts, and nothing is ever submitted.
        return { ok: false, hash: null };
      }
      const receipt = await publicClient.waitForTransactionReceipt({ hash });
      return { ok: receipt.status === "success", hash };
    };

    /* ------------------------------------------------------------------- stack 5 */

    if (IS_STACK5) {
      /**
       * STACK 5: the MARK must be fresh too, not only the registry.
       *
       * `CertOracle.mintAllowed()` is false once `block.timestamp - markAt > maxMarkAge`, and
       * `markAt` is the signed `observedAt`, never the relay's block time. So an idle protocol
       * wakes up with a stale mark as well as a stale attestation, and a mint that refreshes only
       * the registry reverts `CertVault_MintPaused`. Both halves are judged on chain state, aged
       * against the CHAIN's clock (`markAt` is chain-comparable; the reader's clock is not).
       */
      const readMark = async (): Promise<MarkState> => {
        const [markAt, maxMarkAge, nonce, block] = await Promise.all([
          publicClient.readContract({ address: mirror.certOracle, abi: Stack5CertOracleABI, functionName: "markAt" }),
          publicClient.readContract({ address: mirror.certOracle, abi: Stack5CertOracleABI, functionName: "maxMarkAge" }),
          publicClient.readContract({ address: mirror.certOracle, abi: Stack5CertOracleABI, functionName: "markNonce" }),
          publicClient.getBlock({ blockTag: "latest" }),
        ]);
        return { markAt: markAt as bigint, maxMarkAge: maxMarkAge as bigint, nonce: nonce as bigint, now: block.timestamp };
      };

      const attempt5 = async (): Promise<RefreshOutcome> => {
        const batch = await fetchSignedAttestations();
        const a = attestationFor(batch, mirror.vault);
        if (!a) return { status: "unavailable", reason: "no-bundle" };
        const [regFresh, mark] = await Promise.all([registryIsFresh(), readMark()]);
        const markOk = markIsFresh5(mark);
        if (regFresh && markOk) return { status: "already-fresh" };

        // The v2 mark the signer served, relayed only if it is NEWER than the oracle's own: a later
        // observation and a later nonce, or the oracle refuses it (ObservationWentBackwards /
        // StaleNonce) and the wallet prompt was for nothing. And only if it is young enough that
        // relaying it leaves time to send the mint behind it.
        const m = markV2Of(a);
        const markNewer = m !== null && m.observedAt > mark.markAt && m.nonce > mark.nonce;
        const markUseful = m !== null && m.observedAt + mark.maxMarkAge >= mark.now + markMargin5(mark.maxMarkAge);
        if (!markOk && (!markNewer || !markUseful)) return { status: "unavailable", reason: "no-mark" };
        const relayMark = m !== null && markNewer && markUseful && isMarkRelayable(m);
        if (!markOk && !relayMark) return { status: "unavailable", reason: "expiring" };
        if (!regFresh && !isRelayable(a)) return { status: "unavailable", reason: "expiring" };

        let markHash: TxHash | null = null;
        let sentOk = false;
        if (relayMark && m !== null) {
          const sent = await send({
            chainId: CHAIN_ID,
            // PINNED to the bundled mirror, never taken from the payload.
            address: mirror.certOracle,
            abi: Stack5CertOracleABI,
            functionName: "setMarkPriceSigned",
            args: [m.px18, m.nonce, m.observedAt, m.deadline, m.signature],
          });
          markHash = sent.hash;
          sentOk = sent.ok;
          // A racing relayer landing first (StaleNonce, ObservationWentBackwards) is a success if
          // the chain is now fresh. Asked of the chain, not of the error.
          if (!sent.ok && !markOk && !markIsFresh5(await readMark())) {
            return { status: "unavailable", reason: "race-lost" };
          }
        }

        let attestationHash: TxHash | null = null;
        if (!regFresh) {
          const sent = await send({
            chainId: CHAIN_ID,
            address: SHARED.solvencyRegistry,
            abi: Stack5SolvencyRegistryABI,
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
          attestationHash = sent.hash;
          sentOk = sentOk || sent.ok;
          if (!sent.ok && !(await registryIsFresh())) return { status: "unavailable", reason: "race-lost" };
        }

        // Ground truth for both halves before the mint is allowed to go out behind them.
        const [regNow, markNow] = await Promise.all([registryIsFresh(), readMark()]);
        if (!regNow || !markIsFresh5(markNow)) return { status: "unavailable", reason: "race-lost" };
        return sentOk
          ? { status: "refreshed", hashes: { mark: markHash, attestation: attestationHash } }
          : { status: "already-fresh" };
      };

      const [reg0, mark0] = await Promise.all([registryIsFresh(), readMark()]);
      if (reg0 && markIsFresh5(mark0)) return { status: "not-needed" };
      const first5 = await attempt5();
      if (first5.status !== "unavailable" || first5.reason === "no-bundle" || first5.reason === "no-mark") {
        return first5;
      }
      // ONE retry on a newly fetched bundle, exactly as stack 4 does.
      const [reg1, mark1] = await Promise.all([registryIsFresh(), readMark()]);
      if (reg1 && markIsFresh5(mark1)) return { status: "already-fresh" };
      return attempt5();
    }

    /* ------------------------------------------------------------------- stack 4 */

    /** One full attempt on a freshly fetched bundle. */
    const attempt = async (): Promise<RefreshOutcome> => {
      const batch = await fetchSignedAttestations();
      const a = attestationFor(batch, mirror.vault);
      if (!a) return { status: "unavailable", reason: "no-bundle" };
      // Enough life for the mark relay, the registry relay AND the mint behind them.
      if (!isRelayable(a)) return { status: "unavailable", reason: "expiring" };

      /* ------------------------------------------------------------- the mark half */

      // Skipped when the oracle already holds this nonce or newer: `CertOracle_StaleNonce`
      // would refuse it, and a wallet prompt for a transaction that cannot succeed is worse
      // than no prompt at all.
      let mark: TxHash | null = null;
      const onChainNonce = (await publicClient.readContract({
        address: mirror.certOracle,
        abi: Stack4MarkRelayABI,
        functionName: "markNonce",
      })) as bigint;

      if (BigInt(a.markNonce) > onChainNonce) {
        const sent = await send({
          chainId: CHAIN_ID,
          // PINNED to the bundled mirror, exactly as the registry is below.
          address: mirror.certOracle,
          abi: Stack4MarkRelayABI,
          functionName: "setMarkPriceSigned",
          args: [BigInt(a.markPx18), BigInt(a.markNonce), BigInt(a.deadline), a.markSig],
        });
        // A lost mark race is not fatal on its own - the winner set the same price from the
        // same attester - so the registry half still goes out. What must not happen is
        // treating the revert as success and never checking.
        mark = sent.hash;
      }

      /* --------------------------------------------------------- the registry half */

      const sent = await send({
        chainId: CHAIN_ID,
        // PINNED, not taken from the payload. The signer tells us which registry it signed
        // for, and attestationFor() refuses a payload that disagrees with the bundled
        // address - but the transaction itself is addressed from the constant regardless.
        // Whoever controls that endpoint should not be able to aim a user's signed
        // transaction at a contract of their choosing.
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

      if (sent.ok) return { status: "refreshed", hashes: { mark, attestation: sent.hash } };

      // The relay did not land. Ask the chain, not the error: if someone else refreshed it
      // while this was in flight, the mint can go ahead exactly as if we had won.
      if (await registryIsFresh()) return { status: "already-fresh" };
      return { status: "unavailable", reason: "race-lost" };
    };

    const first = await attempt();
    if (first.status !== "unavailable" || first.reason === "no-bundle") return first;

    // ONE retry, on a newly fetched bundle. `no-bundle` is excluded on purpose: the signer
    // just said it has nothing for this vault, and asking the same question 200ms later is
    // not a strategy.
    if (await registryIsFresh()) return { status: "already-fresh" };
    return attempt();
  }, [mutateAsync, mirror.vault, mirror.certOracle, publicClient]);

  const mint = useCallback(
    async (amountInput: string): Promise<MintResult> => {
      const cap = cfg?.instantCap18;
      if (cap === undefined) {
        // Refuse rather than guess: submitting the wrong path reverts at the wallet.
        throw new Error(
          "Cannot route this mint: vault.cfg() has not loaded, so instantCap18 is unknown.",
        );
      }
      // Refresh BEFORE routing. Both relays are confirmed inside this call: sending the
      // mint while either is pending means the mint reads the old state and reverts
      // CertVault_AtCapacity, having charged the user for every transaction in the chain.
      //
      // And REFUSE TO SEND when the refresh could not be made to work. This used to proceed
      // regardless, so a failed relay was followed by a mint that could only revert - the
      // user paid twice to be told no. A mint that cannot succeed is not submitted, and the
      // reason given is the one that actually applies.
      const refresh = await refreshAttestationIfStale();
      if (refresh.status === "unavailable") {
        throw new Error(REFRESH_FAILURE_COPY[refresh.reason]);
      }
      // STACK 5: the form lets a mint through while the ONLY thing closing `mintAllowed()` is a
      // stale mark, because this call refreshes it. So ask the oracle again now that the mark is
      // fresh, and do not send a mint it would refuse (the feed may be stale, or out of band).
      if (IS_STACK5 && publicClient) {
        const allowed = (await publicClient.readContract({
          address: mirror.certOracle,
          abi: Stack5CertOracleABI,
          functionName: "mintAllowed",
        })) as boolean;
        if (!allowed) throw new Error(MINT_STILL_CLOSED_COPY);
      }

      const amountIn6 = toCollateral(amountInput);
      // A keeper-mode vault cannot hedge an instant mint (see VaultConfigView.keeperHedging):
      // every size goes through the receipt, and the certificates arrive when the keeper settles.
      if (!cfg?.keeperHedging && routeMint(amountIn6, cap) === "instant") {
        return { status: "instant", hash: await mintInstant(amountInput) };
      }
      return { status: "requested", hash: await requestMint(amountInput) };
    },
    [cfg?.instantCap18, cfg?.keeperHedging, mintInstant, mirror.certOracle, publicClient, refreshAttestationIfStale, requestMint],
  );

  /**
   * STACK 5: would `redeemInstant` refuse the current price as older than an hour?
   * Uses the same inputs as the contract - `pxUnguarded()`'s observation time, the vault's own
   * `INSTANT_MAX_PRICE_AGE` and the chain's clock. A failed read answers false and leaves the
   * decision to the contract, whose refusal is also routed to the queue (see redeemInstant).
   */
  const instantPriceTooOld5 = useCallback(async (): Promise<boolean> => {
    if (!IS_STACK5 || !publicClient) return false;
    try {
      const [px, maxAge, block] = await Promise.all([
        publicClient.readContract({ address: mirror.certOracle, abi: Stack5CertOracleABI, functionName: "pxUnguarded" }),
        publicClient.readContract({ address: mirror.vault, abi: Stack5CertVaultABI, functionName: "INSTANT_MAX_PRICE_AGE" }),
        publicClient.getBlock({ blockTag: "latest" }),
      ]);
      const observedAt = (px as readonly [bigint, bigint])[1];
      return observedAt + (maxAge as bigint) < block.timestamp;
    } catch {
      return false;
    }
  }, [mirror.certOracle, mirror.vault, publicClient]);

  const redeemInstant = useCallback(
    async (certInput: string): Promise<RedeemResult> => {
      try {
        const hash = await confirmed({
          chainId: CHAIN_ID,
          address: mirror.vault,
          abi: VAULT_WRITE_ABI,
          functionName: "redeemInstant",
          args: [toCert(certInput)],
        });
        return { status: "instant", hash };
      } catch (err) {
        // The fast path declining is a state, not a failure. Stack 5 adds a second way to
        // decline: a price older than an hour (a price-age check lost to the clock).
        if (isUseQueuedRedeem(err) || (IS_STACK5 && revertName(err) === "CertVault_InstantPriceTooOld")) {
          return { status: "needs-queued", reason: decodeRevert(err) };
        }
        throw err;
      }
    },
    [confirmed, mutateAsync, mirror.vault],
  );

  const requestRedeem = useCallback(
    async (certInput: string): Promise<TxHash> =>
      confirmed({
        chainId: CHAIN_ID,
        address: mirror.vault,
        abi: VAULT_WRITE_ABI,
        functionName: "requestRedeem",
        args: [toCert(certInput)],
      }),
    [confirmed, mutateAsync, mirror.vault],
  );

  const redeem = useCallback(
    async (certInput: string): Promise<RedeemResult> => {
      const cap = cfg?.instantCap18;
      if (cap === undefined) {
        throw new Error(
          "Cannot route this redemption: vault.cfg() has not loaded, so instantCap18 is unknown.",
        );
      }
      // Keeper mode posts nearly all of a mint's escrow to the venue, so the vault's own float
      // cannot pay an instant exit; the queue closes the hedge on chain and pays by claim.
      if (!cfg?.keeperHedging && routeRedeem(toCert(certInput), cap) === "instant") {
        // STACK 5: redeemInstant refuses a price older than INSTANT_MAX_PRICE_AGE (every
        // weekend). Checked here, before the wallet, so the holder is offered the queue instead
        // of a prompt for a transaction that can only revert.
        if (IS_STACK5 && (await instantPriceTooOld5())) {
          return { status: "needs-queued", reason: instantPriceTooOldReason() };
        }
        return redeemInstant(certInput);
      }
      return { status: "queued", hash: await requestRedeem(certInput) };
    },
    [cfg?.instantCap18, cfg?.keeperHedging, instantPriceTooOld5, redeemInstant, requestRedeem],
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
      confirmed({
        chainId: CHAIN_ID,
        address: mirror.vault,
        abi: VAULT_WRITE_ABI,
        functionName: "forceExit",
        args: [toCert(certInput)],
      }),
    [confirmed, mutateAsync, mirror.vault],
  );

  const claimRedeem = useCallback(
    async (receiptId: bigint): Promise<ClaimResult> => {
      try {
        const hash = await confirmed({
          chainId: CHAIN_ID,
          address: mirror.vault,
          // Stack 5's ABI where stack 5 is deployed, so its new refusals decode by name.
          abi: VAULT_WRITE_ABI,
          functionName: "claimRedeem",
          args: [receiptId],
        });
        if (!IS_STACK5 || !publicClient) return { status: "claimed", hash };
        // STACK 5: a claim pays min(due, what the vault holds), so it may be an instalment. What
        // it paid and what is still due are in THIS transaction's own events.
        let paid: bigint | null = null;
        let outstanding: bigint | null = 0n;
        try {
          const rc = await publicClient.getTransactionReceipt({ hash });
          for (const log of rc.logs) {
            if (log.address.toLowerCase() !== mirror.vault.toLowerCase()) continue;
            try {
              const ev = decodeEventLog({ abi: Stack5CertVaultABI, data: log.data, topics: log.topics });
              if (ev.eventName === "RedeemClaimed") paid = (ev.args as { amountOut: bigint }).amountOut;
              if (ev.eventName === "RedeemClaimOutstanding") outstanding = (ev.args as { stillDue: bigint }).stillDue;
            } catch {
              // not one of the vault's events
            }
          }
        } catch {
          outstanding = null;
        }
        return { status: "claimed", hash, paid, outstanding };
      } catch (err) {
        // Retryable, never terminal. Do not mark the receipt failed.
        if (isAwaitingSettlement(err)) {
          return { status: "awaiting-settlement", retryable: true, reason: decodeRevert(err) };
        }
        // STACK 5: waiting for a price observed after the request. Bounded: in full after 4 days.
        if (IS_STACK5 && revertName(err) === "CertVault_AwaitingFreshPrice") {
          let paysInFullAt: number | null = null;
          if (publicClient) {
            try {
              const [r, timeout] = await Promise.all([
                publicClient.readContract({
                  address: mirror.vault,
                  abi: Stack5CertVaultABI,
                  functionName: "redeemReceipts",
                  args: [receiptId],
                }),
                publicClient.readContract({ address: mirror.vault, abi: Stack5CertVaultABI, functionName: "QUEUED_PRICE_TIMEOUT" }),
              ]);
              const enqueuedAt = (r as readonly [string, bigint, bigint, bigint, boolean])[2];
              paysInFullAt = Number(enqueuedAt + (timeout as bigint));
            } catch {
              paysInFullAt = null;
            }
          }
          return { status: "awaiting-price", retryable: true, reason: decodeRevert(err), paysInFullAt };
        }
        throw err;
      }
    },
    [confirmed, mutateAsync, mirror.vault, publicClient],
  );

  const stageRefund = useCallback(
    async (receiptId: bigint): Promise<TxHash> =>
      confirmed({
        chainId: CHAIN_ID,
        address: mirror.vault,
        abi: VAULT_WRITE_ABI,
        functionName: "stageRefund",
        args: [receiptId],
      }),
    [confirmed, mutateAsync, mirror.vault],
  );

  const refundMint = useCallback(
    async (receiptId: bigint): Promise<TxHash> =>
      confirmed({
        chainId: CHAIN_ID,
        address: mirror.vault,
        abi: VAULT_WRITE_ABI,
        functionName: "refundMint",
        args: [receiptId],
      }),
    [confirmed, mutateAsync, mirror.vault],
  );

  const recallMargin = useCallback(
    async (): Promise<TxHash> =>
      confirmed({
        chainId: CHAIN_ID,
        address: mirror.vault,
        abi: VAULT_WRITE_ABI,
        functionName: "recallMargin",
        args: [],
      }),
    [confirmed, mutateAsync, mirror.vault],
  );

  const rebalance = useCallback(
    async (): Promise<TxHash> =>
      confirmed({
        chainId: CHAIN_ID,
        address: mirror.vault,
        abi: VAULT_WRITE_ABI,
        functionName: "rebalance",
        args: [],
      }),
    [confirmed, mutateAsync, mirror.vault],
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

/**
 * What happened when a mint tried to make this vault's backing fresh.
 *
 * `hashes` carries what was actually sent; a null half needed no transaction, the mark
 * because the oracle already holds that nonce or newer, the attestation because it was
 * still inside its age budget. Both halves come from ONE signed bundle.
 *
 * The distinction that matters is `already-fresh` versus `unavailable`. Losing a relay race
 * is a SUCCESS: `SolvencyRegistry_StaleBatch` and `CertOracle_StaleNonce` mean somebody
 * else's transaction landed first, which is the outcome this mint wanted. Treating that as
 * an error would refuse a mint that is now perfectly able to proceed.
 */
export type RefreshOutcome =
  /** The attestation was still fresh. Nothing was sent. */
  | { status: "not-needed" }
  /** This mint relayed the bundle itself. */
  | { status: "refreshed"; hashes: RelayHashes }
  /** A relay failed, but the chain is fresh anyway - someone else won the race. Proceed. */
  | { status: "already-fresh" }
  /** No usable refresh. The mint MUST NOT be sent; it would revert at the user's expense. */
  | { status: "unavailable"; reason: RefreshFailure };

export type RefreshFailure =
  /** The signer served nothing usable for this vault. */
  | "no-bundle"
  /** Every bundle offered was too close to its deadline to survive the relays. */
  | "expiring"
  /** Two attempts were relayed and both failed, and the chain is still stale. */
  | "race-lost"
  /**
   * STACK 5: the oracle's mark is too old to mint against and the signer served no v2 mark newer
   * than it (or none young enough to leave time for the mint).
   */
  | "no-mark";

export interface RelayHashes {
  mark: TxHash | null;
  attestation: TxHash | null;
}

/**
 * What to tell someone whose mint could not be made ready.
 *
 * Each says what happened and what to do, because "the contract rejected this action
 * (SolvencyRegistry_StaleBatch)" is accurate and useless - and worse, it reads like a fault
 * when the usual cause is that the protocol is working and somebody else was first.
 */
const REFRESH_FAILURE_COPY: Record<RefreshFailure, string> = {
  "no-bundle":
    "The attester is not serving a signature for this vault right now, so there is nothing " +
    "to refresh the attestation with. Nothing was submitted. Try again shortly.",
  expiring:
    "The attester's signature was too close to expiring to relay safely. Nothing was " +
    "submitted. A new one is published every 30 seconds — try again.",
  "race-lost":
    "Another transaction refreshed this vault while yours was in flight, and the attestation " +
    "is still not fresh enough to mint against. Nothing further was submitted. Try again.",
  "no-mark":
    "Minting needs a recent mark price from the venue, and the attester is not serving a newer " +
    "one for this vault right now. Nothing was submitted. Try again shortly.",
};

/** STACK 5: the mark was refreshed, but the oracle still refuses a mint. */
const MINT_STILL_CLOSED_COPY =
  "Minting is still closed with a fresh mark price: oracle.mintAllowed() is false, so the price " +
  "feed is stale (every weekend) or the venue mark and the feed disagree by more than the " +
  "allowed band. The mint was not submitted. Redemption is unaffected and still works.";

/** STACK 5: the oracle's mark, with the chain's clock to age it against. All unix seconds. */
type MarkState = { markAt: bigint; maxMarkAge: bigint; nonce: bigint; now: bigint };

/**
 * How much of `maxMarkAge` a mark must still have left to count as fresh: time for the mint to
 * land behind the relay. 60 s of a 300 s budget, mirroring REFRESH_AT_AGE_SEC's 240-of-300 for the
 * registry, and a fifth of the budget where the budget is small.
 */
const MARK_REFRESH_MARGIN_SEC = 60n;
function markMargin5(maxMarkAge: bigint): bigint {
  return maxMarkAge / 5n < MARK_REFRESH_MARGIN_SEC ? maxMarkAge / 5n : MARK_REFRESH_MARGIN_SEC;
}
function markIsFresh5(s: MarkState): boolean {
  return s.now - s.markAt + markMargin5(s.maxMarkAge) <= s.maxMarkAge;
}

/** The routing reason `redeem` returns when its own price-age check declines the instant path. */
function instantPriceTooOldReason(): DecodedRevert {
  const entry = REVERT_COPY.CertVault_InstantPriceTooOld;
  return { name: "CertVault_InstantPriceTooOld", args: [], message: entry.message, kind: entry.kind, cause: null };
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
    async (): Promise<TxHash> => {
      // No faucet is deployed on mainnet, so this hook has nothing to call. Throwing names the
      // reason; the UI should not offer the button at all, which is what HAS_FAUCET is for.
      if (!FAUCET_ADDRESS) throw new Error("No faucet is deployed on " + CHAIN_LABEL + ".");
      return mutateAsync({
        chainId: CHAIN_ID,
        address: FAUCET_ADDRESS,
        abi: TestFaucetABI,
        functionName: "claim",
        args: [],
      });
    },
    [mutateAsync],
  );

  return { claim, isPending, error: error ? decodeRevert(error) : null, reset };
}
