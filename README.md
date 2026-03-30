# loopty

An iterative development loop for [Claude Code](https://docs.anthropic.com/en/docs/claude-code).

You write a goal. Loopty spins up a fresh Claude agent, lets it work for a fixed time budget, has a second agent write a journal entry about what happened, then commits and does it again. Each new agent reads the last few journals so it knows where things stand.

## Install

```bash
/plugin marketplace add codybrom/loopty
/plugin install loopty@loopty-plugins
```

Use `/loopty` in any project. It bootstraps itself on first run.

<details>
<summary>Other install methods</summary>

**Into a specific project:**

```bash
git clone https://github.com/codybrom/loopty.git /tmp/loopty
bash /tmp/loopty/install.sh /path/to/your/project
```

The installer is idempotent. Uninstall with `bash /tmp/loopty/install.sh --uninstall /path/to/your/project`.

**Manual:**

```bash
cp loopty/loopty.sh your-project/
cp -r loopty/.claude/commands/loopty.md your-project/.claude/commands/
mkdir -p your-project/.loopty
cp loopty/.loopty/prompt.md.example your-project/.loopty/
```

</details>

## Quick start

```bash
# Write your goal
cat > .loopty/prompt.md << 'EOF'
Improve test coverage for the auth module.

## Success criteria
- Coverage above 80% for src/auth/
- All edge cases for token refresh are tested

## Constraints
- No new dependencies
- Don't modify production code
EOF

# Run 5 iterations, 15 minutes each
bash loopty.sh -n 5
```

Or use the slash command inside Claude Code:

```
/loopty "improve test coverage" 10m 5x
/loopty status
/loopty resume
```

## How it works

```
┌─────────────────────────────────────────────────┐
│  You write .loopty/prompt.md                    │
│                                                 │
│  ┌───────────┐   ┌──────────┐   ┌───────────┐  │
│  │   Work    │ → │ Wrap-up  │ → │  Commit   │  │
│  │  agent    │   │  agent   │   │  (git)    │  │
│  └───────────┘   └──────────┘   └───────────┘  │
│       ↑                              │          │
│       └──── reads last 3 journals ───┘          │
│                                                 │
│  Repeat until done or Ctrl+C                    │
└─────────────────────────────────────────────────┘
```

1. **Work.** A fresh agent gets the goal plus recent journals. It works for the time budget (default 15 minutes).
2. **Wrap-up.** A second agent writes a journal entry: what was attempted, what changed, what to do next.
3. **Commit.** All changes get committed to git.

The loop stops when it hits the max iteration count, you press `Ctrl+C`, or spin detection kicks in. A run summary gets written to `.loopty/last-run-summary.md`.

## Safety

- **Lock file** prevents two runs from stepping on each other
- **Prompt guard** restores your goal file if an agent modifies it
- **Spin detection** warns after 3 zero-change iterations, stops after 5 (`--no-spin-check` to disable)
- **Ctrl+C** stops the agent, writes a partial journal (`status: interrupted`), commits, and exits

## Status

Check on a run without starting a new one:

```bash
bash loopty.sh status                  # table of iterations
bash loopty.sh status --verbose        # include journal summaries
bash loopty.sh status --format json    # machine-readable
```

## Journals

Each journal has YAML frontmatter:

```yaml
---
iteration: 3
timestamp: "2024-01-15-143022"
status: completed      # or: interrupted, fallback
work_agent_exit: 0     # 0 = clean, 124 = timeout, other = error
duration_seconds: 540
files_changed: 5
insertions: 42
deletions: 10
---
```

The body has what was attempted, decisions made, and next steps. The wrap-up agent writes it; the next work agent reads it.

## Configuration

CLI flags take precedence over `LOOPTY_*` env vars.

| Flag | Description | Default |
|------|-------------|---------|
| `-i, --interval` | Seconds per iteration | 900 (15m) |
| `-n, --max-iters` | Stop after N iterations | unlimited |
| `-g, --goal` | Set goal inline | - |
| `--resume` | Continue numbering from last journal | - |
| `-m, --model` | Model override | - |
| `-w, --work-turns` | Work agent turn limit | unlimited |
| `-t, --max-turns` | Wrap-up agent turn limit | 5 |
| `--wrapup-timeout` | Wrap-up timeout (seconds) | 120 |
| `--cooldown` | Pause between iterations (seconds) | 10 |
| `--no-cooldown` | No pause between iterations | - |
| `--no-commit` | Skip git commits | - |
| `--no-spin-check` | Disable stall detection | - |
| `--dry-run` | Show config, don't run | - |
| `-q, --quiet` | Suppress banner | - |

<details>
<summary>File layout</summary>

```
.loopty/
  prompt.md              # Your goal (required)
  journal/               # One entry per iteration
  last-run-summary.md    # Most recent run summary
  lock.d/                # Concurrency lock (auto-managed)
loopty.sh                # The loop script
.claude/commands/
  loopty.md              # Slash command entry point
```

</details>

## Testing

```bash
bash test.sh
```

Runs all CLI tests without launching any agents.

## Inspiration

[autoresearch](https://github.com/karpathy/autoresearch) (fixed wallclock budgets, just keep going) and the [Ralph loop](https://github.com/anthropics/claude-plugins-official/tree/main/plugins/ralph-loop).

## Requirements

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) (`claude`)
- `git`
- bash 4+
