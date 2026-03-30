#!/usr/bin/env bash
set -euo pipefail

# ── loopty installer ──────────────────────────────────────────────
# Installs loopty as a Claude Code skill in the target project.
# Usage: bash install.sh [TARGET_DIR]
#        bash install.sh --uninstall [TARGET_DIR]
# ──────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
UNINSTALL=0

# Parse flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    --uninstall) UNINSTALL=1; shift ;;
    --help|-h)
      echo "Usage: bash install.sh [OPTIONS] [TARGET_DIR]"
      echo ""
      echo "Options:"
      echo "  --uninstall   Remove loopty from the target project"
      echo "  --help, -h    Show this help"
      echo ""
      echo "TARGET_DIR defaults to the current directory."
      exit 0
      ;;
    -*) echo "Error: unknown option '$1'" >&2; exit 1 ;;
    *) TARGET="$1"; shift ;;
  esac
done

TARGET="${TARGET:-.}"

# Resolve to absolute path
if [ ! -d "$TARGET" ]; then
  echo "Error: target directory '$TARGET' does not exist" >&2
  exit 1
fi
TARGET="$(cd "$TARGET" && pwd)"

# ── Uninstall ─────────────────────────────────────────────────────
if [ "$UNINSTALL" -eq 1 ]; then
  echo "Removing loopty from: $TARGET"
  rm -f "$TARGET/loopty.sh"
  rm -f "$TARGET/.claude/commands/loopty.md"
  rm -rf "$TARGET/.claude-plugin"
  rm -rf "$TARGET/skills/loopty"
  # Clean up empty parent dirs
  rmdir "$TARGET/skills" 2>/dev/null || true
  # Remove loopty section from CLAUDE.md if present
  if [ -f "$TARGET/CLAUDE.md" ] && grep -q '## loopty' "$TARGET/CLAUDE.md" 2>/dev/null; then
    awk '
      /^## loopty$/ { skip=1; next }
      /^## / && skip { skip=0 }
      !skip { print }
    ' "$TARGET/CLAUDE.md" | awk 'NR==1{if(/^$/){next}} {print}' | awk '{lines[NR]=$0} END{
      # Trim trailing blank lines
      n=NR; while(n>0 && lines[n]=="") n--
      for(i=1;i<=n;i++) print lines[i]
    }' > "$TARGET/CLAUDE.md.tmp" && mv "$TARGET/CLAUDE.md.tmp" "$TARGET/CLAUDE.md"
    echo "  CLAUDE.md (removed loopty section)"
  fi
  echo "  Removed loopty.sh, .claude/commands/loopty.md, .claude-plugin/, skills/loopty/"
  echo "  Note: .loopty/ directory preserved (contains your journals)"
  echo "  To remove fully: rm -rf $TARGET/.loopty"
  exit 0
fi

# ── Install ───────────────────────────────────────────────────────
echo "Installing loopty into: $TARGET"
echo ""

# Verify source files exist
for src_file in "$SCRIPT_DIR/loopty.sh" "$SCRIPT_DIR/.claude/commands/loopty.md"; do
  if [ ! -f "$src_file" ]; then
    echo "Error: missing source file '$src_file'" >&2
    echo "Are you running install.sh from the loopty repository?" >&2
    exit 1
  fi
done

# Create required directories
mkdir -p "$TARGET/.claude/commands"
mkdir -p "$TARGET/.claude-plugin"
mkdir -p "$TARGET/skills/loopty"
mkdir -p "$TARGET/.loopty"

# Copy files (with checksums to detect changes)
copy_if_changed() {
  local src="$1" dst="$2" label="$3"
  if [ -f "$dst" ]; then
    if diff -q "$src" "$dst" &>/dev/null; then
      echo "  $label (unchanged, skipped)"
      return
    fi
    echo "  $label (updated)"
  else
    echo "  $label (created)"
  fi
  cp "$src" "$dst"
}

copy_if_changed "$SCRIPT_DIR/loopty.sh" "$TARGET/loopty.sh" "loopty.sh"
copy_if_changed "$SCRIPT_DIR/.claude/commands/loopty.md" "$TARGET/.claude/commands/loopty.md" ".claude/commands/loopty.md"

# Copy skill definition and plugin manifest
if [ -f "$SCRIPT_DIR/skills/loopty/SKILL.md" ]; then
  copy_if_changed "$SCRIPT_DIR/skills/loopty/SKILL.md" "$TARGET/skills/loopty/SKILL.md" "skills/loopty/SKILL.md"
fi
if [ -f "$SCRIPT_DIR/.claude-plugin/plugin.json" ]; then
  copy_if_changed "$SCRIPT_DIR/.claude-plugin/plugin.json" "$TARGET/.claude-plugin/plugin.json" ".claude-plugin/plugin.json"
fi

# Copy example prompt if no prompt exists
if [ ! -f "$TARGET/.loopty/prompt.md" ] && [ ! -f "$TARGET/.loopty/prompt.md.example" ]; then
  if [ -f "$SCRIPT_DIR/.loopty/prompt.md.example" ]; then
    cp "$SCRIPT_DIR/.loopty/prompt.md.example" "$TARGET/.loopty/prompt.md.example"
    echo "  .loopty/prompt.md.example (created)"
  fi
elif [ -f "$TARGET/.loopty/prompt.md.example" ]; then
  echo "  .loopty/prompt.md.example (already exists, skipped)"
fi

# Add .loopty/journal to gitignore if not already there
GITIGNORE="$TARGET/.gitignore"
if [ -f "$GITIGNORE" ]; then
  if ! grep -q '\.loopty/journal' "$GITIGNORE" 2>/dev/null; then
    printf '\n# loopty journals (optional — remove this line to track journals)\n.loopty/journal/\n.loopty/last-run-summary.md\n.loopty/lock.d/\n' >> "$GITIGNORE"
    echo "  .gitignore (updated with loopty entries)"
  else
    echo "  .gitignore (already has loopty entries, skipped)"
  fi
else
  printf '# loopty journals (optional — remove this line to track journals)\n.loopty/journal/\n.loopty/last-run-summary.md\n.loopty/lock.d/\n' > "$GITIGNORE"
  echo "  .gitignore (created with loopty entries)"
fi

# Append loopty section to CLAUDE.md if not already present
CLAUDE_MD="$TARGET/CLAUDE.md"
LOOPTY_MARKER="## loopty"
if [ -f "$CLAUDE_MD" ]; then
  if ! grep -q "$LOOPTY_MARKER" "$CLAUDE_MD" 2>/dev/null; then
    cat >> "$CLAUDE_MD" <<'CLAUDEMD'

## loopty

Iterative AI development loop. Use `/loopty` to start, `/loopty status` to review.

- `.loopty/prompt.md` — iteration goal
- `.loopty/journal/` — timestamped journals from each iteration
- `loopty.sh` — main loop script (run with `bash loopty.sh`)
CLAUDEMD
    echo "  CLAUDE.md (appended loopty section)"
  else
    echo "  CLAUDE.md (already has loopty section, skipped)"
  fi
else
  cat > "$CLAUDE_MD" <<'CLAUDEMD'
## loopty

Iterative AI development loop. Use `/loopty` to start, `/loopty status` to review.

- `.loopty/prompt.md` — iteration goal
- `.loopty/journal/` — timestamped journals from each iteration
- `loopty.sh` — main loop script (run with `bash loopty.sh`)
CLAUDEMD
  echo "  CLAUDE.md (created with loopty section)"
fi

echo ""
echo "Done! To get started:"
echo "  1. Write your goal:  echo 'Your goal here' > .loopty/prompt.md"
echo "  2. Start the loop:   bash loopty.sh"
echo "  3. Or use:           /loopty (in Claude Code)"
