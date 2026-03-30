#!/usr/bin/env bash
set -euo pipefail

# ── loopty ──────────────────────────────────────────────────────────
# Iterative AI development loop. Each iteration:
#   1. Spins up a fresh Claude agent with the goal + previous journals
#   2. Lets it work for N minutes
#   3. Runs a wrap-up agent to write a timestamped journal entry
#   4. Commits everything, loops
# ────────────────────────────────────────────────────────────────────

VERSION="0.1.0"

# ── timeout shim for macOS ─────────────────────────────────────────
if ! command -v timeout &>/dev/null; then
  timeout() {
    local dur="${1%s}"
    shift
    perl -e '
      use POSIX ":sys_wait_h";
      my $dur = shift @ARGV;
      $pid = fork // die "fork: $!";
      if ($pid == 0) { exec @ARGV; die "exec: $!" }
      $SIG{ALRM} = sub { kill "TERM", $pid; waitpid($pid, 0); exit 124 };
      $SIG{TERM} = sub { kill "TERM", $pid; waitpid($pid, 0); exit 143 };
      $SIG{INT}  = sub { kill "INT",  $pid; waitpid($pid, 0); exit 130 };
      alarm $dur;
      waitpid $pid, 0;
      exit ($? >> 8);
    ' "$dur" "$@"
  }
fi

# ── defaults ───────────────────────────────────────────────────────
PROMPT_FILE="${LOOPTY_PROMPT:-.loopty/prompt.md}"
JOURNAL_DIR=".loopty/journal"
INTERVAL="${LOOPTY_INTERVAL:-900}"
MAX_TURNS="${LOOPTY_MAX_TURNS:-5}"
WORK_TURNS="${LOOPTY_WORK_TURNS:-0}"
WRAPUP_TIMEOUT="${LOOPTY_WRAPUP_TIMEOUT:-120}"
COOLDOWN="${LOOPTY_COOLDOWN:-10}"
MAX_ITERS="${LOOPTY_MAX_ITERS:-0}"
MODEL="${LOOPTY_MODEL:-}"
DRY_RUN=0
STATUS_MODE=0
INLINE_GOAL=""
RESUME=0
QUIET=0
NO_COMMIT=0
NO_SPIN_CHECK=0
VERBOSE=0
FORMAT="text"
ITER=0
ITERS_THIS_RUN=0
RUN_START=$(date +%s)
INTERRUPTED=0
CHILD_PID=""

# ── usage ──────────────────────────────────────────────────────────
usage() {
  cat <<EOF
loopty v${VERSION} — iterative AI development loop

Usage: bash loopty.sh [OPTIONS] [PROMPT_FILE]
       bash loopty.sh status

Subcommands:
  status                   Show journal history and run summary

Options:
  --interval, -i SECONDS   Time budget per iteration (default: 900 = 15m)
  --max-iters, -n COUNT    Stop after N iterations (default: 0 = unlimited)
  --model, -m MODEL        Claude model override
  --max-turns, -t TURNS    Max turns for wrap-up agent (default: 5)
  --work-turns, -w TURNS   Max turns for work agent (default: 0 = unlimited)
  --wrapup-timeout SECS    Timeout for wrap-up agent in seconds (default: 120)
  --cooldown SECONDS       Pause between iterations (default: 10)
  --no-cooldown            Shorthand for --cooldown 0
  --no-commit              Skip automatic git commits after each iteration
  --no-spin-check          Disable spin/stall detection
  --verbose, -V            Show detailed journal content in status output
  --format FORMAT          Output format for status: text (default) or json
  --goal, -g TEXT          Set the iteration goal inline (creates/updates prompt file)
  --resume                 Continue iteration numbering from last journal entry
  --dry-run                Show config and exit without running
  --quiet, -q              Suppress banner output (show only errors and phase markers)
  --help, -h               Show this help
  --version, -v            Show version

Environment variables (override defaults, CLI args take precedence):
  LOOPTY_INTERVAL    Same as --interval
  LOOPTY_MAX_ITERS   Same as --max-iters
  LOOPTY_MODEL       Same as --model
  LOOPTY_MAX_TURNS   Same as --max-turns
  LOOPTY_WORK_TURNS       Same as --work-turns
  LOOPTY_WRAPUP_TIMEOUT   Same as --wrapup-timeout
  LOOPTY_COOLDOWN         Same as --cooldown
  LOOPTY_PROMPT           Same as PROMPT_FILE positional arg

Examples:
  bash loopty.sh                           # defaults: .loopty/prompt.md, 15m, unlimited
  bash loopty.sh -i 600 -n 3              # 10m intervals, 3 iterations
  bash loopty.sh -g "improve tests" -n 5  # set goal inline, 5 iterations
  bash loopty.sh --resume -n 3            # continue from last iteration number
  bash loopty.sh --dry-run                # show config without running
  bash loopty.sh status                   # review journal history
  bash loopty.sh status --verbose         # include journal summaries
  bash loopty.sh status --format json     # machine-readable output
  LOOPTY_INTERVAL=600 bash loopty.sh      # env var config
EOF
  exit 0
}

# ── argument parsing ───────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --interval|-i)
      [[ $# -lt 2 ]] && { echo "Error: $1 requires a value" >&2; exit 1; }
      INTERVAL="$2"; shift 2 ;;
    --max-iters|-n)
      [[ $# -lt 2 ]] && { echo "Error: $1 requires a value" >&2; exit 1; }
      MAX_ITERS="$2"; shift 2 ;;
    --model|-m)
      [[ $# -lt 2 ]] && { echo "Error: $1 requires a value" >&2; exit 1; }
      MODEL="$2"; shift 2 ;;
    --max-turns|-t)
      [[ $# -lt 2 ]] && { echo "Error: $1 requires a value" >&2; exit 1; }
      MAX_TURNS="$2"; shift 2 ;;
    --work-turns|-w)
      [[ $# -lt 2 ]] && { echo "Error: $1 requires a value" >&2; exit 1; }
      WORK_TURNS="$2"; shift 2 ;;
    --wrapup-timeout)
      [[ $# -lt 2 ]] && { echo "Error: $1 requires a value" >&2; exit 1; }
      WRAPUP_TIMEOUT="$2"; shift 2 ;;
    --cooldown)
      [[ $# -lt 2 ]] && { echo "Error: $1 requires a value" >&2; exit 1; }
      COOLDOWN="$2"; shift 2 ;;
    --goal|-g)
      [[ $# -lt 2 ]] && { echo "Error: $1 requires a value" >&2; exit 1; }
      INLINE_GOAL="$2"; shift 2 ;;
    --no-cooldown)
      COOLDOWN=0; shift ;;
    --no-commit)
      NO_COMMIT=1; shift ;;
    --no-spin-check)
      NO_SPIN_CHECK=1; shift ;;
    --verbose|-V)
      VERBOSE=1; shift ;;
    --format)
      [[ $# -lt 2 ]] && { echo "Error: $1 requires a value" >&2; exit 1; }
      FORMAT="$2"
      if [ "$FORMAT" != "text" ] && [ "$FORMAT" != "json" ]; then
        echo "Error: --format must be 'text' or 'json', got '$FORMAT'" >&2
        exit 1
      fi
      shift 2 ;;
    --resume)
      RESUME=1; shift ;;
    --dry-run)
      DRY_RUN=1; shift ;;
    --quiet|-q)
      QUIET=1; shift ;;
    --help|-h)
      usage ;;
    --version|-v)
      echo "loopty v${VERSION}"; exit 0 ;;
    status)
      STATUS_MODE=1; shift ;;
    -*)
      echo "Error: unknown option '$1'" >&2
      echo "Run 'bash loopty.sh --help' for usage." >&2
      exit 1 ;;
    *)
      PROMPT_FILE="$1"; shift ;;
  esac
done

# ── frontmatter helper ─────────────────────────────────────────────
# Extract a YAML frontmatter value from a journal file.
# Usage: fm_val FILE KEY [DEFAULT]
# Only matches between --- delimiters to avoid false matches in body text.
fm_val() {
  local file="$1" key="$2" default="${3:-}"
  local val="" in_front=0
  while IFS= read -r line; do
    if [ "$line" = "---" ]; then
      if [ "$in_front" -eq 1 ]; then break; fi
      in_front=1
      continue
    fi
    if [ "$in_front" -eq 1 ] && [[ "$line" == "${key}:"* ]]; then
      val="${line#"${key}:"}"
      val="${val#"${val%%[![:space:]]*}"}"
      if [[ "$val" == \"*\" ]] || [[ "$val" == \'*\' ]]; then
        val="${val:1:${#val}-2}"
      fi
      echo "$val"
      return
    fi
  done < "$file" 2>/dev/null
  echo "$default"
}

# ── git diff stat parser ──────────────────────────────────────────
# Parse the summary line of `git diff --stat` output.
# Usage: parse_diff_stat "STAT_OUTPUT"
# Sets: PARSED_FILES, PARSED_INS, PARSED_DEL
parse_diff_stat() {
  local summary
  summary=$(echo "$1" | tail -1)
  PARSED_FILES=$(echo "$summary" | LC_ALL=C grep -oE '[0-9]+ file' | LC_ALL=C grep -oE '[0-9]+' || echo "0")
  PARSED_INS=$(echo "$summary" | LC_ALL=C grep -oE '[0-9]+ insertion' | LC_ALL=C grep -oE '[0-9]+' || echo "0")
  PARSED_DEL=$(echo "$summary" | LC_ALL=C grep -oE '[0-9]+ deletion' | LC_ALL=C grep -oE '[0-9]+' || echo "0")
}

# ── lock file for concurrent run prevention ───────────────────────
LOCK_DIR=".loopty/lock.d"
LOCK_HELD=0

acquire_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    echo $$ > "$LOCK_DIR/pid"
    LOCK_HELD=1
    return 0
  fi
  # Check for stale lock
  if [ -f "$LOCK_DIR/pid" ]; then
    local old_pid
    old_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "")
    if [ -n "$old_pid" ] && ! kill -0 "$old_pid" 2>/dev/null; then
      rm -rf "$LOCK_DIR"
      if mkdir "$LOCK_DIR" 2>/dev/null; then
        echo $$ > "$LOCK_DIR/pid"
        LOCK_HELD=1
        return 0
      fi
    fi
  fi
  echo "Error: another loopty instance is running (lock: $LOCK_DIR)" >&2
  exit 1
}

release_lock() {
  if [ "$LOCK_HELD" -eq 1 ]; then
    rm -rf "$LOCK_DIR" 2>/dev/null || true
    LOCK_HELD=0
  fi
}

# ── logging helper ─────────────────────────────────────────────────
log() {
  [ "$QUIET" -eq 0 ] && echo "$@" || true
}

# ── box drawing helper ─────────────────────────────────────────────
BOX_WIDTH=66

box_top()    { printf "╔"; printf '═%.0s' $(seq 1 $BOX_WIDTH); printf "╗\n"; }
box_mid()    { printf "╠"; printf '═%.0s' $(seq 1 $BOX_WIDTH); printf "╣\n"; }
box_bottom() { printf "╚"; printf '═%.0s' $(seq 1 $BOX_WIDTH); printf "╝\n"; }
box_line()   { printf "║  %-$(( BOX_WIDTH - 2 ))s║\n" "$1"; }
box_title()  { printf "║  %-$(( BOX_WIDTH - 2 ))s║\n" "$1"; }

# ── status mode ────────────────────────────────────────────────────
if [ "$STATUS_MODE" -eq 1 ]; then
  JOURNAL_DIR="${JOURNAL_DIR:-.loopty/journal}"

  # Collect journal files (sorted newest first)
  JOURNAL_FILES=()
  while IFS= read -r -d '' f; do
    [ -n "$f" ] && JOURNAL_FILES+=("$f")
  done < <(find "$JOURNAL_DIR" -maxdepth 1 -name '*.md' -print0 2>/dev/null | sort -rz)
  JOURNAL_COUNT=${#JOURNAL_FILES[@]}

  if [ "$JOURNAL_COUNT" -eq 0 ]; then
    if [ "$FORMAT" = "json" ]; then
      echo '{"version":"'"$VERSION"'","iterations":0,"entries":[]}'
      exit 0
    fi
    box_top
    box_title "loopty v${VERSION} -- status"
    box_bottom
    echo ""
    echo "No journal entries found in $JOURNAL_DIR/"
    echo "Run 'bash loopty.sh' to start your first iteration."
    exit 0
  fi

  # Compute cumulative metrics from all journal frontmatter
  CUM_FILES=0
  CUM_INS=0
  CUM_DEL=0
  CUM_DUR=0
  COMPLETED=0
  INTERRUPTED_COUNT=0
  FALLBACK=0

  # Build per-entry data (used by both text and json)
  declare -a E_ITER E_STATUS E_FILES E_INS E_DEL E_DUR E_TS E_ATTEMPTED
  IDX=0
  for f in "${JOURNAL_FILES[@]}"; do
    jf=$(fm_val "$f" files_changed 0)
    ji=$(fm_val "$f" insertions 0)
    jd=$(fm_val "$f" deletions 0)
    jdur=$(fm_val "$f" duration_seconds 0)
    js=$(fm_val "$f" status unknown)
    jiter=$(fm_val "$f" iteration "")
    [[ "$jf" =~ ^[0-9]+$ ]] || jf=0
    [[ "$ji" =~ ^[0-9]+$ ]] || ji=0
    [[ "$jd" =~ ^[0-9]+$ ]] || jd=0
    [[ "$jdur" =~ ^[0-9]+$ ]] || jdur=0
    CUM_FILES=$((CUM_FILES + jf))
    CUM_INS=$((CUM_INS + ji))
    CUM_DEL=$((CUM_DEL + jd))
    CUM_DUR=$((CUM_DUR + jdur))
    case "$js" in
      completed)   COMPLETED=$((COMPLETED + 1)) ;;
      interrupted) INTERRUPTED_COUNT=$((INTERRUPTED_COUNT + 1)) ;;
      fallback)    FALLBACK=$((FALLBACK + 1)) ;;
    esac

    if [ -z "$jiter" ]; then
      heading=$(head -10 "$f" 2>/dev/null | grep -m1 '^# Iteration' || true)
      jiter="${heading##*Iteration }"
      jiter="${jiter%% *}"
      [[ "$jiter" =~ ^[0-9]+$ ]] || jiter="0"
    fi

    # Extract "What was attempted" section
    _in_attempted=0; _attempted=""
    while IFS= read -r _vline; do
      if [ "$_vline" = "## What was attempted" ]; then
        _in_attempted=1; continue
      fi
      if [ "$_in_attempted" -eq 1 ]; then
        [[ "$_vline" == "## "* ]] && break
        [ -n "$_vline" ] && _attempted+="$_vline "
      fi
    done < "$f" 2>/dev/null

    E_ITER[$IDX]="$jiter"
    E_STATUS[$IDX]="$js"
    E_FILES[$IDX]="$jf"
    E_INS[$IDX]="$ji"
    E_DEL[$IDX]="$jd"
    E_DUR[$IDX]="$jdur"
    E_TS[$IDX]="$(basename "$f" .md)"
    E_ATTEMPTED[$IDX]="$_attempted"
    IDX=$((IDX + 1))
  done

  CUM_DUR_DISPLAY="—"
  if [ "$CUM_DUR" -gt 0 ]; then
    CUM_DUR_DISPLAY="$((CUM_DUR / 60))m$((CUM_DUR % 60))s"
  fi

  # ── JSON output ──────────────────────────────────────────────────
  if [ "$FORMAT" = "json" ]; then
    # Read goal
    PROMPT_FILE="${PROMPT_FILE:-.loopty/prompt.md}"
    _goal=""
    [ -f "$PROMPT_FILE" ] && _goal=$(head -1 "$PROMPT_FILE")

    # Escape strings for JSON (minimal: backslash, double quote, newline)
    json_escape() {
      local s="$1"
      s="${s//\\/\\\\}"
      s="${s//\"/\\\"}"
      s="${s//$'\n'/\\n}"
      s="${s//$'\r'/\\r}"
      s="${s//$'\t'/\\t}"
      # Strip remaining control characters (0x00-0x1f except already handled)
      s=$(printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037')
      printf '%s' "$s"
    }

    printf '{"version":"%s"' "$VERSION"
    printf ',"goal":"%s"' "$(json_escape "$_goal")"
    printf ',"iterations":%d' "$JOURNAL_COUNT"
    printf ',"completed":%d,"interrupted":%d,"fallback":%d' "$COMPLETED" "$INTERRUPTED_COUNT" "$FALLBACK"
    printf ',"cumulative":{"files_changed":%d,"insertions":%d,"deletions":%d,"duration_seconds":%d}' \
      "$CUM_FILES" "$CUM_INS" "$CUM_DEL" "$CUM_DUR"

    # Include last run summary if available
    _summary_file=".loopty/last-run-summary.md"
    if [ -f "$_summary_file" ]; then
      _sum_status="" _sum_iters="" _sum_elapsed="" _sum_agent_dur="" _sum_files="" _sum_ins="" _sum_del=""
      _sum_status=$(fm_val "$_summary_file" status "unknown")
      _sum_iters=$(fm_val "$_summary_file" iterations "0")
      _sum_elapsed=$(fm_val "$_summary_file" elapsed_minutes "0")
      _sum_agent_dur=$(fm_val "$_summary_file" agent_duration "—")
      _sum_files=$(fm_val "$_summary_file" files_changed "0")
      _sum_ins=$(fm_val "$_summary_file" insertions "0")
      _sum_del=$(fm_val "$_summary_file" deletions "0")
      printf ',"last_run":{"status":"%s","iterations":%s,"elapsed_minutes":%s' \
        "$(json_escape "$_sum_status")" "$_sum_iters" "$_sum_elapsed"
      printf ',"agent_duration":"%s","files_changed":%s,"insertions":%s,"deletions":%s}' \
        "$(json_escape "$_sum_agent_dur")" "$_sum_files" "$_sum_ins" "$_sum_del"
    fi

    printf ',"entries":['
    for (( i=0; i<IDX; i++ )); do
      [ "$i" -gt 0 ] && printf ','
      printf '{"iteration":%s,"timestamp":"%s","status":"%s"' \
        "${E_ITER[$i]}" "${E_TS[$i]}" "${E_STATUS[$i]}"
      printf ',"files_changed":%d,"insertions":%d,"deletions":%d,"duration_seconds":%d' \
        "${E_FILES[$i]}" "${E_INS[$i]}" "${E_DEL[$i]}" "${E_DUR[$i]}"
      printf ',"summary":"%s"}' "$(json_escape "${E_ATTEMPTED[$i]}")"
    done
    printf ']}\n'
    exit 0
  fi

  # ── Text output ──────────────────────────────────────────────────
  # Show prompt info if available
  PROMPT_FILE="${PROMPT_FILE:-.loopty/prompt.md}"
  PROMPT_PREVIEW=""
  if [ -f "$PROMPT_FILE" ]; then
    PROMPT_PREVIEW=$(head -3 "$PROMPT_FILE" | tr '\n' ' ' | sed 's/  */ /g')
    [ ${#PROMPT_PREVIEW} -gt 50 ] && PROMPT_PREVIEW="${PROMPT_PREVIEW:0:47}..."
  fi

  box_top
  box_title "loopty v${VERSION} -- status"
  box_mid
  if [ -n "$PROMPT_PREVIEW" ]; then
    box_line "Goal:       $PROMPT_PREVIEW"
  fi
  box_line "Iterations: $JOURNAL_COUNT total ($COMPLETED completed, $INTERRUPTED_COUNT interrupted, $FALLBACK fallback)"
  box_line "Duration:   $CUM_DUR_DISPLAY (agent work time)"
  box_line "Cumulative: $CUM_FILES files, +$CUM_INS/-$CUM_DEL lines"
  box_bottom
  echo ""

  # Column headers
  printf "  %-3s  %-4s  %-11s  %-20s  %-6s  %s\n" "St" "Iter" "Status" "Timestamp" "Time" "Changes"
  printf "  %-3s  %-4s  %-11s  %-20s  %-6s  %s\n" "──" "────" "───────────" "────────────────────" "──────" "───────"

  for (( i=0; i<IDX; i++ )); do
    case "${E_STATUS[$i]}" in
      completed)   STATUS_ICON="+" ;;
      interrupted) STATUS_ICON="!" ;;
      fallback)    STATUS_ICON="~" ;;
      *)           STATUS_ICON="-" ;;
    esac

    DETAIL="—"
    if [ "${E_FILES[$i]}" != "0" ]; then
      DETAIL="${E_FILES[$i]}f +${E_INS[$i]}/-${E_DEL[$i]}"
    fi

    DUR_DISPLAY="—"
    if [ "${E_DUR[$i]}" -gt 0 ] 2>/dev/null; then
      DUR_DISPLAY="$((${E_DUR[$i]} / 60))m$((${E_DUR[$i]} % 60))s"
    fi

    TRUNC_STATUS="${E_STATUS[$i]:0:11}"
    printf "  [%s]  #%-3s  %-11s  %-20s  %-6s  %s\n" \
      "$STATUS_ICON" "${E_ITER[$i]}" "$TRUNC_STATUS" "${E_TS[$i]}" "$DUR_DISPLAY" "$DETAIL"

    # In verbose mode, show "What was attempted" section
    if [ "$VERBOSE" -eq 1 ] && [ -n "${E_ATTEMPTED[$i]}" ]; then
      printf "        %s\n\n" "${E_ATTEMPTED[$i]}"
    fi
  done

  echo ""

  # Show last run summary if it exists
  SUMMARY_FILE=".loopty/last-run-summary.md"
  if [ -f "$SUMMARY_FILE" ]; then
    echo "── Last run summary ──"
    while IFS= read -r line; do
      case "$line" in
        "- "**) line="${line//\*\*/}"; echo "  ${line#- }" ;;
      esac
    done < "$SUMMARY_FILE"
    echo ""
    echo "  Full details: $SUMMARY_FILE"
  fi

  # Show latest journal's next steps if available
  LATEST="${JOURNAL_FILES[0]:-}"
  if [ -n "$LATEST" ]; then
    in_section=0; step_lines=""
    while IFS= read -r line; do
      if [ "$line" = "## Concrete next steps" ]; then
        in_section=1; continue
      fi
      if [ "$in_section" -eq 1 ]; then
        [[ "$line" == "## "* ]] && break
        step_lines+="$line
"
      fi
    done < "$LATEST" 2>/dev/null
    step_lines="${step_lines%$'\n'}"
    if [ -n "$step_lines" ]; then
      echo "── Next steps (from latest journal) ──"
      echo "$step_lines" | head -8
    fi
  fi

  exit 0
fi

# ── inline goal handling ────────────────────────────────────────────
if [ -n "$INLINE_GOAL" ]; then
  if [ -z "${INLINE_GOAL// /}" ]; then
    echo "Error: --goal value is empty or whitespace-only" >&2
    exit 1
  fi
  mkdir -p "$(dirname "$PROMPT_FILE")"
  echo "$INLINE_GOAL" > "$PROMPT_FILE"
  log "Wrote goal to $PROMPT_FILE"
fi

# ── validation ─────────────────────────────────────────────────────
validate() {
  local errors=0

  if [ ! -f "$PROMPT_FILE" ]; then
    echo "Error: prompt file not found at '$PROMPT_FILE'" >&2
    echo "" >&2
    echo "Create one:" >&2
    echo "  mkdir -p .loopty" >&2
    echo "  echo 'Your iterative goal here...' > .loopty/prompt.md" >&2
    echo "" >&2
    echo "Or use --goal to set it inline:" >&2
    echo "  bash loopty.sh -g 'Your goal here'" >&2
    errors=1
  else
    local content
    content=$(cat "$PROMPT_FILE")
    if [ -z "${content// /}" ]; then
      echo "Error: prompt file '$PROMPT_FILE' is empty or whitespace-only" >&2
      errors=1
    fi
  fi

  if [ "$DRY_RUN" -eq 0 ] && ! command -v claude &>/dev/null; then
    echo "Error: 'claude' CLI not found in PATH" >&2
    echo "Install it: https://docs.anthropic.com/en/docs/claude-code" >&2
    errors=1
  fi

  if ! [[ "$INTERVAL" =~ ^[0-9]+$ ]] || [ "$INTERVAL" -lt 60 ]; then
    echo "Error: interval must be a number >= 60 (seconds), got '$INTERVAL'" >&2
    errors=1
  fi

  if ! [[ "$MAX_ITERS" =~ ^[0-9]+$ ]]; then
    echo "Error: max-iters must be a non-negative integer, got '$MAX_ITERS'" >&2
    errors=1
  fi

  if ! [[ "$MAX_TURNS" =~ ^[0-9]+$ ]] || [ "$MAX_TURNS" -lt 1 ]; then
    echo "Error: max-turns must be a positive integer, got '$MAX_TURNS'" >&2
    errors=1
  fi

  if ! [[ "$WORK_TURNS" =~ ^[0-9]+$ ]]; then
    echo "Error: work-turns must be a non-negative integer, got '$WORK_TURNS'" >&2
    errors=1
  fi

  if ! [[ "$WRAPUP_TIMEOUT" =~ ^[0-9]+$ ]] || [ "$WRAPUP_TIMEOUT" -lt 30 ]; then
    echo "Error: wrapup-timeout must be a number >= 30 (seconds), got '$WRAPUP_TIMEOUT'" >&2
    errors=1
  fi

  if ! [[ "$COOLDOWN" =~ ^[0-9]+$ ]]; then
    echo "Error: cooldown must be a non-negative integer, got '$COOLDOWN'" >&2
    errors=1
  elif [[ "$INTERVAL" =~ ^[0-9]+$ ]] && [ "$COOLDOWN" -ge "$INTERVAL" ] && [ "$COOLDOWN" -gt 0 ]; then
    echo "Error: cooldown ($COOLDOWN) must be less than interval ($INTERVAL)" >&2
    errors=1
  fi

  return $errors
}

if ! validate; then
  exit 1
fi

# ── git setup ──────────────────────────────────────────────────────
if ! git rev-parse --is-inside-work-tree &>/dev/null; then
  log "Initializing git repo..."
  git init -q
fi

mkdir -p "$JOURNAL_DIR"

# ── check for uncommitted changes ──────────────────────────────────
if [ "$DRY_RUN" -eq 0 ] && { ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; }; then
  DIRTY_FILES=$(git diff --name-only 2>/dev/null; git diff --cached --name-only 2>/dev/null)
  DIRTY_COUNT=$(echo "$DIRTY_FILES" | sort -u | wc -l | tr -d ' ')
  log "Warning: $DIRTY_COUNT file(s) have uncommitted changes."
  log "  Loopty will commit all changes (including yours) at the end of each iteration."
  log "  Consider committing or stashing your changes first."
  log ""
fi

# ── resume: pick up iteration number from last journal ─────────────
if [ "$RESUME" -eq 1 ]; then
  LAST_ITER=0
  while IFS= read -r jfile; do
    [ -z "$jfile" ] && continue
    candidate=$(fm_val "$jfile" iteration "")
    if [[ "$candidate" =~ ^[0-9]+$ ]] && [ "$candidate" -gt "$LAST_ITER" ] 2>/dev/null; then
      LAST_ITER=$candidate
    fi
  done < <(find "$JOURNAL_DIR" -maxdepth 1 -name '*.md' 2>/dev/null | sort -r | head -5)
  if [ "$LAST_ITER" -gt 0 ]; then
    ITER=$((LAST_ITER))
    log "Resuming from iteration $LAST_ITER (next will be $((ITER + 1)))"
  else
    log "No previous journals found — starting from iteration 1"
  fi
fi

# ── display config ─────────────────────────────────────────────────
GOAL=$(cat "$PROMPT_FILE")
JOURNAL_COUNT=$(find "$JOURNAL_DIR" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
MODEL_DISPLAY="${MODEL:-default}"
ITERS_DISPLAY=$( [ "$MAX_ITERS" -eq 0 ] && echo "unlimited" || echo "$MAX_ITERS" )

show_config() {
  if [ "$QUIET" -eq 1 ]; then return; fi
  box_top
  box_title "loopty v${VERSION} -- iterative AI development loop"
  box_mid
  box_line "Prompt:     $PROMPT_FILE"
  WORK_TURNS_DISPLAY=$( [ "$WORK_TURNS" -eq 0 ] && echo "unlimited" || echo "$WORK_TURNS" )
  box_line "Interval:   $((INTERVAL / 60))m ($WORK_TURNS_DISPLAY turns) + wrap-up (${WRAPUP_TIMEOUT}s)"
  box_line "Cooldown:   ${COOLDOWN}s between iterations"
  box_line "Max iters:  $ITERS_DISPLAY"
  box_line "Model:      $MODEL_DISPLAY"
  if [ "$NO_COMMIT" -eq 1 ]; then
    box_line "Commits:    disabled (--no-commit)"
  fi
  if [ "$NO_SPIN_CHECK" -eq 1 ]; then
    box_line "Spin check: disabled (--no-spin-check)"
  fi
  box_line "Journals:   $JOURNAL_COUNT existing entries"
  box_bottom
}

show_config

if [ "$DRY_RUN" -eq 1 ]; then
  echo ""
  echo "── Prompt content ──────────────────────────────────────"
  echo "$GOAL"
  echo "────────────────────────────────────────────────────────"
  echo ""
  echo "(dry run — exiting without starting agents)"
  exit 0
fi

log ""

# ── signal handling ────────────────────────────────────────────────
cleanup() {
  if [ "$INTERRUPTED" -eq 1 ]; then
    return
  fi
  INTERRUPTED=1
  echo ""
  echo "Signal received — cleaning up iteration $ITER..."

  # Kill child process if running
  if [ -n "$CHILD_PID" ] && kill -0 "$CHILD_PID" 2>/dev/null; then
    kill "$CHILD_PID" 2>/dev/null || true
    wait "$CHILD_PID" 2>/dev/null || true
  fi

  # Write a partial journal entry
  local TS
  TS=$(date +%Y-%m-%d-%H%M%S)
  local JF="$JOURNAL_DIR/$TS.md"
  local D
  D=$(git diff --stat 2>/dev/null || echo "(no git changes)")
  parse_diff_stat "$D"
  local D_FILES="$PARSED_FILES" D_INS="$PARSED_INS" D_DEL="$PARSED_DEL"

  local ELAPSED_AT_INT=$(( $(date +%s) - ${ITER_START:-$RUN_START} ))
  cat > "$JF" <<PARTIAL
---
iteration: $ITER
timestamp: "$TS"
status: interrupted
work_agent_exit: signal
duration_seconds: $ELAPSED_AT_INT
files_changed: $D_FILES
insertions: $D_INS
deletions: $D_DEL
---

# Iteration $ITER — $TS (interrupted)

## Note
This iteration was interrupted by signal (Ctrl+C or SIGTERM).
The agent was working but did not complete its full cycle.

## Git diff --stat at interruption
$D

## Concrete next steps for the next agent
1. Review the partial changes from this interrupted iteration
2. Continue from where this iteration left off
PARTIAL

  echo "  Wrote partial journal: $JF"

  # Commit whatever we have (only if there are changes and --no-commit not set)
  if [ "$NO_COMMIT" -eq 0 ]; then
    git add -A 2>/dev/null || true
    if ! git diff --cached --quiet 2>/dev/null; then
      git commit -m "loopty iteration $ITER — $TS (interrupted)" 2>/dev/null || true
    fi
  fi

  # Write run summary before exiting
  if [ "$ITERS_THIS_RUN" -gt 0 ]; then
    write_run_summary "interrupted"
  fi

  release_lock
  echo "  Clean exit after $ITERS_THIS_RUN iteration(s)."
  exit 130
}

trap 'cleanup' SIGINT SIGTERM

# ── run summary ────────────────────────────────────────────────────
write_run_summary() {
  local status="${1:-completed}"
  local RUN_END
  RUN_END=$(date +%s)
  local ELAPSED=$(( RUN_END - RUN_START ))
  local ELAPSED_MIN=$(( ELAPSED / 60 ))

  local SUMMARY_FILE=".loopty/last-run-summary.md"

  # Gather cumulative stats from journal frontmatter (more reliable than git HEAD~N)
  local cum_files=0 cum_insertions=0 cum_deletions=0 cum_duration=0
  local iter_table=""
  local j_count=0
  while IFS= read -r -d '' f; do
    [ "$j_count" -ge "$ITERS_THIS_RUN" ] && break
    j_count=$((j_count + 1))
    local j_iter j_status j_files j_ins j_del j_dur
    j_iter=$(fm_val "$f" iteration "?")
    j_status=$(fm_val "$f" status "?")
    j_files=$(fm_val "$f" files_changed "0")
    j_ins=$(fm_val "$f" insertions "0")
    j_del=$(fm_val "$f" deletions "0")
    j_dur=$(fm_val "$f" duration_seconds "0")
    # Guard against non-numeric values
    [[ "$j_files" =~ ^[0-9]+$ ]] || j_files=0
    [[ "$j_ins" =~ ^[0-9]+$ ]] || j_ins=0
    [[ "$j_del" =~ ^[0-9]+$ ]] || j_del=0
    [[ "$j_dur" =~ ^[0-9]+$ ]] || j_dur=0
    cum_files=$((cum_files + j_files))
    cum_insertions=$((cum_insertions + j_ins))
    cum_deletions=$((cum_deletions + j_del))
    cum_duration=$((cum_duration + j_dur))
    local dur_display="—"
    if [ "$j_dur" -gt 0 ]; then
      dur_display="$((j_dur / 60))m$((j_dur % 60))s"
    fi
    iter_table+="| $j_iter | $j_status | $j_files | +$j_ins/-$j_del | $dur_display |
"
  done < <(find "$JOURNAL_DIR" -maxdepth 1 -name '*.md' -print0 2>/dev/null | sort -rz)

  local cum_dur_display="—"
  if [ "$cum_duration" -gt 0 ]; then
    cum_dur_display="$((cum_duration / 60))m$((cum_duration % 60))s"
  fi

  cat > "$SUMMARY_FILE" <<SUMMARY
---
status: $status
iterations: $ITERS_THIS_RUN
elapsed_minutes: $ELAPSED_MIN
agent_duration: $cum_dur_display
files_changed: $cum_files
insertions: $cum_insertions
deletions: $cum_deletions
timestamp: "$(date +%Y-%m-%d-%H%M%S)"
---

# Loopty Run Summary

- **Status:** $status
- **Iterations completed:** $ITERS_THIS_RUN
- **Total wall-clock time:** ${ELAPSED_MIN}m
- **Agent work time:** $cum_dur_display
- **Files changed:** $cum_files
- **Lines:** +$cum_insertions / -$cum_deletions

## Per-Iteration Breakdown

| Iter | Status | Files | Lines | Duration |
|------|--------|-------|-------|----------|
${iter_table}
SUMMARY

  if [ "$QUIET" -eq 0 ]; then
    echo ""
    box_top
    box_title "Run Summary"
    box_mid
    box_line "Status:     $status"
    box_line "Iterations: $ITERS_THIS_RUN"
    box_line "Elapsed:    ${ELAPSED_MIN}m"
    box_line "Files:      $cum_files changed (+$cum_insertions/-$cum_deletions)"
    box_line "Details:    $SUMMARY_FILE"
    box_bottom
  fi
}

# ── model flag ─────────────────────────────────────────────────────
MODEL_ARGS=()
if [ -n "$MODEL" ]; then
  MODEL_ARGS=(--model "$MODEL")
fi

# ── work agent turn limit ─────────────────────────────────────────
WORK_TURNS_ARGS=()
if [ "$WORK_TURNS" -gt 0 ] 2>/dev/null; then
  WORK_TURNS_ARGS=(--max-turns "$WORK_TURNS")
fi

# ── acquire lock ──────────────────────────────────────────────────
acquire_lock

# Unified exit handler: release lock on any exit path.
# cleanup() already calls release_lock and exits, so this EXIT trap
# only matters for the normal (non-signal) exit path.
on_exit() {
  release_lock
}
trap 'on_exit' EXIT

# ── main loop ──────────────────────────────────────────────────────
RUN_START=$(date +%s)

while true; do
  if [ "$INTERRUPTED" -eq 1 ]; then break; fi

  if [ "$MAX_ITERS" -gt 0 ] && [ "$ITERS_THIS_RUN" -ge "$MAX_ITERS" ]; then
    log "Reached max iterations ($MAX_ITERS). Done."
    break
  fi
  ITER=$((ITER + 1))
  ITERS_THIS_RUN=$((ITERS_THIS_RUN + 1))

  TIMESTAMP=$(date +%Y-%m-%d-%H%M%S)
  JOURNAL_FILE="$JOURNAL_DIR/$TIMESTAMP.md"
  log "━━━ Iteration $ITER [$TIMESTAMP] ━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  # Gather journal context: last 3 verbatim, 4-10 summarized, cumulative stats header
  PREV_NOTES=""
  PREV_COUNT=0
  CUM_ITER_FILES=0
  CUM_ITER_INS=0
  CUM_ITER_DEL=0
  CUM_ITER_DUR=0
  CUM_COMPLETED=0
  ALL_JOURNALS=()
  while IFS= read -r -d '' f; do
    ALL_JOURNALS+=("$f")
    # Accumulate stats
    jf_files=$(fm_val "$f" files_changed "0")
    jf_ins=$(fm_val "$f" insertions "0")
    jf_del=$(fm_val "$f" deletions "0")
    jf_dur=$(fm_val "$f" duration_seconds "0")
    jf_status=$(fm_val "$f" status "unknown")
    CUM_ITER_FILES=$((CUM_ITER_FILES + jf_files))
    CUM_ITER_INS=$((CUM_ITER_INS + jf_ins))
    CUM_ITER_DEL=$((CUM_ITER_DEL + jf_del))
    CUM_ITER_DUR=$((CUM_ITER_DUR + jf_dur))
    [ "$jf_status" = "completed" ] && CUM_COMPLETED=$((CUM_COMPLETED + 1))
  done < <(find "$JOURNAL_DIR" -maxdepth 1 -name '*.md' -print0 2>/dev/null | sort -rz)

  # Build context: cumulative header + tiered journals
  if [ "${#ALL_JOURNALS[@]}" -gt 0 ]; then
    PREV_NOTES="## Cumulative Stats
- Total iterations: ${#ALL_JOURNALS[@]} ($CUM_COMPLETED completed)
- Total files changed: $CUM_ITER_FILES (+$CUM_ITER_INS/-$CUM_ITER_DEL)
- Total agent time: $((CUM_ITER_DUR / 60))m$((CUM_ITER_DUR % 60))s

"
  fi

  for f in ${ALL_JOURNALS[@]+"${ALL_JOURNALS[@]}"}; do
    PREV_COUNT=$((PREV_COUNT + 1))
    if [ "$PREV_COUNT" -le 3 ]; then
      PREV_NOTES+="
--- $(basename "$f") ---
$(cat "$f")
"
    elif [ "$PREV_COUNT" -le 10 ]; then
      # Summarized: just attempted + next steps
      _attempted=$(sed -n '/^## What was attempted/,/^## /{/^## /d;p;}' "$f" 2>/dev/null | head -3)
      _nextsteps=$(sed -n '/^## Concrete next steps/,/^## /{/^## /d;p;}' "$f" 2>/dev/null | head -5)
      PREV_NOTES+="
--- $(basename "$f") (summary) ---
## What was attempted
${_attempted:-(not available)}
## Concrete next steps
${_nextsteps:-(not available)}
"
    fi
  done

  GOAL=$(cat "$PROMPT_FILE")

  # Resolve journal path to absolute for the work agent
  ABS_JOURNAL_DIR="$(cd "$JOURNAL_DIR" 2>/dev/null && pwd)"
  ABS_PLAN_FILE="$ABS_JOURNAL_DIR/$TIMESTAMP.md"

  # Save prompt checksum for mutation guard
  PROMPT_CHECKSUM=$(shasum "$PROMPT_FILE" | cut -d' ' -f1)
  PROMPT_SAVED=$(cat "$PROMPT_FILE")

  # ── Phase 1: Work ─────────────────────────────────────────────────
  WORK_PROMPT="You are iteration $ITER of an autonomous research/development loop called 'loopty'.

## Your Goal
$GOAL

## Previous Iteration Journals
${PREV_NOTES:-No previous iterations yet. You are the first agent.}

## Rules
- You have ~$((INTERVAL / 60)) minutes of wall-clock time. Work fast and focused.
- Make real, concrete progress toward the goal each iteration.
- Do NOT modify .loopty/prompt.md — it is the user's goal and must not be changed.
- You may read, write, edit files, and run commands freely.
- FIRST THING: Decide what you will work on this iteration, then write a brief plan to $ABS_PLAN_FILE using the Write tool. Format:

# Iteration $ITER — $TIMESTAMP

## Plan
<2-4 bullet points of what you intend to do>

- After writing the plan, begin your work immediately.
- If you finish early, stop. Don't pad time with unnecessary changes."

  log "  Phase 1: Work ($((INTERVAL / 60))m budget)..."
  ITER_START=$(date +%s)
  WORK_EXIT=0
  timeout "${INTERVAL}s" claude -p "$WORK_PROMPT" ${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"} \
    ${WORK_TURNS_ARGS[@]+"${WORK_TURNS_ARGS[@]}"} \
    --allowedTools "Edit,Write,Read,Bash,Glob,Grep,Agent,WebSearch,WebFetch,TodoWrite,NotebookEdit" 2>&1 | tail -5 &
  CHILD_PID=$!
  WORK_EXIT=0
  wait $CHILD_PID 2>/dev/null || WORK_EXIT=$?
  CHILD_PID=""

  if [ "$INTERRUPTED" -eq 1 ]; then break; fi

  # Prompt mutation guard: restore if changed
  PROMPT_CHECKSUM_AFTER=$(shasum "$PROMPT_FILE" | cut -d' ' -f1)
  if [ "$PROMPT_CHECKSUM" != "$PROMPT_CHECKSUM_AFTER" ]; then
    log "  Warning: prompt file was modified by work agent — restoring original"
    echo "$PROMPT_SAVED" > "$PROMPT_FILE"
  fi

  if [ "$WORK_EXIT" -eq 124 ]; then
    log "  (work agent reached time limit — proceeding to wrap-up)"
  elif [ "$WORK_EXIT" -ne 0 ]; then
    log "  Warning: work agent exited with code $WORK_EXIT"
  fi

  # ── Phase 2: Wrap-up ─────────────────────────────────────────────
  WORK_END=$(date +%s)
  WORK_DURATION=$(( WORK_END - ITER_START ))

  # Gather git stats for the journal
  # Use staged + unstaged diff; fall back gracefully if no commits exist yet
  if git rev-parse HEAD &>/dev/null; then
    DIFF=$(git diff HEAD --stat 2>/dev/null || echo "(no git changes)")
    DIFF_DETAIL=$(git diff HEAD 2>/dev/null | head -200 || echo "")
    CHANGED_FILES=$(git diff HEAD --name-only 2>/dev/null | head -20 || echo "(none)")
  else
    # No commits yet — show all tracked files
    DIFF=$(git status --short 2>/dev/null || echo "(no git changes)")
    DIFF_DETAIL=""
    CHANGED_FILES=$(git ls-files 2>/dev/null | head -20 || echo "(none)")
  fi
  parse_diff_stat "$DIFF"
  FILES_CHANGED="$PARSED_FILES"
  INSERTIONS="$PARSED_INS"
  DELETIONS="$PARSED_DEL"

  log "  Phase 2: Wrap-up ($MAX_TURNS turns)..."

  # Resolve journal path to absolute for the agent
  ABS_JOURNAL="$(cd "$(dirname "$JOURNAL_FILE")" 2>/dev/null && pwd)/$(basename "$JOURNAL_FILE")"

  # Describe work agent exit in narrative form
  case "$WORK_EXIT" in
    0)   WORK_EXIT_DESC="Work agent completed successfully (exit 0)" ;;
    124) WORK_EXIT_DESC="Work agent hit time limit (exit 124)" ;;
    *)   WORK_EXIT_DESC="Work agent exited abnormally (exit $WORK_EXIT)" ;;
  esac

  # Write a baseline journal immediately (guarantees we always have one)
  cat > "$JOURNAL_FILE" <<BASELINE
---
iteration: $ITER
timestamp: "$TIMESTAMP"
status: fallback
work_agent_exit: $WORK_EXIT
duration_seconds: $WORK_DURATION
files_changed: $FILES_CHANGED
insertions: $INSERTIONS
deletions: $DELETIONS
---

# Iteration $ITER — $TIMESTAMP

## Goal context
$(head -5 "$PROMPT_FILE")

## What was attempted
$WORK_EXIT_DESC. See diff below for changes made.

## Files changed
$CHANGED_FILES

## Git diff --stat
$DIFF

## Diff detail (first 50 lines)
$(echo "$DIFF_DETAIL" | head -50)

## Concrete next steps
1. Review the changes from this iteration and continue toward the goal
2. Check if work agent exit ($WORK_EXIT) indicates an issue to address
BASELINE

  # Now try to enhance the journal with an agent-written summary.
  WRAPUP_PROMPT="You are a journal-writing agent for the loopty development loop.

Your ONLY task: write a journal entry to the file $ABS_JOURNAL using the Write tool.

The journal must have this EXACT format (copy the structure precisely):

---
iteration: $ITER
timestamp: \"$TIMESTAMP\"
status: completed
work_agent_exit: $WORK_EXIT
duration_seconds: $WORK_DURATION
files_changed: $FILES_CHANGED
insertions: $INSERTIONS
deletions: $DELETIONS
---

# Iteration $ITER — $TIMESTAMP

## What was attempted
<Write 2-3 sentences summarizing what was done based on the diff below>

## Files changed
$CHANGED_FILES

## Git diff --stat
$DIFF

## Concrete next steps
<Write 2-4 specific, actionable next steps for the next agent>

Context:
- Goal: $(head -5 "$PROMPT_FILE")
- Diff detail (first 150 lines):
$(echo "$DIFF_DETAIL" | head -150)

IMPORTANT: Use the Write tool to write the complete journal to $ABS_JOURNAL. Do it in your first response. Do not read any files first."

  # Validate journal quality: "What was attempted" >20 chars + "Concrete next steps" present
  validate_journal_quality() {
    local jf="$1"
    grep -q '^status: completed' "$jf" 2>/dev/null || return 1
    local attempted
    attempted=$(sed -n '/^## What was attempted/,/^## /{/^## What was attempted/d;/^## /d;p;}' "$jf" 2>/dev/null | tr -d '[:space:]')
    [ "${#attempted}" -gt 20 ] || return 1
    grep -q '^## Concrete next steps' "$jf" 2>/dev/null || return 1
    return 0
  }

  # Try wrap-up agent, with one retry on failure
  WRAPUP_SUCCESS=0
  for attempt in 1 2; do
    WRAPUP_EXIT=0
    timeout "${WRAPUP_TIMEOUT}s" claude -p "$WRAPUP_PROMPT" ${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"} --max-turns "$MAX_TURNS" \
      --allowedTools "Write" 2>&1 | tail -3 &
    CHILD_PID=$!
    wait $CHILD_PID 2>/dev/null || WRAPUP_EXIT=$?
    CHILD_PID=""

    if validate_journal_quality "$JOURNAL_FILE"; then
      WRAPUP_SUCCESS=1
      break
    fi

    if [ "$attempt" -eq 1 ]; then
      if [ "$WRAPUP_EXIT" -eq 124 ]; then
        log "  (wrap-up attempt 1 timed out — retrying...)"
      else
        log "  (wrap-up attempt 1 failed [exit $WRAPUP_EXIT] — retrying...)"
      fi
    fi
  done

  if [ "$WRAPUP_SUCCESS" -eq 0 ]; then
    log "  (wrap-up agent didn't update journal — using baseline)"
  fi

  if [ "$INTERRUPTED" -eq 1 ]; then break; fi

  # ── Phase 3: Commit ──────────────────────────────────────────────
  if [ "$NO_COMMIT" -eq 1 ]; then
    log "  Phase 3: Skipping commit (--no-commit)"
  else
    log "  Phase 3: Committing..."
    git add -A
    if git diff --cached --quiet 2>/dev/null; then
      log "  (nothing to commit — no changes this iteration)"
    else
      git commit -m "loopty iteration $ITER — $TIMESTAMP

Auto-committed by loopty iterative development loop.
See $JOURNAL_FILE for details." 2>/dev/null || log "  (commit failed — check git status)"
    fi
  fi

  ITER_END=$(date +%s)
  ITER_ELAPSED=$(( ITER_END - ITER_START ))
  ITER_ELAPSED_MIN=$(( ITER_ELAPSED / 60 ))
  ITER_ELAPSED_SEC=$(( ITER_ELAPSED % 60 ))
  log "  Iteration $ITER complete (${ITER_ELAPSED_MIN}m${ITER_ELAPSED_SEC}s, ${FILES_CHANGED} files, +${INSERTIONS}/-${DELETIONS})."
  log ""

  # ── Spin/stall detection ──────────────────────────────────────────
  if [ "$NO_SPIN_CHECK" -eq 0 ]; then
    RECENT_JOURNALS=()
    while IFS= read -r -d '' rj; do
      RECENT_JOURNALS+=("$rj")
    done < <(find "$JOURNAL_DIR" -maxdepth 1 -name '*.md' -print0 2>/dev/null | sort -rz)

    # Check for zero-change stall
    ZERO_COUNT=0
    for rj in ${RECENT_JOURNALS[@]+"${RECENT_JOURNALS[@]:0:5}"}; do
      rj_files=$(fm_val "$rj" files_changed "0")
      [ "$rj_files" -eq 0 ] 2>/dev/null && ZERO_COUNT=$((ZERO_COUNT + 1)) || break
    done
    if [ "$ZERO_COUNT" -ge 5 ]; then
      log "  *** SPIN DETECTED: Last 5 iterations had 0 file changes — stopping. ***"
      log "  (Use --no-spin-check to override)"
      break
    elif [ "$ZERO_COUNT" -ge 3 ]; then
      log "  Warning: Last $ZERO_COUNT iterations had 0 file changes — possible stall"
    fi

    # Check for repetitive "What was attempted" sections
    if [ "${#RECENT_JOURNALS[@]}" -ge 2 ]; then
      ATTEMPTED_1=$(sed -n '/^## What was attempted/,/^## /{/^## /d;p;}' "${RECENT_JOURNALS[0]}" 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' ' ')
      ATTEMPTED_2=$(sed -n '/^## What was attempted/,/^## /{/^## /d;p;}' "${RECENT_JOURNALS[1]}" 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' ' ')
      if [ -n "$ATTEMPTED_1" ] && [ -n "$ATTEMPTED_2" ]; then
        # Simple word overlap check
        WORDS_1=($ATTEMPTED_1)
        WORDS_2=($ATTEMPTED_2)
        if [ "${#WORDS_1[@]}" -gt 0 ]; then
          MATCH=0
          for w in "${WORDS_1[@]}"; do
            for w2 in "${WORDS_2[@]}"; do
              [ "$w" = "$w2" ] && { MATCH=$((MATCH + 1)); break; }
            done
          done
          OVERLAP=$(( MATCH * 100 / ${#WORDS_1[@]} ))
          if [ "$OVERLAP" -ge 80 ]; then
            log "  Warning: Last 2 iterations have >80% similar descriptions — possible spin"
          fi
        fi
      fi
    fi
  fi

  # Don't sleep if this is the last iteration
  if [ "$MAX_ITERS" -gt 0 ] && [ "$ITERS_THIS_RUN" -ge "$MAX_ITERS" ]; then
    break
  fi

  if [ "$COOLDOWN" -gt 0 ]; then
    log "  Cooling down ${COOLDOWN}s before next iteration..."
    sleep "$COOLDOWN" &
    CHILD_PID=$!
    wait $CHILD_PID 2>/dev/null || true
    CHILD_PID=""
    if [ "$INTERRUPTED" -eq 1 ]; then break; fi
  fi
done

# Write run summary at end of normal completion
if [ "$INTERRUPTED" -eq 0 ] && [ "$ITERS_THIS_RUN" -gt 0 ]; then
  write_run_summary "completed"
fi
