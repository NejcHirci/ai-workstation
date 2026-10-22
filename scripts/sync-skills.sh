#!/usr/bin/env bash
# Copy the selected skills into ~/.agents/skills (read by OpenCode and Kilo).
# Counterpart of sync-skills.ps1.
#
#   sync-skills.sh [--dry-run] [--upstream PATH]
#
#   --upstream PATH   clone of mattpocock/skills
#                     (default: $AI_SKILLS_UPSTREAM, else ~/git/mattpocock-ai-skills)
#
# Needs bash 4 or newer.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM="${AI_SKILLS_UPSTREAM:-$HOME/git/mattpocock-ai-skills}"
TARGET="$HOME/.agents/skills"
MANIFEST="$REPO/skills-manifest.txt"
MINE="$REPO/skills/my-skills"
MARKER='.managed-by-ai-workstation'
dry=0

while (( $# )); do
    case "$1" in
        --dry-run)  dry=1 ;;
        --upstream) shift; UPSTREAM="${1:?--upstream needs a path}" ;;
        -h|--help)  sed -n '2,10p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *)          echo "ERROR: unknown argument: $1" >&2; exit 1 ;;
    esac
    shift
done

die() { echo "ERROR: $*" >&2; exit 1; }
[[ -d "$UPSTREAM/skills" ]] || die "Upstream clone not found at $UPSTREAM (use --upstream or AI_SKILLS_UPSTREAM)."
[[ -f "$MANIFEST" ]] || die "Missing $MANIFEST"

skill_name() {   # frontmatter "name:" of a skill directory
    local n
    n="$(head -n 20 "$1/SKILL.md" | tr -d '\r' | sed -n 's/^name:[[:space:]]*//p' | head -n 1)"
    n="${n%\"}"; n="${n#\"}"; n="${n%\'}"; n="${n#\'}"
    [[ -n "$n" ]] || die "No 'name:' in frontmatter of $1/SKILL.md"
    printf '%s' "$n"
}

# 1. Desired set: leaf name -> source directory (manifest first, then your own skills)
declare -A want=()
order=()
while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="${line//[[:space:]]/}"
    [[ -n "$line" ]] || continue
    src="$UPSTREAM/skills/$line"
    [[ -f "$src/SKILL.md" ]] || die "Missing upstream skill: $line"
    leaf="$(basename "$src")"
    [[ -n "${want[$leaf]+x}" ]] || order+=("$leaf")
    want[$leaf]="$src"
done < "$MANIFEST"

if [[ -d "$MINE" ]]; then
    for d in "$MINE"/*/; do
        [[ -f "${d}SKILL.md" ]] || continue
        d="${d%/}"; leaf="$(basename "$d")"
        [[ -n "${want[$leaf]+x}" ]] || order+=("$leaf")
        want[$leaf]="$d"
    done
fi

# 2. Validate: frontmatter name must equal the directory name (Kilo requires it)
for k in "${order[@]}"; do
    n="$(skill_name "${want[$k]}")"
    [[ "$n" == "$k" ]] || die "Skill '$k': frontmatter name is '$n' (must match folder)"
done

echo "Upstream commit: $(git -C "$UPSTREAM" rev-parse --short HEAD 2>/dev/null || echo unknown)"
echo "Skills to install (${#order[@]}): ${order[*]}"
(( dry )) && exit 0

# 3. Mirror each wanted skill (folders named 'agents' or '.git' are skipped)
mkdir -p "$TARGET"
for k in "${order[@]}"; do
    dst="$TARGET/$k"
    rm -rf "$dst"
    mkdir -p "$dst"
    cp -a "${want[$k]}/." "$dst/"
    find "$dst" -mindepth 1 -type d \( -name agents -o -name .git \) -prune -exec rm -rf {} +
    : > "$dst/$MARKER"
done

# 4. Remove stale skills this script installed earlier (never touches skills you added by hand)
for d in "$TARGET"/*/; do
    [[ -d "$d" ]] || continue
    d="${d%/}"; leaf="$(basename "$d")"
    if [[ -f "$d/$MARKER" && -z "${want[$leaf]+x}" ]]; then
        echo "Removing stale: $leaf"
        rm -rf "$d"
    fi
done

# 5. Security report: anything executable inside the installed skills
echo
echo '--- Embedded shell commands in SKILL.md (Kilo runs these for trusted global skills) ---'
grep -rn --include=SKILL.md -F '!`' "$TARGET" || true
echo
echo '--- Script files bundled with skills ---'
find "$TARGET" -type f \( -name '*.sh' -o -name '*.ps1' -o -name '*.py' -o -name '*.js' -o -name '*.mjs' \
    -o -name '*.cjs' -o -name '*.bat' -o -name '*.cmd' \)
echo
echo 'Done. Review anything listed above before trusting it.'
