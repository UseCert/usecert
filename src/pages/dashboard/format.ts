/** Formatting helpers for the dashboard. */

/** What a missing figure looks like. Never a zero, never a placeholder value. */
export const EM_DASH = "—";

/**
 * What a ratio looks like when its denominator does not exist.
 *
 * A bare em-dash is right for a missing INPUT but too quiet for a missing DENOMINATOR: the
 * reader can see the inputs on the same screen and will assume the app simply failed to divide
 * them. Saying "no position" instead answers the question the blank raises. A mirror with no
 * supply attests `notional18 == 0`, which is the arrival state of every newly deployed mirror,
 * so this is the live state of most attested ratios on the dashboard.
 */
export const NO_POSITION = "n/a — no position";

/**
 * The only way a number should reach the screen.
 *
 * Every figure on the live model is nullable, because plenty of them have no on-chain
 * source and `VaultId` admits ids with no contracts at all. Passing the value through here
 * means an absent figure renders as an em-dash instead of a confident `$0.00`.
 */
export function fmtOrDash(value: number | null | undefined, format: (n: number) => string): string {
  return value === null || value === undefined ? EM_DASH : format(value);
}

/**
 * Seconds → an age phrase. Used for `ageSec`, which must be on screen wherever backing
 * is: a solvency figure with no age is the claim this project spent the most effort not
 * making.
 */
export function fmtAge(sec: number | null | undefined): string {
  if (sec === null || sec === undefined) return EM_DASH;
  if (sec < 0) return EM_DASH;
  if (sec < 90) return `${Math.round(sec)}s ago`;
  const m = Math.floor(sec / 60);
  if (m < 60) return `${m}m ${Math.round(sec % 60)}s ago`;
  const h = Math.floor(m / 60);
  if (h < 24) return `${h}h ${m % 60}m ago`;
  return `${Math.floor(h / 24)}d ${h % 24}h ago`;
}

/** Seconds → a countdown, for the faucet cooldown. */
export function fmtCountdown(sec: number): string {
  if (sec <= 0) return "now";
  const h = Math.floor(sec / 3600);
  const m = Math.floor((sec % 3600) / 60);
  const s = Math.floor(sec % 60);
  if (h > 0) return `${h}h ${String(m).padStart(2, "0")}m`;
  if (m > 0) return `${m}m ${String(s).padStart(2, "0")}s`;
  return `${s}s`;
}

/**
 * A ratio the app computed itself → a percent string, or a reason it could not be computed.
 *
 * The counterpart to `fmtOrDash` for QUOTIENTS. `fmtOrDash` covers a figure that was never
 * read; this covers a figure that could not be derived because its denominator was zero or
 * absent — which is the failure stage 2 left open, since nulling the inputs does not null what
 * is divided by them.
 */
export function fmtRatioOrNoPosition(pct: number | null | undefined, decimals = 2): string {
  return pct === null || pct === undefined ? NO_POSITION : `${fmtNum(pct, decimals)}%`;
}

export function fmtNum(n: number, decimals = 2): string {
  return n.toLocaleString("en-US", {
    minimumFractionDigits: decimals,
    maximumFractionDigits: decimals,
  });
}

export function fmtUSD(n: number, decimals = 2): string {
  return `$${fmtNum(n, decimals)}`;
}

/** Compact USD for axis labels and big stats: $58.2M / $612K / $1,240 */
export function fmtCompactUSD(n: number): string {
  const abs = Math.abs(n);
  if (abs >= 1e9) return `$${(n / 1e9).toFixed(2)}B`;
  if (abs >= 1e6) return `$${(n / 1e6).toFixed(2)}M`;
  if (abs >= 1e3) return `$${(n / 1e3).toFixed(0)}K`;
  return `$${n.toFixed(0)}`;
}

export function timeAgo(ts: number, now = Date.now()): string {
  const s = Math.max(0, Math.floor((now - ts) / 1000));
  if (s < 5) return "just now";
  if (s < 60) return `${s}s ago`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}m ago`;
  const h = Math.floor(m / 60);
  if (h < 24) return `${h}h ago`;
  const d = Math.floor(h / 24);
  return `${d}d ago`;
}

export function truncHash(hash: string): string {
  return `${hash.slice(0, 6)}…${hash.slice(-4)}`;
}

/* Two generators used to live here and both are gone.
 *
 * `mulberry32` (a seeded PRNG) existed only to generate the mock solvency curves, funding
 * bars and flow list, all of which are now read from chain or rendered as an honest empty
 * state. `randHash()` minted a plausible-looking 0x transaction id for transactions that
 * were never submitted; its only caller was the simulated staking flow, which is gone too.
 *
 * Do not reintroduce either. A hash on screen must come from a real receipt, and a number
 * on screen must come from a contract read. */
