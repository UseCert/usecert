/**
 * Wallets that reach chain 46630 only after the user changes a setting.
 *
 * WHAT THIS GOT WRONG THE FIRST TIME, because the correction is the useful part.
 *
 * Phantom's help page "Supported networks (chains)" lists eight networks, all mainnets,
 * and a second page says plainly that you cannot add custom networks to Phantom. Reading
 * only those two, the conclusion looks forced: Phantom cannot reach a testnet, so the app
 * should send the user to MetaMask. That is what this file said, and it was wrong.
 *
 * Phantom's DEVELOPER documentation lists the testnets it supports, and Robinhood Chain
 * Testnet is among them - alongside Sepolia, Base Sepolia, Polygon Amoy and Arc Testnet.
 * They are hidden behind Testnet Mode, off by default, which is why the help pages aimed
 * at ordinary users do not mention them. Chain 46630 is not a custom network Phantom must
 * be asked to add; it is a network Phantom already has, behind a toggle.
 *
 * So the failure is real but the remedy is a setting, not a different wallet. Both halves
 * matter: a user told to install MetaMask when a checkbox would do has been sent away for
 * nothing.
 *
 * WHY IT STILL WARNS BEFORE THE CLICK. Nothing here can read Phantom's Testnet Mode -
 * there is no RPC for it, and the failure only appears after the user has approved a
 * connection. Saying so up front costs a reader one sentence and saves the round trip.
 */

/**
 * EIP-6963 rdns values for wallets that hold chain 46630 behind a setting rather than
 * accepting it from the dapp.
 */
const NEEDS_TESTNET_MODE = new Set(["app.phantom"]);

export interface ConnectorLike {
  id: string;
  name: string;
}

/** Is this a wallet whose testnet support is behind a toggle? */
export function needsTestnetMode(c: ConnectorLike): boolean {
  if (NEEDS_TESTNET_MODE.has(c.id.toLowerCase())) return true;
  // Tokenised rather than a substring test, so "Phantasma" is not caught by "phantom",
  // and with no regex escape to get wrong.
  return c.name
    .toLowerCase()
    .split(/[^a-z0-9]+/)
    .includes("phantom");
}

/** Shown under the wallet's name, before anyone spends a click on it. */
export const TESTNET_MODE_HINT =
  "Needs Testnet Mode on: Settings -> Developer Settings -> Testnet Mode";

/**
 * Does this error, or anything in its cause chain, carry this EIP-1193 code?
 *
 * The chain matters more than the top. wagmi wraps a wallet's refusal to switch or add a
 * chain in a `UserRejectedRequestError` - reasonable for a wallet that showed a prompt,
 * wrong for one that refused before showing anything - so the dashboard told a Phantom
 * user "you dismissed the wallet prompt" when they had dismissed nothing. The original
 * 4902 survives on `cause`.
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
  // plain rejection object into "[object Object]", which matched no rule at all.
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

/**
 * Why the chain switch failed, in a sentence the reader can act on.
 *
 * Returns null when this is not a chain problem, so the caller falls back to its own
 * decoding rather than mislabelling an unrelated failure.
 */
export function explainChainFailure(err: unknown, connector?: ConnectorLike | null): string | null {
  // ORDER MATTERS. 4902 is checked FIRST, anywhere in the cause chain, because wagmi
  // re-labels the failure as a user rejection and that label would otherwise win. A
  // genuine cancel never carries 4902.
  const unrecognised =
    hasCode(err, 4902) ||
    /unrecognized chain|unrecognised chain|chain .*not (found|added|configured)|does not support|unsupported chain/i.test(
      errorText(err),
    );

  if (!unrecognised) {
    if (hasCode(err, 4001) || /user rejected|user denied/i.test(errorText(err))) return null;
  }

  if (unrecognised && connector && needsTestnetMode(connector)) {
    return (
      `${connector.name} supports Robinhood Chain Testnet, but only with Testnet Mode ` +
      `switched on. Open ${connector.name} -> profile avatar (top left) -> Settings -> ` +
      `Developer Settings -> Testnet Mode, turn it on, then try connecting again. Same ` +
      `path on the extension and in the mobile app.`
    );
  }

  if (unrecognised) {
    return (
      "Your wallet would not switch to chain 46630. Add Robinhood Chain testnet manually " +
      "(RPC https://rpc.testnet.chain.robinhood.com, chain id 46630), or enable its testnet " +
      "setting if it has one."
    );
  }

  return null;
}
