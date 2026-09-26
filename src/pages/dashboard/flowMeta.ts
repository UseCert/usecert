import type { VaultId } from "./store";

/**
 * Per-vault presentation metadata, one entry per `VaultId`.
 *
 * All four ids are deployed mirrors on chain 46630. `uspy` points at `/logo.png` with
 * `imgPlaceholder: true` because there is no `cert-plate-uspy.jpg` in `public/`, and
 * borrowing another certificate's plate would dress one certificate in another's artwork.
 * uQQQ and uNVDA do have their own plates.
 *
 * `uspx` used to be here and is gone: the venue has no SPX perpetual, so that certificate
 * cannot exist. Its plate (`/cert-plate-uspx.jpg`) is deliberately not reused for anything.
 *
 * `Record<VaultId, …>` is the guard — a new id does not compile until it has an entry, so
 * no flow row can fall back to a blank name or someone else's artwork.
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
  uqqq: {
    name: "uQQQ",
    full: "Nasdaq 100 Certificate",
    img: "/cert-plate-uqqq.jpg",
    imgPlaceholder: false,
  },
  unvda: {
    name: "uNVDA",
    full: "Nvidia Certificate",
    img: "/cert-plate-unvda.jpg",
    imgPlaceholder: false,
  },
  uaapl: {
    name: "uAAPL",
    full: "Apple Certificate",
    img: "/cert-plate-uaapl.jpg",
    imgPlaceholder: false,
  },
  umsft: {
    name: "uMSFT",
    full: "Microsoft Certificate",
    img: "/logo.png",
    imgPlaceholder: true,
  },
};

/* `flowVaultLabel(flow)` is gone with the `Flow` shape it took. It mapped a
 * `VaultId | "token"` to a label, and "token" was the mock staking row — there is no
 * protocol token on this deployment, so no real flow can ever be one. A `FlowEvent`
 * (`src/chain/useFlows.ts`) carries `vaultSymbol` from the deployed mirror it was read
 * from, so there is nothing left to look up. */
