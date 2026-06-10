# Changelog

All notable changes to BetterDeathRecap are documented here.
This project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- Initial release of BetterDeathRecap — a clean, readable replacement for
  Blizzard's built-in death recap, built as a display layer over the
  `C_DeathRecap` API.
- Killing-blow banner answering "what killed me" at a glance.
- HP-over-time curve (filled area + colour-shifting polyline) sampled from
  lightweight, event-driven `UNIT_HEALTH` tracking.
- Hit timeline with spell-icon swatches, relative timestamps, and a pinned,
  highlighted killing-blow row with overkill/absorb annotations.
- Damage-source bars showing each attacker's share of the damage.
- Context footer (difficulty · zone · window length).
- Slash commands: `/bdr`, `/bdr test`, `/bdr history`, `/bdr lock`, `/bdr unlock`.
- SavedVariables: window position, lock state, and the last death report.
- `/bdr test` renders a built-in sample report so the UI can be reviewed
  without dying in-game.
