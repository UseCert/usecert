import { createFileRoute } from "@tanstack/react-router";
import Layout from "@/components/Layout";
import VaultDetail from "@/pages/VaultDetail";

export const Route = createFileRoute("/vaults/$slug")({
  head: () => ({
    meta: [
      { title: "Vault Detail — Certificate Strategy Breakdown | UseCert" },
      {
        name: "description",
        content:
          "Full breakdown of a UseCert vault: the problem it solves, how the perp-backed position is run, results and how to mint or redeem.",
      },
      { property: "og:title", content: "UseCert Vault Detail" },
      {
        property: "og:description",
        content: "Strategy, results and mechanics behind a single UseCert certificate vault.",
      },
    ],
  }),
  component: () => (
    <Layout>
      <VaultDetail />
    </Layout>
  ),
});
