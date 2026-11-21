# Studio test place

Measures what Roblox's docs leave open and prototypes the scripted workarounds, so decisions rest on
measurements. Runnable by the owner or any future session that has Roblox Studio.
Nothing here is part of the game.

## Run it
1. `rojo build studio-tests.project.json -o studio-tests.rbxl`, then open `studio-tests.rbxl` in Studio.
   (Open the built file: `Lighting.Technology` can only be set by the place file, not by scripts or the Rojo plugin.)
2. Studio: File → Studio Settings → Rendering → Editor Quality Level = max. Window 1920×1080 if possible.
3. Press **Play**. Probes run automatically. Copy the Output text between
   `===== BEGIN XONOTIC STUDIO PROBES` and `===== END` into the session (or HANDOFF §GOTCHAS).
4. Press keys to build each prototype, wait for it to finish, take a screenshot (name in brackets):
   - **1**: specular calibration rig (`v1-specular.png`)
   - **2**: ViewportFrame fidelity: left real render, right ViewportFrame (`v2-viewport.png`)
   - **3**: 170° wide-FOV stitch from three ViewportFrames (`v3-widefov.png`)
   - **4**: premultiplied-lightmap capacity; prints surfaces + FPS after ~3 s (`v4-premultiply.png`)
   - **0**: print all results again.
5. Repeat step 3 on each real device you care about (phone, laptop) with Roblox graphics quality at max:
   NearPlaneZ and budgets differ per device.

## What each answers
| ID | Question | Feeds |
|---|---|---|
| P-NEARPLANE | near clip distance on this device | stud scale (D-008, Q-005) |
| P-FOV | actual vertical FOV clamp | camera (G-006) |
| P-LIGHTRANGE | real Range clamp of Point/Spot/SurfaceLight | dlights, stud scale (G-009) |
| P-EIMG-MAXSIZE / -BUDGET | EditableImage size limit and how many 1024² fit | tiling, premultiply (G-001) |
| P-SA-RUNTIME | runtime mesh + SurfaceAppearance route works on the client | the whole map renderer (G-018) |
| P-LIGHTING | Technology / environment really neutral | every visual test |
| V1 | how Roblox roughness/metalness highlights look under one point light | VIS-SPECCAL |
| V2 | what ViewportFrame rendering loses | scripted reflections, FOV stitching |
| V3 | how a stitched 170° view compares with one projection | FOV > 133° (§DIFFS candidate) |
| V4 | how many unique premultiplied surfaces fit, and FPS | lightmap blend (1,139 `filter` stages) |

Image-size test with uploaded assets (Q-002) needs uploads first (M1-UPLOAD).
