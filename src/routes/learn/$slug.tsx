import { createFileRoute, notFound } from "@tanstack/react-router";
import { getArticle } from "@/pages/learn/data";
import Layout from "@/components/Layout";
import Article from "@/pages/Article";

export const Route = createFileRoute("/learn/$slug")({
  loader: ({ params }) => {
    if (!getArticle(params.slug)) throw notFound();
  },
  // Every article carried the same title and description; each now has its own.
  head: ({ params }) => {
    const a = getArticle(params.slug);
    const title = a ? `${a.title} | UseCert Research` : "Article not found | UseCert";
    const description = a?.subtitle ?? "This article does not exist.";
    return {
      meta: [
        { title },
        { name: "description", content: description },
        { property: "og:title", content: a?.title ?? title },
        { property: "og:description", content: description },
        { property: "og:type", content: "article" },
      ],
    };
  },
  component: () => (
    <Layout>
      <Article />
    </Layout>
  ),
});
