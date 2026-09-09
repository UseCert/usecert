import { Link } from "@/lib/router-compat";
import { motion } from "framer-motion";
import SwapButton from "./SwapButton";
import { SOCIALS, XIcon, TelegramIcon } from "./SocialIcons";

const fadeUp = (delay: number) => ({
  initial: { opacity: 0, y: 24 },
  whileInView: { opacity: 1, y: 0 },
  viewport: { once: true, amount: 0.2 },
  transition: { duration: 0.7, delay, ease: [0.16, 1, 0.3, 1] as [number, number, number, number] },
});

const NAV_LINKS = [
  { label: "Home", to: "/" },
  { label: "Vaults", to: "/vaults" },
  { label: "Roles", to: "/roles" },
  { label: "Learn", to: "/learn" },
  { label: "Dashboard", to: "/dashboard" },
  { label: "404", to: "/404" },
];

/**
 * Shared footer (near-black #050505, all landing pages). The template's
 * contact form is replaced by two white solid buttons (X, Telegram) in the
 * same slot, plus the primary LAUNCH APP CTA.
 */
export default function Footer() {
  return (
    <footer id="community" className="grain bg-abyss text-white">
      <div className="relative z-[2] mx-auto max-w-[1440px] px-4 md:px-6 lg:px-12">
        {/* Upper two-column area */}
        <div className="grid gap-12 py-16 md:py-24 lg:grid-cols-2 lg:gap-16">
          {/* Left column */}
          <motion.div {...fadeUp(0)} className="flex flex-col gap-8">
            {/* Photo card */}
            <div className="relative overflow-hidden">
              <img src="/footer-card.jpg" alt="UseCert vault lounge" className="aspect-[3/2] w-full object-cover" />
              <img src="/logo.png" alt="" aria-hidden className="absolute left-4 top-4 h-9 w-9 object-contain" />
              <div className="absolute bottom-3 left-4 flex items-center gap-2.5">
                <span className="h-[8px] w-[8px] bg-green-bright" aria-hidden />
                <span className="font-mono text-[11px] uppercase tracking-[0.08em] text-white">Vault 01 · Open</span>
              </div>
            </div>
            {/* White quote card */}
            <div className="bg-white p-6 text-ink md:p-8">
              <p className="font-mono text-[11px] uppercase tracking-[0.08em] text-ink-60">Solvency, public</p>
              <p className="mt-3 text-[16px] leading-[1.55]">
                Every certificate is backed by exactly one token's worth of perp exposure plus collateral margin.
                Proven on-chain every attestation (~60s), with the age of the proof published.
              </p>
            </div>
            {/* Community */}
            <div>
              <p className="font-mono text-[11px] uppercase tracking-[0.08em] text-white-60">Community</p>
              <div className="mt-3 flex flex-col gap-1.5 font-mono text-[13px]">
                <a href="https://x.com/usecert" target="_blank" rel="noreferrer" className="text-white transition-colors hover:text-green-bright">
                  x.com/usecert
                </a>
                <a href="https://t.me/usecert" target="_blank" rel="noreferrer" className="text-white transition-colors hover:text-green-bright">
                  t.me/usecert
                </a>
                <a href="https://github.com/usecert" target="_blank" rel="noreferrer" className="text-white transition-colors hover:text-green-bright">
                  github.com/usecert
                </a>
              </div>
              <p className="mt-4 font-mono text-[11px] uppercase tracking-[0.08em] text-white-60">
                We usually respond to all community enquiries within 2 business hours.
              </p>
            </div>
            {/* Monogram + wordmark */}
            <div className="mt-auto flex items-center gap-2.5 pt-4">
              <img src="/logo.png" alt="UseCert monogram" className="h-8 w-8 object-contain" />
              <span className="text-[18px] font-semibold uppercase tracking-[-0.02em]">
                UseCert<sup className="text-[9px] align-super">®</sup>
              </span>
            </div>
          </motion.div>

          {/* Right column: CTA (replaces form block) */}
          <motion.div {...fadeUp(0.15)} className="flex flex-col justify-center">
            <h2 className="text-[44px] font-semibold uppercase leading-[0.85] tracking-[-0.05em] md:text-[60px] lg:text-[78px]">
              Start Holding.
            </h2>
            <p className="mt-6 max-w-[52ch] text-[16px] leading-[1.55] text-white-60">
              Whether you are here to hold, LP, stake, or arb the peg, the vault is open. No pitch decks, no gates,
              just a certificate in your wallet.
            </p>
            <div className="mt-10 grid gap-3 sm:grid-cols-2">
              <SwapButton label="Follow on X" href="https://x.com/usecert" variant="white" icon={<XIcon width={14} height={14} />} className="[&>span]:w-full" />
              <SwapButton label="Join Telegram" href="https://t.me/usecert" variant="white" icon={<TelegramIcon width={14} height={14} />} className="[&>span]:w-full" />
            </div>
            <SwapButton label="Launch App" to="/dashboard" variant="primary" fullWidth className="mt-3" />
            <p className="mt-6 font-mono text-[11px] leading-[1.5] uppercase tracking-[0.06em] text-white-60">
              Certificates are synthetic. No dividends, no shareholder rights. Not available where synthetic equity
              exposure is restricted. UseCert is infrastructure, not investment advice.
            </p>
          </motion.div>
        </div>

        {/* Link area */}
        <motion.div {...fadeUp(0.2)} className="grid gap-10 border-t hairline-dark py-12 md:grid-cols-2">
          <div>
            <p className="font-mono text-[11px] uppercase tracking-[0.08em] text-white-60">Navigation</p>
            <ul className="mt-4 flex flex-wrap gap-x-5 gap-y-2 text-[14px] uppercase">
              {NAV_LINKS.map((l) => (
                <li key={l.label}>
                  <Link to={l.to} className="text-white transition-colors hover:text-green-bright">
                    {l.label}
                  </Link>
                </li>
              ))}
            </ul>
          </div>
          <div className="md:text-right">
            <p className="font-mono text-[11px] uppercase tracking-[0.08em] text-white-60">Deployed on</p>
            <p className="mt-4 text-[14px] uppercase text-white">
              Robinhood Chain · 24/7 oracle-priced markets · Solvency proven every attestation, age published
            </p>
            <div className="mt-5 flex gap-4 md:justify-end">
              {SOCIALS.map(({ label, href, Icon }, i) => (
                <motion.a
                  key={label}
                  href={href}
                  target="_blank"
                  rel="noreferrer"
                  aria-label={label}
                  className="text-white/50 transition-colors hover:text-green-bright"
                  initial={{ opacity: 0, scale: 0.8 }}
                  whileInView={{ opacity: 1, scale: 1 }}
                  viewport={{ once: true }}
                  transition={{ delay: 0.3 + i * 0.06, duration: 0.3 }}
                >
                  <Icon width={24} height={24} />
                </motion.a>
              ))}
            </div>
          </div>
        </motion.div>

        {/* Legal bar */}
        <motion.div
          {...fadeUp(0.3)}
          className="flex flex-col items-center justify-between gap-3 border-t hairline-dark py-6 font-mono text-[10px] uppercase tracking-[0.08em] text-white-60 md:flex-row"
        >
          <div className="flex gap-4">
            <Link to="/legal/privacy-policy" className="transition-colors hover:text-white">
              Privacy Policy
            </Link>
            <span aria-hidden>/</span>
            <Link to="/legal/terms-of-service" className="transition-colors hover:text-white">
              Terms of Service
            </Link>
          </div>
          <p>© 2026 UseCert®. All rights reserved.</p>
          <p>Built on Robinhood Chain</p>
        </motion.div>
      </div>
    </footer>
  );
}
