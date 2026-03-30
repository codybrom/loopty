---
name: loopty
description: Start an iterative development loop. Each iteration spins up a fresh, isolated Claude agent that works toward a goal, writes a timestamped journal entry, and commits — then hands off to the next agent.
argument-hint: "[goal or 'status'] [interval] [iterations]"
user-invocable: true
metadata:
  allowed-tools: Read, Write, Edit, Bash, Glob, Grep, Agent
---

Start an iterative development loop. Each iteration spins up a fresh, isolated Claude agent that works toward a goal, writes a timestamped journal entry, and commits — then hands off to the next agent.

## Usage

The user may provide arguments to customize the run. Parse $ARGUMENTS for any of:

- A time interval (e.g., "10m", "30m", "600") — defaults to 15m
- A max iteration count (e.g., "3 iterations", "5x", "n=3") — defaults to unlimited
- A prompt file path (ending in .md) — defaults to .loopty/prompt.md
- An inline goal in quotes (e.g., "improve test coverage") — creates/updates .loopty/prompt.md
- "status" — show journal history summary instead of starting a loop
- "resume" or "--resume" — continue iteration numbering from last journal
- "no-spin-check" or "--no-spin-check" — disable spin/stall detection
- "dry-run" or "--dry-run" — show config without starting
- "quiet" or "--quiet" — suppress banner output
- "verbose" or "--verbose" or "-V" — show detailed journal content in status
- "json" or "--format json" — machine-readable JSON output for status

## Steps

### Bootstrap (first time only):

If `loopty.sh` is not present in the project root, the skill needs to be bootstrapped.

To find the plugin source files, resolve this path relative to this SKILL.md:

- `SKILL_DIR` is the directory containing this file (skills/loopty/)
- `PLUGIN_ROOT` is two levels up from SKILL_DIR (the repo root)

Run the install script from the plugin root:

```bash
bash "$PLUGIN_ROOT/install.sh" "$(pwd)"
```

If `install.sh` is not found, bootstrap manually:

1. Copy `$PLUGIN_ROOT/loopty.sh` to the project root
2. Copy `$PLUGIN_ROOT/.claude/commands/loopty.md` to the project's `.claude/commands/`
3. Create `.loopty/` directory and copy `$PLUGIN_ROOT/.loopty/prompt.md.example`
4. Tell the user that loopty has been bootstrapped into their project

### If "status" mode:

1. Run `bash loopty.sh status` and present the output
2. Read `.loopty/last-run-summary.md` if it exists for additional context
3. Do NOT start a loop

### If normal run mode:

1. Check that `.loopty/prompt.md` exists. If not:
   - If the user provided an inline goal in quotes, create the prompt file with that goal
   - Otherwise, ask the user what their iterative goal is and create it for them
   - The prompt should describe: the goal, success criteria, and constraints

2. Parse arguments to build CLI flags:
   - Time like "10m" → `-i 600`
   - Time like "30m" → `-i 1800`
   - Time like "600" (bare number > 59) → `-i 600`
   - Iterations like "3 iterations" or "3x" or "n=3" → `-n 3`
   - "resume" or "--resume" → `--resume`
   - "--dry-run" or "dry-run" → `--dry-run`
   - "quiet" or "--quiet" → `--quiet`
   - Work turns like "w=50" or "--work-turns 50" → `-w 50`
   - Inline goal in quotes → `-g "the goal text"`
   - Model override → `-m MODEL`
   - Wrapup timeout like "wrapup-timeout=60" → `--wrapup-timeout 60`
   - Cooldown like "cooldown=5" → `--cooldown 5`
   - "no-cooldown" or "--no-cooldown" → `--no-cooldown`
   - "no-commit" or "--no-commit" → `--no-commit`
   - "no-spin-check" or "--no-spin-check" → `--no-spin-check`
   - "verbose" or "--verbose" or "-V" → `--verbose`
   - "json" or "--format json" → `--format json`

3. Confirm the settings with the user before starting:
   - Show the prompt content (first ~10 lines if long)
   - Show the interval and max iterations
   - Show how many previous journal entries exist in `.loopty/journal/`
   - If --dry-run, run the script with --dry-run and show output, then stop
   - Otherwise, ask for confirmation to begin

4. Run the loop script:

   ```bash
   bash ./loopty.sh [flags]
   ```

   This will run in the foreground. Each iteration:
   - Launches an isolated `claude -p` agent with the goal + previous journals
   - After the time budget, a wrap-up agent writes a journal entry
   - All changes are committed with git

5. When the loop finishes (max iterations reached or interrupted), summarize:
   - How many iterations ran
   - Key findings from the journal entries
   - What the next agent would work on
   - Reference `.loopty/last-run-summary.md` for full details
