import { useRef } from "react";
import { Link } from "@/lib/router-compat";
import { motion, useScroll, useTransform } from "framer-motion";
import type { MotionValue } from "framer-motion";
import { ArrowUpRight } from "lucide-react";

export interface VaultCardData {
  slug: string;
  name: string;
  image: string;
  tags: string;
  year: string;
}

/* Three live vaults. The third card was `uSPX`, tagged "Roadmap C2" — a certificate that
 * cannot exist, because the venue has no SPX perpetual for a vault to hedge against. uQQQ
 * replaces it: also an index certificate, and actually deployed on chain 46630. uSPY tracks
 * the S&P 500 and is live too, so nothing the uSPX card promised is unavailable. */
export const HOME_VAULTS: VaultCardData[] = [
  { slug: "utsla", name: "uTSLA", image: "/vault-utsla.jpg", tags: "Tesla Certificate, Mint + Redeem", year: "2026" },
  { slug: "unvda", name: "uNVDA", image: "/vault-unvda.jpg", tags: "Nvidia Certificate, Mint + Redeem", year: "2026" },
  { slug: "uqqq", name: "uQQQ", image: "/vault-uqqq.jpg", tags: "Index Certificate, Mint + Redeem", year: "2026" },
];

/** Card skins alternate exactly like the template work cards: light grey, deep green, light grey. */
const SKINS = [
  { bg: "#b7b7b5", meta: "text-[#1c1c1c]/70", name: "text-[#1c1c1c]" },
  { bg: "#0f231e", meta: "text-white/60", name: "text-white" },
  { bg: "#b7b7b5", meta: "text-[#1c1c1c]/70", name: "text-[#1c1c1c]" },
];

function VaultCard({
  card,
  index,
  total,
  progress,
}: {
  card: VaultCardData;
  index: number;
  total: number;
  progress: MotionValue<number>;
}) {
  const span = 1 / (total - 1);
  const start = index * span;
  const end = Math.min(start + span, 1);
  const prev = Math.max(0, start - span);
  const skin = SKINS[index % SKINS.length];

  // Current card scales down + sinks as the next card covers it.
  const scale = useTransform(progress, [start, end], [1, index === total - 1 ? 1 : 0.92]);
  const y = useTransform(progress, [start, end], [0, index === total - 1 ? 0 : 24]);
  // Giant title draws on as the card becomes active.
  const titleOpacity = useTransform(progress, [index === 0 ? 0 : prev, index === 0 ? span * 0.5 : start], [index === 0 ? 0.9 : 0.05, 0.9]);
  // Image parallax inside the card.
  const imgY = useTransform(progress, [prev, end], [30, -30]);

  return (
    <div className="sticky top-0 h-[100dvh]">
      <motion.div style={{ scale, y, backgroundColor: skin.bg }} className="relative h-full w-full overflow-hidden">
        <Link to={`/vaults/${card.slug}`} className="group absolute inset-0 block" aria-label={`${card.name} vault`}>
          {/* Giant solid white title, full width, clipped at the edges, behind the image */}
          <motion.span
            style={{ opacity: titleOpacity }}
            className="absolute inset-0 flex items-center justify-center whitespace-nowrap text-[27vw] font-semibold uppercase leading-none tracking-[-0.05em] text-white"
            aria-hidden
          >
            {card.name}
          </motion.span>

          {/* Centered 16:10 image with meta row directly beneath it */}
          <div className="absolute inset-0 flex flex-col items-center justify-center px-6">
            <motion.div style={{ y: imgY }} className="w-full max-w-[880px]">
              <div className="overflow-hidden">
                <img
                  src={card.image}
                  alt={`${card.name} certificate plate`}
                  className="aspect-[16/10] w-full object-cover transition-transform duration-500 group-hover:scale-[1.02]"
                />
              </div>
              <div className="mt-4 flex items-start justify-between gap-4">
                <span className={`font-mono text-[11px] uppercase tracking-[0.08em] ${skin.meta}`}>
                  {card.name} Certificate
                </span>
                <span className={`hidden text-center font-mono text-[11px] uppercase tracking-[0.08em] ${skin.meta} md:block`}>
                  {card.tags}
                </span>
                <span className={`font-mono text-[11px] uppercase tracking-[0.08em] ${skin.meta}`}>
                  {card.year}
                </span>
              </div>
            </motion.div>
          </div>
        </Link>
      </motion.div>
    </div>
  );
}

/** §4 CERTIFICATES: sticky stacking vault cards - #vaults */
export default function Vaults() {
  const ref = useRef<HTMLElement>(null);
  const { scrollYProgress } = useScroll({ target: ref, offset: ["start start", "end end"] });

  return (
    <section id="vaults" ref={ref} className="relative bg-ink text-white">
      <div className="relative z-[2]">
        {HOME_VAULTS.map((card, i) => (
          <VaultCard key={card.slug} card={card} index={i} total={HOME_VAULTS.length} progress={scrollYProgress} />
        ))}
        <div className="flex justify-center border-t hairline-dark py-16">
          <Link
            to="/vaults"
            className="group flex items-center gap-2 text-[13px] font-semibold uppercase tracking-[0.08em] text-white transition-colors hover:text-green-bright"
          >
            All vaults
            <ArrowUpRight size={16} className="transition-transform group-hover:translate-x-0.5 group-hover:-translate-y-0.5" />
          </Link>
        </div>
      </div>
    </section>
  );
}
