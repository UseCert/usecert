import { Link } from "@/lib/router-compat";
import { motion } from "framer-motion";
import { ArrowLeftRight, ArrowUpRight, Layers, LayoutGrid, List, Shield, ShieldAlert } from "lucide-react";
import type { LucideIcon } from "lucide-react";
import { cn } from "@/lib/utils";
import { useDashboard } from "./store";
import type { ViewId } from "./store";
import { PulseDot } from "./ui";
import { WalletButton } from "./modals";
import { CommandTrigger } from "./CommandPalette";
import { LanguageSwitcher } from "@/i18n";

/* Keepers stays removed: no keeper-rewards mechanism is deployed, and that screen ran on
 * invented figures. Insurance came back on 2026-09-26 with the pool actually deployed
 * (InsuranceStaking, 0xDbdA…dAFb1): every figure on it is a chain read of that contract. */
const NAV_ITEMS: { id: ViewId; label: string; short: string; icon: LucideIcon }[] = [
  { id: "overview", label: "Overview", short: "Home", icon: LayoutGrid },
  { id: "vaults", label: "Vaults", short: "Vaults", icon: Layers },
  { id: "mint", label: "Mint / Redeem", short: "Mint", icon: ArrowLeftRight },
  { id: "activity", label: "Activity", short: "Flows", icon: List },
  { id: "risk", label: "Risk & Parameters", short: "Risk", icon: ShieldAlert },
  { id: "stake", label: "Insurance", short: "Insure", icon: Shield },
];

/* ---------------------------------------------------------------- top bar */

export function TopBar() {
  const { block, blockKnown, totals, isError, maxAttestationAgeSec, signer } = useDashboard();
  // No data is not "healthy" and it is not "degraded" either — it is unknown, and the
  // chip says so rather than asserting either one.
  //
  // `totals.ratio` is now `null` when the attested notional is zero, which is the arrival
  // state of every mirror with no supply. That is a FOURTH state and it gets its own label:
  // the old expression was `totals.ratio >= 100`, and against the previous unguarded ratio —
  // margin over a denominator clamped to $1 — a vault with no attested position at all sailed
  // past 100% and published "Attested backing holds". Nothing was attested. It cannot hold.
  //
  // `backingRatio` needs the SAME treatment and did not have it. It is `null` only when no
  // mirror published a point; when the obligation is ZERO — every routed vault at zero supply,
  // which is exactly how uQQQ and uNVDA arrived — `aggregateTotals` returns
  // `POSITIVE_INFINITY` to mean "nothing is owed, so nothing can be short". That is not `null`,
  // so it walked straight into `>= 100` and published a green "Attested backing holds" over a
  // ratio that was never computed. Nothing is owed and nothing is proven; the honest chip is
  // the "no attested position" one, which is why the non-finite case is routed there.
  /** `backingRatio` only when it is an actual measurement. `null` covers both absences. */
  const measuredBackingRatio =
    totals !== null && totals.backingRatio !== null && Number.isFinite(totals.backingRatio)
      ? totals.backingRatio
      : null;
  // An aged attestation is NOT degradation under on-demand attestation - it is what an
  // idle protocol looks like, and a mint refreshes it in its own transaction. Treating it
  // as a fault published "Degraded" continuously over a working system (230,019s on chain
  // against an 11s-old signature at the time this was fixed), which trains a reader to
  // ignore the chip entirely. What IS degradation is an aged attestation that nothing can
  // refresh, so staleness only counts when the signer is known to be down.
  const staleAndUnrefreshable = Boolean(totals?.anyStale) && signer.available === false;
  const status: "unknown" | "no-position" | "healthy" | "degraded" = isError
    ? "degraded"
    : totals === null
      ? "unknown"
      : staleAndUnrefreshable || totals.anyPriceUnavailable
        ? "degraded"
        : measuredBackingRatio === null
          ? "no-position"
          : // Solvency = backing covers the obligation. NOT `ratio >= 100`: `ratio` is margin
            // over hedge notional, which sits at targetMarginBps (90% here) by design, so that
            // test published "Degraded" on a correctly configured vault - live mirrors read
            // 91.11% while every real health signal was green.
            measuredBackingRatio >= 100
            ? "healthy"
            : "degraded";
  return (
    <header className="fixed left-0 right-0 top-0 z-40 h-16 border-b hairline-dark bg-abyss/85 backdrop-blur-[12px]">
      <div className="relative grid h-full grid-cols-[minmax(0,1fr)_auto] items-center gap-3 px-4 md:px-6">
        {/* Left: brand + system status */}
        <div className="flex min-w-0 items-center gap-3">
          <Link to="/" className="flex shrink-0 items-center gap-2.5" aria-label="Back to UseCert home">
            <img src="/logo.png" alt="UseCert monogram" className="h-6 w-6 object-contain" />
            <span className="text-[15px] font-semibold uppercase tracking-[-0.02em] text-white">
              UseCert<sup className="text-[8px] align-super">®</sup>
            </span>
          </Link>
          <span className="hidden h-4 w-px bg-hairline-dark md:block" aria-hidden />
          <span
            className={cn(
              "hidden shrink-0 items-center gap-2 rounded-full border px-3 py-1 font-mono text-[10px] uppercase tracking-[0.08em] md:flex",
              status === "healthy"
                ? "border-green-bright/40 text-green-bright"
                : status === "degraded"
                  ? "border-warn/40 text-warn"
                  : "border-white/20 text-white-60",
            )}
          >
            <PulseDot />{" "}
            {status === "healthy"
              ? "Attested backing holds"
              : status === "degraded"
                ? // Name the one that is actually broken. "Check age and oracle" sent readers
                  // to look at an age that was working as designed.
                  staleAndUnrefreshable
                  ? "Degraded · attester not serving"
                  : "Degraded · check oracle"
                : status === "no-position"
                  ? "No attested position"
                  : "Reading chain…"}
          </span>
          {/* Leads with the figure the chip's own claim rests on - backing over obligation -
              and keeps margin/notional beside it as the hedge-margin reading it actually is.
              Showing only margin/notional here left "Attested backing holds" sitting next to
              91.11%, which reads as a contradiction rather than as support.

              Both are attester-relayed, so the age travels with them. A backing figure with no
              age is the claim this project spent the most effort not making. */}
          <span className="hidden truncate font-mono text-[10px] uppercase tracking-[0.08em] text-white-60 xl:block">
            {totals === null
              ? "Backing / obligation —"
              : `Backing / obligation ${
                  totals.backingRatio === null
                    ? "—"
                    : Number.isFinite(totals.backingRatio)
                      ? `${totals.backingRatio.toFixed(2)}%`
                      : "no obligation"
                } · margin / notional ${
                  totals.ratio === null ? "n/a (attested notional $0)" : `${totals.ratio.toFixed(2)}%`
                } · proven ${Math.round(totals.worstAgeSec)}s ago${
                  !totals.anyStale
                    ? ""
                    : signer.available === false
                      ? ` · >${maxAttestationAgeSec}s and no attester`
                      : ` · >${maxAttestationAgeSec}s · a mint refreshes it`
                }`}
          </span>
        </div>

        {/* Right: search + block ticker + wallet */}
        <div className="flex shrink-0 items-center gap-2 md:gap-4">
          <LanguageSwitcher className="shrink-0" />
          <CommandTrigger className="hidden sm:flex" />
          <span className="hidden font-mono text-[11px] uppercase tracking-[0.06em] text-silver md:block">
            BLOCK{" "}
            <span className="tabular-nums text-white">
              {blockKnown ? block.toLocaleString("en-US") : "—"}
            </span>
          </span>
          <WalletButton />
        </div>
      </div>
    </header>
  );
}

/* ---------------------------------------------------------------- sidebar */

export function Sidebar() {
  const { view, setView } = useDashboard();
  return (
    <aside className="fixed bottom-0 left-0 top-16 z-40 hidden w-16 flex-col border-r hairline-dark bg-abyss md:flex xl:w-60">
      <nav className="flex flex-col gap-1 px-2 pt-8 xl:px-0">
        {NAV_ITEMS.map((item, i) => {
          const active = view === item.id;
          const Icon = item.icon;
          return (
            <motion.button
              key={item.id}
              type="button"
              initial={{ opacity: 0, x: -12 }}
              animate={{ opacity: 1, x: 0 }}
              transition={{ duration: 0.4, delay: i * 0.05 }}
              onClick={() => setView(item.id)}
              className={cn(
                "group relative flex items-center gap-3 px-3 py-3 text-left font-mono text-[12px] uppercase tracking-[0.08em] transition-colors xl:pl-6",
                active ? "bg-section-deep-2 text-white" : "text-white-60 hover:bg-section-deep hover:text-white",
              )}
              title={item.label}
            >
              <span
                className={cn(
                  "absolute left-0 top-0 h-full w-[2px] bg-green-bright transition-transform duration-250",
                  active ? "scale-y-100" : "scale-y-0 group-hover:scale-y-50",
                )}
                aria-hidden
              />
              <Icon size={17} className={cn("shrink-0", active && "text-green-bright")} />
              <span className="hidden xl:block">{item.label}</span>
              <span className={cn("ml-auto hidden text-[10px] xl:block", active ? "text-green-bright" : "text-white-60/50")}>
                /{String(i + 1).padStart(2, "0")}
              </span>
            </motion.button>
          );
        })}
      </nav>

      <div className="mt-auto flex flex-col gap-4 border-t hairline-dark p-4 xl:p-6">
        <Link
          to="/"
          className="flex items-center justify-center gap-1.5 font-mono text-[11px] uppercase tracking-[0.08em] text-white-60 transition-colors hover:text-green-bright xl:justify-start"
          title="Back to site"
        >
          <span className="hidden xl:block">Back to site</span>
          <ArrowUpRight size={14} />
        </Link>
      </div>
    </aside>
  );
}

/* --------------------------------------------------------- mobile tab bar */

export function BottomTabs() {
  const { view, setView } = useDashboard();
  return (
    <nav className="fixed bottom-0 left-0 right-0 z-40 grid grid-cols-5 border-t hairline-dark bg-abyss/95 pb-[env(safe-area-inset-bottom)] backdrop-blur-[12px] md:hidden">
      {NAV_ITEMS.map((item) => {
        const active = view === item.id;
        const Icon = item.icon;
        return (
          <button
            key={item.id}
            type="button"
            onClick={() => setView(item.id)}
            className={cn(
              "relative flex flex-col items-center gap-1 px-0.5 py-2.5 font-mono text-[8.5px] uppercase tracking-[0.02em]",
              active ? "text-green-bright" : "text-white-60",
            )}
          >
            <span className={cn("absolute left-1/2 top-0 h-[2px] w-7 -translate-x-1/2 bg-green-bright", !active && "hidden")} aria-hidden />
            <Icon size={16} />
            {item.short}
          </button>
        );
      })}
    </nav>
  );
}

/* -------------------------------------------------------------- footer bar */

export function FooterBar() {
  return (
    <footer className="mt-16 flex flex-col items-center justify-between gap-3 border-t hairline-dark py-6 font-mono text-[10px] uppercase tracking-[0.08em] text-white-60 md:flex-row">
      <span>© 2026 UseCert®</span>
      <span className="text-center">UseCert is infrastructure, not investment advice.</span>
      <span className="flex items-center gap-4">
        <Link to="/legal/privacy-policy" className="transition-colors hover:text-white">
          Privacy
        </Link>
        <span>/</span>
        <Link to="/legal/terms-of-service" className="transition-colors hover:text-white">
          Terms
        </Link>
      </span>
    </footer>
  );
}
