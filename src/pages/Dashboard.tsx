import { AnimatePresence, motion } from "framer-motion";
import { DashboardProvider, useDashboard } from "./dashboard/store";
import { TopBar, Sidebar, BottomTabs, FooterBar } from "./dashboard/chrome";
import { WalletModal } from "./dashboard/modals";
import ToastStack from "./dashboard/Toasts";
import Overview from "./dashboard/Overview";
import VaultsView from "./dashboard/VaultsView";
import MintRedeem from "./dashboard/MintRedeem";
import StakingView from "./dashboard/StakingView";
import ActivityView from "./dashboard/ActivityView";
import KeepersView from "./dashboard/KeepersView";

function ViewRouter() {
  const { view } = useDashboard();
  switch (view) {
    case "vaults":
      return <VaultsView />;
    case "mint":
      return <MintRedeem />;
    case "staking":
      return <StakingView />;
    case "activity":
      return <ActivityView />;
    case "keepers":
      return <KeepersView />;
    default:
      return <Overview />;
  }
}

function DashboardInner() {
  const { view } = useDashboard();
  return (
    <div className="min-h-[100dvh] bg-abyss text-white">
      {/* Faint blueprint hairline grid for depth */}
      <div
        aria-hidden
        className="pointer-events-none fixed inset-0 z-[1]"
        style={{
          backgroundImage:
            "linear-gradient(rgba(255,255,255,0.035) 1px, transparent 1px), linear-gradient(90deg, rgba(255,255,255,0.035) 1px, transparent 1px)",
          backgroundSize: "120px 120px",
          maskImage: "radial-gradient(80% 70% at 50% 30%, black 30%, transparent 100%)",
          WebkitMaskImage: "radial-gradient(80% 70% at 50% 30%, black 30%, transparent 100%)",
        }}
      />

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

      {/* Ambient sage glow, same atmosphere as the landing deep sections; slowly breathes */}
      <motion.div
        aria-hidden
        className="pointer-events-none fixed inset-0 z-[1]"
        style={{
          background:
            "radial-gradient(55% 38% at 82% 0%, rgba(133,152,133,0.12), transparent 70%), radial-gradient(38% 30% at 8% 100%, rgba(133,152,133,0.07), transparent 70%)",
        }}
        animate={{ opacity: [1, 0.65, 1] }}
        transition={{ duration: 9, repeat: Infinity, ease: "easeInOut" }}
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
      <ToastStack />
    </div>
  );
}

/**
 * /dashboard: UseCert protocol dashboard. Fully self-contained app chrome
 * (own sidebar + topbar, no landing Layout/Navbar/Footer), frontend-only
 * with a live mock data engine.
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
