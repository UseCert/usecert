import { createFileRoute } from "@tanstack/react-router";
import Layout from "@/components/Layout";
import Learn from "@/pages/Learn";

export const Route = createFileRoute("/learn/")({
  head: () => ({
    meta: [
      { title: "Research - Notes on Synthetic Equity and Perp Markets | UseCert" },
      {
        name: "description",
        content:
          "Long-form research from the UseCert team on synthetic equity exposure, funding rates, peg mechanics and on-chain market structure.",
      },
      { property: "og:title", content: "UseCert Research" },
      {
        property: "og:description",
        content: "Articles on synthetic equity, funding rates and on-chain market structure.",
      },
    ],
  }),
  component: () => (
    <Layout>
      <Learn />
    </Layout>
  ),
});
