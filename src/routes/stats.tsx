import { createFileRoute } from "@tanstack/react-router";
import Layout from "@/components/Layout";
import StatsPage from "@/pages/Stats";

export const Route = createFileRoute("/stats")({
  head: () => ({
    meta: [
      { title: "Public Stats - Feed, Venue and the Weekend Gap | UseCert" },
      {
        name: "description",
        content:
          "The basis between each Chainlink feed and the Lighter venue mark, past funding from the vault's side, and how far the venue moved while the feed was frozen. Sampled every 5 minutes, downloadable as CSV.",
      },
      { property: "og:title", content: "UseCert Public Stats" },
      {
        property: "og:description",
        content:
          "Basis, funding and weekend gaps for every UseCert certificate, recorded every 5 minutes. Past observations, not forecasts; venue figures are third-party data.",
      },
    ],
  }),
  component: () => (
    <Layout>
      <StatsPage />
    </Layout>
  ),
});
