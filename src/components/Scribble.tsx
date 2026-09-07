import { useRef } from "react";
import { motion, useInView } from "framer-motion";
import { cn } from "@/lib/utils";

interface ScribbleProps {
  className?: string;
  delay?: number;
  /** trigger draw on scroll into view instead of on mount */
  onScroll?: boolean;
}

/**
 * Hand-drawn "UseCert" signature scribble (green-bright), drawn on via
 * stroke-dashoffset animation. Same placement/proportion role as the
 * template's orange scribble.
 */
export default function Scribble({ className, delay = 0.8, onScroll = false }: ScribbleProps) {
  const ref = useRef<SVGSVGElement>(null);
  const inView = useInView(ref, { once: true, amount: 0.4 });
  const active = onScroll ? inView : true;

  const draw = (d: string, w: number, extraDelay = 0, opacity?: number) => (
    <motion.path
      d={d}
      stroke="#a8c9a4"
      strokeWidth={w}
      strokeLinecap="round"
      strokeLinejoin="round"
      opacity={opacity}
      initial={{ pathLength: 0 }}
      animate={active ? { pathLength: 1 } : { pathLength: 0 }}
      transition={{ duration: 1.4, delay: delay + extraDelay, ease: "easeInOut" }}
    />
  );

  return (
    <svg
      ref={ref}
      viewBox="0 0 900 300"
      fill="none"
      xmlns="http://www.w3.org/2000/svg"
      className={cn("pointer-events-none", className)}
      aria-hidden
    >
      {draw(
        "M60 210 C 90 150, 110 140, 118 160 C 126 182, 100 220, 92 226 C 84 232, 80 218, 96 200 C 130 162, 160 148, 172 158 C 184 168, 168 200, 160 210 C 154 218, 162 214, 178 198 C 196 180, 214 172, 222 180 C 230 188, 220 210, 216 216 C 214 220, 226 208, 244 190 C 262 172, 282 164, 288 174 C 292 182, 282 204, 276 214 C 272 220, 284 210, 300 194 C 318 176, 340 168, 348 178 C 356 188, 342 214, 336 220 C 332 224, 344 214, 362 196 C 384 174, 404 168, 410 178 C 416 188, 400 214, 392 222 C 386 228, 400 218, 420 198 C 442 176, 466 166, 476 176 C 486 186, 470 216, 460 224 C 452 230, 466 220, 488 198 C 512 174, 538 162, 550 172 C 562 182, 546 212, 536 222 C 528 230, 544 218, 568 194 C 594 168, 622 156, 636 166 C 650 176, 634 208, 622 220 C 614 228, 630 216, 656 190 C 684 162, 716 148, 732 158 C 748 168, 730 202, 718 214 C 710 222, 726 210, 754 184 C 784 156, 818 140, 840 150",
        7,
      )}
      {draw("M690 120 C 720 108, 760 100, 800 104", 6, 0.5)}
      {draw("M560 250 C 640 262, 740 256, 830 230", 5, 0.9, 0.7)}
    </svg>
  );
}
