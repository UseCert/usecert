import { useState } from "react";
import { AnimatePresence, motion } from "framer-motion";
import { Plus } from "lucide-react";
import { cn } from "@/lib/utils";

export interface AccordionRow {
  title: string;
  /** right-side meta tag, e.g. "DELTA: 1.0" */
  meta?: string;
  /** body paragraphs; rendered in two columns when two provided */
  body: string[];
  /** optional large image shown inside the open row */
  image?: string;
  imageAlt?: string;
}

interface AccordionProps {
  rows: AccordionRow[];
  dark?: boolean;
  className?: string;
}

/**
 * Template accordion: hairline-separated rows, mono index + title left,
 * right meta tag, +/− toggle rotating 45°, first row open by default. Open
 * rows reveal two text columns + optional large image (0.4s height ease).
 */
export default function Accordion({ rows, dark = true, className }: AccordionProps) {
  const [openIndex, setOpenIndex] = useState<number>(0);

  const line = dark ? "hairline-dark" : "hairline-light";
  const titleColor = dark ? "text-white" : "text-ink";
  const metaColor = dark ? "text-white-60" : "text-ink-60";
  const bodyColor = dark ? "text-white-60" : "text-ink-60";

  return (
    <div className={cn("border-t", line, className)}>
      {rows.map((row, i) => {
        const open = openIndex === i;
        return (
          <div key={row.title} className={cn("border-b", line)}>
            <button
              type="button"
              onClick={() => setOpenIndex(open ? -1 : i)}
              aria-expanded={open}
              className="group flex w-full items-center gap-4 py-5 text-left md:gap-8 md:py-6"
            >
              <span
                className={cn(
                  "font-mono text-[13px] transition-colors",
                  open ? "text-green-bright" : metaColor,
                  "group-hover:text-green-bright",
                )}
              >
                {String(i + 1).padStart(2, "0")}
              </span>
              <span
                className={cn(
                  "flex-1 text-[18px] font-semibold uppercase tracking-[-0.02em] transition-transform duration-300 group-hover:translate-x-2 md:text-[22px]",
                  titleColor,
                )}
              >
                {row.title}
              </span>
              {row.meta && (
                <span className={cn("hidden font-mono text-[11px] uppercase tracking-[0.08em] sm:block", metaColor)}>
                  {row.meta}
                </span>
              )}
              <span
                className={cn(
                  "flex h-9 w-9 shrink-0 items-center justify-center border transition-transform duration-300",
                  line,
                  open ? "rotate-45 text-green-bright" : titleColor,
                )}
              >
                <Plus size={16} />
              </span>
            </button>
            <AnimatePresence initial={false}>
              {open && (
                <motion.div
                  initial={{ height: 0, opacity: 0 }}
                  animate={{ height: "auto", opacity: 1 }}
                  exit={{ height: 0, opacity: 0 }}
                  transition={{ duration: 0.4, ease: "easeInOut" }}
                  className="overflow-hidden"
                >
                  <div className="grid gap-6 pb-8 md:grid-cols-2 md:gap-10 md:pl-[52px]">
                    {row.body.map((p, bi) => (
                      <p key={bi} className={cn("text-[15px] leading-[1.55] md:text-[16px]", bodyColor)}>
                        {p}
                      </p>
                    ))}
                  </div>
                  {row.image && (
                    <motion.img
                      src={row.image}
                      alt={row.imageAlt ?? ""}
                      className="mb-8 aspect-[16/10] w-full object-cover md:ml-[52px] md:w-[calc(100%-52px)]"
                      initial={{ opacity: 0, y: 16 }}
                      animate={{ opacity: 1, y: 0 }}
                      transition={{ duration: 0.5 }}
                    />
                  )}
                </motion.div>
              )}
            </AnimatePresence>
          </div>
        );
      })}
    </div>
  );
}
