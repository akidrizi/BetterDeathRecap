---
name: wow-addon-maintenance
description: >
  Maintain a library-free World of Warcraft addon to its house style: add
  user-visible strings the RIGHT way (define in the English L_enUS base, then fan
  the key out as translated overrides into every other locale table that exists
  in Locale.lua), keep functions single-responsibility and modular, and audit for
  dead code — locale keys, DB keys, constants, .toc/.luacheckrc globals — and
  orphaned media, then remove them and sync the package.sh + pkgmeta.yaml exclude
  lists. Use this whenever working on an EXISTING WoW addon in this style and the
  user wants to: add or change a displayed/localized string or message, add a new
  feature module or function the modular way, clean up / find unused or dead code,
  shrink the shipped package, fix luacheck "unused" noise, translate strings, or
  check the addon follows its conventions. Triggers on "add a string", "localize",
  "translate", "find unused", "dead code", "audit", "clean up the addon",
  "is this following our conventions". For creating a NEW addon from scratch, use
  wow-addon-scaffold instead.
---

# Maintain a WoW Addon (house style)

Enforce the library-free, single-responsibility conventions on an existing addon.
Three jobs live here: **localized strings**, **modular code**, and the
**dead-code/media audit**. Read `references/conventions.md` for the full rule set
and the rationale; this file is the operating procedure.

First, orient: the project's own `CLAUDE.md` is the source of truth for *that*
addon (file responsibilities, DB schema, namespace). Skim it before changing
anything, and reconcile it after — a stale `CLAUDE.md` is itself a defect.

## Job 1 — Add or change a localized string

Never hardcode user-visible text. Every displayed string is a key in
`src/Locale.lua`. The model is: **`L_enUS` is the authoritative contract** (every
key defined), and each other language is a table metatabled to fall back to it, so
a missing translation shows English instead of erroring.

To add a string:

1. **Read `src/Locale.lua` and discover which locale tables exist.** They look
   like `local L_deDE = setmetatable({ … }, { __index = L_enUS })`. The set varies
   per project — *read it, don't assume*. (A typical full set is
   deDE/frFR/esES/ruRU/ptBR/itIT with esMX routed to esES, but confirm.)
2. **Add the key to `L_enUS` first.** Uppercase `SNAKE_CASE`. If it carries a
   `%s`/`%d` placeholder, comment what the placeholder is. Description-style keys
   (`*_DESC`, `HELP_*`) carry **no color codes** — the caller adds color.
3. **Translate it into every other locale table.** Add an override line to each.
   Only add keys whose translation differs from English; if a language genuinely
   reuses the English word, you may omit it and let the fallback handle it — but
   for a normal sentence, translate it. Match the existing house format (aligned
   `=`, the project's quoting and concatenation style for long lines).
4. **Reference it in code** as `Addon.L.KEY` (often aliased `local L = Addon.L`).
   Wrap with `Addon.COLOR.*` … `RESET` if it needs color — never inline hex.
5. **If you remove a string**, remove it from `L_enUS` *and* every locale table.
   An override left in a non-English table after the enUS key is gone is dead (the
   audit flags it).

To change wording: update `L_enUS` and re-check each translation still matches the
new meaning; update the ones that drifted.

## Job 2 — Add a feature module or function (modular)

The core rule is **one responsibility per function**. When asked to add behavior,
resist writing one big function — decompose into a lookup, a decision, and an
effect, composed at the call site. Example from this style: "what roles can the
class do" / "what did the user pick" / "resolve those into what to apply" /
"apply it" are four functions, so the resolver can change without touching the
applier.

- A new module is `src/<Feature>.lua` exposing `Addon.<Feature> = {}` plus public
  functions; file-private helpers stay `local function`.
- Add the file to the `.toc` (alphabetical), and call its init from `Core.lua`'s
  `ADDON_LOADED` handler. **No cross-module calls at load time** — only inside
  function bodies (that's why alphabetical load order is safe).
- Any new WoW global the code now touches must be added to `.luacheckrc` `globals`.
  Any global whose last reference you just removed must come *out*. Run
  `luacheck src/` — it must pass.

## Job 3 — Audit for dead code & orphaned media

luacheck finds unused *locals*. It does not find unused locale keys, DB keys,
constants, `.luacheckrc` globals, or orphaned media. The bundled script does.

### Run it

```bash
bash scripts/audit-unused.sh <project-root>
```

It reports (never edits) five categories:
- **Locale keys** in `L_enUS` referenced nowhere; and keys in a non-English table
  **missing from `L_enUS`** (unreachable — English is the contract).
- **DB keys** defaulted/written but never read via `Get`/`Set`.
- **Constants** (`COLOR.*`) never referenced.
- **`.luacheckrc` globals** with no reference left in `src/`.
- **Media** files referenced by nothing in `src/` or the `.toc`.

Exit code 0 = clean, 1 = findings. Good to wire into CI alongside luacheck.

### Act on findings (report → confirm → fix)

1. **Present the findings** to the user grouped by category. The script is a
   heuristic — verify each before deleting. Two known limitations to double-check
   by hand:
   - It counts a token reference anywhere, so a key that *looks* used by string
     coincidence could be a false negative. Confirm with a quick Grep on the exact
     symbol when in doubt.
   - Media matching is by basename **and** extension-less stem, so a dev duplicate
     like `icon.png` sitting next to a shipped `icon.jpg` won't flag (the stem
     "icon" is referenced by the `.toc`). Eyeball `media/` for such duplicates.
2. **On the user's confirmation, remove the dead symbols:** delete the locale key
   from `L_enUS` and every locale table; delete the DB key from `DEFAULTS` (and add
   a one-line `nil`-out in the schema migration if old saved data may carry it);
   delete the constant; remove the `.luacheckrc` global line.
3. **For orphaned media**, the user's choice is delete-from-repo *or*
   keep-but-don't-ship. To stop shipping without deleting, add the path to **both**
   exclude lists — `package.sh` `EXCLUDES` and `pkgmeta.yaml` `ignore` — and keep
   them byte-identical (the script's output tells you which list already has it).
   If the file is truly unused dev cruft, deleting it is cleaner than excluding it.
4. **Re-run** `bash scripts/audit-unused.sh` and `luacheck src/`; both should come
   back clean. Then reconcile the project's `CLAUDE.md` if any documented symbol,
   media file, or DB key changed.

## Reference

- `references/conventions.md` — the full house style: namespace via `...`, load
  order, the localization model, single-responsibility, the "no dead anything"
  rule, and the three sync-pairs (`.toc`↔`src/`, `.luacheckrc`↔code,
  `package.sh`↔`pkgmeta.yaml`). Read it to settle any "is this the right way" call.
