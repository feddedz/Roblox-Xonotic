# Gentle mode (cl_gentle / sv_gentle) in Xonotic 0.8.6, and the content-ratings questionnaire

Source: `source/qcsrc` and the cfg files of the pinned release (D-001), read 2026-11-20.
Status: the blood/gore policy is **deferred by the owner until before publishing** (Q-007, D-015).
`cl_gentle` behaves exactly as in Xonotic (default 0, menu checkbox). Gore is ported in full and kept
isolated so it can later be locked or removed by one switch (D-016, section "Isolation" below).

## The cvars (defaults in the pinned cfgs)
| cvar | default | meaning (cfg description) |
|---|---|---|
| `cl_gentle` | 0 (`seta`, saved) | client master switch. Menu: Settings → User, checkbox "Disable gore effects and harsh language" (`dialog_settings_user.qc` L72) |
| `cl_gentle_gibs` | 0 | gibs only: 1 white smoke, 2 colourful clouds, 3 "happy_" effects |
| `cl_gentle_messages` | 0 | frag messages / centerprints only |
| `cl_gentle_damage` | 0 | damage flash only: 1 white flash, 2 random colour |
| `sv_gentle` | 0 (`set`) | server: forces `cl_gentle 1` on every client at connect (`client.qc` L968, via `settemp`), and more (below) |

## What `cl_gentle 1` changes (client)
1. **Gibs and blood particles** (`gibs.qc` net_gibsplash L227-316): every gib splash gets the "gentle bit".
   Gib explosions (type 1: eye, bloody skull, arms, legs, chests, chunks, blood shower) become the
   `morphed_damage_dissolve` particle effect (white → purple smoke clouds); blood hits (type 2) become
   `morphed_damage_hit` (white/purple sparks + smoke); flying chunks (type 3) are dropped entirely
   ("no gibs in gentle mode"). `cl_nogibs` no longer applies (and its menu slider is disabled,
   `dialog_settings_game_model.qc` L74). Blood effects carry wall stains (`effect blood` staincolor), so
   blood stains disappear too.
2. **Damage effects on bodies** (`damageeffects.qc` L129): `DamageEffect` returns immediately: no
   bleeding/burning effects attached to the hit bone.
3. **Damage screen flash** (`view.qc` L1166-1177): the blood-image flash is replaced by a colour fill
   (`hud_damage_gentle_color "1 0.7 1"`, alpha × `hud_damage_gentle_alpha_multiplier 0.10`).
4. **Messages** (`util.qh` L230-237, `notifications/all.qh`): in CSQC, `GENTLE = cl_gentle ||
   cl_gentle_messages`; every notification with a gentle variant uses it ("First blood!" → "First score!",
   "drew first blood" / kill-spree wording → score wording). Announcer achievements set to `1` in
   `notifications.cfg` play only when gentle mode is off.

## What `cl_gentle 1` does NOT change
Players still see: corpses lying on the ground after death (no blood), death and pain animations,
death/pain screams and taunts (only `sv_gentle` removes those), weapons and explosions themselves, and
messages that have no gentle variant.

## What `sv_gentle 1` adds (server)
Forces `cl_gentle 1` at connect (players can still untick it afterwards: `settemp` is only applied at
connect); no pain animations (`player.qc` L351); no death sounds (L453); corpses are immediately gibbed,
i.e. removed (L586); no taunts (`globalsound.qc` L388); server-side messages use gentle wording.
**Not** part of D-014: the owner chose `cl_gentle` only.

## Questionnaire facts (owner fills in the questionnaire; this is the input)
Roblox: "Please review your game and confirm that your answers accurately reflect the content of your game.
If you misrepresent your game, you may be subject to moderation consequences." (create.roblox.com/docs/
production/promotion/content-ratings, read 2026-11-20). **Gentle mode is a checkbox players can untick**,
so content behind it is still reachable in the game. See HANDOFF Q-007 before answering.

| Topic | cl_gentle 1 (Roblox default) | cl_gentle 0 (player unticks the box) |
|---|---|---|
| Violence: against | humanoid player characters and bots (armoured humans/robots); frequent, core gameplay | same |
| Violence: setting / style | science-fiction arenas (fantastical world); realistic-styled 3D | same |
| Blood | none: hits show white/purple sparks and clouds, no stains | red blood particles, blood stains on walls, blood showers |
| Gore | none: no body parts; bodies dissolve into clouds when gibbed; corpses stay, intact | gibs: eyes, skulls, arms, legs, torso chunks fly and splat |
| Death presentation | death animation, corpse on floor, death scream | same, plus gibbing |
| Language | gentle wording for kill messages ("First score!") | "First blood!", "drew first blood", frag wording |

## Server-side analysis (for isolation, D-016; verified 2026-11-20)
- **The server never reads `cl_gentle`.** It is not replicated (no REPLICATE/sendcvar use in qcsrc);
  every `cl_gentle*` read is CSQC (`gibs.qc` net_gibsplash, `damageeffects.qc`, `view.qc`, notification
  wording via `GENTLE` in CSQC). So the client mode cannot change server state.
- **Gib splash on the server** (`gibs.qc` L17-55, SVQC): `Violence_GibSplash_At` spawns a temporary
  `new_pure` entity, writes the `net_gibsplash` temp message (type, amount, origin/4, compressed velocity)
  to every real client and deletes the entity. This edict allocate/free happens on every server in every
  mode (it does not depend on any client setting) and the message bytes are identical. All gib entities,
  blood particles and stains are created **only in CSQC** from that message.
- **Corpses** (`player.qc` CopyBody, classname "body") are gameplay, not gore: they exist with or without
  gentle mode and stay untouched. `sv_gibhealth` gibbing (player.qc L212) hides the body server-side and
  sends the splash; that server logic is identical in all modes.
- **Precache affects the server.** Gib models are registered with `MODEL()` (`common/models/all.inc`
  L130-140) and gore sounds with `SOUND()` (`common/sounds/all.inc` L264-268: misc/gib, gib_splat01-04).
  Registries precache on server and client alike, so these names take model/sound **index numbers** that
  appear in network messages. The server loads every precached model with `Mod_ForName(…, crash=true, …)`
  (`sv_main.c` SV_ModelIndex): a missing gib model file is a fatal server error. Sound precache on the server
  only records the name.
- **effectinfo.txt** defines blood effects by name; effect numbers come from the file's order. The file
  must stay byte-identical in every mode (otherwise every effect number after the first gore effect shifts).
- **No server-emitted blood effects:** the server never calls a blood effect by number (only
  `sv_cmd.qc` debug prints of TE_BLOOD/TR_BLOOD indices).

## Isolation (D-016)
QuakeC is not edited. Isolation lives in the asset and platform layers:
- **Gore asset group** `assets/optional/gore/` with its own manifest: gib models (`models/gibs/*` that only
  gibs use) and their skins/textures, gore sounds (misc/gib*, gib_splat*), blood/gib particle textures
  (the particle-atlas tiles used *only* by gore effects; shared tiles stay in the main group), blood
  decal/stain textures, and the red damage-flash image. Built and uploaded separately (task GORE-ASSETS).
- **One switch** `platform/contentpolicy` with three modes:
  - `player-choice`: Xonotic behaviour (cl_gentle default 0, checkbox works), gore group loaded;
  - `forced-gentle`: `cl_gentle` locked to 1 (checkbox shown locked), gore group still loaded but never shown;
  - `removed`: `cl_gentle` locked to 1, gore group never uploaded or loaded. The runtime VFS returns
    policy placeholders for gore paths (a minimal valid model with the same name, silent sound, blank
    texture), so precache order, index numbers, effectinfo numbering and server model loading stay exactly
    as in Xonotic and no missing-asset error occurs.
    **Approved by the owner 2026-11-20 (D-019).** Requirements for GORE-ASSETS: every gore model path the
    server or client precaches gets a same-name placeholder model (valid file for the engine's model
    loader, so `Mod_ForName(..., crash=true)` on the server succeeds; no render data, never uploaded);
    every gore sound gets a same-name silent placeholder; precache calls happen in the same order with the
    same names, so model/sound index numbers in network messages are unchanged.
- **Proof** (task GORE-MODE-TESTS): server frame-diff tests produce identical results in all three modes,
  network messages are byte-identical, and `removed` runs a full match with zero missing-asset messages.
