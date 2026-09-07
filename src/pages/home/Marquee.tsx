import { motion } from "framer-motion";

const ITEMS = [
  { name: "Robinhood Chain", glyph: <span className="mr-2 inline-block h-2 w-2 rounded-full bg-green-bright" aria-hidden /> },
  { name: "CertVault", glyph: <span className="mr-2 inline-block h-3 w-3 border border-current" aria-hidden /> },
  { name: "CertOracle", glyph: <span className="mr-2 inline-block h-3 w-3 rounded-full border border-current" aria-hidden /> },
  { name: "BufferBook", glyph: <span className="mr-2 inline-flex flex-col gap-[2px]" aria-hidden><span className="h-[2px] w-3 bg-current" /><span className="h-[2px] w-2 bg-current" /></span> },
  { name: "InsuranceStaking", glyph: <span className="mr-2 inline-block h-3 w-3 rotate-45 border border-current" aria-hidden /> },
  { name: "FeeVault", glyph: <span className="mr-2 inline-flex h-3 w-3 items-center justify-center border border-current text-[8px] font-semibold leading-none" aria-hidden>F</span> },
  { name: "Certificate", glyph: <img src="/logo.png" alt="" className="mr-2 inline h-4 w-4 object-contain" /> },
];

/** §12 ARCHITECTURE MARQUEE (light grey paper, infinite ticker, 28s cycle) */
export default function Marquee() {
  const row = [...ITEMS, ...ITEMS];
  return (
    <section className="overflow-hidden border-t hairline-light bg-paper py-10">
      <motion.div
        initial={{ opacity: 0 }}
        whileInView={{ opacity: 1 }}
        viewport={{ once: true }}
        transition={{ duration: 0.8 }}
        className="marquee-track flex w-max gap-[14px]"
      >
        {row.map((item, i) => (
          <div
            key={`${item.name}-${i}`}
            className="flex items-center whitespace-nowrap bg-white px-8 py-5 text-[15px] font-semibold uppercase tracking-[0.04em] text-ink/70"
          >
            {item.glyph}
            {item.name}
          </div>
        ))}
      </motion.div>
    </section>
  );
}
