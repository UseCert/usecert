import { useEffect, useRef, useState } from "react";
import type { ReactNode } from "react";
import { AnimatePresence, motion } from "framer-motion";
import { Check, Copy, ExternalLink, Loader2, LogOut, X } from "lucide-react";
import { cn } from "@/lib/utils";
import { useDashboard } from "./store";
import { truncHash } from "./format";
import { MicroLabel } from "./ui";

/* ------------------------------------------------------------- modal shell */

export function ModalShell({
  open,
  onClose,
  children,
  wide,
}: {
  open: boolean;
  onClose: () => void;
  children: ReactNode;
  wide?: boolean;
}) {
  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && onClose();
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [open, onClose]);

  return (
    <AnimatePresence>
      {open && (
        <motion.div
          initial={{ opacity: 0 }}
          animate={{ opacity: 1 }}
          exit={{ opacity: 0 }}
          transition={{ duration: 0.25 }}
          className="fixed inset-0 z-[70] flex items-center justify-center p-4"
          style={{ background: "rgba(5,5,5,0.6)", backdropFilter: "blur(18px)" }}
          onClick={onClose}
        >
          <motion.div
            initial={{ opacity: 0, scale: 0.96, y: 12 }}
            animate={{ opacity: 1, scale: 1, y: 0 }}
            exit={{ opacity: 0, scale: 0.96, y: 12 }}
            transition={{ type: "spring", duration: 0.5, bounce: 0.2 }}
            className={cn("relative w-full border hairline-dark bg-[#0d0f0d] p-6 md:p-8", wide ? "max-w-[520px]" : "max-w-[440px]")}
            onClick={(e) => e.stopPropagation()}
          >
            <button
              type="button"
              aria-label="Close"
              onClick={onClose}
              className="absolute right-4 top-4 flex h-9 w-9 items-center justify-center border hairline-dark text-white-60 transition-colors hover:text-white"
            >
              <X size={15} />
            </button>
            {children}
          </motion.div>
        </motion.div>
      )}
    </AnimatePresence>
  );
}

/* ------------------------------------------------------------ wallet modal */

const WALLETS = [
  { name: "Robinhood Wallet", note: "Native on Robinhood Chain" },
  { name: "MetaMask", note: "Browser extension" },
  { name: "WalletConnect", note: "Scan with any mobile wallet" },
];

export function WalletModal() {
  const { walletModalOpen, setWalletModalOpen, connect } = useDashboard();
  const [connecting, setConnecting] = useState<string | null>(null);
  const timer = useRef(0);

  const close = () => {
    window.clearTimeout(timer.current);
    setConnecting(null);
    setWalletModalOpen(false);
  };

  const choose = (name: string) => {
    setConnecting(name);
    timer.current = window.setTimeout(() => {
      connect();
      setConnecting(null);
      setWalletModalOpen(false);
    }, 1200);
  };

  return (
    <ModalShell open={walletModalOpen} onClose={close}>
      <MicroLabel>Connect Wallet</MicroLabel>
      <h3 className="mt-3 text-[28px] font-semibold uppercase leading-none tracking-[-0.03em]">Choose a wallet</h3>
      <div className="mt-6 flex flex-col gap-px border hairline-dark bg-hairline-dark">
        {WALLETS.map((w) => (
          <button
            key={w.name}
            type="button"
            disabled={connecting !== null}
            onClick={() => choose(w.name)}
            className="group flex items-center justify-between bg-[#0d0f0d] px-5 py-4 text-left transition-colors hover:bg-section-deep-2 disabled:opacity-60"
          >
            <span>
              <span className="block text-[15px] font-medium text-white">{w.name}</span>
              <span className="block font-mono text-[11px] text-white-60">{w.note}</span>
            </span>
            {connecting === w.name ? (
              <span className="flex items-center gap-2 font-mono text-[11px] uppercase tracking-[0.08em] text-green-bright">
                <Loader2 size={14} className="animate-spin" /> Connecting…
              </span>
            ) : (
              <span className="h-1.5 w-1.5 rounded-full bg-white-60 transition-colors group-hover:bg-green-bright" />
            )}
          </button>
        ))}
      </div>
      <p className="mt-5 font-mono text-[10px] uppercase leading-[1.6] tracking-[0.06em] text-white-60">
        Demo environment: any wallet connects the same mock account on Robinhood Chain.
      </p>
    </ModalShell>
  );
}

/* ------------------------------------------------------ connected pill + menu */

export function WalletButton() {
  const { connected, address, setWalletModalOpen, disconnect } = useDashboard();
  const [open, setOpen] = useState(false);
  const [copied, setCopied] = useState(false);

  if (!connected) {
    return (
      <button
        type="button"
        onClick={() => setWalletModalOpen(true)}
        className="bg-green-bright px-4 py-2.5 font-mono text-[11px] font-semibold uppercase tracking-[0.08em] text-ink transition-all hover:bg-[#b8d4b4] active:scale-[0.98] md:px-6"
      >
        Connect Wallet
      </button>
    );
  }

  const copy = async () => {
    try {
      await navigator.clipboard.writeText(address);
    } catch {
      /* clipboard unavailable in some contexts */
    }
    setCopied(true);
    window.setTimeout(() => setCopied(false), 1500);
  };

  return (
    <div className="relative">
      <button
        type="button"
        onClick={() => setOpen((o) => !o)}
        className="flex items-center gap-2 rounded-full border hairline-dark bg-section-deep-2 px-4 py-2 font-mono text-[12px] text-white"
      >
        <span className="h-1.5 w-1.5 rounded-full bg-green-bright" />
        {truncHash(address)}
      </button>
      {open && (
        <>
          <button aria-hidden className="fixed inset-0 z-10 cursor-default" onClick={() => setOpen(false)} />
          <div className="absolute right-0 z-20 mt-2 w-56 border hairline-dark bg-[#0d0f0d] py-1">
            <button
              type="button"
              onClick={copy}
              className="flex w-full items-center gap-3 px-4 py-2.5 font-mono text-[12px] uppercase tracking-[0.06em] text-white-60 transition-colors hover:bg-section-deep-2 hover:text-white"
            >
              {copied ? <Check size={14} className="text-green-bright" /> : <Copy size={14} />}
              {copied ? "Copied" : "Copy address"}
            </button>
            <a
              href={`https://explorer.robinhood.com/address/${address}`}
              target="_blank"
              rel="noreferrer"
              className="flex w-full items-center gap-3 px-4 py-2.5 font-mono text-[12px] uppercase tracking-[0.06em] text-white-60 transition-colors hover:bg-section-deep-2 hover:text-white"
            >
              <ExternalLink size={14} /> View on explorer
            </a>
            <button
              type="button"
              onClick={() => {
                disconnect();
                setOpen(false);
              }}
              className="flex w-full items-center gap-3 px-4 py-2.5 font-mono text-[12px] uppercase tracking-[0.06em] text-white-60 transition-colors hover:bg-section-deep-2 hover:text-white"
            >
              <LogOut size={14} /> Disconnect
            </button>
          </div>
        </>
      )}
    </div>
  );
}

/* ---------------------------------------------------------- tx confirm modal */

export interface QuoteRow {
  label: string;
  value: string;
  accent?: boolean;
}

export function TxConfirmModal({
  open,
  onClose,
  title,
  rows,
  confirmLabel,
  successTitle,
  txHash,
  onExecute,
  onViewActivity,
}: {
  open: boolean;
  onClose: () => void;
  title: string;
  rows: QuoteRow[];
  confirmLabel: string;
  successTitle: string;
  txHash: string;
  onExecute: () => void;
  onViewActivity: () => void;
}) {
  const [step, setStep] = useState<"review" | "confirming" | "success">("review");

  // reset to review each time the modal opens (adjust-state-during-render pattern)
  const [prevOpen, setPrevOpen] = useState(open);
  if (open !== prevOpen) {
    setPrevOpen(open);
    if (open) setStep("review");
  }

  const confirm = () => {
    setStep("confirming");
    onExecute();
    window.setTimeout(() => setStep("success"), 1600);
  };

  return (
    <ModalShell open={open} onClose={onClose} wide>
      {step !== "success" ? (
        <>
          <MicroLabel>Order Summary</MicroLabel>
          <h3 className="mt-3 text-[28px] font-semibold uppercase leading-none tracking-[-0.03em]">{title}</h3>
          <div className="mt-6 flex flex-col">
            {rows.map((r) => (
              <div key={r.label} className="flex items-center justify-between border-b hairline-dark py-3 font-mono text-[13px]">
                <span className="text-[11px] uppercase tracking-[0.08em] text-white-60">{r.label}</span>
                <span className={cn("tabular-nums", r.accent ? "text-green-bright" : "text-white")}>{r.value}</span>
              </div>
            ))}
          </div>
          <button
            type="button"
            onClick={confirm}
            disabled={step === "confirming"}
            className="mt-6 flex w-full items-center justify-center gap-2 bg-green-bright px-8 py-[18px] text-[12px] font-semibold uppercase tracking-[0.08em] text-ink transition-all hover:bg-[#b8d4b4] active:scale-[0.98] disabled:opacity-70"
          >
            {step === "confirming" ? (
              <>
                <Loader2 size={14} className="animate-spin" /> Confirming…
              </>
            ) : (
              confirmLabel
            )}
          </button>
        </>
      ) : (
        <div className="flex flex-col items-center py-4 text-center">
          <svg viewBox="0 0 64 64" className="h-16 w-16">
            <motion.circle
              cx="32"
              cy="32"
              r="28"
              fill="none"
              stroke="#a8c9a4"
              strokeWidth="2"
              initial={{ pathLength: 0 }}
              animate={{ pathLength: 1 }}
              transition={{ duration: 0.6, ease: "easeOut" }}
            />
            <motion.path
              d="M20 33 L28 41 L44 24"
              fill="none"
              stroke="#a8c9a4"
              strokeWidth="3"
              strokeLinecap="round"
              strokeLinejoin="round"
              initial={{ pathLength: 0 }}
              animate={{ pathLength: 1 }}
              transition={{ duration: 0.4, delay: 0.5, ease: "easeOut" }}
            />
          </svg>
          <h3 className="mt-5 text-[28px] font-semibold uppercase leading-none tracking-[-0.03em]">{successTitle}</h3>
          <p className="mt-3 font-mono text-[12px] text-white-60">
            TX <span className="text-silver">{truncHash(txHash)}</span> · Robinhood Chain
          </p>
          <div className="mt-7 grid w-full grid-cols-2 gap-3">
            <button
              type="button"
              onClick={onViewActivity}
              className="border hairline-dark px-6 py-3.5 text-[12px] font-semibold uppercase tracking-[0.08em] text-white transition-colors hover:bg-section-deep-2"
            >
              View Activity
            </button>
            <button
              type="button"
              onClick={onClose}
              className="bg-green-bright px-6 py-3.5 text-[12px] font-semibold uppercase tracking-[0.08em] text-ink transition-all hover:bg-[#b8d4b4] active:scale-[0.98]"
            >
              Done
            </button>
          </div>
        </div>
      )}
    </ModalShell>
  );
}
