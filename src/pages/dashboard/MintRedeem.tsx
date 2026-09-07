import { useEffect, useMemo, useState } from "react";
import { motion } from "framer-motion";
import { Check } from "lucide-react";
import { useDashboard } from "./store";
import type { MintPreset, VaultId } from "./store";
import { Dropdown, MicroLabel, Panel, PulseDot, SegmentedTabs, Stagger, ViewHeader } from "./ui";
import { TxConfirmModal } from "./modals";
import type { QuoteRow } from "./modals";
import { fmtNum, fmtUSD, randHash } from "./format";
import { FLOW_META } from "./flowMeta";
import { cn } from "@/lib/utils";

type Tab = "mint" | "redeem";

/** Outer shell: remounts the form whenever another view requests a preset. */
export default function MintRedeem() {
  const { mintPreset } = useDashboard();
  return <MintRedeemForm key={mintPreset.nonce} preset={mintPreset} />;
}

function MintRedeemForm({ preset }: { preset: MintPreset }) {
  const { vaults, usdc, positions, connected, setWalletModalOpen, mint, redeem, setView } = useDashboard();
  const [tab, setTab] = useState<Tab>(preset.tab);
  const [asset, setAsset] = useState<VaultId>(preset.asset === "uqqq" ? "utsla" : preset.asset);
  const [amountStr, setAmountStr] = useState("");
  const [flicker, setFlicker] = useState(false);
  const [errNonce, setErrNonce] = useState(0);
  const [modalOpen, setModalOpen] = useState(false);
  const [txHash, setTxHash] = useState("");

  const vault = vaults.find((v) => v.id === asset) ?? vaults[0];
  const price = vault.price;
  const meta = FLOW_META[asset];
  const amount = useMemo(() => {
    const n = parseFloat(amountStr);
    return Number.isFinite(n) && n > 0 ? n : 0;
  }, [amountStr]);

  const balance = tab === "mint" ? usdc : positions[asset];
  const fee = tab === "mint" ? amount * 0.001 : amount * price * 0.001;
  const receive = tab === "mint" ? (amount > 0 ? (amount - fee) / price : 0) : amount * price - fee;

  const error =
    amount <= 0
      ? null
      : amount > balance
        ? tab === "mint"
          ? "Insufficient USDC balance"
          : `Insufficient ${meta.name} balance`
        : null;

  const onAmountChange = (v: string) => {
    if (!/^\d*\.?\d*$/.test(v)) return;
    const next = parseFloat(v);
    // shake once when the value first crosses the balance
    if (Number.isFinite(next) && next > balance && amount <= balance) setErrNonce((n) => n + 1);
    setAmountStr(v);
    setFlicker(true);
  };

  // quote recalculation flicker (300ms debounce)
  useEffect(() => {
    if (!flicker) return;
    const t = window.setTimeout(() => setFlicker(false), 300);
    return () => window.clearTimeout(t);
  }, [flicker, amountStr]);

  const openConfirm = () => {
    setTxHash(randHash());
    setModalOpen(true);
  };

  const rows: QuoteRow[] =
    tab === "mint"
      ? [
          { label: "Asset", value: meta.name },
          { label: "You Deposit", value: `${fmtNum(amount)} USDC` },
          { label: "Oracle Price", value: fmtUSD(price) },
          { label: "Mint Fee (10 bps)", value: `${fmtNum(fee)} USDC` },
          { label: "Est. Receive", value: `${receive.toFixed(4)} ${meta.name}`, accent: true },
          { label: "Slippage", value: "0" },
        ]
      : [
          { label: "Asset", value: meta.name },
          { label: "You Burn", value: `${fmtNum(amount, 4)} ${meta.name}` },
          { label: "Oracle Price", value: fmtUSD(price) },
          { label: "Redeem Fee (10 bps)", value: `${fmtNum(fee)} USDC` },
          { label: "Est. Receive", value: `${fmtNum(receive)} USDC`, accent: true },
          { label: "Slippage", value: "0" },
        ];

  const unit = tab === "mint" ? "USDC" : meta.name;

  return (
    <div>
      <ViewHeader
        label="Primary Market"
        title={<>Mint / <span className="text-metallic">Redeem.</span></>}
      />

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
              }}
            />

            <div className="mt-6">
              <MicroLabel className="mb-2 text-[10px]">Asset</MicroLabel>
              <Dropdown
                options={[
                  { value: "utsla", label: "uTSLA · Tesla" },
                  { value: "unvda", label: "uNVDA · Nvidia" },
                  { value: "uspx", label: "uSPX · S&P 500" },
                  { value: "uqqq", label: "uQQQ · Nasdaq 100", disabled: true, hint: "Soon" },
                ]}
                value={asset}
                onChange={(v) => setAsset(v as VaultId)}
              />
            </div>

            <div className="mt-6">
              <div className="flex items-center justify-between">
                <MicroLabel className="text-[10px]">Amount</MicroLabel>
                <button
                  type="button"
                  onClick={() => onAmountChange(balance > 0 ? balance.toFixed(tab === "mint" ? 2 : 4) : "")}
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
              <div className="mt-2 flex items-center justify-between font-mono text-[11px]">
                <span className="text-white-60">
                  Balance: {fmtNum(balance, tab === "mint" ? 2 : 4)} {unit}
                </span>
                {error && <span className="text-warn">{error}</span>}
              </div>
            </div>

            <div className="mt-auto pt-8">
              <span className="block" title={!connected ? `Connect wallet to ${tab}` : error ?? undefined}>
                <button
                  type="button"
                  disabled={connected && (amount <= 0 || !!error)}
                  onClick={() => {
                    if (!connected) {
                      setWalletModalOpen(true);
                      return;
                    }
                    openConfirm();
                  }}
                  className={cn(
                    "w-full bg-green-bright px-8 py-[18px] text-[12px] font-semibold uppercase tracking-[0.08em] text-ink transition-all hover:bg-[#b8d4b4] active:scale-[0.98]",
                    !connected && "opacity-60",
                    connected && (amount <= 0 || !!error) && "pointer-events-none opacity-40",
                  )}
                >
                  {tab === "mint" ? `Mint ${meta.name}` : `Redeem ${meta.name}`}
                </button>
              </span>
              {!connected && (
                <p className="mt-2 text-center font-mono text-[10px] uppercase tracking-[0.08em] text-white-60">
                  Connect wallet to {tab}
                </p>
              )}
            </div>
          </Panel>
        </Stagger>

        {/* Right: live quote */}
        <Stagger index={1}>
          <Panel className={cn("flex h-full flex-col p-5 transition-opacity duration-300 md:p-6", flicker && "opacity-70")}>
            <div className="flex items-center justify-between">
              <MicroLabel>Live Quote · Oracle Price</MicroLabel>
              <PulseDot />
            </div>
            <div className="mt-4 flex flex-col">
              {(tab === "mint"
                ? [
                    ["Oracle Price", fmtUSD(price)],
                    ["You Deposit", `${fmtNum(amount)} USDC`],
                    ["Mint Fee (10 bps)", `${fmtNum(fee)} USDC`],
                    ["Est. Receive", `${receive.toFixed(4)} ${meta.name}`],
                    ["Delta After", "1.000"],
                    ["Settlement", "Same block"],
                  ]
                : [
                    ["Oracle Price", fmtUSD(price)],
                    ["You Burn", `${fmtNum(amount, 4)} ${meta.name}`],
                    ["Redeem Fee", "10 bps"],
                    ["Est. Receive", `${fmtNum(Math.max(0, receive))} USDC`],
                    ["Redemption", "Never gated"],
                    ["Settlement", "Same block"],
                  ]
              ).map(([k, v], i) => (
                <div key={k} className="flex items-center justify-between border-b hairline-dark py-3.5 font-mono text-[13px]">
                  <span className="text-[11px] uppercase tracking-[0.08em] text-white-60">{k}</span>
                  <span className={cn("tabular-nums", i === 3 ? "text-green-bright" : "text-white")}>{v}</span>
                </div>
              ))}
            </div>

            <div className="mt-5 flex items-start gap-2 border hairline-dark bg-[#0d0f0d] p-4">
              <Check size={14} className="mt-0.5 shrink-0 text-green-bright" />
              <p className="font-mono text-[11px] leading-[1.6] text-silver">
                Your certificate is backed by one token's worth of perp exposure plus USDC margin.
              </p>
            </div>

            <p className="mt-4 flex items-center gap-2 font-mono text-[10px] uppercase tracking-[0.06em] text-white-60">
              <PulseDot /> Oracle: CertOracle · updated 2s ago · staleness guard 30s
            </p>
          </Panel>
        </Stagger>
      </div>

      <TxConfirmModal
        open={modalOpen}
        onClose={() => setModalOpen(false)}
        title={tab === "mint" ? `Mint ${meta.name}` : `Redeem ${meta.name}`}
        rows={rows}
        confirmLabel={tab === "mint" ? "Confirm Mint" : "Confirm Redeem"}
        successTitle={tab === "mint" ? "Mint confirmed" : "Redeem confirmed"}
        txHash={txHash}
        onExecute={() => {
          if (tab === "mint") mint(asset, amount, receive);
          else redeem(asset, amount, Math.max(0, receive));
        }}
        onViewActivity={() => {
          setModalOpen(false);
          setView("activity");
        }}
      />
    </div>
  );
}
