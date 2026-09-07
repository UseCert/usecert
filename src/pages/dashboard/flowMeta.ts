import type { Flow, VaultId } from "./store";

export const FLOW_META: Record<VaultId, { name: string; full: string; img: string }> = {
  utsla: { name: "uTSLA", full: "Tesla Certificate", img: "/cert-plate-utsla.jpg" },
  unvda: { name: "uNVDA", full: "Nvidia Certificate", img: "/cert-plate-unvda.jpg" },
  uspx: { name: "uSPX", full: "S&P 500 Certificate", img: "/cert-plate-uspx.jpg" },
  uqqq: { name: "uQQQ", full: "Nasdaq 100 Certificate", img: "/cert-plate-uqqq.jpg" },
};

export function flowVaultLabel(flow: Flow): string {
  if (flow.vault === "token") return "TOKEN";
  return FLOW_META[flow.vault].name;
}
