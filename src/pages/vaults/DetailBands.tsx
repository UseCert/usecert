import { Link } from "@/lib/router-compat";
import { motion } from "framer-motion";
import { ArrowUpRight } from "lucide-react";
import Counter from "@/components/Counter";
import LetterReveal from "@/components/LetterReveal";
import SwapButton from "@/components/SwapButton";
import { EASE } from "./DetailSections";
import type { VaultData } from "./data";
import { useReveal } from "@/i18n";

/** Section 5: "THE RESULTS" full-bleed deep band: two giant stat callouts + copy. */
export function Results({ vault }: { vault: VaultData }) {
  return (
    <section className="grain section-glow relative bg-section-deep text-white">
      <div className="relative z-[2] mx-auto max-w-[1440px] px-4 py-16 md:px-6 md:py-24 lg:px-12 lg:py-32">
        <p className="font-mono text-[11px] uppercase tracking-[0.08em] text-white-60">The results</p>

        <div className="mt-12 grid gap-14 lg:grid-cols-2 lg:gap-20">
          {vault.stats.map((s, i) => (
            <motion.div
              key={s.caption}
              className="flex gap-4"
              initial={{ opacity: 0, y: 24 }}
              whileInView={{ opacity: 1, y: 0 }}
              viewport={{ once: true, amount: 0.4 }}
              transition={{ delay: i * 0.2, duration: 0.7, ease: EASE }}
            >
              <motion.span
                className="mt-3 h-2 w-2 shrink-0 rounded-full bg-green-bright"
                initial={{ scale: 0 }}
                whileInView={{ scale: [0, 1.4, 1] }}
                viewport={{ once: true }}
                transition={{ delay: i * 0.2 + 0.2, duration: 0.5 }}
                aria-hidden
              />
              <div>
                <Counter
                  end={s.value}
                  prefix={s.prefix ?? ""}
                  suffix={s.suffix ?? ""}
                  decimals={s.decimals ?? 0}
                  className="block text-[44px] font-semibold leading-[0.9] tracking-[-0.07em] text-green-bright md:text-[60px] lg:text-[78px]"
                />
                <p className="mt-3 max-w-[40ch] text-[13px] leading-[1.5] text-white-60">{s.caption}</p>
              </div>
            </motion.div>
          ))}
        </div>

        <motion.p
          className="mt-14 max-w-[52ch] text-[15px] leading-[1.55] text-white-60 md:text-[16px]"
          initial={{ opacity: 0 }}
          whileInView={{ opacity: 1 }}
          viewport={{ once: true, amount: 0.4 }}
          transition={{ delay: 0.4, duration: 0.8, ease: EASE }}
        >
          {vault.resultsCopy}
        </motion.p>
      </div>
    </section>
  );
}

/** Section 7: "HOLDER WORDS." testimonial block (replaces "Client words."). */
export function HolderWords({ vault }: { vault: VaultData }) {
  const R = useReveal();
  const words = R(vault.quote.text);

  return (
    <section className="grain bg-ink text-white">
      <div className="relative z-[2] mx-auto max-w-[1440px] border-t hairline-dark px-4 py-16 md:px-6 md:py-24 lg:px-12 lg:py-32">
        <h2 className="text-[44px] font-semibold uppercase leading-[0.85] tracking-[-0.05em] md:text-[60px] lg:text-[78px]">
          <LetterReveal text="Holder words." byWord stagger={0.05} />
        </h2>

        <div className="relative mt-14">
          {/* Giant quote glyph */}
          <span
            className="pointer-events-none absolute -top-16 left-0 select-none text-[220px] font-semibold leading-none text-white/10"
            aria-hidden
          >
            &quot;
          </span>

          <div className="relative grid items-center gap-10 lg:grid-cols-[1fr_360px] lg:gap-20">
            <motion.blockquote
              className="text-[22px] font-medium leading-[1.2] tracking-[-0.02em] text-white md:text-[28px]"
              initial="hidden"
              whileInView="show"
              viewport={{ once: true, amount: 0.3 }}
              variants={{ hidden: {}, show: { transition: { staggerChildren: 0.02 } } }}
            >
              {words.map((w, i) => (
                <motion.span
                  key={`${w}-${i}`}
                  className="inline-block whitespace-pre"
                  variants={{ hidden: { opacity: 0, y: 8 }, show: { opacity: 1, y: 0, transition: { duration: 0.3 } } }}
                >
                  {w}
                  {i < words.length - 1 ? R.sep : ""}
                </motion.span>
              ))}
              <footer className="mt-6 flex items-center gap-3">
                <span className="h-[8px] w-[8px] bg-green-bright" aria-hidden />
                <p className="font-mono text-[12px] uppercase tracking-[0.08em] text-white-60">{vault.quote.role}</p>
              </footer>
            </motion.blockquote>

            <motion.div
              initial="hidden"
              whileInView="show"
              viewport={{ once: true, amount: 0.3 }}
            >
              <motion.div
                className="overflow-hidden"
                variants={{
                  hidden: { clipPath: "inset(100% 0% 0% 0%)" },
                  show: { clipPath: "inset(0% 0% 0% 0%)", transition: { duration: 0.9, ease: EASE } },
                }}
              >
                <img
                  src={vault.quote.image}
                  alt={vault.quote.name}
                  className="aspect-[4/5] w-full max-w-[360px] object-cover"
                />
              </motion.div>
            </motion.div>
          </div>
        </div>
      </div>
    </section>
  );
}

/** Section 8: "NEXT VAULT" full-width card linking to the next vault in sequence. */
export function NextVault({ next }: { next: VaultData }) {
  return (
    <section className="bg-ink text-white">
      <div className="mx-auto max-w-[1440px] px-4 pb-16 md:px-6 md:pb-24 lg:px-12 lg:pb-32">
        <motion.div
          initial={{ opacity: 0, y: 24 }}
          whileInView={{ opacity: 1, y: 0 }}
          viewport={{ once: true, amount: 0.3 }}
          transition={{ duration: 0.7, ease: EASE }}
        >
          <Link
            to={`/vaults/${next.slug}`}
            className="group grid items-center gap-8 border hairline-dark p-6 transition-colors hover:border-white/40 md:grid-cols-[1fr_auto] md:p-10 lg:p-14"
            aria-label={`Next vault: ${next.name}`}
          >
            <div>
              <p className="font-mono text-[11px] uppercase tracking-[0.08em] text-white-60">Next vault</p>
              <p className="mt-6 text-[44px] font-semibold uppercase leading-[0.85] tracking-[-0.05em] text-white transition-colors duration-300 group-hover:text-green-bright md:text-[60px] lg:text-[78px]">
                {next.name}
              </p>
              <div className="mt-6 flex flex-wrap items-center gap-x-6 gap-y-2">
                <span className="font-mono text-[11px] uppercase tracking-[0.08em] text-white-60">{next.tags}</span>
                <span className="font-mono text-[13px] text-white-60">{next.year}</span>
              </div>
            </div>
            <div className="w-full max-w-[320px] overflow-hidden justify-self-start md:justify-self-end">
              <img
                src={next.image}
                alt={`${next.name} certificate plate`}
                className="aspect-[16/10] w-full object-cover transition-transform duration-500 group-hover:scale-[1.03]"
              />
            </div>
          </Link>
        </motion.div>
      </div>
    </section>
  );
}

/** Section 9: slim CTA band above the footer. */
export function CtaBand({ vault }: { vault: VaultData }) {
  const live = vault.status === "LIVE";

  return (
    <section className="grain section-glow relative bg-section-deep text-white">
      <div className="relative z-[2] mx-auto flex max-w-[1440px] flex-wrap items-center justify-between gap-8 px-4 py-14 md:px-6 md:py-20 lg:px-12">
        <h2 className="text-[40px] font-semibold uppercase leading-[0.85] tracking-[-0.05em] md:text-[56px] lg:text-[68px]">
          <LetterReveal text={`Mint ${vault.name}.`} byWord stagger={0.05} />
        </h2>
        <div className="flex flex-col items-start gap-3">
          {live ? (
            <SwapButton
              label="Open dashboard"
              to="/dashboard"
              variant="primary"
              icon={<ArrowUpRight size={14} />}
            />
          ) : (
            <>
              <SwapButton label={`Mint ${vault.name}`} variant="primary" disabled title="Deploys in phase C2" />
              <a
                href="https://t.me/usecertonchain"
                target="_blank"
                rel="noreferrer"
                className="group inline-flex items-center gap-2 text-[13px] font-semibold uppercase tracking-[0.08em] text-white transition-colors hover:text-green-bright"
              >
                Join the waitlist on Telegram
                <ArrowUpRight size={16} className="transition-transform group-hover:translate-x-0.5 group-hover:-translate-y-0.5" />
              </a>
            </>
          )}
        </div>
      </div>
    </section>
  );
}
