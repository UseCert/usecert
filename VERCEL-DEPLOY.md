# Deploying this front-end on Vercel

**Summary: no code change is required. Do not remove the Lovable config.**

Vercel ships a first-class framework preset for exactly this stack —
`tanstack-start-lovable`, "TanStack Start … imported from Lovable" — and its detector keys on
the Lovable package itself. Ripping the wrapper out to "de-Lovable" the app would *lose*
native support, not gain it.

Everything below was verified by reading the installed code and Vercel's builder source, not
inferred from documentation prose. Line references are to the versions pinned in `bun.lock`.

---

## 1. What to do

1. Import `Chrissou78/usecertlah` as a new Vercel project.
2. **Root Directory:** `.` (the app is at the repo root).
3. **Production Branch:** `main`. It carries the testnet wiring as of 2026-09-23 — it was
   the unwired Lovable export until then, and this line said so. `frontend/testnet-wiring`
   is where that work lands first and is the same commit; `backend/contracts-c1` is the
   Solidity backend, an unrelated history in the same repo, and is not deployable as a
   front-end.
4. Leave Framework Preset, Build Command, Output Directory and Install Command **on their
   auto-detected defaults**. Override nothing.
5. **Environment variables: none.** There are no `VITE_*` references anywhere in `src/`; all
   chain configuration is compiled in from `src/chain/config.ts`.

That is the whole procedure. No `vercel.json` is needed, and this repo deliberately does not
ship one — see §4.

---

## 2. Why it already works — the four links in the chain

The apparent obstacle is the warning at the top of `vite.config.ts`: the wrapper bundles
`nitro` "using cloudflare as a default target", and adding plugins manually "will break the
app with duplicate plugins". That reads like a hard Cloudflare coupling. It is not. Four
independent facts make the Vercel path work untouched.

**(a) Vercel detects this exact stack.**
`@vercel/frameworks` defines the preset `tanstack-start-lovable` with:

```
detectors: { every: [ { matchPackage: '@lovable.dev/vite-tanstack-config' } ],
             some:  [ { matchPackage: '@tanstack/react-start' }, … ] }
supersedes: ['tanstack-start', 'ionic-react', 'vite']
```

Both are direct dependencies here, so detection matches, and `supersedes` means it outranks
the generic `vite` preset it would otherwise fall back to.

**(b) Every Cloudflare-specific behaviour is gated on the Lovable sandbox.**
In `@lovable.dev/vite-tanstack-config` v2.21.0, the forced `preset: "cloudflare-module"`, the
forced output layout, and `cloudflare: { nodeCompat, deployConfig }` all sit inside
`if (isSandbox)` (`dist/index.js:1139-1166`). `isSandbox` is
`process.env.LOVABLE_SANDBOX === "1" || !!process.env.DEV_SERVER__PROJECT_PATH`
(`dist/index.js:347-351`). Neither variable exists in a Vercel build, so none of that applies.

**(c) Outside the sandbox, Cloudflare is only a fallback that never fires.**
The one remaining trace is `defaultPreset: "cloudflare-module"` (`dist/index.js:1136`). Nitro
consults `defaultPreset` only under `if (!name && !preset)` — i.e. only when nothing else
resolved (`nitro/dist/_presets.mjs:1898-1901`). On Vercel something else does resolve: nitro
falls back to the std-env detected provider, which is `vercel` (driven by the `VERCEL`
environment variable Vercel sets in every build), and that matches the nitro preset whose
`_meta.stdName` is `"vercel"`. So the Cloudflare default is skipped entirely.

**(d) Nitro's Vercel output short-circuits Vercel's own output handling.**
That preset writes `{{ rootDir }}/.vercel/output` — Build Output API v3. Vercel's
`static-build` builder, *after* running the build command, checks for it and returns
immediately, with the reason stated in its own comment:

> `// If the Build Command or Framework output files according to the Build Output v3 API,`
> `// then stop processing here in static-build since the output is already in its final form.`

(`packages/static-build/src/index.ts:827-839`, detecting `.vercel/output/config.json` via
`BUILD_OUTPUT_DIR = '.vercel/output'`.) This is why the preset's nominal
`outputDirectory: 'dist'` is harmless — it is never consulted.

One supporting detail: `nitro` is already an exact devDependency at `3.0.260603-beta`, which
is precisely the minimum the wrapper requires for `defaultPreset` support. Nothing to bump.

## 3. Portability of the server entry

`vite.config.ts` redirects TanStack Start's server entry to `src/server.ts`. That file exports
a plain Web-standard `fetch(request, env, ctx)` handler and never reads `env` — no Cloudflare
bindings, no Workers-only API. It runs unmodified on the Vercel function the nitro preset
emits. There are no `wrangler.toml`, `.dev.vars`, `_headers` or `_redirects` files in the
repo; the only Cloudflare mention in the entire tree is the comment in `vite.config.ts`.

---

## 4. Why there is no `vercel.json`

Every layer above resolves correctly on its own, so a config file could only *repeat* those
defaults — and each repetition is a thing that can later disagree with reality. Pinning
`framework` in particular buys nothing: were the Lovable wrapper ever removed, detection
falls to `tanstack-start`, and fact (d) still short-circuits the output handling, so the build
keeps working. A pin would instead break if the slug were renamed.

If you nonetheless want the build spelled out explicitly, this is the faithful form:

```json
{
  "$schema": "https://openapi.vercel.sh/vercel.json",
  "framework": "tanstack-start-lovable",
  "buildCommand": "vite build"
}
```

## 5. Two things that can bite, neither of which is a code fix

**The 24-hour supply-chain guard applies on Vercel too.** `bunfig.toml` sets
`minimumReleaseAge = 86400`, so `bun install` refuses any package version published less than
a day ago. A deploy attempted shortly after a dependency bump can therefore fail at install
with an age error. The fix is to wait, never to add a `minimumReleaseAgeExcludes` entry —
that list is a reviewed security boundary, and the file says to confirm before extending it.

**Vercel's default `bun install` is not frozen.** With `bun.lock` present and Bun ≥ 1.2,
Vercel runs a bare `bun install`. Because `package.json` uses `^` ranges throughout, that
install may resolve versions *newer* than the reviewed lockfile, so the deployed bundle can
contain dependency versions that were never recorded in `bun.lock`. `minimumReleaseAge` still
blocks anything under a day old, but a package published two days ago and absent from the
lockfile would be pulled in silently.

Setting `installCommand` to `bun install --frozen-lockfile` would close that gap by failing
loudly on lockfile drift. It is left as **a deliberate open decision rather than an applied
change**, because Vercel documents that an overridden install command uses "the oldest version
of the specified package manager available in the build container" — and the text-based
`bun.lock` format requires Bun ≥ 1.2. If that override selects an older Bun 1.x, the install
breaks on the lockfile format. Confirm which Bun version the build log reports before adopting
it.

---

## 6. Relationship to Lovable

Adding Vercel does not remove the Lovable path. Inside a Lovable build, `isSandbox` is true and
the wrapper force-sets the Cloudflare preset and output layout, overriding any user-supplied
nitro options. The two targets therefore coexist, and the same commit deploys to both.
