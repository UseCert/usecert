import { motion } from "framer-motion";

const BAR_GLYPH = (
  <span className="mr-2 inline-flex flex-col gap-[2px]" aria-hidden>
    <span className="h-[2px] w-3 bg-current" />
    <span className="h-[2px] w-2 bg-current" />
  </span>
);

const ITEMS = [
  { name: "Robinhood Chain", glyph: BAR_GLYPH },
  { name: "CertVault", glyph: BAR_GLYPH },
  { name: "CertOracle", glyph: BAR_GLYPH },
  { name: "BufferBook", glyph: BAR_GLYPH },
  { name: "Certificate", glyph: BAR_GLYPH },
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
