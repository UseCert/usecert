import { useEffect, useRef, useState } from "react";
import { motion, useScroll, useTransform } from "framer-motion";
import LetterReveal from "@/components/LetterReveal";
import { IS_TESTNET } from "@/chain/deployment";
import { useLang, useT } from "@/i18n";

const EASE = [0.16, 1, 0.3, 1] as [number, number, number, number];

/** Live date/time widget, updates every minute. e.g. "September 06, 21:27" */
function LiveClock() {
  const format = () => {
    const d = new Date();
    const month = d.toLocaleString("en-US", { month: "long" });
    const day = String(d.getDate()).padStart(2, "0");
    const hh = String(d.getHours()).padStart(2, "0");
    const mm = String(d.getMinutes()).padStart(2, "0");
    return `${month} ${day}, ${hh}:${mm}`;
  };
  // Rendered client-side only: server time zone never matches the visitor's.
  const [now, setNow] = useState<string | null>(null);
  useEffect(() => {
    setNow(format());
    const id = window.setInterval(() => setNow(format()), 30_000);
    return () => window.clearInterval(id);
  }, []);
  return <span className="text-white">{now ?? "\u00a0"}</span>;

}

/** 5-bar phase indicator (3 green-bright / 2 grey) */
function SlotBars() {
  return (
    <span className="flex items-end gap-[3px]" aria-hidden>
      {[0, 1, 2, 3, 4].map((i) => (
        <motion.span
          key={i}
          className={i < 3 ? "w-[3px] bg-green-bright" : "w-[3px] bg-white/25"}
          initial={{ height: 4 }}
          animate={{ height: 14 }}
          transition={{ delay: 1.6 + i * 0.08, duration: 0.4, ease: EASE }}
        />
      ))}
    </span>
  );
}

const PARA_SEGMENTS: { text: string; bold?: boolean }[] = [
  { text: "We mint " },
  { text: "the missing asset", bold: true },
  { text: " on Robinhood Chain. Deposit USDG, the vault opens a fully backed long on the equity perp underneath, and you receive a stock certificate token that tracks the stock, sits in your wallet, and " },
  { text: "redeems at oracle price any time", bold: true },
  { text: "." },
];

/** Headline paragraph with letter-by-letter reveal and bold spans. */
function RevealParagraph() {
  const lang = useLang();
  const t = useT();
  const words: { word: string; bold?: boolean }[] = [];
  // Chinese: the segments joined into one sentence and translated whole; the bold emphasis is an
  // English word-level device and is not carried over.
  if (lang === "zh") Array.from(t(PARA_SEGMENTS.map((sg) => sg.text).join(""))).forEach((c) => words.push({ word: c }));
  else PARA_SEGMENTS.forEach((seg) => {
    seg.text.split(" ").forEach((w, i, arr) => {
      if (w) words.push({ word: w + (i < arr.length - 1 ? " " : ""), bold: seg.bold });
      else if (i < arr.length - 1) words.push({ word: " " });
    });
  });
  return (
    <motion.p
      className="uppercase-render mt-8 max-w-[52ch] text-[14px] leading-[1.6] text-white md:text-[16px]"
      initial="hidden"
      animate="show"
      variants={{ hidden: {}, show: { transition: { staggerChildren: 0.02, delayChildren: 0.9 } } }}
    >
      {words.map((w, i) => (
        <motion.span
          key={i}
          className={w.bold ? "inline-block font-semibold" : "inline-block"}
          variants={{
            hidden: { y: 14, opacity: 0 },
            show: { y: 0, opacity: 1, transition: { duration: 0.5, ease: EASE } },
          }}
        >
          {w.word.replace(/ $/, "\u00A0")}
        </motion.span>
      ))}
    </motion.p>
  );
}

function CornerDot({ className }: { className: string }) {
  return <span className={`absolute h-[5px] w-[5px] bg-white ${className}`} aria-hidden />;
}

export default function Hero() {
  const ref = useRef<HTMLElement>(null);
  const { scrollYProgress } = useScroll({ target: ref, offset: ["start start", "end start"] });
  const imgY = useTransform(scrollYProgress, [0, 1], [0, -40]);

  return (
    <section id="top" ref={ref} className="grain relative -mt-16 flex min-h-[100dvh] items-center overflow-hidden bg-ink md:-mt-20">
      {/* Background portrait: slow scale 1.08 -> 1 on load + parallax */}
      <motion.div className="absolute inset-0" style={{ y: imgY }}>
        <motion.img
          src="/hero-portrait.jpg"
          alt=""
          className="h-full w-full object-cover opacity-70"
          initial={{ scale: 1.08 }}
          animate={{ scale: 1 }}
          transition={{ duration: 2, ease: "easeOut" }}
        />
        <div className="absolute inset-0 bg-gradient-to-t from-ink via-ink/40 to-ink/60" />
      </motion.div>

      {/* Framed rectangle with corner dots */}
      <motion.div
        className="relative z-[2] mx-auto w-full max-w-[900px] px-4 md:px-6"
        initial={{ opacity: 0, scale: 0.985 }}
        animate={{ opacity: 1, scale: 1 }}
        transition={{ duration: 1, delay: 0.1, ease: EASE }}
      >
        <div className="relative border hairline-dark px-6 py-10 md:px-12 md:py-14">
          <CornerDot className="left-[-3px] top-[-3px]" />
          <CornerDot className="right-[-3px] top-[-3px]" />
          <CornerDot className="bottom-[-3px] left-[-3px]" />
          <CornerDot className="bottom-[-3px] right-[-3px]" />

          <p className="font-mono text-[11px] uppercase tracking-[0.08em] text-white-60">
            (EST. 2026 · VERSION 1.0.0)
          </p>

          {/* Wordmark */}
          <div className="relative mt-6">
            <h1 className="text-[40px] font-semibold uppercase leading-[0.9] tracking-[-0.04em] text-white sm:text-[52px] sm:leading-[0.82] sm:tracking-[-0.05em] md:text-[68px] lg:text-[92px]">
              <LetterReveal text="USECERT®" immediate delay={0.2} stagger={0.03} />
            </h1>
          </div>


          <RevealParagraph />

          {/* Protocol badge row */}
          <motion.div
            className="mt-8 flex items-center gap-3"
            initial={{ opacity: 0, y: 20 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ delay: 1.4, duration: 0.6, ease: EASE }}
          >
            <img src="/logo.png" alt="UseCert monogram" className="h-10 w-10 object-contain" />
            <div>
              <p className="text-[14px] font-semibold text-white">UseCert®</p>
              <p className="font-mono text-[12px] uppercase tracking-[0.08em] text-white-60">Protocol on Robinhood Chain</p>
            </div>
          </motion.div>

          {/* Bottom row of frame */}
          <motion.div
            className="mt-10 flex items-center gap-2 border-t hairline-dark pt-5 text-[12px] font-medium uppercase tracking-[0.08em] text-white-60"
            initial={{ opacity: 0, y: 20 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ delay: 1.5, duration: 0.6, ease: EASE }}
          >
            <span>Mint</span>
            <span aria-hidden>/</span>
            <span>Hold</span>
            <span aria-hidden>/</span>
            <span>Redeem</span>
          </motion.div>
        </div>
      </motion.div>

      {/* Bottom-left: phase + slot bars */}
      <motion.div
        className="absolute bottom-5 left-4 z-[2] flex items-center gap-2 font-mono text-[10px] uppercase tracking-[0.06em] text-white-60 sm:gap-3 sm:text-[11px] sm:tracking-[0.08em] md:left-12"
        initial={{ opacity: 0, y: 20 }}
        animate={{ opacity: 1, y: 0 }}
        transition={{ delay: 1.6, duration: 0.6, ease: EASE }}
      >
        <span>Phase:</span>
        <SlotBars />
        <span className="whitespace-nowrap text-white">{IS_TESTNET ? "C1 on testnet" : "C1 on mainnet"}</span>
      </motion.div>

      {/* Bottom-right: local time */}
      <motion.div
        className="absolute bottom-5 right-4 z-[2] flex items-center gap-2 font-mono text-[10px] uppercase tracking-[0.06em] text-white-60 sm:text-[11px] sm:tracking-[0.08em] md:right-12"
        initial={{ opacity: 0, y: 20 }}
        animate={{ opacity: 1, y: 0 }}
        transition={{ delay: 1.7, duration: 0.6, ease: EASE }}
      >
        <span className="hidden sm:inline">Local Time:</span>
        <LiveClock />
      </motion.div>

    </section>
  );
}
