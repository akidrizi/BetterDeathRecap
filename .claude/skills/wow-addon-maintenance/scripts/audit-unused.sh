#!/usr/bin/env bash
# audit-unused.sh — find dead symbols & orphaned media in a library-free WoW addon.
#
# luacheck catches unused *locals*. It does NOT catch:
#   • locale keys defined in L_enUS but referenced nowhere
#   • locale keys present in a non-English table but MISSING from L_enUS (dead —
#     English is the contract; these can never be reached)
#   • DB keys that are written/defaulted but never read
#   • Constants (COLOR.* and other Constants.lua fields) never referenced
#   • .luacheckrc globals with no remaining reference in src/
#   • media files referenced by nothing in src/ or the .toc
#
# This script REPORTS only — it never edits. The wow-addon-maintenance skill
# decides what to remove and (for orphaned media) syncs package.sh + pkgmeta.yaml.
#
# Usage:  bash audit-unused.sh [project-root]   (default: current directory)
# Exit:   0 = clean, 1 = findings, 2 = usage/setup error.

set -uo pipefail

ROOT="${1:-.}"
cd "$ROOT" || { echo "ERROR: cannot cd into '$ROOT'." >&2; exit 2; }

# Prefer ripgrep; fall back to grep -r.
if command -v rg >/dev/null 2>&1; then
    search() { rg -n --no-heading "$@"; }
    count()  { rg -c --no-filename "$@" 2>/dev/null | awk '{s+=$1} END{print s+0}'; }
else
    search() { grep -rn "$@"; }
    count()  { grep -rho "$@" 2>/dev/null | wc -l | tr -d ' '; }
fi

SRC="src"
[[ -d "$SRC" ]] || { echo "ERROR: no src/ directory under '$ROOT'." >&2; exit 2; }

TOC=$(find . -maxdepth 1 -name '*.toc' | head -n1)
[[ -n "$TOC" ]] || echo "WARN: no .toc found in root — skipping .toc-related checks." >&2

LOCALE="$SRC/Locale.lua"
DBFILE="$SRC/Database.lua"
CONSTS="$SRC/Constants.lua"
LUACHECKRC=".luacheckrc"
MEDIA="media"
PKGSH="package.sh"
PKGMETA="pkgmeta.yaml"

FINDINGS=0
section() { echo ""; echo "── $1 ──────────────────────────────────────────"; }
flag()    { echo "  [DEAD] $1"; FINDINGS=$((FINDINGS+1)); }

# Count references to a token across src/, optionally excluding one file.
# $1 = token (literal), $2 = file to exclude (optional)
refs_in_src() {
    local token="$1" exclude="${2:-}"
    local files=()
    while IFS= read -r f; do
        [[ "$f" == "$exclude" ]] && continue
        files+=("$f")
    done < <(find "$SRC" -name '*.lua')
    [[ ${#files[@]} -eq 0 ]] && { echo 0; return; }
    if command -v rg >/dev/null 2>&1; then
        rg -F -c --no-filename "$token" "${files[@]}" 2>/dev/null | awk '{s+=$1} END{print s+0}'
    else
        grep -Fho "$token" "${files[@]}" 2>/dev/null | wc -l | tr -d ' '
    fi
}

# Extract KEY names from a `local L_xxXX = { ... }` (or setmetatable({ ... })) block.
# $1 = file, $2 = block-start regex anchor (e.g. 'local L_enUS')
locale_keys() {
    local file="$1" anchor="$2"
    awk -v anchor="$anchor" '
        $0 ~ anchor { grab=1 }
        grab && /^}/ { grab=0 }                       # close at column-0 }
        grab && match($0, /^[[:space:]]+[A-Z][A-Z0-9_]*[[:space:]]*=/) {
            line=$0; sub(/[[:space:]]*=.*/, "", line); gsub(/[[:space:]]/, "", line); print line
        }
    ' "$file"
}

# ── 1. Locale keys ──────────────────────────────────────────────────────────
if [[ -f "$LOCALE" ]]; then
    section "Locale keys (src/Locale.lua)"

    EN_KEYS=$(locale_keys "$LOCALE" 'local L_enUS')

    # 1a. enUS keys referenced nowhere else.
    while IFS= read -r key; do
        [[ -z "$key" ]] && continue
        n=$(refs_in_src ".$key" "$LOCALE")
        # also catch L["KEY"] style
        b=$(refs_in_src "\"$key\"" "$LOCALE")
        if [[ "$n" -eq 0 && "$b" -eq 0 ]]; then
            flag "locale key never used: $key"
        fi
    done <<< "$EN_KEYS"

    # 1b. keys in a non-English table but absent from L_enUS (unreachable / dead).
    OTHER_KEYS=$(grep -oE 'local L_[a-z]{2}[A-Z]{2}' "$LOCALE" | sed 's/local //' | sort -u)
    while IFS= read -r tbl; do
        [[ -z "$tbl" ]] && continue
        while IFS= read -r key; do
            [[ -z "$key" ]] && continue
            if ! grep -qxF "$key" <<< "$EN_KEYS"; then
                flag "locale key '$key' in $tbl is missing from L_enUS (English is the contract)"
            fi
        done < <(locale_keys "$LOCALE" "local $tbl")
    done <<< "$OTHER_KEYS"
else
    echo "WARN: $LOCALE not found — skipping locale check." >&2
fi

# ── 2. DB keys ──────────────────────────────────────────────────────────────
if [[ -f "$DBFILE" ]]; then
    section "Database keys (src/Database.lua)"
    # Keys defined in the DEFAULTS table + any DB[...] = assignments in migrations.
    DB_KEYS=$(awk '
        /local DEFAULTS = {/ { grab=1 }
        grab && /^}/ { grab=0 }
        grab && match($0, /^[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*=/) {
            line=$0; sub(/[[:space:]]*=.*/, "", line); gsub(/[[:space:]]/, "", line); print line
        }
    ' "$DBFILE" | grep -v '^schemaVersion$')
    while IFS= read -r key; do
        [[ -z "$key" ]] && continue
        n=$(refs_in_src "\"$key\"" "$DBFILE")
        if [[ "$n" -eq 0 ]]; then
            flag "DB key defaulted but never read via Get/Set: $key"
        fi
    done <<< "$DB_KEYS"
else
    echo "WARN: $DBFILE not found — skipping DB check." >&2
fi

# ── 3. Constants (COLOR.* fields) ───────────────────────────────────────────
if [[ -f "$CONSTS" ]]; then
    section "Constants (src/Constants.lua COLOR fields)"
    COLOR_KEYS=$(awk '
        /COLOR = {/ { grab=1 }
        grab && /^}/ { grab=0 }
        grab && match($0, /^[[:space:]]+[A-Z][A-Z0-9_]*[[:space:]]*=/) {
            line=$0; sub(/[[:space:]]*=.*/, "", line); gsub(/[[:space:]]/, "", line); print line
        }
    ' "$CONSTS")
    while IFS= read -r key; do
        [[ -z "$key" ]] && continue
        n=$(refs_in_src ".$key" "$CONSTS")
        if [[ "$n" -eq 0 ]]; then
            flag "COLOR.$key defined but never used"
        fi
    done <<< "$COLOR_KEYS"
fi

# ── 4. .luacheckrc globals ──────────────────────────────────────────────────
if [[ -f "$LUACHECKRC" ]]; then
    section ".luacheckrc globals vs code references"
    GLOBALS=$(awk '
        /globals = {/ { grab=1 }
        grab && /^}/ { grab=0 }
        grab { while (match($0, /"[^"]+"/)) { print substr($0, RSTART+1, RLENGTH-2); $0=substr($0, RSTART+RLENGTH) } }
    ' "$LUACHECKRC")
    while IFS= read -r g; do
        [[ -z "$g" ]] && continue
        n=$(refs_in_src "$g")
        if [[ "$n" -eq 0 ]]; then
            flag "global '$g' declared in .luacheckrc but referenced nowhere in src/"
        fi
    done <<< "$GLOBALS"
fi

# ── 5. Orphaned media ───────────────────────────────────────────────────────
if [[ -d "$MEDIA" ]]; then
    section "Media (referenced by src/ or the .toc?)"
    ORPHANS=()
    while IFS= read -r f; do
        base=$(basename "$f")
        stem="${base%.*}"
        hits=0
        # search src/ and the .toc for either the basename or the extension-less stem
        for needle in "$base" "$stem"; do
            n=$(refs_in_src "$needle")
            hits=$((hits+n))
            if [[ -n "$TOC" ]]; then
                t=$(grep -Fc "$needle" "$TOC" 2>/dev/null); t=${t:-0}
                hits=$((hits+t))
            fi
        done
        if [[ "$hits" -eq 0 ]]; then
            flag "media never referenced: $f"
            ORPHANS+=("$base")
        fi
    done < <(find "$MEDIA" -type f)

    # For each orphan, note whether package.sh / pkgmeta already exclude it.
    if [[ ${#ORPHANS[@]} -gt 0 ]]; then
        echo ""
        echo "  To stop shipping these, add them to BOTH exclude lists (keep in sync):"
        for o in "${ORPHANS[@]}"; do
            in_sh="no"; in_meta="no"
            [[ -f "$PKGSH"   ]] && grep -qF "$o" "$PKGSH"   && in_sh="yes"
            [[ -f "$PKGMETA" ]] && grep -qF "$o" "$PKGMETA" && in_meta="yes"
            echo "    media/$o   (package.sh: excluded=$in_sh, pkgmeta.yaml: excluded=$in_meta)"
        done
    fi
fi

# ── Summary ─────────────────────────────────────────────────────────────────
echo ""
if [[ "$FINDINGS" -eq 0 ]]; then
    echo "✅ No dead symbols or orphaned media found."
    exit 0
else
    echo "Found $FINDINGS item(s) of likely dead code/media. Review each above."
    echo "(Heuristic — confirm a symbol is truly unused before deleting.)"
    exit 1
fi
