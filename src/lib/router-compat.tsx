/**
 * Thin compatibility layer so pages authored against react-router keep working
 * on TanStack Router (the router used by this project).
 */
import {
  Link as TanstackLink,
  Navigate as TanstackNavigate,
  Outlet,
  useLocation as useTanstackLocation,
  useNavigate as useTanstackNavigate,
  useParams as useTanstackParams,
} from "@tanstack/react-router";
import type { AnchorHTMLAttributes, ReactElement } from "react";

/* eslint-disable @typescript-eslint/no-explicit-any */

export { Outlet };

export function Link(props: AnchorHTMLAttributes<HTMLAnchorElement> & { to: string }) {
  const Cmp = TanstackLink as any;
  return <Cmp {...(props as any)} /> as ReactElement;
}

export function Navigate({ to, replace }: { to: string; replace?: boolean }) {
  const Cmp = TanstackNavigate as any;
  return <Cmp to={to} replace={replace} /> as ReactElement;
}

export function useLocation() {
  return useTanstackLocation();
}

export function useNavigate() {
  const navigate = useTanstackNavigate();
  return (to: string, options?: { replace?: boolean }) =>
    navigate({ to, replace: options?.replace } as any);
}

export function useParams<
  T extends Record<string, string | undefined> = Record<string, string | undefined>,
>(): T {
  return (useTanstackParams as any)({ strict: false }) as T;
}
