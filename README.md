# BetterDeathRecap

A World of Warcraft (retail / *Midnight*) addon that replaces Blizzard's poor
built-in death recap with a clean, readable custom UI.

BetterDeathRecap is a **display layer** on top of Blizzard's `C_DeathRecap` API.
Blizzard collects the death data; we render it well. It does **not** parse the
combat log — addons cannot access CLEU on Midnight, which is exactly why the
dominant death-analysis addon has gone dark and why this niche is open.

The one thing `C_DeathRecap` does not provide is a health-over-time curve, so we
supplement it with lightweight, event-driven `UNIT_HEALTH` sampling.

## Features

- **Killing-blow banner** — answers "what killed me?" at a glance.
- **HP curve** — health over the last few seconds, with a filled area and a
  line that shifts green → amber → red as your health drops.
- **Hit timeline** — every hit with a spell-icon swatch, relative timestamp,
  and damage, with the killing blow pinned and highlighted (overkill + absorbs).
- **Damage-source bars** — shows whether one mob or a pile-on killed you.
- **Context footer** — difficulty · zone · window length.

## Design principles

- **Near-zero performance cost.** The only always-on events are `PLAYER_DEAD`,
  `PLAYER_ENTERING_WORLD`, and an event-driven `UNIT_HEALTH` registered for the
  player. No combat-log parsing, no per-frame polling.
- **Read-only & ban-safe.** Only reads data Blizzard explicitly exposes.
- **Self-contained.** No dependency on Details! or any other addon.
- **Small.** A few hundred lines across focused modules.

## Slash commands

| Command          | Action                                            |
| ---------------- | ------------------------------------------------- |
| `/bdr`           | Toggle the window (shows the last report if any). |
| `/bdr test`      | Render the built-in sample report (UI preview).   |
| `/bdr history`   | Show the most recent saved death.                 |
| `/bdr lock`      | Lock the window in place.                         |
| `/bdr unlock`    | Allow drag-to-move.                               |

## Installation

Download the latest release and unzip it into
`World of Warcraft/_retail_/Interface/AddOns/`. The folder dropped in must be
named `BetterDeathRecap`.

### Building from source

```sh
make lint       # luacheck all Lua under src/
make build      # produce dist/<version>.zip
make deploy     # install into the live client (override with DEST=...)
```

## License

[MIT](LICENSE.md) © Akis Idrizi
