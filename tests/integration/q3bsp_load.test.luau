--!strict
-- M3-BSPLOAD: engine/model_brush.luau loads every stock map (work/vfs-high/maps/*.bsp) and the loaded arrays
-- match an independent decoder of the file format (tests/vectors/q3bsp.tsv, tools/testgen/q3bsp_vectors.py):
-- counts and a hash of every array. Every brush also goes through Collision_NewBrushFromPlanes (itself checked
-- against the C build in tests/unit/collision.test.luau). Needs game data.
local t = require("../_lib/t")
local lfs = require("@lune/fs")
local console = require("../../engine/console")
local f32 = require("../../engine/_port/f32")
local model_brush = require("../../engine/model_brush")

-- checksum of tools/testgen/q3bsp_vectors.py: words w[i] of the zero-padded data,
-- a = sum(w[i]), b = sum((w[i] & 0xFFFF) * (i % 65521 + 1) + (w[i] >> 16) * (i % 65519 + 1)), both mod 2^32
local function fnv(b: buffer, len: number?): string
	local n = len or buffer.len(b)
	local words = n // 4
	local readu32 = buffer.readu32
	local a, s = 0, 0
	local function add(i: number, w: number)
		a = (a + w) % 4294967296
		s = (s + (w % 65536) * (i % 65521 + 1) + (w // 65536) * (i % 65519 + 1)) % 4294967296
	end
	for i = 0, words - 1 do
		add(i, readu32(b, i * 4))
	end
	if n % 4 ~= 0 then
		local w = 0
		for k = 0, n % 4 - 1 do
			w += buffer.readu8(b, words * 4 + k) * 256 ^ k
		end
		add(words, w)
	end
	return string.format("%08x%08x", a, s)
end

return function(ctx: t.Ctx)
	local dir = "work/vfs-high/maps"
	if not lfs.isDir(dir) or not lfs.isFile(dir .. "/stormkeep.bsp") then
		t.skip(ctx, "needs work/vfs-high")
		return
	end
	local oldsink = console.sink
	local warnings = 0
	console.sink = function(_line: string)
		warnings += 1
	end
	local brushes, nilbrushes, points = 0, 0, 0
	for line in string.gmatch(t.read("tests/vectors/q3bsp.tsv"), "[^\r\n]+") do
		if string.sub(line, 1, 1) == "#" then
			continue
		end
		local c = string.split(line, "\t")
		local name = c[1]
		local mod = model_brush.newmodel("maps/" .. name .. ".bsp")
		model_brush.Mod_IBSP_Load(mod, lfs.readFile(`{dir}/{name}.bsp`))
		local brush, q3 = mod.brush, mod.brushq3
		local col = 1
		local function want(got: any, what: string)
			col += 1
			t.eq(ctx, tostring(got), c[col], `{name}: {what}`)
		end
		want(q3.header_version, "version")
		want(fnv(buffer.fromstring(brush.entities or "")), "entities")
		want(if q3.deluxemapping then 1 else 0, "deluxemapping")

		-- textures: name NUL surfaceflags supercontents
		local parts = {}
		for i, tex in mod.data_textures do
			parts[i] = tex.name .. "\0" .. string.pack("<i4I4", tex.surfaceflags, tex.supercontents)
		end
		want(mod.num_textures, "num_textures")
		want(fnv(buffer.fromstring(table.concat(parts))), "textures")

		-- planes: normal dist type signbits
		local planeindex: { [any]: number } = {}
		local pb = buffer.create(brush.num_planes * 24)
		for i, p in brush.data_planes do
			planeindex[p] = i - 1
			local o = (i - 1) * 24
			buffer.writef32(pb, o, p.normal[1])
			buffer.writef32(pb, o + 4, p.normal[2])
			buffer.writef32(pb, o + 8, p.normal[3])
			buffer.writef32(pb, o + 12, p.dist)
			buffer.writei32(pb, o + 16, p.type)
			buffer.writei32(pb, o + 20, p.signbits)
		end
		want(brush.num_planes, "num_planes")
		want(fnv(pb), "planes")

		local sb = buffer.create(brush.num_brushsides * 8)
		for i, s in brush.data_brushsides do
			buffer.writei32(sb, (i - 1) * 8, planeindex[s.plane])
			buffer.writei32(sb, (i - 1) * 8 + 4, s.texture.index)
		end
		want(brush.num_brushsides, "num_brushsides")
		want(fnv(sb), "brushsides")

		local bb = buffer.create(brush.num_brushes * 12)
		for i, b in brush.data_brushes do
			buffer.writei32(bb, (i - 1) * 12, b.firstbrushside)
			buffer.writei32(bb, (i - 1) * 12 + 4, b.numbrushsides)
			buffer.writei32(bb, (i - 1) * 12 + 8, b.texture.index)
			brushes += 1
			if b.colbrushf then
				points += b.colbrushf.numpoints
			else
				nilbrushes += 1
			end
		end
		want(brush.num_brushes, "num_brushes")
		want(fnv(bb), "brushes")
		want(q3.num_effects, "num_effects")

		want(q3.num_vertices, "num_vertices")
		want(fnv(q3.data_vertex3f), "data_vertex3f")
		want(fnv(q3.data_normal3f), "data_normal3f")
		want(fnv(q3.data_texcoordtexture2f), "data_texcoordtexture2f")
		want(fnv(q3.data_texcoordlightmap2f), "data_texcoordlightmap2f")
		want(fnv(q3.data_color4f), "data_color4f")
		want(if mod.lit then 1 else 0, "lit")
		want(q3.num_triangles, "num_triangles")
		want(fnv(q3.data_element3i or buffer.create(0)), "data_element3i")
		want(mod.num_surfaces, "num_surfaces")

		local mb = buffer.create(q3.num_models * 40)
		for i, m in q3.data_models do
			local o = (i - 1) * 40
			for k = 1, 3 do
				buffer.writef32(mb, o + (k - 1) * 4, m.mins[k])
				buffer.writef32(mb, o + 12 + (k - 1) * 4, m.maxs[k])
			end
			buffer.writei32(mb, o + 24, m.firstface)
			buffer.writei32(mb, o + 28, m.numfaces)
			buffer.writei32(mb, o + 32, m.firstbrush)
			buffer.writei32(mb, o + 36, m.numbrushes)
		end
		want(q3.num_models, "num_models")
		want(fnv(mb), "models")

		want(brush.num_leafbrushes, "num_leafbrushes")
		want(fnv(brush.data_leafbrushes), "data_leafbrushes")
		want(brush.num_leafsurfaces, "num_leafsurfaces")
		want(fnv(brush.data_leafsurfaces), "data_leafsurfaces")

		local nleafs = #brush.data_leafs
		local lb = buffer.create(nleafs * 52)
		for i, l in brush.data_leafs do
			local o = (i - 1) * 52
			buffer.writei32(lb, o, l.clusterindex)
			buffer.writei32(lb, o + 4, l.areaindex)
			for k = 1, 3 do
				buffer.writef32(lb, o + 8 + (k - 1) * 4, l.mins[k])
				buffer.writef32(lb, o + 20 + (k - 1) * 4, l.maxs[k])
			end
			buffer.writei32(lb, o + 32, l.firstleafsurface)
			buffer.writei32(lb, o + 36, l.numleafsurfaces)
			buffer.writei32(lb, o + 40, l.firstleafbrush)
			buffer.writei32(lb, o + 44, l.numleafbrushes)
			buffer.writeu32(lb, o + 48, l.combinedsupercontents)
		end
		want(nleafs, "leafs in the lump")
		want(fnv(lb), "leafs")

		local nb = buffer.create(brush.num_nodes * 40)
		for i, n in brush.data_nodes do
			local o = (i - 1) * 40
			buffer.writei32(nb, o, planeindex[n.plane])
			for j = 1, 2 do
				local ch = n.children[j]
				buffer.writei32(nb, o + j * 4, if ch.plane then ch.index else -1 - ch.index)
			end
			for k = 1, 3 do
				buffer.writef32(nb, o + 12 + (k - 1) * 4, n.mins[k])
				buffer.writef32(nb, o + 24 + (k - 1) * 4, n.maxs[k])
			end
			buffer.writeu32(nb, o + 36, n.combinedsupercontents)
			if i > 1 then
				t.ok(ctx, n.parent ~= nil, `{name}: node {i - 1} has a parent`)
			end
		end
		want(brush.num_nodes, "num_nodes")
		want(fnv(nb), "nodes")
		want(brush.num_leafs, "num_leafs after Mod_Q3BSP_RecursiveFindNumLeafs")

		want(brush.num_pvsclusters, "num_pvsclusters")
		want(brush.num_pvsclusterbytes, "num_pvsclusterbytes")
		want(fnv(brush.data_pvsclusters), "data_pvsclusters")

		local cs = q3.num_lightgrid_cellsize
		want(string.format("%g %g %g", cs[1], cs[2], cs[3]), "num_lightgrid_cellsize")
		want(table.concat(q3.num_lightgrid_imins, " "), "num_lightgrid_imins")
		want(table.concat(q3.num_lightgrid_isize, " "), "num_lightgrid_isize")
		want(q3.num_lightgrid, "num_lightgrid")
		want(fnv(q3.data_lightgrid or buffer.create(0)), "data_lightgrid")
		local xb = buffer.create(64)
		for r = 1, 4 do
			for cc = 1, 4 do
				buffer.writeu32(xb, ((r - 1) * 4 + (cc - 1)) * 4, f32.tobits(q3.num_lightgrid_indexfromworld.m[r][cc]))
			end
		end
		want(fnv(xb), "num_lightgrid_indexfromworld")
	end
	console.sink = oldsink
	print(
		`    q3bsp: {brushes} brushes built ({nilbrushes} rejected like in C), {points} corner points, {warnings} console lines`
	)
end
