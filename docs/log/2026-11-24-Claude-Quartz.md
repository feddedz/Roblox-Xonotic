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

## After the owner's approval (2026-11-24)
- Owner approved the sheets. Dry run: 3,296 done, 7,634 to upload. Nothing uploaded yet: no ROBLOX_API_KEY here.
- run_unattended.sh now takes [batch] (default 100); new Windows twin run_unattended.ps1 (log in
  work/upload/run.log, commits roblox-images.tsv every 10 min); upload_images.py reads one owned asset before
  uploading, so a missing or blocked key stops before any upload. Not run end to end (no key).

## Upload (2026-11-24, owner's PC)
- Owner entered the key in a masked pop-up (tools/upload/set_key.ps1 → Windows user variable; never in chat/repo).
- `run_unattended.ps1 -UserId 876999276 -Jobs 6 -Batch 100`: 77 batches, 7,634 ok, 0 not ok; every batch
  "all approved"; no Rejected, no 403, no 45-min timeout. About 2.5 h.
- Check: all 10,910 rows of upload-ready.tsv (incl. the 122 fixed3 rows) have an asset id in roblox-images.tsv.
  Its 316 error rows are the "User is moderated" rows of 2026-11-22 (same count as before this run).

## Next step
Owner: archive the 28 assets of assets/manifest/archive-now.tsv; decide on the 119 flagged images that were
uploaded before the ban (live_findings_{a..c}.tsv, not part of this task). The key stays on the PC until
`set_key.ps1 -Remove`.
