import type { VaultId } from "./store";

/**
 * Per-vault presentation metadata.
 *
 * `uspy` is here because it is deployed (market 26). It points at `/logo.png` with
 * `imgPlaceholder: true` because there is no `cert-plate-uspy.jpg` in `public/` — putting
 * the uSPX plate under a uSPY heading would dress one certificate in another's artwork.
 * The other three ids have no contracts on chain 46630; they are kept so the roadmap
 * stays visible, but they never carry figures.
 */
export const FLOW_META: Record<
  VaultId,
  { name: string; full: string; img: string; imgPlaceholder: boolean }
> = {
  utsla: {
    name: "uTSLA",
    full: "Tesla Certificate",
    img: "/cert-plate-utsla.jpg",
    imgPlaceholder: false,
  },
  uspy: {
    name: "uSPY",
    full: "S&P 500 Certificate",
    img: "/logo.png",
    imgPlaceholder: true,
  },
  unvda: {
    name: "uNVDA",
    full: "Nvidia Certificate",
    img: "/cert-plate-unvda.jpg",
    imgPlaceholder: false,
  },
  uspx: {
    name: "uSPX",
    full: "S&P 500 Index Certificate",
    img: "/cert-plate-uspx.jpg",
    imgPlaceholder: false,
  },
  uqqq: {
    name: "uQQQ",
    full: "Nasdaq 100 Certificate",
    img: "/cert-plate-uqqq.jpg",
    imgPlaceholder: false,
  },
};

/* `flowVaultLabel(flow)` is gone with the `Flow` shape it took. It mapped a
 * `VaultId | "token"` to a label, and "token" was the mock staking row — there is no
 * protocol token on this deployment, so no real flow can ever be one. A `FlowEvent`
 * (`src/chain/useFlows.ts`) carries `vaultSymbol` from the deployed mirror it was read
 * from, so there is nothing left to look up. */
