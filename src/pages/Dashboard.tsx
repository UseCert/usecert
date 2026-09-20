import { AnimatePresence, motion } from "framer-motion";
import { DashboardProvider, useDashboard } from "./dashboard/store";
import { TopBar, Sidebar, BottomTabs, FooterBar } from "./dashboard/chrome";
import { WalletModal } from "./dashboard/modals";
import ToastStack from "./dashboard/Toasts";
import CommandPalette from "./dashboard/CommandPalette";
import Overview from "./dashboard/Overview";
import VaultsView from "./dashboard/VaultsView";
import MintRedeem from "./dashboard/MintRedeem";
import ActivityView from "./dashboard/ActivityView";
import RiskView from "./dashboard/RiskView";

function ViewRouter() {
  const { view } = useDashboard();
  switch (view) {
    case "vaults":
      return <VaultsView />;
    case "mint":
      return <MintRedeem />;
    case "activity":
      return <ActivityView />;
    case "risk":
      return <RiskView />;
    default:
      return <Overview />;
  }
}

function DashboardInner() {
  const { view } = useDashboard();
  return (
    <div className="dashboard-root min-h-[100dvh] bg-black text-white">
      {/* Static grain texture; the single animated grain layer is the global FilmGrain */}
      <div
        aria-hidden
        className="pointer-events-none fixed inset-0 z-[1]"
        style={{
          backgroundImage: "url(/grain.png)",
          backgroundRepeat: "repeat",
          backgroundSize: "512px 512px",
          opacity: 0.07,
        }}
      />

      <TopBar />
      <Sidebar />

      <main className="relative z-[2] pb-24 pt-16 md:pb-0 md:pl-16 xl:pl-60">
        <AnimatePresence mode="wait">
          <motion.div
            key={view}
            initial={{ opacity: 0, y: 18 }}
            animate={{ opacity: 1, y: 0 }}
            exit={{ opacity: 0, y: -10 }}
            transition={{ duration: 0.45, ease: [0.16, 1, 0.3, 1] }}
            className="mx-auto max-w-[1200px] px-4 py-8 md:px-8"
          >
            <ViewRouter />
            <FooterBar />
          </motion.div>
        </AnimatePresence>
      </main>

      <BottomTabs />
      <WalletModal />
      <CommandPalette />
      <ToastStack />
    </div>
  );
}

/**
 * /dashboard: UseCert protocol dashboard. Fully self-contained app chrome
 * (own sidebar + topbar, no landing Layout/Navbar/Footer), reading the live
 * deployment on Robinhood Chain testnet (chain 46630). There is no mock data
 * engine any more: every figure comes from a contract read or renders as an
 * em-dash.
 */
export default function Dashboard() {
  return (
    <DashboardProvider>
      <motion.div
        initial={{ opacity: 0, y: 12 }}
        animate={{ opacity: 1, y: 0 }}
        transition={{ duration: 0.35, ease: "easeOut" }}
      >
        <DashboardInner />
      </motion.div>
    </DashboardProvider>
  );
}
