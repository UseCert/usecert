import { createFileRoute } from "@tanstack/react-router";
import Layout from "@/components/Layout";
import Legal from "@/pages/Legal";

export const Route = createFileRoute("/legal/terms-of-service")({
  head: () => ({
    meta: [
      { title: "Terms of Service | UseCert" },
      {
        name: "description",
        content: "The terms that govern use of the UseCert interface, certificates and vault infrastructure.",
      },
      { property: "og:title", content: "UseCert Terms of Service" },
      { property: "og:description", content: "Terms governing use of the UseCert interface and certificates." },
    ],
  }),
  component: () => (
    <Layout>
      <Legal doc="terms-of-service" />
    </Layout>
  ),
});
