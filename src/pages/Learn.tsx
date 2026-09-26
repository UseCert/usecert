import { useState } from "react";
import { motion } from "framer-motion";
import LetterReveal from "@/components/LetterReveal";
import { cn } from "@/lib/utils";
import Faq from "./home/Faq";
import { ARTICLES, CATEGORIES } from "./learn/data";
import type { ArticleCategory } from "./learn/data";
import ArticleGrid from "./learn/ArticleGrid";

const EASE = [0.16, 1, 0.3, 1] as [number, number, number, number];

type Filter = "ALL" | ArticleCategory;

/**
 * LEARN (/learn): research index, 1:1 replica of the template /blog.
 * Header + filter tabs + article cards + shared FAQ. Footer via Layout.
 */
export default function Learn() {
  const [filter, setFilter] = useState<Filter>("ALL");
  const articles = filter === "ALL" ? ARTICLES : ARTICLES.filter((a) => a.category === filter);

  return (
    <>
      {/* §1 HEADER (light grey paper) */}
      <section className="bg-paper text-ink">
        <div className="mx-auto max-w-[1440px] px-4 pt-16 md:px-6 md:pt-24 lg:px-12 lg:pt-32">
          <div className="flex items-start justify-between gap-6">
            <p className="font-mono text-[11px] uppercase tracking-[0.08em] text-ink-60">Research</p>
            <p className="font-mono text-[11px] uppercase tracking-[0.08em] text-ink-60">2026©</p>
          </div>
          <h1 className="mt-6 max-w-[14ch] text-[44px] font-semibold uppercase leading-[0.85] tracking-[-0.05em] md:text-[60px] lg:text-[78px]">
            <LetterReveal text="Latest research." byWord stagger={0.05} immediate />
          </h1>
          <motion.p
            className="mt-8 max-w-[52ch] text-[16px] leading-[1.55] text-ink-60"
            initial={{ opacity: 0, y: 16 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ delay: 0.3, duration: 0.6, ease: EASE }}
          >
            We write about what we have learned building holdable stock certificates on Robinhood
            Chain.
          </motion.p>

          {/* Filter tabs */}
          <div className="mt-12 flex flex-wrap items-center gap-2">
            {CATEGORIES.map((cat, i) => (
              <motion.button
                key={cat}
                type="button"
                onClick={() => setFilter(cat)}
                initial={{ opacity: 0, x: -12 }}
                animate={{ opacity: 1, x: 0 }}
                transition={{ delay: 0.4 + i * 0.05, duration: 0.4, ease: EASE }}
                className={cn(
                  "px-5 py-2.5 text-[12px] font-semibold uppercase tracking-[0.08em] transition-colors duration-300",
                  filter === cat
                    ? "bg-ink text-white"
                    : "border hairline-light bg-transparent text-ink-60 hover:text-ink",
                )}
              >
                {cat}
              </motion.button>
            ))}
          </div>
        </div>

        {/* §2 ARTICLE CARDS */}
        <div className="mx-auto max-w-[1440px] px-4 pb-16 pt-14 md:px-6 md:pb-24 md:pt-16 lg:px-12 lg:pb-32">
          <ArticleGrid articles={articles} />
        </div>
      </section>

      {/* §3 SHARED FAQ */}
      <Faq />
    </>
  );
}
