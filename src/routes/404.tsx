import { createFileRoute } from "@tanstack/react-router";
import Layout from "@/components/Layout";
import NotFound from "@/pages/NotFound";

export const Route = createFileRoute("/404")({
  head: () => ({
    meta: [
      { title: "Page Not Found | UseCert" },
      { name: "description", content: "This UseCert page doesn't exist. Head back to the vaults." },
      { property: "og:title", content: "Page Not Found | UseCert" },
      { property: "og:description", content: "This UseCert page doesn't exist." },
    ],
  }),
  component: () => (
    <Layout>
      <NotFound />
    </Layout>
  ),
});
