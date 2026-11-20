# Visual reference (D-009)

The reference look is Xonotic 0.8.6 **-high** build with the **Ultra** preset (menu: Settings → Effects →
Ultra), which runs `effects-ultra.cfg`. Exact contents in the pinned data:

```
cl_decals 1
cl_decals_models 0
cl_decals_fadetime 10
cl_particles 1
cl_particles_quality 1.0
cl_damageeffect 2
cl_spawn_point_particles 1
cl_playerdetailreduction 0
gl_flashblend 0
gl_picmip -1
gl_texturecompression_2d 0
gl_texturecompression_sky 0
mod_q3bsp_nolightmaps 0
r_bloom 1
r_coronas 1
r_coronas_occlusionquery 1
hud_postprocessing_maxbluralpha 0.5
hud_powerup 0.5
r_depthfirst 2
r_drawdecals_drawdistance 500
r_drawparticles_drawdistance 2000
r_glsl_deluxemapping 1
r_glsl_offsetmapping 1
r_glsl_offsetmapping_reliefmapping 0
r_motionblur 0.4
r_shadow_gloss 1
r_shadow_realtime_dlight 1
r_shadow_realtime_dlight_shadows 1
r_shadow_realtime_world 1
r_shadow_realtime_world_shadows 0
r_shadow_shadowmapping 1
r_shadow_usenormalmap 1
r_showsurfaces 0
r_sky 1
r_subdivisions_tolerance 2
r_texture_dds_load 0
r_water 1
r_water_resolutionmultiplier 0.5

menu_sync
```

Key consequences:
- `r_texture_dds_load 0`, `gl_texturecompression_2d 0`, `gl_picmip -1`: uncompressed original textures at
  full resolution (D-002).
- `r_shadow_realtime_dlight 1` + `_shadows 1`: dynamic lights cast shadows. `r_shadow_realtime_world 1` with
  `_shadows 0`: world rtlights on, without shadows. `r_shadow_usenormalmap 1`, `r_shadow_gloss 1`:
  normal maps and specular gloss.
- `r_glsl_deluxemapping 1`, `r_glsl_offsetmapping 1` (parallax, not relief).
- `r_bloom 1`, `r_motionblur 0.4`, `r_water 1` (reflection/refraction at 0.5× resolution), `r_coronas 1`.
- `cl_particles_quality 1.0`, `cl_decals 1` (fade 10 s, draw distance 500), particles draw distance 2000.

The "Ultimate" preset exists only with `developer > 0`; it is not the reference.
Screenshot procedure for the owner: README.md "comparison screenshots".
