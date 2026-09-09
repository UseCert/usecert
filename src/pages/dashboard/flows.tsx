import { ArrowDown, ArrowUp, Coins } from "lucide-react";
import { cn } from "@/lib/utils";
import type { FlowType } from "./store";

/* Only the flow kinds the deployed contracts can produce. Stakes, unstakes and staking
 * withdrawals were removed with the staking view: no staking contract exists here. */
const TYPE_ICON: Record<FlowType, typeof ArrowUp> = {
  MINT: ArrowUp,
  REDEEM: ArrowDown,
  CLAIM: Coins,
};

export function FlowTypeBadge({ type, className }: { type: FlowType; className?: string }) {
  const Icon = TYPE_ICON[type];
  const positive = type === "MINT" || type === "CLAIM";
  return (
    <span className={cn("inline-flex items-center gap-2 font-mono text-[11px] uppercase tracking-[0.06em]", className)}>
      <span
        className={cn(
          "flex h-6 w-6 items-center justify-center border",
          positive ? "border-green-bright/40 text-green-bright" : "border-silver/30 text-silver",
        )}
      >
        <Icon size={12} />
      </span>
      <span className={positive ? "text-green-bright" : "text-silver"}>{type}</span>
    </span>
  );
}
