import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import {
  Outlet,
  Link,
  createRootRouteWithContext,
  useRouter,
  HeadContent,
  Scripts,
} from "@tanstack/react-router";
import { useEffect, useMemo, useState, type ReactNode } from "react";
import { AnimatePresence } from "framer-motion";
import { WagmiProvider } from "wagmi";

import { getWagmiConfig } from "@/chain/config";
import appCss from "../styles.css?url";
import { reportLovableError } from "../lib/lovable-error-reporting";
import Layout from "@/components/Layout";
import Preloader from "@/components/Preloader";
import FilmGrain from "@/components/FilmGrain";
import ScrollToTop from "@/components/ScrollToTop";
import NotFound from "@/pages/NotFound";
import { I18nRuntime } from "@/i18n";

function NotFoundComponent() {
  return (
    <div className="flex min-h-screen items-center justify-center bg-background px-4">
      <div className="max-w-md text-center">
        <h1 className="text-7xl font-bold text-foreground">404</h1>
        <h2 className="mt-4 text-xl font-semibold text-foreground">Page not found</h2>
        <p className="mt-2 text-sm text-muted-foreground">
          The page you're looking for doesn't exist or has been moved.
        </p>
        <div className="mt-6">
          <Link
            to="/"
            className="inline-flex items-center justify-center rounded-md bg-primary px-4 py-2 text-sm font-medium text-primary-foreground transition-colors hover:bg-primary/90"
          >
            Go home
          </Link>
        </div>
      </div>
    </div>
  );
}

function ErrorComponent({ error, reset }: { error: Error; reset: () => void }) {
  console.error(error);
  const router = useRouter();
  useEffect(() => {
    reportLovableError(error, { boundary: "tanstack_root_error_component" });
  }, [error]);

  return (
    <div className="flex min-h-screen items-center justify-center bg-background px-4">
      <div className="max-w-md text-center">
        <h1 className="text-xl font-semibold tracking-tight text-foreground">
          This page didn't load
        </h1>
        <p className="mt-2 text-sm text-muted-foreground">
          Something went wrong on our end. You can try refreshing or head back home.
        </p>
        <div className="mt-6 flex flex-wrap justify-center gap-2">
          <button
            onClick={() => {
              router.invalidate();
              reset();
            }}
            className="inline-flex items-center justify-center rounded-md bg-primary px-4 py-2 text-sm font-medium text-primary-foreground transition-colors hover:bg-primary/90"
          >
            Try again
          </button>
          <a
            href="/"
            className="inline-flex items-center justify-center rounded-md border border-input bg-background px-4 py-2 text-sm font-medium text-foreground transition-colors hover:bg-accent"
          >
            Go home
          </a>
        </div>
      </div>
    </div>
  );
}

export const Route = createRootRouteWithContext<{ queryClient: QueryClient }>()({
  head: () => ({
    meta: [
      { charSet: "utf-8" },
      { name: "viewport", content: "width=device-width, initial-scale=1" },
      { title: "UseCert - On-Chain Equity Certificates" },
      {
        name: "description",
        content:
          "UseCert issues perp-backed certificates that track equity exposure fully on chain: mint, hold, stake and redeem.",
      },
      { name: "author", content: "UseCert" },
      { property: "og:title", content: "UseCert - On-Chain Equity Certificates" },
      {
        property: "og:description",
        content: "Perp-backed certificates tracking equity exposure, fully on chain.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary_large_image" },
    ],
    links: [
      {
        rel: "stylesheet",
        href: appCss,
      },
      { rel: "preconnect", href: "https://fonts.googleapis.com" },
      { rel: "preconnect", href: "https://fonts.gstatic.com", crossOrigin: "anonymous" },
      {
        rel: "stylesheet",
        href: "https://fonts.googleapis.com/css2?family=Geist:wght@400;500;600&family=Geist+Mono:wght@400;500&family=Inter:wght@400;500&display=swap",
      },
      { rel: "icon", href: "/logo.png", type: "image/png" },
    ],
  }),
  shellComponent: RootShell,
  component: RootComponent,
  notFoundComponent: NotFoundRoute,
  errorComponent: ErrorComponent,
});

function NotFoundRoute() {
  return (
    <Layout>
      <NotFound />
    </Layout>
  );
}

function RootShell({ children }: { children: ReactNode }) {
  return (
    <html lang="en">
      <head>
        <HeadContent />
        {/* Chinese chosen earlier: hold the first paint until the page is translated, so English
            does not flash. Released by I18nRuntime, or after 2.5 s whatever happens. */}
        <script
          dangerouslySetInnerHTML={{
            __html:
              "try{if(localStorage.getItem('usecert.lang')==='zh'){var d=document.documentElement;d.setAttribute('data-i18n-pending','');d.lang='zh-CN';setTimeout(function(){d.removeAttribute('data-i18n-pending')},2500)}}catch(e){}",
          }}
        />
        <style>{"html[data-i18n-pending] body{visibility:hidden}"}</style>
      </head>
      <body>
        {children}
        <Scripts />
      </body>
    </html>
  );
}

function RootComponent() {
  const { queryClient } = Route.useRouteContext();
  const [exiting, setExiting] = useState(false);
  const [loaded, setLoaded] = useState(false);

  // Built here rather than at module scope: `createConfig` runs connector and storage
  // setup, and this app is server-rendered. See src/chain/config.ts.
  const wagmiConfig = useMemo(() => getWagmiConfig(), []);

  useEffect(() => {
    const a = window.setTimeout(() => setExiting(true), 1700);
    const b = window.setTimeout(() => setLoaded(true), 2600);
    return () => {
      window.clearTimeout(a);
      window.clearTimeout(b);
    };
  }, []);

  return (
    // WagmiProvider wraps QueryClientProvider: wagmi's hooks are react-query mutations
    // and queries, so the query client must be inside. The existing QueryClientProvider
    // is reused as-is — there is only ever one.
    <WagmiProvider config={wagmiConfig}>
      <QueryClientProvider client={queryClient}>
        <AnimatePresence>
          {!loaded && <Preloader key="preloader" exiting={exiting} />}
        </AnimatePresence>
        <FilmGrain />
        <ScrollToTop />
        <I18nRuntime />
        {/* Required: nested routes render here. Removing <Outlet /> breaks all child routes. */}
        <Outlet />
      </QueryClientProvider>
    </WagmiProvider>
  );
}
