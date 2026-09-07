import { useEffect } from "react";
import { useLocation } from "react-router";
import { scrollToHash, scrollToTop } from "@/lib/scroll";

/**
 * Global scroll manager: every navigation (page, card, or section link)
 * starts at the top of the new page. Hash links scroll to their target
 * instead. Mounted once in App so it covers every route, including the
 * dashboard which lives outside the landing Layout.
 */
export default function ScrollToTop() {
  const { pathname, hash } = useLocation();

  useEffect(() => {
    if (hash) {
      // Wait for the page to render before scrolling to the anchor.
      const t = window.setTimeout(() => scrollToHash(hash), 80);
      return () => window.clearTimeout(t);
    }
    scrollToTop();
  }, [pathname, hash]);

  return null;
}
