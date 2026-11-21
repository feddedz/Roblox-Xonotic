# Audio assets plan (AUDIO-PLAN)

Owner spec (2026-11-21), applied by `tools/sounds/audio_plan.py` → `assets/manifest/audio-plan.tsv`.
Playback itself (channels, attenuation, spatialisation, timing) is M8-SOUND; this is only how the files
of the pinned release become Roblox audio assets.

## Rules
1. **Dedupe first**: files with the same sha256 are uploaded once; every vpath maps to that upload
   (`dup_of` column). DarkPlaces still sees every name, so precache order/indices are unchanged.
2. **One asset per sound** by default.
3. **Quota check**: before uploading, read the account's 30-day audio upload quota from Open Cloud
   (G-030): `GET https://apis.roblox.com/cloud/v2/users/{user_id}/asset-quotas?filter=quotaType ==
   RateLimitUpload && assetType == Audio`, header `x-api-key`, scope `asset:read`; remaining =
   `capacity - usage`, resets at `usageResetTime`. `audio_plan.py --query-quota --user-id <id>`
   (`$ROBLOX_API_KEY`) or `--quota <remaining>`.
4. **Pack only if needed**: if unique uploads > remaining quota, pack short sounds **by group**, biggest
   group first, only until it fits. Packable groups: one weapon (`weapon/<name>`), one announcer set
   (`announcer/<set>`), one voice set (`voice/<set>`), `pickups`. 0.5 s of silence between sounds.
   Manifest records `pack`, `start_s`, `end_s` per sound (sample-exact: frame / rate).
5. **Never packed**: music (`sound/cdtracks`), looping sounds (own loop marker — Ogg `LOOP_START`
   comment / WAV `cue ` chunk, as DarkPlaces reads them — or used looped by the game), long sounds
   (> 10 s), everything outside the packable groups.
6. **No quality loss from packing**: packs are 16-bit FLAC of the decoded PCM. DarkPlaces decodes Vorbis
   to 16-bit PCM, so the pack holds the samples DarkPlaces plays; no second lossy encode. Members of a
   pack share rate and channel count (no resampling: one pack per (group, rate, channels)); packs are
   split before 7 min / 20 MB.
7. **Still over quota** after packing every packable group: upload in stages across quota windows
   (the planner prints how many remain); never drop or merge further.
8. **Before packing any gameplay sound**: the [needs Studio] test P-AUDIOSLICE (below) must pass and be
   recorded in §GOTCHAS. If it fails, packing is not used for gameplay sounds; uploads are staged instead.

## Limits used (G-030, creator-docs read 2026-11-21)
Audio asset: `.mp3/.ogg/.wav/.flac`, ≤ 7 min, ≤ 20 MB, ≤ 48 kHz, mono/stereo/surround. Upload quota: the
docs disagree (audio/assets: 2,000 per 30 days ID-verified, 100 unverified; cloud/guides/usage-assets:
100/month verified, 10 unverified), hence the live quota query. Audio assets can't be updated via Open
Cloud: a re-upload is a new asset (counts against the quota). `Sound.PlaybackRegion` (needs
`PlaybackRegionsEnabled`) and `AudioPlayer.PlaybackRegion` select a slice; `LoopRegion` loops inside it.

## P-AUDIOSLICE [needs Studio]
`audio_plan.py --test-pack` writes `work/audio/p-audioslice.flac` (8 tone bursts of 0.1 s, slice i at
[0.6·i, 0.6·i + 0.1] s, louder with i). Owner uploads it once and puts the id in the probe
(`tests/studio`, attribute `AudioSliceAssetId` on the probe script). Must confirm:
- a slice starts without audible delay or a click, and stops at `PlaybackRegion.Max` without bleeding
  into the next slice (the 0.5 s gap also guards this);
- 8 Sounds on the same asset with different regions can play at the same time (overlap), and two Sounds
  with the same region overlap (rapid fire);
- `TimePosition` right after `Play()` equals `PlaybackRegion.Min` (log measured values);
- the same with `AudioPlayer` (+ `AudioEmitter`/`AudioListener`), which M8-SOUND may use instead.

## Findings (2026-11-21, Claude-Anvil, 0.8.6-high)
- 851 sound files under `sound/` (846 ogg, 3 wav, 2 mp3); 46 identical by sha256 (25 of them pk3 symlinks,
  G-031) → **805 unique uploads**, 145.4 min. No file over 7 min or 20 MB (longest music 406 s).
- 43 files carry a loop marker (all tuba notes, `*_fly`, `arc_loop`, machines, 3 music tracks with real
  loop points, e.g. heavymetal LOOP_START 1289185): M8-SOUND must reproduce them (LoopRegion).
  QuakeC `loopsound()` is a plain `sound()`; looping comes only from these markers (or FORCELOOP flags).
- Packable: 465 sounds; the rest (map, ambient, monsters, ctf/gametype, menu, music, loops) stay single.
  Packing everything packable gives **410 uploads** (49 packs, 38 MB FLAC). So: quota ≥ 805 → all
  single; 410 ≤ quota < 805 → packs as needed; quota < 410 → packs + staged uploads.
- Packs verified sample-identical to the decoded originals (40 slices checked).
- `sound/supernatural/*.mp3` (2 files): DarkPlaces 0.8.6 only loads .wav/.ogg (snd_mem.c L335-362), so
  the game never plays them; they are still listed (and uploaded) so nothing is dropped.

## Not done yet (M1-SOUNDS)
Uploader (Open Cloud `POST /assets/v1/assets`, `assetType: Audio`, needs an API key with `asset:write`)
that fills `asset_id`, and the runtime lookup vpath → asset id (+ slice region).
