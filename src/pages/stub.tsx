import Vaults from "./Vaults";
import VaultDetail from "./VaultDetail";
import Legal from "./Legal";

export { default as LearnStub } from "./Learn";
export { default as ArticleStub } from "./Article";
export { default as NotFoundStub } from "./NotFound";

export function PrivacyStub() {
  return <Legal doc="privacy-policy" />;
}

export function TermsStub() {
  return <Legal doc="terms-of-service" />;
}

// Vaults pages are implemented: route stubs delegate to the real pages.
export function VaultsStub() {
  return <Vaults />;
}

export function VaultDetailStub() {
  return <VaultDetail />;
}

export { default as AboutStub } from "./About";
export { default as RolesStub } from "./Roles";

export { default as DashboardStub } from "./Dashboard";


