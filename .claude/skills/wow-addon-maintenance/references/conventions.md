# Conventions — the house style this skill enforces

The rules a library-free addon in this style must hold to. The project's own
`CLAUDE.md` is authoritative for project-specific facts (which modules exist, the
DB schema, the exact locale set); this doc is the general law.

## Namespace via the `...` vararg

WoW calls each addon file as `(addonName, sharedTable)`. The same table is passed
to every file, and it is the addon's entire public surface:

```lua
local _, Addon = ...          -- most files
local addonName, Addon = ...  -- when the literal name is needed
```

No `LibStub`, no Ace, no `_G` writes beyond the `.toc`-declared SavedVariable and
the `SLASH_*` globals + `SlashCmdList`. File-private = `local`; public =
`Addon.Thing`. If you find yourself reaching for a global to pass state between
files, use the shared table instead.

## Load order is alphabetical — keep it safe

The `.toc` lists `src/` files alphabetically. This only works because **no file
calls another module's function at load time.** Load time *defines*
(`Addon.Foo = {}`, `function Addon.Foo.Bar() end`); anything that *calls* across
modules runs inside a function body, after `ADDON_LOADED`, when all files exist.
Breaking this gives load-order-dependent nil errors. If you need load-time
cross-module work, move it into an init function called from `Core.lua`.

## Localization model

One `src/Locale.lua`. `L_enUS` is the **authoritative contract** — every key is
defined there. Other languages are tables metatabled to fall back:

```lua
local L_xxXX = setmetatable({ KEY = "translation" }, { __index = L_enUS })
```

Consequences that drive the rules:
- A translator only overrides keys that differ; untranslated keys show English,
  never nil.
- A key in a non-English table that is **not** in `L_enUS` is unreachable dead
  code — English is the contract, so nothing ever asks for that key. Remove it.
- Adding a string = add to `L_enUS` first, then fan out overrides. Removing one =
  remove from `L_enUS` *and* every override table.
- A `GetLocale()` router at the bottom selects the table; it defaults to `L_enUS`.
  When you add a new language table, add its routing branch too (and remember
  `esMX` conventionally routes to `esES`).

This is intentionally *not* AceLocale (`NewLocale`/`GetLocale` per-file
registration). Don't "fix" it toward Ace.

## One responsibility per function

The modularity rule that matters most. Keep lookups, decisions, and side effects
in separate, well-named functions that compose at the call site. This is what lets
one behavior change without disturbing its neighbors. When a function grows a
second job ("…and also writes the DB", "…and also updates the UI"), split it.

## No dead anything

Every locale key, DB key, constant, color, `.toc`/`.luacheckrc` global, function,
and media file must be referenced. luacheck handles unused *locals* only;
`scripts/audit-unused.sh` handles the rest. Dead symbols are removed, not left
"just in case" — version control is the safety net.

## The three sync-pairs

The most common source of rot. Check these whenever the relevant files change:

1. **`.toc` src list ↔ files in `src/`.** A `.lua` not listed never loads; a
   listed file that doesn't exist errors on login.
2. **`.luacheckrc` `globals` ↔ WoW globals referenced in code.** Too few → CI
   fails on "accessing undefined global". Too many → you're masking dead
   references. The list doubles as documentation of which Blizzard APIs the addon
   touches; keep it honest.
3. **`package.sh` `EXCLUDES` ↔ `pkgmeta.yaml` `ignore`.** `package.sh` governs the
   local zip and `--deploy`; `pkgmeta.yaml` governs the CurseForge/Wago packager.
   If they disagree the addon ships differently per channel. Keep the two lists
   identical.

## Output & color discipline

`Print` for the signature-colored `[Addon]` chat line; `Warn` (red) for genuine
problems. Normal operation is near-silent. Colors come from `Addon.COLOR` and
every colored span closes with `RESET`; never hardcode hex outside `Constants.lua`.
