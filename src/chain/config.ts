/**
 * wagmi configuration for the UseCert deployment on Robinhood Chain testnet.
 *
 * Chain 46630 ONLY. Mainnet (4663) is deliberately absent: that chain ID has never been
 * verified from the contracts repo, and pointing a UI at an unverified chain ID is how a
 * user ends up signing against the wrong network. See INTEGRATION-NOTES.md §1 and §7.
 *
 * SSR: this app is server-rendered (TanStack Start), so NOTHING here may touch `window`
 * at module scope. The config is therefore built lazily by `getWagmiConfig()` and memoised;
 * the `injected()` connector only reaches for `window.ethereum` once it is actually used in
 * the browser, and `cookieStorage` is SSR-safe.
 */
import {
  cookieStorage,
  createConfig,
  createStorage,
  http,
  type Config,
} from "wagmi";
import { injected } from "wagmi/connectors";
import { defineChain } from "viem";

import { CHAIN } from "./contracts";

/** The one chain this app is allowed to talk to. */
export const CHAIN_ID = CHAIN.id;

/**
 * viem chain definition, derived from the generated `CHAIN` constant rather than
 * redeclared. Spread into mutable arrays because `CHAIN` is `as const`.
 */
export const usecertChain = defineChain({
  id: CHAIN.id,
  name: CHAIN.name,
  nativeCurrency: { ...CHAIN.nativeCurrency },
  rpcUrls: { default: { http: [...CHAIN.rpcUrls.default.http] } },
  blockExplorers: { default: { ...CHAIN.blockExplorers.default } },
  testnet: CHAIN.testnet,
});

/** True only for chain 46630. Use this to gate the whole app and offer a network switch. */
export function isSupportedChain(chainId: number | undefined): boolean {
  return chainId === CHAIN_ID;
}

/** Block explorer link for a transaction hash, for receipts and toasts. */
export function explorerTxUrl(hash: string): string {
  return `${CHAIN.blockExplorers.default.url}/tx/${hash}`;
}

/** Block explorer link for an address. */
export function explorerAddressUrl(address: string): string {
  return `${CHAIN.blockExplorers.default.url}/address/${address}`;
}

let cached: Config | undefined;

/**
 * Build (once) and return the wagmi config.
 *
 * Deliberately a function, not a module-scope `export const config = createConfig(...)`:
 * calling `createConfig` at import time runs storage and connector setup during SSR.
 * Call this inside a component or effect (see `src/routes/__root.tsx`).
 */
export function getWagmiConfig(): Config {
  if (cached) return cached;
  cached = createConfig({
    chains: [usecertChain],
    connectors: [injected({ shimDisconnect: true })],
    transports: {
      [usecertChain.id]: http(CHAIN.rpcUrls.default.http[0]),
    },
    // Server-rendered app: defer hydration of persisted wallet state to the client.
    ssr: true,
    storage: createStorage({ storage: cookieStorage }),
  });
  return cached;
}
