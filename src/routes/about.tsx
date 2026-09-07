import { createFileRoute } from "@tanstack/react-router";
import Layout from "@/components/Layout";
import About from "@/pages/About";

export const Route = createFileRoute("/about")({
  head: () => ({
    meta: [
      { title: "About UseCert - The Team Behind On-Chain Certificates" },
      {
        name: "description",
        content:
          "Why UseCert exists: the story, the numbers and the people building perp-backed certificates for on-chain equity exposure.",
      },
      { property: "og:title", content: "About UseCert" },
      {
        property: "og:description",
        content: "The story and the numbers behind UseCert's perp-backed certificates.",
      },
    ],
  }),
  component: () => (
    <Layout>
      <About />
    </Layout>
  ),
});
