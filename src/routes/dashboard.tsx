import { createFileRoute } from "@tanstack/react-router";
import Dashboard from "@/pages/Dashboard";

export const Route = createFileRoute("/dashboard")({
  head: () => ({
    meta: [
      { title: "Dashboard — Mint, Redeem and Stake Certificates | UseCert" },
      {
        name: "description",
        content:
          "The UseCert app dashboard: track positions, mint or redeem certificates, stake for yield and monitor keeper activity.",
      },
      { property: "og:title", content: "UseCert Dashboard" },
      {
        property: "og:description",
        content: "Track positions, mint or redeem certificates and stake for yield.",
      },
    ],
  }),
  component: Dashboard,
});
