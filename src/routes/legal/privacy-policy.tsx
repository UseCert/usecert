import { createFileRoute } from "@tanstack/react-router";
import Layout from "@/components/Layout";
import Legal from "@/pages/Legal";

export const Route = createFileRoute("/legal/privacy-policy")({
  head: () => ({
    meta: [
      { title: "Privacy Policy | UseCert" },
      {
        name: "description",
        content: "How UseCert collects, uses and protects data across the protocol interface and website.",
      },
      { property: "og:title", content: "UseCert Privacy Policy" },
      { property: "og:description", content: "Data practices for the UseCert interface and website." },
    ],
  }),
  component: () => (
    <Layout>
      <Legal doc="privacy-policy" />
    </Layout>
  ),
});
