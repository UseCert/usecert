import RolesHero from "./roles/Hero";
import RolesAccordion from "./roles/RolesAccordion";
import TokenFlow from "./roles/TokenFlow";
import Quote from "./roles/Quote";
import Roadmap from "./roles/Roadmap";
import CtaBand from "./roles/CtaBand";

/**
 * * ROLES (/roles): "A Role For Everyone". Careers-page replacement built from
 * template components: hero, roles accordion with CTAs, token fee-flow
 * counters, quote, C1-C4 roadmap strip, CTA band, footer (via Layout).
 */
export default function Roles() {
  return (
    <>
      <RolesHero />
      <RolesAccordion />
      <TokenFlow />
      <Quote />
      <Roadmap />
      <CtaBand />
    </>
  );
}
