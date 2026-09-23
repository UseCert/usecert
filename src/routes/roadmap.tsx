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
          "What is live on UseCert today, what is being built, and what has to be true before mainnet. Testnet only: the collateral is a test token and the perp venue is simulated.",
      },
      { property: "og:title", content: "UseCert Milestones" },
      {
        property: "og:description",
        content:
          "Delivery status without dates. Every shipped item is checkable against chain 46630.",
      },
    ],
  }),
  component: () => (
    <Layout>
      <RoadmapPage />
    </Layout>
  ),
});
