#!/usr/bin/env bash
set -euo pipefail

# ── loopty test suite ─────────────────────────────────────────────
# Exercises CLI paths without launching actual agents.
# Usage: bash test.sh
# ──────────────────────────────────────────────────────────────────

PASS=0
FAIL=0
SCRIPT="./loopty.sh"

pass() { PASS=$((PASS + 1)); echo "  [PASS] $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  [FAIL] $1: $2"; }

assert_exit() {
  local desc="$1" expected="$2"
  shift 2
  local actual
  "$@" >/dev/null 2>&1 && actual=0 || actual=$?
  if [ "$actual" -eq "$expected" ]; then
    pass "$desc"
  else
    fail "$desc" "expected exit $expected, got $actual"
  fi
}

assert_output_contains() {
  local desc="$1" pattern="$2"
  shift 2
  local output
  output=$("$@" 2>&1) || true
  if echo "$output" | grep -q "$pattern"; then
    pass "$desc"
  else
    fail "$desc" "output did not contain '$pattern'"
  fi
}

assert_valid_json() {
  local desc="$1"
  shift
  local output
  output=$("$@" 2>&1) || true
  if echo "$output" | python3 -m json.tool >/dev/null 2>&1; then
    pass "$desc"
  else
    fail "$desc" "output is not valid JSON"
  fi
}

echo "loopty test suite"
echo "═════════════════"
echo ""

# ── --help ────────────────────────────────────────────────────────
echo "CLI basics:"
assert_exit "--help exits 0" 0 bash "$SCRIPT" --help
assert_output_contains "--help shows usage" "Usage:" bash "$SCRIPT" --help
assert_exit "--version exits 0" 0 bash "$SCRIPT" --version
assert_output_contains "--version shows version" "loopty v" bash "$SCRIPT" --version

# ── error cases ───────────────────────────────────────────────────
echo ""
echo "Error handling:"
assert_exit "unknown option exits 1" 1 bash "$SCRIPT" --badarg
assert_output_contains "unknown option shows error" "unknown option" bash "$SCRIPT" --badarg
assert_exit "invalid format exits 1" 1 bash "$SCRIPT" --format xml
assert_output_contains "invalid format shows error" "must be 'text' or 'json'" bash "$SCRIPT" --format xml
assert_exit "--interval missing value exits 1" 1 bash "$SCRIPT" --interval
assert_exit "--max-iters missing value exits 1" 1 bash "$SCRIPT" --max-iters
assert_exit "non-numeric max-iters rejected" 1 bash "$SCRIPT" -n abc --dry-run
assert_output_contains "non-numeric max-iters message" "max-iters must be" bash "$SCRIPT" -n abc --dry-run

# ── --dry-run ─────────────────────────────────────────────────────
echo ""
echo "Dry run:"
assert_exit "--dry-run exits 0" 0 bash "$SCRIPT" --dry-run
assert_output_contains "--dry-run shows config" "dry run" bash "$SCRIPT" --dry-run
assert_output_contains "--dry-run shows prompt" "Prompt" bash "$SCRIPT" --dry-run

# ── status ────────────────────────────────────────────────────────
echo ""
echo "Status:"
assert_exit "status exits 0" 0 bash "$SCRIPT" status
assert_output_contains "status shows header" "loopty" bash "$SCRIPT" status
assert_exit "status --format json exits 0" 0 bash "$SCRIPT" status --format json
assert_valid_json "status --format json is valid JSON" bash "$SCRIPT" status --format json
assert_output_contains "status json has version" '"version"' bash "$SCRIPT" status --format json
assert_output_contains "status json has entries" '"entries"' bash "$SCRIPT" status --format json
assert_exit "status --verbose exits 0" 0 bash "$SCRIPT" status --verbose

# ── validation ────────────────────────────────────────────────────
echo ""
echo "Validation:"
assert_exit "bad interval rejected" 1 bash "$SCRIPT" -i 10 --dry-run
assert_output_contains "bad interval message" "interval must be" bash "$SCRIPT" -i 10 --dry-run
assert_exit "non-numeric interval rejected" 1 bash "$SCRIPT" -i abc --dry-run
assert_exit "bad max-turns rejected" 1 bash "$SCRIPT" -t 0 --dry-run
assert_output_contains "bad max-turns message" "max-turns must be" bash "$SCRIPT" -t 0 --dry-run
assert_exit "non-numeric work-turns rejected" 1 bash "$SCRIPT" -w abc --dry-run
assert_output_contains "bad work-turns message" "work-turns must be" bash "$SCRIPT" -w abc --dry-run
assert_exit "wrapup-timeout < 30 rejected" 1 bash "$SCRIPT" --wrapup-timeout 5 --dry-run
assert_output_contains "bad wrapup-timeout message" "wrapup-timeout must be" bash "$SCRIPT" --wrapup-timeout 5 --dry-run
assert_exit "non-numeric cooldown rejected" 1 bash "$SCRIPT" --cooldown abc --dry-run
assert_output_contains "bad cooldown message" "cooldown must be" bash "$SCRIPT" --cooldown abc --dry-run

# Test with nonexistent prompt file
assert_exit "missing prompt file rejected" 1 bash "$SCRIPT" /tmp/nonexistent-prompt-file.md --dry-run
assert_output_contains "missing prompt message" "prompt file not found" bash "$SCRIPT" /tmp/nonexistent-prompt-file.md --dry-run

# ── --resume ──────────────────────────────────────────────────────
echo ""
echo "Resume:"
assert_output_contains "--resume with journals shows resuming" "Resuming from iteration" bash "$SCRIPT" --resume --dry-run
assert_exit "--resume with --dry-run exits 0" 0 bash "$SCRIPT" --resume --dry-run

# ── missing claude CLI ────────────────────────────────────────────
echo ""
echo "Missing claude CLI:"
# Use PATH override to hide the claude binary — keep git available
MISSING_OUT=$(PATH=/usr/bin:/bin bash "$SCRIPT" 2>&1) && MISSING_EXIT=0 || MISSING_EXIT=$?
if [ "$MISSING_EXIT" -eq 1 ]; then
  pass "missing claude CLI exits 1"
else
  fail "missing claude CLI exits 1" "expected exit 1, got $MISSING_EXIT"
fi
if echo "$MISSING_OUT" | grep -q "claude.*CLI not found"; then
  pass "missing claude CLI shows error"
else
  fail "missing claude CLI shows error" "output did not contain expected error"
fi

# ── dry-run without claude CLI ───────────────────────────────────
echo ""
echo "Dry run without claude:"
# --dry-run should succeed even without claude in PATH
DRYNOCLAUDE_OUT=$(PATH=/usr/bin:/bin bash "$SCRIPT" --dry-run 2>&1) && DRYNOCLAUDE_EXIT=0 || DRYNOCLAUDE_EXIT=$?
if [ "$DRYNOCLAUDE_EXIT" -eq 0 ]; then
  pass "--dry-run succeeds without claude CLI"
else
  fail "--dry-run succeeds without claude CLI" "expected exit 0, got $DRYNOCLAUDE_EXIT"
fi
if echo "$DRYNOCLAUDE_OUT" | grep -q "dry run"; then
  pass "--dry-run output correct without claude CLI"
else
  fail "--dry-run output correct without claude CLI" "expected 'dry run' in output"
fi

# ── env var overrides ─────────────────────────────────────────────
echo ""
echo "Environment variables:"
assert_output_contains "LOOPTY_INTERVAL overrides default" "10m" env LOOPTY_INTERVAL=600 bash "$SCRIPT" --dry-run
assert_output_contains "CLI arg overrides env var" "5m" env LOOPTY_INTERVAL=600 bash "$SCRIPT" -i 300 --dry-run

# ── signal handling ───────────────────────────────────────────────
echo ""
echo "Signal handling:"
# Test that the cleanup function exists and the trap is set
# Verify the script structure handles signals correctly
if grep -qE "trap .?cleanup.? SIGINT SIGTERM" "$SCRIPT" && grep -q 'status: interrupted' "$SCRIPT"; then
  pass "cleanup handler writes interrupted journal"
else
  fail "cleanup handler writes interrupted journal" "trap or interrupted status not found in script"
fi
if grep -q 'write_run_summary' "$SCRIPT" && grep -q 'cleanup()' "$SCRIPT"; then
  pass "cleanup handler calls write_run_summary"
else
  fail "cleanup handler calls write_run_summary" "missing from cleanup function"
fi

# ── JSON structure ────────────────────────────────────────────────
echo ""
echo "JSON structure:"
assert_output_contains "JSON has cumulative object" '"cumulative"' bash "$SCRIPT" status --format json
assert_output_contains "JSON has goal field" '"goal"' bash "$SCRIPT" status --format json
assert_output_contains "JSON has completed count" '"completed"' bash "$SCRIPT" status --format json
assert_output_contains "JSON has interrupted count" '"interrupted"' bash "$SCRIPT" status --format json

# ── --goal flag ───────────────────────────────────────────────────
echo ""
echo "Goal flag:"
# --goal should write the prompt and show it in dry-run
GOAL_OUT=$(bash "$SCRIPT" --goal "my test goal" --dry-run 2>&1)
if echo "$GOAL_OUT" | grep -q "my test goal"; then
  pass "--goal content appears in dry-run output"
else
  fail "--goal content appears in dry-run output" "goal text not found"
fi
# --goal should overwrite existing prompt
OVERWRITE_OUT=$(bash "$SCRIPT" --goal "second goal" --dry-run 2>&1)
if echo "$OVERWRITE_OUT" | grep -q "second goal"; then
  pass "--goal overwrites existing prompt"
else
  fail "--goal overwrites existing prompt" "overwritten goal text not found"
fi
# Restore the original prompt.md
git checkout -- .loopty/prompt.md 2>/dev/null || true
# --goal creates .loopty/ dir when it doesn't exist
GOAL_TMPDIR=$(mktemp -d)
(cd "$GOAL_TMPDIR" && git init -q)
GOAL_FRESH_OUT=$(cd "$GOAL_TMPDIR" && bash "$OLDPWD/$SCRIPT" --goal "fresh goal" --dry-run 2>&1) && GOAL_FRESH_EXIT=0 || GOAL_FRESH_EXIT=$?
if [ "$GOAL_FRESH_EXIT" -eq 0 ] && [ -f "$GOAL_TMPDIR/.loopty/prompt.md" ]; then
  pass "--goal creates .loopty/ dir and prompt file"
else
  fail "--goal creates .loopty/ dir and prompt file" "exit=$GOAL_FRESH_EXIT, file exists=$([ -f \"$GOAL_TMPDIR/.loopty/prompt.md\" ] && echo yes || echo no)"
fi
rm -rf "$GOAL_TMPDIR"

# ── --no-cooldown and --no-commit in dry-run ─────────────────────
echo ""
echo "Flag combinations:"
assert_exit "--no-cooldown with --dry-run exits 0" 0 bash "$SCRIPT" --no-cooldown --dry-run
assert_output_contains "--no-cooldown shows 0s cooldown" "0s between" bash "$SCRIPT" --no-cooldown --dry-run
assert_exit "--no-commit with --dry-run exits 0" 0 bash "$SCRIPT" --no-commit --dry-run
assert_output_contains "--no-commit shows disabled" "disabled" bash "$SCRIPT" --no-commit --dry-run
assert_output_contains "--model shows in dry-run" "test-model" bash "$SCRIPT" -m test-model --dry-run

# Cooldown must be less than interval
assert_exit "cooldown >= interval rejected" 1 bash "$SCRIPT" --cooldown 900 -i 900 --dry-run
assert_output_contains "cooldown >= interval message" "cooldown.*must be less" bash "$SCRIPT" --cooldown 900 -i 900 --dry-run

# ── status text output ───────────────────────────────────────────
echo ""
echo "Status text output:"
assert_output_contains "status shows Goal line" "Goal:" bash "$SCRIPT" status
assert_output_contains "status shows Iterations line" "Iterations:" bash "$SCRIPT" status
assert_output_contains "status shows Duration line" "Duration:" bash "$SCRIPT" status
assert_output_contains "status shows Cumulative line" "Cumulative:" bash "$SCRIPT" status
assert_output_contains "status shows column headers" "Iter" bash "$SCRIPT" status

# ── status verbose shows attempted text ──────────────────────────
echo ""
echo "Status verbose:"
VERBOSE_OUT=$(bash "$SCRIPT" status --verbose 2>&1)
if echo "$VERBOSE_OUT" | grep -qE "Extended|Improved|Added|Bumped|summary"; then
  pass "status --verbose includes journal summaries"
else
  fail "status --verbose includes journal summaries" "no summary text found in verbose output"
fi

# ── status with empty journal dir ────────────────────────────────
echo ""
echo "Status empty journal:"
EMPTY_TMPDIR=$(mktemp -d)
(cd "$EMPTY_TMPDIR" && git init -q && mkdir -p .loopty/journal)
EMPTY_STATUS=$(cd "$EMPTY_TMPDIR" && bash "$OLDPWD/$SCRIPT" status 2>&1) && EMPTY_EXIT=0 || EMPTY_EXIT=$?
if [ "$EMPTY_EXIT" -eq 0 ]; then
  pass "status with no journals exits 0"
else
  fail "status with no journals exits 0" "expected exit 0, got $EMPTY_EXIT"
fi
if echo "$EMPTY_STATUS" | grep -q "No journal entries"; then
  pass "status with no journals shows helpful message"
else
  fail "status with no journals shows helpful message" "expected 'No journal entries' message"
fi
EMPTY_JSON=$(cd "$EMPTY_TMPDIR" && bash "$OLDPWD/$SCRIPT" status --format json 2>&1)
if echo "$EMPTY_JSON" | python3 -m json.tool >/dev/null 2>&1; then
  pass "status --format json with no journals is valid JSON"
else
  fail "status --format json with no journals is valid JSON" "not valid JSON"
fi
if echo "$EMPTY_JSON" | grep -q '"iterations":0'; then
  pass "status json with no journals has iterations:0"
else
  fail "status json with no journals has iterations:0" "iterations field missing or wrong"
fi
rm -rf "$EMPTY_TMPDIR"

# ── wrapup-timeout and work-turns edge cases ─────────
echo ""
echo "Wrapup/work-turns edge cases:"
assert_exit "wrapup-timeout at minimum (30) accepted" 0 bash "$SCRIPT" --wrapup-timeout 30 --dry-run
assert_output_contains "wrapup-timeout 30 shows in config" "30s" bash "$SCRIPT" --wrapup-timeout 30 --dry-run
assert_exit "work-turns 0 (unlimited) accepted" 0 bash "$SCRIPT" -w 0 --dry-run
assert_output_contains "work-turns 0 shows unlimited" "unlimited" bash "$SCRIPT" -w 0 --dry-run
assert_exit "work-turns positive accepted" 0 bash "$SCRIPT" -w 50 --dry-run
assert_output_contains "work-turns positive shows count" "50 turns" bash "$SCRIPT" -w 50 --dry-run

# ── resume numbering ────────────────────────────────────
echo ""
echo "Resume numbering:"
RESUME_TMPDIR=$(mktemp -d)
(cd "$RESUME_TMPDIR" && git init -q && mkdir -p .loopty/journal)
# Create a fake journal with iteration 7
cat > "$RESUME_TMPDIR/.loopty/journal/2024-01-01-120000.md" <<'JRNL'
---
iteration: 7
timestamp: "2024-01-01-120000"
status: completed
work_agent_exit: 0
duration_seconds: 100
files_changed: 1
insertions: 10
deletions: 2
---
# Iteration 7
JRNL
echo "Test goal" > "$RESUME_TMPDIR/.loopty/prompt.md"
RESUME_OUT=$(cd "$RESUME_TMPDIR" && bash "$OLDPWD/$SCRIPT" --resume --dry-run 2>&1)
if echo "$RESUME_OUT" | grep -q "Resuming from iteration 7"; then
  pass "--resume picks up iteration 7 from journal"
else
  fail "--resume picks up iteration 7 from journal" "did not find 'Resuming from iteration 7'"
fi
rm -rf "$RESUME_TMPDIR"

# ── empty prompt file ───────────────────────────────────
echo ""
echo "Empty prompt:"
EMPTY_PROMPT_TMPDIR=$(mktemp -d)
(cd "$EMPTY_PROMPT_TMPDIR" && git init -q && mkdir -p .loopty)
echo "   " > "$EMPTY_PROMPT_TMPDIR/.loopty/prompt.md"
EMPTY_PROMPT_OUT=$(cd "$EMPTY_PROMPT_TMPDIR" && bash "$OLDPWD/$SCRIPT" --dry-run 2>&1) && EMPTY_PROMPT_EXIT=0 || EMPTY_PROMPT_EXIT=$?
if [ "$EMPTY_PROMPT_EXIT" -eq 1 ]; then
  pass "empty/whitespace prompt file rejected"
else
  fail "empty/whitespace prompt file rejected" "expected exit 1, got $EMPTY_PROMPT_EXIT"
fi
if echo "$EMPTY_PROMPT_OUT" | grep -q "empty or whitespace"; then
  pass "empty prompt shows helpful error"
else
  fail "empty prompt shows helpful error" "expected 'empty or whitespace' message"
fi
rm -rf "$EMPTY_PROMPT_TMPDIR"

# ── install --uninstall preserves .loopty/ ──────────────
echo ""
echo "Install uninstall preservation:"
UNINST_TMPDIR=$(mktemp -d)
(cd "$UNINST_TMPDIR" && git init -q)
bash install.sh "$UNINST_TMPDIR" > /dev/null 2>&1
mkdir -p "$UNINST_TMPDIR/.loopty/journal"
echo "test journal" > "$UNINST_TMPDIR/.loopty/journal/test.md"
bash install.sh --uninstall "$UNINST_TMPDIR" > /dev/null 2>&1
if [ -f "$UNINST_TMPDIR/.loopty/journal/test.md" ]; then
  pass "uninstall preserves .loopty/journal/"
else
  fail "uninstall preserves .loopty/journal/" "journal was deleted"
fi
rm -rf "$UNINST_TMPDIR"

# ── version consistency ─────────────────────────────────
echo ""
echo "Version consistency:"
SCRIPT_VERSION=$(bash "$SCRIPT" --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
PLUGIN_VERSION=$(python3 -c "import json; print(json.load(open('.claude-plugin/plugin.json'))['version'])" 2>/dev/null)
MARKETPLACE_VERSION=$(python3 -c "import json; print(json.load(open('.claude-plugin/marketplace.json'))['plugins'][0]['version'])" 2>/dev/null)
if [ "$SCRIPT_VERSION" = "$PLUGIN_VERSION" ]; then
  pass "loopty.sh version matches plugin.json version"
else
  fail "loopty.sh version matches plugin.json version" "script=$SCRIPT_VERSION, plugin=$PLUGIN_VERSION"
fi
if [ "$SCRIPT_VERSION" = "$MARKETPLACE_VERSION" ]; then
  pass "loopty.sh version matches marketplace.json version"
else
  fail "loopty.sh version matches marketplace.json version" "script=$SCRIPT_VERSION, marketplace=$MARKETPLACE_VERSION"
fi

# ── JSON with last_run_summary ────────────────────────────────────
echo ""
echo "JSON last_run field:"
JSON_RUN_TMPDIR=$(mktemp -d)
(cd "$JSON_RUN_TMPDIR" && git init -q && mkdir -p .loopty/journal)
echo "Test goal" > "$JSON_RUN_TMPDIR/.loopty/prompt.md"
# Create a fake journal
cat > "$JSON_RUN_TMPDIR/.loopty/journal/2024-01-01-120000.md" <<'JRNL'
---
iteration: 1
timestamp: "2024-01-01-120000"
status: completed
work_agent_exit: 0
duration_seconds: 100
files_changed: 2
insertions: 20
deletions: 5
---
# Iteration 1
JRNL
# Create a fake run summary
cat > "$JSON_RUN_TMPDIR/.loopty/last-run-summary.md" <<'SUM'
---
status: completed
iterations: 1
elapsed_minutes: 3
agent_duration: 1m40s
files_changed: 2
insertions: 20
deletions: 5
timestamp: "2024-01-01-120200"
---

# Loopty Run Summary
SUM
JSON_RUN_OUT=$(cd "$JSON_RUN_TMPDIR" && bash "$OLDPWD/$SCRIPT" status --format json 2>&1)
if echo "$JSON_RUN_OUT" | python3 -m json.tool >/dev/null 2>&1; then
  pass "JSON with last_run_summary is valid JSON"
else
  fail "JSON with last_run_summary is valid JSON" "not valid JSON"
fi
if echo "$JSON_RUN_OUT" | grep -q '"last_run"'; then
  pass "JSON includes last_run field"
else
  fail "JSON includes last_run field" "last_run not found"
fi
if echo "$JSON_RUN_OUT" | grep -q '"agent_duration"'; then
  pass "JSON last_run has agent_duration"
else
  fail "JSON last_run has agent_duration" "field not found"
fi
rm -rf "$JSON_RUN_TMPDIR"

# ── JSON without last_run_summary ─────────────────────────────────
echo ""
echo "JSON without last_run:"
JSON_NORUN_TMPDIR=$(mktemp -d)
(cd "$JSON_NORUN_TMPDIR" && git init -q && mkdir -p .loopty/journal)
echo "Test goal" > "$JSON_NORUN_TMPDIR/.loopty/prompt.md"
cat > "$JSON_NORUN_TMPDIR/.loopty/journal/2024-01-01-120000.md" <<'JRNL'
---
iteration: 1
timestamp: "2024-01-01-120000"
status: completed
work_agent_exit: 0
duration_seconds: 100
files_changed: 1
insertions: 10
deletions: 2
---
# Iteration 1
JRNL
JSON_NORUN_OUT=$(cd "$JSON_NORUN_TMPDIR" && bash "$OLDPWD/$SCRIPT" status --format json 2>&1)
if echo "$JSON_NORUN_OUT" | python3 -m json.tool >/dev/null 2>&1; then
  pass "JSON without run summary is valid JSON"
else
  fail "JSON without run summary is valid JSON" "not valid JSON"
fi
if ! echo "$JSON_NORUN_OUT" | grep -q '"last_run"'; then
  pass "JSON omits last_run when no summary file"
else
  fail "JSON omits last_run when no summary file" "last_run should not be present"
fi
rm -rf "$JSON_NORUN_TMPDIR"

# ── json_escape handles control chars ─────────────────────────────
echo ""
echo "JSON escaping:"
# Create a journal with a carriage return in the summary to test escaping
JSON_ESC_TMPDIR=$(mktemp -d)
(cd "$JSON_ESC_TMPDIR" && git init -q && mkdir -p .loopty/journal)
echo "Test goal" > "$JSON_ESC_TMPDIR/.loopty/prompt.md"
printf -- '---\niteration: 1\ntimestamp: "2024-01-01-120000"\nstatus: completed\nwork_agent_exit: 0\nduration_seconds: 100\nfiles_changed: 1\ninsertions: 10\ndeletions: 2\n---\n# Iteration 1\n\n## What was attempted\nFixed a "quote" and a tab\there.\n' > "$JSON_ESC_TMPDIR/.loopty/journal/2024-01-01-120000.md"
JSON_ESC_OUT=$(cd "$JSON_ESC_TMPDIR" && bash "$OLDPWD/$SCRIPT" status --format json 2>&1)
if echo "$JSON_ESC_OUT" | python3 -m json.tool >/dev/null 2>&1; then
  pass "JSON with special chars is valid JSON"
else
  fail "JSON with special chars is valid JSON" "not valid JSON: $JSON_ESC_OUT"
fi
rm -rf "$JSON_ESC_TMPDIR"

# ── lock file tests ──────────────────────────────────────────────
echo ""
echo "Lock file:"
LOCK_TMPDIR=$(mktemp -d)
(cd "$LOCK_TMPDIR" && git init -q && mkdir -p .loopty/journal)
echo "Test goal" > "$LOCK_TMPDIR/.loopty/prompt.md"

# Test that lock dir is created (simulate by sourcing acquire_lock)
mkdir "$LOCK_TMPDIR/.loopty/lock.d" 2>/dev/null
echo "99999999" > "$LOCK_TMPDIR/.loopty/lock.d/pid"
# A second attempt should fail because lock exists (PID won't be valid but mkdir will fail)
LOCK_OUT=$(cd "$LOCK_TMPDIR" && PATH="/dev/null:$PATH" bash "$OLDPWD/$SCRIPT" --dry-run 2>&1 || true)
# Since --dry-run exits before acquire_lock, test with a mock
# Instead: test stale lock cleanup — the PID 99999999 shouldn't exist
rm -rf "$LOCK_TMPDIR/.loopty/lock.d"
# Create lock with current PID to simulate active lock
mkdir "$LOCK_TMPDIR/.loopty/lock.d"
echo $$ > "$LOCK_TMPDIR/.loopty/lock.d/pid"
# Trying to run should fail because our PID is alive
LOCK_OUT2=$(cd "$LOCK_TMPDIR" && bash "$OLDPWD/$SCRIPT" 2>&1; echo "EXIT:$?")
if echo "$LOCK_OUT2" | grep -q "another loopty instance"; then
  pass "concurrent run blocked by lock file"
else
  fail "concurrent run blocked by lock file" "$LOCK_OUT2"
fi
# Stale lock (dead PID 99999999) should be cleaned up and not block a run
rm -rf "$LOCK_TMPDIR/.loopty/lock.d"
mkdir "$LOCK_TMPDIR/.loopty/lock.d"
echo "99999999" > "$LOCK_TMPDIR/.loopty/lock.d/pid"
# Run the script — it should clean up the stale lock and proceed (will fail at claude invocation, but that's fine)
STALE_OUT=$(cd "$LOCK_TMPDIR" && bash "$OLDPWD/$SCRIPT" -n 1 2>&1; echo "EXIT:$?")
# If it got past the lock (no "another loopty instance" error), the stale lock was cleaned
if echo "$STALE_OUT" | grep -q "another loopty instance"; then
  fail "stale lock with dead PID is cleaned up" "lock was not cleaned up"
else
  pass "stale lock with dead PID is cleaned up"
fi
# Verify lock dir was cleaned/recreated (not the old stale one)
if [ -d "$LOCK_TMPDIR/.loopty/lock.d" ] && [ -f "$LOCK_TMPDIR/.loopty/lock.d/pid" ]; then
  LOCK_PID=$(cat "$LOCK_TMPDIR/.loopty/lock.d/pid" 2>/dev/null)
  if [ "$LOCK_PID" != "99999999" ]; then
    pass "stale lock PID was replaced"
  else
    fail "stale lock PID was replaced" "still has stale PID"
  fi
else
  # Lock dir cleaned up by EXIT trap — also acceptable
  pass "stale lock PID was replaced"
fi
rm -rf "$LOCK_TMPDIR"

# ── YAML parsing edge cases ─────────────────────────────────────
echo ""
echo "YAML parsing:"
YAML_TMPDIR=$(mktemp -d)
(cd "$YAML_TMPDIR" && git init -q && mkdir -p .loopty/journal)
echo "Test goal" > "$YAML_TMPDIR/.loopty/prompt.md"

# Test colon in value
cat > "$YAML_TMPDIR/.loopty/journal/2024-01-01-120000.md" <<'YAMLTEST'
---
iteration: 1
timestamp: "2024-01-01-120000"
status: completed
work_agent_exit: 0
duration_seconds: 100
files_changed: 1
insertions: 10
deletions: 2
---
# Test
YAMLTEST

# fm_val should extract "2024-01-01-120000" (with colons and quotes)
YAML_OUT=$(cd "$YAML_TMPDIR" && bash "$OLDPWD/$SCRIPT" status --format json 2>&1)
if echo "$YAML_OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d['entries'][0]['timestamp'] == '2024-01-01-120000'" 2>/dev/null; then
  pass "YAML parsing handles quoted values with special chars"
else
  fail "YAML parsing handles quoted values with special chars" "$YAML_OUT"
fi

# Test value with no space after colon
cat > "$YAML_TMPDIR/.loopty/journal/2024-01-02-120000.md" <<'YAMLTEST2'
---
iteration: 2
timestamp:"2024-01-02-120000"
status:completed
work_agent_exit: 0
duration_seconds: 100
files_changed: 0
insertions: 0
deletions: 0
---
# Test 2
YAMLTEST2
YAML_OUT2=$(cd "$YAML_TMPDIR" && bash "$OLDPWD/$SCRIPT" status --format json 2>&1)
if echo "$YAML_OUT2" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d['entries'][0]['timestamp'] == '2024-01-02-120000'" 2>/dev/null; then
  pass "YAML parsing handles missing space after colon"
else
  fail "YAML parsing handles missing space after colon" "$YAML_OUT2"
fi
rm -rf "$YAML_TMPDIR"

# ── lock release guard ──────────────────────────────────────────
echo ""
echo "Lock release guard:"
# Verify the script uses LOCK_HELD guard to prevent double-release
if grep -q 'LOCK_HELD=0' "$SCRIPT" && grep -q 'LOCK_HELD=1' "$SCRIPT" && grep -q 'if \[ "\$LOCK_HELD" -eq 1 \]' "$SCRIPT"; then
  pass "release_lock uses LOCK_HELD guard (no double-release)"
else
  fail "release_lock uses LOCK_HELD guard (no double-release)" "LOCK_HELD guard not found in script"
fi

# ── marketplace.json ────────────────────────────────────────────
echo ""
echo "Marketplace metadata:"
MARKETPLACE=".claude-plugin/marketplace.json"
if [ -f "$MARKETPLACE" ]; then
  pass "marketplace.json exists"
else
  fail "marketplace.json exists" "file not found"
fi
if python3 -m json.tool "$MARKETPLACE" >/dev/null 2>&1; then
  pass "marketplace.json is valid JSON"
else
  fail "marketplace.json is valid JSON" "not valid JSON"
fi
if python3 -c "import json; d=json.load(open('$MARKETPLACE')); assert 'plugins' in d and len(d['plugins']) > 0" 2>/dev/null; then
  pass "marketplace.json has plugins array"
else
  fail "marketplace.json has plugins array" "missing or empty plugins"
fi
# Marketplace source type should be "url" (not "source")
MKT_SOURCE_TYPE=$(python3 -c "import json; print(json.load(open('$MARKETPLACE'))['plugins'][0]['source']['type'])" 2>/dev/null)
if [ "$MKT_SOURCE_TYPE" = "url" ]; then
  pass "marketplace.json source type is 'url'"
else
  fail "marketplace.json source type is 'url'" "got '$MKT_SOURCE_TYPE'"
fi
# Version in marketplace should match plugin.json
MKT_VERSION=$(python3 -c "import json; print(json.load(open('$MARKETPLACE'))['plugins'][0]['version'])" 2>/dev/null)
if [ "$MKT_VERSION" = "$PLUGIN_VERSION" ]; then
  pass "marketplace.json version matches plugin.json"
else
  fail "marketplace.json version matches plugin.json" "marketplace=$MKT_VERSION, plugin=$PLUGIN_VERSION"
fi

# ── prompt.md.example ───────────────────────────────────────────
echo ""
echo "Prompt example:"
EXAMPLE=".loopty/prompt.md.example"
if [ -f "$EXAMPLE" ]; then
  pass "prompt.md.example exists"
else
  fail "prompt.md.example exists" "file not found"
fi
if grep -q "Success criteria" "$EXAMPLE" 2>/dev/null; then
  pass "prompt.md.example has Success criteria section"
else
  fail "prompt.md.example has Success criteria section" "missing section"
fi

# ── --no-spin-check flag ────────────────────────────────────────
echo ""
echo "Spin check flag:"
SPIN_TMPDIR=$(mktemp -d)
(cd "$SPIN_TMPDIR" && git init -q && mkdir -p .loopty/journal)
echo "Test goal" > "$SPIN_TMPDIR/.loopty/prompt.md"
SPIN_OUT=$(cd "$SPIN_TMPDIR" && bash "$OLDPWD/$SCRIPT" --no-spin-check --dry-run 2>&1)
if echo "$SPIN_OUT" | grep -q "dry run"; then
  pass "--no-spin-check accepted as valid flag"
else
  fail "--no-spin-check accepted as valid flag" "$SPIN_OUT"
fi
if echo "$SPIN_OUT" | grep -q "Spin check:.*disabled"; then
  pass "--no-spin-check shown in config"
else
  fail "--no-spin-check shown in config" "expected 'Spin check: disabled' in output"
fi
rm -rf "$SPIN_TMPDIR"

# ── install script ─────────────────────────────────────────────────
echo ""
echo "Install script:"
INSTALL_SCRIPT="./install.sh"

# Fresh install into empty target
INST_TMPDIR=$(mktemp -d)
(cd "$INST_TMPDIR" && git init -q)
INST_OUT=$(bash "$INSTALL_SCRIPT" "$INST_TMPDIR" 2>&1)
if [ -f "$INST_TMPDIR/loopty.sh" ] && [ -f "$INST_TMPDIR/.claude/commands/loopty.md" ]; then
  pass "install creates loopty.sh and slash command"
else
  fail "install creates loopty.sh and slash command" "missing files"
fi
if [ -f "$INST_TMPDIR/skills/loopty/SKILL.md" ]; then
  pass "install copies SKILL.md"
else
  fail "install copies SKILL.md" "missing skills/loopty/SKILL.md"
fi
if [ -f "$INST_TMPDIR/.claude-plugin/plugin.json" ]; then
  pass "install copies plugin.json"
else
  fail "install copies plugin.json" "missing .claude-plugin/plugin.json"
fi
if [ -d "$INST_TMPDIR/.loopty" ]; then
  pass "install creates .loopty directory"
else
  fail "install creates .loopty directory" "missing .loopty/"
fi
if grep -q '\.loopty/journal' "$INST_TMPDIR/.gitignore" 2>/dev/null; then
  pass "install updates .gitignore"
else
  fail "install updates .gitignore" "missing .loopty/journal entry"
fi
if grep -q '## loopty' "$INST_TMPDIR/CLAUDE.md" 2>/dev/null; then
  pass "install appends to CLAUDE.md"
else
  fail "install appends to CLAUDE.md" "missing loopty section"
fi

# Check prompt.md.example was copied
if [ -f "$INST_TMPDIR/.loopty/prompt.md.example" ]; then
  pass "install copies prompt.md.example"
else
  fail "install copies prompt.md.example" "file not found"
fi

# Idempotent re-install (should say "unchanged, skipped")
INST_OUT2=$(bash "$INSTALL_SCRIPT" "$INST_TMPDIR" 2>&1)
if echo "$INST_OUT2" | grep -q "unchanged, skipped"; then
  pass "re-install is idempotent (skips unchanged files)"
else
  fail "re-install is idempotent (skips unchanged files)" "$INST_OUT2"
fi

# Uninstall
UNINST_OUT=$(bash "$INSTALL_SCRIPT" --uninstall "$INST_TMPDIR" 2>&1)
if [ ! -f "$INST_TMPDIR/loopty.sh" ] && [ ! -f "$INST_TMPDIR/.claude/commands/loopty.md" ]; then
  pass "uninstall removes loopty.sh and slash command"
else
  fail "uninstall removes loopty.sh and slash command" "files still present"
fi
if [ ! -d "$INST_TMPDIR/skills/loopty" ]; then
  pass "uninstall removes skills/loopty/"
else
  fail "uninstall removes skills/loopty/" "directory still present"
fi
if [ ! -d "$INST_TMPDIR/.claude-plugin" ]; then
  pass "uninstall removes .claude-plugin/"
else
  fail "uninstall removes .claude-plugin/" "directory still present"
fi
if [ -d "$INST_TMPDIR/.loopty" ]; then
  pass "uninstall preserves .loopty/ (journals)"
else
  fail "uninstall preserves .loopty/ (journals)" ".loopty/ was removed"
fi
# Verify uninstall removes loopty section from CLAUDE.md
# Re-install to get a fresh CLAUDE.md with loopty section, then uninstall
UNINST_CLAUDE_TMPDIR=$(mktemp -d)
bash "$INSTALL_SCRIPT" "$UNINST_CLAUDE_TMPDIR" >/dev/null 2>&1
# Add some other content so we can verify it's preserved
echo -e "\n## other-section\n\nKeep this." >> "$UNINST_CLAUDE_TMPDIR/CLAUDE.md"
bash "$INSTALL_SCRIPT" --uninstall "$UNINST_CLAUDE_TMPDIR" >/dev/null 2>&1
if [ -f "$UNINST_CLAUDE_TMPDIR/CLAUDE.md" ] && ! grep -q '## loopty' "$UNINST_CLAUDE_TMPDIR/CLAUDE.md"; then
  pass "uninstall removes loopty section from CLAUDE.md"
else
  fail "uninstall removes loopty section from CLAUDE.md" "loopty section still present"
fi
if grep -q '## other-section' "$UNINST_CLAUDE_TMPDIR/CLAUDE.md" 2>/dev/null; then
  pass "uninstall preserves other CLAUDE.md sections"
else
  fail "uninstall preserves other CLAUDE.md sections" "other section was removed"
fi
rm -rf "$UNINST_CLAUDE_TMPDIR"
# Verify gitignore includes lock.d
INST_TMPDIR2=$(mktemp -d)
bash "$INSTALL_SCRIPT" "$INST_TMPDIR2" >/dev/null 2>&1
if grep -q 'lock\.d' "$INST_TMPDIR2/.gitignore"; then
  pass "install adds lock.d to gitignore"
else
  fail "install adds lock.d to gitignore" "lock.d not in .gitignore"
fi
rm -rf "$INST_TMPDIR2"

rm -rf "$INST_TMPDIR"

# Install --help
INST_HELP=$(bash "$INSTALL_SCRIPT" --help 2>&1) || true
if echo "$INST_HELP" | grep -q "TARGET_DIR"; then
  pass "install --help shows usage"
else
  fail "install --help shows usage" "$INST_HELP"
fi

# Install into nonexistent directory
INST_BAD=$(bash "$INSTALL_SCRIPT" "/tmp/nonexistent_loopty_test_$$" 2>&1) && BAD_EXIT=0 || BAD_EXIT=$?
if [ "$BAD_EXIT" -ne 0 ]; then
  pass "install rejects nonexistent target directory"
else
  fail "install rejects nonexistent target directory" "exit 0"
fi

# ── plugin file consistency ──────────────────────────────────────
echo ""
echo "Plugin file consistency:"
# Verify all files listed in plugin.json actually exist
PLUGIN_FILES=$(python3 -c "import json; [print(f) for f in json.load(open('.claude-plugin/plugin.json'))['files']]" 2>/dev/null)
PLUGIN_FILES_OK=1
while IFS= read -r pf; do
  if [ ! -f "$pf" ]; then
    PLUGIN_FILES_OK=0
    break
  fi
done <<< "$PLUGIN_FILES"
if [ "$PLUGIN_FILES_OK" -eq 1 ]; then
  pass "all files listed in plugin.json exist"
else
  fail "all files listed in plugin.json exist" "missing: $pf"
fi

# Verify plugin.json skills path exists
SKILL_PATH=$(python3 -c "import json; print(json.load(open('.claude-plugin/plugin.json'))['skills'][0]['path'])" 2>/dev/null)
if [ -f "$SKILL_PATH" ]; then
  pass "plugin.json skill path ($SKILL_PATH) exists"
else
  fail "plugin.json skill path ($SKILL_PATH) exists" "file not found"
fi

# Verify plugin.json commands path exists
CMD_PATH=$(python3 -c "import json; print(json.load(open('.claude-plugin/plugin.json'))['commands'][0]['path'])" 2>/dev/null)
if [ -f "$CMD_PATH" ]; then
  pass "plugin.json command path ($CMD_PATH) exists"
else
  fail "plugin.json command path ($CMD_PATH) exists" "file not found"
fi

# Verify SKILL.md has user-invocable: true
if grep -q 'user-invocable: true' skills/loopty/SKILL.md 2>/dev/null; then
  pass "SKILL.md is user-invocable"
else
  fail "SKILL.md is user-invocable" "user-invocable: true not found"
fi

# Verify README mentions both install methods
if grep -q 'claude install' README.md && grep -q 'install.sh' README.md; then
  pass "README documents both install methods"
else
  fail "README documents both install methods" "missing install method"
fi

# Verify --no-spin-check is documented in README
if grep -q 'no-spin-check' README.md; then
  pass "README documents --no-spin-check"
else
  fail "README documents --no-spin-check" "missing from README"
fi

# Verify --no-spin-check is in SKILL.md
if grep -q 'no-spin-check' skills/loopty/SKILL.md; then
  pass "SKILL.md documents --no-spin-check"
else
  fail "SKILL.md documents --no-spin-check" "missing from SKILL.md"
fi

# ── --quiet flag ────────────────────────────────────────────────
echo ""
echo "Quiet flag:"
QUIET_OUT=$(bash "$SCRIPT" --quiet --dry-run 2>&1)
# --quiet should suppress the banner box but still show dry-run output
if echo "$QUIET_OUT" | grep -q "dry run"; then
  pass "--quiet still shows dry-run exit message"
else
  fail "--quiet still shows dry-run exit message" "expected 'dry run' in output"
fi
# The banner box lines (═ characters) should NOT appear in quiet mode
if echo "$QUIET_OUT" | grep -q "╔"; then
  fail "--quiet suppresses banner box" "banner box still present"
else
  pass "--quiet suppresses banner box"
fi

# ── cumulative stats in JSON ────────────────────────────────────
echo ""
echo "Cumulative stats in JSON:"
CUM_TMPDIR=$(mktemp -d)
(cd "$CUM_TMPDIR" && git init -q && mkdir -p .loopty/journal)
echo "Test goal" > "$CUM_TMPDIR/.loopty/prompt.md"
# Create two journals with known metrics
cat > "$CUM_TMPDIR/.loopty/journal/2024-01-01-120000.md" <<'J1'
---
iteration: 1
timestamp: "2024-01-01-120000"
status: completed
work_agent_exit: 0
duration_seconds: 100
files_changed: 3
insertions: 30
deletions: 10
---
# Iteration 1
## What was attempted
First iteration work.
J1
cat > "$CUM_TMPDIR/.loopty/journal/2024-01-02-120000.md" <<'J2'
---
iteration: 2
timestamp: "2024-01-02-120000"
status: interrupted
work_agent_exit: signal
duration_seconds: 50
files_changed: 2
insertions: 15
deletions: 5
---
# Iteration 2
## What was attempted
Second iteration interrupted.
J2
CUM_JSON=$(cd "$CUM_TMPDIR" && bash "$OLDPWD/$SCRIPT" status --format json 2>&1)
# Verify cumulative totals: files=5, ins=45, del=15, dur=150
if echo "$CUM_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); c=d['cumulative']; assert c['files_changed']==5 and c['insertions']==45 and c['deletions']==15 and c['duration_seconds']==150, f'got {c}'" 2>/dev/null; then
  pass "JSON cumulative stats sum correctly across entries"
else
  fail "JSON cumulative stats sum correctly across entries" "$CUM_JSON"
fi
# Verify status counts: 1 completed, 1 interrupted
if echo "$CUM_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d['completed']==1 and d['interrupted']==1, f'got c={d[\"completed\"]} i={d[\"interrupted\"]}'" 2>/dev/null; then
  pass "JSON status counts are correct"
else
  fail "JSON status counts are correct" "$CUM_JSON"
fi
rm -rf "$CUM_TMPDIR"

# ── multiple flags combined ────────────────────────────────────
echo ""
echo "Combined flags:"
assert_exit "--resume --no-commit --no-cooldown --dry-run exits 0" 0 bash "$SCRIPT" --resume --no-commit --no-cooldown --dry-run
COMBO_OUT=$(bash "$SCRIPT" --resume --no-commit --no-cooldown --no-spin-check --dry-run 2>&1)
if echo "$COMBO_OUT" | grep -q "disabled" && echo "$COMBO_OUT" | grep -q "0s between"; then
  pass "multiple flags reflected in config"
else
  fail "multiple flags reflected in config" "$COMBO_OUT"
fi

# ── install idempotent CLAUDE.md ────────────────────────────────
echo ""
echo "Install CLAUDE.md idempotent:"
CLMD_TMPDIR=$(mktemp -d)
(cd "$CLMD_TMPDIR" && git init -q)
# Install twice — CLAUDE.md should only have one loopty section
bash "$INSTALL_SCRIPT" "$CLMD_TMPDIR" > /dev/null 2>&1
bash "$INSTALL_SCRIPT" "$CLMD_TMPDIR" > /dev/null 2>&1
LOOPTY_SECTIONS=$(grep -c '## loopty' "$CLMD_TMPDIR/CLAUDE.md" 2>/dev/null)
if [ "$LOOPTY_SECTIONS" -eq 1 ]; then
  pass "re-install doesn't duplicate CLAUDE.md section"
else
  fail "re-install doesn't duplicate CLAUDE.md section" "found $LOOPTY_SECTIONS sections"
fi
rm -rf "$CLMD_TMPDIR"

# ── install idempotent .gitignore ───────────────────────────────
echo ""
echo "Install gitignore idempotent:"
GI_TMPDIR=$(mktemp -d)
(cd "$GI_TMPDIR" && git init -q)
bash "$INSTALL_SCRIPT" "$GI_TMPDIR" > /dev/null 2>&1
bash "$INSTALL_SCRIPT" "$GI_TMPDIR" > /dev/null 2>&1
GI_ENTRIES=$(grep -c '\.loopty/journal' "$GI_TMPDIR/.gitignore" 2>/dev/null)
if [ "$GI_ENTRIES" -eq 1 ]; then
  pass "re-install doesn't duplicate .gitignore entries"
else
  fail "re-install doesn't duplicate .gitignore entries" "found $GI_ENTRIES entries"
fi
rm -rf "$GI_TMPDIR"

# ── box alignment ──────────────────────────────────────────────────
echo ""
echo "Box alignment:"
# All box lines should be the same character count
BOX_OUTPUT=$(bash "$SCRIPT" --dry-run 2>&1)
BOX_TOP_LEN=$(echo "$BOX_OUTPUT" | head -1 | wc -m | tr -d ' ')
BOX_TITLE_LEN=$(echo "$BOX_OUTPUT" | sed -n '2p' | wc -m | tr -d ' ')
BOX_CONTENT_LEN=$(echo "$BOX_OUTPUT" | sed -n '4p' | wc -m | tr -d ' ')
if [ "$BOX_TOP_LEN" -eq "$BOX_TITLE_LEN" ]; then
  pass "box title line aligns with border"
else
  fail "box title line aligns with border" "top=$BOX_TOP_LEN, title=$BOX_TITLE_LEN"
fi
if [ "$BOX_TOP_LEN" -eq "$BOX_CONTENT_LEN" ]; then
  pass "box content lines align with border"
else
  fail "box content lines align with border" "top=$BOX_TOP_LEN, content=$BOX_CONTENT_LEN"
fi

# ── help completeness ─────────────────────────────────────────────
echo ""
echo "Help completeness:"
HELP_OUT=$(bash "$SCRIPT" --help 2>&1)
for flag in "--interval" "--max-iters" "--model" "--max-turns" "--work-turns" "--wrapup-timeout" "--cooldown" "--no-cooldown" "--no-commit" "--no-spin-check" "--verbose" "--format" "--goal" "--resume" "--dry-run" "--quiet" "--help" "--version"; do
  if echo "$HELP_OUT" | grep -q -- "$flag"; then
    pass "--help documents $flag"
  else
    fail "--help documents $flag" "flag not found in help output"
  fi
done

# ── --goal edge cases ────────────────────────────────────────────
echo ""
echo "Goal edge cases:"
assert_exit "--goal with whitespace-only rejected" 1 bash "$SCRIPT" --goal "   " --dry-run
assert_output_contains "--goal whitespace error message" "empty or whitespace" bash "$SCRIPT" --goal "   " --dry-run
# Verify whitespace goal doesn't overwrite existing prompt
GOAL_GUARD_TMPDIR=$(mktemp -d)
(cd "$GOAL_GUARD_TMPDIR" && git init -q && mkdir -p .loopty)
echo "My real goal" > "$GOAL_GUARD_TMPDIR/.loopty/prompt.md"
(cd "$GOAL_GUARD_TMPDIR" && bash "$OLDPWD/$SCRIPT" --goal "   " --dry-run 2>/dev/null) || true
GOAL_AFTER=$(cat "$GOAL_GUARD_TMPDIR/.loopty/prompt.md")
if [ "$GOAL_AFTER" = "My real goal" ]; then
  pass "--goal whitespace doesn't overwrite existing prompt"
else
  fail "--goal whitespace doesn't overwrite existing prompt" "prompt was overwritten to: $GOAL_AFTER"
fi
rm -rf "$GOAL_GUARD_TMPDIR"

# ── work agent prompt context ────────────────────────────────────
echo ""
echo "Work agent context:"
# Verify the cumulative stats format in the agent prompt renders correctly
CUM_TMPDIR2=$(mktemp -d)
(cd "$CUM_TMPDIR2" && git init -q && mkdir -p .loopty/journal)
echo "Test goal" > "$CUM_TMPDIR2/.loopty/prompt.md"
cat > "$CUM_TMPDIR2/.loopty/journal/2024-01-01-120000.md" <<'J1'
---
iteration: 1
timestamp: "2024-01-01-120000"
status: completed
work_agent_exit: 0
duration_seconds: 125
files_changed: 3
insertions: 30
deletions: 10
---
# Iteration 1
## What was attempted
First iteration.
J1
# Verify work agent wait uses safe pattern (won't crash on non-zero exit due to set -e)
if grep -q 'WORK_EXIT=0' "$SCRIPT" && grep -q 'wait.*|| WORK_EXIT=' "$SCRIPT"; then
  pass "work agent wait uses set -e safe pattern"
else
  fail "work agent wait uses set -e safe pattern" "pattern not found"
fi

# Check that fm_val correctly sums duration for display
DUR_VAL=$(cd "$CUM_TMPDIR2" && bash -c 'source '"$OLDPWD"'/loopty.sh --help 2>/dev/null; exit 0' 2>&1 || true)
# Instead, verify the script has the correct format string for agent time
if grep -q 'CUM_ITER_DUR / 60))m\$((CUM_ITER_DUR % 60))s' "$SCRIPT"; then
  pass "cumulative agent time shows minutes and seconds"
else
  fail "cumulative agent time shows minutes and seconds" "format string not found"
fi
rm -rf "$CUM_TMPDIR2"

echo ""
echo "Wrap-up agent wait safety:"
# Verify wrap-up agent wait uses set -e safe pattern (WRAPUP_EXIT pre-init + || capture)
if grep -q 'WRAPUP_EXIT=0' "$SCRIPT" && grep -q 'wait.*|| WRAPUP_EXIT=' "$SCRIPT"; then
  pass "wrap-up agent wait uses set -e safe pattern"
else
  fail "wrap-up agent wait uses set -e safe pattern" "WRAPUP_EXIT pattern not found"
fi

# Verify wrap-up retry logs include exit code
if grep -q 'exit \$WRAPUP_EXIT' "$SCRIPT"; then
  pass "wrap-up retry log includes exit code"
else
  fail "wrap-up retry log includes exit code" "exit code not in retry message"
fi

# Verify wrap-up handles timeout (exit 124) distinctly
if grep -q 'WRAPUP_EXIT.*-eq 124' "$SCRIPT"; then
  pass "wrap-up distinguishes timeout from other failures"
else
  fail "wrap-up distinguishes timeout from other failures" "124 check not found"
fi

echo ""
echo "Cooldown interrupt handling:"
# Verify cooldown uses backgrounded sleep + wait for signal responsiveness
if grep -A3 'Cooling down' "$SCRIPT" | grep -q 'sleep.*&'; then
  pass "cooldown sleep is backgrounded for signal responsiveness"
else
  fail "cooldown sleep is backgrounded for signal responsiveness" "sleep not backgrounded"
fi

# Verify cooldown checks INTERRUPTED after sleep
if grep -A6 'Cooling down' "$SCRIPT" | grep -q 'INTERRUPTED.*-eq 1.*break'; then
  pass "cooldown checks for interrupt after sleep"
else
  fail "cooldown checks for interrupt after sleep" "interrupt check not found after cooldown"
fi

# ── summary ───────────────────────────────────────────────────────
echo ""
echo "═════════════════"
TOTAL=$((PASS + FAIL))
echo "$PASS/$TOTAL passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
