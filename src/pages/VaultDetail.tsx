import { useParams } from "@/lib/router-compat";
import DetailHero from "./vaults/DetailHero";
import { IntroMeta, MediaBlock, TextBlock } from "./vaults/DetailSections";
import { CtaBand, HolderWords, NextVault, Results } from "./vaults/DetailBands";
import { getVault, nextVault } from "./vaults/data";

/**
 * /vaults/:slug detail page: hero, intro + meta grid, problem, media block,
 * results, approach, holder words, next vault, CTA band. Driven entirely by
 * the per-vault data module (slugs: utsla, unvda, uqqq, uaapl, uspy, umsft - the six deployed
 * vaults). `uspx` was removed: the venue has no SPX perpetual. An unknown slug is a 404.
 */
export default function VaultDetail() {
  const { slug } = useParams();
  // The route's loader 404s an unknown slug before this renders; the guard keeps the type honest.
  const vault = getVault(slug);
  if (!vault) return null;
  const next = nextVault(vault.slug);

  return (
    <>
      <DetailHero vault={vault} />
      <IntroMeta vault={vault} />
      <TextBlock heading="The problem." paragraphs={vault.problem} />
      <MediaBlock vault={vault} />
      <Results vault={vault} />
      <TextBlock
        heading="The approach."
        paragraphs={vault.approach}
        link={{ label: "Read the funding mechanics", to: "/learn/funding-buffered-then-feed" }}
      />
      <HolderWords vault={vault} />
      <NextVault next={next} />
      <CtaBand vault={vault} />
    </>
  );
}
