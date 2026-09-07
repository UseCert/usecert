import { createFileRoute } from "@tanstack/react-router";
import Layout from "@/components/Layout";
import Article from "@/pages/Article";

export const Route = createFileRoute("/learn/$slug")({
  head: () => ({
    meta: [
      { title: "Article - UseCert Research" },
      {
        name: "description",
        content:
          "A UseCert research article on synthetic equity certificates, perp funding and on-chain market design.",
      },
      { property: "og:title", content: "UseCert Research Article" },
      {
        property: "og:description",
        content: "Long-form notes from the UseCert team on certificates and perp markets.",
      },
    ],
  }),
  component: () => (
    <Layout>
      <Article />
    </Layout>
  ),
});
