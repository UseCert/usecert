import Hero from "./home/Hero";
import WhyNow from "./home/WhyNow";
import Mint from "./home/Mint";
import Vaults from "./home/Vaults";
import WhyUseCert from "./home/WhyUseCert";
import HowItWorks from "./home/HowItWorks";
import TheGap from "./home/TheGap";
import Faq from "./home/Faq";
import Boundaries from "./home/Boundaries";
import Compare from "./home/Compare";
import Testimonials from "./home/Testimonials";
import Marquee from "./home/Marquee";
import Research from "./home/Research";

/** UseCert landing page: 1:1 Mattis homepage replica, 14 sections in template order. */
export default function Home() {
  return (
    <>
      <Hero />
      <WhyNow />
      <Mint />
      <Vaults />
      <WhyUseCert />
      <HowItWorks />
      <TheGap />
      <Faq />
      <Boundaries />
      <Compare />
      <Testimonials />
      <Marquee />
      <Research />
    </>
  );
}
