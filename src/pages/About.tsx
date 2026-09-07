import AboutHero from "./about/Hero";
import Story from "./about/Story";
import Stats from "./about/Stats";
import RolesPreview from "./about/RolesPreview";
import HowItWorks from "./home/HowItWorks";

/**
 * * ABOUT (/about): Why UseCert. 1:1 replica of the template /about page:
 * hero, story paragraphs, counter stats, "The roles." (replaces "The team."),
 * shared How It Works accordion, footer (via Layout).
 */
export default function About() {
  return (
    <>
      <AboutHero />
      <Story />
      <Stats />
      <RolesPreview />
      <HowItWorks />
    </>
  );
}
