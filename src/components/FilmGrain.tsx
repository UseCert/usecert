/**
 * Animated film grain overlay. Mounted once at the app root so every page
 * (landing, dashboard, vaults, learn) shares the same living grain as the
 * reference video. Purely decorative; never intercepts pointer events.
 */
export default function FilmGrain() {
  return <div className="film-grain" aria-hidden />;
}
