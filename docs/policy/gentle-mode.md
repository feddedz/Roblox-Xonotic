# Gentle mode (cl_gentle / sv_gentle) in Xonotic 0.8.6, and the content-ratings questionnaire

Source: `source/qcsrc` and the cfg files of the pinned release (D-001), read 2026-11-20. Owner decision
D-014: on Roblox, `cl_gentle` defaults to 1; the normal gore path stays ported and tested.

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
