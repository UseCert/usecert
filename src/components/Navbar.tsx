import { useEffect, useState } from "react";
import { Link, useLocation, useNavigate } from "@/lib/router-compat";
import { Menu } from "lucide-react";
import { cn } from "@/lib/utils";
import { scrollToHash } from "@/lib/scroll";
import SwapButton from "./SwapButton";

export const NAV_HEIGHT = "h-16 md:h-20";

interface NavLinkItem {
  label: string;
  hash?: string;
  to?: string;
}

const LINKS: NavLinkItem[] = [
  { label: "VAULTS", hash: "#vaults" },
  { label: "HOW IT WORKS", hash: "#how-it-works" },
  { label: "COMPARE", hash: "#compare" },
  { label: "ROLES", to: "/roles" },
  { label: "FAQ", hash: "#faq" },
];

/**
 * Fixed overlay nav (all landing pages). Transparent over hero, solid ink +
 * hairline bottom border + backdrop blur after 80px scroll.
 */
export default function Navbar({ onMenuOpen }: { onMenuOpen: () => void }) {
  const [scrolled, setScrolled] = useState(false);
  const location = useLocation();
  const navigate = useNavigate();

  useEffect(() => {
    const onScroll = () => setScrolled(window.scrollY > 80);
    onScroll();
    window.addEventListener("scroll", onScroll, { passive: true });
    return () => window.removeEventListener("scroll", onScroll);
  }, []);

  const goToHash = (hash: string) => {
    if (location.pathname === "/") {
      scrollToHash(hash);
    } else {
      navigate(`/${hash}`);
    }
  };

  return (
    <header
      className={cn(
        "fixed top-0 left-0 right-0 z-50 transition-colors duration-300",
        scrolled ? "bg-ink/90 border-b hairline-dark backdrop-blur-[12px]" : "bg-transparent border-b border-transparent",
      )}
    >
      <div className={cn("mx-auto flex max-w-[1440px] items-center justify-between px-4 md:px-6 lg:px-12", NAV_HEIGHT)}>
        {/* Left: monogram + wordmark + tagline */}
        <div className="flex items-center gap-3">
          <Link to="/" className="flex items-center gap-2.5" aria-label="UseCert home">
            <img src="/logo.png" alt="UseCert monogram" className="h-7 w-7 object-contain" />
            <span className="text-[17px] font-semibold uppercase tracking-[-0.02em] text-white">
              UseCert<sup className="text-[9px] align-super">®</sup>
            </span>
          </Link>
          <span className="hidden md:block h-4 w-px bg-hairline-dark" aria-hidden />
          <span className="hidden md:block font-mono text-[11px] uppercase tracking-[0.08em] text-white-60">
            Stock certificates on Robinhood Chain
          </span>
        </div>

        {/* Right: links + CTA + hamburger */}
        <nav className="flex items-center gap-6">
          <ul className="hidden lg:flex items-center gap-2 text-[12px] font-medium uppercase tracking-[0.08em]">
            {LINKS.map((l, i) => (
              <li key={l.label} className="flex items-center gap-2">
                {i > 0 && <span className="text-white-60">/</span>}
                {l.to ? (
                  <Link to={l.to} className="group relative text-white-60 transition-colors hover:text-white">
                    {l.label}
                    <span className="absolute -bottom-1 left-0 h-px w-0 bg-green-bright transition-all duration-300 group-hover:w-full" />
                  </Link>
                ) : (
                  <button
                    type="button"
                    onClick={() => goToHash(l.hash!)}
                    className="group relative text-white-60 transition-colors hover:text-white"
                  >
                    {l.label}
                    <span className="absolute -bottom-1 left-0 h-px w-0 bg-green-bright transition-all duration-300 group-hover:w-full" />
                  </button>
                )}
              </li>
            ))}
          </ul>
          <SwapButton label="Launch App" to="/dashboard" variant="primary" className="[&_span]:px-5 [&_span]:py-3" />
          <button
            type="button"
            onClick={onMenuOpen}
            aria-label="Open menu"
            className="lg:hidden flex h-11 w-11 items-center justify-center border hairline-dark bg-ink text-white"
          >
            <Menu size={18} />
          </button>
        </nav>
      </div>
    </header>
  );
}
