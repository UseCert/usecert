import { useEffect, useState } from "react";
import type { ReactNode } from "react";
import { AnimatePresence, motion } from "framer-motion";
import { Check, Copy, ExternalLink, Loader2, LogOut, X } from "lucide-react";
import { useConnect, useConnectors } from "wagmi";
import { cn } from "@/lib/utils";
import { useDashboard } from "./store";
import { truncHash } from "./format";
import { MicroLabel } from "./ui";
import { explorerAddressUrl } from "@/chain/config";
import { decodeRevert } from "@/chain/useActions";

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

/**
 * Real wallet connection.
 *
 * The list is `useConnectors()` — whatever the wagmi config actually declares, which here
 * is the injected connector and nothing else. The previous hardcoded three (Robinhood
 * Wallet / MetaMask / WalletConnect) offered choices this build cannot honour, and
 * "any wallet connects the same mock account" is no longer true: this connects a real
 * wallet to chain 46630.
 */
export function WalletModal() {
  const { walletModalOpen, setWalletModalOpen, chainId } = useDashboard();
  const connectors = useConnectors();
  const { mutateAsync: connectAsync, isPending } = useConnect();
  const [pendingId, setPendingId] = useState<string | null>(null);
  const [failure, setFailure] = useState<string | null>(null);

  const close = () => {
    setPendingId(null);
    setFailure(null);
    setWalletModalOpen(false);
  };

  const choose = async (connector: (typeof connectors)[number]) => {
    setPendingId(connector.uid);
    setFailure(null);
    try {
      await connectAsync({ connector, chainId });
      setWalletModalOpen(false);
    } catch (err) {
      setFailure(decodeRevert(err).message);
    } finally {
      setPendingId(null);
    }
  };

  return (
    <ModalShell open={walletModalOpen} onClose={close}>
      <MicroLabel>Connect Wallet</MicroLabel>
      <h3 className="mt-3 text-[28px] font-semibold uppercase leading-none tracking-[-0.03em]">
        Choose a wallet
      </h3>
      <div className="mt-6 flex flex-col gap-px border hairline-dark bg-hairline-dark">
        {connectors.length === 0 && (
          <p className="bg-[#0d0f0d] px-5 py-4 font-mono text-[11px] leading-[1.6] text-white-60">
            No browser wallet detected. Install one that can add a custom network, then reload.
          </p>
        )}
        {connectors.map((c) => (
          <button
            key={c.uid}
            type="button"
            disabled={isPending}
            onClick={() => void choose(c)}
            className="group flex items-center justify-between bg-[#0d0f0d] px-5 py-4 text-left transition-colors hover:bg-section-deep-2 disabled:opacity-60"
          >
            <span>
              <span className="block text-[15px] font-medium text-white">{c.name}</span>
              <span className="block font-mono text-[11px] text-white-60">{c.type}</span>
            </span>
            {pendingId === c.uid ? (
              <span className="flex items-center gap-2 font-mono text-[11px] uppercase tracking-[0.08em] text-green-bright">
                <Loader2 size={14} className="animate-spin" /> Connecting…
              </span>
            ) : (
              <span className="h-1.5 w-1.5 rounded-full bg-white-60 transition-colors group-hover:bg-green-bright" />
            )}
          </button>
        ))}
      </div>
      {failure && <p className="mt-4 font-mono text-[11px] leading-[1.6] text-warn">{failure}</p>}
      <p className="mt-5 font-mono text-[10px] uppercase leading-[1.6] tracking-[0.06em] text-white-60">
        Chain 46630 (Robinhood Chain testnet) only. Mainnet is deliberately not offered: that chain id
        has never been verified from the contracts repo.
      </p>
    </ModalShell>
  );
}

/* ------------------------------------------------------ connected pill + menu */

export function WalletButton() {
  const { connected, address, setWalletModalOpen, disconnect, isConnecting, wrongNetwork } =
    useDashboard();
  const [open, setOpen] = useState(false);
  const [copied, setCopied] = useState(false);

  if (!connected || !address) {
    return (
      <button
        type="button"
        onClick={() => setWalletModalOpen(true)}
        className="bg-green-bright px-4 py-2.5 font-mono text-[11px] font-semibold uppercase tracking-[0.08em] text-ink transition-all hover:bg-[#b8d4b4] active:scale-[0.98] md:px-6"
      >
        {isConnecting ? "Connecting…" : "Connect Wallet"}
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
        <span
          className={cn("h-1.5 w-1.5 rounded-full", wrongNetwork ? "bg-warn" : "bg-green-bright")}
        />
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
              href={explorerAddressUrl(address)}
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

/* The simulated transaction-confirmation modal that used to live here is gone.
 * It displayed a `randHash()` transaction id and a green "confirmed" checkmark for a
 * transaction that was never submitted, and its only caller was the deleted staking view.
 * Real submissions report through the toast stack and the explorer link instead. */
