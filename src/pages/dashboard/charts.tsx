/**
 * Canvas charts for a solvency series and a funding-bar series.
 *
 * NOTE: both are currently unmounted. No view function on the UseCert contracts returns a
 * time series, so there is no 60-point solvency curve and no 48-bar funding history to
 * draw; the views render an honest empty state instead of a curve derived from one point.
 * These are kept, unchanged, for whenever an event indexer exists to feed them — do not
 * wire them to interpolated or repeated values in the meantime.
 */
import { useCallback, useEffect, useRef, useState } from "react";
import type { FundingBar, SeriesPoint, Timeframe } from "./store";
import { fmtCompactUSD, fmtUSD } from "./format";

/* ------------------------------------------------------------ size hook */

function useSize<T extends HTMLElement>() {
  const ref = useRef<T>(null);
  const [size, setSize] = useState({ w: 0, h: 0 });
  useEffect(() => {
    if (!ref.current) return;
    const ro = new ResizeObserver((entries) => {
      const r = entries[0].contentRect;
      setSize({ w: r.width, h: r.height });
    });
    ro.observe(ref.current);
    return () => ro.disconnect();
  }, []);
  return { ref, size };
}

function useDrawOn(duration = 1200) {
  const progress = useRef(0);
  const done = useRef(false);
  useEffect(() => {
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
      progress.current = 1;
      done.current = true;
    }
  }, []);
  const run = useCallback(
    (draw: () => void) => {
      if (done.current) return;
      done.current = true;
      let raf = 0;
      const start = performance.now();
      const step = (t: number) => {
        progress.current = Math.min((t - start) / duration, 1);
        draw();
        if (progress.current < 1) raf = requestAnimationFrame(step);
      };
      raf = requestAnimationFrame(step);
      return () => cancelAnimationFrame(raf);
    },
    [duration],
  );
  return { progress, run };
}

const TF_SPACING_MS: Record<Timeframe, number> = {
  "1H": 4 * 60 * 1000,
  "24H": 24 * 60 * 1000,
  "7D": 2 * 3600 * 1000,
  ALL: 2 * 86400 * 1000,
};

function xLabel(tf: Timeframe, ageMs: number): string {
  const d = new Date(Date.now() - ageMs);
  if (tf === "1H" || tf === "24H") {
    return d.toLocaleTimeString("en-US", { hour: "2-digit", minute: "2-digit", hour12: false });
  }
  return d.toLocaleDateString("en-US", { month: "short", day: "numeric" });
}

function tipTime(tf: Timeframe, ageMs: number): string {
  const d = new Date(Date.now() - ageMs);
  const date = d.toLocaleDateString("en-US", { month: "short", day: "numeric" });
  const time = d.toLocaleTimeString("en-US", { hour: "2-digit", minute: "2-digit", hour12: false });
  return tf === "ALL" ? date : `${date} · ${time}`;
}

/* -------------------------------------------------------- solvency chart */

export function SolvencyChart({
  points,
  tf = "24H",
  height = 380,
}: {
  points: SeriesPoint[];
  tf?: Timeframe;
  height?: number;
}) {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const { ref: wrapRef, size } = useSize<HTMLDivElement>();
  const [hover, setHover] = useState<number | null>(null);
  const [hoverTime, setHoverTime] = useState("");
  const { progress, run } = useDrawOn(1200);

  const PAD = { l: 8, r: 62, t: 14, b: 26 };

  const draw = useCallback(() => {
    const canvas = canvasRef.current;
    if (!canvas || size.w === 0 || points.length < 2) return;
    const dpr = window.devicePixelRatio || 1;
    const w = size.w;
    const h = height;
    if (canvas.width !== w * dpr || canvas.height !== h * dpr) {
      canvas.width = w * dpr;
      canvas.height = h * dpr;
    }
    const ctx = canvas.getContext("2d");
    if (!ctx) return;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, w, h);

    const iw = w - PAD.l - PAD.r;
    const ih = h - PAD.t - PAD.b;
    let min = Infinity;
    let max = -Infinity;
    for (const p of points) {
      min = Math.min(min, p.obligation);
      max = Math.max(max, p.backing);
    }
    const pad = (max - min) * 0.15 || 1;
    min -= pad;
    max += pad;
    const X = (i: number) => PAD.l + (i / (points.length - 1)) * iw;
    const Y = (v: number) => PAD.t + ih - ((v - min) / (max - min)) * ih;

    // grid + y labels
    ctx.strokeStyle = "rgba(255,255,255,0.06)";
    ctx.fillStyle = "rgba(255,255,255,0.6)";
    ctx.font = "10px 'Geist Mono', monospace";
    ctx.textAlign = "left";
    ctx.lineWidth = 1;
    for (let g = 0; g <= 4; g++) {
      const v = min + ((max - min) * g) / 4;
      const y = Y(v);
      ctx.beginPath();
      ctx.moveTo(PAD.l, y);
      ctx.lineTo(PAD.l + iw, y);
      ctx.stroke();
      ctx.fillText(fmtCompactUSD(v), PAD.l + iw + 8, y + 3);
    }
    // x labels
    ctx.textAlign = "center";
    const spacing = TF_SPACING_MS[tf];
    for (let g = 0; g <= 4; g++) {
      const i = Math.round(((points.length - 1) * g) / 4);
      const age = (points.length - 1 - i) * spacing;
      ctx.fillText(xLabel(tf, age), X(i), h - 8);
    }

    ctx.save();
    ctx.beginPath();
    ctx.rect(0, 0, PAD.l + iw * progress.current + 2, h);
    ctx.clip();

    // backing area fill (metallic green gradient to transparent)
    const grad = ctx.createLinearGradient(0, PAD.t, 0, PAD.t + ih);
    grad.addColorStop(0, "rgba(168,201,164,0.30)");
    grad.addColorStop(0.55, "rgba(133,152,133,0.10)");
    grad.addColorStop(1, "rgba(133,152,133,0)");
    ctx.beginPath();
    ctx.moveTo(X(0), Y(points[0].backing));
    for (let i = 1; i < points.length; i++) ctx.lineTo(X(i), Y(points[i].backing));
    ctx.lineTo(X(points.length - 1), PAD.t + ih);
    ctx.lineTo(X(0), PAD.t + ih);
    ctx.closePath();
    ctx.fillStyle = grad;
    ctx.fill();

    // backing line
    ctx.beginPath();
    ctx.moveTo(X(0), Y(points[0].backing));
    for (let i = 1; i < points.length; i++) ctx.lineTo(X(i), Y(points[i].backing));
    ctx.strokeStyle = "#a8c9a4";
    ctx.lineWidth = 1.5;
    ctx.stroke();

    // obligation line (silver)
    ctx.beginPath();
    ctx.moveTo(X(0), Y(points[0].obligation));
    for (let i = 1; i < points.length; i++) ctx.lineTo(X(i), Y(points[i].obligation));
    ctx.strokeStyle = "rgba(202,208,202,0.9)";
    ctx.lineWidth = 1;
    ctx.stroke();

    ctx.restore();

    // crosshair
    if (hover !== null && hover >= 0 && hover < points.length) {
      const x = X(hover);
      ctx.strokeStyle = "rgba(255,255,255,0.25)";
      ctx.lineWidth = 1;
      ctx.beginPath();
      ctx.moveTo(x, PAD.t);
      ctx.lineTo(x, PAD.t + ih);
      ctx.stroke();
      const p = points[hover];
      for (const [v, c] of [
        [p.backing, "#a8c9a4"],
        [p.obligation, "#cad0ca"],
      ] as const) {
        ctx.beginPath();
        ctx.arc(x, Y(v), 3, 0, Math.PI * 2);
        ctx.fillStyle = c;
        ctx.fill();
      }
    }
  }, [size, points, hover, height, tf, progress, PAD.l, PAD.r, PAD.t, PAD.b]);

  const drawRef = useRef(draw);
  useEffect(() => {
    drawRef.current = draw;
    draw();
  }, [draw]);
  useEffect(() => run(() => drawRef.current()), [run]);

  const onMove = (e: React.MouseEvent<HTMLDivElement>) => {
    const rect = e.currentTarget.getBoundingClientRect();
    const iw = size.w - PAD.l - PAD.r;
    const x = e.clientX - rect.left - PAD.l;
    const i = Math.max(0, Math.min(points.length - 1, Math.round((x / iw) * (points.length - 1))));
    setHover(i);
    setHoverTime(tipTime(tf, (points.length - 1 - i) * TF_SPACING_MS[tf]));
  };

  const hoverPoint = hover !== null ? points[hover] : null;

  return (
    <div ref={wrapRef} className="relative w-full" style={{ height }} onMouseMove={onMove} onMouseLeave={() => setHover(null)}>
      <canvas ref={canvasRef} style={{ width: "100%", height: "100%", display: "block" }} />
      {hoverPoint && hover !== null && (
        <div
          className="pointer-events-none absolute z-10 border hairline-dark bg-[#0d0f0d] px-3 py-2 font-mono text-[11px] leading-[1.7]"
          style={{
            left: Math.min(Math.max((hover / (points.length - 1)) * (size.w - PAD.l - PAD.r) + PAD.l + 12, 8), size.w - 190),
            top: 10,
          }}
        >
          <p className="text-white-60">{hoverTime}</p>
          <p className="text-green-bright">BACKING {fmtUSD(hoverPoint.backing, 0)}</p>
          <p className="text-silver">SUPPLY × PRICE {fmtUSD(hoverPoint.obligation, 0)}</p>
          <p className="text-white-60">
            DELTA +{(((hoverPoint.backing / hoverPoint.obligation) - 1) * 100).toFixed(2)}%
          </p>
        </div>
      )}
    </div>
  );
}

/* ---------------------------------------------------------- funding chart */

export function FundingChart({ bars, height = 260 }: { bars: FundingBar[]; height?: number }) {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const { ref: wrapRef, size } = useSize<HTMLDivElement>();
  const [hover, setHover] = useState<number | null>(null);
  const [hoverHour, setHoverHour] = useState("");
  const { progress, run } = useDrawOn(1000);

  const PAD = { l: 8, r: 8, t: 14, b: 24 };

  const draw = useCallback(() => {
    const canvas = canvasRef.current;
    if (!canvas || size.w === 0 || bars.length === 0) return;
    const dpr = window.devicePixelRatio || 1;
    const w = size.w;
    const h = height;
    if (canvas.width !== w * dpr || canvas.height !== h * dpr) {
      canvas.width = w * dpr;
      canvas.height = h * dpr;
    }
    const ctx = canvas.getContext("2d");
    if (!ctx) return;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, w, h);

    const iw = w - PAD.l - PAD.r;
    const ih = h - PAD.t - PAD.b;
    const maxAbs = Math.max(...bars.map((b) => Math.abs(b.rate))) || 1;
    const zeroY = PAD.t + ih * 0.62;
    const scale = (ih * 0.55) / maxAbs;
    const slot = iw / bars.length;
    const bw = Math.max(2, slot * 0.55);

    // zero line
    ctx.strokeStyle = "rgba(255,255,255,0.12)";
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.moveTo(PAD.l, zeroY);
    ctx.lineTo(PAD.l + iw, zeroY);
    ctx.stroke();

    // bars (staggered grow)
    for (let i = 0; i < bars.length; i++) {
      const local = Math.max(0, Math.min((progress.current - i * 0.012) / 0.6, 1));
      if (local <= 0) continue;
      const b = bars[i];
      const bh = Math.abs(b.rate) * scale * local;
      const x = PAD.l + i * slot + (slot - bw) / 2;
      ctx.fillStyle = b.rate >= 0 ? (hover === i ? "#c4dcc0" : "#a8c9a4") : hover === i ? "#e6dba8" : "#d8c98a";
      if (b.rate >= 0) ctx.fillRect(x, zeroY - bh, bw, bh);
      else ctx.fillRect(x, zeroY, bw, bh);
    }

    // x labels (every 12th)
    ctx.fillStyle = "rgba(255,255,255,0.6)";
    ctx.font = "10px 'Geist Mono', monospace";
    ctx.textAlign = "center";
    for (let i = 0; i < bars.length; i += 12) {
      const d = new Date(Date.now() - (bars.length - 1 - i) * 3600 * 1000);
      ctx.fillText(
        d.toLocaleTimeString("en-US", { hour: "2-digit", minute: "2-digit", hour12: false }),
        PAD.l + i * slot + slot / 2,
        h - 8,
      );
    }
  }, [size, bars, hover, height, progress, PAD.l, PAD.r, PAD.t, PAD.b]);

  const drawRef = useRef(draw);
  useEffect(() => {
    drawRef.current = draw;
    draw();
  }, [draw]);
  useEffect(() => run(() => drawRef.current()), [run]);

  const onMove = (e: React.MouseEvent<HTMLDivElement>) => {
    const rect = e.currentTarget.getBoundingClientRect();
    const iw = size.w - PAD.l - PAD.r;
    const i = Math.max(0, Math.min(bars.length - 1, Math.floor(((e.clientX - rect.left - PAD.l) / iw) * bars.length)));
    setHover(i);
    setHoverHour(
      new Date(Date.now() - (bars.length - 1 - i) * 3600 * 1000).toLocaleTimeString("en-US", {
        hour: "2-digit",
        minute: "2-digit",
        hour12: false,
      }),
    );
  };

  const hoverBar = hover !== null ? bars[hover] : null;

  return (
    <div ref={wrapRef} className="relative w-full" style={{ height }} onMouseMove={onMove} onMouseLeave={() => setHover(null)}>
      <canvas ref={canvasRef} style={{ width: "100%", height: "100%", display: "block" }} />
      {hoverBar && hover !== null && (
        <div
          className="pointer-events-none absolute z-10 border hairline-dark bg-[#0d0f0d] px-3 py-2 font-mono text-[11px] leading-[1.7]"
          style={{ left: Math.min(Math.max((hover / bars.length) * size.w, 8), size.w - 200), top: 8 }}
        >
          <p className="text-white-60">{hoverHour} HOUR</p>
          <p className={hoverBar.rate >= 0 ? "text-green-bright" : "text-warn"}>
            RATE {hoverBar.rate >= 0 ? "+" : ""}
            {hoverBar.rate.toFixed(4)}%
          </p>
          <p className="text-silver">
            ACCRUED {hoverBar.accrued >= 0 ? "+" : ""}
            {fmtUSD(hoverBar.accrued, 0)}
          </p>
          <p className="text-white-60">BUFFER AFTER {fmtCompactUSD(hoverBar.bufferAfter)}</p>
        </div>
      )}
    </div>
  );
}
