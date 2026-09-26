import { createFileRoute } from "@tanstack/react-router";
import Layout from "@/components/Layout";
import ContractsPage from "@/pages/Contracts";

export const Route = createFileRoute("/contracts")({
  head: () => ({
    meta: [
      { title: "Contract Addresses - Verify Every One | UseCert" },
      {
        name: "description",
        content:
          "Every UseCert contract on Robinhood Chain mainnet, with a link to each on the explorer and its verified source on Sourcify.",
      },
      { property: "og:title", content: "UseCert Contract Addresses" },
      {
        property: "og:description",
        content:
          "All 26 contracts, each linking to its source on the explorer. Taken from the same module the app transacts against.",
      },
    ],
  }),
  component: () => (
    <Layout>
      <ContractsPage />
    </Layout>
  ),
});
