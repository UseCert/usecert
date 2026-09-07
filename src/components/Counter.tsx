import { useEffect, useRef, useState } from "react";
import { useInView } from "framer-motion";
import { cn } from "@/lib/utils";

interface CounterProps {
  /** Target numeric value, e.g. 52 for "52%" or 213 for "$213B" */
  end: number;
  prefix?: string;
  suffix?: string;
  /** decimal places, default 0 */
  decimals?: number;
  duration?: number;
  className?: string;
}

/**
 * Animated counter: counts 0 -> end on scroll into view
 * (1.6s, ease power2.out, trigger at ~80% viewport).
 */
export default function Counter({ end, prefix = "", suffix = "", decimals = 0, duration = 1.6, className }: CounterProps) {
  const ref = useRef<HTMLSpanElement>(null);
  const inView = useInView(ref, { once: true, margin: "0px 0px -20% 0px" });
  const [value, setValue] = useState(0);

  useEffect(() => {
    if (!inView) return;
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
      setValue(end);
      return;
    }
    let raf = 0;
    const start = performance.now();
    const tick = (now: number) => {
      const t = Math.min((now - start) / (duration * 1000), 1);
      // power2.out
      const eased = 1 - (1 - t) * (1 - t);
      setValue(end * eased);
      if (t < 1) raf = requestAnimationFrame(tick);
    };
    raf = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(raf);
  }, [inView, end, duration]);

  return (
    <span ref={ref} className={cn("tabular-nums", className)}>
      {prefix}
      {value.toFixed(decimals)}
      {suffix}
    </span>
  );
}
