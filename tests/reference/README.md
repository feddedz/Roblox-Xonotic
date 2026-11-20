# tests/reference/

Recorded reference data from **real** Xonotic 0.8.6 / DarkPlaces (`xonotic-v0.8.6`), or the scripts that
regenerate it. The Luau port must match it (bit-identical unless a tolerance is justified in writing).

Planned layout (each added by its task in HANDOFF §TASKS):
- `traces/<map>.bin` + `traces/README.md`: traceline/tracebox inputs and results (M3-TRACEREF), recorded
  with the instrumented build in `tools/darkplaces-ref/` (REF-DP).
- `frames/<scenario>/`: server entity state per frame from scripted inputs, demos, bot matches (M4).
- `net/<scenario>/`: raw network messages for byte comparison (M6).
- `particles/<scene>/`: particle simulation state per frame (M9).
- `screens/cameras.tsv`, `screens/ref/<map>/<id>.png`: Ultra screenshots from the -high build (REF-SHOTS);
  `screens/rbx/…`: the owner's Roblox screenshots for `tools/shotdiff/`.

Large binary sets that would bloat git: commit the generator script + sha256 of the output instead, and
regenerate into `work/reference/`.
