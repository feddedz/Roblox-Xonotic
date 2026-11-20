# Xonotic for Roblox (one-to-one port)

A faithful port of [Xonotic](https://xonotic.org) 0.8.6 to Roblox: the DarkPlaces engine hand-ported to
Luau, the original QuakeC game code compiled ahead of time to Luau, and the original assets at full
quality. The goal is that a Xonotic player cannot tell the difference. Project state lives in
[`HANDOFF.md`](HANDOFF.md); AI sessions follow [`CLAUDE.md`](CLAUDE.md).

Xonotic is © Team Xonotic and contributors, licensed GPLv3+. This port is GPLv3+ too: see
[`LICENSE`](LICENSE). Original copyright notices are kept in every ported file.

## For the owner: syncing into Roblox Studio

1. Install [Rokit](https://github.com/rojo-rbx/rokit), then in a terminal in this repo run `rokit install`
   (installs the pinned Rojo, Lune, StyLua and Selene from `rokit.toml`).
2. Install the Rojo Studio plugin: `rojo plugin install` (once).
3. Run `rojo serve` in the repo. In Studio, open a new Baseplate, open the **Rojo** plugin tab, click
   **Connect**. The code appears under `ReplicatedStorage.Xonotic`, plus `ServerScriptService.XonoticServer`
   and `StarterPlayerScripts.XonoticClient`.
4. Press **Play**. Until the engine is ported, the Output window shows `NOT YET PORTED: …` messages: that is
   expected. `HANDOFF.md` §STATUS says what currently works and what to test.

Alternative without the plugin: `rojo build default.project.json -o xonotic.rbxl` and open the file.

Studio settings for testing visuals (Xonotic's reference is its highest "Ultra" preset):
- File → Studio Settings → Rendering: set **Editor Quality Level** and **Graphics Mode** to the maximum.
- In the game client (Play), Esc → Settings → Graphics Quality: **manual, maximum (10)**.

## For the owner: comparison screenshots

Visual tasks are finished when the Roblox render matches real Xonotic. Each session's end message lists
the shots it needs. The procedure:

1. **Reference shots (real Xonotic):** install the **Xonotic 0.8.6 "high"** build
   (`xonotic-0.8.6-high.zip` from xonotic.org/download). In the menu: Settings → Effects → **Ultra**,
   resolution **1920×1080**, fov at default (the camera list fixes everything else). Camera positions come
   from `tests/reference/screens/cameras.tsv` (added by task TOOL-SHOTDIFF), each with a console command
   that places the camera. Take the shot with the `screenshot` console command (it saves PNG/JPG in
   your Xonotic user folder's `data/screenshots/`).
2. **Roblox shots:** in Studio Play at 1920×1080 with maximum graphics quality, the same camera list
   will be available through a debug command (added in M5). Use Roblox's screenshot or Studio's
   screenshot tool.
3. Put both in a folder and tell the next session, or commit them under `tests/reference/screens/`
   (`ref/<map>/<id>.png` and `rbx/<map>/<id>.png`). The diff tool (`tools/shotdiff/`) marks the worst regions.

## For contributors and AI sessions (headless)

```bash
tools/bootstrap.sh && export PATH="$PWD/.tools/bin:$PATH"   # pinned toolchain into .tools/ + Python deps
tools/release/fetch.sh                                       # Xonotic 0.8.6 zips into work/, sha512-checked
python3 tools/pk3/manifest.py --build high --extract         # resolve the virtual filesystem into work/vfs-high/
lune run tests/run.luau                                      # headless Luau tests
python3 -m unittest discover -s tools -t . -p "test_*.py"    # converter tests
stylua --check engine platform tests game && selene engine platform tests
```

Layout: `engine/` (DarkPlaces port, one `.luau` per C file) · `platform/` (Roblox backends: render, sound,
net, input, storage) · `game/generated/` (compiled QuakeC; never hand-edited) · `tools/` (offline
converters) · `assets/manifest/` (every asset with checksums, later Roblox asset ids) · `tests/`
(differential tests; `tests/reference/` holds recorded reference data) · `docs/` (session logs,
subsystem notes, shader status table).

The Roblox **Open Cloud API key** for asset uploads is never committed. Provide it as an environment
variable (`ROBLOX_OPEN_CLOUD_KEY`) or as a network secret for cloud sessions.
