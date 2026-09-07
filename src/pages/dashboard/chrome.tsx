import { Link } from "@/lib/router-compat";
import { motion } from "framer-motion";
import { ArrowLeftRight, ArrowUpRight, Check, Cpu, Layers, LayoutGrid, List, Shield } from "lucide-react";
import type { LucideIcon } from "lucide-react";
import { cn } from "@/lib/utils";
import { useDashboard } from "./store";
import type { ViewId } from "./store";
import { PulseDot } from "./ui";
import { WalletButton } from "./modals";

const NAV_ITEMS: { id: ViewId; label: string; icon: LucideIcon }[] = [
  { id: "overview", label: "Overview", icon: LayoutGrid },
  { id: "vaults", label: "Vaults", icon: Layers },
  { id: "mint", label: "Mint / Redeem", icon: ArrowLeftRight },
  { id: "staking", label: "Staking", icon: Shield },
  { id: "activity", label: "Activity", icon: List },
  { id: "keepers", label: "Keepers", icon: Cpu },
];

/* ---------------------------------------------------------------- top bar */

export function TopBar() {
  const { block } = useDashboard();
  return (
    <header className="fixed left-0 right-0 top-0 z-40 h-16 border-b hairline-dark bg-abyss/85 backdrop-blur-[12px]">
      <div className="relative flex h-full items-center justify-between gap-4 px-4 md:px-6">
        {/* Left: brand */}
        <div className="flex items-center gap-3">
          <Link to="/" className="flex items-center gap-2.5" aria-label="Back to UseCert home">
            <img src="/logo.png" alt="UseCert monogram" className="h-6 w-6 object-contain" />
            <span className="text-[15px] font-semibold uppercase tracking-[-0.02em] text-white">
              UseCert<sup className="text-[8px] align-super">®</sup>
            </span>
          </Link>
          <span className="hidden h-4 w-px bg-hairline-dark md:block" aria-hidden />
          <span className="hidden font-mono text-[10px] uppercase tracking-[0.08em] text-white-60 md:block">
            Solvency, public every block
          </span>
        </div>

        {/* Center: network chip */}
        <div className="absolute left-1/2 hidden -translate-x-1/2 items-center gap-2 rounded-full border hairline-dark bg-section-deep-2 px-4 py-1.5 lg:flex">
          <PulseDot />
          <span className="font-mono text-[11px] uppercase tracking-[0.08em] text-white-60">
            Robinhood Chain · Mainnet
          </span>
        </div>

        {/* Right: block ticker + wallet */}
        <div className="flex items-center gap-3 md:gap-5">
          <span className="hidden font-mono text-[11px] uppercase tracking-[0.06em] text-silver sm:block">
            BLOCK <span className="tabular-nums text-white">{block.toLocaleString("en-US")}</span>
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

      {/* Giant ghost wordmark, landing-style oversized type */}
      <div className="pointer-events-none relative mt-auto hidden h-40 overflow-hidden xl:block" aria-hidden>
        <span
          className="absolute -bottom-6 left-2 select-none text-[92px] font-semibold uppercase leading-none tracking-[-0.06em] text-transparent"
          style={{ WebkitTextStroke: "1px rgba(255,255,255,0.07)" }}
        >
          UseCert
        </span>
      </div>

      <div className="flex flex-col gap-4 border-t hairline-dark p-4 xl:p-6">
        <div className="hidden items-start gap-2 xl:flex">
          <Check size={13} className="mt-0.5 shrink-0 text-green-bright" />
          <p className="font-mono text-[10px] uppercase leading-[1.6] tracking-[0.06em] text-green-bright">
            Backing ≥ Supply × Price
          </p>
        </div>
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
    <nav className="fixed bottom-0 left-0 right-0 z-40 grid grid-cols-6 border-t hairline-dark bg-abyss/95 backdrop-blur-[12px] md:hidden">
      {NAV_ITEMS.map((item) => {
        const active = view === item.id;
        const Icon = item.icon;
        return (
          <button
            key={item.id}
            type="button"
            onClick={() => setView(item.id)}
            className={cn(
              "relative flex flex-col items-center gap-1 py-2.5 font-mono text-[9px] uppercase tracking-[0.04em]",
              active ? "text-green-bright" : "text-white-60",
            )}
          >
            <span className={cn("absolute left-1/2 top-0 h-[2px] w-8 -translate-x-1/2 bg-green-bright", !active && "hidden")} aria-hidden />
            <Icon size={17} />
            {item.id === "mint" ? "Mint" : item.label}
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
