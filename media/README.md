# media/

Addon art ships from here (it is **not** excluded by the packager).

Expected assets (add as they are produced):

- `icon.tga` / `icon.png` — addon icon referenced by `## IconTexture` in the
  `.toc` (drop the extension in the `.toc` path).
- `minimap_64.png` — 64px minimap button icon.
- `banner.png` — CurseForge/Wago store banner.

Until real art exists the addon loads fine without it; `## IconTexture` simply
points at nothing and WoW falls back to the default addon icon.
