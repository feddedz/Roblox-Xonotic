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
	local surfaces, patches, meshverts = 0, 0, 0
	for line in string.gmatch(t.read("tests/vectors/q3bsp.tsv"), "[^\r\n]+") do
		if string.sub(line, 1, 1) == "#" then
			continue
		end
		local c = string.split(line, "\t")
		local name = c[1]
		local mod = model_brush.newmodel("maps/" .. name .. ".bsp")
		-- the brushq3 vertex / triangle arrays are freed by Mod_Q3BSP_LoadFaces: checksum them before
		local pre: { [string]: any } = {}
		model_brush.debug_after_triangles = function(m: any)
			local mq = m.brushq3
			pre.num_vertices = mq.num_vertices
			pre.vertex3f = fnv(mq.data_vertex3f)
			pre.normal3f = fnv(mq.data_normal3f)
			pre.texcoordtexture2f = fnv(mq.data_texcoordtexture2f)
			pre.texcoordlightmap2f = fnv(mq.data_texcoordlightmap2f)
			pre.color4f = fnv(mq.data_color4f)
			pre.lit = m.lit
			pre.num_triangles = mq.num_triangles
			pre.element3i = fnv(mq.data_element3i or buffer.create(0))
		end
		local filedata = lfs.readFile(`{dir}/{name}.bsp`)
		model_brush.Mod_IBSP_Load(mod, filedata)
		model_brush.debug_after_triangles = nil
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

		want(pre.num_vertices, "num_vertices")
		want(pre.vertex3f, "data_vertex3f")
		want(pre.normal3f, "data_normal3f")
		want(pre.texcoordtexture2f, "data_texcoordtexture2f")
		want(pre.texcoordlightmap2f, "data_texcoordlightmap2f")
		want(pre.color4f, "data_color4f")
		want(if pre.lit then 1 else 0, "lit (vertex colours)")
		want(pre.num_triangles, "num_triangles")
		want(pre.element3i, "data_element3i")
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
		-- surfaces against the raw face lump: flat and mesh faces are copies of the lump's vertices and
		-- elements; a patch has the vertex count of its tesselation and only valid elements
		local fb = buffer.fromstring(filedata)
		local vofs, fofs, eofs =
			buffer.readi32(fb, 8 + 10 * 8), buffer.readi32(fb, 8 + 13 * 8), buffer.readi32(fb, 8 + 11 * 8)
		local sm = mod.surfmesh
		local flat, patch, bad = 0, 0, 0
		local sumv, sumt = 0, 0
		local controlverts = 0
		for si, s in mod.data_surfaces do
			local fp = fofs + (si - 1) * 104
			local ftype = buffer.readi32(fb, fp + 8)
			local fv = s.num_firstvertex
			sumv += s.num_vertices
			sumt += s.num_triangles
			if s.num_vertices == 0 then
				continue
			end
			for j = 0, s.num_triangles * 3 - 1 do
				local e = buffer.readi32(sm.data_element3i, (s.num_firsttriangle * 3 + j) * 4)
				if e < fv or e >= fv + s.num_vertices then
					bad += 1
				end
			end
			if ftype == 1 or ftype == 3 then
				flat += 1
				local first, n = buffer.readi32(fb, fp + 12), buffer.readi32(fb, fp + 16)
				local same = n == s.num_vertices
				for j = 0, n - 1 do
					local src = vofs + (first + j) * 44
					for k = 0, 8, 4 do
						if buffer.readu32(sm.data_vertex3f, (fv + j) * 12 + k) ~= buffer.readu32(fb, src + k) then
							same = false
						end
						if buffer.readu32(sm.data_normal3f, (fv + j) * 12 + k) ~= buffer.readu32(fb, src + 28 + k) then
							same = false
						end
					end
					if buffer.readu32(sm.data_texcoordtexture2f, (fv + j) * 8) ~= buffer.readu32(fb, src + 12) then
						same = false
					end
				end
				local fe = buffer.readi32(fb, fp + 20)
				for j = 0, s.num_triangles * 3 - 1 do
					local e = buffer.readi32(sm.data_element3i, (s.num_firsttriangle * 3 + j) * 4)
					if e - fv ~= buffer.readi32(fb, eofs + (fe + j) * 4) then
						same = false
					end
				end
				if not same then
					t.ok(ctx, false, `{name}: surface {si - 1} is not a copy of its face's vertices / elements`)
				end
			elseif ftype == 2 then
				patch += 1
				controlverts += buffer.readi32(fb, fp + 16)
				t.ok(
					ctx,
					s.num_collisiontriangles <= s.num_collisionvertices * 2,
					`{name}: patch {si - 1} collision counts`
				)
			end
		end
		t.eq(ctx, bad, 0, name .. ": elements outside their surface")
		-- the engine also counts every patch's control points when it sizes the mesh (model_brush.c L6111-6114
		-- add them once, L6140-6143 add the tesselated count again), so that many vertices stay unused
		t.eq(
			ctx,
			sumv + controlverts,
			sm.num_vertices,
			name .. ": surface vertices + patch control points = mesh vertices"
		)
		t.ok(ctx, sumt <= sm.num_triangles, name .. ": triangle count")
		surfaces += #mod.data_surfaces
		patches += patch
		meshverts += sm.num_vertices
	end
	console.sink = oldsink
	print(
		`    q3bsp: {brushes} brushes built ({nilbrushes} rejected like in C), {points} corner points, {warnings} console lines`
	)
end
