import { Link } from "react-router";
import type { ReactNode } from "react";
import { cn } from "@/lib/utils";

type Variant = "primary" | "black" | "white" | "outline";

const variantClasses: Record<Variant, string> = {
  // Solid green-bright, ink text. Hover layer: green-deep bg, white text.
  primary: "bg-green-bright text-ink",
  black: "bg-ink text-white",
  white: "bg-white text-ink",
  outline: "bg-transparent text-white border border-hairline-dark",
};

const hoverLayerClasses: Record<Variant, string> = {
  primary: "bg-green-deep text-white",
  black: "bg-green-deep text-white",
  white: "bg-green-bright text-ink",
  outline: "bg-green-deep text-white border-green-deep",
};

interface SwapButtonProps {
  label: string;
  to?: string;
  href?: string;
  onClick?: () => void;
  variant?: Variant;
  className?: string;
  icon?: ReactNode;
  fullWidth?: boolean;
  disabled?: boolean;
  title?: string;
}

/**
 * Template signature button: two-layer label swap on hover
 * (duplicate text node slides up into view, 0.25s ease), 2% scale-down on tap.
 */
export default function SwapButton({
  label,
  to,
  href,
  onClick,
  variant = "primary",
  className,
  icon,
  fullWidth,
  disabled,
  title,
}: SwapButtonProps) {
  const inner = (
    <span className="relative block overflow-hidden">
      <span className="flex items-center justify-center gap-2 px-8 py-[18px] text-[12px] font-semibold uppercase tracking-[0.08em] transition-transform duration-250 ease-out group-hover:-translate-y-full">
        {icon}
        {label}
      </span>
      <span
        aria-hidden
        className={cn(
          "absolute inset-0 flex translate-y-full items-center justify-center gap-2 px-8 py-[18px] text-[12px] font-semibold uppercase tracking-[0.08em] transition-transform duration-250 ease-out group-hover:translate-y-0",
          hoverLayerClasses[variant],
        )}
      >
        {icon}
        {label}
      </span>
    </span>
  );

  const classes = cn(
    "group inline-block select-none active:scale-[0.98] transition-transform",
    variantClasses[variant],
    fullWidth && "w-full",
    fullWidth && "[&>span]:w-full",
    disabled && "opacity-50 pointer-events-none",
    className,
  );

  if (to) {
    return (
      <Link to={to} className={classes} title={title} onClick={onClick}>
        {inner}
      </Link>
    );
  }
  if (href) {
    return (
      <a href={href} target="_blank" rel="noreferrer" className={classes} title={title} onClick={onClick}>
        {inner}
      </a>
    );
  }
  return (
    <button type="button" className={classes} title={title} onClick={onClick} disabled={disabled}>
      {inner}
    </button>
  );
}
