--!strict
-- Debug export (not part of the port): load a stock map with engine/model_brush.luau under Lune and dump the
-- surface mesh exactly as the loader holds it, for tools/studio/render_map.py (a headless picture of what the
-- port loaded) and for other offline checks.
--   lune run tools/studio/export_surfaces.luau stormkeep   -> work/studio/stormkeep.xsm
-- File: "XSM1", u32 vertices, triangles, surfaces, textures; vertex3f; normal3f; texcoordtexture2f; element3i;
-- per surface i32 texture, firsttriangle, numtriangles, surfaceflags; texture names separated by "\n".
local fs = require("@lune/fs")
local process = require("@lune/process")
local console = require("../../engine/console")
local model_brush = require("../../engine/model_brush")

local name = process.args[1] or "stormkeep"
console.sink = function(_line: string) end
local mod = model_brush.newmodel("maps/" .. name .. ".bsp")
model_brush.Mod_IBSP_Load(mod, fs.readFile(`work/vfs-high/maps/{name}.bsp`))

local sm = mod.surfmesh
local nv, nt = sm.num_vertices, sm.num_triangles
local surfaces = mod.data_surfaces
local names = {}
for i, tex in mod.data_textures do
	names[i] = tex.name
end
local namestr = table.concat(names, "\n")
local out = buffer.create(20 + nv * 32 + nt * 12 + #surfaces * 16 + #namestr)
buffer.writestring(out, 0, "XSM1")
buffer.writeu32(out, 4, nv)
buffer.writeu32(out, 8, nt)
buffer.writeu32(out, 12, #surfaces)
buffer.writeu32(out, 16, #names)
local o = 20
buffer.copy(out, o, sm.data_vertex3f, 0, nv * 12)
o += nv * 12
buffer.copy(out, o, sm.data_normal3f, 0, nv * 12)
o += nv * 12
buffer.copy(out, o, sm.data_texcoordtexture2f, 0, nv * 8)
o += nv * 8
buffer.copy(out, o, sm.data_element3i, 0, nt * 12)
o += nt * 12
for _, s in surfaces do
	buffer.writei32(out, o, if s.texture then s.texture.index else -1)
	buffer.writei32(out, o + 4, s.num_firsttriangle)
	buffer.writei32(out, o + 8, s.num_triangles)
	buffer.writei32(out, o + 12, if s.texture then s.texture.surfaceflags else 0)
	o += 16
end
buffer.writestring(out, o, namestr)
fs.writeDir("work/studio")
fs.writeFile(`work/studio/{name}.xsm`, buffer.tostring(out))
print(`{name}: {nv} vertices, {nt} triangles, {#surfaces} surfaces, {#names} textures -> work/studio/{name}.xsm`)
