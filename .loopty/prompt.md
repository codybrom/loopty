Improve Loopty as a polished Claude Code plugin across four areas.

## 1. Plugin packaging

- Make it installable as a proper Claude Code skill (not just a local slash command)
- Add a proper package structure so users can install via `claude install` or similar
- Ensure CLAUDE.md, commands, and the shell script are all discoverable and well-organized
- Add a README.md with clear install/usage instructions

## 2. Developer UX

- Improve the slash command experience — better argument parsing, help text, validation
- Make the banner/output cleaner and more informative during runs
- Add a `--dry-run` mode that shows what would happen without starting agents
- Support passing the goal inline (e.g., `/loopty "improve tests" 10m 3 iterations`)

## 3. Richer journal & reporting

- Add an iteration summary at the end of a run (not just per-iteration journals)
- Track cumulative metrics across iterations (files changed, tests passing, etc.)
- Add a `/loopty status` or review mode that summarizes the journal history
- Make journal entries more structured and machine-parseable

## 4. Robustness & error handling

- Handle signals gracefully (SIGINT/SIGTERM) — write a partial journal, don't lose work
- Better error messages when claude CLI is missing, git fails, or agents timeout
- Validate the prompt file content before starting
- Handle the case where git commit has nothing to commit without noisy errors
- Ensure the wrap-up agent reliably writes the journal (retry or better fallback)

## Success criteria

- The tool works end-to-end on a fresh clone with clear install instructions
- Signal handling: Ctrl+C during a run produces a clean partial journal and exit
- Journal entries are consistent, structured, and useful to subsequent agents
- The slash command validates input and gives helpful errors for bad arguments
- A run summary is produced at the end showing what was accomplished

## Constraints

- Keep it as a bash script + slash command — don't rewrite in another language
- No external dependencies beyond `claude` CLI and `git`
- Maintain backward compatibility with the current env var config interface
- Each iteration should make focused, testable progress — don't try to do everything at once
