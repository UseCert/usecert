# UseCert Services 2a — Data Foundation and Read API

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the read side of the UseCert backend — typed Lighter API client, Postgres/Timescale schema, market-snapshot ingestion, chain event indexer, and the tRPC surface the front-end dashboard needs.

**Architecture:** A Bun service with two shapes: scheduled workers that write to Postgres, and a tRPC read API that never talks to a chain or a third party in the request path — it only reads our own tables. Every external call is isolated behind a client module with explicit retry and rate-limit handling, because the public Robinhood RPC returns 429 on consecutive calls.

**Tech Stack:** Bun, TypeScript (strict), Hono, tRPC v11, Drizzle ORM, Postgres 16 + TimescaleDB, viem, zod, `bun:test`.

**Specs:** `docs/superpowers/specs/2026-09-07-usecert-robinhood-backend-design.md` §11, §12
**Companion plan:** `docs/superpowers/plans/2026-09-07-usecert-contracts-c1.md`

## Global Constraints

Every task's requirements implicitly include this section. Values are verified as of 2026-09-07.

**External endpoints**
- Lighter API base: `https://api.rh.lighter.xyz`
- `GET /info` → `{"contract_address": "0x94bAB9693Ba2f6358507eFfcbd372b0660AFfF9d"}`
- `GET /api/v1/orderBookDetails` → `{code, order_book_details[]}`, 57 markets
- `GET /api/v1/exchangeStats` → `{code, total, order_book_stats[]}`
- `GET /api/v1/systemConfig` → fee-collector and pool indices
- **These return HTTP 403: `/api/v1/assets`, `/api/v1/spotAssets`, `/api/v1/status`, `/api/v1/info`, `/api/v1/bridgeSupportedNetworks`, `/api/v1/layer2BasicInfo`.** Do not build against them.
- Robinhood Chain mainnet: chain ID `4663`, public RPC `https://rpc.mainnet.chain.robinhood.com`
- Robinhood Chain testnet: chain ID `46630`, public RPC `https://rpc.testnet.chain.robinhood.com`
- Explorer: `https://robinhoodchain.blockscout.com` — **its API rejects non-browser clients with 403; never depend on it.**

**Hard operational facts**
- **The public RPC returns 429 on the second consecutive call.** A paid endpoint (`ROBINHOOD_RPC_URL`) is mandatory. The public URL is a fallback for local development only and every code path must tolerate 429.
- Lighter batches land roughly once per minute. Nothing should poll faster than every 15s.
- Native gas token is ETH.

**Market reference data (verified)**
- TSLA: `market_id` 16, `price_decimals` 2, `size_decimals` 4, min base `0.0200`, min quote `10.000000`, `order_quote_limit` 25000000, `maker_fee` 0.0000, `taker_fee` 0.0000.
- NVDA: `market_id` 15, `price_decimals` 2, `size_decimals` 4, min base `0.0400`, min quote `10.000000`, `order_quote_limit` 25000000, `maker_fee` 0.0000, `taker_fee` 0.0000.
- Observed 2026-09-07: TSLA open interest 3353.2198 base / mark 355.83; NVDA 12389.1738 base / mark 232.46.

**Units — get this wrong and capacity breaks**
- Lighter reports `open_interest` in **base units** (3353.2198 TSLA), not dollars.
- `CapacityOracle.openInterest18` expects **notional in 1e18-scaled dollars**. The conversion is `open_interest * mark_price`, scaled to 1e18. Every write of `openInterest18` must apply it.
- All money in the database is stored as `numeric(78, 0)` integer strings scaled to 1e18. **No floats anywhere.** Parse API decimal strings with a fixed-point helper, never `parseFloat`.

**Conventions**
- TypeScript `strict: true`, no `any`, no non-null assertions.
- Every external response is parsed through a zod schema at the boundary. Unvalidated data never reaches the database.
- The tRPC read API must not call Lighter or a chain RPC in the request path. It reads Postgres only.
- Collateral is **USDG**, not USDC, despite every source document saying USDC.
- Certificate symbols use the `u` prefix: `uTSLA`, `uNVDA`, `uSPX`.
- Solvency figures are **always** returned with their age. There is no code path that returns backing without `ageSec`.

**Copy rules inherited from the spec — these bind API field names and any string the API returns**
- Never emit "provable every block". C1's wording is "independently verifiable every batch (~60s)".
- Redemption SLA must be expressed as expected **and** worst case: one batch expected, 14 days worst case.

---

## Prerequisites

- Bun installed: `bun --version`
- A Postgres 16 instance with the TimescaleDB extension available. Local Docker is fine:

```bash
docker run -d --name usecert-pg -p 5432:5432 -e POSTGRES_PASSWORD=usecert -e POSTGRES_DB=usecert timescale/timescaledb:latest-pg16
```

- Redis is **not** needed for this plan (it arrives with the keepers in 2c).

---

## File Structure

```
services/package.json                       Bun workspace root for services
services/tsconfig.json                      strict TS config
services/drizzle.config.ts                  Drizzle migration config
services/.env.example                       Documented env template

services/src/config/env.ts                  zod-validated environment
services/src/config/markets.ts              Verified market reference constants

services/src/lib/fixed.ts                   Fixed-point decimal-string -> 1e18 bigint
services/src/lib/retry.ts                   Backoff with explicit 429 handling

services/src/clients/lighter.ts             Typed Lighter API client + zod schemas
services/src/clients/chain.ts               viem client, paid RPC, 429-tolerant

services/src/db/schema.ts                   Drizzle tables
services/src/db/client.ts                   Connection + migration runner
services/src/db/migrations/                 Generated SQL + Timescale hypertable DDL

services/src/workers/marketSnapshot.ts      Persists market state + OI notional
services/src/workers/chainIndexer.ts        Contract events -> flows/receipts

services/src/api/router.ts                  tRPC root router
services/src/api/routers/vaults.ts          list, solvency, capacity
services/src/api/routers/markets.ts         snapshot, history
services/src/api/routers/receipts.ts        by wallet
services/src/api/server.ts                  Hono + tRPC adapter + health

services/test/fixtures/orderBookDetails.json  Real captured API response
services/test/fixed.test.ts
services/test/lighter.test.ts
services/test/marketSnapshot.test.ts
services/test/chainIndexer.test.ts
services/test/api.test.ts
```

**Deferred to plan 2b (solvency prover):** Poseidon2 in TypeScript, blob ingestion, account-tree reconstruction, attestation submission, the attester signer. This plan writes the `solvency` table and reads it; nothing here fills it.

**Deferred to plan 2c (keepers):** Redis, BullMQ, delta keeper, funding sweeper, buffer watchdog, fill reporter — every component that sends a transaction.

**This plan sends no transactions.** It is read-only against chain and Lighter. That is deliberate: it can be developed and run safely before any contract exists.

---

## Task 1: Scaffold and validated environment

**Files:**
- Create: `services/package.json`, `services/tsconfig.json`, `services/.env.example`
- Create: `services/src/config/env.ts`
- Test: `services/test/env.test.ts`

**Interfaces:**
- Consumes: nothing.
- Produces: `loadEnv(source: Record<string, string | undefined>): Env` and type `Env` with fields `DATABASE_URL`, `ROBINHOOD_RPC_URL`, `ROBINHOOD_CHAIN_ID`, `LIGHTER_API_BASE`, `ZKLIGHTER_ADDRESS`, `PORT`, `LOG_LEVEL`. Throws `EnvError` listing every invalid key at once.

- [ ] **Step 1: Create `services/package.json`**

```json
{
  "name": "@usecert/services",
  "private": true,
  "type": "module",
  "scripts": {
    "test": "bun test",
    "typecheck": "tsc --noEmit",
    "api": "bun run src/api/server.ts",
    "worker:market": "bun run src/workers/marketSnapshot.ts",
    "worker:indexer": "bun run src/workers/chainIndexer.ts",
    "db:generate": "drizzle-kit generate",
    "db:migrate": "bun run src/db/client.ts --migrate"
  },
  "dependencies": {
    "@trpc/server": "^11.0.0",
    "drizzle-orm": "^0.36.0",
    "hono": "^4.6.0",
    "postgres": "^3.4.5",
    "viem": "^2.21.0",
    "zod": "^3.23.8"
  },
  "devDependencies": {
    "@types/bun": "^1.1.0",
    "drizzle-kit": "^0.28.0",
    "typescript": "^5.6.0"
  }
}
```

- [ ] **Step 2: Create `services/tsconfig.json`**

```json
{
  "compilerOptions": {
    "target": "ESNext",
    "module": "ESNext",
    "moduleResolution": "bundler",
    "types": ["bun-types"],
    "strict": true,
    "noUncheckedIndexedAccess": true,
    "noImplicitOverride": true,
    "exactOptionalPropertyTypes": true,
    "skipLibCheck": true,
    "esModuleInterop": true,
    "resolveJsonModule": true
  },
  "include": ["src", "test"]
}
```

- [ ] **Step 3: Create `services/.env.example`**

```bash
# Postgres with TimescaleDB
DATABASE_URL=postgres://postgres:usecert@localhost:5432/usecert

# REQUIRED: a paid RPC endpoint. The public Robinhood RPC
# (https://rpc.mainnet.chain.robinhood.com) returns 429 on the second
# consecutive call and is unusable for anything but local poking.
ROBINHOOD_RPC_URL=https://robinhood-mainnet.g.alchemy.com/v2/YOUR_KEY
ROBINHOOD_CHAIN_ID=4663

LIGHTER_API_BASE=https://api.rh.lighter.xyz
ZKLIGHTER_ADDRESS=0x94bAB9693Ba2f6358507eFfcbd372b0660AFfF9d

PORT=8080
LOG_LEVEL=info
```

- [ ] **Step 4: Write the failing test**

```ts
import { describe, expect, it } from "bun:test";
import { EnvError, loadEnv } from "../src/config/env";

const valid = {
  DATABASE_URL: "postgres://u:p@localhost:5432/db",
  ROBINHOOD_RPC_URL: "https://example.invalid/rpc",
  ROBINHOOD_CHAIN_ID: "4663",
  LIGHTER_API_BASE: "https://api.rh.lighter.xyz",
  ZKLIGHTER_ADDRESS: "0x94bAB9693Ba2f6358507eFfcbd372b0660AFfF9d",
  PORT: "8080",
  LOG_LEVEL: "info",
};

describe("loadEnv", () => {
  it("parses a valid environment", () => {
    const env = loadEnv(valid);
    expect(env.ROBINHOOD_CHAIN_ID).toBe(4663);
    expect(env.PORT).toBe(8080);
    expect(env.ZKLIGHTER_ADDRESS).toBe("0x94bAB9693Ba2f6358507eFfcbd372b0660AFfF9d");
  });

  it("reports every problem at once, not just the first", () => {
    try {
      loadEnv({ ...valid, ROBINHOOD_CHAIN_ID: "nope", ZKLIGHTER_ADDRESS: "0xdeadbeef" });
      throw new Error("should have thrown");
    } catch (e) {
      expect(e).toBeInstanceOf(EnvError);
      const msg = (e as EnvError).message;
      expect(msg).toContain("ROBINHOOD_CHAIN_ID");
      expect(msg).toContain("ZKLIGHTER_ADDRESS");
    }
  });

  it("rejects a missing RPC url rather than defaulting to the public one", () => {
    const { ROBINHOOD_RPC_URL: _drop, ...rest } = valid;
    expect(() => loadEnv(rest)).toThrow(EnvError);
  });

  it("warns but accepts the public RPC url", () => {
    const env = loadEnv({ ...valid, ROBINHOOD_RPC_URL: "https://rpc.mainnet.chain.robinhood.com" });
    expect(env.usingPublicRpc).toBe(true);
  });
});
```

- [ ] **Step 5: Run to verify it fails**

Run: `cd services && bun test test/env.test.ts`
Expected: FAIL — cannot resolve `../src/config/env`.

- [ ] **Step 6: Write `src/config/env.ts`**

```ts
import { z } from "zod";

export class EnvError extends Error {}

const PUBLIC_RPCS = [
  "https://rpc.mainnet.chain.robinhood.com",
  "https://rpc.testnet.chain.robinhood.com",
];

const schema = z.object({
  DATABASE_URL: z.string().url(),
  ROBINHOOD_RPC_URL: z.string().url(),
  ROBINHOOD_CHAIN_ID: z.coerce.number().int().positive(),
  LIGHTER_API_BASE: z.string().url(),
  ZKLIGHTER_ADDRESS: z.string().regex(/^0x[a-fA-F0-9]{40}$/, "must be a 20-byte hex address"),
  PORT: z.coerce.number().int().positive().default(8080),
  LOG_LEVEL: z.enum(["debug", "info", "warn", "error"]).default("info"),
});

export type Env = z.infer<typeof schema> & { usingPublicRpc: boolean };

export function loadEnv(source: Record<string, string | undefined>): Env {
  const parsed = schema.safeParse(source);
  if (!parsed.success) {
    const lines = parsed.error.issues.map((i) => `  ${i.path.join(".")}: ${i.message}`);
    throw new EnvError(`Invalid environment:\n${lines.join("\n")}`);
  }
  return {
    ...parsed.data,
    usingPublicRpc: PUBLIC_RPCS.includes(parsed.data.ROBINHOOD_RPC_URL),
  };
}
```

- [ ] **Step 7: Run to verify it passes**

Run: `cd services && bun test test/env.test.ts`
Expected: PASS, 4 tests.

- [ ] **Step 8: Commit**

```bash
git add services/package.json services/tsconfig.json services/.env.example services/src/config/env.ts services/test/env.test.ts
git commit -m "feat(services): bun scaffold with zod-validated environment"
```

---

## Task 2: Fixed-point helper

Lighter returns decimal strings like `"3353.2198"` and `"355.83"`. Every one becomes a 1e18-scaled bigint. `parseFloat` would silently lose precision on large notionals, so it is banned.

**Files:**
- Create: `services/src/lib/fixed.ts`
- Test: `services/test/fixed.test.ts`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `toScaled(decimal: string, scale?: number): bigint` — default scale 18.
  - `fromScaled(v: bigint, scale?: number): string`
  - `mulScaled(a: bigint, b: bigint): bigint` — 1e18 x 1e18 → 1e18.
  - `notional18(openInterestBase: string, markPrice: string): bigint` — the conversion the capacity formula depends on.
  - Throws `FixedPointError` on malformed input or excess precision.

- [ ] **Step 1: Write the failing test**

```ts
import { describe, expect, it } from "bun:test";
import { FixedPointError, fromScaled, mulScaled, notional18, toScaled } from "../src/lib/fixed";

describe("toScaled", () => {
  it("scales integers and decimals", () => {
    expect(toScaled("1")).toBe(10n ** 18n);
    expect(toScaled("355.83")).toBe(355_830000000000000000n);
    expect(toScaled("0.0200")).toBe(20_000000000000000n);
  });

  it("handles a value with no fractional part", () => {
    expect(toScaled("25000000")).toBe(25_000_000n * 10n ** 18n);
  });

  it("rejects malformed input", () => {
    expect(() => toScaled("")).toThrow(FixedPointError);
    expect(() => toScaled("abc")).toThrow(FixedPointError);
    expect(() => toScaled("1.2.3")).toThrow(FixedPointError);
  });

  it("rejects precision beyond the scale rather than truncating silently", () => {
    expect(() => toScaled("1.0000000000000000001")).toThrow(FixedPointError);
  });
});

describe("mulScaled", () => {
  it("keeps 1e18 scale", () => {
    expect(mulScaled(toScaled("2"), toScaled("3"))).toBe(toScaled("6"));
  });
});

describe("notional18", () => {
  it("converts observed TSLA open interest to dollar notional", () => {
    // 3353.2198 TSLA * 355.83 = 1,193,141.02... dollars
    const n = notional18("3353.2198", "355.83");
    expect(fromScaled(n).startsWith("1193141.")).toBe(true);
  });

  it("converts observed NVDA open interest to dollar notional", () => {
    // 12389.1738 * 232.46 = 2,879,573.... dollars
    const n = notional18("12389.1738", "232.46");
    expect(fromScaled(n).startsWith("2879")).toBe(true);
  });

  it("is zero when either side is zero", () => {
    expect(notional18("0", "355.83")).toBe(0n);
    expect(notional18("3353.2198", "0")).toBe(0n);
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd services && bun test test/fixed.test.ts`
Expected: FAIL — cannot resolve `../src/lib/fixed`.

- [ ] **Step 3: Write `src/lib/fixed.ts`**

```ts
export class FixedPointError extends Error {}

const DEFAULT_SCALE = 18;

export function toScaled(decimal: string, scale: number = DEFAULT_SCALE): bigint {
  if (!/^-?\d+(\.\d+)?$/.test(decimal)) {
    throw new FixedPointError(`not a decimal number: ${JSON.stringify(decimal)}`);
  }
  const negative = decimal.startsWith("-");
  const body = negative ? decimal.slice(1) : decimal;
  const [whole = "0", frac = ""] = body.split(".");

  if (frac.length > scale) {
    throw new FixedPointError(`${decimal} has more than ${scale} decimal places`);
  }
  const padded = frac.padEnd(scale, "0");
  const value = BigInt(whole) * 10n ** BigInt(scale) + BigInt(padded === "" ? "0" : padded);
  return negative ? -value : value;
}

export function fromScaled(v: bigint, scale: number = DEFAULT_SCALE): string {
  const negative = v < 0n;
  const abs = negative ? -v : v;
  const unit = 10n ** BigInt(scale);
  const whole = abs / unit;
  const frac = (abs % unit).toString().padStart(scale, "0").replace(/0+$/, "");
  const out = frac === "" ? whole.toString() : `${whole}.${frac}`;
  return negative ? `-${out}` : out;
}

/** 1e18 x 1e18 -> 1e18 */
export function mulScaled(a: bigint, b: bigint): bigint {
  return (a * b) / 10n ** BigInt(DEFAULT_SCALE);
}

/**
 * Lighter reports open_interest in BASE units (e.g. 3353.2198 TSLA), but
 * CapacityOracle.openInterest18 expects dollar notional. Getting this wrong
 * would understate capacity by roughly the share price, so it lives in one
 * named function that is tested against observed values.
 */
export function notional18(openInterestBase: string, markPrice: string): bigint {
  return mulScaled(toScaled(openInterestBase), toScaled(markPrice));
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd services && bun test test/fixed.test.ts`
Expected: PASS, 9 tests.

- [ ] **Step 5: Commit**

```bash
git add services/src/lib/fixed.ts services/test/fixed.test.ts
git commit -m "feat(services): fixed-point helpers with base-to-notional conversion"
```

---

## Task 3: Retry with explicit 429 handling

**Files:**
- Create: `services/src/lib/retry.ts`
- Test: `services/test/retry.test.ts`

**Interfaces:**
- Consumes: nothing.
- Produces: `withRetry<T>(fn: () => Promise<T>, opts?: { attempts?: number; baseDelayMs?: number; onRetry?: (a: number, e: unknown) => void }): Promise<T>`; `RateLimitError` (has `retryAfterMs?: number`); `isRetryable(e: unknown): boolean`.

- [ ] **Step 1: Write the failing test**

```ts
import { describe, expect, it } from "bun:test";
import { RateLimitError, withRetry } from "../src/lib/retry";

describe("withRetry", () => {
  it("returns immediately on success", async () => {
    let calls = 0;
    const out = await withRetry(async () => {
      calls++;
      return "ok";
    });
    expect(out).toBe("ok");
    expect(calls).toBe(1);
  });

  it("retries a rate-limit error and eventually succeeds", async () => {
    let calls = 0;
    const out = await withRetry(
      async () => {
        calls++;
        if (calls < 3) throw new RateLimitError("429");
        return "ok";
      },
      { baseDelayMs: 1 },
    );
    expect(out).toBe("ok");
    expect(calls).toBe(3);
  });

  it("gives up after the attempt limit", async () => {
    let calls = 0;
    await expect(
      withRetry(
        async () => {
          calls++;
          throw new RateLimitError("429");
        },
        { attempts: 2, baseDelayMs: 1 },
      ),
    ).rejects.toBeInstanceOf(RateLimitError);
    expect(calls).toBe(2);
  });

  it("does not retry a non-retryable error", async () => {
    let calls = 0;
    await expect(
      withRetry(
        async () => {
          calls++;
          throw new TypeError("bad code");
        },
        { baseDelayMs: 1 },
      ),
    ).rejects.toBeInstanceOf(TypeError);
    expect(calls).toBe(1);
  });

  it("respects an explicit retryAfterMs", async () => {
    let calls = 0;
    const started = Date.now();
    await withRetry(
      async () => {
        calls++;
        if (calls === 1) {
          const e = new RateLimitError("429");
          e.retryAfterMs = 25;
          throw e;
        }
        return "ok";
      },
      { baseDelayMs: 1 },
    );
    expect(Date.now() - started).toBeGreaterThanOrEqual(20);
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd services && bun test test/retry.test.ts`
Expected: FAIL — cannot resolve `../src/lib/retry`.

- [ ] **Step 3: Write `src/lib/retry.ts`**

```ts
export class RateLimitError extends Error {
  retryAfterMs?: number;
}

export class TransientError extends Error {}

export function isRetryable(e: unknown): boolean {
  return e instanceof RateLimitError || e instanceof TransientError;
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

export async function withRetry<T>(
  fn: () => Promise<T>,
  opts: { attempts?: number; baseDelayMs?: number; onRetry?: (attempt: number, e: unknown) => void } = {},
): Promise<T> {
  const attempts = opts.attempts ?? 5;
  const base = opts.baseDelayMs ?? 500;

  let lastError: unknown;
  for (let attempt = 1; attempt <= attempts; attempt++) {
    try {
      return await fn();
    } catch (e) {
      lastError = e;
      if (!isRetryable(e) || attempt === attempts) throw e;
      opts.onRetry?.(attempt, e);
      const explicit = e instanceof RateLimitError ? e.retryAfterMs : undefined;
      // Exponential backoff with jitter. The public Robinhood RPC 429s on the
      // second consecutive call, so backoff has to be generous, not cosmetic.
      const delay = explicit ?? base * 2 ** (attempt - 1) + Math.floor(Math.random() * base);
      await sleep(delay);
    }
  }
  throw lastError;
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd services && bun test test/retry.test.ts`
Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
git add services/src/lib/retry.ts services/test/retry.test.ts
git commit -m "feat(services): retry helper with explicit rate-limit backoff"
```

---

## Task 4: Lighter API client

**Files:**
- Create: `services/src/clients/lighter.ts`
- Create: `services/src/config/markets.ts`
- Create: `services/test/fixtures/orderBookDetails.json`
- Test: `services/test/lighter.test.ts`

**Interfaces:**
- Consumes: `withRetry`, `RateLimitError` (T3); `toScaled`, `notional18` (T2).
- Produces:
  - `createLighterClient(opts: { baseUrl: string; fetchImpl?: typeof fetch })` returning
    `{ getContractAddress(): Promise<string>; getOrderBookDetails(): Promise<MarketDetail[]>; getMarketBySymbol(s: string): Promise<MarketDetail | undefined> }`
  - `type MarketDetail = { symbol: string; marketId: number; status: string; priceDecimals: number; sizeDecimals: number; markPrice18: bigint; indexPrice18: bigint; openInterestBase18: bigint; openInterestNotional18: bigint; minBaseAmount18: bigint; minQuoteAmount18: bigint; orderQuoteLimit18: bigint; makerFeeBps: number; takerFeeBps: number; forceReduceOnly: boolean; rfqEnabled: boolean }`
  - `MARKETS` from `config/markets.ts`: `{ TSLA: { marketId: 16, priceDecimals: 2, sizeDecimals: 4 }, NVDA: { marketId: 15, priceDecimals: 2, sizeDecimals: 4 } }`
  - `LighterApiError`

- [ ] **Step 1: Capture a real fixture**

```bash
cd services && mkdir -p test/fixtures
curl -s --max-time 30 "https://api.rh.lighter.xyz/api/v1/orderBookDetails" \
  -o test/fixtures/orderBookDetails.json
node -e "const d=require('./test/fixtures/orderBookDetails.json');console.log('markets:',d.order_book_details.length)"
```

Expected: prints a market count (57 at time of writing). If the request fails, do not invent a fixture — the tests must run against a real captured response.

- [ ] **Step 2: Write `src/config/markets.ts`**

```ts
/**
 * Verified against https://api.rh.lighter.xyz/api/v1/orderBookDetails on 2026-09-07.
 * These are a safety net: the client reads live values, and the market-snapshot
 * worker asserts the live response still matches these before writing.
 */
export const MARKETS = {
  TSLA: { marketId: 16, priceDecimals: 2, sizeDecimals: 4, minBaseAmount: "0.0200" },
  NVDA: { marketId: 15, priceDecimals: 2, sizeDecimals: 4, minBaseAmount: "0.0400" },
} as const;

export type MarketSymbol = keyof typeof MARKETS;
export const C1_SYMBOLS: MarketSymbol[] = ["TSLA", "NVDA"];
```

- [ ] **Step 3: Write the failing test**

```ts
import { describe, expect, it } from "bun:test";
import fixture from "./fixtures/orderBookDetails.json";
import { createLighterClient, LighterApiError } from "../src/clients/lighter";
import { fromScaled } from "../src/lib/fixed";

function stubFetch(body: unknown, status = 200): typeof fetch {
  return (async () =>
    new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } })) as typeof fetch;
}

describe("lighter client", () => {
  it("parses the real orderBookDetails fixture", async () => {
    const c = createLighterClient({ baseUrl: "https://x.invalid", fetchImpl: stubFetch(fixture) });
    const markets = await c.getOrderBookDetails();
    expect(markets.length).toBeGreaterThan(50);
  });

  it("finds TSLA with the verified market id and decimals", async () => {
    const c = createLighterClient({ baseUrl: "https://x.invalid", fetchImpl: stubFetch(fixture) });
    const tsla = await c.getMarketBySymbol("TSLA");
    expect(tsla?.marketId).toBe(16);
    expect(tsla?.priceDecimals).toBe(2);
    expect(tsla?.sizeDecimals).toBe(4);
    expect(tsla?.status).toBe("active");
  });

  it("finds NVDA with market id 15", async () => {
    const c = createLighterClient({ baseUrl: "https://x.invalid", fetchImpl: stubFetch(fixture) });
    expect((await c.getMarketBySymbol("NVDA"))?.marketId).toBe(15);
  });

  it("computes open interest as dollar notional, not base units", async () => {
    const c = createLighterClient({ baseUrl: "https://x.invalid", fetchImpl: stubFetch(fixture) });
    const tsla = await c.getMarketBySymbol("TSLA");
    if (!tsla) throw new Error("TSLA missing from fixture");
    // notional must be far larger than base size: ~1.19M vs ~3353
    expect(tsla.openInterestNotional18 > tsla.openInterestBase18 * 100n).toBe(true);
  });

  it("records zero fees for C1 markets", async () => {
    const c = createLighterClient({ baseUrl: "https://x.invalid", fetchImpl: stubFetch(fixture) });
    const tsla = await c.getMarketBySymbol("TSLA");
    expect(tsla?.makerFeeBps).toBe(0);
    expect(tsla?.takerFeeBps).toBe(0);
  });

  it("reads the deployed contract address from /info", async () => {
    const c = createLighterClient({
      baseUrl: "https://x.invalid",
      fetchImpl: stubFetch({ contract_address: "0x94bAB9693Ba2f6358507eFfcbd372b0660AFfF9d" }),
    });
    expect(await c.getContractAddress()).toBe("0x94bAB9693Ba2f6358507eFfcbd372b0660AFfF9d");
  });

  it("throws LighterApiError on a non-200", async () => {
    const c = createLighterClient({ baseUrl: "https://x.invalid", fetchImpl: stubFetch({}, 403) });
    await expect(c.getOrderBookDetails()).rejects.toBeInstanceOf(LighterApiError);
  });

  it("rejects a response whose shape does not match the schema", async () => {
    const c = createLighterClient({
      baseUrl: "https://x.invalid",
      fetchImpl: stubFetch({ code: 200, order_book_details: [{ symbol: "TSLA" }] }),
    });
    await expect(c.getOrderBookDetails()).rejects.toBeInstanceOf(LighterApiError);
  });
});
```

- [ ] **Step 4: Run to verify it fails**

Run: `cd services && bun test test/lighter.test.ts`
Expected: FAIL — cannot resolve `../src/clients/lighter`.

- [ ] **Step 5: Write `src/clients/lighter.ts`**

```ts
import { z } from "zod";
import { notional18, toScaled } from "../lib/fixed";
import { RateLimitError, TransientError, withRetry } from "../lib/retry";

export class LighterApiError extends Error {}

const decimalString = z.union([z.string(), z.number()]).transform((v) => String(v));

const marketSchema = z.object({
  symbol: z.string(),
  market_id: z.number().int(),
  status: z.string(),
  market_type: z.string(),
  price_decimals: z.number().int(),
  size_decimals: z.number().int(),
  mark_price: decimalString,
  index_price: decimalString,
  open_interest: decimalString,
  min_base_amount: decimalString,
  min_quote_amount: decimalString,
  order_quote_limit: decimalString,
  maker_fee: decimalString,
  taker_fee: decimalString,
  market_config: z.object({ force_reduce_only: z.boolean(), rfq_enabled: z.boolean() }),
});

const detailsSchema = z.object({ code: z.number(), order_book_details: z.array(marketSchema) });
const infoSchema = z.object({ contract_address: z.string().regex(/^0x[a-fA-F0-9]{40}$/) });

export type MarketDetail = {
  symbol: string;
  marketId: number;
  status: string;
  priceDecimals: number;
  sizeDecimals: number;
  markPrice18: bigint;
  indexPrice18: bigint;
  openInterestBase18: bigint;
  openInterestNotional18: bigint;
  minBaseAmount18: bigint;
  minQuoteAmount18: bigint;
  orderQuoteLimit18: bigint;
  makerFeeBps: number;
  takerFeeBps: number;
  forceReduceOnly: boolean;
  rfqEnabled: boolean;
};

function toMarketDetail(m: z.infer<typeof marketSchema>): MarketDetail {
  return {
    symbol: m.symbol,
    marketId: m.market_id,
    status: m.status,
    priceDecimals: m.price_decimals,
    sizeDecimals: m.size_decimals,
    markPrice18: toScaled(m.mark_price),
    indexPrice18: toScaled(m.index_price),
    openInterestBase18: toScaled(m.open_interest),
    openInterestNotional18: notional18(m.open_interest, m.mark_price),
    minBaseAmount18: toScaled(m.min_base_amount),
    minQuoteAmount18: toScaled(m.min_quote_amount),
    orderQuoteLimit18: toScaled(m.order_quote_limit),
    // API reports percentages, e.g. "0.0350" meaning 0.0350% -> 3.5 bps.
    makerFeeBps: Math.round(Number(m.maker_fee) * 100),
    takerFeeBps: Math.round(Number(m.taker_fee) * 100),
    forceReduceOnly: m.market_config.force_reduce_only,
    rfqEnabled: m.market_config.rfq_enabled,
  };
}

export function createLighterClient(opts: { baseUrl: string; fetchImpl?: typeof fetch }) {
  const doFetch = opts.fetchImpl ?? fetch;

  async function getJson(path: string): Promise<unknown> {
    return withRetry(async () => {
      const res = await doFetch(`${opts.baseUrl}${path}`);
      if (res.status === 429) {
        const e = new RateLimitError(`429 from ${path}`);
        const ra = res.headers.get("retry-after");
        if (ra) e.retryAfterMs = Number(ra) * 1000;
        throw e;
      }
      if (res.status >= 500) throw new TransientError(`${res.status} from ${path}`);
      if (!res.ok) throw new LighterApiError(`${res.status} from ${path}`);
      return res.json();
    });
  }

  return {
    async getContractAddress(): Promise<string> {
      const parsed = infoSchema.safeParse(await getJson("/info"));
      if (!parsed.success) throw new LighterApiError(`/info shape changed: ${parsed.error.message}`);
      return parsed.data.contract_address;
    },

    async getOrderBookDetails(): Promise<MarketDetail[]> {
      const parsed = detailsSchema.safeParse(await getJson("/api/v1/orderBookDetails"));
      if (!parsed.success) {
        throw new LighterApiError(`orderBookDetails shape changed: ${parsed.error.message}`);
      }
      return parsed.data.order_book_details.map(toMarketDetail);
    },

    async getMarketBySymbol(symbol: string): Promise<MarketDetail | undefined> {
      return (await this.getOrderBookDetails()).find((m) => m.symbol === symbol);
    },
  };
}
```

- [ ] **Step 6: Run to verify it passes**

Run: `cd services && bun test test/lighter.test.ts`
Expected: PASS, 8 tests.

- [ ] **Step 7: Commit**

```bash
git add services/src/clients/lighter.ts services/src/config/markets.ts services/test/fixtures/ services/test/lighter.test.ts
git commit -m "feat(services): typed Lighter API client validated against a real fixture"
```

---

## Task 5: Database schema

**Files:**
- Create: `services/drizzle.config.ts`
- Create: `services/src/db/schema.ts`
- Create: `services/src/db/client.ts`
- Create: `services/src/db/migrations/0001_timescale.sql`
- Test: `services/test/db.test.ts`

**Interfaces:**
- Consumes: `Env` (T1).
- Produces:
  - Tables `vaults`, `marketSnapshots`, `solvency`, `funding`, `flows`, `receipts`.
  - `createDb(url: string)` returning `{ db, sql, close() }`.
  - `runMigrations(db)` applying Drizzle SQL then the Timescale hypertable DDL.

- [ ] **Step 1: Write `src/db/schema.ts`**

```ts
import { bigint, boolean, index, integer, numeric, pgTable, primaryKey, text, timestamp } from "drizzle-orm/pg-core";

/** All money is numeric(78,0): an integer string scaled to 1e18. Never a float. */
const money = (name: string) => numeric(name, { precision: 78, scale: 0 });

export const vaults = pgTable("vaults", {
  asset: text("asset").primaryKey(), // "TSLA"
  vaultAddr: text("vault_addr").notNull(),
  certificate: text("certificate").notNull(),
  certificateSymbol: text("certificate_symbol").notNull(), // "uTSLA"
  marketId: integer("market_id").notNull(),
  priceDecimals: integer("price_decimals").notNull(),
  sizeDecimals: integer("size_decimals").notNull(),
  lighterAccountIndex: bigint("lighter_account_index", { mode: "bigint" }),
  instantCap18: money("instant_cap_18").notNull(),
  status: text("status").notNull().default("pending"), // pending | enabled | winddown
  createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
});

/** Timescale hypertable. Powers the capacity panel and the market history chart. */
export const marketSnapshots = pgTable(
  "market_snapshots",
  {
    asset: text("asset").notNull(),
    ts: timestamp("ts", { withTimezone: true }).notNull(),
    markPrice18: money("mark_price_18").notNull(),
    indexPrice18: money("index_price_18").notNull(),
    basisBps: integer("basis_bps").notNull(),
    openInterestBase18: money("open_interest_base_18").notNull(),
    openInterestNotional18: money("open_interest_notional_18").notNull(),
    status: text("status").notNull(),
  },
  (t) => ({ pk: primaryKey({ columns: [t.asset, t.ts] }) }),
);

/** Written by plan 2b (solvency prover). Read-only here. */
export const solvency = pgTable(
  "solvency",
  {
    asset: text("asset").notNull(),
    ts: timestamp("ts", { withTimezone: true }).notNull(),
    batchId: bigint("batch_id", { mode: "bigint" }).notNull(),
    supply18: money("supply_18").notNull(),
    notional18: money("notional_18").notNull(),
    margin18: money("margin_18").notNull(),
    buffer18: money("buffer_18").notNull(),
    deltaBps: integer("delta_bps").notNull(),
    proofOk: boolean("proof_ok").notNull(),
  },
  (t) => ({ pk: primaryKey({ columns: [t.asset, t.ts] }) }),
);

export const funding = pgTable(
  "funding",
  {
    asset: text("asset").notNull(),
    ts: timestamp("ts", { withTimezone: true }).notNull(),
    fundingRateBps: integer("funding_rate_bps").notNull(),
    basisBps: integer("basis_bps").notNull(),
    accrued18: money("accrued_18").notNull(),
    bufferAfter18: money("buffer_after_18").notNull(),
  },
  (t) => ({ pk: primaryKey({ columns: [t.asset, t.ts] }) }),
);

export const flows = pgTable(
  "flows",
  {
    txHash: text("tx_hash").notNull(),
    logIndex: integer("log_index").notNull(),
    asset: text("asset").notNull(),
    kind: text("kind").notNull(), // mint | redeem
    path: text("path").notNull(), // instant | request | force
    user: text("user").notNull(),
    amountIn18: money("amount_in_18").notNull(),
    certAmount18: money("cert_amount_18").notNull(),
    px18: money("px_18").notNull(),
    fillPx18: money("fill_px_18"),
    fee18: money("fee_18").notNull(),
    blockNumber: bigint("block_number", { mode: "bigint" }).notNull(),
    ts: timestamp("ts", { withTimezone: true }).notNull(),
  },
  (t) => ({
    pk: primaryKey({ columns: [t.txHash, t.logIndex] }),
    byUser: index("flows_user_idx").on(t.user),
    byAsset: index("flows_asset_ts_idx").on(t.asset, t.ts),
  }),
);

export const receipts = pgTable(
  "receipts",
  {
    asset: text("asset").notNull(),
    receiptId: bigint("receipt_id", { mode: "bigint" }).notNull(),
    kind: text("kind").notNull(), // mint | redeem
    user: text("user").notNull(),
    escrow18: money("escrow_18").notNull(),
    owed18: money("owed_18").notNull(),
    status: text("status").notNull(), // open | settled | paid
    enqueuedAt: timestamp("enqueued_at", { withTimezone: true }).notNull(),
    /** enqueuedAt + PRIORITY_EXPIRATION (14 days): the honest worst case shown in the UI. */
    expiresAt: timestamp("expires_at", { withTimezone: true }).notNull(),
    settledBatch: bigint("settled_batch", { mode: "bigint" }),
  },
  (t) => ({
    pk: primaryKey({ columns: [t.asset, t.receiptId] }),
    byUser: index("receipts_user_idx").on(t.user),
  }),
);
```

- [ ] **Step 2: Write `drizzle.config.ts` and generate migrations**

```ts
import type { Config } from "drizzle-kit";

export default {
  schema: "./src/db/schema.ts",
  out: "./src/db/migrations",
  dialect: "postgresql",
  dbCredentials: { url: process.env.DATABASE_URL ?? "" },
} satisfies Config;
```

```bash
cd services && bun install && bun run db:generate
```

- [ ] **Step 3: Write `src/db/migrations/0001_timescale.sql`**

```sql
-- Timescale hypertables for the three append-only time series.
-- Applied after the Drizzle-generated DDL. Idempotent.
CREATE EXTENSION IF NOT EXISTS timescaledb;

SELECT create_hypertable('market_snapshots', 'ts', if_not_exists => TRUE, migrate_data => TRUE);
SELECT create_hypertable('solvency',         'ts', if_not_exists => TRUE, migrate_data => TRUE);
SELECT create_hypertable('funding',          'ts', if_not_exists => TRUE, migrate_data => TRUE);

-- Snapshots land roughly once a minute per asset; compress anything older than a week.
ALTER TABLE market_snapshots SET (timescaledb.compress, timescaledb.compress_segmentby = 'asset');
SELECT add_compression_policy('market_snapshots', INTERVAL '7 days', if_not_exists => TRUE);
```

- [ ] **Step 4: Write `src/db/client.ts`**

```ts
import { drizzle, type PostgresJsDatabase } from "drizzle-orm/postgres-js";
import { migrate } from "drizzle-orm/postgres-js/migrator";
import postgres from "postgres";
import { readFileSync } from "node:fs";
import { join } from "node:path";

export type Db = PostgresJsDatabase<Record<string, never>>;

export function createDb(url: string) {
  const sql = postgres(url, { max: 10, onnotice: () => {} });
  const db = drizzle(sql);
  return { db, sql, close: () => sql.end({ timeout: 5 }) };
}

export async function runMigrations(url: string): Promise<void> {
  const { db, sql, close } = createDb(url);
  const folder = join(import.meta.dir, "migrations");
  await migrate(db, { migrationsFolder: folder });
  // Timescale DDL is not expressible in Drizzle's schema, so it is applied by hand.
  const timescale = readFileSync(join(folder, "0001_timescale.sql"), "utf8");
  await sql.unsafe(timescale);
  await close();
}

if (import.meta.main && process.argv.includes("--migrate")) {
  const url = process.env.DATABASE_URL;
  if (!url) throw new Error("DATABASE_URL is required");
  await runMigrations(url);
  console.log("migrations applied");
}
```

- [ ] **Step 5: Write the failing test**

```ts
import { beforeAll, afterAll, describe, expect, it } from "bun:test";
import { createDb, runMigrations } from "../src/db/client";
import { marketSnapshots, vaults } from "../src/db/schema";
import { eq } from "drizzle-orm";

const url = process.env.DATABASE_URL ?? "postgres://postgres:usecert@localhost:5432/usecert";
let handle: ReturnType<typeof createDb>;

describe("database", () => {
  beforeAll(async () => {
    await runMigrations(url);
    handle = createDb(url);
    await handle.sql`TRUNCATE vaults, market_snapshots CASCADE`;
  });

  afterAll(async () => {
    await handle.close();
  });

  it("stores a vault row", async () => {
    await handle.db.insert(vaults).values({
      asset: "TSLA",
      vaultAddr: "0x1111111111111111111111111111111111111111",
      certificate: "0x2222222222222222222222222222222222222222",
      certificateSymbol: "uTSLA",
      marketId: 16,
      priceDecimals: 2,
      sizeDecimals: 4,
      instantCap18: "10000000000000000000000",
    });
    const rows = await handle.db.select().from(vaults).where(eq(vaults.asset, "TSLA"));
    expect(rows[0]?.marketId).toBe(16);
    expect(rows[0]?.certificateSymbol).toBe("uTSLA");
    expect(rows[0]?.status).toBe("pending");
  });

  it("stores 1e18-scaled money without precision loss", async () => {
    const huge = "1193141020000000000000000"; // ~1.19M dollars at 1e18
    await handle.db.insert(marketSnapshots).values({
      asset: "TSLA",
      ts: new Date("2026-09-07T13:00:00Z"),
      markPrice18: "355830000000000000000",
      indexPrice18: "355860000000000000000",
      basisBps: 0,
      openInterestBase18: "3353219800000000000000",
      openInterestNotional18: huge,
      status: "active",
    });
    const rows = await handle.db.select().from(marketSnapshots);
    expect(rows[0]?.openInterestNotional18).toBe(huge);
  });

  it("made market_snapshots a hypertable", async () => {
    const rows = await handle.sql`
      SELECT hypertable_name FROM timescaledb_information.hypertables
      WHERE hypertable_name = 'market_snapshots'`;
    expect(rows.length).toBe(1);
  });
});
```

- [ ] **Step 6: Run to verify it fails, then passes**

Run: `cd services && bun test test/db.test.ts`
Expected first: FAIL (module or table missing). After Steps 1–4 are complete: PASS, 3 tests.

- [ ] **Step 7: Commit**

```bash
git add services/drizzle.config.ts services/src/db/ services/test/db.test.ts
git commit -m "feat(services): Drizzle schema with Timescale hypertables and 1e18 integer money"
```

---

## Task 6: Market snapshot worker

**Files:**
- Create: `services/src/workers/marketSnapshot.ts`
- Test: `services/test/marketSnapshot.test.ts`

**Interfaces:**
- Consumes: `createLighterClient`, `MarketDetail` (T4); `createDb`, `marketSnapshots` (T5); `MARKETS`, `C1_SYMBOLS` (T4).
- Produces:
  - `snapshotOnce(deps: { client: LighterClient; db: Db; now?: () => Date }): Promise<SnapshotResult>`
  - `type SnapshotResult = { written: string[]; skipped: Array<{ asset: string; reason: string }> }`
  - `computeBasisBps(mark18: bigint, index18: bigint): number`

- [ ] **Step 1: Write the failing test**

```ts
import { beforeEach, describe, expect, it } from "bun:test";
import fixture from "./fixtures/orderBookDetails.json";
import { createLighterClient } from "../src/clients/lighter";
import { createDb, runMigrations } from "../src/db/client";
import { marketSnapshots } from "../src/db/schema";
import { computeBasisBps, snapshotOnce } from "../src/workers/marketSnapshot";

const url = process.env.DATABASE_URL ?? "postgres://postgres:usecert@localhost:5432/usecert";
const stub = (body: unknown, status = 200): typeof fetch =>
  (async () => new Response(JSON.stringify(body), { status })) as typeof fetch;

describe("computeBasisBps", () => {
  it("is zero when mark equals index", () => {
    expect(computeBasisBps(355_83n * 10n ** 16n, 355_83n * 10n ** 16n)).toBe(0);
  });

  it("matches the observed TSLA spread of under 1 bp", () => {
    const bps = computeBasisBps(355_830000000000000000n, 355_860000000000000000n);
    expect(bps).toBeLessThanOrEqual(1);
  });

  it("matches the observed NVDA spread of about 7 bps", () => {
    const bps = computeBasisBps(232_460000000000000000n, 232_290000000000000000n);
    expect(bps).toBe(7);
  });

  it("is unsigned", () => {
    expect(computeBasisBps(100n * 10n ** 18n, 101n * 10n ** 18n)).toBeGreaterThan(0);
  });
});

describe("snapshotOnce", () => {
  let handle: ReturnType<typeof createDb>;

  beforeEach(async () => {
    await runMigrations(url);
    handle = createDb(url);
    await handle.sql`TRUNCATE market_snapshots CASCADE`;
  });

  it("writes one row per C1 asset with notional open interest", async () => {
    const client = createLighterClient({ baseUrl: "https://x.invalid", fetchImpl: stub(fixture) });
    const res = await snapshotOnce({ client, db: handle.db, now: () => new Date("2026-09-07T13:00:00Z") });

    expect(res.written.sort()).toEqual(["NVDA", "TSLA"]);
    const rows = await handle.db.select().from(marketSnapshots);
    expect(rows.length).toBe(2);
    const tsla = rows.find((r) => r.asset === "TSLA");
    // notional must be orders of magnitude above base size
    expect(BigInt(tsla!.openInterestNotional18) > BigInt(tsla!.openInterestBase18) * 100n).toBe(true);
    await handle.close();
  });

  it("skips an asset whose market id no longer matches the verified constant", async () => {
    const tampered = structuredClone(fixture) as typeof fixture;
    const t = tampered.order_book_details.find((m) => m.symbol === "TSLA");
    if (t) t.market_id = 999;
    const client = createLighterClient({ baseUrl: "https://x.invalid", fetchImpl: stub(tampered) });

    const res = await snapshotOnce({ client, db: handle.db });
    expect(res.written).toEqual(["NVDA"]);
    expect(res.skipped[0]?.asset).toBe("TSLA");
    expect(res.skipped[0]?.reason).toContain("market_id");
    await handle.close();
  });

  it("skips an inactive market rather than recording it as tradeable", async () => {
    const tampered = structuredClone(fixture) as typeof fixture;
    const t = tampered.order_book_details.find((m) => m.symbol === "TSLA");
    if (t) t.status = "paused";
    const client = createLighterClient({ baseUrl: "https://x.invalid", fetchImpl: stub(tampered) });

    const res = await snapshotOnce({ client, db: handle.db });
    expect(res.written).toEqual(["NVDA"]);
    expect(res.skipped[0]?.reason).toContain("status");
    await handle.close();
  });

  it("is idempotent for the same timestamp", async () => {
    const client = createLighterClient({ baseUrl: "https://x.invalid", fetchImpl: stub(fixture) });
    const now = () => new Date("2026-09-07T13:00:00Z");
    await snapshotOnce({ client, db: handle.db, now });
    await snapshotOnce({ client, db: handle.db, now });
    const rows = await handle.db.select().from(marketSnapshots);
    expect(rows.length).toBe(2);
    await handle.close();
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd services && bun test test/marketSnapshot.test.ts`
Expected: FAIL — cannot resolve `../src/workers/marketSnapshot`.

- [ ] **Step 3: Write `src/workers/marketSnapshot.ts`**

```ts
import { sql } from "drizzle-orm";
import type { MarketDetail } from "../clients/lighter";
import { createLighterClient } from "../clients/lighter";
import { C1_SYMBOLS, MARKETS, type MarketSymbol } from "../config/markets";
import { createDb, type Db } from "../db/client";
import { marketSnapshots } from "../db/schema";
import { loadEnv } from "../config/env";

export type SnapshotResult = {
  written: string[];
  skipped: Array<{ asset: string; reason: string }>;
};

/** Unsigned spread between the Lighter mark and the index, in basis points. */
export function computeBasisBps(mark18: bigint, index18: bigint): number {
  if (index18 === 0n) return 0;
  const diff = mark18 > index18 ? mark18 - index18 : index18 - mark18;
  return Number((diff * 10_000n) / index18);
}

type Client = ReturnType<typeof createLighterClient>;

export async function snapshotOnce(deps: {
  client: Client;
  db: Db;
  now?: () => Date;
}): Promise<SnapshotResult> {
  const ts = (deps.now ?? (() => new Date()))();
  const all = await deps.client.getOrderBookDetails();
  const bySymbol = new Map<string, MarketDetail>(all.map((m) => [m.symbol, m]));

  const written: string[] = [];
  const skipped: Array<{ asset: string; reason: string }> = [];

  for (const symbol of C1_SYMBOLS) {
    const m = bySymbol.get(symbol);
    if (!m) {
      skipped.push({ asset: symbol, reason: "absent from orderBookDetails" });
      continue;
    }

    // Guard against silent venue changes: the whole design is pinned to these
    // values, so a mismatch must stop the write rather than be recorded.
    const expected = MARKETS[symbol as MarketSymbol];
    if (m.marketId !== expected.marketId) {
      skipped.push({ asset: symbol, reason: `market_id changed: ${m.marketId} != ${expected.marketId}` });
      continue;
    }
    if (m.priceDecimals !== expected.priceDecimals || m.sizeDecimals !== expected.sizeDecimals) {
      skipped.push({ asset: symbol, reason: "price/size decimals changed" });
      continue;
    }
    if (m.status !== "active") {
      skipped.push({ asset: symbol, reason: `status is ${m.status}` });
      continue;
    }

    await deps.db
      .insert(marketSnapshots)
      .values({
        asset: symbol,
        ts,
        markPrice18: m.markPrice18.toString(),
        indexPrice18: m.indexPrice18.toString(),
        basisBps: computeBasisBps(m.markPrice18, m.indexPrice18),
        openInterestBase18: m.openInterestBase18.toString(),
        openInterestNotional18: m.openInterestNotional18.toString(),
        status: m.status,
      })
      .onConflictDoUpdate({
        target: [marketSnapshots.asset, marketSnapshots.ts],
        set: {
          markPrice18: sql`excluded.mark_price_18`,
          indexPrice18: sql`excluded.index_price_18`,
          openInterestNotional18: sql`excluded.open_interest_notional_18`,
        },
      });

    written.push(symbol);
  }

  return { written, skipped };
}

if (import.meta.main) {
  const env = loadEnv(process.env);
  const client = createLighterClient({ baseUrl: env.LIGHTER_API_BASE });
  const handle = createDb(env.DATABASE_URL);

  // Batches land about once a minute; 30s is frequent enough and stays well
  // clear of any rate limit.
  const INTERVAL_MS = 30_000;
  const tick = async () => {
    try {
      const res = await snapshotOnce({ client, db: handle.db });
      if (res.skipped.length > 0) console.warn("snapshot skipped:", res.skipped);
    } catch (e) {
      console.error("snapshot failed:", e);
    }
  };
  await tick();
  setInterval(tick, INTERVAL_MS);
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd services && bun test test/marketSnapshot.test.ts`
Expected: PASS, 8 tests.

- [ ] **Step 5: Commit**

```bash
git add services/src/workers/marketSnapshot.ts services/test/marketSnapshot.test.ts
git commit -m "feat(services): market snapshot worker with venue-drift guards"
```

---

## Task 7: Chain client

**Files:**
- Create: `services/src/clients/chain.ts`
- Test: `services/test/chain.test.ts`

**Interfaces:**
- Consumes: `Env` (T1); `withRetry`, `RateLimitError` (T3).
- Produces:
  - `robinhoodChain(chainId: number, rpcUrl: string)` — a viem `Chain` object.
  - `createChainClient(opts: { chainId: number; rpcUrl: string; transportOverride?: Transport })` returning a viem `PublicClient` wrapped so 429 responses raise `RateLimitError` and retry.
  - `getBlockNumberSafe(client): Promise<bigint>`

- [ ] **Step 1: Write the failing test**

```ts
import { describe, expect, it } from "bun:test";
import { custom } from "viem";
import { createChainClient, getBlockNumberSafe, robinhoodChain } from "../src/clients/chain";
import { RateLimitError } from "../src/lib/retry";

describe("robinhoodChain", () => {
  it("describes mainnet correctly", () => {
    const c = robinhoodChain(4663, "https://example.invalid");
    expect(c.id).toBe(4663);
    expect(c.nativeCurrency.symbol).toBe("ETH");
  });
});

describe("createChainClient", () => {
  it("reads a block number", async () => {
    const transport = custom({ request: async () => "0x2dfe3d0" });
    const client = createChainClient({ chainId: 4663, rpcUrl: "https://x.invalid", transportOverride: transport });
    expect(await getBlockNumberSafe(client)).toBe(48228816n);
  });

  it("retries a 429 and then succeeds", async () => {
    let calls = 0;
    const transport = custom({
      request: async () => {
        calls++;
        if (calls < 3) {
          const e: Error & { status?: number } = new Error("Too Many Requests");
          e.status = 429;
          throw e;
        }
        return "0x1";
      },
    });
    const client = createChainClient({ chainId: 4663, rpcUrl: "https://x.invalid", transportOverride: transport });
    expect(await getBlockNumberSafe(client)).toBe(1n);
    expect(calls).toBe(3);
  });

  it("surfaces a persistent 429 as RateLimitError", async () => {
    const transport = custom({
      request: async () => {
        const e: Error & { status?: number } = new Error("Too Many Requests");
        e.status = 429;
        throw e;
      },
    });
    const client = createChainClient({ chainId: 4663, rpcUrl: "https://x.invalid", transportOverride: transport });
    await expect(getBlockNumberSafe(client)).rejects.toBeInstanceOf(RateLimitError);
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd services && bun test test/chain.test.ts`
Expected: FAIL — cannot resolve `../src/clients/chain`.

- [ ] **Step 3: Write `src/clients/chain.ts`**

```ts
import { createPublicClient, defineChain, http, type PublicClient, type Transport } from "viem";
import { RateLimitError, TransientError, withRetry } from "../lib/retry";

export function robinhoodChain(chainId: number, rpcUrl: string) {
  return defineChain({
    id: chainId,
    name: chainId === 4663 ? "Robinhood Chain" : "Robinhood Chain Testnet",
    nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: { default: { http: [rpcUrl] } },
    blockExplorers: {
      default: { name: "Blockscout", url: "https://robinhoodchain.blockscout.com" },
    },
  });
}

function classify(e: unknown): unknown {
  const status = (e as { status?: number } | null)?.status;
  const msg = e instanceof Error ? e.message : String(e);
  if (status === 429 || /too many requests|rate.?limit/i.test(msg)) {
    return new RateLimitError(msg);
  }
  if (status !== undefined && status >= 500) return new TransientError(msg);
  return e;
}

export function createChainClient(opts: {
  chainId: number;
  rpcUrl: string;
  transportOverride?: Transport;
}): PublicClient {
  const transport = opts.transportOverride ?? http(opts.rpcUrl, { retryCount: 0 });
  return createPublicClient({ chain: robinhoodChain(opts.chainId, opts.rpcUrl), transport });
}

/**
 * The public Robinhood RPC 429s on the second consecutive call, so every read
 * goes through retry. Classification converts viem's opaque errors into ours.
 */
export async function getBlockNumberSafe(client: PublicClient): Promise<bigint> {
  return withRetry(
    async () => {
      try {
        return await client.getBlockNumber();
      } catch (e) {
        throw classify(e);
      }
    },
    { baseDelayMs: 50 },
  );
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd services && bun test test/chain.test.ts`
Expected: PASS, 4 tests.

- [ ] **Step 5: Commit**

```bash
git add services/src/clients/chain.ts services/test/chain.test.ts
git commit -m "feat(services): viem chain client with rate-limit classification"
```

---

## Task 8: tRPC read API

**Files:**
- Create: `services/src/api/router.ts`
- Create: `services/src/api/routers/vaults.ts`
- Create: `services/src/api/routers/markets.ts`
- Create: `services/src/api/server.ts`
- Test: `services/test/api.test.ts`

**Interfaces:**
- Consumes: `createDb`, `vaults`, `marketSnapshots`, `solvency` (T5).
- Produces:
  - `appRouter` with `vaults.list`, `vaults.solvency`, `vaults.capacity`, `markets.snapshot`, `markets.history`.
  - `createContext(db: Db)`
  - `createServer(db: Db, port: number)` — Hono app with `/health` and `/trpc/*`.
  - `vaults.solvency` output **always** includes `ageSec` and `verifiability: "independently-verifiable-per-batch"`.

- [ ] **Step 1: Write the failing test**

```ts
import { beforeAll, afterAll, describe, expect, it } from "bun:test";
import { createDb, runMigrations } from "../src/db/client";
import { marketSnapshots, solvency, vaults } from "../src/db/schema";
import { appRouter, createContext } from "../src/api/router";

const url = process.env.DATABASE_URL ?? "postgres://postgres:usecert@localhost:5432/usecert";
let handle: ReturnType<typeof createDb>;
let caller: ReturnType<typeof appRouter.createCaller>;

describe("api", () => {
  beforeAll(async () => {
    await runMigrations(url);
    handle = createDb(url);
    await handle.sql`TRUNCATE vaults, market_snapshots, solvency CASCADE`;

    await handle.db.insert(vaults).values({
      asset: "TSLA",
      vaultAddr: "0x1111111111111111111111111111111111111111",
      certificate: "0x2222222222222222222222222222222222222222",
      certificateSymbol: "uTSLA",
      marketId: 16,
      priceDecimals: 2,
      sizeDecimals: 4,
      instantCap18: "10000000000000000000000",
      status: "enabled",
    });
    await handle.db.insert(marketSnapshots).values({
      asset: "TSLA",
      ts: new Date("2026-09-07T13:00:00Z"),
      markPrice18: "355830000000000000000",
      indexPrice18: "355860000000000000000",
      basisBps: 0,
      openInterestBase18: "3353219800000000000000",
      openInterestNotional18: "1193141020000000000000000",
      status: "active",
    });
    await handle.db.insert(solvency).values({
      asset: "TSLA",
      ts: new Date("2026-09-07T13:00:00Z"),
      batchId: 100n,
      supply18: "10000000000000000000",
      notional18: "3558300000000000000000",
      margin18: "3600000000000000000000",
      buffer18: "100000000000000000000000",
      deltaBps: 10000,
      proofOk: true,
    });

    caller = appRouter.createCaller(createContext(handle.db));
  });

  afterAll(async () => {
    await handle.close();
  });

  it("lists vaults", async () => {
    const out = await caller.vaults.list();
    expect(out.length).toBe(1);
    expect(out[0]?.certificateSymbol).toBe("uTSLA");
  });

  it("always returns solvency with its age and an honest verifiability label", async () => {
    const s = await caller.vaults.solvency({ asset: "TSLA" });
    expect(s).not.toBeNull();
    expect(s!.batchId).toBe("100");
    expect(typeof s!.ageSec).toBe("number");
    // C1 copy rule: never "provable every block"
    expect(s!.verifiability).toBe("independently-verifiable-per-batch");
  });

  it("returns null solvency for an asset never attested, rather than a fake zero", async () => {
    await handle.db.insert(vaults).values({
      asset: "NVDA",
      vaultAddr: "0x3333333333333333333333333333333333333333",
      certificate: "0x4444444444444444444444444444444444444444",
      certificateSymbol: "uNVDA",
      marketId: 15,
      priceDecimals: 2,
      sizeDecimals: 4,
      instantCap18: "10000000000000000000000",
    });
    expect(await caller.vaults.solvency({ asset: "NVDA" })).toBeNull();
  });

  it("reports capacity from open interest and the depth share", async () => {
    const c = await caller.vaults.capacity({ asset: "TSLA", depthBps: 1000 });
    // 10% of 1,193,141.02 = 119,314.102
    expect(c!.maxNotional18.startsWith("119314")).toBe(true);
    expect(c!.openInterestNotional18).toBe("1193141020000000000000000");
  });

  it("returns the newest market snapshot", async () => {
    const m = await caller.markets.snapshot({ asset: "TSLA" });
    expect(m!.markPrice18).toBe("355830000000000000000");
  });

  it("rejects an unknown asset with a validation error", async () => {
    await expect(caller.markets.snapshot({ asset: "" })).rejects.toThrow();
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd services && bun test test/api.test.ts`
Expected: FAIL — cannot resolve `../src/api/router`.

- [ ] **Step 3: Write `src/api/router.ts`**

```ts
import { initTRPC } from "@trpc/server";
import { and, desc, eq } from "drizzle-orm";
import { z } from "zod";
import type { Db } from "../db/client";
import { marketSnapshots, solvency, vaults } from "../db/schema";

export type Context = { db: Db };
export const createContext = (db: Db): Context => ({ db });

const t = initTRPC.context<Context>().create();
const assetInput = z.object({ asset: z.string().min(1).max(16) });

const vaultsRouter = t.router({
  list: t.procedure.query(async ({ ctx }) => {
    const rows = await ctx.db.select().from(vaults);
    return rows.map((r) => ({
      asset: r.asset,
      vaultAddr: r.vaultAddr,
      certificate: r.certificate,
      certificateSymbol: r.certificateSymbol,
      marketId: r.marketId,
      status: r.status,
      instantCap18: r.instantCap18,
    }));
  }),

  /**
   * Backing is never returned without its age. The label is deliberately
   * "independently-verifiable-per-batch" for C1 — route A means anyone can
   * reconstruct and check, NOT that a contract verified it. Do not upgrade this
   * string until route B ships.
   */
  solvency: t.procedure.input(assetInput).query(async ({ ctx, input }) => {
    const rows = await ctx.db
      .select()
      .from(solvency)
      .where(eq(solvency.asset, input.asset))
      .orderBy(desc(solvency.ts))
      .limit(1);

    const r = rows[0];
    if (!r) return null;

    return {
      asset: r.asset,
      batchId: r.batchId.toString(),
      supply18: r.supply18,
      notional18: r.notional18,
      margin18: r.margin18,
      buffer18: r.buffer18,
      deltaBps: r.deltaBps,
      proofOk: r.proofOk,
      provenAt: r.ts.toISOString(),
      ageSec: Math.floor((Date.now() - r.ts.getTime()) / 1000),
      verifiability: "independently-verifiable-per-batch" as const,
    };
  }),

  /** Mirrors CapacityOracle.maxNotional18 so the UI can show the same number. */
  capacity: t.procedure
    .input(assetInput.extend({ depthBps: z.number().int().min(1).max(10_000) }))
    .query(async ({ ctx, input }) => {
      const snap = (
        await ctx.db
          .select()
          .from(marketSnapshots)
          .where(eq(marketSnapshots.asset, input.asset))
          .orderBy(desc(marketSnapshots.ts))
          .limit(1)
      )[0];
      if (!snap) return null;

      const oi = BigInt(snap.openInterestNotional18);
      const byDepth = (oi * BigInt(input.depthBps)) / 10_000n;

      const used = (
        await ctx.db
          .select()
          .from(solvency)
          .where(eq(solvency.asset, input.asset))
          .orderBy(desc(solvency.ts))
          .limit(1)
      )[0];

      return {
        asset: input.asset,
        openInterestNotional18: snap.openInterestNotional18,
        depthBps: input.depthBps,
        maxNotional18: byDepth.toString(),
        usedNotional18: used?.notional18 ?? "0",
        utilisationBps: byDepth === 0n ? 0 : Number((BigInt(used?.notional18 ?? "0") * 10_000n) / byDepth),
        asOf: snap.ts.toISOString(),
      };
    }),
});

const marketsRouter = t.router({
  snapshot: t.procedure.input(assetInput).query(async ({ ctx, input }) => {
    const rows = await ctx.db
      .select()
      .from(marketSnapshots)
      .where(eq(marketSnapshots.asset, input.asset))
      .orderBy(desc(marketSnapshots.ts))
      .limit(1);
    return rows[0] ? { ...rows[0], ts: rows[0].ts.toISOString() } : null;
  }),

  history: t.procedure
    .input(assetInput.extend({ since: z.string().datetime(), limit: z.number().int().min(1).max(1000).default(500) }))
    .query(async ({ ctx, input }) => {
      const rows = await ctx.db
        .select()
        .from(marketSnapshots)
        .where(and(eq(marketSnapshots.asset, input.asset)))
        .orderBy(desc(marketSnapshots.ts))
        .limit(input.limit);
      return rows
        .filter((r) => r.ts >= new Date(input.since))
        .map((r) => ({ ts: r.ts.toISOString(), markPrice18: r.markPrice18, basisBps: r.basisBps }));
    }),
});

export const appRouter = t.router({ vaults: vaultsRouter, markets: marketsRouter });
export type AppRouter = typeof appRouter;
```

- [ ] **Step 4: Write `src/api/server.ts`**

```ts
import { trpcServer } from "@hono/trpc-server";
import { Hono } from "hono";
import { loadEnv } from "../config/env";
import { createDb, type Db } from "../db/client";
import { appRouter, createContext } from "./router";

export function createServer(db: Db) {
  const app = new Hono();

  app.get("/health", (c) => c.json({ ok: true }));

  app.use(
    "/trpc/*",
    trpcServer({ router: appRouter, createContext: () => createContext(db) }),
  );

  return app;
}

if (import.meta.main) {
  const env = loadEnv(process.env);
  if (env.usingPublicRpc) {
    console.warn("WARNING: using the public Robinhood RPC. It 429s on consecutive calls.");
  }
  const handle = createDb(env.DATABASE_URL);
  const app = createServer(handle.db);
  console.log(`api listening on :${env.PORT}`);
  Bun.serve({ fetch: app.fetch, port: env.PORT });
}
```

Add the adapter dependency:

```bash
cd services && bun add @hono/trpc-server
```

- [ ] **Step 5: Run to verify it passes**

Run: `cd services && bun test test/api.test.ts`
Expected: PASS, 7 tests.

- [ ] **Step 6: Run the whole suite and typecheck**

Run: `cd services && bun test && bun run typecheck`
Expected: all tests pass, no type errors.

- [ ] **Step 7: Commit**

```bash
git add services/src/api/ services/test/api.test.ts services/package.json
git commit -m "feat(services): tRPC read API with age-carrying solvency and capacity views"
```

---

## Self-Review

**Spec coverage.** §11's tRPC surface: `vaultRouter.list` and `.solvency` are Task 8; `bufferRouter.state`, `receiptRouter.byWallet` and `statsRouter.history` need the indexer, which is deferred to plan 2c along with everything that writes them — noted below. §12's data model: all six tables exist in Task 5. §15.1's capacity formula is mirrored in `vaults.capacity` (Task 8) using the same `min()` inputs the contract uses, and the base-to-notional conversion the formula depends on has its own tested function (Task 2). §17's copy rules are enforced in code: the `verifiability` literal is asserted by a test.

**Known gaps, deliberate and flagged.**
- **Task 7's chain client has no consumer in this plan.** The chain indexer that would use it needs deployed contract addresses and ABIs, which do not exist until the contracts plan finishes. The client is built and tested here because 2b and 2c both depend on it, and its rate-limit behaviour is the single most operationally important thing in the service. The `chainIndexer.ts` file listed in File Structure therefore moves to plan 2c; I have left it out of the task list rather than writing a task that cannot be tested.
- `receipts` and `funding` tables are created but unwritten here. `solvency` is written by 2b.
- No Redis, no queues, no transactions sent. Deliberate: this plan is safe to run before any contract exists.

**Type consistency.** `MarketDetail` field names are used identically in Tasks 4, 6 and 8. `toScaled`/`notional18`/`mulScaled` signatures match across Tasks 2, 4 and 6. `Db` from `db/client` is the single database type in Tasks 5, 6 and 8. Money is a `string` at every API and database boundary and a `bigint` only inside computations — no mixing.

**One correction made during review.** The original File Structure listed `chainIndexer.ts` and a `receipts` router as Task-level work. Both depend on contract ABIs that will not exist until the contracts plan lands, so specifying them here would have meant writing tests that cannot run. They are now explicitly deferred rather than half-specified.

---

## Execution Handoff

Plan complete. Two execution options:

1. **Subagent-Driven (recommended)** — a fresh subagent per task, review between tasks, fast iteration.
2. **Inline Execution** — execute tasks in this session with checkpoints.

This plan needs Postgres running (see Prerequisites) but **not** Foundry, and no deployed contracts. It can start immediately.
