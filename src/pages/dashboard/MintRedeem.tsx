import { useCallback, useMemo, useState } from "react";
import { motion } from "framer-motion";
import { AlertTriangle, ArrowRight, Check, Info, Loader2 } from "lucide-react";
import { isChainVaultId, useDashboard } from "./store";
import type { MintPreset, VaultId } from "./store";
import {
  AgeLine,
  CapacityHalt,
  Dropdown,
  MicroLabel,
  Panel,
  PriceUnavailable,
  SegmentedTabs,
  Stagger,
  ViewHeader,
} from "./ui";
import { EM_DASH, fmtCountdown, fmtNum, fmtOrDash, fmtUSD, truncHash } from "./format";
import { FLOW_META } from "./flowMeta";
import { explorerTxUrl } from "@/chain/config";
import {
  decodeRevert,
  routeMint,
  routeRedeem,
  useCertActions,
  useFaucetActions,
  type DecodedRevert,
  type SizeRoute,
} from "@/chain/useActions";
import { capacityLegsLabel, type ChainVaultId } from "@/chain/useVaults";
import {
  ONE_18,
  feeAmount18,
  fromBps,
  fromCert,
  fromCollateral,
  fromPrice18,
  quoteCertOut18,
  quoteCollateralOut6,
  scaleCollateralTo18,
  toCert,
  toCollateral,
} from "@/chain/units";
import { cn } from "@/lib/utils";

type Tab = "mint" | "redeem";
type Busy = "approve" | "submit" | "queue" | "force" | "claim" | "recall" | "faucet" | null;

interface Notice {
  tone: "info" | "warn" | "ok";
  title: string;
  body: string;
  /** Offered when the contract's answer means "do this instead", not "you failed". */
  action?: { label: string; run: () => void };
}

/** Outer shell: remounts the form whenever another view requests a preset. */
export default function MintRedeem() {
  const { mintPreset } = useDashboard();
  return <MintRedeemForm key={mintPreset.nonce} preset={mintPreset} />;
}

/**
 * A revert becomes a presentation, not a red toast.
 *
 * `CertVault_UseQueuedRedeem` and the keeper no-ops are classified `not-an-error` /
 * `no-op` by the chain layer, and `CertVault_AwaitingSettlement` as `retryable` — none of
 * them may be shown as a failure.
 */
function noticeFor(err: unknown, action?: Notice["action"]): Notice {
  const decoded: DecodedRevert = decodeRevert(err);
  const tone: Notice["tone"] =
    decoded.kind === "not-an-error" || decoded.kind === "no-op" || decoded.kind === "rejected"
      ? "info"
      : "warn";
  const title =
    decoded.kind === "not-an-error"
      ? "Not an error"
      : decoded.kind === "retryable"
        ? "Retryable — nothing is lost"
        : decoded.kind === "rejected"
          ? "Cancelled in the wallet"
          : decoded.kind === "routing-bug"
            ? "App routing bug"
            : "The contract declined";
  return { tone, title, body: decoded.message, action };
}

function NoticeCard({ notice, onDismiss }: { notice: Notice; onDismiss: () => void }) {
  const Icon = notice.tone === "warn" ? AlertTriangle : notice.tone === "ok" ? Check : Info;
  return (
    <div
      className={cn(
        "mt-4 flex items-start gap-3 border-l-2 border border-white/10 bg-[#0d0f0d] p-4",
        notice.tone === "warn" && "border-l-warn",
        notice.tone === "ok" && "border-l-green-bright",
        notice.tone === "info" && "border-l-silver",
      )}
    >
      <Icon
        size={14}
        className={cn(
          "mt-0.5 shrink-0",
          notice.tone === "warn" ? "text-warn" : notice.tone === "ok" ? "text-green-bright" : "text-silver",
        )}
      />
      <div className="min-w-0 flex-1">
        <p className="font-mono text-[11px] uppercase tracking-[0.08em] text-white">{notice.title}</p>
        <p className="mt-1 font-mono text-[11px] leading-[1.6] text-white-60">{notice.body}</p>
        <div className="mt-3 flex flex-wrap items-center gap-4">
          {notice.action && (
            <button
              type="button"
              onClick={notice.action.run}
              className="flex items-center gap-1.5 border hairline-dark px-3 py-1.5 font-mono text-[10px] uppercase tracking-[0.08em] text-white transition-colors hover:bg-section-deep-2"
            >
              {notice.action.label} <ArrowRight size={11} />
            </button>
          )}
          <button
            type="button"
            onClick={onDismiss}
            className="font-mono text-[10px] uppercase tracking-[0.08em] text-white-60 hover:text-white"
          >
            Dismiss
          </button>
        </div>
      </div>
    </div>
  );
}

/**
 * "Max" fills the input by TRUNCATING, never rounding.
 *
 * A rounded-up last digit would ask the vault to spend more than the wallet holds and
 * revert at the wallet for no good reason. The display figure is a float anyway (18
 * decimals do not fit in a double), so this is a ceiling, not an exact balance.
 */
function maxInput(balance: number | null, dp: number): string {
  if (balance === null || balance <= 0) return "";
  const scale = 10 ** dp;
  return (Math.floor(balance * scale) / scale).toFixed(dp);
}

function Row({ label, value, accent }: { label: string; value: React.ReactNode; accent?: boolean }) {
  return (
    <div className="flex items-baseline justify-between gap-4 border-b hairline-dark py-3.5 font-mono text-[13px]">
      <span className="text-[11px] uppercase tracking-[0.08em] text-white-60">{label}</span>
      <span className={cn("text-right tabular-nums", accent ? "text-green-bright" : "text-white")}>
        {value}
      </span>
    </div>
  );
}

function MintRedeemForm({ preset }: { preset: MintPreset }) {
  const {
    vaults,
    liveVault,
    vaultConfig,
    usdc,
    collateralSymbol,
    positions,
    connected,
    setWalletModalOpen,
    wrongNetwork,
    switchToUseCert,
    faucet,
    now,
    maxAttestationAgeSec,
    refetch,
    refetchBalances,
    pushToast,
    settleToast,
    dismissToast,
  } = useDashboard();

  // Only a routed vault can reach the write path. `isChainVaultId` is the only door.
  const [asset, setAsset] = useState<ChainVaultId>(
    isChainVaultId(preset.asset) ? preset.asset : "utsla",
  );
  const [tab, setTab] = useState<Tab>(preset.tab);
  const [amountStr, setAmountStr] = useState("");
  const [receiptStr, setReceiptStr] = useState("");
  const [errNonce, setErrNonce] = useState(0);
  const [busy, setBusy] = useState<Busy>(null);
  const [notice, setNotice] = useState<Notice | null>(null);

  const actions = useCertActions(asset);
  const faucetActions = useFaucetActions();

  const vault = vaults.find((v) => v.id === asset) ?? vaults[0];
  const lv = liveVault(asset);
  const cfg = vaultConfig(asset);
  const meta = FLOW_META[asset];

  const px18 = lv?.raw.px18 ?? null;
  const priceUnavailable = Boolean(lv?.priceUnavailable);
  const mintAllowed = Boolean(lv?.mintAllowed);
  const attestationStale = Boolean(lv?.attestationStale);

  /* ---------------------------------------------------------------- quote */

  // Amounts sent on-chain are parsed from the input STRING, never from a float: the
  // display helpers lose precision at 18 decimals by design.
  const amountIn6 = useMemo(() => {
    try {
      return toCollateral(amountStr);
    } catch {
      return 0n;
    }
  }, [amountStr]);

  const certIn18 = useMemo(() => {
    try {
      return toCert(amountStr);
    } catch {
      return 0n;
    }
  }, [amountStr]);

  const quote = useMemo(() => {
    if (!cfg || px18 === null) return null;
    if (tab === "mint") {
      const gross18 = scaleCollateralTo18(amountIn6);
      return {
        fee: fromPrice18(feeAmount18(gross18, cfg.mintFeeBps)),
        feeBps: cfg.mintFeeBps,
        out: fromCert(quoteCertOut18({ amountIn6, px18, mintFeeBps: cfg.mintFeeBps })),
        outUnit: meta.name,
      };
    }
    const gross18 = (certIn18 * px18) / ONE_18;
    return {
      fee: fromPrice18(feeAmount18(gross18, cfg.redeemFeeBps)),
      feeBps: cfg.redeemFeeBps,
      out: fromCollateral(quoteCollateralOut6({ certIn18, px18, redeemFeeBps: cfg.redeemFeeBps })),
      outUnit: collateralSymbol,
    };
  }, [cfg, px18, tab, amountIn6, certIn18, meta.name, collateralSymbol]);

  /**
   * The size fork, mirrored before anything reaches the wallet.
   *
   * `mintInstant` reverts `CertVault_AboveInstantCap` above the cap and `requestMint`
   * reverts `CertVault_BelowInstantCap` below it, so the amount decides which function is
   * called. `instantCap18` comes from `vault.cfg()`; when it has not loaded the button is
   * disabled rather than guessing.
   */
  const route: SizeRoute | null = useMemo(() => {
    if (!cfg) return null;
    return tab === "mint" ? routeMint(amountIn6, cfg.instantCap18) : routeRedeem(certIn18, cfg.instantCap18);
  }, [cfg, tab, amountIn6, certIn18]);

  const balance = tab === "mint" ? usdc : positions[asset];
  const amount = useMemo(() => {
    const n = parseFloat(amountStr);
    return Number.isFinite(n) && n > 0 ? n : 0;
  }, [amountStr]);

  const overBalance = balance !== null && amount > balance;
  const error = amount <= 0 ? null : overBalance ? `Insufficient ${tab === "mint" ? collateralSymbol : meta.name} balance` : null;

  const onAmountChange = (v: string) => {
    if (!/^\d*\.?\d*$/.test(v)) return;
    const next = parseFloat(v);
    if (Number.isFinite(next) && balance !== null && next > balance && !overBalance) {
      setErrNonce((n) => n + 1);
    }
    setAmountStr(v);
  };

  /* -------------------------------------------------------------- actions */

  const after = useCallback(() => {
    refetch();
    refetchBalances();
  }, [refetch, refetchBalances]);

  const run = useCallback(
    async (
      kind: Exclude<Busy, null>,
      pendingTitle: string,
      submit: () => Promise<`0x${string}`>,
      successTitle: string,
    ) => {
      setBusy(kind);
      setNotice(null);
      const toastId = pushToast({ state: "pending", title: pendingTitle });
      try {
        const hash = await submit();
        settleToast(toastId, successTitle, truncHash(hash));
        setNotice({
          tone: "ok",
          title: successTitle,
          body: `Submitted as ${truncHash(hash)} on chain 46630. ${explorerTxUrl(hash)}`,
        });
        after();
      } catch (err) {
        dismissToast(toastId);
        setNotice(noticeFor(err));
      } finally {
        setBusy(null);
      }
    },
    [after, dismissToast, pushToast, settleToast],
  );

  /** `TestUSDG.approve(vault, amountIn)` at SIX decimals, before either mint path. */
  const onApprove = () =>
    run(
      "approve",
      `Approving ${collateralSymbol}`,
      () => actions.approve(amountStr),
      "Approval submitted",
    );

  const onMint = async () => {
    setBusy("submit");
    setNotice(null);
    const toastId = pushToast({ state: "pending", title: `Mint ${meta.name}` });
    try {
      const result = await actions.mint(amountStr);
      if (result.status === "instant") {
        settleToast(toastId, `Minted ${meta.name}`, truncHash(result.hash));
        setNotice({
          tone: "ok",
          title: "Minted instantly",
          body: `Below the instant cap, so mintInstant was used. ${truncHash(result.hash)}`,
        });
      } else {
        settleToast(toastId, "Mint requested", truncHash(result.hash));
        setNotice({
          tone: "info",
          title: "Mint requested — escrowed, awaiting the fill",
          body:
            "Above the instant cap, so requestMint escrowed your collateral and opened a receipt. A keeper calls settleMint once the fill is known — that step is not yours. If the 24-hour settle window passes unsettled, anyone (including you) may stage and claim a full refund of the escrow.",
        });
      }
      after();
    } catch (err) {
      dismissToast(toastId);
      setNotice(noticeFor(err));
    } finally {
      setBusy(null);
    }
  };

  const onQueueRedeem = () =>
    run(
      "queue",
      `Queued redemption of ${meta.name}`,
      () => actions.requestRedeem(amountStr),
      "Redemption queued",
    );

  const onRedeem = async () => {
    setBusy("submit");
    setNotice(null);
    const toastId = pushToast({ state: "pending", title: `Redeem ${meta.name}` });
    try {
      const result = await actions.redeem(amountStr);
      if (result.status === "needs-queued") {
        // NOT a failure. The fast path declined because the hot buffer is thin.
        dismissToast(toastId);
        setNotice({
          tone: "info",
          title: "Instant buffer is thin — use the queue",
          body: `${result.reason.message} Queued redemptions take two batch round-trips (one to close, one to withdraw), then you claim the receipt.`,
          action: { label: "Send through the queue", run: onQueueRedeem },
        });
        return;
      }
      if (result.status === "instant") {
        settleToast(toastId, `Redeemed ${meta.name}`, truncHash(result.hash));
        setNotice({
          tone: "ok",
          title: "Redeemed from the hot buffer",
          body: `Paid instantly. ${truncHash(result.hash)}`,
        });
      } else {
        settleToast(toastId, "Redemption queued", truncHash(result.hash));
        setNotice({
          tone: "info",
          title: "Redemption queued",
          body:
            "Above the instant cap, so requestRedeem burned the certificates now and pays by claim. Two batch round-trips are expected; the venue's priority expiration is 14 days, which is the real worst case. Claim the receipt below once settled.",
        });
      }
      after();
    } catch (err) {
      dismissToast(toastId);
      setNotice(noticeFor(err));
    } finally {
      setBusy(null);
    }
  };

  /** Gated on NOTHING. forceExit reads no buffer level, no capacity, no mintAllowed. */
  const onForceExit = () =>
    run("force", `Force exit ${meta.name}`, () => actions.forceExit(amountStr), "Force exit submitted");

  const onClaim = async () => {
    let receiptId: bigint;
    try {
      receiptId = BigInt(receiptStr.trim());
    } catch {
      setNotice({
        tone: "warn",
        title: "Receipt id",
        body: "Enter the numeric receipt id from your RedeemRequested / ForceExited event.",
      });
      return;
    }
    setBusy("claim");
    setNotice(null);
    const toastId = pushToast({ state: "pending", title: `Claim receipt ${receiptStr}` });
    try {
      const result = await actions.claimRedeem(receiptId);
      if (result.status === "awaiting-settlement") {
        // Retryable, NEVER terminal: the receipt stays claimable forever.
        dismissToast(toastId);
        setNotice({
          tone: "warn",
          title: "Awaiting settlement — retryable, not failed",
          body: `${result.reason.message} This receipt stays claimable indefinitely; recallMargin is permissionless and anyone may call it to push the funds along.`,
          action: { label: "Call recallMargin()", run: onRecall },
        });
        return;
      }
      settleToast(toastId, "Receipt claimed", truncHash(result.hash));
      setNotice({ tone: "ok", title: "Receipt claimed", body: truncHash(result.hash) });
      after();
    } catch (err) {
      dismissToast(toastId);
      setNotice(noticeFor(err));
    } finally {
      setBusy(null);
    }
  };

  function onRecall() {
    void run(
      "recall",
      "recallMargin()",
      () => actions.recallMargin(),
      "recallMargin submitted",
    );
  }

  const onFaucet = async () => {
    setBusy("faucet");
    setNotice(null);
    const toastId = pushToast({ state: "pending", title: `Claiming ${collateralSymbol}` });
    try {
      const hash = await faucetActions.claim();
      settleToast(toastId, `${collateralSymbol} claimed`, truncHash(hash));
      after();
    } catch (err) {
      dismissToast(toastId);
      setNotice(noticeFor(err));
    } finally {
      setBusy(null);
    }
  };

  /* --------------------------------------------------------------- gating */

  const unit = tab === "mint" ? collateralSymbol : meta.name;

  /**
   * The SILENT mint halt.
   *
   * `capacityOracle.maxNotional18` returning 0 refuses every mint through
   * `_requireCapacity` (`CertVault.sol:1770`) while leaving `oracle.mintAllowed()` true, the
   * price healthy and the attestation fresh. Nothing else on this form moves, so it is gated
   * and explained explicitly. `capIsZero` is false while the cap is still being read — an
   * unknown cap must never present as a halt.
   */
  const capacity = lv?.capacity ?? null;
  const capacityHalted = Boolean(capacity?.capIsZero);
  const mintBlocked = tab === "mint" && (!mintAllowed || priceUnavailable || capacityHalted);
  const submitDisabled =
    !connected ||
    wrongNetwork ||
    amount <= 0 ||
    Boolean(error) ||
    !actions.isRoutable ||
    busy !== null ||
    (tab === "mint" && mintBlocked);

  const faucetReady = faucet ? faucet.nextAvailableAt * 1000 <= now : false;
  const faucetWaitSec = faucet ? Math.max(0, faucet.nextAvailableAt - Math.floor(now / 1000)) : 0;

  return (
    <div>
      <ViewHeader label="Primary Market" title={<>Mint / <span className="text-metallic">Redeem.</span></>} />

      {wrongNetwork && (
        <div className="mt-6 flex flex-wrap items-center justify-between gap-3 border border-warn/40 bg-[#12120d] px-4 py-3">
          <p className="font-mono text-[11px] uppercase tracking-[0.06em] text-warn">
            Your wallet is on another network. This app only talks to chain 46630.
          </p>
          <button
            type="button"
            onClick={switchToUseCert}
            className="border border-warn/40 px-3 py-1.5 font-mono text-[10px] uppercase tracking-[0.08em] text-warn hover:bg-warn/10"
          >
            Switch network
          </button>
        </div>
      )}

      <div className="mt-8 grid gap-3 lg:grid-cols-[55fr_45fr]">
        {/* Left: action panel */}
        <Stagger index={0}>
          <Panel className="flex h-full flex-col p-5 md:p-6">
            <SegmentedTabs
              options={[
                { value: "mint" as Tab, label: "Mint" },
                { value: "redeem" as Tab, label: "Redeem" },
              ]}
              value={tab}
              onChange={(t) => {
                setTab(t);
                setAmountStr("");
                setNotice(null);
              }}
            />

            <div className="mt-6">
              <MicroLabel className="mb-2 text-[10px]">Asset</MicroLabel>
              <Dropdown
                options={vaults.map((v) => ({
                  value: v.id,
                  label: `${v.name} · ${v.full}`,
                  disabled: !isChainVaultId(v.id),
                  hint: isChainVaultId(v.id) ? undefined : "not deployed",
                }))}
                value={asset}
                onChange={(v) => {
                  const id = v as VaultId;
                  if (isChainVaultId(id)) {
                    setAsset(id);
                    setAmountStr("");
                    setNotice(null);
                  }
                }}
              />
            </div>

            <div className="mt-6">
              <div className="flex items-center justify-between">
                <MicroLabel className="text-[10px]">Amount</MicroLabel>
                <button
                  type="button"
                  onClick={() => onAmountChange(maxInput(balance, tab === "mint" ? 2 : 6))}
                  className="font-mono text-[10px] uppercase tracking-[0.08em] text-green-bright hover:text-white"
                >
                  Max
                </button>
              </div>
              <motion.div
                key={errNonce}
                animate={errNonce > 0 ? { x: [0, -8, 8, -4, 4, 0] } : undefined}
                transition={{ duration: 0.4 }}
                className="mt-1 flex items-end gap-3 border-b hairline-dark pb-2 focus-within:border-green-bright"
              >
                <input
                  value={amountStr}
                  onChange={(e) => onAmountChange(e.target.value)}
                  inputMode="decimal"
                  placeholder="0.00"
                  className="w-full bg-transparent font-mono text-[32px] tabular-nums leading-none text-white outline-none placeholder:text-white-60/40 md:text-[40px]"
                />
                <span className="mb-1 shrink-0 border hairline-dark px-2.5 py-1 font-mono text-[11px] uppercase tracking-[0.06em] text-silver">
                  {unit}
                </span>
              </motion.div>
              <div className="mt-2 flex flex-wrap items-center justify-between gap-2 font-mono text-[11px]">
                <span className="text-white-60">
                  Balance: {fmtOrDash(balance, (n) => fmtNum(n, tab === "mint" ? 2 : 6))} {unit}
                  {!connected && " · wallet not connected"}
                </span>
                {error && <span className="text-warn">{error}</span>}
              </div>
              {/* Which contract function this amount will call, decided before submitting. */}
              <p className="mt-2 font-mono text-[10px] uppercase tracking-[0.06em] text-white-60/70">
                {!cfg
                  ? "Reading vault.cfg() for the instant cap — the submit button stays disabled until it lands."
                  : route === "instant"
                    ? tab === "mint"
                      ? `At or below the instant cap (${fmtUSD(fromPrice18(cfg.instantCap18), 0)}) → mintInstant, one transaction`
                      : `At or below the instant cap → redeemInstant, paid from the hot buffer`
                    : tab === "mint"
                      ? `Above the instant cap (${fmtUSD(fromPrice18(cfg.instantCap18), 0)}) → requestMint, escrow plus a receipt`
                      : `Above the instant cap → requestRedeem, burns now and pays by claim`}
              </p>
            </div>

            {/* The capacity halt is its OWN card, not a line inside the oracle card: it fires
                with a healthy oracle and mintAllowed() == true, so folding it into "minting
                paused because the oracle is unhealthy" would misattribute it. */}
            {tab === "mint" && capacity !== null && (
              <CapacityHalt className="mt-4" view={capacity} bufferHeld={vault.buffer} />
            )}

            {mintBlocked && (!mintAllowed || priceUnavailable) && (
              <div className="mt-4 border border-warn/40 bg-[#12120d] p-4">
                <p className="font-mono text-[11px] uppercase tracking-[0.06em] text-warn">
                  {priceUnavailable ? "Price unavailable · minting paused" : "Minting paused"}
                </p>
                <p className="mt-1 font-mono text-[11px] leading-[1.6] text-white-60">
                  {priceUnavailable
                    ? "oracle.px() reverted: the feed is stale, deviant or badly fed. That is designed behaviour, not an outage."
                    : "oracle.mintAllowed() is false."}
                  {attestationStale
                    ? ` The attestation is also older than ${maxAttestationAgeSec}s, which sets capacity to zero — that alone stops minting.`
                    : ""}{" "}
                  Redemption is unaffected and still works.
                </p>
              </div>
            )}

            {/* Headroom before CertVault_AtCapacity, so an over-cap amount is visible before
                the wallet rather than after a revert. */}
            {tab === "mint" && capacity !== null && !capacity.capIsZero && (
              <p className="mt-3 font-mono text-[10px] uppercase leading-[1.7] tracking-[0.06em] text-white-60/70">
                {capacity.utilisationPct === null || capacity.cap === null || capacity.used === null
                  ? "Reading capacityOracle.maxNotional18 for this vault's mint ceiling…"
                  : `Mint ceiling ${fmtUSD(capacity.cap, 0)} · ${fmtNum(
                      capacity.utilisationPct,
                      2,
                    )}% used · ${fmtUSD(Math.max(0, capacity.cap - capacity.used), 0)} of notional headroom${
                      capacity.bindingLegs.length > 0
                        ? ` · bound by ${capacityLegsLabel(capacity.bindingLegs)}`
                        : ""
                    }`}
              </p>
            )}

            {tab === "mint" && (
              <div className="mt-5 border hairline-dark bg-[#0d0f0d] p-4">
                <div className="flex flex-wrap items-center justify-between gap-2">
                  <MicroLabel className="text-[10px]">
                    Step 1 · approve {collateralSymbol} (6 decimals)
                  </MicroLabel>
                  <button
                    type="button"
                    disabled={!connected || wrongNetwork || amount <= 0 || busy !== null}
                    onClick={onApprove}
                    className="flex items-center gap-2 border hairline-dark px-3 py-1.5 font-mono text-[10px] uppercase tracking-[0.08em] text-white transition-colors hover:bg-section-deep-2 disabled:pointer-events-none disabled:opacity-40"
                  >
                    {busy === "approve" && <Loader2 size={11} className="animate-spin" />}
                    Approve
                  </button>
                </div>
                <p className="mt-1 font-mono text-[10px] leading-[1.6] uppercase tracking-[0.06em] text-white-60/70">
                  Both mint paths spend your collateral, so the vault needs an allowance first.
                </p>
              </div>
            )}

            <div className="mt-auto pt-6">
              <button
                type="button"
                disabled={connected && submitDisabled}
                onClick={() => {
                  if (!connected) {
                    setWalletModalOpen(true);
                    return;
                  }
                  void (tab === "mint" ? onMint() : onRedeem());
                }}
                className={cn(
                  "flex w-full items-center justify-center gap-2 bg-green-bright px-8 py-[18px] text-[12px] font-semibold uppercase tracking-[0.08em] text-ink transition-all hover:bg-[#b8d4b4] active:scale-[0.98]",
                  !connected && "opacity-60",
                  connected && submitDisabled && "pointer-events-none opacity-40",
                )}
              >
                {busy === "submit" && <Loader2 size={13} className="animate-spin" />}
                {!connected
                  ? "Connect wallet"
                  : tab === "mint"
                    ? `Step 2 · Mint ${meta.name}`
                    : `Redeem ${meta.name}`}
              </button>

              {tab === "redeem" && (
                <button
                  type="button"
                  disabled={!connected || wrongNetwork || amount <= 0 || busy !== null}
                  onClick={() => void onForceExit()}
                  title="Permissionless. Reads no buffer level, no capacity, no mintAllowed and no governance state."
                  className="mt-3 flex w-full items-center justify-center gap-2 border hairline-dark px-8 py-3.5 font-mono text-[11px] uppercase tracking-[0.08em] text-white transition-colors hover:bg-section-deep-2 disabled:pointer-events-none disabled:opacity-40"
                >
                  {busy === "force" && <Loader2 size={12} className="animate-spin" />}
                  Force exit — never gated
                </button>
              )}

              {notice && <NoticeCard notice={notice} onDismiss={() => setNotice(null)} />}
            </div>
          </Panel>
        </Stagger>

        {/* Right: quote + faucet + receipts */}
        <div className="flex flex-col gap-3">
          <Stagger index={1}>
            <Panel className="flex flex-col p-5 md:p-6">
              <div className="flex items-center justify-between gap-3">
                <MicroLabel>Quote · guarded oracle price</MicroLabel>
                <AgeLine
                  ageSec={lv?.ageSec ?? null}
                  stale={attestationStale}
                  maxAgeSec={maxAttestationAgeSec}
                  batch={lv?.backing.provenAtBatch ?? null}
                />
              </div>

              <div className="mt-4 flex flex-col">
                <Row
                  label="Oracle price"
                  value={
                    priceUnavailable || px18 === null ? (
                      <PriceUnavailable />
                    ) : (
                      fmtUSD(fromPrice18(px18))
                    )
                  }
                />
                <Row
                  label={tab === "mint" ? `You deposit (${collateralSymbol})` : `You burn (${meta.name})`}
                  value={amount > 0 ? fmtNum(amount, tab === "mint" ? 2 : 6) : EM_DASH}
                />
                <Row
                  label={
                    quote
                      ? `${tab === "mint" ? "Mint" : "Redeem"} fee (${fromBps(quote.feeBps).toFixed(2)}%)`
                      : `${tab === "mint" ? "Mint" : "Redeem"} fee`
                  }
                  value={quote && amount > 0 ? fmtUSD(quote.fee, 4) : EM_DASH}
                />
                <Row
                  label="Indicative receive"
                  accent
                  value={
                    quote && amount > 0
                      ? `${fmtNum(quote.out, tab === "mint" ? 6 : 2)} ${quote.outUnit}`
                      : EM_DASH
                  }
                />
                <Row
                  label="Route"
                  value={
                    route === null
                      ? EM_DASH
                      : route === "instant"
                        ? tab === "mint"
                          ? "mintInstant"
                          : "redeemInstant"
                        : tab === "mint"
                          ? "requestMint"
                          : "requestRedeem"
                  }
                />
                <Row
                  label="Settlement"
                  value={
                    route === "instant"
                      ? "one transaction"
                      : tab === "mint"
                        ? "keeper fill, then settleMint"
                        : "two batch round-trips, then claim"
                  }
                />
              </div>

              <p className="mt-4 font-mono text-[10px] leading-[1.7] uppercase tracking-[0.06em] text-white-60/70">
                Indicative only. The vault applies venue quantisation, and on the request path the real
                figure depends on the keeper's fill price. The fee is shown separately, not folded into
                the rate. Collateral is 6 decimals in, certificates 18 decimals out.
              </p>
            </Panel>
          </Stagger>

          {/* Faucet: the ONLY way a tester gets collateral on this deployment. */}
          <Stagger index={2}>
            <Panel className="p-5">
              <div className="flex flex-wrap items-center justify-between gap-2">
                <MicroLabel>Test collateral · TestFaucet</MicroLabel>
                <button
                  type="button"
                  disabled={!connected || wrongNetwork || busy !== null || !faucetReady}
                  onClick={() => void onFaucet()}
                  className="flex items-center gap-2 border hairline-dark px-3 py-1.5 font-mono text-[10px] uppercase tracking-[0.08em] text-white transition-colors hover:bg-section-deep-2 disabled:pointer-events-none disabled:opacity-40"
                >
                  {busy === "faucet" && <Loader2 size={11} className="animate-spin" />}
                  {faucetReady ? "Claim" : `Cooldown ${fmtCountdown(faucetWaitSec)}`}
                </button>
              </div>
              <div className="mt-3 grid grid-cols-2 gap-3 font-mono text-[11px]">
                <p className="text-white-60">
                  Drip{" "}
                  <span className="text-white">
                    {fmtOrDash(faucet?.drip ?? null, (n) => `${fmtNum(n, 0)} ${collateralSymbol}`)}
                  </span>
                </p>
                <p className="text-white-60">
                  Faucet holds{" "}
                  <span className={cn(faucet && faucet.balance <= 0 ? "text-warn" : "text-white")}>
                    {fmtOrDash(faucet?.balance ?? null, (n) => `${fmtNum(n, 0)} ${collateralSymbol}`)}
                  </span>
                </p>
              </div>
              <p className="mt-2 font-mono text-[10px] leading-[1.6] uppercase tracking-[0.06em] text-white-60/70">
                TestUSDG.mint is owner-gated, so this faucet is the only source of collateral here. An
                empty faucet is a faucet problem, not a minting problem.
              </p>
            </Panel>
          </Stagger>

          {/* Receipt claiming. Awaiting settlement is retryable, never terminal. */}
          <Stagger index={3}>
            <Panel className="p-5">
              <MicroLabel>Claim a redemption receipt</MicroLabel>
              <div className="mt-3 flex flex-wrap items-center gap-2">
                <input
                  value={receiptStr}
                  onChange={(e) => setReceiptStr(e.target.value.replace(/[^\d]/g, ""))}
                  inputMode="numeric"
                  placeholder="receipt id"
                  className="min-w-0 flex-1 border hairline-dark bg-[#0d0f0d] px-3 py-2 font-mono text-[12px] tabular-nums text-white outline-none placeholder:text-white-60/40 focus:border-green-bright"
                />
                <button
                  type="button"
                  disabled={!connected || wrongNetwork || receiptStr === "" || busy !== null}
                  onClick={() => void onClaim()}
                  className="flex items-center gap-2 border hairline-dark px-3 py-2 font-mono text-[10px] uppercase tracking-[0.08em] text-white transition-colors hover:bg-section-deep-2 disabled:pointer-events-none disabled:opacity-40"
                >
                  {busy === "claim" && <Loader2 size={11} className="animate-spin" />}
                  Claim
                </button>
                <button
                  type="button"
                  disabled={!connected || wrongNetwork || busy !== null}
                  onClick={onRecall}
                  title="Permissionless. Reaches freed margin in two calls, a batch apart."
                  className="flex items-center gap-2 border hairline-dark px-3 py-2 font-mono text-[10px] uppercase tracking-[0.08em] text-white transition-colors hover:bg-section-deep-2 disabled:pointer-events-none disabled:opacity-40"
                >
                  {busy === "recall" && <Loader2 size={11} className="animate-spin" />}
                  recallMargin()
                </button>
              </div>
              <p className="mt-2 font-mono text-[10px] leading-[1.6] uppercase tracking-[0.06em] text-white-60/70">
                Receipt ids are not enumerable on-chain and there is no receiptsOf(user), so ids have to
                come from your RedeemRequested / ForceExited event until an indexer exists. A receipt
                that is awaiting settlement is never failed — it stays claimable, and recallMargin is
                permissionless.
              </p>
            </Panel>
          </Stagger>
        </div>
      </div>

      {vault.imgPlaceholder && (
        <p className="mt-4 font-mono text-[10px] uppercase tracking-[0.06em] text-white-60/60">
          {vault.name} has no certificate plate in this build; a neutral mark is used rather than
          another certificate's artwork.
        </p>
      )}
    </div>
  );
}
