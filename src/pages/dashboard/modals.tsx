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
import { CHAIN } from "@/chain/contracts";
import { IS_TESTNET } from "@/chain/deployment";
import { decodeRevert } from "@/chain/useActions";
import {
  TESTNET_MODE_HINT,
  explainChainFailure,
  needsTestnetMode,
} from "@/chain/walletSupport";

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
/**
 * What a connector actually means to someone choosing one.
 *
 * The list previously showed `connector.type` - "injected", "coinbaseWallet" - which is
 * wagmi's internal identifier, not information. The distinction that matters to a user
 * with no wallet installed is whether a choice needs an extension at all.
 */
function connectorHint(c: { id: string; type: string; name: string }): string {
  // What the user must DO outranks the form factor. Phantom reaches chain 46630 only
  // with Testnet Mode on, and nothing here can read that setting - the failure surfaces
  // only after they have approved a connection. One sentence up front saves the round trip.
  if (needsTestnetMode(c)) return TESTNET_MODE_HINT;
  if (c.type === "walletConnect") return "Scan with a mobile wallet";
  if (c.id === "coinbaseWalletSDK" || c.type === "coinbaseWallet") {
    return "Extension, or a passkey - no install needed";
  }
  return "Browser extension";
}

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
      // A wallet that cannot hold chain 46630 fails here with a viem string that says
      // nothing useful ("An error occurred when attempting to switch chain"). Name the
      // actual cause when it is one we understand, and fall back otherwise.
      setFailure(explainChainFailure(err, connector) ?? decodeRevert(err).message);
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
      {/* The footer's non-affiliation notice does NOT render here - the dashboard has its own
          chrome and no footer - so the one screen that actually requests a wallet was the one
          screen without it. Both the reader and an automated wallet-security classifier look at
          the connect prompt, so it belongs in the prompt. Also states the network plainly:
          MetaMask will ask to add chain 46630, and a user who was not told to expect that
          reasonably reads the request as hostile. */}
      <p className="mt-4 font-mono text-[11px] leading-[1.6] text-white-60">
        {IS_TESTNET
          ? `Testnet only, chain ${CHAIN.id} — your wallet will ask to add or switch to it, and no real-world value is at stake.`
          : `${CHAIN.name}, chain ${CHAIN.id} — your wallet will ask to add or switch to it. Real value is at stake here.`}{" "} UseCert is independent and not affiliated with,
        endorsed by, or sponsored by Robinhood Markets, Inc. or any issuer whose ticker a
        certificate mirrors. This prompt requests an address only; every approval you are asked
        for later is for an exact amount, never an unlimited allowance.
      </p>
      <div className="mt-6 flex flex-col gap-px border hairline-dark bg-hairline-dark">
        {connectors.length === 0 && (
          <p className="bg-[#0d0f0d] px-5 py-4 font-mono text-[11px] leading-[1.6] text-white-60">
            No wallet available. Reload, or install a browser wallet that can add a custom network.
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
              <span
                className={cn(
                  "block font-mono text-[11px]",
                  // Not amber: this wallet works, it just needs a setting turned on.
                  // Amber would read as "broken" and send people to a different wallet,
                  // which is the mistake this line previously made in words.
                  needsTestnetMode(c) ? "text-green-bright/80" : "text-white-60",
                )}
              >
                {connectorHint(c)}
              </span>
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
        Chain {chainId} ({CHAIN.name}) only. Mainnet is not offered because nothing is deployed
        there — the chain itself is real and verified (4663, and the venue and USDG are live on
        it), but UseCert has no contracts on it. See deploy/mainnet/4663.plan.json.
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
