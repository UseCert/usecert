import { motion } from "framer-motion";
import { ArrowUpRight } from "lucide-react";
import { CHAIN, MIRRORS, SHARED } from "@/chain/contracts";
import { explorerAddressUrl } from "@/chain/config";
import { COLLATERAL_SYMBOL, FAUCET_ADDRESS, IS_TESTNET, VENUE_SIM_ADDRESS } from "@/chain/deployment";
import { MARKET_INDEX_UNVERIFIED_NOTE, isMarketIndexVerified } from "@/chain/useVaults";
import { cn } from "@/lib/utils";

const EASE = [0.16, 1, 0.3, 1] as [number, number, number, number];

/**
 * THE ADDRESS BOOK (/contracts).
 *
 * WHY THIS PAGE EXISTS. The milestones page told readers "every address is in the dashboard
 * and on the explorer" as the way to check that four mirrors are live. No contract address
 * was rendered anywhere on this site — not one. The only address that ever linked to the
 * explorer was the reader's own connected wallet. A verification instruction that cannot be
 * followed is worse than none: it borrows the credibility of being checkable without
 * providing it.
 *
 * Roadmap 3.4 asks for "a published address book that a user can verify against the
 * explorer". This is that. Every address comes from the generated bundle — the same module
 * the app itself transacts against — so the page cannot drift from what the dashboard uses.
 * Hand-maintaining a second list would reintroduce exactly the gap it is meant to close.
 *
 * All 26 contracts publish their source on the explorer (roadmap 3.5), so each link lands on
 * readable code rather than bytecode. Blockscout reports them as a PARTIAL match: the runtime
 * bytecode agrees and the metadata hash does not. That is stated on the page rather than left
 * for a reader to discover and wonder about.
 */

type Row = { label: string; address: string; note?: string };

const SHARED_ROWS: Row[] = [
  {
    label: "SolvencyRegistry",
    address: SHARED.solvencyRegistry,
    note: "Holds every attestation and its timestamp. ageSec() here is the number the dashboard publishes.",
  },
  {
    label: "CapacityOracle",
    address: SHARED.capacityOracle,
    note: "maxNotional18() — the mint ceiling. Returns zero while an attestation is aged out.",
  },
  {
    label: "CertFactory",
    address: SHARED.certFactory,
    note: "A registry, not a deployer. It stopped constructing vaults when doing so pushed it past the EIP-170 size limit.",
  },
  {
    label: IS_TESTNET ? "TestUSDG (collateral)" : `${COLLATERAL_SYMBOL} (collateral)`,
    address: SHARED.collateral,
    note: IS_TESTNET
      ? "The test collateral, 6 decimals. On mainnet this is replaced by real USDG and nothing here mints it."
      : "Real USDG, 6 decimals. Nothing in this deployment mints it; the vaults only hold what holders deposit.",
  },
];

// Appended only where the contract is actually deployed. The address book is generated from
// the deployment, so a row whose address does not exist would be a row about another chain.
if (FAUCET_ADDRESS) {
  SHARED_ROWS.push({
    label: "TestFaucet",
    address: FAUCET_ADDRESS,
    note: "The only way a tester gets collateral. It does not exist on mainnet — free money is a testnet feature.",
  });
}
if (VENUE_SIM_ADDRESS) {
  SHARED_ROWS.push({
    label: "LighterSim (venue)",
    address: VENUE_SIM_ADDRESS,
    note: "The perp venue, simulated. Lighter is not deployed on this testnet, so this contract stands in for it — and every margin and position figure on the dashboard describes a position it holds.",
  });
}

function Address({ address }: { address: string }) {
  return (
    <a
      href={explorerAddressUrl(address as `0x${string}`)}
      target="_blank"
      rel="noreferrer"
      className="group inline-flex items-center gap-1.5 font-mono text-[11px] text-white-60 transition-colors hover:text-green-bright"
    >
      <span className="break-all">{address}</span>
      <ArrowUpRight
        size={12}
        className="shrink-0 transition-transform group-hover:-translate-y-0.5 group-hover:translate-x-0.5"
      />
    </a>
  );
}

function RowLine({ row }: { row: Row }) {
  return (
    <div className="border-b hairline-dark py-4 last:border-b-0">
      <div className="flex flex-wrap items-baseline justify-between gap-x-6 gap-y-1">
        <p className="font-mono text-[12px] uppercase tracking-[0.06em] text-white">{row.label}</p>
        <Address address={row.address} />
      </div>
      {row.note && (
        <p className="mt-1.5 max-w-[78ch] text-[12px] leading-[1.6] text-white-60/70">{row.note}</p>
      )}
    </div>
  );
}

export default function ContractsPage() {
  return (
    <section className="grain bg-ink text-white">
      <div className="relative z-[2] mx-auto max-w-[1440px] px-4 py-24 md:px-6 md:py-32 lg:px-12">
        <p className="font-mono text-[11px] uppercase tracking-[0.08em] text-white-60">Addresses</p>
        <h1 className="mt-4 max-w-[20ch] text-[44px] font-semibold uppercase leading-[0.85] tracking-[-0.05em] md:text-[60px] lg:text-[78px]">
          Every contract<span className="text-green-bright">,</span> and where to read it
        </h1>

        <p className="mt-8 max-w-[64ch] text-[16px] leading-[1.55] text-silver">
          All {MIRRORS.length * 5 + SHARED_ROWS.length} contracts behind UseCert, on{" "}
          <strong className="text-white">{CHAIN.name}</strong> (chain {CHAIN.id}). Every one
          publishes its source on the explorer, so each link lands on code rather than bytecode.
        </p>
        <p className="mt-4 max-w-[64ch] text-[14px] leading-[1.6] text-white-60">
          These come from the same generated module the app transacts against — not a list kept
          by hand beside it — so this page cannot drift from the contracts the dashboard is
          actually talking to.
        </p>

        {/* Shared */}
        <div className="mt-16 md:mt-24">
          <p className="font-mono text-[11px] uppercase tracking-[0.08em] text-white-60">
            Shared <span className="text-white-60/60">· {SHARED_ROWS.length}</span>
          </p>
          <div className="mt-6 border-t hairline-dark">
            {SHARED_ROWS.map((r) => (
              <RowLine key={r.label} row={r} />
            ))}
          </div>
        </div>

        {/* Per mirror */}
        {MIRRORS.map((m, i) => {
          // MIRRORS is keyed by venue symbol ("uTSLA"); the verified map by vault id
          // ("utsla"). Lowercasing is the mapping the rest of the app uses.
          const verified = isMarketIndexVerified(
            m.symbol.toLowerCase() as Parameters<typeof isMarketIndexVerified>[0],
          );
          return (
            <motion.div
              key={m.symbol}
              className="mt-14"
              initial={{ opacity: 0, y: 16 }}
              whileInView={{ opacity: 1, y: 0 }}
              viewport={{ once: true, amount: 0.15 }}
              transition={{ delay: Math.min(i, 3) * 0.05, duration: 0.5, ease: EASE }}
            >
              <div className="flex flex-wrap items-baseline gap-x-3 gap-y-1">
                <p className="font-mono text-[11px] uppercase tracking-[0.08em] text-white-60">
                  {m.symbol} <span className="text-white-60/60">· 5</span>
                </p>
                <p
                  className={cn(
                    "font-mono text-[10px] uppercase tracking-[0.06em]",
                    verified ? "text-white-60/60" : "text-warn",
                  )}
                >
                  venue market {m.marketIndex} · {verified ? "verified" : "does not match the live venue"}
                </p>
              </div>
              <div className="mt-6 border-t hairline-dark">
                <RowLine
                  row={{
                    label: "CertVault",
                    address: m.vault,
                    note: "Holds the collateral, runs the hedge, and is the only contract that can mint or burn the certificate.",
                  }}
                />
                <RowLine
                  row={{
                    label: "Certificate",
                    address: m.certificate,
                    note: "The ERC-20 you actually hold.",
                  }}
                />
                <RowLine
                  row={{
                    label: "CertOracle",
                    address: m.certOracle,
                    note: "px() and the three guards — staleness, deviation, basis — whose thresholds the risk table reads from here.",
                  }}
                />
                <RowLine
                  row={{ label: "BufferBook", address: m.bufferBook, note: "The accrual ledger." }}
                />
                <RowLine
                  row={{
                    // The address book keeps the key `replayAggregator` on both chains; on
                    // mainnet the address it holds is the Chainlink feed CertOracle reads.
                    label: IS_TESTNET ? "ReplayAggregator" : "Chainlink feed",
                    address: m.replayAggregator,
                    note: IS_TESTNET
                      ? "The price feed stand-in. A real deployment reads a live aggregator instead."
                      : "Chainlink price feed, 8 decimals, total-return. Read only through CertOracle, which applies the guards.",
                  }}
                />
              </div>
            </motion.div>
          );
        })}

        {/* The caveats a reader would otherwise have to discover */}
        <div className="mt-16 border hairline-dark bg-section-deep p-6 md:mt-24 md:p-8">
          <p className="font-mono text-[11px] uppercase tracking-[0.08em] text-green-bright">
            What "verified" does and does not mean here
          </p>
          {IS_TESTNET ? (
            <p className="mt-3 max-w-[70ch] text-[14px] leading-[1.6] text-white-60">
              The explorer reports these as a <strong className="text-white">partial match</strong>:
              the runtime bytecode agrees with the published source, and the compiler metadata hash
              does not. A full match needs the exact metadata settings used at deploy time. The code
              you read is the code that runs; the build that produced it is not byte-reproducible
              from this repository yet.
            </p>
          ) : (
            <p className="mt-3 max-w-[70ch] text-[14px] leading-[1.6] text-white-60">
              Source for all {MIRRORS.length * 4 + 3} contracts is published on{" "}
              <a
                href="https://sourcify.dev/#/lookup"
                target="_blank"
                rel="noreferrer"
                className="text-white underline underline-offset-4 hover:text-green-bright"
              >
                Sourcify
              </a>{" "}
              with an <strong className="text-white">exact match</strong> on the runtime bytecode.
              The contracts this deployment created directly also match on creation bytecode; each
              vault's certificate and buffer ledger are created inside the vault's own constructor,
              so they have no creation transaction of their own to match.
            </p>
          )}
          <p className="mt-4 max-w-[70ch] text-[14px] leading-[1.6] text-white-60">
            {MIRRORS.every((m) => isMarketIndexVerified(m.symbol.toLowerCase() as Parameters<typeof isMarketIndexVerified>[0]))
              ? "Every mirror's venue market index was read from the venue's own market list before deploying, by a preflight that refuses a market the venue does not list. The index is immutable, so a wrong one could only be fixed by redeploying."
              : MARKET_INDEX_UNVERIFIED_NOTE}
          </p>
        </div>
      </div>
    </section>
  );
}
