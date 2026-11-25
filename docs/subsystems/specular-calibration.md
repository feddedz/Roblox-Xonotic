# Specular calibration (task VIS-SPECCAL)

Goal: for every texture with a gloss map, choose Roblox `RoughnessMap`/`MetalnessMap` values (generated
per texture by the converter) so highlights match Xonotic at Ultra as closely as Roblox allows. The
residual is measured per texture and logged.

## DarkPlaces model (pinned source)
`shader_glsl.h` SHADESPECULAR, Blinn-Phong:
`specular = pow(max(dot(N, normalize(L + E)), 0), 1 + SpecularPower * gloss.a)`, multiplied by the gloss
colour (`gloss.rgb`) × `r_shadow_glossintensity` (1) × the shader's `dpglossintensitymod`. `SpecularPower`
= `r_shadow_glossexponent` (32, engine default; Xonotic cfg does not override) × `dpglossexponentmod`.
`r_shadow_glossexact 1` (xonotic-client.cfg L843) selects the exact half-vector variant.
Shaders using the mods: 484 `dpglossexponentmod`, 478 `dpglossintensitymod` (docs/shaders.md).

## Roblox model
PBR roughness/metalness (red channel of each map), applied through
`AssetService:CreateSurfaceAppearanceAsync` (G-018). Exact BRDF not documented, so calibrate by measurement.

## Procedure
1. Starting point: Blinn-Phong exponent n ↔ GGX-style roughness via α = sqrt(2 / (n + 2)), roughness = sqrt(α).
   Metalness 0 (DarkPlaces specular is additive and coloured by the gloss map, not by albedo).
2. Rig: Studio test place V1 (same light, camera and grey albedo) and, per texture, the same quad with
   the real colour/normal/gloss-derived maps. Reference: the identical scene in Xonotic (REF-SHOTS: a test
   map or `r_editlights` scene with one light at the same distance).
3. Fit per texture: sweep roughness scale/offset and specular strength (via albedo/metalness) to minimise
   the screenshot diff of the highlight region (`tools/shotdiff/`). Record the fitted parameters in
   `assets/data/specular-calibration.tsv` (texture, n, intensity, roughness map params, residual %).
4. Gloss colour cannot be expressed exactly in PBR without changing albedo: log textures where the
   residual stays visible in §DIFFS (category: proven-impossible platform limit, with the residual).
