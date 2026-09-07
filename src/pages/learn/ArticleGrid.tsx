import { AnimatePresence, motion } from "framer-motion";
import type { Article } from "./data";
import ArticleCard from "./ArticleCard";

const EASE = [0.16, 1, 0.3, 1] as [number, number, number, number];

interface ArticleGridProps {
  articles: Article[];
  /** animate cards in with 24px rise, 0.08s stagger (on mount / filter change) */
  animated?: boolean;
}

/** Article cards grid (shared by /learn index and the article page "All articles"). */
export default function ArticleGrid({ articles, animated = true }: ArticleGridProps) {
  return (
    <div className="grid gap-x-6 gap-y-12 md:grid-cols-2 lg:gap-x-8">
      <AnimatePresence mode="popLayout">
        {articles.map((article, i) =>
          animated ? (
            <motion.div
              key={article.slug}
              layout
              initial={{ opacity: 0, y: 24 }}
              animate={{ opacity: 1, y: 0 }}
              exit={{ opacity: 0, y: 12 }}
              transition={{ delay: i * 0.08, duration: 0.5, ease: EASE, layout: { duration: 0.4, ease: EASE } }}
            >
              <ArticleCard article={article} />
            </motion.div>
          ) : (
            <motion.div
              key={article.slug}
              initial={{ opacity: 0, y: 24 }}
              whileInView={{ opacity: 1, y: 0 }}
              viewport={{ once: true, amount: 0.2 }}
              transition={{ delay: i * 0.08, duration: 0.6, ease: EASE }}
            >
              <ArticleCard article={article} />
            </motion.div>
          ),
        )}
      </AnimatePresence>
    </div>
  );
}
