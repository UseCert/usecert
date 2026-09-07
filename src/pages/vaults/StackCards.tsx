import { useRef } from "react";
import { Link } from "@/lib/router-compat";
import { motion, useScroll, useTransform } from "framer-motion";
import type { MotionValue } from "framer-motion";
import { cn } from "@/lib/utils";
import type { VaultData } from "./data";

/** Status pill: green LIVE, brass SOON. */
export function StatusPill({ status, className }: { status: VaultData["status"]; className?: string }) {
  return (
    <span
      className={cn(
        "inline-flex items-center gap-1.5 rounded-full border px-3 py-1 font-mono text-[10px] uppercase tracking-[0.08em]",
        status === "LIVE" ? "border-green-bright/40 text-green-bright" : "border-warn/40 text-warn",
        className,
      )}
    >
      <span className={cn("h-[6px] w-[6px] rounded-full", status === "LIVE" ? "bg-green-bright" : "bg-warn")} aria-hidden />
      {status === "LIVE" ? "Live" : "Soon"}
    </span>
  );
}

function StackCard({
  card,
  index,
  total,
  progress,
}: {
  card: VaultData;
  index: number;
  total: number;
  progress: MotionValue<number>;
}) {
  const span = 1 / (total - 1 || 1);
  const start = index * span;
  const end = Math.min(start + span, 1);
  const prev = Math.max(0, start - span);

  // Current card scales down + sinks as the next card covers it.
  const scale = useTransform(progress, [start, end], [1, index === total - 1 ? 1 : 0.92]);
  const y = useTransform(progress, [start, end], [0, index === total - 1 ? 0 : 24]);
  // Title outline draws on as the card becomes active.
  const titleOpacity = useTransform(
    progress,
    [index === 0 ? 0 : prev, index === 0 ? span * 0.5 : start],
    [index === 0 ? 0.9 : 0.05, 0.9],
  );
  // Image parallax inside the card.
  const imgY = useTransform(progress, [prev, end], [30, -30]);

  return (
    <div className="sticky top-0 h-[100dvh]">
      <motion.div style={{ scale, y }} className="relative h-full w-full overflow-hidden border-t hairline-dark bg-ink">
        <Link to={`/vaults/${card.slug}`} className="group absolute inset-0 block" aria-label={`${card.name} vault`}>
          {/* Giant solid title behind image (template style) */}
          <motion.span
            style={{ opacity: titleOpacity }}
            className="absolute inset-0 flex items-center justify-center text-[27vw] font-semibold uppercase leading-none tracking-[-0.05em] text-white"
            aria-hidden
          >
            {card.name}
          </motion.span>

          {/* Centered 16:10 image */}
          <div className="absolute inset-0 flex items-center justify-center px-6">
            <motion.div style={{ y: imgY }} className="relative w-full max-w-[880px] overflow-hidden">
              <img
                src={card.image}
                alt={`${card.name} certificate plate`}
                className="aspect-[16/10] w-full object-cover transition-transform duration-500 group-hover:scale-[1.02]"
              />
              <span
                className="pointer-events-none absolute inset-0 -translate-x-full bg-gradient-to-r from-transparent via-green-bright/15 to-transparent transition-transform duration-500 group-hover:translate-x-full"
                aria-hidden
              />
            </motion.div>
          </div>

          {/* Top-left index / top-right label */}
          <span className="absolute left-4 top-24 font-mono text-[13px] text-white-60 md:left-12">
            ({String(index + 1).padStart(2, "0")})
          </span>
          <span className="absolute right-4 top-24 font-mono text-[11px] uppercase tracking-[0.08em] text-white-60 md:right-12">
            Vaults
          </span>

          {/* Status pill above the meta row */}
          <StatusPill status={card.status} className="absolute bottom-24 left-4 md:left-12" />

          {/* Bottom meta row */}
          <div className="absolute bottom-8 left-4 right-4 flex items-end justify-between gap-4 md:left-12 md:right-12">
            <span className="text-[20px] font-semibold uppercase tracking-[-0.03em] text-white md:text-[28px]">
              {card.name}
            </span>
            <span className="hidden font-mono text-[11px] uppercase tracking-[0.08em] text-white-60 md:block">
              {card.tags}
            </span>
            <span className="font-mono text-[13px] text-white-60">{card.year}</span>
          </div>
        </Link>
      </motion.div>
    </div>
  );
}

/**
 * Sticky-stacking vault cards (same mechanics as home section 4).
 * The parent passes a `key` derived from the active filter so the whole
 * stack remounts and the scroll-tracked layout re-runs cleanly.
 */
export default function StackCards({ cards }: { cards: VaultData[] }) {
  const ref = useRef<HTMLDivElement>(null);
  const { scrollYProgress } = useScroll({ target: ref, offset: ["start start", "end end"] });

  return (
    <motion.div
      ref={ref}
      className="relative z-[2]"
      initial={{ opacity: 0 }}
      animate={{ opacity: 1 }}
      transition={{ duration: 0.4, ease: "easeOut" }}
    >
      {cards.map((card, i) => (
        <StackCard key={card.slug} card={card} index={i} total={cards.length} progress={scrollYProgress} />
      ))}
    </motion.div>
  );
}
