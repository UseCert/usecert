import { createFileRoute } from "@tanstack/react-router";
import Layout from "@/components/Layout";
import Roles from "@/pages/Roles";

export const Route = createFileRoute("/roles")({
  head: () => ({
    meta: [
      { title: "Roles — Holders, Stakers, Arbitrageurs and Builders | UseCert" },
      {
        name: "description",
        content:
          "Four ways to participate in UseCert: hold certificates, stake for yield, arbitrage the peg, or build on the vault infrastructure.",
      },
      { property: "og:title", content: "Roles in the UseCert Protocol" },
      {
        property: "og:description",
        content: "Hold, stake, arbitrage or build — the four roles that keep UseCert vaults balanced.",
      },
    ],
  }),
  component: () => (
    <Layout>
      <Roles />
    </Layout>
  ),
});
