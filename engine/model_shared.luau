--!strict
--!native
--[[
Copyright (C) 1996-1997 Id Software, Inc.

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.

(DarkPlaces model_shared.c / model_shared.h)
]]
--[[
	Port of model_shared.c @xonotic-v0.8.6. PARTIAL (task M3-BSPLOAD): the mesh helpers the Q3 BSP loader calls:
	Mod_BuildTextureVectorsFromNormals, Mod_AllocSurfMesh, Mod_SnapVertices, Mod_RemoveDegenerateTriangles.
	float arrays are f32 buffers and int arrays i32 buffers, passed as (buffer, byte offset) where the C code
	passes a pointer into the middle of an array; every float operation is rounded like C (D-004).
	model_shared.loadmodel is the C global `loadmodel` (set by the loader that is running).
	NOT YET PORTED: everything else (model registry and loading, Q3 shaders and Mod_LoadTextureFromQ3Shader,
	skins, shadow meshes, sorted surfaces, lightmap allocation, ...).
]]
local f32 = require("./_port/f32")

local model_shared = {}

local R = f32.round
local readf32, writef32, readi32, writei32 = buffer.readf32, buffer.writef32, buffer.readi32, buffer.writei32

-- model_shared.c L47: dp_model_t *loadmodel;
model_shared.loadmodel = nil :: any

-- VectorNormalize (mathlib.h L118) on 3 floats at byte offset o of b
local function VectorNormalize_b(b: buffer, o: number)
	local x, y, z = readf32(b, o), readf32(b, o + 4), readf32(b, o + 8)
	local ilength = R(math.sqrt(R(R(R(x * x) + R(y * y)) + R(z * z))))
	if ilength ~= 0 then
		ilength = R(1.0 / ilength)
	end
	writef32(b, o, x * ilength)
	writef32(b, o + 4, y * ilength)
	writef32(b, o + 8, z * ilength)
end

-- port: model_shared.c Mod_BuildTextureVectorsFromNormals L924-1002 @xonotic-v0.8.6
-- (elements: i32 buffer + byte offset; the float arrays are whole buffers, indexed from vertex 0)
function model_shared.Mod_BuildTextureVectorsFromNormals(
	firstvertex: number,
	numvertices: number,
	numtriangles: number,
	vertex3f: buffer,
	texcoord2f: buffer,
	normal3f: buffer,
	elements: buffer,
	eofs: number,
	svector3f: buffer,
	tvector3f: buffer,
	areaweighting: boolean
)
	local sdir = { 0, 0, 0 }
	local tdir = { 0, 0, 0 }
	local normal = { 0, 0, 0 }
	local f: number
	local tangentcross = { 0, 0, 0 }
	local v10 = { 0, 0, 0 }
	local v20 = { 0, 0, 0 }
	local tc10 = { 0, 0 }
	local tc20 = { 0, 0 }
	-- clear the vectors
	buffer.fill(svector3f, 3 * firstvertex * 4, 0, numvertices * 12)
	buffer.fill(tvector3f, 3 * firstvertex * 4, 0, numvertices * 12)
	-- process each vertex of each triangle and accumulate the results
	for tnum = 0, numtriangles - 1 do
		local e = eofs + tnum * 12
		local e0, e1, e2 = readi32(elements, e), readi32(elements, e + 4), readi32(elements, e + 8)
		local v0, v1, v2 = e0 * 12, e1 * 12, e2 * 12
		local tc0, tc1, tc2 = e0 * 8, e1 * 8, e2 * 8
		-- calculate the edge directions and surface normal
		-- 6 multiply, 9 subtract
		for k = 0, 2 do
			local a = readf32(vertex3f, v0 + k * 4)
			v10[k + 1] = R(readf32(vertex3f, v1 + k * 4) - a)
			v20[k + 1] = R(readf32(vertex3f, v2 + k * 4) - a)
		end
		normal[1] = R(R(v20[2] * v10[3]) - R(v20[3] * v10[2]))
		normal[2] = R(R(v20[3] * v10[1]) - R(v20[1] * v10[3]))
		normal[3] = R(R(v20[1] * v10[2]) - R(v20[2] * v10[1]))
		-- calculate the tangents
		-- 12 multiply, 10 subtract
		tc10[2] = R(readf32(texcoord2f, tc1 + 4) - readf32(texcoord2f, tc0 + 4))
		tc20[2] = R(readf32(texcoord2f, tc2 + 4) - readf32(texcoord2f, tc0 + 4))
		sdir[1] = R(R(tc10[2] * v20[1]) - R(tc20[2] * v10[1]))
		sdir[2] = R(R(tc10[2] * v20[2]) - R(tc20[2] * v10[2]))
		sdir[3] = R(R(tc10[2] * v20[3]) - R(tc20[2] * v10[3]))
		tc10[1] = R(readf32(texcoord2f, tc1) - readf32(texcoord2f, tc0))
		tc20[1] = R(readf32(texcoord2f, tc2) - readf32(texcoord2f, tc0))
		tdir[1] = R(R(tc10[1] * v20[1]) - R(tc20[1] * v10[1]))
		tdir[2] = R(R(tc10[1] * v20[2]) - R(tc20[1] * v10[2]))
		tdir[3] = R(R(tc10[1] * v20[3]) - R(tc20[1] * v10[3]))
		-- if texture is mapped the wrong way (counterclockwise), the tangents
		-- have to be flipped, this is detected by calculating a normal from the
		-- two tangents, and seeing if it is opposite the surface normal
		-- 9 multiply, 2 add, 3 subtract, 1 compare, 50% chance of: 6 negates
		tangentcross[1] = R(R(tdir[2] * sdir[3]) - R(tdir[3] * sdir[2]))
		tangentcross[2] = R(R(tdir[3] * sdir[1]) - R(tdir[1] * sdir[3]))
		tangentcross[3] = R(R(tdir[1] * sdir[2]) - R(tdir[2] * sdir[1]))
		if
			R(R(R(tangentcross[1] * normal[1]) + R(tangentcross[2] * normal[2])) + R(tangentcross[3] * normal[3]))
			< 0
		then
			sdir[1], sdir[2], sdir[3] = -sdir[1], -sdir[2], -sdir[3]
			tdir[1], tdir[2], tdir[3] = -tdir[1], -tdir[2], -tdir[3]
		end
		if not areaweighting then
			local il = R(math.sqrt(R(R(R(sdir[1] * sdir[1]) + R(sdir[2] * sdir[2])) + R(sdir[3] * sdir[3]))))
			if il ~= 0 then
				il = R(1.0 / il)
			end
			sdir[1], sdir[2], sdir[3] = R(sdir[1] * il), R(sdir[2] * il), R(sdir[3] * il)
			il = R(math.sqrt(R(R(R(tdir[1] * tdir[1]) + R(tdir[2] * tdir[2])) + R(tdir[3] * tdir[3]))))
			if il ~= 0 then
				il = R(1.0 / il)
			end
			tdir[1], tdir[2], tdir[3] = R(tdir[1] * il), R(tdir[2] * il), R(tdir[3] * il)
		end
		for i = 0, 2 do
			local o = readi32(elements, e + i * 4) * 12
			writef32(svector3f, o, readf32(svector3f, o) + sdir[1])
			writef32(svector3f, o + 4, readf32(svector3f, o + 4) + sdir[2])
			writef32(svector3f, o + 8, readf32(svector3f, o + 8) + sdir[3])
			writef32(tvector3f, o, readf32(tvector3f, o) + tdir[1])
			writef32(tvector3f, o + 4, readf32(tvector3f, o + 4) + tdir[2])
			writef32(tvector3f, o + 8, readf32(tvector3f, o + 8) + tdir[3])
		end
	end
	-- make the tangents completely perpendicular to the surface normal, and
	-- then normalize them
	-- 16 assignments, 2 divide, 2 sqrt, 2 negates, 14 adds, 24 multiplies
	for i = 0, numvertices - 1 do
		local o = (firstvertex + i) * 12
		local n1, n2, n3 = readf32(normal3f, o), readf32(normal3f, o + 4), readf32(normal3f, o + 8)
		for _, vec in { svector3f, tvector3f } do
			local a, b, c = readf32(vec, o), readf32(vec, o + 4), readf32(vec, o + 8)
			f = -R(R(R(a * n1) + R(b * n2)) + R(c * n3))
			writef32(vec, o, a + R(f * n1))
			writef32(vec, o + 4, b + R(f * n2))
			writef32(vec, o + 8, c + R(f * n3))
			VectorNormalize_b(vec, o)
		end
	end
end

-- port: model_shared.c Mod_AllocSurfMesh L1004-1031 @xonotic-v0.8.6
-- (C carves the arrays out of one allocation; here each array is its own zeroed buffer)
function model_shared.Mod_AllocSurfMesh(
	numvertices: number,
	numtriangles: number,
	lightmapoffsets: boolean,
	vertexcolors: boolean,
	neighbors: boolean
)
	local loadmodel = model_shared.loadmodel
	local surfmesh = loadmodel.surfmesh
	if not surfmesh then
		surfmesh = {}
		loadmodel.surfmesh = surfmesh
	end
	surfmesh.num_vertices = numvertices
	surfmesh.num_triangles = numtriangles
	if surfmesh.num_vertices ~= 0 then
		surfmesh.data_vertex3f = buffer.create(12 * numvertices)
		surfmesh.data_svector3f = buffer.create(12 * numvertices)
		surfmesh.data_tvector3f = buffer.create(12 * numvertices)
		surfmesh.data_normal3f = buffer.create(12 * numvertices)
		surfmesh.data_texcoordtexture2f = buffer.create(8 * numvertices)
		surfmesh.data_texcoordlightmap2f = buffer.create(8 * numvertices)
		if vertexcolors then
			surfmesh.data_lightmapcolor4f = buffer.create(16 * numvertices)
		end
		if lightmapoffsets then
			surfmesh.data_lightmapoffsets = buffer.create(4 * numvertices)
		end
	end
	if surfmesh.num_triangles ~= 0 then
		surfmesh.data_element3i = buffer.create(12 * numtriangles)
		if neighbors then
			surfmesh.data_neighbor3i = buffer.create(12 * numtriangles)
		end
		if surfmesh.num_vertices <= 65536 then
			surfmesh.data_element3s = buffer.create(6 * numtriangles)
		end
	end
end

-- port: model_shared.c Mod_SnapVertices L3001-3007 @xonotic-v0.8.6
function model_shared.Mod_SnapVertices(
	numcomponents: number,
	numvertices: number,
	vertices: buffer,
	vofs: number,
	snap: number
)
	local isnap = 1.0 / snap
	for i = 0, numvertices * numcomponents - 1 do
		local o = vofs + i * 4
		writef32(vertices, o, math.floor(readf32(vertices, o) * isnap) * snap)
	end
end

-- port: model_shared.c Mod_RemoveDegenerateTriangles L3009-3031 @xonotic-v0.8.6
-- (inelement3i and outelement3i may be the same place, as in C; vertex3f is indexed from vertex 0)
function model_shared.Mod_RemoveDegenerateTriangles(
	numtriangles: number,
	inelement3i: buffer,
	inofs: number,
	outelement3i: buffer,
	outofs: number,
	vertex3f: buffer
): number
	local outtriangles = 0
	local limit = R(0.001) -- 0.001f
	-- a degenerate triangle is one with no width (thickness, surface area)
	-- these are characterized by having all 3 points colinear (along a line)
	-- or having two points identical
	-- the simplest check is to calculate the triangle's area
	for i = 0, numtriangles - 1 do
		local ip = inofs + i * 12
		local e0, e1, e2 = readi32(inelement3i, ip), readi32(inelement3i, ip + 4), readi32(inelement3i, ip + 8)
		local a, b, c = e0 * 12, e1 * 12, e2 * 12
		-- calculate first edge
		local ax, ay, az = readf32(vertex3f, a), readf32(vertex3f, a + 4), readf32(vertex3f, a + 8)
		local d1x, d1y, d1z =
			R(readf32(vertex3f, b) - ax), R(readf32(vertex3f, b + 4) - ay), R(readf32(vertex3f, b + 8) - az)
		local d2x, d2y, d2z =
			R(readf32(vertex3f, c) - ax), R(readf32(vertex3f, c + 4) - ay), R(readf32(vertex3f, c + 8) - az)
		local tx = R(R(d1y * d2z) - R(d1z * d2y))
		local ty = R(R(d1z * d2x) - R(d1x * d2z))
		local tz = R(R(d1x * d2y) - R(d1y * d2x))
		if R(R(R(tx * tx) + R(ty * ty)) + R(tz * tz)) < limit then
			continue -- degenerate triangle (no area)
		end
		-- valid triangle (has area)
		local op = outofs + outtriangles * 12
		writei32(outelement3i, op, e0)
		writei32(outelement3i, op + 4, e1)
		writei32(outelement3i, op + 8, e2)
		outtriangles += 1
	end
	return outtriangles
end

return model_shared
