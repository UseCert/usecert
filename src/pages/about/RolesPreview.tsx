import { Link } from "react-router";
import { motion } from "framer-motion";
import { ArrowUpRight } from "lucide-react";

const EASE = [0.16, 1, 0.3, 1] as [number, number, number, number];

const ROLES = [
  { name: "Holder", desc: "Mints and holds certificates at UseCert®" },
  { name: "DeFi Builder", desc: "Lists certificates as collateral and pairs at UseCert®" },
  { name: "Staker", desc: "Backstops the buffer at UseCert®" },
  { name: "Arbitrageur", desc: "Keeps the peg tight at UseCert®" },
];

/** §4 "THE ROLES." (black): heading + copy + 4 name/role rows, all linking to /roles. */
export default function RolesPreview() {
  return (
    <section className="grain bg-ink text-white">
      <div className="relative z-[2] mx-auto max-w-[1440px] px-4 py-16 md:px-6 md:py-24 lg:px-12 lg:py-32">
        <div className="grid gap-10 lg:grid-cols-[1fr_2fr] lg:gap-20">
          {/* Left: heading + copy + arrow link */}
          <div>
            <p className="font-mono text-[11px] uppercase tracking-[0.08em] text-white-60">Small surface area</p>
            <motion.h2
              className="mt-4 text-[44px] font-semibold uppercase leading-[0.85] tracking-[-0.05em] text-white md:text-[60px] lg:text-[78px]"
              initial={{ opacity: 0, y: 24 }}
              whileInView={{ opacity: 1, y: 0 }}
              viewport={{ once: true, amount: 0.3 }}
              transition={{ duration: 0.7, ease: EASE }}
            >
              The Roles.
            </motion.h2>
            <motion.p
              className="mt-6 max-w-[40ch] text-[16px] leading-[1.55] text-white-60"
              initial={{ opacity: 0, y: 24 }}
              whileInView={{ opacity: 1, y: 0 }}
              viewport={{ once: true, amount: 0.3 }}
              transition={{ delay: 0.1, duration: 0.7, ease: EASE }}
            >
              Small surface area on purpose. Four roles, no layers, no custody between you and the asset.
            </motion.p>
            <motion.div
              className="mt-8"
              initial={{ opacity: 0, y: 16 }}
              whileInView={{ opacity: 1, y: 0 }}
              viewport={{ once: true }}
              transition={{ delay: 0.2, duration: 0.6, ease: EASE }}
            >
              <Link
                to="/roles"
                className="group inline-flex items-center gap-2 text-[13px] font-semibold uppercase tracking-[0.08em] text-white transition-colors hover:text-green-bright"
              >
                A role for everyone
                <ArrowUpRight size={16} className="transition-transform group-hover:-translate-y-0.5 group-hover:translate-x-0.5" />
              </Link>
            </motion.div>
          </div>

          {/* Right: hairline-separated role rows */}
          <div className="border-t hairline-dark">
            {ROLES.map((r, i) => (
              <motion.div
                key={r.name}
                initial={{ opacity: 0, y: 24 }}
                whileInView={{ opacity: 1, y: 0 }}
                viewport={{ once: true, amount: 0.3 }}
                transition={{ delay: i * 0.08, duration: 0.6, ease: EASE }}
              >
                <Link to="/roles" className="group flex items-center gap-4 border-b hairline-dark py-6 md:gap-6 md:py-7">
                  <span
                    className="h-2 w-2 shrink-0 rounded-full bg-white/25 transition-colors duration-300 group-hover:bg-green-bright"
                    aria-hidden
                  />
                  <span className="text-[22px] font-semibold uppercase tracking-[-0.03em] text-white transition-transform duration-300 group-hover:translate-x-2 md:text-[28px]">
                    {r.name}
                  </span>
                  <span className="ml-auto text-right font-mono text-[12px] uppercase tracking-[0.06em] text-white-60 md:text-[13px]">
                    {r.desc}
                  </span>
                </Link>
              </motion.div>
            ))}
          </div>
        </div>
      </div>
    </section>
  );
}
