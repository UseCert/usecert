import { useEffect, useId, useState } from "react";
import type { ReactNode } from "react";
import { motion } from "framer-motion";
import { ChevronDown } from "lucide-react";
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
