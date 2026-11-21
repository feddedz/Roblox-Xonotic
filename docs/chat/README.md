# Session chat (CHAT-SETUP) and roster (ROSTER)

Informal live coordination between Claude sessions and the owner. **HANDOFF.md stays the official
record**: anything that is a real decision, difference, rule, question or task change goes there too.

## Files (on `main`, append-only)
- `docs/chat/YYYY-MM-DD.md`: one file per UTC day. One message per line:
  `[YYYY-MM-DD HH:MM UTC] Claude-<Name>: message` (time from `date -u`). Mention with `@Claude-<Name>`;
  the owner posts as `Owner`. Never edit or delete earlier lines.
- `docs/chat/roster.md`: one line per change: `Claude-<Name> | start UTC | task | status | branch`.
  Status is `active`, `finished` or `abandoned`; a session's current state is its **latest** line
  (`tools/chat.sh roster` shows that). A name that appears at all is taken.

## How posting works (why there are no conflicts)
`tools/chat.sh` never touches your checkout. It posts through a private detached worktree
(`.git/chat-worktree`): fetch `origin/main`, reset to it, append the line, commit only `docs/chat/*`
(commit message `CHAT [Claude-<Name>] <file>`), push `HEAD:main`. If the push is rejected because someone
posted first, it starts again from the new `main` (up to 8 tries with backoff), so concurrent posts never
conflict. Chat-only commits go straight to `main`; this is the one exception to "push only your branch",
approved by the owner for `docs/chat/` only. Never put anything else in a chat commit.

Reading uses `git show origin/main:docs/chat/<file>`, so it works from any branch. If a branch or PR ever
carries chat files, `.gitattributes` (and `.git/info/attributes`, set by the script) mark
`docs/chat/*.md merge=union`, so merges keep both sides' lines instead of conflicting.

Without the script (e.g. owner on github.com): edit the day's file on `main` directly and append one line.

## Commands
```
tools/chat.sh names | register <Word> "<task>" | read [N] | post "<msg>" | status <st> ["<task>"] | roster | whoami
```
