import { useEffect, useId, useState } from "react";
import type { ReactNode } from "react";
import { motion } from "framer-motion";
import { ChevronDown } from "lucide-react";
import { capacityLegsLabel, type CapacityView, type DeltaView } from "@/chain/useVaults";
import { EM_DASH, NO_POSITION, fmtAge, fmtNum, fmtUSD } from "./format";
import { cn } from "@/lib/utils";

/* ------------------------------------------------------------ primitives */

export function MicroLabel({ children, className }: { children: ReactNode; className?: string }) {
  return (
    <p className={cn("font-mono text-[11px] uppercase tracking-[0.08em] text-white-60", className)}>
      {children}
    </p>
  );
}

/** Template signature: 5px white corner dots on framed panels. */
export function CornerDots() {
  return (
    <>
      <span className="absolute -left-[3px] -top-[3px] h-[5px] w-[5px] bg-white/70" aria-hidden />
      <span className="absolute -right-[3px] -top-[3px] h-[5px] w-[5px] bg-white/70" aria-hidden />
      <span className="absolute -bottom-[3px] -left-[3px] h-[5px] w-[5px] bg-white/70" aria-hidden />
      <span className="absolute -bottom-[3px] -right-[3px] h-[5px] w-[5px] bg-white/70" aria-hidden />
    </>
  );
}

export function Panel({ children, className, dots = true }: { children: ReactNode; className?: string; dots?: boolean }) {
  return (
    <div className={cn("relative border hairline-dark bg-section-deep-2", className)}>
      {dots && <CornerDots />}
      {children}
    </div>
  );
}

/** Landing-style view header: mono label + cinematic giant headline. */
export function ViewHeader({
  label,
  title,
  right,
  className,
}: {
  label: string;
  title: ReactNode;
  right?: ReactNode;
  className?: string;
}) {
  return (
    <div className={cn("flex flex-wrap items-end justify-between gap-6", className)}>
      <div>
        <MicroLabel>{label}</MicroLabel>
        <motion.h1
          initial={{ opacity: 0, y: 20 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.65, ease: [0.16, 1, 0.3, 1] }}
          className="mt-3 text-[36px] font-semibold uppercase leading-[0.9] tracking-[-0.05em] md:text-[52px]"
        >
          {title}
        </motion.h1>
      </div>
      {right}
    </div>
  );
}

/** Giant outlined ghost word, decorative background type (landing DNA). */
export function GhostWord({ children, className }: { children: ReactNode; className?: string }) {
  return (
    <span
      aria-hidden
      className={cn(
        "pointer-events-none absolute select-none font-semibold uppercase leading-none tracking-[-0.05em] text-transparent",
        className,
      )}
      style={{ WebkitTextStroke: "1px rgba(255,255,255,0.08)" }}
    >
      {children}
    </span>
  );
}

export function PulseDot({ className }: { className?: string }) {
  return (
    <span className={cn("relative inline-flex h-1.5 w-1.5", className)}>
      <span className="absolute inline-flex h-full w-full animate-ping rounded-full bg-green-bright opacity-60" />
      <span className="relative inline-flex h-1.5 w-1.5 rounded-full bg-green-bright" />
    </span>
  );
}

/* ------------------------------------------------------------- count-up */

/** Live number readout: green flash when the value changes. */
export function Flash({ value, format, className }: { value: number; format: (n: number) => string; className?: string }) {
  const [reduced, setReduced] = useState(false);
  useEffect(() => {
    setReduced(window.matchMedia("(prefers-reduced-motion: reduce)").matches);
  }, []);
  const [flash, setFlash] = useState(false);

  // adjust-state-during-render: flip flash on the render where value changes
  const [prev, setPrev] = useState(value);
  if (prev !== value) {
    setPrev(value);
    if (!reduced) setFlash(true);
  }

  useEffect(() => {
    if (!flash) return;
    const t = window.setTimeout(() => setFlash(false), 600);
    return () => window.clearTimeout(t);
  }, [flash]);
  return (
    <span
      className={cn(
        "tabular-nums transition-colors duration-500",
        flash && "bg-green-bright/15 text-green-bright",
        className,
      )}
    >
      {format(value)}
    </span>
  );
}

/* ------------------------------------------------------------- sparkline */

export function Sparkline({ data, className }: { data: number[]; className?: string }) {
  const gid = useId();
  const w = 120;
  const h = 40;
  const min = Math.min(...data);
  const max = Math.max(...data);
  const span = max - min || 1;
  const pts = data
    .map((v, i) => `${((i / (data.length - 1)) * w).toFixed(1)},${(h - 3 - ((v - min) / span) * (h - 6)).toFixed(1)}`)
    .join(" ");
  return (
    <svg viewBox={`0 0 ${w} ${h}`} className={cn("h-10 w-full", className)} preserveAspectRatio="none" aria-hidden>
      <defs>
        <linearGradient id={gid} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%" stopColor="rgba(168,201,164,0.35)" />
          <stop offset="100%" stopColor="rgba(168,201,164,0)" />
        </linearGradient>
      </defs>
      <polygon points={`0,${h} ${pts} ${w},${h}`} fill={`url(#${gid})`} stroke="none" />
      <polyline points={pts} fill="none" stroke="rgba(168,201,164,0.7)" strokeWidth="1" />
    </svg>
  );
}

/* --------------------------------------------------------- segmented tabs */

export function SegmentedTabs<T extends string>({
  options,
  value,
  onChange,
  className,
}: {
  options: { value: T; label: string; disabled?: boolean; title?: string }[];
  value: T;
  onChange: (v: T) => void;
  className?: string;
}) {
  return (
    <div className={cn("inline-flex border hairline-dark", className)}>
      {options.map((o) => (
        <button
          key={o.value}
          type="button"
          disabled={o.disabled}
          title={o.title}
          onClick={() => onChange(o.value)}
          className={cn(
            "px-5 py-2.5 font-mono text-[12px] uppercase tracking-[0.08em] transition-colors",
            value === o.value ? "bg-green-bright text-ink" : "text-white-60 hover:text-white",
            o.disabled && "cursor-not-allowed opacity-40",
          )}
        >
          {o.label}
        </button>
      ))}
    </div>
  );
}

/** Underline tab group (timeframes, filters). */
export function UnderlineTabs<T extends string>({
  options,
  value,
  onChange,
  className,
}: {
  options: { value: T; label: string }[];
  value: T;
  onChange: (v: T) => void;
  className?: string;
}) {
  return (
    <div className={cn("flex items-center gap-5", className)}>
      {options.map((o) => (
        <button
          key={o.value}
          type="button"
          onClick={() => onChange(o.value)}
          className={cn(
            "relative pb-1 font-mono text-[11px] uppercase tracking-[0.08em] transition-colors",
            value === o.value ? "text-white" : "text-white-60 hover:text-white",
          )}
        >
          {o.label}
          <span
            className={cn(
              "absolute bottom-0 left-0 h-px bg-green-bright transition-all duration-300",
              value === o.value ? "w-full" : "w-0",
            )}
          />
        </button>
      ))}
    </div>
  );
}

/* --------------------------------------------------------------- dropdown */

export function Dropdown({
  label,
  options,
  value,
  onChange,
  className,
}: {
  label?: string;
  options: { value: string; label: string; disabled?: boolean; hint?: string }[];
  value: string;
  onChange: (v: string) => void;
  className?: string;
}) {
  const [open, setOpen] = useState(false);
  const selected = options.find((o) => o.value === value);
  return (
    <div className={cn("relative", className)}>
      <button
        type="button"
        onClick={() => setOpen((o) => !o)}
        className="flex w-full items-center justify-between gap-3 border hairline-dark bg-[#0d0f0d] px-4 py-3 font-mono text-[12px] uppercase tracking-[0.08em] text-white"
      >
        <span className="flex items-center gap-2">
          {label && <span className="text-white-60">{label}</span>}
          {selected?.label}
        </span>
        <ChevronDown size={14} className={cn("text-white-60 transition-transform", open && "rotate-180")} />
      </button>
      {open && (
        <>
          <button aria-hidden className="fixed inset-0 z-10 cursor-default" onClick={() => setOpen(false)} />
          <div className="absolute left-0 right-0 z-20 mt-1 border hairline-dark bg-[#0d0f0d]">
            {options.map((o) => (
              <button
                key={o.value}
                type="button"
                disabled={o.disabled}
                title={o.hint}
                onClick={() => {
                  onChange(o.value);
                  setOpen(false);
                }}
                className={cn(
                  "flex w-full items-center justify-between px-4 py-2.5 text-left font-mono text-[12px] uppercase tracking-[0.08em] transition-colors",
                  o.disabled ? "cursor-not-allowed text-white-60/50" : "text-white-60 hover:bg-section-deep-2 hover:text-white",
                  o.value === value && "text-green-bright",
                )}
              >
                {o.label}
                {o.hint && <span className="text-[10px] text-white-60/60">{o.hint}</span>}
              </button>
            ))}
          </div>
        </>
      )}
    </div>
  );
}

/* ------------------------------------------------------------- stat cards */

export function DeltaLine({ value, suffix, invert }: { value: number; suffix?: string; invert?: boolean }) {
  const up = value >= 0;
  const good = invert ? !up : up;
  return (
    <span className={cn("font-mono text-[11px] tracking-[0.04em]", good ? "text-green-bright" : "text-silver")}>
      {up ? "▲" : "▼"} {Math.abs(value).toFixed(2)}
      {suffix ?? "%"} / 24H
    </span>
  );
}

/* ------------------------------------------------------------ honesty bits */

/**
 * What a panel shows when the data does not exist.
 *
 * Used for the 60-point solvency series, the 48 funding bars, the flow list and the 24h
 * change — none of which have an on-chain source. Interpolating them, repeating the
 * current value, or keeping the mock curve would make the dashboard lie about the one
 * thing it exists to prove.
 */
export function EmptyState({
  title,
  detail,
  height,
  className,
}: {
  title: string;
  detail?: ReactNode;
  height?: number;
  className?: string;
}) {
  return (
    <div
      className={cn(
        "flex flex-col items-center justify-center gap-2 border border-dashed border-white/10 px-6 py-10 text-center",
        className,
      )}
      style={height ? { minHeight: height } : undefined}
    >
      <p className="font-mono text-[11px] uppercase tracking-[0.08em] text-white-60">{title}</p>
      {detail && (
        <p className="max-w-[52ch] font-mono text-[10px] leading-[1.7] tracking-[0.04em] text-white-60/70">
          {detail}
        </p>
      )}
    </div>
  );
}

/**
 * The age of the attestation a backing figure rests on.
 *
 * There is no code path in the vault that returns backing without also returning its age,
 * and this component is why: wherever backing is on screen, so is this. Past
 * `maxAgeSec` (300 s) capacity is zero and minting is off, which is the single most likely
 * reason a healthy-looking deployment refuses to mint.
 */
export function AgeLine({
  ageSec,
  stale,
  maxAgeSec,
  batch,
  className,
}: {
  ageSec: number | null;
  stale: boolean;
  maxAgeSec: number;
  batch?: number | null;
  className?: string;
}) {
  const age =
    ageSec === null
      ? "age unknown"
      : ageSec < 90
        ? `proven ${Math.round(ageSec)}s ago`
        : `proven ${Math.floor(ageSec / 60)}m ${Math.round(ageSec % 60)}s ago`;
  return (
    <span
      className={cn(
        "font-mono text-[10px] uppercase tracking-[0.06em]",
        stale ? "text-warn" : "text-white-60",
        className,
      )}
    >
      {ageSec === null ? age : stale ? `${age} · attestation stale (>${maxAgeSec}s) · minting off` : age}
      {batch !== undefined && batch !== null && ageSec !== null ? ` · batch ${batch}` : ""}
    </span>
  );
}

/**
 * Marks a figure that is an attester's claim rather than a measured balance.
 *
 * `accrual18` is relayed by an attester and nothing on-chain verifies it. It shares a
 * screen with `buffer18`, which is the vault's own ERC-20 balance, and the two were one
 * field once — published as "the buffer", measured drifting 100,000.01 against 91,028.00
 * actually held. Different visual register, explicit label.
 */
export function UnverifiedTag({ className }: { className?: string }) {
  return (
    <span
      className={cn(
        "inline-flex items-center gap-1 border border-warn/40 px-1.5 py-px font-mono text-[9px] uppercase tracking-[0.08em] text-warn",
        className,
      )}
      title="Attester-relayed claim. Nothing on-chain verifies this figure, and it is not collateral the vault holds."
    >
      Unverified claim
    </span>
  );
}

/** "price unavailable / minting paused" — a designed oracle state, never a $0.00. */
export function PriceUnavailable({ className }: { className?: string }) {
  return (
    <span
      className={cn("font-mono text-[11px] uppercase tracking-[0.06em] text-warn", className)}
      title="oracle.px() reverted: the feed is stale, deviant or badly fed. Minting is paused; redemption still works."
    >
      Price unavailable · minting paused
    </span>
  );
}

/* ------------------------------------------------- provenance: third class */

/*
 * There are THREE provenance classes on this dashboard, and the flow history introduced
 * the third:
 *
 *   1. CHAIN READ         a guarded view function through wagmi. Ground truth. No tag —
 *                         it is the default register everything else is measured against.
 *   2. ATTESTER CLAIM     relayed into the contract, nothing on-chain verifies it.
 *                         `UnverifiedTag`, in `warn`. (`solvency.accrual18`.)
 *   3. THIRD-PARTY INDEX  an HTTP response from an explorer this project does not run.
 *                         `ExplorerSourcedTag`, below.
 *
 * Class 3 is not class 2 and must not borrow its colour: an explorer-decoded `Minted` log
 * is not somebody's unverified assertion about a balance, it is a real event relayed by a
 * trusted intermediary. It is also not class 1, because the app did not read it from a
 * node. So it gets its own neutral register — silver, not warn, not the plain white the
 * chain reads use.
 */

/**
 * Marks a figure that came from the chain's public block explorer rather than a contract read.
 *
 * See `src/chain/useFlows.ts` for why the flow list can only come from an index at all
 * (receipt ids are not enumerable on-chain) and why a full-history `eth_getLogs` scan is
 * not an option (~104M blocks).
 */
export function ExplorerSourcedTag({ className }: { className?: string }) {
  return (
    <span
      className={cn(
        "inline-flex items-center gap-1 border border-silver/40 px-1.5 py-px font-mono text-[9px] uppercase tracking-[0.08em] text-silver",
        className,
      )}
      title="Decoded from the chain's public Blockscout index over HTTP. The events are real and decoded from the contract ABI, but this is a third-party index, not a chain read performed by this app."
    >
      Explorer index
    </span>
  );
}

/**
 * The prose that has to sit next to an explorer-sourced list.
 *
 * `fetchedAt` is the age of the HTTP response, not the age of an attestation — a different
 * clock from `AgeLine`, which is why this does not reuse it. Both answer "how old is what I
 * am looking at", and neither list should ever be on screen without its answer.
 */
export function ExplorerSourceNote({
  detail,
  url,
  fetchedAt,
  now,
  className,
}: {
  detail: string;
  url: string;
  /** ms epoch of the last successful index read, or `0` when there has not been one. */
  fetchedAt: number;
  /** Wall clock, from the dashboard store, so the age ticks with everything else. */
  now: number;
  className?: string;
}) {
  const ageSec = fetchedAt > 0 ? Math.max(0, (now - fetchedAt) / 1000) : null;
  return (
    <div className={cn("flex flex-col gap-1.5", className)}>
      <div className="flex flex-wrap items-center gap-2">
        <ExplorerSourcedTag />
        <span className="font-mono text-[10px] uppercase tracking-[0.06em] text-white-60">
          {ageSec === null ? "index not read yet" : `index read ${fmtAge(ageSec)}`}
        </span>
      </div>
      <p className="max-w-[86ch] font-mono text-[10px] leading-[1.7] tracking-[0.04em] text-white-60/70">
        {detail}{" "}
        <a
          href={url}
          target="_blank"
          rel="noreferrer noopener"
          className="underline decoration-white/20 underline-offset-2 transition-colors hover:text-green-bright"
        >
          {url.replace(/^https?:\/\//, "")}
        </a>
      </p>
    </div>
  );
}

/**
 * What the flow list renders when the index cannot be read.
 *
 * This component is the reason the feature is worth having. An empty table on a failed
 * HTTP call reads as "you have no activity" — a false statement about somebody's money,
 * produced by a third party being down. So a failure gets a louder register than an empty
 * state, and it names the failure rather than the data.
 */
export function IndexUnavailable({
  message,
  rateLimited,
  onRetry,
  className,
}: {
  message: string;
  rateLimited: boolean;
  onRetry?: () => void;
  className?: string;
}) {
  return (
    <div
      className={cn(
        "flex flex-col items-center justify-center gap-3 border border-dashed border-warn/40 px-6 py-10 text-center",
        className,
      )}
    >
      <p className="font-mono text-[11px] uppercase tracking-[0.08em] text-warn">
        Flow index unavailable — this is not an empty history
      </p>
      <p className="max-w-[62ch] font-mono text-[10px] leading-[1.7] tracking-[0.04em] text-white-60">
        {message} Your mints and redemptions are on chain either way; this app simply could
        not read the explorer index that lists them.{" "}
        {rateLimited
          ? "The index is rate-limiting this browser — wait a moment before retrying."
          : "Retry, or open the vault on the explorer directly."}
      </p>
      {onRetry && (
        <button
          type="button"
          onClick={onRetry}
          className="border border-warn/40 px-5 py-2 font-mono text-[10px] uppercase tracking-[0.08em] text-warn transition-colors hover:bg-warn/10"
        >
          Retry
        </button>
      )}
    </div>
  );
}

/**
 * The last index read failed, but an earlier one succeeded.
 *
 * The sibling of `IndexUnavailable` for the case where there IS a list. Discarding good
 * history because a refresh failed would hide events the user has already been shown;
 * showing it without saying the read failed would imply it is current. So: keep the list,
 * say it may be behind.
 */
export function IndexStaleNotice({
  message,
  onRetry,
  className,
}: {
  message: string;
  onRetry?: () => void;
  className?: string;
}) {
  return (
    <div
      className={cn(
        "flex flex-wrap items-center gap-x-3 gap-y-1 border border-warn/40 px-4 py-2.5",
        className,
      )}
    >
      <span className="font-mono text-[10px] uppercase tracking-[0.08em] text-warn">
        Index read failed — list may be behind
      </span>
      <span className="font-mono text-[10px] tracking-[0.04em] text-white-60">{message}</span>
      {onRetry && (
        <button
          type="button"
          onClick={onRetry}
          className="ml-auto font-mono text-[10px] uppercase tracking-[0.08em] text-warn underline underline-offset-2"
        >
          Retry
        </button>
      )}
    </div>
  );
}

/* ------------------------------------------------------ capacity + delta */

/**
 * The mint-ceiling utilisation bar.
 *
 * This is the ONE bounded capacity indicator on these contracts: it mirrors
 * `CertVault._requireCapacity` (`CertVault.sol:1755-1771`) and therefore hits exactly 100% at
 * the moment `CertVault_AtCapacity` starts firing.
 *
 * It replaces `buffer held / bufferCapacity18()`, which was not an indicator. That ratio is
 * pinned within rounding of 1% at every fill level, because `bufferCapacity18()` is
 * `freeCollateral18() × BUFFER_COVERAGE_MULTIPLE` capped by the ledger's own claim
 * (`CertVault.sol:563-569`) — a notional-exposure CEILING, not headroom — and it RISES as the
 * vault mints, since `_postMargin` retains `1 − targetMarginBps` of every mint as float
 * (`CertVault.sol:1925-1931`). It also overstated the real bound by 111×: $10,000,003 against
 * a binding $90,000 on uTSLA. Pairing it with `hotBuffer()` would have been worse still —
 * `hotBuffer()` is 6-decimal and `bufferCapacity18()` 18-decimal, so that quotient renders
 * 0.0000% forever.
 *
 * A zero cap gets its own rendering rather than a `0 / 0` percentage: it is a real, reachable
 * state that stops every mint (see `CapacityHalt`).
 */
export function CapacityBar({
  view,
  className,
}: {
  view: CapacityView;
  className?: string;
}) {
  const { utilisationPct, used, cap, capIsZero, atCapacity } = view;

  if (capIsZero) {
    return (
      <div className={cn("relative h-6 w-full border border-warn/40 bg-warn/10", className)}>
        <span className="absolute inset-0 flex items-center justify-center font-mono text-[10px] uppercase tracking-[0.08em] text-warn">
          Mint ceiling is 0 — every mint is refused
        </span>
      </div>
    );
  }

  if (utilisationPct === null || used === null || cap === null) {
    // Two different absences, and they must not share a message. `used` needs the oracle
    // price to value the outstanding supply, so a reverted `px()` makes the numerator
    // unmeasurable — that is a designed oracle state, not a read still in flight.
    const oracleBlocked = cap !== null && used === null;
    return (
      <div
        className={cn(
          "relative h-6 w-full border bg-white/5",
          oracleBlocked ? "border-warn/40" : "hairline-dark",
          className,
        )}
      >
        <span
          className={cn(
            "absolute inset-0 flex items-center justify-center font-mono text-[10px] uppercase tracking-[0.08em]",
            oracleBlocked ? "text-warn" : "text-white-60",
          )}
        >
          {oracleBlocked
            ? `Ceiling ${fmtUSD(cap, 2)} · used not measurable while oracle.px() reverts`
            : "Reading capacityOracle.maxNotional18…"}
        </span>
      </div>
    );
  }

  // Clamp the BAR, never the figure: utilisation can exceed 100% when an existing position
  // sits above a cap governance has since lowered, and the label must still say so.
  const barPct = Math.max(0, Math.min(100, utilisationPct));
  return (
    <div
      className={cn(
        "relative h-6 w-full border bg-white/5",
        atCapacity ? "border-warn/40" : "hairline-dark",
        className,
      )}
      title="used / cap, where used = max((totalSupply + pendingMintCerts) × oracle price, attested notional18) and cap = capacityOracle.maxNotional18(vault, bufferCapacity18()). Mirrors CertVault._requireCapacity."
    >
      <div
        className={cn(
          "h-full transition-all duration-500",
          atCapacity ? "bg-warn/60" : "bg-green-bright/60",
        )}
        style={{ width: `${barPct}%` }}
      />
      <span className="absolute inset-0 flex items-center justify-center font-mono text-[10px] uppercase tracking-[0.08em] text-white">
        {fmtNum(utilisationPct, 2)}% of mint ceiling · {fmtUSD(used, 2)} of {fmtUSD(cap, 2)}
      </span>
    </div>
  );
}

/** The binding leg, as one line. The actual diagnostic when a mint is refused. */
export function CapacityLegLine({
  view,
  className,
}: {
  view: CapacityView;
  className?: string;
}) {
  if (view.bindingLegs.length === 0) return null;
  return (
    <p
      className={cn(
        "font-mono text-[10px] uppercase leading-[1.7] tracking-[0.06em]",
        view.capIsZero ? "text-warn" : "text-white-60/70",
        className,
      )}
    >
      Binding leg{view.bindingLegs.length > 1 ? "s" : ""}: {capacityLegsLabel(view.bindingLegs)}.
    </p>
  );
}

/**
 * Why minting is refused when nothing on screen looks wrong — the silent halt.
 *
 * `BufferBook.capacity18` returns 0 whenever `balance18 <= 0` (`BufferBook.sol:183-187`). That
 * forces `bufferCapacity18()` to 0 (`CertVault.sol:563-569`), which forces
 * `CapacityOracle.maxNotional18` to 0 (`CapacityOracle.sol:97`), and `_requireCapacity` then
 * reverts `CertVault_AtCapacity` for EVERY mint — a $100 mint into a vault sitting on $100,000
 * of tUSDG, with a healthy oracle, `mintAllowed() == true` and a fresh attestation. Nothing
 * else on the page moves when this fires, so it has to be said out loud.
 *
 * Renders nothing unless the cap is actually zero.
 */
export function CapacityHalt({
  view,
  bufferHeld,
  className,
}: {
  view: CapacityView;
  /** `solvency.buffer18` — shown beside the ledger to make the gap between them explicit. */
  bufferHeld?: number | null;
  className?: string;
}) {
  if (!view.capIsZero) return null;

  const ledger = view.bufferLedger;
  return (
    <div className={cn("border border-warn/40 bg-[#12120d] p-4", className)}>
      <p className="font-mono text-[11px] uppercase tracking-[0.06em] text-warn">
        Minting halted · mint ceiling is zero
      </p>
      <p className="mt-1 font-mono text-[11px] leading-[1.6] text-white-60">
        capacityOracle.maxNotional18 is 0, so _requireCapacity refuses every mint regardless of
        the collateral this vault holds. Redemption is unaffected: no redemption path reads
        capacity, and forceExit is gated on nothing.
        {view.bindingLegs.length > 0 ? ` Cause: ${capacityLegsLabel(view.bindingLegs)}.` : ""}
      </p>
      {view.bindingLeg === "buffer-ledger-nonpositive" && (
        <p className="mt-2 font-mono text-[10px] uppercase leading-[1.7] tracking-[0.06em] text-white-60/70">
          BufferBook.balance18 is {ledger === null ? EM_DASH : fmtUSD(ledger, 2)}
          {bufferHeld !== null && bufferHeld !== undefined
            ? ` while the vault still holds ${fmtUSD(bufferHeld, 2)} of collateral`
            : ""}
          . The ledger is an accrual claim, not the balance — at or below zero it zeroes the
          ceiling on its own.
        </p>
      )}
    </div>
  );
}

/**
 * `solvency.deltaBps`, rendered as the three things it can actually be.
 *
 * The field is a hedge-to-obligation RATIO in basis points — `notional18 × 10_000 / required`
 * (`CertVault.sol:1600`) — so 10_000 bps is dead centre and 0 is completely unhedged. Stage 2
 * printed the raw bps as "% from target", which inverts it in the worst possible direction:
 * a perfectly hedged vault read "100.00% from target" and the live state right now — an
 * attested notional of $0 against a real obligation, i.e. NO hedge at all — reads a reassuring
 * "0.00%". Two of the three states are sentinels for a zero denominator and are not numbers at
 * all (`CertVault.sol:1491-1508`, `CertVault.sol:1587-1600`).
 */
export function HedgeRatio({
  view,
  className,
}: {
  view: DeltaView | null;
  className?: string;
}) {
  if (view === null) {
    return <span className={cn("text-white-60", className)}>{EM_DASH}</span>;
  }

  if (view.kind === "no-obligation") {
    return (
      <span
        className={cn("text-white-60", className)}
        title="required == 0 and the attested notional is 0: nothing outstanding and nothing hedged. The contract publishes 10_000 bps here as a sentinel so rebalance() reverts CertVault_InBand — it is not a measurement of a position, because there is no position."
      >
        {NO_POSITION}
      </span>
    );
  }

  if (view.kind === "unbounded") {
    return (
      <span
        className={cn("text-warn", className)}
        title="DELTA_UNBOUNDED_BPS (type(uint256).max): a live attested position against a zero obligation. The hedge-to-obligation ratio has no denominator, and this is the worst state the vault can be in — pure unhedged directional risk."
      >
        unbounded · position vs zero obligation
      </span>
    );
  }

  // Under-hedged is the dangerous side, so it is the side that gets the warn colour.
  const tone =
    Math.abs(view.driftPct) <= 1
      ? "text-white"
      : view.driftPct < 0
        ? "text-warn"
        : "text-silver";
  return (
    <span
      className={cn(tone, className)}
      title="notional18 × 10_000 / (supply × oracle price), from solvency(). 100% is at target; below 100% is under-hedged, above is over-hedged."
    >
      {fmtNum(view.hedgeRatioPct, 2)}% of target
      <span className="text-white-60">
        {" "}
        ({view.driftPct >= 0 ? "+" : "−"}
        {fmtNum(Math.abs(view.driftPct), 2)} pts)
      </span>
    </span>
  );
}

/* --------------------------------------------------------- stagger helper */

export function Stagger({ index, children, className }: { index: number; children: ReactNode; className?: string }) {
  return (
    <motion.div
      initial={{ opacity: 0, y: 16 }}
      animate={{ opacity: 1, y: 0 }}
      transition={{ duration: 0.5, delay: index * 0.08, ease: [0.16, 1, 0.3, 1] }}
      className={className}
    >
      {children}
    </motion.div>
  );
}
