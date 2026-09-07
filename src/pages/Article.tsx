import { useState } from "react";
import type { FormEvent } from "react";
import { Link, Navigate, useParams } from "react-router";
import { motion } from "framer-motion";
import { Check, Loader2 } from "lucide-react";
import LetterReveal from "@/components/LetterReveal";
import SwapButton from "@/components/SwapButton";
import { ARTICLES, getArticle } from "./learn/data";
import ArticleGrid from "./learn/ArticleGrid";

const EASE = [0.16, 1, 0.3, 1] as [number, number, number, number];

/** §3 Newsletter block: heading + copy + underlined email input + black pill SUBSCRIBE. */
function SubscribeBlock() {
  const [email, setEmail] = useState("");
  const [error, setError] = useState("");
  const [state, setState] = useState<"idle" | "loading" | "success">("idle");

  const onSubmit = (e: FormEvent) => {
    e.preventDefault();
    if (state === "loading") return;
    const value = email.trim();
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value)) {
      setError("Please enter a valid email address.");
      return;
    }
    setError("");
    setState("loading");
    window.setTimeout(() => {
      setState("success");
      setEmail("");
    }, 1000);
  };

  return (
    <section className="bg-paper text-ink">
      <div className="mx-auto max-w-[720px] px-4 pb-16 md:px-6 md:pb-24">
        <motion.div
          className="border hairline-light bg-white p-8 md:p-12"
          initial={{ opacity: 0, y: 24 }}
          whileInView={{ opacity: 1, y: 0 }}
          viewport={{ once: true, amount: 0.3 }}
          transition={{ duration: 0.6, ease: EASE }}
        >
          <h3 className="text-[28px] font-semibold uppercase leading-none tracking-[-0.03em] md:text-[32px]">
            The vault report.
          </h3>
          <p className="mt-4 text-[15px] leading-[1.55] text-ink-60">
            Short notes on certificates, funding, and the RWA market every Tuesday.
          </p>
          {state === "success" ? (
            <p className="mt-8 flex items-center gap-3 border-t hairline-light pt-6 text-[14px] font-medium text-green-deep">
              <Check size={18} aria-hidden />
              Subscribed. See you Tuesday.
            </p>
          ) : (
            <form onSubmit={onSubmit} noValidate className="mt-8">
              <div className="flex flex-col gap-4 sm:flex-row sm:items-end">
                <input
                  type="email"
                  value={email}
                  onChange={(e) => {
                    setEmail(e.target.value);
                    if (error) setError("");
                  }}
                  placeholder="example@email.com"
                  aria-label="Email address"
                  className="w-full flex-1 border-0 border-b hairline-light bg-transparent py-3 text-[15px] text-ink outline-none transition-colors placeholder:text-ink-60/60 focus:border-ink"
                />
                <button
                  type="submit"
                  disabled={state === "loading"}
                  className="group relative inline-block select-none self-start bg-ink text-white transition-transform active:scale-[0.98] disabled:opacity-70 sm:self-auto"
                >
                  <span className="relative block overflow-hidden">
                    <span className="flex items-center justify-center gap-2 px-8 py-[14px] text-[12px] font-semibold uppercase tracking-[0.08em] transition-transform duration-250 ease-out group-hover:-translate-y-full">
                      {state === "loading" ? <Loader2 size={14} className="animate-spin" aria-hidden /> : null}
                      Subscribe
                    </span>
                    <span
                      aria-hidden
                      className="absolute inset-0 flex translate-y-full items-center justify-center gap-2 bg-green-deep px-8 py-[14px] text-[12px] font-semibold uppercase tracking-[0.08em] text-white transition-transform duration-250 ease-out group-hover:translate-y-0"
                    >
                      Subscribe
                    </span>
                  </span>
                </button>
              </div>
              {error ? <p className="mt-3 font-mono text-[11px] uppercase tracking-[0.08em] text-[#8a3b2e]">{error}</p> : null}
            </form>
          )}
        </motion.div>
      </div>
    </section>
  );
}

/**
 * ARTICLE (/learn/:slug): research article template, 1:1 replica of the
 * template blog post. Title + subtitle, byline, long-form body, pull-quote,
 * newsletter block, all-articles grid. Footer via Layout.
 */
export default function Article() {
  const { slug } = useParams();
  const article = getArticle(slug);

  if (!article) {
    return <Navigate to="/404" replace />;
  }

  return (
    <>
      {/* §1 ARTICLE HERO (light grey paper) */}
      <section className="bg-paper text-ink">
        <div className="mx-auto max-w-[1200px] px-4 pt-16 md:px-6 md:pt-24 lg:px-12 lg:pt-28">
          <p className="font-mono text-[11px] uppercase tracking-[0.08em] text-ink-60">
            <Link to="/learn" className="transition-colors hover:text-ink">
              Research
            </Link>{" "}
            / {article.category} / {article.date}
          </p>
          <h1 className="mt-6 max-w-[20ch] text-[32px] font-semibold uppercase leading-[0.95] tracking-[-0.04em] md:text-[44px] lg:text-[52px]">
            <LetterReveal text={article.title} byWord stagger={0.04} immediate />
          </h1>
          <motion.p
            className="mt-8 max-w-[34ch] text-[26px] font-medium leading-[1.05] tracking-[-0.03em] text-ink-60 md:text-[32px]"
            initial={{ opacity: 0, y: 16 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ delay: 0.35, duration: 0.6, ease: EASE }}
          >
            {article.subtitle}
          </motion.p>

          {/* Byline row */}
          <motion.div
            className="mt-10 flex items-center justify-between gap-6 border-t hairline-light pt-6"
            initial={{ opacity: 0, y: 12 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ delay: 0.55, duration: 0.5, ease: EASE }}
          >
            <div className="flex items-center gap-3">
              <img
                src="/logo.png"
                alt=""
                className="h-8 w-8 object-contain"
              />
              <p className="text-[14px] leading-[1.3]">
                <span className="font-semibold">{article.author}</span>
                <span className="text-ink-60">
                  , {article.role}
                </span>
              </p>
            </div>
            <p className="font-mono text-[11px] uppercase tracking-[0.08em] text-ink-60">
              {article.readTime}
            </p>
          </motion.div>

          {/* Hero thumb: full-width 16:10, hairline border, clip reveal */}
          <motion.div
            className="mt-10 overflow-hidden border hairline-light"
            initial={{ clipPath: "inset(0 0 100% 0)" }}
            animate={{ clipPath: "inset(0 0 0% 0)" }}
            transition={{ delay: 0.65, duration: 1, ease: EASE }}
          >
            <img
              src={article.image}
              alt={article.title}
              className="aspect-[16/10] w-full object-cover"
            />
          </motion.div>
        </div>
      </section>

      {/* §2 BODY (max 720px centered, Inter 18px/1.7) */}
      <section className="bg-paper text-ink">
        <div className="mx-auto max-w-[720px] px-4 py-16 md:px-6 md:py-24">
          {article.intro.map((p, i) => (
            <motion.p
              key={`intro-${i}`}
              className="font-[Inter,sans-serif] text-[17px] leading-[1.7] text-ink md:text-[18px] [&:not(:first-child)]:mt-6"
              initial={{ opacity: 0, y: 16 }}
              whileInView={{ opacity: 1, y: 0 }}
              viewport={{ once: true, amount: 0.2 }}
              transition={{ delay: i * 0.05, duration: 0.6, ease: EASE }}
            >
              {p}
            </motion.p>
          ))}

          {article.sections.map((section, si) => (
            <div key={section.heading} className="mt-14">
              <motion.h2
                className="text-[26px] font-semibold uppercase leading-[1] tracking-[-0.03em] md:text-[28px]"
                initial={{ opacity: 0, y: 16 }}
                whileInView={{ opacity: 1, y: 0 }}
                viewport={{ once: true, amount: 0.4 }}
                transition={{ duration: 0.6, ease: EASE }}
              >
                {section.heading}
              </motion.h2>
              {section.paragraphs.map((p, pi) => (
                <motion.p
                  key={`${si}-${pi}`}
                  className="mt-6 font-[Inter,sans-serif] text-[17px] leading-[1.7] text-ink md:text-[18px]"
                  initial={{ opacity: 0, y: 16 }}
                  whileInView={{ opacity: 1, y: 0 }}
                  viewport={{ once: true, amount: 0.2 }}
                  transition={{ delay: 0.05 + pi * 0.05, duration: 0.6, ease: EASE }}
                >
                  {p}
                </motion.p>
              ))}
              {/* Pull-quote after the third section (template rhythm) */}
              {si === 2 && (
                <motion.blockquote
                  className="relative my-16 px-6 text-center md:px-12"
                  initial={{ opacity: 0, scale: 0.98 }}
                  whileInView={{ opacity: 1, scale: 1 }}
                  viewport={{ once: true, amount: 0.4 }}
                  transition={{ duration: 0.7, ease: EASE }}
                >
                  <span
                    aria-hidden
                    className="pointer-events-none absolute -top-16 left-1/2 -translate-x-1/2 select-none text-[180px] font-semibold leading-none text-silver/50"
                  >
                    &ldquo;
                  </span>
                  <p className="relative text-[24px] font-semibold leading-[1.2] tracking-[-0.02em] md:text-[28px]">
                    {article.quote}
                  </p>
                </motion.blockquote>
              )}
            </div>
          ))}
        </div>
      </section>

      {/* §3 NEWSLETTER */}
      <SubscribeBlock />

      {/* §4 ALL ARTICLES */}
      <section className="border-t hairline-light bg-paper text-ink">
        <div className="mx-auto max-w-[1440px] px-4 py-16 md:px-6 md:py-24 lg:px-12 lg:py-32">
          <div className="flex flex-wrap items-end justify-between gap-8">
            <h2 className="text-[44px] font-semibold uppercase leading-[0.85] tracking-[-0.05em] md:text-[60px] lg:text-[78px]">
              <LetterReveal text="Latest research." byWord stagger={0.05} />
            </h2>
            <SwapButton label="See More" to="/learn" variant="black" />
          </div>
          <div className="mt-14">
            <ArticleGrid articles={ARTICLES} animated={false} />
          </div>
        </div>
      </section>
    </>
  );
}
