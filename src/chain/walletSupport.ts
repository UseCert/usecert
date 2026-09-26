/**
 * Which wallets can actually reach chain 46630, and what to say when one cannot.
 *
 * THE PROBLEM. This app talks to exactly one chain: Robinhood Chain testnet, 46630. A
 * wallet reaches it in one of two ways - it already knows the chain, or the dapp asks it
 * to add it with `wallet_addEthereumChain`. Some wallets do neither, and Phantom is the
 * one users actually have installed.
 *
 * Phantom ships a fixed set of networks and does not let anything add another. Its own
 * documentation is unambiguous: "You can't add new or custom networks to Phantom manually.
 * Phantom only supports the networks that have been integrated directly into the app."
 * That list is Solana, Ethereum, Robinhood Chain, Arc, HyperEVM, Bitcoin, Base and Polygon
 * - mainnets, with no testnet among them.
 *
 * Robinhood Chain being on that list is what makes this confusing rather than obvious: a
 * user sees their chain supported, picks Phantom, and then cannot get to 46630, because
 * the testnet is a different chain from the mainnet Phantom integrated.
 *
 * WHY THIS WARNS RATHER THAN BLOCKS. Phantom could add this chain tomorrow and no code
 * here would know. Disabling the button would then be a permanent lie told by a stale
 * constant. Warning costs a user one click and is self-correcting: if it works, it works,
 * and the warning was merely pessimistic. Silence was the actual bug - the wallet
 * connected, the app sat on "wrong network", and the switch button did nothing at all.
 */

/** EIP-6963 rdns values for wallets that cannot be asked to add a chain. */
const NO_CUSTOM_CHAINS = new Set(["app.phantom"]);

export interface ConnectorLike {
  id: string;
  name: string;
}

/**
 * Can this wallet be asked to add chain 46630?
 *
 * Matches on the EIP-6963 rdns first, which is the stable identifier, and falls back to
 * the display name for providers discovered without one.
 */
export function cannotAddCustomChains(c: ConnectorLike): boolean {
  if (NO_CUSTOM_CHAINS.has(c.id.toLowerCase())) return true;
  // Tokenised rather than a substring test: "Phantasma" contains "phantom" nowhere, but a
  // naive includes() would eventually flag some unrelated wallet whose name embeds it.
  // Splitting on non-alphanumerics gives word matching without a regex escape to get wrong.
  return c.name
    .toLowerCase()
    .split(/[^a-z0-9]+/)
    .includes("phantom");
}

/** Shown under the wallet's name, before anyone clicks it. */
export const CUSTOM_CHAIN_WARNING =
  "Cannot add chain 46630 - Phantom only supports networks built into the app";

/**
 * Does this error, or anything in its cause chain, carry this EIP-1193 code?
 *
 * The chain matters more than the top. wagmi wraps a wallet's refusal to ADD a chain in a
 * `UserRejectedRequestError` - reasonably, since for most wallets a failed add does mean
 * the user closed the prompt. For a wallet that cannot show that prompt at all it is
 * simply wrong, and it is why the dashboard told a Phantom user "you dismissed the wallet
 * prompt" when they had dismissed nothing. The original 4902 survives on `cause`.
 */
function hasCode(err: unknown, code: number): boolean {
  let node: unknown = err;
  for (let depth = 0; depth < 6 && node; depth += 1) {
    const n = node as { code?: unknown; cause?: unknown };
    if (n.code === code) return true;
    node = n.cause;
  }
  return false;
}

function errorText(err: unknown): string {
  // Walk the shapes wagmi/viem actually throw. Reading only `Error.message` turned a
  // plain rejection object into "[object Object]", which matched no rule.
  const seen: string[] = [];
  let node: unknown = err;
  for (let depth = 0; depth < 6 && node; depth += 1) {
    const n = node as { message?: unknown; shortMessage?: unknown; details?: unknown; cause?: unknown };
    for (const field of [n.message, n.shortMessage, n.details]) {
      if (typeof field === "string") seen.push(field);
    }
    node = n.cause;
  }
  if (seen.length === 0 && typeof err === "string") seen.push(err);
  return seen.join(" | ");
}

export function explainChainFailure(err: unknown, connector?: ConnectorLike | null): string | null {
  // ORDER MATTERS. 4902 ("unrecognized chain") is checked FIRST, anywhere in the cause
  // chain, because wagmi re-labels a failed add as a user rejection and that label would
  // otherwise win. A genuine cancel never carries 4902.
  const unrecognised =
    hasCode(err, 4902) ||
    /unrecognized chain|unrecognised chain|chain .*not (found|added|configured)|does not support|unsupported chain/i.test(
      errorText(err),
    );

  if (!unrecognised) {
    // Only now is a rejection really a rejection. Saying a wallet is incapable when the
    // user pressed Cancel would send them to install a second wallet for no reason.
    if (hasCode(err, 4001) || /user rejected|user denied/i.test(errorText(err))) return null;
  }

  if (unrecognised && connector && cannotAddCustomChains(connector)) {
    return (
      `${connector.name} cannot reach chain 46630. It only supports the networks built into ` +
      `the app and does not allow adding another, so this testnet is out of its reach - note ` +
      `that Robinhood Chain mainnet being supported does not include its testnet. Use a wallet ` +
      `that can add a custom network, such as MetaMask or Rabby.`
    );
  }

  if (unrecognised) {
    return (
      "Your wallet would not add chain 46630. Add Robinhood Chain testnet manually " +
      "(RPC https://rpc.testnet.chain.robinhood.com, chain id 46630), or use a wallet that " +
      "accepts a custom network."
    );
  }

  return null;
}
