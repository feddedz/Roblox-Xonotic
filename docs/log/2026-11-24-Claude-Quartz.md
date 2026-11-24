# 2026-11-24 Claude-Quartz — UPLOAD-FIX3

## Goal
Fix the 275 images flagged by the 2026-11-23 strict review as subtly as possible, show the owner before/after,
upload nothing until the owner approves.

## Done
- Ran on the owner's Windows PC (not the cloud): downloaded xonotic-0.8.6-high.zip (sha512 = pin), extracted
  work/vfs-high, regenerated fixed/fixed2/blurred. All 10,910 ready files hash-match the committed
  upload-ready.tsv, so gore_fix.py / content_fix.py / blur_text.py are byte-reproducible on Windows too.
- tools/upload/content_fix3.py: 124 files fixed → work/upload/fixed3/, 153 kept with reasons. Starts from the
  file that would be uploaded today (fixed > fixed2 > blurred > original), because the strict review looked at
  that set. New ops: soft_patch (stain → clean sibling + faint shadow), clone_patch, regrain, rot_disc (also
  turns normal-map vectors), smooth_skin, glass_blank, splatter smudge.
- Rule used: every high/medium fixed; low fixed when name/handle/brand/other game/blood-like/star/cross-in-ring/
  hooked shape/body-like/ambiguous letters; harmless signage and the XONOTIC wordmark kept.
- The 9 textures/screens/screen_*.jpg read at 2x: one shared noise layer. Removed the 'FK' line starts and the
  'KK' on the 5 screens where they show; on the other 4 the big word covers them.
- build_ready.py: fixed3 first; upload-ready.tsv rebuilt (122 fixed3 rows; 870 rows only got their asset id
  column filled from roblox-images.tsv).
- tools/upload/fix3_sheets.py → work/review_fix3/f00..f17.jpg (before/after, 7 files per sheet) sent to the owner.

## Files changed
tools/upload/content_fix3.py, tools/upload/fix3_sheets.py, tools/upload/build_ready.py,
assets/manifest/review/content_fixes3.tsv, assets/manifest/review/content_kept3.tsv,
assets/manifest/upload-ready.tsv, HANDOFF.md (STATUS, TASKS, DIFF-009), this log, docs/log/INDEX.md.

## Tests run and results
- content_fix3.py twice → identical sha256 for all 124 outputs; every output has the original's size and mode.
- `python -m unittest discover -s tools -t . -p "test_*.py"`: 22 run, 19 ok, 3 errors in tools/pk3/test_vfs.py
  (Windows only: temp .pk3 still open when the temp dir is removed; not touched here).
- Lune / StyLua / Selene not run (no Luau changed; toolchain not installed on this PC).

## Diffs added or closed
DIFF-009 added.

## Decisions
None new (D-025 + the owner's brief of 2026-11-24 applied).

## Problems / dead ends
- Windows: no bash (tools/handoff.sh, fetch.sh not run; chat.sh works with MinGit's sh). manifest.py and the fix
  tools write CRLF on Windows; git normalises it, content is identical.
- Reading box coordinates off a scaled preview gave wrong boxes twice; always read the ruler ticks.
- e7wgrate: a small triangle of the old star tip stays painted on the bottom plate (colour map only).

## Next step
Owner approves the sheets → `tools/upload/run_unattended.sh 876999276 6` with `--batch 100` (the script must
pass --batch 100 to upload_images.py; today it does not pass it). Needs ROBLOX_API_KEY on this PC or a cloud
session. Stop on Rejected, 403, or Reviewing > 45 min.
