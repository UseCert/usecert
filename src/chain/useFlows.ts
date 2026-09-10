/**
 * Transaction-flow history for the routed UseCert vaults, read from the chain's own
 * Blockscout index.
 *
 * ─────────────────────────────────────────────────────────────────────────────────────
 * WHY THIS EXISTS — AND WHAT THE OLD COPY GOT WRONG
 * ─────────────────────────────────────────────────────────────────────────────────────
 * The dashboard used to say: "No flow history yet: needs an indexer — receipt ids are not
 * enumerable on-chain and there is no `receiptsOf(user)`, so a flow list can only be built
 * from indexed events. None are indexed yet."
 *
 * The first half is true and stays true. Receipt ids really are not enumerable: there is no
 * `receiptsOf(address)` on `CertVault`, so a wallet's two-step mints and redemptions cannot
 * be walked from a view function. A flow list really can only come from logs.
 *
 * The last sentence was false. Robinhood Chain testnet runs a Blockscout instance that
 * already indexes AND decodes these events, its REST API is public, and it answers with
 * `access-control-allow-origin: *` — so the browser can call it directly. No proxy, no
 * server route, no service to run. That is what this file does.
 *
 * A raw `eth_getLogs` scan is NOT an alternative: the deployment block is 11,667,691 and
 * the head is past 116,000,000. A ~104M-block range is not a request any public RPC will
 * serve, which is exactly why the index is the only route.
 *
 * ─────────────────────────────────────────────────────────────────────────────────────
 * PROVENANCE — THE THIRD CLASS
 * ─────────────────────────────────────────────────────────────────────────────────────
 * This project already separates two provenance classes rigorously:
 *
 *   1. CHAIN READ        a guarded view function, called through wagmi. Ground truth.
 *   2. ATTESTER CLAIM    relayed into the contract, nothing on-chain verifies it.
 *                        Rendered with `UnverifiedTag`. (`solvency.accrual18`.)
 *
 * Everything in this file is a THIRD class:
 *
 *   3. THIRD-PARTY INDEX an HTTP response from an explorer this project does not run.
 *
 * Class 3 is not class 1. The underlying events are real and the explorer decodes them
 * from the same contract ABI, but the app is trusting an intermediary's HTTP JSON, not a
 * value it read from a node itself. Anything sourced here therefore travels with
 * `FLOW_SOURCE` and is rendered under `ExplorerSourcedTag` / `ExplorerSourceNote`
 * (`src/pages/dashboard/ui.tsx`). Do not let a figure from here share a visual register
 * with a `useReadContracts` figure.
 *
 * And the corollary, which is the whole point: when the index is unreachable, slow or
 * rate-limiting, the UI must say the INDEX is unavailable. An empty list would read as
 * "you have no activity" — a false statement about the user's money, produced by a
 * third-party HTTP failure. `FlowsResult.indexUnavailable` exists so no view can make
 * that mistake by accident.
 *
 * ─────────────────────────────────────────────────────────────────────────────────────
 * THE RECEIPT-ID JOIN
 * ─────────────────────────────────────────────────────────────────────────────────────
 * Five of the eight flow events carry the wallet in an indexed topic. Two do not:
 *
 *   MintSettled(uint256 indexed receiptId, uint256 certOut, uint256 fillPx18)
 *   RedeemClaimed(uint256 indexed receiptId, uint256 amountOut)
 *
 * Both identify the flow ONLY by `receiptId`. To attribute them to a wallet we first build
 * `receiptId -> user` from the events that do carry a user — `MintRequested`,
 * `RedeemRequested` and `ForceExited` — and then match. Receipt ids are per-vault
 * counters, so the join key is `(vault, receiptId)`, never the bare id: uTSLA receipt 1
 * and uSPY receipt 1 are different receipts belonging to possibly different people.
 *
 * When the request half is not in the fetched window, the settlement is NOT guessed. It is
 * marked `attribution: "unattributed"`, kept in the all-vault view (the event happened) and
 * omitted from any per-wallet view (we cannot say whose it is). `FlowsResult.unattributed`
 * carries the count so a view can state the omission rather than silently shorten a list.
 *
 * ─────────────────────────────────────────────────────────────────────────────────────
 * DECIMALS
 * ─────────────────────────────────────────────────────────────────────────────────────
 * Four domains, not interchangeable — see `src/chain/units.ts`. Per event:
 *
 *   amountIn, amountOut, fee     COLLATERAL, 6 dp   -> `fromCollateral`
 *   certIn, certOut              CERTIFICATE, 18 dp -> `fromCert`
 *   px18, fillPx18               PRICE, 18 dp       -> `fromPrice18`
 *   expiresAt                    unix seconds       -> plain number
 *
 * The check, against a real `Minted` log on the uTSLA vault
 * (`amountIn=500000000, certOut=1362400000000000000, px18=366620400000000000000, fee=500000`):
 * $500.00 in, 1.3624 uTSLA out, $366.6204 price, $0.50 fee. A renderer that disagrees with
 * those four numbers has the decimals wrong, not the data.
 *
 * ─────────────────────────────────────────────────────────────────────────────────────
 * POLITENESS
 * ─────────────────────────────────────────────────────────────────────────────────────
 * The API publishes `x-ratelimit-limit` / `-remaining` / `-reset`. This hook does not
 * poll: react-query holds the result for `STALE_TIME_MS` and refetch is user-initiated.
 * Do not add a `refetchInterval` here — the flow list is history, it does not need a
 * 15-second tick, and a shared public index is not ours to hammer.
 */
import { useCallback, useMemo, useState } from "react";
import { useQuery } from "@tanstack/react-query";

import { CHAIN } from "./contracts";
import { explorerTxUrl } from "./config";
import { fromCert, fromCollateral, fromPrice18 } from "./units";
import {
  CHAIN_VAULT_IDS,
  chainVaultMeta,
  vaultAddresses,
  type ChainVaultId,
} from "./useVaults";

/* ─────────────────────────────────────────────────────────────────── provenance */

/**
 * The provenance label every flow in this module carries.
 *
 * A string constant rather than a comment so a component cannot render one of these rows
 * without the label being available to it.
 */
export const FLOW_SOURCE = "third-party index" as const;

/** Human sentence for the provenance note. Kept next to the constant it explains. */
export const FLOW_SOURCE_DETAIL =
  `Flow history is read from the chain's public Blockscout index at ${CHAIN.blockExplorers.default.url}, ` +
  "which decodes these events from the contract ABI. It is a third-party HTTP index, not a " +
  "chain read performed by this app: the events are real, but the intermediary is trusted. " +
  "Balances, prices, capacity and solvency elsewhere on this dashboard are read directly " +
  "from the contracts and are not affected by this index.";

/* ────────────────────────────────────────────────────────────────── tuning knobs */

/** How long react-query treats a fetched page set as fresh. History does not go stale fast. */
const STALE_TIME_MS = 60_000;
/** Pages (50 logs each) fetched per vault on first load, and added by `loadMore`. */
const PAGE_STEP = 2;
/** Hard ceiling on pages per vault, so `loadMore` cannot walk the index unbounded. */
const MAX_PAGES = 10;
/** Per-request timeout. A hanging index must become `indexUnavailable`, not a spinner. */
const REQUEST_TIMEOUT_MS = 15_000;

/* ──────────────────────────────────────────────────────────────────── flow shape */

/**
 * The eight `CertVault` events that describe what happened to a user's money.
 *
 * `MarginPosted` and the other operational events are deliberately absent: they are the
 * vault's internal venue plumbing, not a flow belonging to a wallet. They are counted in
 * `FlowsResult.ignored` so a view can say they were skipped rather than pretend the vault
 * emitted nothing else.
 */
export type FlowKind =
  | "MINT" // Minted            — instant path, settled in one transaction
  | "MINT_REQUESTED" // MintRequested     — two-step path opened
  | "MINT_SETTLED" // MintSettled       — two-step path filled by the keeper
  | "MINT_REFUNDED" // MintRefunded      — two-step path returned the collateral
  | "REDEEM" // Redeemed          — instant path
  | "REDEEM_REQUESTED" // RedeemRequested   — two-step path opened
  | "REDEEM_CLAIMED" // RedeemClaimed     — two-step path paid out
  | "FORCE_EXITED"; // ForceExited       — user exited past the settle window

/** Which side of the vault a flow sits on. Drives the badge, not the maths. */
export type FlowSide = "MINT" | "REDEEM";

/**
 * How the wallet on a flow was determined.
 *
 *  `direct`        the event carries an indexed `user` topic. As certain as the log itself.
 *  `joined`        matched to a wallet through `(vault, receiptId)` — see the file header.
 *  `unattributed`  `MintSettled` / `RedeemClaimed` whose request half is outside the
 *                  fetched window. NOT guessed: excluded from per-wallet views.
 */
export type FlowAttribution = "direct" | "joined" | "unattributed";

export interface FlowEvent {
  /** `${txHash}:${logIndex}` — unique per log, stable across refetches. React key. */
  id: string;
  kind: FlowKind;
  /** Sentence-case label: "Minted", "Redeem claimed". */
  label: string;
  side: FlowSide;

  vaultId: ChainVaultId;
  /** "uTSLA" / "uSPY". */
  vaultSymbol: string;
  vaultAddress: string;

  blockNumber: number;
  /** ms epoch from the index's `block_timestamp`. `null` when it was absent or unparseable. */
  timeMs: number | null;
  txHash: string;
  /** `{explorer}/tx/{hash}`. */
  txUrl: string;
  logIndex: number;

  /** Collateral leg (6 dp), display number. `null` when the event carries none. */
  collateral: number | null;
  /** Certificate leg (18 dp), display number. `null` when the event carries none. */
  cert: number | null;
  /** Price (18 dp). `null` on every event that does not carry one — never a 0. */
  price: number | null;
  /** Protocol fee, collateral (6 dp). Only `Minted` carries one. `null` elsewhere. */
  fee: number | null;

  /** Per-vault receipt id, as a decimal string. `null` on the instant paths. */
  receiptId: string | null;
  /** `RedeemRequested.expiresAt`, unix seconds. `null` on every other event. */
  expiresAtSec: number | null;

  /** Lower-cased wallet, or `null` when unattributed. Compare against a lower-cased address. */
  user: string | null;
  attribution: FlowAttribution;
}

/** Badge/label text per kind. One place, so two views cannot disagree on wording. */
const KIND_LABEL: Record<FlowKind, string> = {
  MINT: "Minted",
  MINT_REQUESTED: "Mint requested",
  MINT_SETTLED: "Mint settled",
  MINT_REFUNDED: "Mint refunded",
  REDEEM: "Redeemed",
  REDEEM_REQUESTED: "Redeem requested",
  REDEEM_CLAIMED: "Redeem claimed",
  FORCE_EXITED: "Force exited",
};

export function flowKindLabel(kind: FlowKind): string {
  return KIND_LABEL[kind];
}

/** Solidity event name → our kind. Anything not in here is operational, not a user flow. */
const EVENT_KIND: Record<string, FlowKind> = {
  Minted: "MINT",
  MintRequested: "MINT_REQUESTED",
  MintSettled: "MINT_SETTLED",
  MintRefunded: "MINT_REFUNDED",
  Redeemed: "REDEEM",
  RedeemRequested: "REDEEM_REQUESTED",
  RedeemClaimed: "REDEEM_CLAIMED",
  ForceExited: "FORCE_EXITED",
};

const KIND_SIDE: Record<FlowKind, FlowSide> = {
  MINT: "MINT",
  MINT_REQUESTED: "MINT",
  MINT_SETTLED: "MINT",
  MINT_REFUNDED: "MINT",
  REDEEM: "REDEEM",
  REDEEM_REQUESTED: "REDEEM",
  REDEEM_CLAIMED: "REDEEM",
  FORCE_EXITED: "REDEEM",
};

/* ──────────────────────────────────────────────────── raw response, treated as unknown */

/**
 * The Blockscout v2 log shape, every field optional.
 *
 * This is somebody else's API and it is not versioned by us, so nothing here is assumed to
 * be present. Every read goes through the coercion helpers below and a log that does not
 * yield what an event needs is dropped and counted, never rendered half-parsed.
 */
interface RawParam {
  name?: unknown;
  value?: unknown;
  indexed?: unknown;
  type?: unknown;
}

interface RawDecoded {
  method_call?: unknown;
  parameters?: unknown;
}

interface RawLog {
  address?: { hash?: unknown } | null;
  block_number?: unknown;
  block_timestamp?: unknown;
  transaction_hash?: unknown;
  index?: unknown;
  decoded?: RawDecoded | null;
}

interface RawLogsPage {
  items?: unknown;
  next_page_params?: unknown;
}

function asString(value: unknown): string | null {
  if (typeof value === "string") return value;
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  return null;
}

function asInt(value: unknown): number | null {
  if (typeof value === "number" && Number.isFinite(value)) return Math.trunc(value);
  if (typeof value === "string" && value.trim() !== "") {
    const n = Number(value);
    return Number.isFinite(n) ? Math.trunc(n) : null;
  }
  return null;
}

/**
 * A uint parameter → `bigint`, or `null`.
 *
 * Deliberately via `bigint` and not `Number`: an 18-decimal `certOut` is ~19 digits and
 * `Number("1362400000000000000")` has already lost precision before any scaling happens.
 * The `from*` converters take the bigint and do the scaling exactly.
 */
function asBigint(value: unknown): bigint | null {
  const s = asString(value);
  if (s === null) return null;
  const trimmed = s.trim();
  if (!/^-?\d+$/.test(trimmed)) return null;
  try {
    return BigInt(trimmed);
  } catch {
    return null;
  }
}

/** The event name out of `method_call`, i.e. everything before the first "(". */
function eventName(decoded: RawDecoded | null | undefined): string | null {
  const call = asString(decoded?.method_call);
  if (call === null) return null;
  const open = call.indexOf("(");
  const name = (open === -1 ? call : call.slice(0, open)).trim();
  return name === "" ? null : name;
}

/** Named parameter lookup. Positional indexing is avoided: the index owns the ordering. */
function paramValue(decoded: RawDecoded | null | undefined, name: string): unknown {
  const params = decoded?.parameters;
  if (!Array.isArray(params)) return undefined;
  for (const p of params as RawParam[]) {
    if (p && asString(p.name) === name) return p.value;
  }
  return undefined;
}

/** An address parameter, lower-cased so wallet comparison never depends on checksum case. */
function paramAddress(decoded: RawDecoded | null | undefined, name: string): string | null {
  const raw = asString(paramValue(decoded, name));
  if (raw === null) return null;
  const lower = raw.trim().toLowerCase();
  return /^0x[0-9a-f]{40}$/.test(lower) ? lower : null;
}

function paramBigint(decoded: RawDecoded | null | undefined, name: string): bigint | null {
  return asBigint(paramValue(decoded, name));
}

function timestampMs(value: unknown): number | null {
  const s = asString(value);
  if (s === null) return null;
  const ms = Date.parse(s);
  return Number.isFinite(ms) ? ms : null;
}

/* ───────────────────────────────────────────────────────────────────── fetching */

/** `GET {explorer}/api/v2/addresses/{address}/logs`. */
function logsUrl(address: string, page: Record<string, string> | null): string {
  const base = `${CHAIN.blockExplorers.default.url}/api/v2/addresses/${address}/logs`;
  if (!page) return base;
  const qs = new URLSearchParams(page).toString();
  return qs === "" ? base : `${base}?${qs}`;
}

/**
 * The index said no.
 *
 * A distinct class so the UI can tell "the index is unavailable" from "the vault has no
 * events", which is the distinction this whole feature turns on.
 */
export class FlowIndexError extends Error {
  readonly status: number | null;
  /** True for HTTP 429: the caller should back off, not retry in a loop. */
  readonly rateLimited: boolean;

  constructor(message: string, status: number | null) {
    super(message);
    this.name = "FlowIndexError";
    this.status = status;
    this.rateLimited = status === 429;
  }
}

/** `next_page_params` narrowed to the string map `URLSearchParams` can take. */
function nextPageParams(value: unknown): Record<string, string> | null {
  if (value === null || value === undefined || typeof value !== "object") return null;
  const out: Record<string, string> = {};
  for (const [k, v] of Object.entries(value as Record<string, unknown>)) {
    const s = asString(v);
    if (s !== null) out[k] = s;
  }
  return Object.keys(out).length === 0 ? null : out;
}

async function fetchLogsPage(
  address: string,
  page: Record<string, string> | null,
  signal: AbortSignal | undefined,
): Promise<{ items: RawLog[]; next: Record<string, string> | null }> {
  // react-query's own signal aborts on unmount/refetch; the timer turns a hanging index
  // into a reported failure instead of a permanent spinner. Both feed one controller.
  const controller = new AbortController();
  const onAbort = () => controller.abort();
  signal?.addEventListener("abort", onAbort, { once: true });
  const timer = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);

  let res: Response;
  try {
    res = await fetch(logsUrl(address, page), {
      headers: { accept: "application/json" },
      signal: controller.signal,
    });
  } catch (err) {
    if (signal?.aborted) throw err; // a real cancellation, not an index failure
    const reason = err instanceof Error ? err.message : "network error";
    throw new FlowIndexError(`Could not reach the explorer index (${reason}).`, null);
  } finally {
    clearTimeout(timer);
    signal?.removeEventListener("abort", onAbort);
  }

  if (!res.ok) {
    throw new FlowIndexError(
      res.status === 429
        ? "The explorer index is rate-limiting this browser."
        : `The explorer index answered HTTP ${res.status}.`,
      res.status,
    );
  }

  let body: RawLogsPage;
  try {
    body = (await res.json()) as RawLogsPage;
  } catch {
    throw new FlowIndexError("The explorer index returned a response this app could not parse.", res.status);
  }

  return {
    items: Array.isArray(body.items) ? (body.items as RawLog[]) : [],
    next: nextPageParams(body.next_page_params),
  };
}

/** Walk up to `maxPages` pages of logs for one address. Newest first, as the index serves them. */
async function fetchVaultLogs(
  address: string,
  maxPages: number,
  signal: AbortSignal | undefined,
): Promise<{ items: RawLog[]; hasMore: boolean }> {
  const items: RawLog[] = [];
  let page: Record<string, string> | null = null;
  for (let i = 0; i < maxPages; i += 1) {
    const res = await fetchLogsPage(address, page, signal);
    items.push(...res.items);
    if (!res.next) return { items, hasMore: false };
    page = res.next;
  }
  // Pages remain: `loadMore` can ask for them, and the UI must not imply this is everything.
  return { items, hasMore: true };
}

/* ──────────────────────────────────────────────────────────────── normalisation */

/**
 * A partially-parsed flow: everything except the wallet, which the join fills in.
 *
 * Split out because attribution needs a second pass over the whole set — the request that
 * names the wallet may sit many blocks below the settlement that does not.
 */
interface PartialFlow extends Omit<FlowEvent, "user" | "attribution"> {
  /** The wallet from the event's own indexed topic, when it has one. */
  directUser: string | null;
}

function parseLog(raw: RawLog, vaultId: ChainVaultId, vaultSymbol: string): PartialFlow | null {
  const decoded = raw.decoded ?? null;
  const name = eventName(decoded);
  if (name === null) return null; // undecoded log: the index had no ABI match

  const kind = EVENT_KIND[name];
  if (!kind) return null; // a real event, but operational (MarginPosted &c.), not a user flow

  const txHash = asString(raw.transaction_hash);
  const blockNumber = asInt(raw.block_number);
  const logIndex = asInt(raw.index);
  if (txHash === null || blockNumber === null || logIndex === null) return null;

  const receiptRaw = paramBigint(decoded, "receiptId");
  const expiresAt = paramBigint(decoded, "expiresAt");

  // ── the decimal domains, one converter each. See the file header for the checked figures.
  const amountIn = paramBigint(decoded, "amountIn");
  const amountOut = paramBigint(decoded, "amountOut");
  const certIn = paramBigint(decoded, "certIn");
  const certOut = paramBigint(decoded, "certOut");
  const feeRaw = paramBigint(decoded, "fee");
  // `Minted`/`Redeemed` name it `px18`; `MintSettled` names the keeper's fill `fillPx18`.
  const pxRaw = paramBigint(decoded, "px18") ?? paramBigint(decoded, "fillPx18");

  // COLLATERAL, 6 dp — amountIn on the way in, amountOut on the way out. Never both.
  const collateral6 = amountIn ?? amountOut;
  // CERTIFICATE, 18 dp — certOut on a mint, certIn on a redemption.
  const cert18 = certOut ?? certIn;

  return {
    id: `${txHash}:${logIndex}`,
    kind,
    label: KIND_LABEL[kind],
    side: KIND_SIDE[kind],
    vaultId,
    vaultSymbol,
    vaultAddress: asString(raw.address?.hash) ?? "",
    blockNumber,
    timeMs: timestampMs(raw.block_timestamp),
    txHash,
    txUrl: explorerTxUrl(txHash),
    logIndex,
    collateral: collateral6 === null ? null : fromCollateral(collateral6),
    cert: cert18 === null ? null : fromCert(cert18),
    price: pxRaw === null ? null : fromPrice18(pxRaw),
    fee: feeRaw === null ? null : fromCollateral(feeRaw),
    receiptId: receiptRaw === null ? null : receiptRaw.toString(),
    expiresAtSec: expiresAt === null ? null : Number(expiresAt),
    directUser: paramAddress(decoded, "user"),
  };
}

/** The join key. Receipt ids are per-vault counters, so the vault is part of the identity. */
function receiptKey(vaultId: ChainVaultId, receiptId: string): string {
  return `${vaultId}:${receiptId}`;
}

/**
 * Attribute every flow to a wallet, or admit it cannot be.
 *
 * Pass 1 collects `(vault, receiptId) -> user` from the events that carry a `user` topic.
 * Pass 2 stamps the two that do not (`MintSettled`, `RedeemClaimed`). No fallback, no
 * nearest-neighbour, no "probably the same wallet as the previous row": an unmatched
 * receipt stays `unattributed`.
 */
function attribute(partials: PartialFlow[]): FlowEvent[] {
  const owner = new Map<string, string>();
  for (const p of partials) {
    if (p.directUser !== null && p.receiptId !== null) {
      owner.set(receiptKey(p.vaultId, p.receiptId), p.directUser);
    }
  }

  return partials.map(({ directUser, ...rest }) => {
    if (directUser !== null) return { ...rest, user: directUser, attribution: "direct" as const };
    if (rest.receiptId !== null) {
      const joined = owner.get(receiptKey(rest.vaultId, rest.receiptId));
      if (joined !== undefined) return { ...rest, user: joined, attribution: "joined" as const };
    }
    return { ...rest, user: null, attribution: "unattributed" as const };
  });
}

/** Newest first: block descending, then log index descending within a block. */
function newestFirst(a: FlowEvent, b: FlowEvent): number {
  if (a.blockNumber !== b.blockNumber) return b.blockNumber - a.blockNumber;
  return b.logIndex - a.logIndex;
}

/* ────────────────────────────────────────────────────────────────── the fetch job */

interface FlowsSnapshot {
  flows: FlowEvent[];
  /** True when at least one vault still had pages the current depth did not reach. */
  hasMore: boolean;
  /** Decoded vault events that are not user flows (`MarginPosted` &c.), plus undecoded logs. */
  ignored: number;
  /** Vaults whose logs came back, so a partial index can be reported as partial. */
  vaultsRead: number;
}

async function fetchFlows(maxPages: number, signal: AbortSignal | undefined): Promise<FlowsSnapshot> {
  // Addresses come from the generated address book via `vaultAddresses`, never a literal
  // here: one hand-copied vault address is a whole history attributed to the wrong contract.
  const targets = CHAIN_VAULT_IDS.map((id) => ({
    id,
    symbol: chainVaultMeta(id).name,
    address: vaultAddresses(id).vault as string,
  }));

  // One request per routed vault, in parallel — two vaults today. If ANY vault fails the
  // whole snapshot fails: a list missing one vault's history, presented as the history, is
  // the same lie as an empty list.
  const results = await Promise.all(
    targets.map((t) => fetchVaultLogs(t.address, maxPages, signal)),
  );

  const partials: PartialFlow[] = [];
  let ignored = 0;
  results.forEach((res, i) => {
    const t = targets[i];
    for (const raw of res.items) {
      const parsed = parseLog(raw, t.id, t.symbol);
      if (parsed === null) ignored += 1;
      else partials.push(parsed);
    }
  });

  return {
    flows: attribute(partials).sort(newestFirst),
    hasMore: results.some((r) => r.hasMore),
    ignored,
    vaultsRead: targets.length,
  };
}

/* ──────────────────────────────────────────────────────────────────────── hook */

export interface FlowsResult {
  /** Every flow across the routed vaults, newest first. Empty while loading or on failure. */
  flows: FlowEvent[];
  /**
   * `flows` filtered to `address`, with unattributed settlements REMOVED.
   *
   * `null` when no address was supplied. `null` is not `[]`: "no wallet connected" and
   * "this wallet has no flows" are different sentences and the view must say the right one.
   */
  mine: FlowEvent[] | null;
  /** How many settlements could not be tied to any wallet. See the header. */
  unattributed: number;
  /**
   * How many of `unattributed` are hidden from `mine`. Equal to `unattributed` by
   * construction — kept as its own field so a per-wallet view can state the omission
   * without re-deriving why.
   */
  hiddenFromMine: number;
  /** Vault events that are not user flows, plus any log the index could not decode. */
  ignored: number;

  isLoading: boolean;
  isFetching: boolean;
  /**
   * THE important flag. True when the index could not be read AND there is nothing cached
   * to fall back on: unreachable, timed out, rate-limited or unparseable. A view seeing
   * this MUST say the index is unavailable and MUST NOT render an empty list.
   */
  indexUnavailable: boolean;
  /**
   * The last read failed but an earlier one succeeded, so `flows` is real history that is
   * simply not current.
   *
   * Kept apart from `indexUnavailable` because throwing away a good list on a failed
   * REFRESH would hide events the user has already been shown. A view should render the
   * list and say it may be behind — the failure belongs on screen either way.
   */
  indexStale: boolean;
  /** A sentence fit for the screen when `indexUnavailable` or `indexStale`. */
  indexError: string | null;
  /** True specifically for HTTP 429, which deserves "try again shortly" rather than "broken". */
  rateLimited: boolean;

  /** ms epoch of the last successful fetch, for an "index read Xs ago" line. `0` if never. */
  fetchedAt: number;
  /** True when the index still had pages beyond the current depth. */
  hasMore: boolean;
  /** True once `loadMore` has walked to `MAX_PAGES`. */
  atPageCeiling: boolean;
  loadMore: () => void;
  refetch: () => void;

  /** Provenance, carried with the data so a renderer always has it in hand. */
  source: typeof FLOW_SOURCE;
  sourceDetail: string;
  sourceUrl: string;
}

/**
 * Decoded flow history for the routed vaults.
 *
 * @param options.address  the connected wallet, for `mine`. Deliberately NOT part of the
 *                         query key: the index request is per-vault and identical for every
 *                         visitor, so keying on the wallet would fetch the same JSON again
 *                         for each connection. Filtering happens locally.
 */
export function useFlows(options?: { address?: string | undefined }): FlowsResult {
  const [pages, setPages] = useState(PAGE_STEP);

  const query = useQuery<FlowsSnapshot, Error>({
    queryKey: ["usecert", "explorer-flows", CHAIN.id, pages],
    queryFn: ({ signal }) => fetchFlows(pages, signal),
    staleTime: STALE_TIME_MS,
    gcTime: 5 * 60_000,
    // No `refetchInterval` on purpose: this is history against a shared public index.
    refetchOnWindowFocus: false,
    retry: (attempt, error) => {
      // A rate-limit is the one failure retrying makes worse.
      if (error instanceof FlowIndexError && error.rateLimited) return false;
      return attempt < 1;
    },
  });

  const snapshot = query.data;
  const flows = snapshot?.flows ?? [];

  const wallet = options?.address?.toLowerCase();

  const mine = useMemo<FlowEvent[] | null>(() => {
    if (!wallet) return null;
    // `attribution === "unattributed"` rows have `user === null` and are excluded by this
    // comparison automatically — a receipt whose owner is unknown is never anybody's.
    return flows.filter((f) => f.user === wallet);
  }, [flows, wallet]);

  const unattributed = useMemo(
    () => flows.filter((f) => f.attribution === "unattributed").length,
    [flows],
  );

  const loadMore = useCallback(() => {
    setPages((p) => Math.min(p + PAGE_STEP, MAX_PAGES));
  }, []);

  const refetch = useCallback(() => {
    void query.refetch();
  }, [query]);

  const error = query.error;
  // A failed read with nothing cached is "unavailable"; a failed read over good cached
  // history is "stale". Collapsing the two would either hide a failure or discard a list.
  const readFailed = query.isError;
  const indexUnavailable = readFailed && snapshot === undefined;
  const indexStale = readFailed && snapshot !== undefined;

  return {
    flows,
    mine,
    unattributed,
    hiddenFromMine: unattributed,
    ignored: snapshot?.ignored ?? 0,

    isLoading: query.isLoading,
    isFetching: query.isFetching,
    indexUnavailable,
    indexStale,
    indexError: readFailed ? (error?.message ?? "The explorer index could not be read.") : null,
    rateLimited: error instanceof FlowIndexError && error.rateLimited,

    fetchedAt: query.dataUpdatedAt,
    hasMore: snapshot?.hasMore ?? false,
    atPageCeiling: pages >= MAX_PAGES,
    loadMore,
    refetch,

    source: FLOW_SOURCE,
    sourceDetail: FLOW_SOURCE_DETAIL,
    sourceUrl: CHAIN.blockExplorers.default.url,
  };
}
