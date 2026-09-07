import { useEffect, useState } from "react";
import { Link, useLocation, useNavigate } from "@/lib/router-compat";
import { AnimatePresence, motion } from "framer-motion";
import { Menu, X } from "lucide-react";
import { scrollToHash } from "@/lib/scroll";
import SwapButton from "./SwapButton";

type Item = { label: string; to?: string; hash?: string };

const MENU_ITEMS: Item[] = [
  { label: "Home", to: "/" },
  { label: "Vaults", to: "/vaults" },
  { label: "How It Works", hash: "#how-it-works" },
  { label: "Compare", hash: "#compare" },
  { label: "Roles", to: "/roles" },
  { label: "Learn", to: "/learn" },
  { label: "Dashboard", to: "/dashboard" },
];

/**
 * Floating hamburger (appears bottom-center after scrolling past hero) +
 * centered dark menu modal over a blurred backdrop (design.md §5.2).
 */
export default function MenuModal({
  open,
  onOpen,
  onClose,
}: {
  open: boolean;
  onOpen: () => void;
  onClose: () => void;
}) {
  const [showFab, setShowFab] = useState(false);
  const location = useLocation();
  const navigate = useNavigate();

  useEffect(() => {
    const onScroll = () => setShowFab(window.scrollY > window.innerHeight * 0.8);
    onScroll();
    window.addEventListener("scroll", onScroll, { passive: true });
    return () => window.removeEventListener("scroll", onScroll);
  }, []);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && onClose();
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  useEffect(() => {
    onClose();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [location.pathname]);

  const go = (item: Item) => {
    onClose();
    if (item.to) {
      navigate(item.to);
      window.scrollTo(0, 0);
    } else if (item.hash) {
      if (location.pathname === "/") {
        scrollToHash(item.hash);
      } else {
        navigate(`/${item.hash}`);
      }
    }
  };

  return (
    <>
      {/* Floating hamburger */}
      <AnimatePresence>
        {showFab && !open && (
          <motion.button
            type="button"
            aria-label="Open menu"
            onClick={onOpen}
            initial={{ opacity: 0, y: 16 }}
            animate={{ opacity: 1, y: 0 }}
            exit={{ opacity: 0, y: 16 }}
            transition={{ duration: 0.25 }}
            className="fixed bottom-6 left-1/2 z-50 flex h-11 w-11 -translate-x-1/2 items-center justify-center border hairline-dark bg-ink text-white"
          >
            <Menu size={18} />
          </motion.button>
        )}
      </AnimatePresence>

      {/* Modal */}
      <AnimatePresence>
        {open && (
          <motion.div
            className="fixed inset-0 z-[60] flex flex-col items-center justify-center px-4"
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            exit={{ opacity: 0 }}
            transition={{ duration: 0.25 }}
          >
            <div
              className="absolute inset-0 bg-abyss/60 backdrop-blur-[18px]"
              onClick={onClose}
              aria-hidden
            />
            <motion.div
              role="dialog"
              aria-modal="true"
              aria-label="Menu"
              className="relative w-full max-w-[480px] border hairline-dark bg-[#0d0f0d] p-8 md:p-10"
              initial={{ scale: 0.96, opacity: 0 }}
              animate={{ scale: 1, opacity: 1 }}
              exit={{ scale: 0.96, opacity: 0 }}
              transition={{ type: "spring", duration: 0.5, bounce: 0.15 }}
            >
              <p className="font-mono text-[11px] uppercase tracking-[0.08em] text-white-60">Menu</p>
              <nav className="mt-4 flex flex-col">
                {MENU_ITEMS.map((item, i) => (
                  <motion.button
                    key={item.label}
                    type="button"
                    onClick={() => go(item)}
                    className="text-left text-[28px] font-semibold uppercase leading-[1.25] tracking-[-0.03em] text-white transition-colors hover:text-green-bright"
                    initial={{ opacity: 0, y: 12 }}
                    animate={{ opacity: 1, y: 0 }}
                    transition={{ delay: 0.08 + i * 0.05, duration: 0.3 }}
                  >
                    {item.label}
                  </motion.button>
                ))}
              </nav>

              <p className="mt-8 font-mono text-[11px] uppercase tracking-[0.08em] text-white-60">Community</p>
              <div className="mt-3 flex flex-col gap-1.5 font-mono text-[13px]">
                <a href="https://x.com/usecert" target="_blank" rel="noreferrer" className="text-white-60 transition-colors hover:text-green-bright">
                  x.com/usecert
                </a>
                <a href="https://t.me/usecert" target="_blank" rel="noreferrer" className="text-white-60 transition-colors hover:text-green-bright">
                  t.me/usecert
                </a>
              </div>

              <div className="mt-8 flex items-end justify-between gap-4">
                <SwapButton label="Launch App" to="/dashboard" variant="primary" className="flex-1 [&>span]:w-full" />
              </div>
              <div className="mt-5 flex justify-end gap-4 font-mono text-[10px] uppercase tracking-[0.08em]">
                <Link to="/legal/privacy-policy" className="text-white-60 transition-colors hover:text-white">
                  Privacy Policy
                </Link>
                <Link to="/legal/terms-of-service" className="text-white-60 transition-colors hover:text-white">
                  Terms of Service
                </Link>
              </div>
            </motion.div>

            {/* Close button below card */}
            <motion.button
              type="button"
              aria-label="Close menu"
              onClick={onClose}
              className="relative mt-4 flex h-11 w-11 items-center justify-center border hairline-dark bg-ink text-white"
              initial={{ opacity: 0, scale: 0.9 }}
              animate={{ opacity: 1, scale: 1 }}
              exit={{ opacity: 0, scale: 0.9 }}
              transition={{ delay: 0.1 }}
            >
              <X size={18} />
            </motion.button>
          </motion.div>
        )}
      </AnimatePresence>
    </>
  );
}
