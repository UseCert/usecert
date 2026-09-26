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
import { injected, walletConnect } from "wagmi/connectors";
import { defineChain } from "viem";

import { CHAIN } from "./contracts";

/** The one chain this app is allowed to talk to. */
export const CHAIN_ID = CHAIN.id;

/**
 * viem chain definition, derived from the generated `CHAIN` constant rather than
 * redeclared. Spread into mutable arrays because `CHAIN` is `as const`.
 */
/**
 * Multicall3, where the generated bundle names one (mainnet does, after checking it on chain).
 * With it, wagmi batches every `useReadContracts` into one call; without it the dashboard sent
 * ~220 separate requests every 30 seconds, enough to trip the RPC's rate limit - which a
 * browser reports as a CORS failure, because the limiter's reply carries no CORS header.
 */
const MULTICALL3 = (CHAIN as { contracts?: { multicall3?: { address: `0x${string}` } } }).contracts
  ?.multicall3;

export const usecertChain = defineChain({
  id: CHAIN.id,
  name: CHAIN.name,
  nativeCurrency: { ...CHAIN.nativeCurrency },
  rpcUrls: { default: { http: [...CHAIN.rpcUrls.default.http] } },
  blockExplorers: { default: { ...CHAIN.blockExplorers.default } },
  ...(MULTICALL3 ? { contracts: { multicall3: { address: MULTICALL3.address } } } : {}),
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

/**
 * The wallets a user may connect with.
 *
 * `injected()` is not one wallet: wagmi's multi-injected discovery (EIP-6963) is on by
 * default, so every browser extension that announces itself - MetaMask, Rabby, Brave,
 * Coinbase's extension - already appears as its own entry. What it CANNOT reach is a
 * wallet that is not an extension, and that is the whole gap this list closes.
 *
 * Coinbase Smart Wallet was tried and reverted. `@coinbase/wallet-sdk` pulls in
 * `@coinbase/cdp-sdk`, which imports `toClientEvmSigner` from `@x402/evm` - an OPTIONAL
 * peer dependency that is not installed - and the SSR build fails on the missing export.
 * The ways out were installing a payments SDK this project has no use for, or overriding
 * a vite config the repo explicitly says not to touch. Neither is worth one connector.
 *
 * `walletConnect` is the one that reaches the hundreds of MOBILE wallets - scan a QR and
 * sign on the phone. It is CONDITIONAL because it needs a project id from Reown/
 * WalletConnect Cloud, which is an account this project has to own. Listing a connector
 * that cannot complete is worse than not listing it: the user picks it, nothing happens,
 * and they conclude the site is broken. Set VITE_WALLETCONNECT_PROJECT_ID and it appears.
 *
 * Deliberately NOT here: `safe()`, which only functions inside a Safe app iframe and would
 * otherwise sit in the list as an option that can never connect.
 */
function buildConnectors() {
  const wcProjectId = import.meta.env?.VITE_WALLETCONNECT_PROJECT_ID as string | undefined;
  return [
    injected({ shimDisconnect: true }),
    ...(wcProjectId
      ? [
          walletConnect({
            projectId: wcProjectId,
            showQrModal: true,
            metadata: {
              name: "UseCert",
              description: `Perp-backed certificates on ${CHAIN.name}`,
              url: "https://use-cert.com",
              icons: ["https://use-cert.com/logo192.png"],
            },
          }),
        ]
      : []),
  ];
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
    connectors: buildConnectors(),
    transports: {
      [usecertChain.id]: http(CHAIN.rpcUrls.default.http[0]),
    },
    // Server-rendered app: defer hydration of persisted wallet state to the client.
    ssr: true,
    storage: createStorage({ storage: cookieStorage }),
  });
  return cached;
}
