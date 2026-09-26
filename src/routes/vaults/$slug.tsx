import { createFileRoute, notFound } from "@tanstack/react-router";
import { getVault } from "@/pages/vaults/data";
import Layout from "@/components/Layout";
import VaultDetail from "@/pages/VaultDetail";

export const Route = createFileRoute("/vaults/$slug")({
  // An unknown slug is a real 404 (it used to render uTSLA under any URL).
  loader: ({ params }) => {
    if (!getVault(params.slug)) throw notFound();
  },
  head: ({ params }) => {
    const v = getVault(params.slug);
    const subject = v ? v.tagline.split(",")[0] : "A UseCert vault";
    const title = v ? `${v.name} - ${subject} as a holdable certificate | UseCert` : "Vault not found | UseCert";
    const description = v?.intro ?? "This vault does not exist.";
    return {
      meta: [
        { title },
        { name: "description", content: description },
        { property: "og:title", content: title },
        { property: "og:description", content: description },
      ],
    };
  },
  component: () => (
    <Layout>
      <VaultDetail />
    </Layout>
  ),
});
