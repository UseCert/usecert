import { createFileRoute } from "@tanstack/react-router";
import Layout from "@/components/Layout";
import RoadmapPage from "@/pages/Roadmap";

export const Route = createFileRoute("/roadmap")({
  head: () => ({
    meta: [
      { title: "Milestones - What Works, and What Does Not Yet | UseCert" },
      {
        name: "description",
        content:
          "What is live on UseCert on Robinhood Chain mainnet today, what is being built, and what is still open.",
      },
      { property: "og:title", content: "UseCert Milestones" },
      {
        property: "og:description",
        content:
          "Delivery status without dates. Every shipped item is checkable on chain.",
      },
    ],
  }),
  component: () => (
    <Layout>
      <RoadmapPage />
    </Layout>
  ),
});
