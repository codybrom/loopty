# loopty

Iterative AI development loop tool. Spins up isolated Claude agents in a loop, each building on the journal notes of the previous one.

## Structure

- `loopty.sh` — main loop script with CLI argument parsing
- `install.sh` — installer script for adding loopty to other projects
- `test.sh` — CLI test suite (run with `bash test.sh`)
- `.claude-plugin/plugin.json` — plugin manifest
- `.claude-plugin/marketplace.json` — marketplace listing
- `skills/loopty/SKILL.md` — Claude Code plugin skill definition
- `.loopty/prompt.md` — the user's iteration goal (create this to start)
- `.loopty/journal/` — timestamped markdown journals from each iteration (YAML frontmatter: iteration, timestamp, status, work_agent_exit, duration_seconds, files_changed, insertions, deletions)
- `.loopty/last-run-summary.md` — summary of the most recent run
- `.claude/commands/loopty.md` — slash command entry point (`/loopty`)

## How it works

1. User writes a goal in `.loopty/prompt.md`
2. `/loopty` (or `bash loopty.sh`) starts the loop
3. Each iteration: fresh agent works → wrap-up agent writes journal → git commit
4. Next agent reads last 3 journals for continuity
5. On completion or Ctrl+C, a run summary is written

## CLI usage

```bash
bash loopty.sh [OPTIONS] [PROMPT_FILE]
bash loopty.sh status

Subcommands:
  status                   Show journal history and run summary

Options:
  --interval, -i SECONDS   Time per iteration (default: 900)
  --max-iters, -n COUNT    Max iterations (default: 0 = unlimited)
  --model, -m MODEL        Model override
  --max-turns, -t TURNS    Wrap-up turns (default: 5)
  --work-turns, -w TURNS   Work agent turns (default: 0 = unlimited)
  --wrapup-timeout SECS    Wrap-up agent timeout (default: 120)
  --cooldown SECONDS       Pause between iterations (default: 10)
  --no-cooldown            Shorthand for --cooldown 0
  --no-commit              Skip automatic git commits
  --no-spin-check          Disable spin/stall detection
  --verbose, -V            Show detailed journal content in status output
  --format FORMAT          Output format for status: text (default) or json
  --goal, -g TEXT          Set goal inline (creates/updates prompt file)
  --resume                 Continue numbering from last journal
  --dry-run                Show config without running
  --quiet, -q              Suppress banner output
  --help, -h               Show help
  --version, -v            Show version
```

## Config (env vars)

- `LOOPTY_INTERVAL` — seconds per iteration (default: 900 = 15m)
- `LOOPTY_MAX_ITERS` — stop after N iterations (default: 0 = infinite)
- `LOOPTY_MODEL` — model override (default: claude's default)
- `LOOPTY_MAX_TURNS` — wrap-up agent turn limit (default: 5)
- `LOOPTY_WORK_TURNS` — work agent turn limit (default: 0 = unlimited)
- `LOOPTY_WRAPUP_TIMEOUT` — wrap-up agent timeout in seconds (default: 120)
- `LOOPTY_COOLDOWN` — pause between iterations in seconds (default: 10)
- `LOOPTY_PROMPT` — prompt file path (default: .loopty/prompt.md)

## Concurrency & safety

- **Lock file:** A lock directory (`.loopty/lock.d/`) prevents concurrent runs. Stale locks from dead processes are automatically cleaned up.
- **Spin detection:** After each iteration, loopty checks for stalls (5 consecutive zero-change iterations → auto-stop, 3 → warning). Also detects repetitive journal descriptions (>80% word overlap). Disable with `--no-spin-check`.
- **Prompt guard:** The work agent's prompt file is checksummed before and after each iteration; if the agent modifies it, the original is restored.
