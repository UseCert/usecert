import { useEffect, useState, type ReactNode } from "react";
import { Outlet } from "@/lib/router-compat";
import Lenis from "lenis";
import Navbar from "./Navbar";
import Footer from "./Footer";
import MenuModal from "./MenuModal";
import { setLenis } from "@/lib/scroll";

/**
 * Shared layout: fixed overlay Navbar + floating hamburger menu modal +
 * content slot + Footer.
 *
 * Nav offset contract: the nav is `fixed top-0 z-50` (overlay style), so this
 * Layout owns the offset: top padding equal to the nav height (h-16 md:h-20)
 * on the content slot. Pages with full-bleed heroes opt out INSIDE the page
 * (e.g. `-mt-16 md:-mt-20` on the hero section). Page agents: do not add
 * nav-height padding/margins yourselves.
 */
export default function Layout({ children }: { children?: ReactNode }) {
  const [menuOpen, setMenuOpen] = useState(false);

  // Lenis smooth scrolling (lerp 0.09), disabled for reduced motion.
  useEffect(() => {
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;
    const lenis = new Lenis({ lerp: 0.09 });
    setLenis(lenis);
    let raf = 0;
    const loop = (time: number) => {
      lenis.raf(time);
      raf = requestAnimationFrame(loop);
    };
    raf = requestAnimationFrame(loop);
    return () => {
      cancelAnimationFrame(raf);
      lenis.destroy();
      setLenis(null);
    };
  }, []);

  // Route-change scroll handling lives in <ScrollToTop /> (App level),
  // which resets through Lenis so no stale mid-page position survives.

  return (
    <div className="min-h-[100dvh] bg-ink text-white">
      <Navbar onMenuOpen={() => setMenuOpen(true)} />
      <MenuModal open={menuOpen} onOpen={() => setMenuOpen(true)} onClose={() => setMenuOpen(false)} />
      <main className="pt-16 md:pt-20">
        <Outlet />
      </main>
      <Footer />
    </div>
  );
}
