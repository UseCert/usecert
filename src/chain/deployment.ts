import { CHAIN, SHARED } from "./contracts";

/**
 * WHAT THIS DEPLOYMENT ACTUALLY IS, derived rather than asserted.
 *
 * THE PROBLEM THIS SOLVES. The word "testnet" appeared 64 times across this source, "tUSDG"
 * 62 times and "faucet" 82 — every one of them a literal typed by someone who knew which
 * chain they were on at the time. Switching to mainnet is one file: `contracts.ts` is
 * regenerated and `CHAIN_ID`, the RPC, the explorer and all 26 addresses follow. The COPY did
 * not follow, so the plan was a manual sweep of ~290 strings at switch time — which is not a
 * plan, it is a list of things to forget under pressure.
 *
 * Every fact below is read from the generated bundle, so it changes when the bundle changes
 * and cannot disagree with the contracts the app is talking to.
 *
 * WHY ABSENCE IS THE SIGNAL. `testFaucet` and `lighterSim` are testnet-only by construction:
 * a faucet on mainnet is a mint of free money, and the simulator exists only because Lighter
 * is not deployed on testnet. The mainnet address book has both null and the generator omits
 * null keys entirely, so their absence from `SHARED` is a fact about the deployment rather
 * than a flag somebody has to remember to flip.
 */

/**
 * The addresses that exist on one deployment and not the other.
 *
 * WHY A CAST. `SHARED` is a generated object literal, so TypeScript knows its keys
 * EXACTLY. On testnet `SHARED.testFaucet` is a string; on mainnet the key is absent and
 * the same expression is a COMPILE ERROR rather than `undefined`. That was not theoretical:
 * building against a mainnet-shaped bundle broke four files with seven errors that could not
 * have surfaced any other way, because nothing type-checks against a bundle it never sees.
 *
 * Widening here once means the rest of the app reads an optional address and has to decide
 * what to do when it is missing, which is the decision that actually needs making.
 */
type OptionalAddresses = { testFaucet?: `0x${string}`; lighterSim?: `0x${string}` };
const OPTIONAL = SHARED as OptionalAddresses;

/** The test faucet, or `undefined` where none is deployed. */
export const FAUCET_ADDRESS: `0x${string}` | undefined = OPTIONAL.testFaucet;

/** The venue simulator, or `undefined` where the vault is wired to the real venue. */
export const VENUE_SIM_ADDRESS: `0x${string}` | undefined = OPTIONAL.lighterSim;

/**
 * Robinhood Chain testnet (46630) rather than mainnet (4663). From the bundle's own flag.
 *
 * Read into a `boolean` rather than compared to `true`: the generator emits the flag as a
 * literal, so `=== true` is a comparison between `false` and `true` on a mainnet bundle
 * and TypeScript rejects it as unintentional. The generator always emits the key, so if it
 * ever stops, this line fails loudly instead of quietly deciding the deployment is mainnet.
 */
const TESTNET_FLAG: boolean = CHAIN.testnet;
export const IS_TESTNET: boolean = TESTNET_FLAG;

/** "Robinhood Chain Testnet" or "Robinhood Chain". */
export const CHAIN_LABEL: string = CHAIN.name;

export const CHAIN_ID: number = CHAIN.id;

/**
 * Is the perp venue a simulator this project runs?
 *
 * True exactly when a `lighterSim` address is present. On mainnet the vault is wired to
 * Lighter's real ZkLighter proxy and no simulator is deployed, so this is false without
 * anyone editing it.
 */
export const VENUE_IS_SIMULATED: boolean = VENUE_SIM_ADDRESS !== undefined;

/** Is there a faucet handing out collateral? Testnet only, by construction. */
export const HAS_FAUCET: boolean = FAUCET_ADDRESS !== undefined;

/**
 * The collateral's ticker.
 *
 * The one fact here that is not read from an address, because the bundle carries the token's
 * address and not its symbol. Deriving it from `IS_TESTNET` keeps it to a single place that
 * changes with the chain, which is the whole point — rather than 62 literals that do not.
 */
export const COLLATERAL_SYMBOL: string = IS_TESTNET ? "tUSDG" : "USDG";

/** Does real-world value move on this deployment? */
export const HAS_REAL_VALUE: boolean = !IS_TESTNET;

/**
 * The disclosure that belongs above anything describing a position.
 *
 * On testnet it names all three reasons the figures are not what they look like. On mainnet
 * the collateral and the venue are real, so the sentence would be false and there is nothing
 * to say — an empty string, which every caller renders as nothing.
 */
export const VALUE_DISCLOSURE: string = !IS_TESTNET
  ? ""
  : VENUE_IS_SIMULATED
    ? `UseCert runs on ${CHAIN_LABEL} (chain ${CHAIN_ID}). Nothing here holds real-world value, the collateral is a test token, and the perp venue is a simulator this project runs — so every margin and position figure describes a simulated position, not a market.`
    : `UseCert runs on ${CHAIN_LABEL} (chain ${CHAIN_ID}). Nothing here holds real-world value and the collateral is a test token.`;

/** The same thing in one line, for a chip or a caption. */
export const SHORT_DISCLOSURE: string = !IS_TESTNET
  ? ""
  : VENUE_IS_SIMULATED
    ? "Testnet · test collateral · simulated venue"
    : "Testnet · test collateral";

/**
 * How a holder gets collateral, as a sentence.
 *
 * On mainnet there is no faucet and the answer is that they buy it, which is a different
 * product and should read like one.
 */
export const HOW_TO_GET_COLLATERAL: string = HAS_FAUCET
  ? `${COLLATERAL_SYMBOL} comes from the test faucet — there is nothing to buy.`
  : `${COLLATERAL_SYMBOL} is real collateral you already hold or acquire; this protocol does not issue it.`;

/**
 * The CERT project token ("UseCert", 18 decimals, 1,000,000,000 supply), where one exists.
 *
 * WHY IT IS TYPED HERE. The token is not part of the vault stack, so the generated address
 * book does not carry it. It exists on Robinhood Chain mainnet (4663) only, so it is keyed on
 * the chain id: any other bundle reads `undefined` and keeps saying there is no token.
 *
 * WHAT IT DOES NOT MEAN. The token existing is not staking, an insurance tranche, buybacks
 * or a fee split. None of those is deployed, and copy that reads this flag must keep saying so.
 */
export const CERT_TOKEN_ADDRESS: `0x${string}` | undefined =
  CHAIN_ID === 4663 ? "0xb01356A005403C38c0fb01bd0aAfe51e81Ab9B07" : undefined;

/** Is the CERT token deployed on this chain? (Staking and the fee split are not, either way.) */
export const HAS_CERT_TOKEN: boolean = CERT_TOKEN_ADDRESS !== undefined;

/** `0xb013…9B07`, for copy too narrow for the full address. Empty where there is no token. */
export const CERT_TOKEN_SHORT: string = CERT_TOKEN_ADDRESS
  ? `${CERT_TOKEN_ADDRESS.slice(0, 6)}…${CERT_TOKEN_ADDRESS.slice(-4)}`
  : "";
