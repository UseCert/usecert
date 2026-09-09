import { useEffect, useMemo, useRef, useState } from "react";
import { AnimatePresence, motion } from "framer-motion";
import { ArrowLeftRight, Layers, LayoutGrid, List, Search, ShieldAlert, Wallet } from "lucide-react";
import type { LucideIcon } from "lucide-react";
import { cn } from "@/lib/utils";
import { useDashboard } from "./store";
import type { VaultId, ViewId } from "./store";

interface Cmd {
  id: string;
  label: string;
  hint: string;
  group: "Navigate" | "Actions" | "Vaults";
  icon: LucideIcon;
  run: () => void;
}

/**
 * Enterprise command palette (⌘K / Ctrl-K): jump to any view, vault or action
 * without leaving the keyboard.
 */
export default function CommandPalette() {
  const { setView, goVault, goMint, vaults, connected, setWalletModalOpen, disconnect } = useDashboard();
  const [open, setOpen] = useState(false);
  const [q, setQ] = useState("");
  const [active, setActive] = useState(0);
  const inputRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key.toLowerCase() === "k" && (e.metaKey || e.ctrlKey)) {
        e.preventDefault();
        setOpen((o) => !o);
      }
      if (e.key === "Escape") setOpen(false);
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  useEffect(() => {
    if (open) {
      setQ("");
      setActive(0);
      window.setTimeout(() => inputRef.current?.focus(), 40);
    }
  }, [open]);

  const commands = useMemo<Cmd[]>(() => {
    const nav: { id: ViewId; label: string; icon: LucideIcon }[] = [
      { id: "overview", label: "Overview", icon: LayoutGrid },
      { id: "vaults", label: "Vaults", icon: Layers },
      { id: "mint", label: "Mint / Redeem", icon: ArrowLeftRight },
      { id: "activity", label: "Activity", icon: List },
      { id: "risk", label: "Risk & Parameters", icon: ShieldAlert },
    ];
    const list: Cmd[] = nav.map((n) => ({
      id: `nav-${n.id}`,
      label: n.label,
      hint: "Go to",
      group: "Navigate",
      icon: n.icon,
      run: () => setView(n.id),
    }));

    vaults
      .filter((v) => v.status === "LIVE")
      .forEach((v) => {
        list.push({
          id: `vault-${v.id}`,
          label: `${v.name} - ${v.full}`,
          hint: "Open vault",
          group: "Vaults",
          icon: Layers,
          run: () => goVault(v.id as VaultId),
        });
        list.push({
          id: `mint-${v.id}`,
          label: `Mint ${v.name}`,
          hint: "New position",
          group: "Actions",
          icon: ArrowLeftRight,
          run: () => goMint("mint", v.id as VaultId),
        });
        list.push({
          id: `redeem-${v.id}`,
          label: `Redeem ${v.name}`,
          hint: "Close position",
          group: "Actions",
          icon: ArrowLeftRight,
          run: () => goMint("redeem", v.id as VaultId),
        });
      });

    list.push({
      id: "wallet",
      label: connected ? "Disconnect wallet" : "Connect wallet",
      hint: "Wallet",
      group: "Actions",
      icon: Wallet,
      run: () => (connected ? disconnect() : setWalletModalOpen(true)),
    });

    return list;
  }, [vaults, connected, setView, goVault, goMint, disconnect, setWalletModalOpen]);

  const results = useMemo(() => {
    const term = q.trim().toLowerCase();
    if (!term) return commands;
    return commands.filter((c) => `${c.label} ${c.group} ${c.hint}`.toLowerCase().includes(term));
  }, [q, commands]);

  const run = (cmd: Cmd | undefined) => {
    if (!cmd) return;
    cmd.run();
    setOpen(false);
  };

  const onInputKey = (e: React.KeyboardEvent) => {
    if (e.key === "ArrowDown") {
      e.preventDefault();
      setActive((a) => Math.min(a + 1, results.length - 1));
    } else if (e.key === "ArrowUp") {
      e.preventDefault();
      setActive((a) => Math.max(a - 1, 0));
    } else if (e.key === "Enter") {
      e.preventDefault();
      run(results[active]);
    }
  };

  let lastGroup = "";

  return (
    <>
      {/* Global trigger for pointer users lives in the top bar; this is the sheet. */}
      <AnimatePresence>
        {open && (
          <motion.div
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            exit={{ opacity: 0 }}
            transition={{ duration: 0.2 }}
            className="fixed inset-0 z-[80] flex items-start justify-center p-4 pt-[12vh]"
            style={{ background: "rgba(5,5,5,0.6)", backdropFilter: "blur(18px)" }}
            onClick={() => setOpen(false)}
          >
            <motion.div
              initial={{ opacity: 0, y: -12, scale: 0.98 }}
              animate={{ opacity: 1, y: 0, scale: 1 }}
              exit={{ opacity: 0, y: -12, scale: 0.98 }}
              transition={{ type: "spring", duration: 0.4, bounce: 0.15 }}
              onClick={(e) => e.stopPropagation()}
              className="w-full max-w-[560px] border hairline-dark bg-[#0d0f0d]"
            >
              <div className="flex items-center gap-3 border-b hairline-dark px-4 py-3.5">
                <Search size={15} className="shrink-0 text-white-60" />
                <input
                  ref={inputRef}
                  value={q}
                  onChange={(e) => {
                    setQ(e.target.value);
                    setActive(0);
                  }}
                  onKeyDown={onInputKey}
                  placeholder="Search views, vaults and actions…"
                  className="min-w-0 flex-1 bg-transparent font-mono text-[13px] text-white outline-none placeholder:text-white-60/60"
                />
                <span className="hidden shrink-0 border hairline-dark px-2 py-0.5 font-mono text-[10px] uppercase tracking-[0.08em] text-white-60 sm:block">
                  Esc
                </span>
              </div>

              <div className="max-h-[52vh] overflow-y-auto py-1">
                {results.length === 0 && (
                  <p className="px-4 py-6 text-center font-mono text-[11px] uppercase tracking-[0.08em] text-white-60">
                    No matches
                  </p>
                )}
                {results.map((c, i) => {
                  const Icon = c.icon;
                  const header = c.group !== lastGroup ? c.group : null;
                  lastGroup = c.group;
                  return (
                    <div key={c.id}>
                      {header && (
                        <p className="px-4 pb-1 pt-3 font-mono text-[10px] uppercase tracking-[0.1em] text-white-60/70">{header}</p>
                      )}
                      <button
                        type="button"
                        onMouseEnter={() => setActive(i)}
                        onClick={() => run(c)}
                        className={cn(
                          "flex w-full items-center gap-3 px-4 py-2.5 text-left font-mono text-[12px] transition-colors",
                          i === active ? "bg-section-deep-2 text-white" : "text-white-60",
                        )}
                      >
                        <Icon size={14} className={cn("shrink-0", i === active && "text-green-bright")} />
                        <span className="min-w-0 flex-1 truncate">{c.label}</span>
                        <span className="shrink-0 text-[10px] uppercase tracking-[0.08em] text-white-60/60">{c.hint}</span>
                      </button>
                    </div>
                  );
                })}
              </div>

              <div className="flex items-center justify-between gap-3 border-t hairline-dark px-4 py-2.5 font-mono text-[10px] uppercase tracking-[0.08em] text-white-60/70">
                <span>↑ ↓ to move · ↵ to run</span>
                <span className="hidden sm:block">Robinhood Chain · Testnet 46630</span>
              </div>
            </motion.div>
          </motion.div>
        )}
      </AnimatePresence>
    </>
  );
}

/** Top-bar affordance that opens the palette via the same keyboard shortcut. */
export function CommandTrigger({ className }: { className?: string }) {
  const fire = () => {
    window.dispatchEvent(
      new KeyboardEvent("keydown", { key: "k", metaKey: true, bubbles: true, cancelable: true }),
    );
  };
  return (
    <button
      type="button"
      onClick={fire}
      aria-label="Open command palette"
      className={cn(
        "flex items-center gap-2 border hairline-dark px-3 py-2 font-mono text-[11px] uppercase tracking-[0.08em] text-white-60 transition-colors hover:border-green-bright/40 hover:text-white",
        className,
      )}
    >
      <Search size={13} />
      <span className="hidden lg:block">Search</span>
      <span className="hidden border hairline-dark px-1.5 py-px text-[9px] lg:block">⌘K</span>
    </button>
  );
}
