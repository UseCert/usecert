import { useRef } from "react";
import { Link } from "react-router";
import { motion, useScroll, useTransform } from "framer-motion";
import { ArrowLeft } from "lucide-react";
import LetterReveal from "@/components/LetterReveal";
import type { VaultData } from "./data";

const EASE = [0.16, 1, 0.3, 1] as [number, number, number, number];

/** Detail section 1: back link + giant title + tagline + framed hero media. */
export default function DetailHero({ vault }: { vault: VaultData }) {
  const mediaRef = useRef<HTMLDivElement>(null);
  const { scrollYProgress } = useScroll({ target: mediaRef, offset: ["start end", "end start"] });
  const imgY = useTransform(scrollYProgress, [0, 1], [0, -30]);

  return (
    <section className="grain bg-ink text-white">
      <div className="relative z-[2] mx-auto max-w-[1440px] px-4 pb-16 pt-10 md:px-6 md:pb-24 md:pt-14 lg:px-12">
        <motion.div
          initial={{ opacity: 0, y: 12 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.5, ease: EASE }}
        >
          <Link
            to="/vaults"
            className="group inline-flex items-center gap-2 font-mono text-[11px] uppercase tracking-[0.08em] text-white-60 transition-colors hover:text-white"
          >
            <ArrowLeft size={14} className="transition-transform group-hover:-translate-x-0.5" />
            Back to vaults
          </Link>
        </motion.div>

        <h1 className="mt-8 text-[52px] font-semibold uppercase leading-[0.82] tracking-[-0.05em] md:text-[68px] lg:text-[92px]">
          <LetterReveal text={vault.name} delay={0.15} stagger={0.03} immediate />
        </h1>

        <motion.p
          className="mt-6 max-w-[26ch] text-[26px] font-medium leading-[1.05] tracking-[-0.03em] text-white-60 md:text-[32px] lg:text-[40px]"
          initial="hidden"
          animate="show"
          variants={{ hidden: {}, show: { transition: { staggerChildren: 0.03, delayChildren: 0.4 } } }}
        >
          {vault.tagline.split(" ").map((w, i, arr) => (
            <motion.span
              key={`${w}-${i}`}
              className="inline-block whitespace-pre"
              variants={{ hidden: { opacity: 0, y: 10 }, show: { opacity: 1, y: 0, transition: { duration: 0.4 } } }}
            >
              {w}
              {i < arr.length - 1 ? " " : ""}
            </motion.span>
          ))}
        </motion.p>

        {/* Hero media: clip reveal from bottom + scroll parallax */}
        <div ref={mediaRef} className="mt-12 md:mt-16">
          <motion.div
            className="border hairline-dark"
            initial={{ clipPath: "inset(100% 0% 0% 0%)" }}
            animate={{ clipPath: "inset(0% 0% 0% 0%)" }}
            transition={{ delay: 0.5, duration: 1, ease: EASE }}
          >
            <motion.img
              src={vault.image}
              alt={`${vault.name} certificate plate`}
              style={{ y: imgY }}
              className="aspect-[16/10] w-full scale-[1.06] object-cover"
            />
          </motion.div>
        </div>
      </div>
    </section>
  );
}
