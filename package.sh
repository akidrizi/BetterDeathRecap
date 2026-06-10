#!/usr/bin/env bash
# package.sh — build a release zip OR deploy BetterDeathRecap to the live client.
#
# This is the SINGLE SOURCE OF TRUTH for what ships: the EXCLUDES list below
# defines the runtime file set, and both modes build the exact same staging
# tree from it, so a local deploy is byte-identical to the released zip.
#
# Usage:
#   ./package.sh                 Build dist/<version>.zip (release artifact).
#   ./package.sh --deploy        Install into the live WoW AddOns folder.
#   ./package.sh -d --dest DIR   Deploy into a specific AddOns directory.
#
# Deploy destination (first match wins):
#   1. --dest <addons-dir>        e.g. ".../World of Warcraft/_retail_/Interface/AddOns"
#   2. $WOW_ADDONS_DIR            environment variable
#   3. DEFAULT_ADDONS_DIR         the fallback below
#
# ⚠ Keep the EXCLUDES list in sync with the ignore list in pkgmeta.yaml
#   (used by the CurseForge/Wago packager).
set -euo pipefail

# Default live-client AddOns directory (Git Bash path style). Override per-run
# with --dest or the $WOW_ADDONS_DIR env var rather than editing this.
DEFAULT_ADDONS_DIR="/c/Program Files (x86)/World of Warcraft/_retail_/Interface/AddOns"

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
DEPLOY=false
DEST_ADDONS=""

usage() {
    sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--deploy) DEPLOY=true; shift ;;
        --dest)      DEST_ADDONS="${2:-}"; shift 2 ;;
        -h|--help)   usage; exit 0 ;;
        *)           echo "ERROR: unknown option '$1' (try --help)." >&2; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Resolve version from the .toc file
# ---------------------------------------------------------------------------
TOC="BetterDeathRecap.toc"

if [[ ! -f "$TOC" ]]; then
    echo "ERROR: $TOC not found. Run this script from the project root." >&2
    exit 1
fi

VERSION=$(grep -E "^## Version:" "$TOC" | awk '{print $NF}')

if [[ -z "$VERSION" ]]; then
    echo "ERROR: Could not read ## Version: from $TOC." >&2
    exit 1
fi

if $DEPLOY; then
    echo "BetterDeathRecap — deploying ${VERSION} …"
else
    echo "BetterDeathRecap — building ${VERSION} …"
fi

# ---------------------------------------------------------------------------
# Staging — build the runtime tree once; both modes consume it.
# ---------------------------------------------------------------------------
DIST="dist"
STAGING="$DIST/BetterDeathRecap"

rm -rf "$DIST"
mkdir -p "$STAGING"

# Files/dirs to exclude from the shipped addon (release zip AND live deploy).
# This is the single source of truth — release.yml delegates here via ./package.sh.
# ⚠ Keep in sync with the ignore list in pkgmeta.yaml.
EXCLUDES=(
    '.git'
    '.github'
    '.idea'
    'docs'
    'dist'
    'CLAUDE.md'
    'PLAN.md'
    '.editorconfig'
    '.gitattributes'
    '.gitignore'
    '.luacheckrc'
    'Makefile'
    'package.sh'
    'pkgmeta.yaml'
    '*.zip'
    '*.tar.gz'
)

# Copy the source tree into staging, honoring EXCLUDES (rsync, with a tar
# fallback so the script works on machines without rsync).
if command -v rsync >/dev/null 2>&1; then
    RSYNC_EXCLUDES=()
    for ex in "${EXCLUDES[@]}"; do RSYNC_EXCLUDES+=("--exclude=$ex"); done
    rsync -a "${RSYNC_EXCLUDES[@]}" . "$STAGING/"
else
    echo "(rsync not found — using tar fallback)"
    TAR_EXCLUDES=()
    for ex in "${EXCLUDES[@]}"; do TAR_EXCLUDES+=("--exclude=$ex"); done
    tar "${TAR_EXCLUDES[@]}" -cf - . | tar -C "$STAGING" -xf -
fi

# ---------------------------------------------------------------------------
# Deploy mode — copy the staged tree into the live client
# ---------------------------------------------------------------------------
if $DEPLOY; then
    ADDONS_DIR="${DEST_ADDONS:-${WOW_ADDONS_DIR:-$DEFAULT_ADDONS_DIR}}"

    if [[ ! -d "$ADDONS_DIR" ]]; then
        echo "ERROR: AddOns directory not found:" >&2
        echo "  $ADDONS_DIR" >&2
        echo "Set the right path with --dest <addons-dir> or \$WOW_ADDONS_DIR." >&2
        exit 1
    fi

    TARGET="$ADDONS_DIR/BetterDeathRecap"

    # Staging is fully built before we touch the live folder, so a build
    # failure can never leave the installed addon half-wiped.
    if [[ -d "$TARGET" ]]; then
        echo "Removing existing $TARGET …"
        rm -rf "$TARGET"
    fi
    mkdir -p "$TARGET"
    cp -a "$STAGING/." "$TARGET/"

    echo ""
    echo "  Deployed to : $TARGET"
    echo ""
    echo "Done. Reload the client (or /reload) to pick it up."
    exit 0
fi

# ---------------------------------------------------------------------------
# Package mode — zip (top-level folder inside the archive must be "BetterDeathRecap")
# ---------------------------------------------------------------------------
ZIPFILE="${VERSION}.zip"

cd "$DIST"
zip -r "$ZIPFILE" BetterDeathRecap/
cd ..

echo ""
echo "  Output  : dist/${ZIPFILE}"
echo "  Install : unzip into World of Warcraft/_retail_/Interface/AddOns/"
echo ""
echo "Done."
