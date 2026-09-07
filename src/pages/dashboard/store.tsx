/* eslint-disable react-refresh/only-export-components */
import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState } from "react";
import type { ReactNode } from "react";
import { mulberry32, randHash } from "./format";

/* ------------------------------------------------------------------ types */

export type VaultId = "utsla" | "unvda" | "uspx" | "uqqq";
export type ViewId = "overview" | "vaults" | "mint" | "staking" | "activity" | "keepers";
export type FlowType = "MINT" | "REDEEM" | "STAKE" | "UNSTAKE" | "CLAIM" | "WITHDRAW";
export type Timeframe = "1H" | "24H" | "7D" | "ALL";

export interface SeriesPoint {
  backing: number;
  obligation: number;
}

export interface FundingBar {
  rate: number; // percent, hourly
  accrued: number; // USD to buffer that hour
  bufferAfter: number; // USD
}

export interface Vault {
  id: VaultId;
  name: string;
  full: string;
  img: string;
  status: "LIVE" | "SOON";
  price: number;
  change24h: number;
  supply: number; // certificate units
  buffer: number; // USD
  bufferPct: number; // percent of target
  delta: number;
  funding8h: number; // percent
  solvency: SeriesPoint[]; // 60 points, last = now
  funding: FundingBar[]; // 48 hourly bars, last = current hour
}

export interface Flow {
  id: number;
  type: FlowType;
  vault: VaultId | "token";
  amount: number;
  usdc: number;
  price: number;
  feeBps: number;
  time: number;
  tx: string;
}

export interface Cooldown {
  id: number;
  amount: number;
  startAt: number;
  readyAt: number;
  ready: boolean;
}

export interface Keeper {
  id: string;
  name: string;
  desc: string;
  lastRun: number;
  runsToday: number;
  runsLabel: string;
  detail: string;
  nextInSec?: number;
}

export interface Toast {
  id: number;
  state: "pending" | "success";
  title: string;
  desc?: string;
}

export interface MintPreset {
  tab: "mint" | "redeem";
  asset: VaultId;
  nonce: number;
}

/* ------------------------------------------------------- series generators */

function genSeries(n: number, end: number, volPct: number, seed: number): SeriesPoint[] {
  const rand = mulberry32(seed);
  const obligation = new Array<number>(n);
  obligation[n - 1] = end;
  for (let i = n - 2; i >= 0; i--) {
    obligation[i] = obligation[i + 1] / (1 + (rand() - 0.48) * volPct);
  }
  return obligation.map((o) => ({
    obligation: o,
    backing: o * (1.0014 + rand() * 0.0006),
  }));
}

function genFunding(n: number, bufferEnd: number, seed: number): FundingBar[] {
  const rand = mulberry32(seed);
  const bars: FundingBar[] = [];
  let buf = bufferEnd;
  for (let i = 0; i < n; i++) {
    const rate = (rand() - 0.42) * 0.012; // mostly positive, percent per hour
    const accrued = rate * 4200;
    buf = Math.max(0, buf + accrued);
    bars.push({ rate, accrued, bufferAfter: buf });
  }
  return bars;
}

/* ------------------------------------------------------------ seeded flows */

const FLOW_VAULTS: VaultId[] = ["utsla", "unvda", "uspx"];
const FLOW_NAMES: Record<VaultId, string> = {
  utsla: "uTSLA",
  unvda: "uNVDA",
  uspx: "uSPX",
  uqqq: "uQQQ",
};

function seedFlows(now: number, prices: Record<VaultId, number>): Flow[] {
  const rand = mulberry32(777);
  const out: Flow[] = [];
  let t = now - 26 * 60 * 1000;
  for (let i = 0; i < 24; i++) {
    const r = rand();
    const type: FlowType = r < 0.42 ? "MINT" : r < 0.72 ? "REDEEM" : r < 0.88 ? "STAKE" : "CLAIM";
    const vault = FLOW_VAULTS[Math.floor(rand() * 3)];
    const price = prices[vault] * (1 + (rand() - 0.5) * 0.01);
    const isCert = type === "MINT" || type === "REDEEM";
    const amount = isCert ? 0.5 + rand() * 22 : 40 + rand() * 900;
    const usdc = isCert ? amount * price : amount * 1.0;
    out.push({
      id: 1000 - i,
      type,
      vault: isCert ? vault : "token",
      amount,
      usdc,
      price: isCert ? price : 1,
      feeBps: isCert ? 10 : 0,
      time: t,
      tx: randHash(rand),
    });
    t -= (14 + rand() * 180) * 60 * 1000;
  }
  return out;
}

/* ------------------------------------------------------------------ vaults */

function makeVaults(): Vault[] {
  const defs: Array<{
    id: VaultId;
    name: string;
    full: string;
    img: string;
    price: number;
    change24h: number;
    supply: number;
    buffer: number;
    bufferPct: number;
    funding8h: number;
    seed: number;
  }> = [
    { id: "utsla", name: "uTSLA", full: "Tesla Certificate", img: "/cert-plate-utsla.jpg", price: 412.36, change24h: 2.1, supply: 71204, buffer: 612000, bufferPct: 78, funding8h: 0.0042, seed: 11 },
    { id: "unvda", name: "uNVDA", full: "Nvidia Certificate", img: "/cert-plate-unvda.jpg", price: 178.92, change24h: 1.4, supply: 118540, buffer: 891000, bufferPct: 74, funding8h: 0.0031, seed: 22 },
    { id: "uspx", name: "uSPX", full: "S&P 500 Certificate", img: "/cert-plate-uspx.jpg", price: 592.1, change24h: 0.6, supply: 12830, buffer: 357000, bufferPct: 81, funding8h: 0.0018, seed: 33 },
  ];
  const vaults: Vault[] = defs.map((d) => ({
    id: d.id,
    name: d.name,
    full: d.full,
    img: d.img,
    status: "LIVE",
    price: d.price,
    change24h: d.change24h,
    supply: d.supply,
    buffer: d.buffer,
    bufferPct: d.bufferPct,
    delta: 1.0,
    funding8h: d.funding8h,
    solvency: genSeries(60, d.supply * d.price, 0.004, d.seed),
    funding: genFunding(48, d.buffer, d.seed * 7),
  }));
  vaults.push({
    id: "uqqq",
    name: "uQQQ",
    full: "Nasdaq 100 Certificate",
    img: "/cert-plate-uqqq.jpg",
    status: "SOON",
    price: 0,
    change24h: 0,
    supply: 0,
    buffer: 0,
    bufferPct: 0,
    delta: 1,
    funding8h: 0,
    solvency: genSeries(60, 1000, 0.001, 44),
    funding: [],
  });
  return vaults;
}

function makeKeepers(now: number): Keeper[] {
  return [
    { id: "delta", name: "DELTA-KEEPER", desc: "Band check each block window", lastRun: now - 2000, runsToday: 41204, runsLabel: "runs today", detail: "Band within ±0.2% across all vaults" },
    { id: "funding", name: "FUNDING-SWEEPER", desc: "Hourly funding accrual sweep", lastRun: now - 14 * 60 * 1000, runsToday: 17, runsLabel: "sweeps today", detail: "Next sweep in 46m", nextInSec: 46 * 60 },
    { id: "snapshot", name: "SOLVENCY-SNAPSHOTTER", desc: "Powers this dashboard", lastRun: now - 2000, runsToday: 41198, runsLabel: "snapshots today", detail: "Backing pinned to chain state" },
    { id: "watchdog", name: "BUFFER-WATCHDOG", desc: "Threshold transitions, fee activation", lastRun: now - 2000, runsToday: 41201, runsLabel: "checks today", detail: "BUFFER HEALTHY · NO FEES ACTIVE" },
    { id: "indexer", name: "CHAIN-INDEXER", desc: "Flows, stakes, blocks", lastRun: now - 2000, runsToday: 41210, runsLabel: "blocks indexed", detail: "Indexed through current block" },
  ];
}

/* ---------------------------------------------------------------- context */

interface DashboardCtx {
  // engine
  block: number;
  now: number;
  vaults: Vault[];
  agg: Record<Timeframe, SeriesPoint[]>;
  totals: { notional: number; margin: number; buffer: number; ratio: number; delta: number };
  // navigation
  view: ViewId;
  setView: (v: ViewId) => void;
  selectedVault: VaultId;
  goVault: (id: VaultId) => void;
  mintPreset: MintPreset;
  goMint: (tab: "mint" | "redeem", asset: VaultId) => void;
  // wallet
  connected: boolean;
  address: string;
  walletModalOpen: boolean;
  setWalletModalOpen: (open: boolean) => void;
  connect: () => void;
  disconnect: () => void;
  usdc: number;
  tokenLiquid: number;
  tokenStaked: number;
  totalStaked: number;
  rewards: number;
  positions: Record<VaultId, number>;
  // flows
  flows: Flow[];
  loadMoreFlows: () => void;
  // staking
  cooldowns: Cooldown[];
  // keepers
  keepers: Keeper[];
  runKeeper: (id: string) => void;
  // toasts + transactions
  toasts: Toast[];
  dismissToast: (id: number) => void;
  pauseToast: (id: number) => void;
  resumeToast: (id: number) => void;
  mint: (asset: VaultId, amountUsdc: number, receive: number) => void;
  redeem: (asset: VaultId, units: number, receiveUsdc: number) => void;
  stake: (amount: number) => void;
  unstake: (amount: number) => void;
  claim: () => void;
  fastForward: (id: number) => void;
  withdraw: (id: number) => void;
}

const Ctx = createContext<DashboardCtx | null>(null);

export function useDashboard(): DashboardCtx {
  const ctx = useContext(Ctx);
  if (!ctx) throw new Error("useDashboard must be used within DashboardProvider");
  return ctx;
}

const MOCK_ADDRESS = "0x4fA2b7C1d8E9f0A1b2C3d4E5f6A7b8C9d0E19cE1";
const START_BLOCK = 48213904;
const COOLDOWN_MS = 7 * 24 * 3600 * 1000;

let idCounter = 5000;
const nextId = () => ++idCounter;

export function DashboardProvider({ children }: { children: ReactNode }) {
  const [block, setBlock] = useState(START_BLOCK);
  const [now, setNow] = useState(() => Date.now());
  const [vaults, setVaults] = useState<Vault[]>(makeVaults);
  const [agg, setAgg] = useState<Record<Timeframe, SeriesPoint[]>>(() => {
    const total = makeVaults()
      .filter((v) => v.status === "LIVE")
      .reduce((s, v) => s + v.supply * v.price, 0);
    return {
      "1H": genSeries(15, total, 0.0012, 101),
      "24H": genSeries(60, total, 0.004, 102),
      "7D": genSeries(84, total, 0.009, 103),
      ALL: genSeries(120, total, 0.016, 104),
    };
  });

  // navigation
  const [view, setView] = useState<ViewId>("overview");
  const [selectedVault, setSelectedVault] = useState<VaultId>("utsla");
  const [mintPreset, setMintPreset] = useState<MintPreset>({ tab: "mint", asset: "utsla", nonce: 0 });

  // wallet
  const [connected, setConnected] = useState(false);
  const [walletModalOpen, setWalletModalOpen] = useState(false);
  const [usdc, setUsdc] = useState(12480);
  const [tokenLiquid, setTokenLiquid] = useState(3500);
  const [tokenStaked, setTokenStaked] = useState(1250);
  const [totalStaked, setTotalStaked] = useState(4820000);
  const [rewards, setRewards] = useState(42.18);
  const [positions, setPositions] = useState<Record<VaultId, number>>({ utsla: 18.42, unvda: 6.1, uspx: 0, uqqq: 0 });

  // flows / staking / keepers / toasts
  const [flows, setFlows] = useState<Flow[]>(() => seedFlows(Date.now(), { utsla: 412.36, unvda: 178.92, uspx: 592.1, uqqq: 0 }));
  const loadOffset = useRef(0);
  const [cooldowns, setCooldowns] = useState<Cooldown[]>([]);
  const [keepers, setKeepers] = useState<Keeper[]>(() => makeKeepers(Date.now()));
  const [toasts, setToasts] = useState<Toast[]>([]);
  const toastTimers = useRef(new Map<number, ReturnType<typeof setTimeout>>());
  const tickCount = useRef(0);

  /* ------------------------------------------------------------- toasts */

  const dismissToast = useCallback((id: number) => {
    const timer = toastTimers.current.get(id);
    if (timer) clearTimeout(timer);
    toastTimers.current.delete(id);
    setToasts((ts) => ts.filter((t) => t.id !== id));
  }, []);

  const scheduleDismiss = useCallback(
    (id: number, ms: number) => {
      const prev = toastTimers.current.get(id);
      if (prev) clearTimeout(prev);
      toastTimers.current.set(
        id,
        setTimeout(() => dismissToast(id), ms),
      );
    },
    [dismissToast],
  );

  const pauseToast = useCallback((id: number) => {
    const timer = toastTimers.current.get(id);
    if (timer) clearTimeout(timer);
    toastTimers.current.delete(id);
  }, []);

  const resumeToast = useCallback(
    (id: number) => scheduleDismiss(id, 5000),
    [scheduleDismiss],
  );

  const pushToast = useCallback((toast: Omit<Toast, "id">): number => {
    const id = nextId();
    setToasts((ts) => [...ts.slice(-2), { ...toast, id }]);
    if (toast.state === "success") scheduleDismiss(id, 5000);
    return id;
  }, [scheduleDismiss]);

  /** Fire pending toast, apply mutation after applyDelay, flip toast after toastDelay. */
  const executeTx = useCallback(
    (pendingTitle: string, successTitle: string, mutate: () => void, applyDelay = 1600, toastDelay = 2400) => {
      const id = pushToast({ state: "pending", title: pendingTitle });
      window.setTimeout(mutate, applyDelay);
      window.setTimeout(() => {
        setToasts((ts) => ts.map((t) => (t.id === id ? { ...t, state: "success", title: successTitle } : t)));
        scheduleDismiss(id, 5000);
      }, toastDelay);
    },
    [pushToast, scheduleDismiss],
  );

  /* ------------------------------------------------------------- engine */

  useEffect(() => {
    const interval = window.setInterval(() => {
      if (document.hidden) return;
      const t = Date.now();
      setNow(t);
      setBlock((b) => b + 1);
      tickCount.current += 1;

      setVaults((vs) =>
        vs.map((v) => {
          if (v.status !== "LIVE") return v;
          const change = (Math.random() - 0.5) * 0.001; // ±0.05%
          const price = v.price * (1 + change);
          const bufferPct = Math.min(96, Math.max(58, v.bufferPct + (Math.random() - 0.48) * 0.3));
          const buffer = Math.max(0, v.buffer + (Math.random() - 0.35) * 220);
          const obligation = v.supply * price;
          const point: SeriesPoint = { obligation, backing: obligation * (1.0014 + Math.random() * 0.0006) };
          return {
            ...v,
            price,
            change24h: v.change24h + change * 100,
            buffer,
            bufferPct,
            delta: 1 + (Math.random() - 0.5) * 0.0016,
            solvency: [...v.solvency.slice(1), point],
          };
        }),
      );

      setAgg((prev) => {
        const total = prev["24H"][prev["24H"].length - 1].obligation * (1 + (Math.random() - 0.5) * 0.0006);
        const point: SeriesPoint = { obligation: total, backing: total * (1.0014 + Math.random() * 0.0006) };
        const shift = (arr: SeriesPoint[]) => [...arr.slice(1), point];
        return { "1H": shift(prev["1H"]), "24H": shift(prev["24H"]), "7D": shift(prev["7D"]), ALL: shift(prev["ALL"]) };
      });

      setRewards((r) => r + 0.006 + Math.random() * 0.01);
      setTotalStaked((s) => s + Math.floor(Math.random() * 3));

      // keepers stay fresh
      setKeepers((ks) =>
        ks.map((k) =>
          k.nextInSec !== undefined
            ? { ...k, nextInSec: Math.max(0, k.nextInSec - 2) }
            : { ...k, lastRun: t },
        ),
      );

      // ambient flow roughly every 20s
      if (tickCount.current % 10 === 0) {
        setFlows((fs) => {
          const vault = FLOW_VAULTS[Math.floor(Math.random() * 3)];
          const price = vault === "utsla" ? 412.36 : vault === "unvda" ? 178.92 : 592.1;
          const type: FlowType = Math.random() < 0.55 ? "MINT" : Math.random() < 0.75 ? "REDEEM" : Math.random() < 0.9 ? "STAKE" : "CLAIM";
          const isCert = type === "MINT" || type === "REDEEM";
          const amount = isCert ? 0.5 + Math.random() * 18 : 40 + Math.random() * 700;
          const flow: Flow = {
            id: nextId(),
            type,
            vault: isCert ? vault : "token",
            amount,
            usdc: isCert ? amount * price : amount,
            price: isCert ? price * (1 + (Math.random() - 0.5) * 0.001) : 1,
            feeBps: isCert ? 10 : 0,
            time: t,
            tx: randHash(),
          };
          return [flow, ...fs];
        });
      }
    }, 2000);
    return () => window.clearInterval(interval);
  }, []);

  // one-second clock for countdown labels
  useEffect(() => {
    const clock = window.setInterval(() => setNow(Date.now()), 1000);
    return () => window.clearInterval(clock);
  }, []);

  /* ---------------------------------------------------------- navigation */

  const goVault = useCallback((id: VaultId) => {
    setSelectedVault(id);
    setView("vaults");
  }, []);

  const goMint = useCallback((tab: "mint" | "redeem", asset: VaultId) => {
    setMintPreset((p) => ({ tab, asset, nonce: p.nonce + 1 }));
    setView("mint");
  }, []);

  /* -------------------------------------------------------------- wallet */

  const connect = useCallback(() => setConnected(true), []);
  const disconnect = useCallback(() => setConnected(false), []);

  /* ----------------------------------------------------------- mutations */

  const bumpVault = useCallback((asset: VaultId, supplyDelta: number) => {
    setVaults((vs) =>
      vs.map((v) => {
        if (v.id !== asset) return v;
        const supply = Math.max(0, v.supply + supplyDelta);
        const obligation = supply * v.price;
        const point: SeriesPoint = { obligation, backing: obligation * (1.0014 + Math.random() * 0.0006) };
        return { ...v, supply, solvency: [...v.solvency.slice(1), point] };
      }),
    );
  }, []);

  const mint = useCallback(
    (asset: VaultId, amountUsdc: number, receive: number) => {
      executeTx(
        `Mint pending: ${FLOW_NAMES[asset]}`,
        `Mint confirmed: ${receive.toFixed(4)} ${FLOW_NAMES[asset]}`,
        () => {
          setUsdc((u) => Math.max(0, u - amountUsdc));
          setPositions((p) => ({ ...p, [asset]: p[asset] + receive }));
          bumpVault(asset, receive);
          setFlows((fs) => [
            {
              id: nextId(),
              type: "MINT",
              vault: asset,
              amount: receive,
              usdc: amountUsdc,
              price: amountUsdc / receive,
              feeBps: 10,
              time: Date.now(),
              tx: randHash(),
            },
            ...fs,
          ]);
        },
      );
    },
    [executeTx, bumpVault],
  );

  const redeem = useCallback(
    (asset: VaultId, units: number, receiveUsdc: number) => {
      executeTx(
        `Redeem pending: ${FLOW_NAMES[asset]}`,
        `Redeem confirmed: $${receiveUsdc.toFixed(2)} USDC`,
        () => {
          setPositions((p) => ({ ...p, [asset]: Math.max(0, p[asset] - units) }));
          setUsdc((u) => u + receiveUsdc);
          bumpVault(asset, -units);
          setFlows((fs) => [
            {
              id: nextId(),
              type: "REDEEM",
              vault: asset,
              amount: units,
              usdc: receiveUsdc,
              price: receiveUsdc / units,
              feeBps: 10,
              time: Date.now(),
              tx: randHash(),
            },
            ...fs,
          ]);
        },
      );
    },
    [executeTx, bumpVault],
  );

  const stake = useCallback(
    (amount: number) => {
      executeTx("Stake pending", `Stake confirmed: ${amount.toFixed(2)} token`, () => {
        setTokenLiquid((v) => Math.max(0, v - amount));
        setTokenStaked((v) => v + amount);
        setTotalStaked((v) => v + amount);
        setFlows((fs) => [
          { id: nextId(), type: "STAKE", vault: "token", amount, usdc: amount, price: 1, feeBps: 0, time: Date.now(), tx: randHash() },
          ...fs,
        ]);
      });
    },
    [executeTx],
  );

  const unstake = useCallback(
    (amount: number) => {
      executeTx("Unstake pending", `Unstake confirmed: ${amount.toFixed(2)} token`, () => {
        const startAt = Date.now();
        setTokenStaked((v) => Math.max(0, v - amount));
        setTotalStaked((v) => Math.max(0, v - amount));
        setCooldowns((cs) => [{ id: nextId(), amount, startAt, readyAt: startAt + COOLDOWN_MS, ready: false }, ...cs]);
        setFlows((fs) => [
          { id: nextId(), type: "UNSTAKE", vault: "token", amount, usdc: amount, price: 1, feeBps: 0, time: Date.now(), tx: randHash() },
          ...fs,
        ]);
      });
    },
    [executeTx],
  );

  const claim = useCallback(() => {
    const r = rewards;
    if (r <= 0) return;
    executeTx("Claim pending", `Claim confirmed: ${r.toFixed(2)} token`, () => {
      setRewards(0);
      setTokenLiquid((v) => v + r);
      setFlows((fs) => [
        { id: nextId(), type: "CLAIM", vault: "token", amount: r, usdc: r, price: 1, feeBps: 0, time: Date.now(), tx: randHash() },
        ...fs,
      ]);
    });
  }, [executeTx, rewards]);

  const fastForward = useCallback((id: number) => {
    setCooldowns((cs) => cs.map((c) => (c.id === id ? { ...c, ready: true, readyAt: Date.now() } : c)));
  }, []);

  const withdraw = useCallback(
    (id: number) => {
      const cd = cooldowns.find((c) => c.id === id);
      if (!cd) return;
      executeTx("Withdraw pending", `Withdraw confirmed: ${cd.amount.toFixed(2)} token`, () => {
        setTokenLiquid((v) => v + cd.amount);
        setCooldowns((cs) => cs.filter((c) => c.id !== id));
        setFlows((fs) => [
          { id: nextId(), type: "WITHDRAW", vault: "token", amount: cd.amount, usdc: cd.amount, price: 1, feeBps: 0, time: Date.now(), tx: randHash() },
          ...fs,
        ]);
      });
    },
    [cooldowns, executeTx],
  );

  /* -------------------------------------------------------------- keepers */

  const runKeeper = useCallback(
    (id: string) => {
      const t = Date.now();
      setKeepers((ks) => ks.map((k) => (k.id === id ? { ...k, lastRun: t, runsToday: k.runsToday + 1 } : k)));
      if (id === "delta") {
        pushToast({ state: "success", title: "Band within ±0.2%, no rebalance needed" });
      } else if (id === "funding") {
        setVaults((vs) => vs.map((v) => (v.id === "utsla" ? { ...v, buffer: v.buffer + 412 } : v)));
        setKeepers((ks) => ks.map((k) => (k.id === id ? { ...k, nextInSec: 3600 } : k)));
        pushToast({ state: "success", title: "Funding swept: +$412 to buffer" });
      } else if (id === "snapshot") {
        pushToast({ state: "success", title: `Snapshot pinned at block ${block.toLocaleString("en-US")}` });
      } else if (id === "watchdog") {
        pushToast({ state: "success", title: "Buffer healthy: no threshold crossings" });
      } else if (id === "indexer") {
        pushToast({ state: "success", title: `Indexed through block ${block.toLocaleString("en-US")}` });
      }
    },
    [pushToast, block],
  );

  /* ---------------------------------------------------------------- flows */

  const loadMoreFlows = useCallback(() => {
    loadOffset.current += 1;
    const rand = mulberry32(777 + loadOffset.current * 131);
    setFlows((fs) => {
      const oldest = fs[fs.length - 1]?.time ?? Date.now();
      const older: Flow[] = [];
      let t = oldest - 20 * 60 * 1000;
      for (let i = 0; i < 8; i++) {
        const r = rand();
        const type: FlowType = r < 0.42 ? "MINT" : r < 0.72 ? "REDEEM" : r < 0.88 ? "STAKE" : "CLAIM";
        const vault = FLOW_VAULTS[Math.floor(rand() * 3)];
        const price = vault === "utsla" ? 412.36 : vault === "unvda" ? 178.92 : 592.1;
        const isCert = type === "MINT" || type === "REDEEM";
        const amount = isCert ? 0.5 + rand() * 22 : 40 + rand() * 900;
        older.push({
          id: nextId(),
          type,
          vault: isCert ? vault : "token",
          amount,
          usdc: isCert ? amount * price : amount,
          price: isCert ? price : 1,
          feeBps: isCert ? 10 : 0,
          time: t,
          tx: randHash(rand),
        });
        t -= (20 + rand() * 200) * 60 * 1000;
      }
      return [...fs, ...older];
    });
  }, []);

  /* ---------------------------------------------------------------- totals */

  const totals = useMemo(() => {
    const live = vaults.filter((v) => v.status === "LIVE");
    const notional = live.reduce((s, v) => s + v.supply * v.price, 0);
    const margin = live.reduce((s, v) => s + v.supply * v.price * 1.0002, 0);
    const buffer = live.reduce((s, v) => s + v.buffer, 0);
    const delta = live.length ? live.reduce((s, v) => s + v.delta, 0) / live.length : 1;
    return { notional, margin, buffer, ratio: (margin / Math.max(1, notional)) * 100, delta };
  }, [vaults]);

  const value: DashboardCtx = {
    block,
    now,
    vaults,
    agg,
    totals,
    view,
    setView,
    selectedVault,
    goVault,
    mintPreset,
    goMint,
    connected,
    address: MOCK_ADDRESS,
    walletModalOpen,
    setWalletModalOpen,
    connect,
    disconnect,
    usdc,
    tokenLiquid,
    tokenStaked,
    totalStaked,
    rewards,
    positions,
    flows,
    loadMoreFlows,
    cooldowns,
    keepers,
    runKeeper,
    toasts,
    dismissToast,
    pauseToast,
    resumeToast,
    mint,
    redeem,
    stake,
    unstake,
    claim,
    fastForward,
    withdraw,
  };

  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}
