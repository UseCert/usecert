/**
 * Site language: English (the source) or Simplified Chinese.
 *
 * HOW IT WORKS, AND WHY THIS WAY. The copy lives inline in ~130 components. Rewriting every one
 * to call t() would touch the whole site at once; instead the English stays the source of truth,
 * and Chinese is a dictionary keyed by the exact English text, applied two ways:
 *
 *   1. useT() for text a component SPLITS before rendering (word/letter reveal animations). A
 *      sentence cut into word spans cannot be translated word by word, so those components
 *      translate the whole sentence first and split the result.
 *   2. <I18nRuntime/> for everything else: after hydration it walks the page's text nodes and a
 *      few attributes, swaps each exact English string for its Chinese entry, and keeps doing so
 *      as React re-renders (a MutationObserver). Values - prices, ages, block numbers, addresses -
 *      are lifted out as placeholders and put back, so "proven 21m 51s ago" is one entry.
 *
 * Anything with no dictionary entry stays in English rather than being guessed at. The choice is
 * stored per browser; switching back to English reloads, so the page is the untouched source.
 */
import { useEffect, useState, useSyncExternalStore } from "react";
import ZH from "./zh-CN.json";

export type Lang = "en" | "zh";
const KEY = "usecert.lang";
const listeners = new Set<() => void>();

function read(): Lang {
  try {
    return localStorage.getItem(KEY) === "zh" ? "zh" : "en";
  } catch {
    return "en";
  }
}

export function setLang(l: Lang) {
  try {
    localStorage.setItem(KEY, l);
  } catch {
    /* storage blocked: the choice lasts this page only */
  }
  if (l === "en") {
    window.location.reload();
    return;
  }
  listeners.forEach((f) => f());
}

export function useLang(): Lang {
  return useSyncExternalStore(
    (f) => {
      listeners.add(f);
      return () => listeners.delete(f);
    },
    read,
    () => "en",
  );
}

// ------------------------------------------------------------------ the dictionary

const EXACT = (ZH as { exact: Record<string, string> }).exact;
const TPL = (ZH as { tpl: Record<string, string> }).tpl;
/** Values that are never translated: hex addresses (full or shortened) and numbers. */
const VALUE = /0x[0-9a-fA-F]{4,}(?:…[0-9a-fA-F]+)?|\d{1,3}(?:,\d{3})+(?:\.\d+)?|\d+(?:\.\d+)?/g;

/** The Chinese for one English string, or null. Whitespace is normalised for the lookup. */
export function translate(src: string): string | null {
  const t = src.replace(/\s+/g, " ").trim();
  if (!t || !/[A-Za-z]/.test(t)) return null;
  const hit = EXACT[t];
  if (hit !== undefined) return hit;
  const vals: string[] = [];
  const key = t.replace(VALUE, (m) => {
    vals.push(m);
    return "{#}";
  });
  if (!vals.length) return null;
  const tpl = TPL[key];
  if (tpl === undefined) return null;
  return tpl.replace(/\{(\d+)\}/g, (_, i) => vals[Number(i)] ?? "");
}

/** For components that split text: translate the whole string when Chinese is on. */
export function useT(): (s: string) => string {
  const lang = useLang();
  return (s: string) => (lang === "zh" ? (translate(s) ?? s) : s);
}

/**
 * For word-reveal animations: R(text) gives the units to animate, R.sep what goes between them.
 * English: the words and a space. Chinese: the characters of the TRANSLATED sentence and nothing
 * (Chinese has no spaces, and one unbreakable span would never wrap).
 */
export function useReveal(): ((text: string) => string[]) & { sep: string } {
  const lang = useLang();
  const f = ((text: string) =>
    lang === "zh" ? Array.from(translate(text) ?? text) : text.split(" ")) as ((text: string) => string[]) & { sep: string };
  f.sep = lang === "zh" ? "" : " ";
  return f;
}

/** Units for a reveal animation: words in English, characters in Chinese (no spaces to split on). */
export function revealUnits(text: string, lang: Lang, byWord: boolean): string[] {
  if (lang === "zh") return Array.from(text);
  return byWord ? text.split(" ") : Array.from(text);
}

// ------------------------------------------------------------------ the page-wide pass

const ATTRS = ["placeholder", "title", "aria-label", "alt"] as const;
const SKIP = new Set(["SCRIPT", "STYLE", "NOSCRIPT", "CODE", "PRE", "TEXTAREA"]);
const done = new WeakMap<Text, string>(); // node -> the value we wrote, so our own writes are not redone

function inSkipped(el: Element | null): boolean {
  for (let e = el; e; e = e.parentElement) {
    if (SKIP.has(e.tagName) || e.hasAttribute("data-i18n-skip")) return true;
  }
  return false;
}

function doText(n: Text) {
  const v = n.nodeValue ?? "";
  if (done.get(n) === v) return;
  if (inSkipped(n.parentElement)) return;
  const zh = translate(v);
  if (zh === null) return;
  const lead = v.match(/^\s*/)![0];
  const trail = v.match(/\s*$/)![0];
  const out = lead + zh + trail;
  done.set(n, out);
  if (out !== v) n.nodeValue = out;
}

function doAttrs(el: Element) {
  if (inSkipped(el)) return;
  for (const a of ATTRS) {
    const v = el.getAttribute(a);
    if (!v || el.getAttribute(`data-i18n-${a}`) === v) continue;
    const zh = translate(v);
    if (zh !== null) {
      el.setAttribute(a, zh);
      el.setAttribute(`data-i18n-${a}`, zh);
    }
  }
}

function pass(root: Node) {
  if (root.nodeType === Node.TEXT_NODE) return doText(root as Text);
  if (root.nodeType !== Node.ELEMENT_NODE) return;
  doAttrs(root as Element);
  const w = document.createTreeWalker(root, NodeFilter.SHOW_TEXT | NodeFilter.SHOW_ELEMENT);
  for (let n = w.nextNode(); n; n = w.nextNode()) {
    if (n.nodeType === Node.TEXT_NODE) doText(n as Text);
    else doAttrs(n as Element);
  }
}

export function I18nRuntime() {
  const lang = useLang();
  useEffect(() => {
    document.documentElement.lang = lang === "zh" ? "zh-CN" : "en";
    const release = () => document.documentElement.removeAttribute("data-i18n-pending");
    if (lang !== "zh") {
      release();
      return;
    }
    let queued = new Set<Node>();
    let raf = 0;
    const flush = () => {
      raf = 0;
      const q = queued;
      queued = new Set();
      q.forEach((n) => n.isConnected && pass(n));
      const tt = translate(document.title);
      if (tt) document.title = tt;
    };
    const mo = new MutationObserver((ms) => {
      for (const m of ms) {
        if (m.type === "characterData") queued.add(m.target);
        else if (m.type === "attributes") queued.add(m.target);
        else m.addedNodes.forEach((n) => queued.add(n));
      }
      if (!raf) raf = requestAnimationFrame(flush);
    });
    // Route chunks hydrate after this effect runs. Rewriting their text before React has
    // hydrated them is a hydration mismatch (#418), so the first pass waits for the page to
    // finish loading and for React to commit what it loaded; the paint is held until then.
    let started = false;
    let dead = false;
    const start = () => {
      if (started) return;
      started = true;
      requestAnimationFrame(() =>
        requestAnimationFrame(() => {
          if (dead) return;
          pass(document.body);
          flush();
          mo.observe(document.body, { subtree: true, childList: true, characterData: true, attributes: true, attributeFilter: [...ATTRS] });
          release();
        }),
      );
    };
    if (document.readyState === "complete") start();
    else window.addEventListener("load", start, { once: true });
    return () => {
      started = dead = true;
      window.removeEventListener("load", start);
      mo.disconnect();
      if (raf) cancelAnimationFrame(raf);
    };
  }, [lang]);
  return null;
}

// ------------------------------------------------------------------ the switch

export function LanguageSwitcher({ className = "" }: { className?: string }) {
  const lang = useLang();
  const [mounted, setMounted] = useState(false);
  useEffect(() => setMounted(true), []);
  return (
    <label className={className} data-i18n-skip>
      <span className="sr-only">Language / 语言</span>
      <select
        id="usecert-lang"
        aria-label="Language / 语言"
        value={mounted ? lang : "en"}
        onChange={(e) => setLang(e.target.value as Lang)}
        className="cursor-pointer border hairline-dark bg-ink px-2 py-2 font-mono text-[11px] uppercase tracking-[0.06em] text-white outline-none focus:border-green-bright"
      >
        <option value="en">EN</option>
        <option value="zh">中文</option>
      </select>
    </label>
  );
}
