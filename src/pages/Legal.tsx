import { useLocation } from "@/lib/router-compat";
import { motion } from "framer-motion";

const EASE = [0.16, 1, 0.3, 1] as [number, number, number, number];

export type LegalDoc = "privacy-policy" | "terms-of-service";

interface LegalSection {
  heading: string;
  paragraphs: string[];
}

const PROTOCOL_DISCLAIMER =
  "Certificates are synthetic instruments backed by on chain perp positions and USDG margin. No dividends, no shareholder rights. Not available where synthetic equity exposure is restricted. UseCert is infrastructure, not investment advice.";

const CONTACT_LINE =
  "For any questions about this document, reach the team on X (x.com/use_cert) or Telegram (t.me/usecertonchain).";

const DOCS: Record<LegalDoc, { title: string; updated: string; sections: LegalSection[] }> = {
  "privacy-policy": {
    title: "Privacy Policy.",
    updated: "Last updated: Jul 01, 2026",
    sections: [
      {
        heading: "1. Introduction",
        paragraphs: [
          "This Privacy Policy explains how UseCert handles information when you use the UseCert interface and website. UseCert is a frontend interface to public smart contracts on Robinhood Chain. We do not custody funds, and we do not require accounts, emails, or personal information to use the protocol.",
        ],
      },
      {
        heading: "2. Information we collect",
        paragraphs: [
          "Connecting a wallet shares your public wallet address with the interface only. On chain transactions are public by design and are recorded on Robinhood Chain, where they can be read by anyone.",
          "If you subscribe to the vault report, we store the email address you provide solely to send that newsletter. You can unsubscribe at any time from any issue.",
        ],
      },
      {
        heading: "3. How we use information",
        paragraphs: [
          "We use your public wallet address to display your positions, certificates, and transaction history in the interface. We use aggregate, non-identifying usage data to improve the interface. We do not sell personal information, and we do not share it with advertisers.",
        ],
      },
      {
        heading: "4. Third party services",
        paragraphs: [
          "The interface relies on third party infrastructure such as RPC providers, oracles, and hosting services. These providers may process standard request metadata such as IP addresses and browser information. Their own privacy policies apply to that processing.",
        ],
      },
      {
        heading: "5. Data retention and security",
        paragraphs: [
          "On chain data is immutable and cannot be deleted by anyone, including us. Off chain data we hold, such as newsletter subscriptions, is retained only as long as needed and protected with industry standard safeguards. No system is perfectly secure, and you use the interface at your own risk.",
        ],
      },
      {
        heading: "6. Protocol disclaimer",
        paragraphs: [PROTOCOL_DISCLAIMER],
      },
      {
        heading: "7. Changes and contact",
        paragraphs: [
          "We may update this policy from time to time. The current version is always published on this page with its revision date. " + CONTACT_LINE,
        ],
      },
    ],
  },
  "terms-of-service": {
    title: "Terms of Service.",
    updated: "Last updated: Jul 01, 2026",
    sections: [
      {
        heading: "1. The service",
        paragraphs: [
          "These Terms of Service govern your use of the UseCert interface and website. UseCert provides access to holdable stock certificates: synthetic price exposure backed by perp positions and USDG margin on Robinhood Chain. The interface is a read and transaction layer over public smart contracts; the contracts themselves run autonomously on chain.",
        ],
      },
      {
        heading: "2. Certificates are not shares",
        paragraphs: [
          "Certificates are synthetic instruments. They are backed by on chain perp positions and USDG margin, not by custody of shares. Certificates carry no dividends, no voting rights, and no shareholder rights of any kind, and grant no claim on any issuer, exchange, or company referenced by an underlying market.",
        ],
      },
      {
        heading: "3. Minting, redemption, and fees",
        paragraphs: [
          "Redemption is never gated. On this deployment every redemption is queued: the vault closes the matching hedge on chain in the same transaction, and the collateral is paid by claim once it is back from the venue, usually within minutes and, in the worst case the venue allows, up to its 14-day priority expiration. Queued is not refused. That guarantee is a property of these contracts and stops where they do: submitting the transaction at all requires Robinhood Chain to include it, which is the chain’s concern and not something UseCert can promise on its behalf. Minting pauses automatically when oracle prices are stale or deviate beyond published guard bands; redemption continues at the last good price. Funding is paid on the venue, into and out of each vault’s margin account; sustained negative funding reduces what backs the vault, and no holding-fee pass-through is deployed. All parameters, thresholds and each vault’s collateral balance are public on chain.",
        ],
      },
      {
        heading: "4. Risks",
        paragraphs: [
          "Using the protocol involves risk, including smart contract risk, oracle risk, market and funding risk, dependence on a single trading venue and a single attester, and the risk that backing mechanisms behave differently under extreme conditions. No staking or insurance layer is deployed: today nothing sits between a vault’s own buffer and holders’ backing. You are responsible for understanding these risks before minting, holding or redeeming. Nothing in the interface constitutes a guarantee of value.",
        ],
      },
      {
        heading: "5. Eligibility and acceptable use",
        paragraphs: [
          "You may not use the protocol where synthetic equity exposure is restricted by the laws that apply to you, and you are solely responsible for that determination. You agree not to use the interface for unlawful activity, market manipulation, or attempts to exploit the contracts, the oracle, or other users.",
        ],
      },
      {
        heading: "6. No advice and no liability",
        paragraphs: [
          "UseCert is infrastructure, not investment advice. Nothing on this site is a recommendation to buy, sell, or hold any asset. To the maximum extent permitted by law, the UseCert contributors are not liable for any losses arising from your use of the interface or the protocol.",
        ],
      },
      {
        heading: "7. Protocol disclaimer",
        paragraphs: [PROTOCOL_DISCLAIMER],
      },
      {
        heading: "8. Changes and contact",
        paragraphs: [
          "We may update these terms from time to time. Continued use of the interface after an update constitutes acceptance of the revised terms. " + CONTACT_LINE,
        ],
      },
    ],
  },
};

/**
 * LEGAL (/legal/privacy-policy, /legal/terms-of-service): simple shared
 * layout, template typography, light grey paper, max 760px centered column.
 * Document selected by prop or derived from the route path.
 */
export default function Legal({ doc }: { doc?: LegalDoc }) {
  const { pathname } = useLocation();
  const resolved: LegalDoc =
    doc ?? (pathname.includes("terms-of-service") ? "terms-of-service" : "privacy-policy");
  const content = DOCS[resolved];

  return (
    <section className="bg-paper text-ink">
      <motion.div
        className="mx-auto max-w-[760px] px-4 py-16 md:px-6 md:py-24 lg:py-32"
        initial={{ opacity: 0, y: 16 }}
        animate={{ opacity: 1, y: 0 }}
        transition={{ duration: 0.6, ease: EASE }}
      >
        <p className="font-mono text-[11px] uppercase tracking-[0.08em] text-ink-60">Legal</p>
        <h1 className="mt-6 text-[36px] font-semibold uppercase leading-[0.9] tracking-[-0.04em] md:text-[52px]">
          {content.title}
        </h1>
        <p className="mt-4 font-mono text-[11px] uppercase tracking-[0.08em] text-ink-60">
          {content.updated}
        </p>

        <div className="mt-12">
          {content.sections.map((section, i) => (
            <motion.div
              key={section.heading}
              className="mt-10 first:mt-0"
              initial={{ opacity: 0, y: 16 }}
              animate={{ opacity: 1, y: 0 }}
              transition={{ delay: 0.15 + i * 0.04, duration: 0.5, ease: EASE }}
            >
              <h2 className="text-[20px] font-semibold uppercase tracking-[-0.02em]">
                {section.heading}
              </h2>
              {section.paragraphs.map((p, pi) => (
                <p key={pi} className="mt-4 text-[15px] leading-[1.65] text-ink-60 md:text-[16px]">
                  {p}
                </p>
              ))}
            </motion.div>
          ))}
        </div>
      </motion.div>
    </section>
  );
}
