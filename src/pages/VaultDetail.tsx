import { useParams } from "@/lib/router-compat";
import DetailHero from "./vaults/DetailHero";
import { IntroMeta, MediaBlock, TextBlock } from "./vaults/DetailSections";
import { CtaBand, HolderWords, NextVault, Results } from "./vaults/DetailBands";
import { getVault, nextVault } from "./vaults/data";

/**
 * /vaults/:slug detail page: hero, intro + meta grid, problem, media block,
 * results, approach, holder words, next vault, CTA band. Driven entirely by
 * the per-vault data module (slugs: utsla, unvda, uqqq, uaapl). `uspx` was removed: the
 * venue has no SPX perpetual, so that vault cannot exist. uSPY, which tracks the same
 * index and IS deployed, has no marketing entry yet — see `vaults/data.ts`.
 */
export default function VaultDetail() {
  const { slug } = useParams();
  const vault = getVault(slug);
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
