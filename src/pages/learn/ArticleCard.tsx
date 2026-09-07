import { Link } from "react-router";
import { ArrowUpRight } from "lucide-react";
import type { Article } from "./data";

/**
 * Template blog card anatomy: thumb (16:10, metallic grade), title with
 * underline-sweep hover, author + role, category / date. The minimal
 * variant swaps the thumb for a small circular image + arrow glyph.
 */
export default function ArticleCard({ article }: { article: Article }) {
  return (
    <Link to={`/learn/${article.slug}`} className="group block h-full">
      {article.minimal ? (
        <div className="flex aspect-[16/10] items-center justify-center gap-4 border hairline-light bg-white p-6">
          <img
            src={article.image}
            alt=""
            className="h-20 w-20 rounded-full object-cover md:h-24 md:w-24"
          />
          <ArrowUpRight
            size={28}
            className="text-ink transition-transform duration-300 group-hover:translate-x-1 group-hover:-translate-y-1"
          />
        </div>
      ) : (
        <div className="relative aspect-[16/10] overflow-hidden border hairline-light">
          <img
            src={article.image}
            alt={article.title}
            className="h-full w-full object-cover transition-transform duration-500 group-hover:scale-105"
          />
          <span
            className="pointer-events-none absolute inset-0 bg-green-deep/0 transition-colors duration-500 group-hover:bg-green-deep/20"
            aria-hidden
          />
          <ArrowUpRight
            size={22}
            className="absolute right-4 top-4 text-white opacity-0 transition-all duration-300 group-hover:translate-x-1 group-hover:-translate-y-1 group-hover:opacity-100"
            aria-hidden
          />
        </div>
      )}
      <h3 className="relative mt-4 inline text-[20px] font-semibold leading-[1.2] tracking-[-0.02em] text-ink md:text-[22px]">
        {article.title}
        <span
          className="absolute bottom-0 left-0 h-px w-0 bg-green-deep transition-all duration-300 group-hover:w-full"
          aria-hidden
        />
      </h3>
      <p className="mt-3 text-[14px] leading-[1.4] text-ink-60">
        {article.author}, {article.role}
      </p>
      <p className="mt-1.5 font-mono text-[11px] uppercase tracking-[0.08em] text-ink-60">
        {article.category} / {article.date}
      </p>
    </Link>
  );
}
