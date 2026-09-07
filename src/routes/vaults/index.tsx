import { createFileRoute } from "@tanstack/react-router";
import Layout from "@/components/Layout";
import Vaults from "@/pages/Vaults";

export const Route = createFileRoute("/vaults/")({
  head: () => ({
    meta: [
      { title: "Vaults - Perp-Backed Certificate Strategies | UseCert" },
      {
        name: "description",
        content:
          "Browse UseCert vaults: uTSLA, uNVDA, uSPX, uQQQ and uAAPL certificates, each backed by on-chain perp positions and USDC margin.",
      },
      { property: "og:title", content: "UseCert Vaults" },
      {
        property: "og:description",
        content: "uTSLA, uNVDA, uSPX, uQQQ and uAAPL - perp-backed certificate strategies.",
      },
    ],
  }),
  component: () => (
    <Layout>
      <Vaults />
    </Layout>
  ),
});
