import Lenis from "lenis";

let lenis: Lenis | null = null;

export function setLenis(instance: Lenis | null) {
  lenis = instance;
}

export function scrollToHash(hash: string) {
  const el = document.querySelector(hash);
  if (!el) return;
  if (lenis) {
    lenis.scrollTo(el as HTMLElement, { offset: 0, duration: 1.2 });
  } else {
    (el as HTMLElement).scrollIntoView({ behavior: "smooth" });
  }
}

/** Hard reset to the top of the page. Goes through Lenis first (immediate,
 *  forced) so Lenis cannot restore its cached mid-page position, then syncs
 *  the native scroll for pages without Lenis (e.g. the dashboard). */
export function scrollToTop() {
  if (lenis) {
    lenis.scrollTo(0, { immediate: true, force: true });
  }
  window.scrollTo(0, 0);
}
