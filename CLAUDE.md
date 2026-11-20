# Xonotic → Roblox, one-to-one

This repo ports **Xonotic 0.8.6** (open-source arena FPS, GPLv3+) to Roblox so exactly that a Xonotic
player finds no difference in gameplay or visuals. DarkPlaces is hand-ported to Luau line by line
(`engine/`, one module per C file), OS-facing parts become Roblox backends (`platform/`), the release's
compiled QuakeC runs unchanged via an ahead-of-time QC→Luau compiler (`tools/qcaot/` → `game/generated/`),
and assets are converted at full quality (`tools/`). The owner syncs with Rojo and tests in Studio;
sessions test headless with Lune. Many sessions work in turn; `HANDOFF.md` is the shared state.

**The one-to-one rule is absolute, for gameplay and visuals.** Nothing simplified, rebalanced, removed or
"Roblox-ified". The only allowed differences are listed in HANDOFF §RULES, and each is logged in §DIFFS.
Never change content for Roblox policy on your own: ask in §QUESTIONS.

## Session protocol
1. **Start, without reading the whole repo:** read HANDOFF.md `§STATUS`, `§RULES`, `§TASKS` (grep the
   marker, read only that section), then the top 5 lines of `docs/log/INDEX.md`. Read other sections or
   `docs/subsystems/*.md` only when your task needs them. Toolchain: `tools/bootstrap.sh &&
   export PATH="$PWD/.tools/bin:$PATH"`; game data: `tools/release/fetch.sh` + `python3 tools/pk3/manifest.py --build high --extract`.
2. **Claim:** pick an `open` task whose deps are `done`, not in a subsystem another session has claimed.
   Set it to `claimed by <session> <date>` in §TASKS, **commit and push that alone before any work**.
   Branch `<task-id>-<short-name>` (or the branch the environment assigns; D-011).
3. **Work** in small commits; every message starts with the task ID. Port faithfully (`-- port: file.c
   Func Lstart-Lend @xonotic-v0.8.6`, keep copyright notices), apply the float32 rule (D-004), run
   `lune run tests/run.luau`, `stylua --check engine platform tests game`, `selene engine platform tests`,
   `python3 -m unittest discover -s tools -t . -p "test_*.py"`, and add the tests your subsystem needs.
4. **Log as you go**, after each meaningful step, in `docs/log/<YYYY-MM-DD>-<session>.md` with sections
   `## Goal`, `## Done`, `## Files changed`, `## Tests run and results`, `## Diffs added or closed`,
   `## Decisions`, `## Problems / dead ends`, `## Next step`. Terse.
5. **Finish:** add one line at the top of `docs/log/INDEX.md`: `<date> <session> <task-id> — <result> → <log>`;
   update §MAP, §DIFFS, §DECISIONS, §QUESTIONS, §GOTCHAS as needed; rewrite §STATUS (≤15 lines); mark the
   task `done` or unclaim it with a note; push; open a PR with a short description.
6. **Never** delete or skip original functionality or lower visual quality. If something can't work yet,
   stub it so it logs `NOT YET PORTED: <name>`, and add a task.
7. **Never** guess Roblox limits or APIs from memory: check current docs (create.roblox.com or
   raw.githubusercontent.com/Roblox/creator-docs), record the finding and date in §GOTCHAS.
8. **End of session:** tell the owner in plain language what you did, what to test in Studio (including
   screenshots to capture for comparison), and anything you need from them.
