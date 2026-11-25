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

## Account check (2026-11-25, owner asked "is the account side 100% done?")
- tools/upload/check_assets.py (read-only GETs, 429-limited: ~4,100 reads ≈ 20 min) →
  assets/manifest/roblox-assets-state.tsv. `--skip-last 7634` = do not re-read what the gate just approved.
- Sounds: 804 needed Approved, cdtracks/heavymetal.ogg Rejected. Images: 3,270 older needed Approved + Active,
  1 needed Rejected (gfx/menu/luminos/background_ingame_alpha.jpg). Nothing is Archived.
- archive-now.tsv: 25 of 28 are still needed (upload-ready.tsv has no fixed version for them), incl. all five
  textures/cp*.jpg. 112 of the 119 live findings are in use unfixed → new task UPLOAD-FIX4.

## UPLOAD-FIX4 (2026-11-25, owner: "fix everything")
- tools/upload/content_fix4.py → work/upload/fixed4/: 43 fixed, 70 kept (content_{fixes,kept}4.tsv), 7 were already
  replaced by earlier tools. Starts from the live version (fixed3 > fixed > fixed2 > blurred > original). New ops:
  mirror_glyph (CP sign), hatch_yards (radar), quad_fill, smooth_shape, drop_lines, const_box. Run twice: same
  sha256. 11 "medium" findings that are only the XONOTIC logo kept on the owner's wordmark rule (told the owner).
- build_ready.py: fixed4 first. fix3_sheets.py --fix4 → work/review_fix4/f00..f06.jpg, sent; owner approved.
- Gated upload: 43 ok, batch all Approved.
- Owner asked "will the game know which asset is the new version, and is anything missing?" → there was no
  texture lookup at all (only the upload log). tools/upload/asset_index.py --write → assets/manifest/
  texture-assets.tsv + platform/render/texture_assets.luau (+5 parts, each < 190k chars): all 13,676 texture
  vpaths → current asset id. tools/upload/test_asset_index.py (4 tests, ok) fails when the table is stale or
  hands out a superseded upload. Sounds: 851/851 in audio_assets.luau.
- tools/upload/archive_assets.py --apply (owner approved): 16 old rejected sound uploads Archived. Images:
  HTTP 400 "not an archivable asset type" (G-052) → 68 unused images written to archive-now.tsv for the owner.
  Bug found on the way: the tool stopped on an asset id containing "403"; now it tests for "HTTP 403".

## Tests run and results (2026-11-25)
- `python -m unittest tools/upload/test_asset_index.py`: 4 ok.
- Lune / StyLua / Selene NOT run on platform/render/texture_assets*.luau (toolchain not on this PC): the next
  cloud session should run `stylua --check platform` and `selene platform` once.

## Next step
Owner: archive the 68 images of assets/manifest/archive-now.tsv in the Creator Dashboard; appeal heavymetal.ogg
(Q-013). The key stays on the PC until `set_key.ps1 -Remove`. Renderer/texture tasks read texture_assets.luau.

## Local setup on the owner's PC (2026-11-25, owner: "we can't do a cloud environment, we can just use Studio")
- PRs 1, 2, 3 merged into main (owner: "do whatever you think is best"); GitHub default branch set to main.
  CI was red on main after PR 2 (rojo build: game/generated/vfs had no .gitkeep); fixed before merging PR 3.
- `rokit install` (Rokit was already installed): rojo 7.7.1, lune 0.11.1, stylua 2.6.0, selene 0.31.0.
  stylua/selene clean; Lune: 13/14, tests/unit/libc.test.luau failed on Windows only -> G-053, fixed in
  libc.format1 (non-finite doubles formatted in Luau); now 14/14. The new texture_assets*.luau pass CI and load
  in Studio (13,676 entries).
- `rojo build default.project.json -o work/xonotic.rbxl`, opened in a second Studio window, saved to Roblox as
  the experience "Xonotic" (placeId 130462204737495, universeId 10779065323) through Studio's Save dialog
  (computer use, the only step that needed the screen). The session reaches it through the Studio MCP tools.
- The owner's other Studio window ("walled in") was no longer open afterwards; this session did not close it on
  purpose (told the owner).

## Next step
Game work on this PC: branch from main, run `stylua --check`, `selene`, `lune run tests/run.luau` locally, check
in Studio through the Studio MCP tools. First candidates: M3-BSPLOAD, M1-TEX, M1-MODELS.

