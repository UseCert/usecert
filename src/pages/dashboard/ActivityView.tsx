import { useMemo, useState } from "react";
import { AnimatePresence, motion } from "framer-motion";
import { Check } from "lucide-react";
import { useDashboard } from "./store";
import type { FlowType, VaultId } from "./store";
import { Dropdown, Panel, UnderlineTabs, ViewHeader } from "./ui";
import { fmtNum, fmtUSD, timeAgo, truncHash } from "./format";
import { FlowTypeBadge } from "./flows";
import { flowVaultLabel } from "./flowMeta";
import { cn } from "@/lib/utils";

type TypeFilter = "ALL" | "MINT" | "REDEEM" | "STAKE" | "CLAIM";

const TYPE_TABS: { value: TypeFilter; label: string }[] = [
  { value: "ALL", label: "All" },
  { value: "MINT", label: "Mints" },
  { value: "REDEEM", label: "Redeems" },
  { value: "STAKE", label: "Stakes" },
  { value: "CLAIM", label: "Claims" },
];

const TYPE_MATCH: Record<TypeFilter, FlowType[]> = {
  ALL: ["MINT", "REDEEM", "STAKE", "UNSTAKE", "CLAIM", "WITHDRAW"],
  MINT: ["MINT"],
  REDEEM: ["REDEEM"],
  STAKE: ["STAKE", "UNSTAKE", "WITHDRAW"],
  CLAIM: ["CLAIM"],
};

function TxCell({ hash }: { hash: string }) {
  const [copied, setCopied] = useState(false);
  return (
    <button
      type="button"
      title={copied ? "Copied" : "Click to copy"}
      onClick={async () => {
        try {
          await navigator.clipboard.writeText(hash);
        } catch {
          /* noop */
        }
        setCopied(true);
        window.setTimeout(() => setCopied(false), 1500);
      }}
      className={cn("flex items-center gap-1.5 font-mono text-[12px] transition-colors", copied ? "text-green-bright" : "text-white-60 hover:text-white")}
    >
      {copied && <Check size={11} />}
      {copied ? "Copied" : truncHash(hash)}
    </button>
  );
}

export default function ActivityView() {
  const { flows, loadMoreFlows } = useDashboard();
  const [typeFilter, setTypeFilter] = useState<TypeFilter>("ALL");
  const [assetFilter, setAssetFilter] = useState<string>("all");

  const filtered = useMemo(
    () =>
      flows.filter((f) => {
        if (!TYPE_MATCH[typeFilter].includes(f.type)) return false;
        if (assetFilter === "all") return true;
        if (assetFilter === "token") return f.vault === "token";
        return f.vault === (assetFilter as VaultId);
      }),
    [flows, typeFilter, assetFilter],
  );

  return (
    <div>
      <ViewHeader
        label="Protocol Flows"
        title={<>Every Flow, <span className="text-metallic">On Chain.</span></>}
      />

      <div className="mt-8 flex flex-wrap items-center justify-between gap-4">
        <UnderlineTabs options={TYPE_TABS} value={typeFilter} onChange={setTypeFilter} />
        <Dropdown
          className="w-[190px]"
          options={[
            { value: "all", label: "All assets" },
            { value: "utsla", label: "uTSLA" },
            { value: "unvda", label: "uNVDA" },
            { value: "uspx", label: "uSPX" },
            { value: "token", label: "Token" },
          ]}
          value={assetFilter}
          onChange={setAssetFilter}
        />
      </div>

      <Panel className="mt-4 overflow-x-auto">
        {filtered.length === 0 ? (
          <p className="py-20 text-center font-mono text-[11px] uppercase tracking-[0.08em] text-white-60">
            No flows match this filter.
          </p>
        ) : (
          <table className="w-full min-w-[860px] font-mono text-[12px]">
            <thead>
              <tr className="border-b hairline-dark text-left text-[10px] uppercase tracking-[0.08em] text-white-60">
                <th className="px-5 py-3 font-medium">Type</th>
                <th className="px-3 py-3 font-medium">Vault</th>
                <th className="px-3 py-3 text-right font-medium">Amount</th>
                <th className="px-3 py-3 text-right font-medium">USDC</th>
                <th className="hidden px-3 py-3 text-right font-medium lg:table-cell">Price</th>
                <th className="hidden px-3 py-3 text-right font-medium md:table-cell">Fee</th>
                <th className="px-3 py-3 text-right font-medium">Time</th>
                <th className="px-5 py-3 text-right font-medium">Tx</th>
              </tr>
            </thead>
            <tbody>
              <AnimatePresence initial={false}>
                {filtered.map((f) => (
                  <motion.tr
                    key={f.id}
                    layout="position"
                    initial={{ opacity: 0, y: -12 }}
                    animate={{ opacity: 1, y: 0 }}
                    transition={{ duration: 0.35 }}
                    className="border-b hairline-dark transition-colors last:border-b-0 hover:bg-section-deep"
                  >
                    <td className="px-5 py-3">
                      <FlowTypeBadge type={f.type} />
                    </td>
                    <td className="px-3 py-3 text-white">{flowVaultLabel(f)}</td>
                    <td className="px-3 py-3 text-right tabular-nums text-silver">{fmtNum(f.amount, f.vault === "token" ? 2 : 4)}</td>
                    <td className="px-3 py-3 text-right tabular-nums text-white">{fmtUSD(f.usdc, 0)}</td>
                    <td className="hidden px-3 py-3 text-right tabular-nums text-silver lg:table-cell">
                      {f.vault === "token" ? "–" : fmtUSD(f.price)}
                    </td>
                    <td className="hidden px-3 py-3 text-right text-white-60 md:table-cell">{f.feeBps} bps</td>
                    <td className="px-3 py-3 text-right text-white-60">{timeAgo(f.time)}</td>
                    <td className="px-5 py-3">
                      <span className="flex justify-end">
                        <TxCell hash={f.tx} />
                      </span>
                    </td>
                  </motion.tr>
                ))}
              </AnimatePresence>
            </tbody>
          </table>
        )}
      </Panel>

      <div className="mt-6 flex justify-center">
        <button
          type="button"
          onClick={loadMoreFlows}
          className="border hairline-dark px-8 py-3.5 text-[12px] font-semibold uppercase tracking-[0.08em] text-white transition-all hover:bg-section-deep-2 active:scale-[0.98]"
        >
          Load more
        </button>
      </div>
    </div>
  );
}
