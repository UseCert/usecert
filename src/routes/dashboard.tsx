import { createFileRoute } from "@tanstack/react-router";
import Dashboard from "@/pages/Dashboard";

export const Route = createFileRoute("/dashboard")({
  head: () => ({
    meta: [
      { title: "Dashboard - Mint and Redeem Certificates, Solvency Live | UseCert" },
      {
        name: "description",
        content:
          "The UseCert app dashboard: track positions, mint or redeem certificates, stake for yield and monitor keeper activity.",
      },
      { property: "og:title", content: "UseCert Dashboard" },
      {
        property: "og:description",
        content: "Mint and redeem certificates, track your receipts, and read solvency live from the contracts.",
      },
    ],
  }),
  component: Dashboard,
});
