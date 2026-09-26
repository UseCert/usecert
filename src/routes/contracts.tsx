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
          "Every UseCert contract on Robinhood Chain testnet, with a link to its verified source on the explorer. Testnet only: the collateral is a test token and the perp venue is simulated.",
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
