import { createFileRoute } from "@tanstack/react-router";
import Layout from "@/components/Layout";
import Home from "@/pages/Home";

export const Route = createFileRoute("/")({
  head: () => ({
    meta: [
      { title: "UseCert - Tokenized Certificates for On-Chain Equity Exposure" },
      {
        name: "description",
        content:
          "UseCert turns perp-backed vaults into tokenized certificates: mint, hold and redeem synthetic equity exposure fully on chain.",
      },
      { property: "og:title", content: "UseCert - On-Chain Equity Certificates" },
      {
        property: "og:description",
        content:
          "Mint, hold and redeem perp-backed certificates tracking TSLA, NVDA, SPX, QQQ and AAPL exposure on chain.",
      },
    ],
  }),
  component: () => (
    <Layout>
      <Home />
    </Layout>
  ),
});
