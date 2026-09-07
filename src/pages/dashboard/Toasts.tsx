import { AnimatePresence, motion } from "framer-motion";
import { Check, Loader2, X } from "lucide-react";
import { useDashboard } from "./store";

/**
 * Toast stack (design.md §5.10): dark cards, hairline border, green-bright
 * left bar, top-right. Pending -> confirmed. Slide in from right, stack max
 * 3, auto-dismiss 5s, hover pauses.
 */
export default function ToastStack() {
  const { toasts, dismissToast, pauseToast, resumeToast } = useDashboard();

  return (
    <div className="pointer-events-none fixed right-4 top-20 z-[80] flex w-[320px] max-w-[calc(100vw-32px)] flex-col gap-2">
      <AnimatePresence initial={false}>
        {toasts.slice(-3).map((t) => (
          <motion.div
            key={t.id}
            layout="position"
            initial={{ opacity: 0, x: 60 }}
            animate={{ opacity: 1, x: 0 }}
            exit={{ opacity: 0, x: 60 }}
            transition={{ type: "spring", duration: 0.55, bounce: 0.25 }}
            onMouseEnter={() => t.state === "success" && pauseToast(t.id)}
            onMouseLeave={() => t.state === "success" && resumeToast(t.id)}
            className="pointer-events-auto relative border hairline-dark bg-[#121a12] py-3 pl-5 pr-9"
          >
            <span className="absolute bottom-0 left-0 top-0 w-[2px] bg-green-bright" aria-hidden />
            <div className="flex items-center gap-2.5">
              {t.state === "pending" ? (
                <Loader2 size={14} className="shrink-0 animate-spin text-silver" />
              ) : (
                <Check size={14} className="shrink-0 text-green-bright" />
              )}
              <p className="font-mono text-[12px] leading-[1.4] text-white">{t.title}</p>
            </div>
            {t.desc && <p className="mt-1 font-mono text-[11px] text-white-60">{t.desc}</p>}
            <button
              type="button"
              aria-label="Dismiss"
              onClick={() => dismissToast(t.id)}
              className="absolute right-2 top-2 text-white-60 transition-colors hover:text-white"
            >
              <X size={13} />
            </button>
          </motion.div>
        ))}
      </AnimatePresence>
    </div>
  );
}
