import { useMemo, useState } from "react";
import { motion } from "framer-motion";
import { useDashboard } from "./store";
import { MicroLabel, Panel, Stagger, ViewHeader } from "./ui";
import { TxConfirmModal } from "./modals";
import { fmtNum, randHash } from "./format";
import { cn } from "@/lib/utils";

type Tab = "stake" | "unstake";

const FEE_SPLIT = [
  { label: "Buyback", pct: 80, color: "#cad0ca" },
  { label: "Staker Pay", pct: 10, color: "#a8c9a4" },
  { label: "Buffer", pct: 5, color: "#859885" },
  { label: "Treasury", pct: 5, color: "#4c5a4d" },
];

function fmtRemaining(ms: number): string {
  if (ms <= 0) return "Ready";
  const h = Math.floor(ms / 3600000);
  const d = Math.floor(h / 24);
  return `Ready in ${d}d ${h % 24}h`;
}

export default function StakingView() {
  const {
    totalStaked,
    tokenStaked,
    tokenLiquid,
    rewards,
    claim,
    stake,
    unstake,
    cooldowns,
    fastForward,
    withdraw,
    connected,
    setWalletModalOpen,
    now,
    setView,
  } = useDashboard();

  const [tab, setTab] = useState<Tab>("stake");
  const [amountStr, setAmountStr] = useState("");
  const [modalOpen, setModalOpen] = useState(false);
  const [txHash, setTxHash] = useState("");

  const amount = useMemo(() => {
    const n = parseFloat(amountStr);
    return Number.isFinite(n) && n > 0 ? n : 0;
  }, [amountStr]);

  const available = tab === "stake" ? tokenLiquid : tokenStaked;
  const error = amount > 0 && amount > available ? "Insufficient token balance" : null;

  const openConfirm = () => {
    setTxHash(randHash());
    setModalOpen(true);
  };

  return (
    <div>
      {/* Header */}
      <ViewHeader
        className="grid gap-8 lg:grid-cols-2"
        label="Insurance Staking"
        title={<>Holders are <span className="text-metallic">Senior.</span></>}
        right={
        <p className="max-w-[46ch] self-end text-[18px] leading-[1.4] tracking-[-0.02em] text-silver md:text-[20px]">
          Staked tokens underwrite the insurance buffer. Buffer draw beyond threshold slashes staked tokens before it
          ever touches holder backing. In exchange, stakers earn.
        </p>
        }
      />

      {/* Stat row */}
      <div className="mt-8 grid gap-3 md:grid-cols-3">
        <Stagger index={0}>
          <Panel className="p-5">
            <MicroLabel>Total Staked</MicroLabel>
            <p className="mt-2 font-mono text-[30px] tabular-nums leading-none text-white md:text-[36px]">
              {fmtNum(totalStaked / 1e6, 2)}M <span className="text-[14px] text-white-60">token</span>
            </p>
          </Panel>
        </Stagger>
        <Stagger index={1}>
          <Panel className="p-5">
            <MicroLabel>Your Stake</MicroLabel>
            <p className="mt-2 font-mono text-[30px] tabular-nums leading-none text-white md:text-[36px]">
              {fmtNum(tokenStaked)} <span className="text-[14px] text-white-60">token</span>
            </p>
          </Panel>
        </Stagger>
        <Stagger index={2}>
          <Panel className="flex items-center justify-between gap-4 p-5">
            <div>
              <MicroLabel>Rewards Earned</MicroLabel>
              <p className="mt-2 font-mono text-[30px] tabular-nums leading-none text-green-bright md:text-[36px]">
                {fmtNum(rewards)} <span className="text-[14px] text-white-60">token</span>
              </p>
            </div>
            <span title={!connected ? "Connect wallet to claim" : rewards <= 0 ? "No rewards to claim" : undefined}>
              <button
                type="button"
                disabled={connected && rewards <= 0}
                onClick={() => {
                  if (!connected) {
                    setWalletModalOpen(true);
                    return;
                  }
                  claim();
                }}
                className={cn(
                  "bg-green-bright px-5 py-2.5 text-[11px] font-semibold uppercase tracking-[0.08em] text-ink transition-all hover:bg-[#b8d4b4] active:scale-[0.98]",
                  !connected && "opacity-60",
                  connected && rewards <= 0 && "pointer-events-none opacity-40",
                )}
              >
                Claim
              </button>
            </span>
          </Panel>
        </Stagger>
      </div>

      {/* Fee split */}
      <Stagger index={3}>
        <Panel className="mt-3 p-5 md:p-6">
          <MicroLabel>Protocol Fees</MicroLabel>
          <div className="mt-5 flex h-8 w-full overflow-hidden">
            {FEE_SPLIT.map((s, i) => (
              <motion.div
                key={s.label}
                initial={{ width: 0 }}
                animate={{ width: `${s.pct}%` }}
                transition={{ duration: 1, delay: i * 0.15, ease: [0.16, 1, 0.3, 1] }}
                style={{ background: s.color }}
                className="h-full border-r border-abyss last:border-r-0"
              />
            ))}
          </div>
          <div className="mt-3 flex flex-wrap gap-x-6 gap-y-2">
            {FEE_SPLIT.map((s) => (
              <span key={s.label} className="flex items-center gap-2 font-mono text-[11px] uppercase tracking-[0.08em] text-white-60">
                <span className="h-2 w-2" style={{ background: s.color }} aria-hidden />
                {s.pct}% {s.label}
              </span>
            ))}
          </div>
          <p className="mt-4 max-w-[64ch] text-[14px] leading-[1.55] text-white-60">
            Mint and redeem fees plus the funding-surplus share flow to open market token buyback and staker pay.
          </p>
        </Panel>
      </Stagger>

      <div className="mt-3 grid gap-3 lg:grid-cols-2">
        {/* Stake / Unstake form */}
        <Stagger index={4}>
          <Panel className="flex h-full flex-col p-5 md:p-6">
            <div className="inline-flex self-start border hairline-dark">
              {(["stake", "unstake"] as Tab[]).map((t) => (
                <button
                  key={t}
                  type="button"
                  onClick={() => {
                    setTab(t);
                    setAmountStr("");
                  }}
                  className={cn(
                    "px-6 py-2.5 font-mono text-[12px] uppercase tracking-[0.08em] transition-colors",
                    tab === t ? "bg-green-bright text-ink" : "text-white-60 hover:text-white",
                  )}
                >
                  {t}
                </button>
              ))}
            </div>

            <div className="mt-6">
              <div className="flex items-center justify-between">
                <MicroLabel className="text-[10px]">Amount</MicroLabel>
                <button
                  type="button"
                  onClick={() => setAmountStr(available > 0 ? available.toFixed(2) : "")}
                  className="font-mono text-[10px] uppercase tracking-[0.08em] text-green-bright hover:text-white"
                >
                  Max
                </button>
              </div>
              <div className="mt-1 flex items-end gap-3 border-b hairline-dark pb-2 focus-within:border-green-bright">
                <input
                  value={amountStr}
                  onChange={(e) => {
                    const v = e.target.value;
                    if (/^\d*\.?\d*$/.test(v)) setAmountStr(v);
                  }}
                  inputMode="decimal"
                  placeholder="0.00"
                  className="w-full bg-transparent font-mono text-[32px] tabular-nums leading-none text-white outline-none placeholder:text-white-60/40 md:text-[40px]"
                />
                <span className="mb-1 shrink-0 border hairline-dark px-2.5 py-1 font-mono text-[11px] uppercase tracking-[0.06em] text-silver">
                  token
                </span>
              </div>
              <div className="mt-2 flex items-center justify-between font-mono text-[11px]">
                <span className="text-white-60">
                  {tab === "stake" ? `Available: ${fmtNum(tokenLiquid)} token` : `Staked: ${fmtNum(tokenStaked)} token`}
                </span>
                {error && <span className="text-warn">{error}</span>}
              </div>
            </div>

            {tab === "unstake" && (
              <p className="mt-4 font-mono text-[11px] leading-[1.6] text-white-60">
                Unstaking starts a 7-day cooldown. Funds move to your wallet on withdraw.
              </p>
            )}

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
                  {tab === "stake" ? "Stake Token" : "Unstake Token"}
                </button>
              </span>
            </div>
          </Panel>
        </Stagger>

        {/* Cooldowns + slashing honesty */}
        <div className="flex flex-col gap-3">
          <Stagger index={5}>
            <Panel className="p-5 md:p-6">
              <MicroLabel>Cooldowns</MicroLabel>
              {cooldowns.length === 0 ? (
                <p className="mt-4 font-mono text-[12px] text-white-60">No active cooldowns.</p>
              ) : (
                <ul className="mt-4 flex flex-col gap-4">
                  {cooldowns.map((c) => {
                    const progress = c.ready ? 1 : Math.min(1, (now - c.startAt) / (c.readyAt - c.startAt));
                    return (
                      <li key={c.id} className="border hairline-dark bg-[#0d0f0d] p-4">
                        <div className="flex flex-wrap items-center justify-between gap-2 font-mono text-[12px]">
                          <span className="tabular-nums text-white">{fmtNum(c.amount)} token</span>
                          <span className={c.ready ? "text-green-bright" : "text-white-60"}>
                            {c.ready ? "Ready to withdraw" : fmtRemaining(c.readyAt - now)}
                          </span>
                        </div>
                        <div className="mt-3 h-[3px] w-full bg-white/10">
                          <div className="h-full bg-green-bright transition-all duration-1000" style={{ width: `${progress * 100}%` }} />
                        </div>
                        <div className="mt-3 flex items-center gap-4">
                          {!c.ready && (
                            <button
                              type="button"
                              onClick={() => fastForward(c.id)}
                              className="font-mono text-[10px] uppercase tracking-[0.08em] text-green-bright underline decoration-green-bright/40 underline-offset-4 hover:text-white"
                            >
                              Fast-Forward (Demo)
                            </button>
                          )}
                          {c.ready && (
                            <button
                              type="button"
                              onClick={() => withdraw(c.id)}
                              className="bg-green-bright px-4 py-2 text-[10px] font-semibold uppercase tracking-[0.08em] text-ink transition-all hover:bg-[#b8d4b4] active:scale-[0.98]"
                            >
                              Withdraw
                            </button>
                          )}
                        </div>
                      </li>
                    );
                  })}
                </ul>
              )}
            </Panel>
          </Stagger>

          <Stagger index={6}>
            <div className="border hairline-dark border-l-2 border-l-warn bg-[#0d0f0d] p-5 md:p-6">
              <MicroLabel className="text-warn">Named Plainly</MicroLabel>
              <p className="mt-3 text-[14px] leading-[1.6] text-silver">
                If the buffer draws beyond the insurance_draw threshold, staked tokens are slashed to restore it. That
                is the deal stakers are paid for. Holder backing is never touched.
              </p>
            </div>
          </Stagger>
        </div>
      </div>

      <TxConfirmModal
        open={modalOpen}
        onClose={() => setModalOpen(false)}
        title={tab === "stake" ? "Stake Token" : "Unstake Token"}
        rows={[
          { label: "Action", value: tab === "stake" ? "Stake" : "Unstake (7-day cooldown)" },
          { label: "Amount", value: `${fmtNum(amount)} token`, accent: true },
          { label: tab === "stake" ? "Rewards" : "Cooldown", value: tab === "stake" ? "Accrue every block" : "7 days" },
          { label: "Slashing Risk", value: "Stakers absorb first" },
        ]}
        confirmLabel={tab === "stake" ? "Confirm Stake" : "Confirm Unstake"}
        successTitle={tab === "stake" ? "Stake confirmed" : "Unstake confirmed"}
        txHash={txHash}
        onExecute={() => {
          if (tab === "stake") stake(amount);
          else unstake(amount);
        }}
        onViewActivity={() => {
          setModalOpen(false);
          setView("activity");
        }}
      />
    </div>
  );
}
