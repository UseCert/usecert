/**
 * Thin compatibility layer so pages authored against react-router keep working
 * on TanStack Router (the router used by this project).
 */
import {
  Link as TanstackLink,
  Navigate as TanstackNavigate,
  useLocation as useTanstackLocation,
  useNavigate as useTanstackNavigate,
  useParams as useTanstackParams,
} from "@tanstack/react-router";
import type { ComponentProps } from "react";

type AnyProps = Record<string, unknown>;

export function Link(props: ComponentProps<"a"> & { to: string }) {
  const Cmp = TanstackLink as unknown as (p: AnyProps) => JSX.Element;
  return <Cmp {...(props as AnyProps)} />;
}

export function Navigate({ to, replace }: { to: string; replace?: boolean }) {
  const Cmp = TanstackNavigate as unknown as (p: AnyProps) => JSX.Element;
  return <Cmp to={to} replace={replace} />;
}

export function useLocation() {
  return useTanstackLocation();
}

export function useNavigate() {
  const navigate = useTanstackNavigate();
  return (to: string, options?: { replace?: boolean }) =>
    navigate({ to, replace: options?.replace } as never);
}

export function useParams<T extends Record<string, string | undefined>>(): T {
  return useTanstackParams({ strict: false }) as T;
}
