# Assets: release, VFS, manifests, converters

## Release and builds (D-001, D-002)
`tools/release/fetch.sh [standard|high|source|all]` downloads into `work/download/` (sha512 pinned) and
unpacks to `work/release-<build>/Xonotic/`. Both builds contain the same game code and non-texture
files; textures differ (standard: DDS/S3TC; high: original JPEG + `_alpha` JPEG). Ultra loads the
originals, so **textures come from `-high`**.

## VFS (fs.c @xonotic-v0.8.6)
`tools/pk3/vfs.py` mirrors FS_AddGameDirectory: pk3 names sorted with strcasecmp, each prepended to the
search path, so the alphabetically last pk3 wins; pk3 lookups are case-sensitive.
`python3 tools/pk3/manifest.py --build <b> [--extract]` writes:
- `assets/manifest/pk3-<b>.tsv`: every pk3 with size, sha256 and search order.
- `assets/manifest/vfs-<b>.tsv`: every resolved file: vpath, kind, winning pk3, size, sha256, shadowed pk3s.
- `--extract`: the winning files to `work/vfs-<b>/` (input for every converter).

0.8.6 counts (resolved files): standard 14,589, high 16,494 (13,677 textures, 830 sounds, 750 models,
31 maps, 186 shader scripts, 3 progs, 22 music tracks).

## Runtime data on Roblox (task M1-RTVFS)
The engine reads files at runtime (bsp for collision, cfg, shader scripts, effectinfo.txt, mapinfo,
.skin/.framegroups, progs string tables…). These must ship inside the place as Rojo-syncable modules
(likely chunked strings or buffers). Verify ModuleScript/StringValue size limits in docs first.

## Converter rules
- Never downscale. Tile any image larger than the verified max (Q-002) across UV regions/meshes.
- JPEG alpha: merge `<name>_alpha.jpg` as alpha exactly like image.c (G-016).
- Image lookup order follows image.c `imageformats_*` lists (tga, png, jpg… with and without `textures/`).
- Keep every converted file traceable: manifest row → source vpath + sha256 → Roblox asset id.

## Shaders
`tools/shaders/parse.py` → `assets/data/shaders.json` (every shader, every stage, in load order) and
`docs/shaders.md` (status table). Parsing mirrors model_shared.c `Mod_LoadQ3Shaders`.
