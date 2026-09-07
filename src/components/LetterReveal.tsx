import { motion } from "framer-motion";
import type { ElementType } from "react";
import { cn } from "@/lib/utils";

interface LetterRevealProps {
  text: string;
  as?: ElementType;
  className?: string;
  /** seconds */
  delay?: number;
  /** seconds between chars */
  stagger?: number;
  /** animate on mount instead of on scroll into view */
  immediate?: boolean;
  /** split by word instead of char (long headlines) */
  byWord?: boolean;
  once?: boolean;
}

/**
 * Letter-by-letter reveal: chars stagger in with y 24px -> 0, opacity 0 -> 1.
 * Longer headlines should use byWord.
 */
export default function LetterReveal({
  text,
  as,
  className,
  delay = 0,
  stagger = 0.018,
  immediate = false,
  byWord = false,
  once = true,
}: LetterRevealProps) {
  const Tag = (as ?? "span") as ElementType;
  const reduced =
    typeof window !== "undefined" && window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  if (reduced) {
    return <Tag className={className}>{text}</Tag>;
  }

  const units = byWord ? text.split(" ") : Array.from(text);

  const container = {
    hidden: {},
    show: { transition: { staggerChildren: stagger, delayChildren: delay } },
  };
  const child = {
    hidden: { y: 24, opacity: 0 },
    show: { y: 0, opacity: 1, transition: { duration: 0.6, ease: [0.16, 1, 0.3, 1] as [number, number, number, number] } },
  };

  return (
    <Tag className={cn("inline-block", className)} aria-label={text}>
      <motion.span
        className="inline-block"
        variants={container}
        initial="hidden"
        {...(immediate
          ? { animate: "show" }
          : { whileInView: "show", viewport: { once, amount: 0.3 } })}
      >
        {byWord
          ? units.map((u, i) => (
              <motion.span
                key={`${u}-${i}`}
                variants={child}
                className="inline-block whitespace-pre will-change-transform"
                aria-hidden
              >
                {`${u}${i < units.length - 1 ? "\u00A0" : ""}`}
              </motion.span>
            ))
          : text.split(" ").map((word, wi, arr) => (
              <span key={wi} className="inline-block whitespace-nowrap" aria-hidden>
                {Array.from(word).map((ch, ci) => (
                  <motion.span
                    key={`${ch}-${ci}`}
                    variants={child}
                    className="inline-block whitespace-pre will-change-transform"
                  >
                    {ch}
                  </motion.span>
                ))}
                {wi < arr.length - 1 ? "\u00A0" : ""}
              </span>
            ))}
      </motion.span>
    </Tag>
  );
}
