import { useEffect } from "react";
import { AnimatePresence, motion } from "framer-motion";
import { X } from "lucide-react";

/**
 * Showreel modal (home §15): full-screen dark backdrop + blur, centered 16:9
 * frame with hairline border and corner dots. Uses showreel-poster.jpg with a
 * 12s Ken Burns zoom (showreel.mp4 intentionally skipped). ESC/backdrop closes.
 */
export default function ShowreelModal({ open, onClose }: { open: boolean; onClose: () => void }) {
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && onClose();
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  return (
    <AnimatePresence>
      {open && (
        <motion.div
          className="fixed inset-0 z-[60] flex flex-col items-center justify-center px-4"
          initial={{ opacity: 0 }}
          animate={{ opacity: 1 }}
          exit={{ opacity: 0 }}
          transition={{ duration: 0.25 }}
        >
          <div className="absolute inset-0 bg-abyss/85 backdrop-blur-[18px]" onClick={onClose} aria-hidden />
          <motion.div
            role="dialog"
            aria-modal="true"
            aria-label="Showreel"
            className="relative w-full max-w-[960px]"
            initial={{ scale: 0.94, opacity: 0 }}
            animate={{ scale: 1, opacity: 1 }}
            exit={{ scale: 0.94, opacity: 0 }}
            transition={{ type: "spring", duration: 0.55, bounce: 0.12 }}
          >
            <div className="relative aspect-video w-full overflow-hidden border hairline-dark">
              <span className="absolute left-[-3px] top-[-3px] z-[2] h-[5px] w-[5px] bg-white" aria-hidden />
              <span className="absolute right-[-3px] top-[-3px] z-[2] h-[5px] w-[5px] bg-white" aria-hidden />
              <span className="absolute bottom-[-3px] left-[-3px] z-[2] h-[5px] w-[5px] bg-white" aria-hidden />
              <span className="absolute bottom-[-3px] right-[-3px] z-[2] h-[5px] w-[5px] bg-white" aria-hidden />
              <img src="/showreel-poster.jpg" alt="UseCert certificate plate under a spotlight" className="ken-burns h-full w-full object-cover" />
            </div>
          </motion.div>
          <motion.button
            type="button"
            aria-label="Close showreel"
            onClick={onClose}
            className="relative mt-4 flex h-11 w-11 items-center justify-center border hairline-dark bg-ink text-white"
            initial={{ opacity: 0, scale: 0.9 }}
            animate={{ opacity: 1, scale: 1 }}
            exit={{ opacity: 0, scale: 0.9 }}
          >
            <X size={18} />
          </motion.button>
        </motion.div>
      )}
    </AnimatePresence>
  );
}
