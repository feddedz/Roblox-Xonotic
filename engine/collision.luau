--!strict
--!native
--[[
	DarkPlaces collision.c / collision.h (Forest Hale); GPLv2 or later like the rest of DarkPlaces.
]]
--[[
	Port of collision.c @xonotic-v0.8.6. PARTIAL (task M3-BSPLOAD). Part 1: Collision_NewBrushFromPlanes with
	Collision_ValidateBrush, Collision_PrintBrushAsQHull and furthestplanedist_float.

	colbrushf_t:
	  * planes: 1-based array of colplanef_t (C element i at [i + 1]).
	  * points, edgedirs: f32 buffers, 3 floats per entry (C `colpointf_t` arrays); elements: i32 buffer.
	  * ENGINE BUG KEPT ON PURPOSE (collision.c L384-385): the C code sets both brush->edgedirs and
	    brush->elements to the address right after the points, then copies the edge directions and afterwards
	    the triangle elements to that same address. The elements therefore overwrite the start of the edge
	    directions: the first numtriangles * 3 float slots of brush->edgedirs hold the integer element indexes
	    (as raw bits, i.e. denormal floats), only the slots after them keep real edge directions. Traces read
	    brush->edgedirs, so the port must hand out the same bytes: `edgedirs` here is the buffer after that
	    overwrite, `elements` holds the same integers.
	float (vec_t) values are float32; double temporaries (the clipped polygon p) are plain numbers (D-004).
	Part 2: Collision_Init (cvars), triangle brushes, Collision_BrushForBox, the brush / line / point traces
	against brushes and triangles, Collision_BoundingBoxOfBrushTraceSegment. The triangle brush of the
	Collision_TraceBrushTriangle* functions is one reused scratch brush (C: locals on the stack).
	NOT YET PORTED: the trace cache (Collision_Cache_*), Collision_ClipTrace_Line_Sphere, Collision_ClipTo*,
	Collision_CombineTraces, Collision_ClipTrace_Box / _Point.
]]
local console = require("./console")
local cvar = require("./cvar")
local f32 = require("./_port/f32")
local polygon = require("./polygon")

local collision = {}

local R = f32.round
local Con_Print, Con_Printf, Con_DPrint, Con_DPrintf =
	console.Con_Print, console.Con_Printf, console.Con_DPrint, console.Con_DPrintf
local readf32, writef32, writei32 = buffer.readf32, buffer.writef32, buffer.writei32

-- collision.c L5-10
local COLLISION_EDGEDIR_DOT_EPSILON = R(0.999) -- (0.999f)
local COLLISION_SNAPSCALE = 32.0
local COLLISION_SNAP2 = 2.0 / COLLISION_SNAPSCALE
local COLLISION_PLANE_DIST_EPSILON = 2.0 / COLLISION_SNAPSCALE
collision.COLLISION_PLANE_DIST_EPSILON = COLLISION_PLANE_DIST_EPSILON

-- collision.h colplanef_t L84-98 (texture: model_brush texture_t)
export type colplanef_t = {
	texture: any,
	q3surfaceflags: number,
	normal: { number },
	dist: number,
}

-- collision.h colbrushf_t L100-128
export type colbrushf_t = {
	-- culling box
	mins: { number },
	maxs: { number },
	-- used to avoid tracing against the same brush more than once per sweep
	markframe: number,
	-- the content flags of this brush
	supercontents: number,
	-- bounding planes (face planes) of this brush
	numplanes: number,
	planes: { colplanef_t },
	-- edge directions (normals) of this brush
	numedgedirs: number,
	edgedirs: buffer,
	-- points (corners) of this brush
	numpoints: number,
	points: buffer,
	-- renderable triangles representing this brush, using the points
	numtriangles: number,
	elements: buffer,
	-- texture data for cases where an edgedir is used
	texture: any,
	q3surfaceflags: number,
	-- optimized collisions for common cases
	isaabb: boolean, -- indicates this is an axis aligned box
	hasaabbplanes: boolean, -- indicates this has precomputed planes for AABB collisions
}

-- mathlib.h DotProduct on floats, operands (a[0..2]) in a buffer at byte offset ao
local function DotProduct_bv(a: buffer, ao: number, b: { number }): number
	return R(R(R(readf32(a, ao) * b[1]) + R(readf32(a, ao + 4) * b[2])) + R(readf32(a, ao + 8) * b[3]))
end

-- port: collision.c Collision_PrintBrushAsQHull L55-65 @xonotic-v0.8.6
local function Collision_PrintBrushAsQHull(brush: colbrushf_t, name: string)
	Con_Printf("3 %s\n%i\n", name, brush.numpoints)
	for i = 0, brush.numpoints - 1 do
		Con_Printf(
			"%f %f %f\n",
			readf32(brush.points, i * 12),
			readf32(brush.points, i * 12 + 4),
			readf32(brush.points, i * 12 + 8)
		)
	end
	-- FIXME: optimize!
	Con_Printf("4\n%i\n", brush.numplanes)
	for i = 1, brush.numplanes do
		local p = brush.planes[i]
		Con_Printf("%f %f %f %f\n", p.normal[1], p.normal[2], p.normal[3], p.dist)
	end
end

-- port: collision.c Collision_ValidateBrush L67-124 @xonotic-v0.8.6
local function Collision_ValidateBrush(brush: colbrushf_t)
	local pointsoffplanes, pointonplanes, pointswithinsufficientplanes = 0, 0, 0
	local d: number
	local printbrush = false
	if brush.numpoints == 0 then
		Con_Print("Collision_ValidateBrush: brush with no points!\n")
		printbrush = true
	end
	if brush.numplanes ~= 0 then
		pointsoffplanes = 0
		pointswithinsufficientplanes = 0
		for k = 0, brush.numplanes - 1 do
			local n = brush.planes[k + 1].normal
			if R(R(R(n[1] * n[1]) + R(n[2] * n[2])) + R(n[3] * n[3])) < R(0.0001) then
				Con_Printf(
					"Collision_ValidateBrush: plane #%i (%f %f %f %f) is degenerate\n",
					k,
					n[1],
					n[2],
					n[3],
					brush.planes[k + 1].dist
				)
			end
		end
		for j = 0, brush.numpoints - 1 do
			pointonplanes = 0
			for k = 0, brush.numplanes - 1 do
				local pl = brush.planes[k + 1]
				d = R(DotProduct_bv(brush.points, j * 12, pl.normal) - pl.dist)
				if d > COLLISION_PLANE_DIST_EPSILON then
					Con_Printf(
						"Collision_ValidateBrush: point #%i (%f %f %f) infront of plane #%i (%f %f %f %f)\n",
						j,
						readf32(brush.points, j * 12),
						readf32(brush.points, j * 12 + 4),
						readf32(brush.points, j * 12 + 8),
						k,
						pl.normal[1],
						pl.normal[2],
						pl.normal[3],
						pl.dist
					)
					printbrush = true
				end
				if math.abs(d) > COLLISION_PLANE_DIST_EPSILON then
					pointsoffplanes += 1
				else
					pointonplanes += 1
				end
			end
			if pointonplanes < 3 then
				pointswithinsufficientplanes += 1
			end
		end
		if pointswithinsufficientplanes ~= 0 then
			Con_Print(
				"Collision_ValidateBrush: some points have insufficient planes, every point must be on at least 3 planes to form a corner.\n"
			)
			printbrush = true
		end
		if pointsoffplanes == 0 then -- all points are on all planes
			Con_Print("Collision_ValidateBrush: all points lie on all planes (degenerate, no brush volume!)\n")
			printbrush = true
		end
	end
	if printbrush then
		Collision_PrintBrushAsQHull(brush, "unnamed")
	end
end

-- port: collision.c furthestplanedist_float L142-156 @xonotic-v0.8.6 (points: f32 buffer, numpoints entries)
local function furthestplanedist_float(normal: { number }, points: buffer, numpoints: number): number
	local dist: number, bestdist: number
	if numpoints == 0 then
		return 0
	end
	bestdist = DotProduct_bv(points, 0, normal)
	for i = 1, numpoints - 1 do
		dist = DotProduct_bv(points, i * 12, normal)
		bestdist = math.max(bestdist, dist)
	end
	return bestdist
end

-- port: collision.c Collision_NewBrushFromPlanes L165-449 @xonotic-v0.8.6
-- (mempool argument dropped; originalplanes is a 1-based array of numoriginalplanes colplanef_t)
function collision.Collision_NewBrushFromPlanes(
	numoriginalplanes: number,
	originalplanes: { colplanef_t },
	supercontents: number,
	q3surfaceflags: number,
	texture: any,
	hasaabbplanes: boolean
): colbrushf_t?
	-- TODO: planesbuf could be replaced by a remapping table
	local w: number, xyzflags: number
	local numpointsbuf, maxpointsbuf, numedgedirsbuf, maxedgedirsbuf = 0, 256, 0, 256
	local numplanesbuf, maxplanesbuf, numelementsbuf, maxelementsbuf = 0, 256, 0, 256
	local isaabb = true
	local maxdist: number
	local pointsbuf = buffer.create(256 * 12)
	local edgedirsbuf = buffer.create(256 * 12)
	local planesbuf: { colplanef_t } = {}
	local elementsbuf: { number } = {}
	local polypointbuf: { number } = {}
	local pmaxpoints = 64
	local pnumpoints: number
	local p = { table.create(3 * 64, 0), table.create(3 * 64, 0) }

	-- check if there are too many planes and skip the brush
	if numoriginalplanes >= maxplanesbuf then
		Con_DPrint("Collision_NewBrushFromPlanes: failed to build collision brush: too many planes for buffer\n")
		return nil
	end

	-- figure out how large a bounding box we need to properly compute this brush
	maxdist = 0
	for j = 1, numoriginalplanes do
		maxdist = math.max(maxdist, math.abs(originalplanes[j].dist))
	end
	-- now make it large enough to enclose the entire brush, and round it off to a reasonable multiple of 1024
	maxdist = math.floor(maxdist * (4.0 / 1024.0) + 2) * 1024.0
	-- construct a collision brush (points, planes, and renderable mesh) from
	-- a set of planes, this also optimizes out any unnecessary planes (ones
	-- whose polygon is clipped away by the other planes)
	for j = 1, numoriginalplanes do
		local oj = originalplanes[j]
		-- add the new plane
		planesbuf[numplanesbuf + 1] = {
			normal = { oj.normal[1], oj.normal[2], oj.normal[3] },
			dist = oj.dist,
			q3surfaceflags = oj.q3surfaceflags,
			texture = oj.texture,
		}
		numplanesbuf += 1

		-- create a large polygon from the plane
		w = 0
		polygon.PolygonD_QuadForPlane(p[w + 1], oj.normal[1], oj.normal[2], oj.normal[3], oj.dist, maxdist)
		pnumpoints = 4
		-- clip it by all other planes
		local k = 1
		while k <= numoriginalplanes and pnumpoints >= 3 and pnumpoints <= pmaxpoints do
			-- skip the plane this polygon
			-- (nothing happens if it is processed, this is just an optimization)
			if k ~= j then
				-- we want to keep the inside of the brush plane so we flip
				-- the cutting plane
				local ok = originalplanes[k]
				pnumpoints = polygon.PolygonD_Divide(
					pnumpoints,
					p[w + 1],
					-ok.normal[1],
					-ok.normal[2],
					-ok.normal[3],
					-ok.dist,
					COLLISION_PLANE_DIST_EPSILON,
					pmaxpoints,
					p[(1 - w) + 1],
					0,
					nil
				)
				w = 1 - w
			end
			k += 1
		end

		-- if nothing is left, skip it
		if pnumpoints < 3 then
			continue
		end
		local pw = p[w + 1]

		local kk = 0
		while kk < pnumpoints do
			local m = 0
			for l = 1, numoriginalplanes do
				local ol = originalplanes[l]
				if
					math.abs(
						(pw[kk * 3 + 1] * ol.normal[1] + pw[kk * 3 + 2] * ol.normal[2] + pw[kk * 3 + 3] * ol.normal[3])
							- ol.dist
					) < COLLISION_PLANE_DIST_EPSILON
				then
					m += 1
				end
			end
			if m < 3 then
				break
			end
			kk += 1
		end
		if kk < pnumpoints then
			Con_DPrintf("Collision_NewBrushFromPlanes: warning: polygon point does not lie on at least 3 planes\n")
			--return NULL;
		end

		-- check if there are too many polygon vertices for buffer
		if pnumpoints > pmaxpoints then
			Con_DPrint("Collision_NewBrushFromPlanes: failed to build collision brush: too many points for buffer\n")
			return nil
		end

		-- check if there are too many triangle elements for buffer
		if numelementsbuf + (pnumpoints - 2) * 3 > maxelementsbuf then
			Con_DPrint(
				"Collision_NewBrushFromPlanes: failed to build collision brush: too many triangle elements for buffer\n"
			)
			return nil
		end

		-- add the unique points for this polygon
		for q = 0, pnumpoints - 1 do
			local m: number
			-- downgrade to float precision before comparing
			local v1, v2, v3 = R(pw[q * 3 + 1]), R(pw[q * 3 + 2]), R(pw[q * 3 + 3])

			-- check if there is already a matching point (no duplicates)
			m = 0
			while m < numpointsbuf do
				local d1 = R(v1 - readf32(pointsbuf, m * 12))
				local d2 = R(v2 - readf32(pointsbuf, m * 12 + 4))
				local d3 = R(v3 - readf32(pointsbuf, m * 12 + 8))
				if R(R(R(d1 * d1) + R(d2 * d2)) + R(d3 * d3)) < COLLISION_SNAP2 then
					break
				end
				m += 1
			end

			-- if there is no match, add a new one
			if m == numpointsbuf then
				-- check if there are too many and skip the brush
				if numpointsbuf >= maxpointsbuf then
					Con_DPrint(
						"Collision_NewBrushFromPlanes: failed to build collision brush: too many points for buffer\n"
					)
					return nil
				end
				-- add the new one
				writef32(pointsbuf, numpointsbuf * 12, pw[q * 3 + 1])
				writef32(pointsbuf, numpointsbuf * 12 + 4, pw[q * 3 + 2])
				writef32(pointsbuf, numpointsbuf * 12 + 8, pw[q * 3 + 3])
				numpointsbuf += 1
			end

			-- store the index into a buffer
			polypointbuf[q + 1] = m
		end

		-- add the triangles for the polygon
		-- (this particular code makes a triangle fan)
		for q = 0, pnumpoints - 3 do
			elementsbuf[numelementsbuf + 1] = polypointbuf[1]
			elementsbuf[numelementsbuf + 2] = polypointbuf[q + 2]
			elementsbuf[numelementsbuf + 3] = polypointbuf[q + 3]
			numelementsbuf += 3
		end

		-- add the unique edgedirs for this polygon
		local n = pnumpoints - 1
		for q = 0, pnumpoints - 1 do
			local m: number
			-- downgrade to float precision before comparing
			local dir =
				{ R(pw[q * 3 + 1] - pw[n * 3 + 1]), R(pw[q * 3 + 2] - pw[n * 3 + 2]), R(pw[q * 3 + 3] - pw[n * 3 + 3]) }
			n = q
			-- VectorNormalize(dir)
			local ilength = R(math.sqrt(R(R(R(dir[1] * dir[1]) + R(dir[2] * dir[2])) + R(dir[3] * dir[3]))))
			if ilength ~= 0 then
				ilength = R(1.0 / ilength)
			end
			dir[1] = R(dir[1] * ilength)
			dir[2] = R(dir[2] * ilength)
			dir[3] = R(dir[3] * ilength)

			-- check if there is already a matching edgedir (no duplicates)
			m = 0
			while m < numedgedirsbuf do
				if
					R(
						R(R(dir[1] * readf32(edgedirsbuf, m * 12)) + R(dir[2] * readf32(edgedirsbuf, m * 12 + 4)))
							+ R(dir[3] * readf32(edgedirsbuf, m * 12 + 8))
					) >= COLLISION_EDGEDIR_DOT_EPSILON
				then
					break
				end
				m += 1
			end
			-- skip this if there is
			if m < numedgedirsbuf then
				continue
			end

			-- try again with negated edgedir
			dir[1], dir[2], dir[3] = -dir[1], -dir[2], -dir[3]
			-- check if there is already a matching edgedir (no duplicates)
			m = 0
			while m < numedgedirsbuf do
				if
					R(
						R(R(dir[1] * readf32(edgedirsbuf, m * 12)) + R(dir[2] * readf32(edgedirsbuf, m * 12 + 4)))
							+ R(dir[3] * readf32(edgedirsbuf, m * 12 + 8))
					) >= COLLISION_EDGEDIR_DOT_EPSILON
				then
					break
				end
				m += 1
			end
			-- if there is no match, add a new one
			if m == numedgedirsbuf then
				-- check if there are too many and skip the brush
				if numedgedirsbuf >= maxedgedirsbuf then
					Con_DPrint(
						"Collision_NewBrushFromPlanes: failed to build collision brush: too many edgedirs for buffer\n"
					)
					return nil
				end
				-- add the new one
				writef32(edgedirsbuf, numedgedirsbuf * 12, dir[1])
				writef32(edgedirsbuf, numedgedirsbuf * 12 + 4, dir[2])
				writef32(edgedirsbuf, numedgedirsbuf * 12 + 8, dir[3])
				numedgedirsbuf += 1
			end
		end

		-- if any normal is not purely axial, it's not an axis-aligned box
		if
			isaabb
			and (if oj.normal[1] == 0 then 1 else 0)
					+ (if oj.normal[2] == 0 then 1 else 0)
					+ (if oj.normal[3] == 0 then 1 else 0)
				< 2
		then
			isaabb = false
		end
	end

	-- if nothing is left, there's nothing to allocate
	if numplanesbuf < 4 then
		Con_DPrintf(
			"Collision_NewBrushFromPlanes: failed to build collision brush: %i triangles, %i planes (input was %i planes), %i vertices\n",
			numelementsbuf // 3,
			numplanesbuf,
			numoriginalplanes,
			numpointsbuf
		)
		return nil
	end

	-- if no triangles or points could be constructed, then this routine failed but the brush is not discarded
	if numelementsbuf < 12 or numpointsbuf < 4 then
		Con_DPrintf(
			"Collision_NewBrushFromPlanes: unable to rebuild triangles/points for collision brush: %i triangles, %i planes (input was %i planes), %i vertices\n",
			numelementsbuf // 3,
			numplanesbuf,
			numoriginalplanes,
			numpointsbuf
		)
	end

	-- validate plane distances
	for j = 1, numplanesbuf do
		local d = furthestplanedist_float(planesbuf[j].normal, pointsbuf, numpointsbuf)
		if math.abs(R(planesbuf[j].dist - d)) > COLLISION_PLANE_DIST_EPSILON then
			Con_DPrintf(
				"plane %f %f %f %f mismatches dist %f\n",
				planesbuf[j].normal[1],
				planesbuf[j].normal[2],
				planesbuf[j].normal[3],
				planesbuf[j].dist,
				d
			)
		end
	end

	-- allocate the brush and copy to it
	local numtriangles = numelementsbuf // 3
	local points = buffer.create(numpointsbuf * 12)
	buffer.copy(points, 0, pointsbuf, 0, numpointsbuf * 12)
	-- brush->edgedirs and brush->elements are the same address in C (see the note at the top of this file):
	-- the edge directions are copied first, then the elements are written over their start.
	local edgedirs = buffer.create(numedgedirsbuf * 12)
	buffer.copy(edgedirs, 0, edgedirsbuf, 0, numedgedirsbuf * 12)
	local elements = buffer.create(numtriangles * 3 * 4)
	for j = 0, numtriangles * 3 - 1 do
		writei32(elements, j * 4, elementsbuf[j + 1])
		if j * 4 < numedgedirsbuf * 12 then
			writei32(edgedirs, j * 4, elementsbuf[j + 1])
		end
	end
	local brush: colbrushf_t = {
		mins = { 0, 0, 0 },
		maxs = { 0, 0, 0 },
		markframe = 0,
		supercontents = supercontents,
		numplanes = numplanesbuf,
		planes = planesbuf,
		numedgedirs = numedgedirsbuf,
		edgedirs = edgedirs,
		numpoints = numpointsbuf,
		points = points,
		numtriangles = numtriangles,
		elements = elements,
		texture = texture,
		q3surfaceflags = q3surfaceflags,
		isaabb = isaabb,
		hasaabbplanes = hasaabbplanes,
	}

	xyzflags = 0
	for j = 1, math.min(6, numoriginalplanes) do
		local o = originalplanes[j]
		if o.normal[1] == 1 then
			xyzflags = bit32.bor(xyzflags, 1)
			brush.maxs[1] = o.dist
		elseif o.normal[1] == -1 then
			xyzflags = bit32.bor(xyzflags, 2)
			brush.mins[1] = -o.dist
		elseif o.normal[2] == 1 then
			xyzflags = bit32.bor(xyzflags, 4)
			brush.maxs[2] = o.dist
		elseif o.normal[2] == -1 then
			xyzflags = bit32.bor(xyzflags, 8)
			brush.mins[2] = -o.dist
		elseif o.normal[3] == 1 then
			xyzflags = bit32.bor(xyzflags, 16)
			brush.maxs[3] = o.dist
		elseif o.normal[3] == -1 then
			xyzflags = bit32.bor(xyzflags, 32)
			brush.mins[3] = -o.dist
		end
	end
	-- if not all xyzflags were set, then this is not a brush from q3map/q3map2, and needs reconstruction of the bounding box
	-- (this case works for any brush with valid points, but sometimes brushes are not reconstructed properly and hence the points are not valid, so this is reserved as a fallback case)
	if xyzflags ~= 63 then
		-- C reads brush->points[0] even when there are no points (the memory after the planes); with no points
		-- the first "point" is the start of the shared edgedirs / elements area, or zero bytes when that is empty
		local function pt(j: number, c: number): number
			if j < brush.numpoints then
				return readf32(points, j * 12 + c * 4)
			elseif (j - brush.numpoints) * 12 + c * 4 + 4 <= buffer.len(edgedirs) then
				return readf32(edgedirs, (j - brush.numpoints) * 12 + c * 4)
			end
			return 0
		end
		brush.mins[1], brush.mins[2], brush.mins[3] = pt(0, 0), pt(0, 1), pt(0, 2)
		brush.maxs[1], brush.maxs[2], brush.maxs[3] = pt(0, 0), pt(0, 1), pt(0, 2)
		for j = 1, brush.numpoints - 1 do
			brush.mins[1] = math.min(brush.mins[1], pt(j, 0))
			brush.mins[2] = math.min(brush.mins[2], pt(j, 1))
			brush.mins[3] = math.min(brush.mins[3], pt(j, 2))
			brush.maxs[1] = math.max(brush.maxs[1], pt(j, 0))
			brush.maxs[2] = math.max(brush.maxs[2], pt(j, 1))
			brush.maxs[3] = math.max(brush.maxs[3], pt(j, 2))
		end
	end
	brush.mins[1] = R(brush.mins[1] - 1)
	brush.mins[2] = R(brush.mins[2] - 1)
	brush.mins[3] = R(brush.mins[3] - 1)
	brush.maxs[1] = R(brush.maxs[1] + 1)
	brush.maxs[2] = R(brush.maxs[2] + 1)
	brush.maxs[3] = R(brush.maxs[3] + 1)
	Collision_ValidateBrush(brush)
	return brush
end

-- ---------------------------------------------------------------------------------------------------------
-- collision.c L13-22: the static cvar_t of this file (and developer_extra of host.c, which the triangle brush
-- code reads). As in C their value / integer are 0 until Collision_Init registers them. `cv` holds the records;
-- Collision_Init rebinds them, so read them through `cv` (collision.cv from other modules).
local CVAR_DEFS: { { string } } = {
	{ "collision_impactnudge", "0.03125", "how much to back off from the impact" },
	{
		"collision_extendmovelength",
		"16",
		"internal bias on trace length to ensure detection of collisions within the collision_impactnudge distance so that short moves do not degrade across frames (this does not alter the final trace length)",
	},
	{
		"collision_extendtracelinelength",
		"1",
		"internal bias for traceline() qc builtin to account for collision_impactnudge (this does not alter the final trace length)",
	},
	{
		"collision_extendtraceboxlength",
		"1",
		"internal bias for tracebox() qc builtin to account for collision_impactnudge (this does not alter the final trace length)",
	},
	{
		"collision_debug_tracelineasbox",
		"0",
		"workaround for any bugs in Collision_TraceLineBrushFloat by using Collision_TraceBrushBrushFloat",
	},
	{
		"collision_cache",
		"1",
		"store results of collision traces for next frame to reuse if possible (optimization)",
	},
	{
		"collision_triangle_bevelsides",
		"0",
		"generate sloped edge planes on triangles - if 0, see axialedgeplanes",
	},
	{
		"collision_triangle_axialsides",
		"1",
		"generate axially-aligned edge planes on triangles - otherwise use perpendicular edge planes",
	},
	{
		"collision_bih_fullrecursion",
		"0",
		"debugging option to disable the bih recursion optimizations by iterating the entire tree",
	},
}
local cv: { [string]: cvar.Cvar } = {}
for _, d in CVAR_DEFS do
	cv[d[1]] = cvar.static(0, d[1], d[2], d[3])
end
cv.developer_extra = cvar.static(0, "developer_extra", "0", "")
collision.cv = cv

local cache_notported = false

-- port: collision.c Collision_Init L26-40 @xonotic-v0.8.6
-- (host.luau registers every dedicated-server cvar from its generated table before the per-file init functions
-- run; a cvar that is already registered is this file's cvar_t, so its record is taken instead of a second one.
-- Call it again after cvar.reset().)
function collision.Collision_Init()
	for _, d in CVAR_DEFS do
		local existing = cvar.Cvar_FindVar(d[1])
		if existing then
			cv[d[1]] = existing
		else
			local c = cvar.static(0, d[1], d[2], d[3])
			cvar.Cvar_RegisterVariable(c)
			cv[d[1]] = c
		end
	end
	-- extern cvar_t developer_extra (registered by Host_InitLocal)
	cv.developer_extra = cvar.Cvar_FindVar("developer_extra") or cvar.static(0, "developer_extra", "0", "")
	-- collision_mempool = Mem_AllocPool("collision cache", 0, NULL); Collision_Cache_Init(collision_mempool);
	if not cache_notported then
		cache_notported = true
		print("NOT YET PORTED: Collision_Cache_Init (collision.c trace cache)")
	end
end

-- collision.h trace_t L16-68 (plane_t: normal + dist)
export type trace_t = {
	allsolid: boolean, -- if true, the entire trace was in solid (see hitsupercontentsmask)
	startsolid: boolean, -- if true, the initial point was in solid (see hitsupercontentsmask)
	worldstartsolid: boolean,
	bmodelstartsolid: boolean,
	inopen: boolean,
	inwater: boolean,
	-- fraction of the total distance that was traveled before impact
	-- in case of impact this is actually nudged a bit off the surface
	-- (1.0 = did not hit anything)
	fraction: number,
	-- final position of the trace (simply a point between start and end)
	endpos: { number },
	-- surface normal at impact (not really correct for edge collisions)
	plane: { normal: { number }, dist: number },
	ent: any,
	hitsupercontentsmask: number,
	skipsupercontentsmask: number,
	skipmaterialflagsmask: number,
	startsupercontents: number,
	hitsupercontents: number,
	hitq3surfaceflags: number,
	hittexture: any,
	startfound: boolean,
	-- if startsolid, contains the minimum penetration depth found in the
	-- trace, and the normal needed to push it out of that solid
	startdepth: number,
	startdepthnormal: { number },
	starttexture: any,
}

-- A zeroed trace_t (C: memset(trace, 0, sizeof(*trace)); callers then set fraction = 1 and the masks).
function collision.newtrace(): trace_t
	return {
		allsolid = false,
		startsolid = false,
		worldstartsolid = false,
		bmodelstartsolid = false,
		inopen = false,
		inwater = false,
		fraction = 0,
		endpos = { 0, 0, 0 },
		plane = { normal = { 0, 0, 0 }, dist = 0 },
		ent = nil,
		hitsupercontentsmask = 0,
		skipsupercontentsmask = 0,
		skipmaterialflagsmask = 0,
		startsupercontents = 0,
		hitsupercontents = 0,
		hitq3surfaceflags = 0,
		hittexture = nil,
		startfound = false,
		startdepth = 0,
		startdepthnormal = { 0, 0, 0 },
		starttexture = nil,
	}
end

-- memset(trace, 0, sizeof(*trace)) on an existing record (its vectors are kept and zeroed)
function collision.cleartrace(t: trace_t)
	t.allsolid = false
	t.startsolid = false
	t.worldstartsolid = false
	t.bmodelstartsolid = false
	t.inopen = false
	t.inwater = false
	t.fraction = 0
	t.endpos[1], t.endpos[2], t.endpos[3] = 0, 0, 0
	t.plane.normal[1], t.plane.normal[2], t.plane.normal[3] = 0, 0, 0
	t.plane.dist = 0
	t.ent = nil
	t.hitsupercontentsmask = 0
	t.skipsupercontentsmask = 0
	t.skipmaterialflagsmask = 0
	t.startsupercontents = 0
	t.hitsupercontents = 0
	t.hitq3surfaceflags = 0
	t.hittexture = nil
	t.startfound = false
	t.startdepth = 0
	t.startdepthnormal[1], t.startdepthnormal[2], t.startdepthnormal[3] = 0, 0, 0
	t.starttexture = nil
end

local COLLISION_EDGECROSS_MINLENGTH2 = 1.0 / 4194304.0 -- (1.0f / 4194304.0f)
local COLLISION_SNAP = 1.0 / COLLISION_SNAPSCALE

-- texture ? texture->currentmaterialflags : 0
local function currentmaterialflags(texture: any): number
	return if texture then (texture.currentmaterialflags or 0) else 0
end

-- port: collision.c nearestplanedist_float L126-141 @xonotic-v0.8.6 (points: f32 buffer; normal: 3 floats)
local function nearestplanedist_float(n1: number, n2: number, n3: number, points: buffer, numpoints: number): number
	if numpoints == 0 then
		return 0
	end
	local bestdist = R(R(R(readf32(points, 0) * n1) + R(readf32(points, 4) * n2)) + R(readf32(points, 8) * n3))
	for i = 1, numpoints - 1 do
		local o = i * 12
		local dist = R(R(R(readf32(points, o) * n1) + R(readf32(points, o + 4) * n2)) + R(readf32(points, o + 8) * n3))
		if dist < bestdist then
			bestdist = dist
		end
	end
	return bestdist
end

-- furthestplanedist_float (L142-156) with the normal as three numbers, for the trace loops
local function furthestplanedist3(n1: number, n2: number, n3: number, points: buffer, numpoints: number): number
	if numpoints == 0 then
		return 0
	end
	local bestdist = R(R(R(readf32(points, 0) * n1) + R(readf32(points, 4) * n2)) + R(readf32(points, 8) * n3))
	for i = 1, numpoints - 1 do
		local o = i * 12
		local dist = R(R(R(readf32(points, o) * n1) + R(readf32(points, o + 4) * n2)) + R(readf32(points, o + 8) * n3))
		if dist > bestdist then
			bestdist = dist
		end
	end
	return bestdist
end

-- port: collision.c Collision_CalcEdgeDirsForPolygonBrushFloat L158-163 @xonotic-v0.8.6
local function Collision_CalcEdgeDirsForPolygonBrushFloat(brush: colbrushf_t)
	local points, edgedirs = brush.points, brush.edgedirs
	local j = brush.numpoints - 1
	for i = 0, brush.numpoints - 1 do
		writef32(edgedirs, j * 12, readf32(points, i * 12) - readf32(points, j * 12))
		writef32(edgedirs, j * 12 + 4, readf32(points, i * 12 + 4) - readf32(points, j * 12 + 4))
		writef32(edgedirs, j * 12 + 8, readf32(points, i * 12 + 8) - readf32(points, j * 12 + 8))
		j = i
	end
end

-- VectorNormalize (mathlib.h L118) on a { x, y, z } table
local function VectorNormalize(v: { number })
	local ilength = R(math.sqrt(R(R(R(v[1] * v[1]) + R(v[2] * v[2])) + R(v[3] * v[3]))))
	if ilength ~= 0 then
		ilength = R(1.0 / ilength)
	end
	v[1] = R(v[1] * ilength)
	v[2] = R(v[2] * ilength)
	v[3] = R(v[3] * ilength)
end

-- CrossProduct (mathlib.h L117) of floats into c
local function CrossProduct(a: { number }, b: { number }, c: { number })
	local c1 = R(R(a[2] * b[3]) - R(a[3] * b[2]))
	local c2 = R(R(a[3] * b[1]) - R(a[1] * b[3]))
	local c3 = R(R(a[1] * b[2]) - R(a[2] * b[1]))
	c[1], c[2], c[3] = c1, c2, c3
end

-- port: collision.c Collision_CalcPlanesForTriangleBrushFloat L453-557 @xonotic-v0.8.6
function collision.Collision_CalcPlanesForTriangleBrushFloat(brush: colbrushf_t)
	local edge0, edge1, edge2 = { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 }
	local pts = brush.points
	local planes = brush.planes
	local p0 = { readf32(pts, 0), readf32(pts, 4), readf32(pts, 8) }
	local p1 = { readf32(pts, 12), readf32(pts, 16), readf32(pts, 20) }
	local p2 = { readf32(pts, 24), readf32(pts, 28), readf32(pts, 32) }
	local n = planes[1].normal
	-- TriangleNormal(points[0], points[1], points[2], planes[0].normal)
	n[1] = R(R(R(p0[2] - p1[2]) * R(p2[3] - p1[3])) - R(R(p0[3] - p1[3]) * R(p2[2] - p1[2])))
	n[2] = R(R(R(p0[3] - p1[3]) * R(p2[1] - p1[1])) - R(R(p0[1] - p1[1]) * R(p2[3] - p1[3])))
	n[3] = R(R(R(p0[1] - p1[1]) * R(p2[2] - p1[2])) - R(R(p0[2] - p1[2]) * R(p2[1] - p1[1])))
	if R(R(R(n[1] * n[1]) + R(n[2] * n[2])) + R(n[3] * n[3])) < R(0.0001) then
		-- there's no point in processing a degenerate triangle (GIGO - Garbage In, Garbage Out)
		-- note that some of these exist in q3bsp bspline patches
		brush.numplanes = 0
		return
	end

	-- there are 5 planes (front, back, sides) and 3 edges
	brush.numplanes = 5
	brush.numedgedirs = 3
	VectorNormalize(n)
	planes[1].dist = R(R(R(p0[1] * n[1]) + R(p0[2] * n[2])) + R(p0[3] * n[3]))
	local n1 = planes[2].normal
	n1[1], n1[2], n1[3] = -n[1], -n[2], -n[3]
	planes[2].dist = -planes[1].dist
	-- edge directions are easy to calculate
	for k = 1, 3 do
		edge0[k] = R(p2[k] - p0[k])
		edge1[k] = R(p0[k] - p1[k])
		edge2[k] = R(p1[k] - p2[k])
	end
	local ed = brush.edgedirs
	for k = 1, 3 do
		writef32(ed, (k - 1) * 4, edge0[k])
		writef32(ed, 12 + (k - 1) * 4, edge1[k])
		writef32(ed, 24 + (k - 1) * 4, edge2[k])
	end
	local s2, s3, s4 = planes[3].normal, planes[4].normal, planes[5].normal
	-- now select an algorithm to generate the side planes
	if cv.collision_triangle_bevelsides.integer ~= 0 then
		-- use 45 degree slopes at the edges of the triangle to make a sinking trace error turn into "riding up" the slope rather than getting stuck
		CrossProduct(edge0, n, s2)
		CrossProduct(edge1, n, s3)
		CrossProduct(edge2, n, s4)
		VectorNormalize(s2)
		VectorNormalize(s3)
		VectorNormalize(s4)
		for k = 1, 3 do
			s2[k] = R(s2[k] + n[k])
			s3[k] = R(s3[k] + n[k])
			s4[k] = R(s4[k] + n[k])
		end
		VectorNormalize(s2)
		VectorNormalize(s3)
		VectorNormalize(s4)
	elseif cv.collision_triangle_axialsides.integer ~= 0 then
		local projectionnormal = { 0, 0, 0 }
		local projectionedge0 = { edge0[1], edge0[2], edge0[3] }
		local projectionedge1 = { edge1[1], edge1[2], edge1[3] }
		local projectionedge2 = { edge2[1], edge2[2], edge2[3] }
		local bestdist = math.abs(n[1])
		local best = 0
		for i = 1, 2 do
			local dist = math.abs(n[i + 1])
			if bestdist < dist then
				bestdist = dist
				best = i
			end
		end
		if n[best + 1] < 0 then
			projectionnormal[best + 1] = -1
		else
			projectionnormal[best + 1] = 1
		end
		projectionedge0[best + 1] = 0
		projectionedge1[best + 1] = 0
		projectionedge2[best + 1] = 0
		CrossProduct(projectionedge0, projectionnormal, s2)
		CrossProduct(projectionedge1, projectionnormal, s3)
		CrossProduct(projectionedge2, projectionnormal, s4)
		VectorNormalize(s2)
		VectorNormalize(s3)
		VectorNormalize(s4)
	else
		CrossProduct(edge0, n, s2)
		CrossProduct(edge1, n, s3)
		CrossProduct(edge2, n, s4)
		VectorNormalize(s2)
		VectorNormalize(s3)
		VectorNormalize(s4)
	end
	planes[3].dist = R(R(R(p2[1] * s2[1]) + R(p2[2] * s2[2])) + R(p2[3] * s2[3]))
	planes[4].dist = R(R(R(p0[1] * s3[1]) + R(p0[2] * s3[2])) + R(p0[3] * s3[3]))
	planes[5].dist = R(R(R(p1[1] * s4[1]) + R(p1[2] * s4[2])) + R(p1[3] * s4[3]))

	if cv.developer_extra.integer ~= 0 then
		-- validity check - will be disabled later
		Collision_ValidateBrush(brush)
		for i = 0, brush.numplanes - 1 do
			local pl = planes[i + 1]
			for j = 0, brush.numpoints - 1 do
				if DotProduct_bv(pts, j * 12, pl.normal) > R(pl.dist + COLLISION_PLANE_DIST_EPSILON) then
					Con_DPrintf("Error in brush plane generation, plane %i\n", i)
				end
			end
		end
	end
end

-- port: collision.c Collision_TraceBrushBrushFloat L560-759 @xonotic-v0.8.6
-- NOTE: start and end of each brush pair must have same numplanes/numpoints
function collision.Collision_TraceBrushBrushFloat(
	trace: trace_t,
	trace_start: colbrushf_t,
	trace_end: colbrushf_t,
	other_start: colbrushf_t,
	other_end: colbrushf_t
)
	local nplane2: number, nedge1: number, nedge2: number
	local hitq3surfaceflags = 0
	local tracenumedgedirs = trace_start.numedgedirs
	local tracenumpoints = trace_start.numpoints
	local othernumpoints = other_start.numpoints
	local numplanes1 = other_start.numplanes
	local numplanes2 = numplanes1 + trace_start.numplanes
	local numplanes3 = numplanes2 + trace_start.numedgedirs * other_start.numedgedirs * 2
	local enterfrac, leavefrac, enterfrac2 = -1, 1, -1
	local startdist: number, enddist: number, ie: number, f: number, imove: number
	local sp1, sp2, sp3, sp4 = 0, 0, 0, 0 -- startplane
	local ep1, ep2, ep3, ep4 = 0, 0, 0, 0 -- endplane
	local ni1, ni2, ni3, ni4 = 0, 0, 0, 0 -- newimpactplane
	local hittexture: any = nil
	local startdepth = 1
	local sdn1, sdn2, sdn3 = 0, 0, 0 -- startdepthnormal
	local starttexture: any = nil
	local impactnudge = cv.collision_impactnudge.value

	-- fast case for AABB vs compiled brushes (which begin with AABB planes and also have precomputed bevels for AABB collisions)
	if trace_start.isaabb and other_start.hasaabbplanes then
		numplanes2 = numplanes1
		numplanes3 = numplanes1
	end

	local os_planes, oe_planes = other_start.planes, other_end.planes
	local ts_planes, te_planes = trace_start.planes, trace_end.planes
	local ts_edges, te_edges = trace_start.edgedirs, trace_end.edgedirs
	local os_edges, oe_edges = other_start.edgedirs, other_end.edgedirs

	-- Separating Axis Theorem:
	-- if a supporting vector (plane normal) can be found that separates two
	-- objects, they are not colliding.
	--
	-- Minkowski Sum:
	-- reduce the size of one object to a point while enlarging the other to
	-- represent the space that point can not occupy.
	--
	-- try every plane we can construct between the two brushes and measure
	-- the distance between them.
	for nplane = 0, numplanes3 - 1 do
		if nplane < numplanes1 then
			nplane2 = nplane
			local a, b = os_planes[nplane2 + 1].normal, oe_planes[nplane2 + 1].normal
			sp1, sp2, sp3 = a[1], a[2], a[3]
			ep1, ep2, ep3 = b[1], b[2], b[3]
		elseif nplane < numplanes2 then
			nplane2 = nplane - numplanes1
			local a, b = ts_planes[nplane2 + 1].normal, te_planes[nplane2 + 1].normal
			sp1, sp2, sp3 = a[1], a[2], a[3]
			ep1, ep2, ep3 = b[1], b[2], b[3]
		else
			-- pick an edgedir from each brush and cross them
			nplane2 = nplane - numplanes2
			nedge1 = bit32.rshift(nplane2, 1)
			nedge2 = nedge1 // tracenumedgedirs
			nedge1 -= nedge2 * tracenumedgedirs
			local t1, t2, t3 =
				readf32(ts_edges, nedge1 * 12), readf32(ts_edges, nedge1 * 12 + 4), readf32(ts_edges, nedge1 * 12 + 8)
			local o1, o2, o3 =
				readf32(os_edges, nedge2 * 12), readf32(os_edges, nedge2 * 12 + 4), readf32(os_edges, nedge2 * 12 + 8)
			local u1, u2, u3 =
				readf32(te_edges, nedge1 * 12), readf32(te_edges, nedge1 * 12 + 4), readf32(te_edges, nedge1 * 12 + 8)
			local q1, q2, q3 =
				readf32(oe_edges, nedge2 * 12), readf32(oe_edges, nedge2 * 12 + 4), readf32(oe_edges, nedge2 * 12 + 8)
			if bit32.band(nplane2, 1) ~= 0 then
				-- CrossProduct(trace_start->edgedirs[nedge1].v, other_start->edgedirs[nedge2].v, startplane)
				sp1 = R(R(t2 * o3) - R(t3 * o2))
				sp2 = R(R(t3 * o1) - R(t1 * o3))
				sp3 = R(R(t1 * o2) - R(t2 * o1))
				ep1 = R(R(u2 * q3) - R(u3 * q2))
				ep2 = R(R(u3 * q1) - R(u1 * q3))
				ep3 = R(R(u1 * q2) - R(u2 * q1))
			else
				-- CrossProduct(other_start->edgedirs[nedge2].v, trace_start->edgedirs[nedge1].v, startplane)
				sp1 = R(R(o2 * t3) - R(o3 * t2))
				sp2 = R(R(o3 * t1) - R(o1 * t3))
				sp3 = R(R(o1 * t2) - R(o2 * t1))
				ep1 = R(R(q2 * u3) - R(q3 * u2))
				ep2 = R(R(q3 * u1) - R(q1 * u3))
				ep3 = R(R(q1 * u2) - R(q2 * u1))
			end
			if
				R(R(R(sp1 * sp1) + R(sp2 * sp2)) + R(sp3 * sp3)) < COLLISION_EDGECROSS_MINLENGTH2
				or R(R(R(ep1 * ep1) + R(ep2 * ep2)) + R(ep3 * ep3)) < COLLISION_EDGECROSS_MINLENGTH2
			then
				continue -- degenerate crossproducts
			end
			-- VectorNormalize(startplane); VectorNormalize(endplane)
			local il = R(math.sqrt(R(R(R(sp1 * sp1) + R(sp2 * sp2)) + R(sp3 * sp3))))
			if il ~= 0 then
				il = R(1.0 / il)
			end
			sp1, sp2, sp3 = R(sp1 * il), R(sp2 * il), R(sp3 * il)
			il = R(math.sqrt(R(R(R(ep1 * ep1) + R(ep2 * ep2)) + R(ep3 * ep3))))
			if il ~= 0 then
				il = R(1.0 / il)
			end
			ep1, ep2, ep3 = R(ep1 * il), R(ep2 * il), R(ep3 * il)
		end
		sp4 = furthestplanedist3(sp1, sp2, sp3, other_start.points, othernumpoints)
		ep4 = furthestplanedist3(ep1, ep2, ep3, other_end.points, othernumpoints)
		startdist = R(nearestplanedist_float(sp1, sp2, sp3, trace_start.points, tracenumpoints) - sp4)
		enddist = R(nearestplanedist_float(ep1, ep2, ep3, trace_end.points, tracenumpoints) - ep4)

		-- aside from collisions, this is also used for error correction
		if startdist <= 0.0 and nplane < numplanes1 and (startdepth < startdist or startdepth == 1) then
			startdepth = startdist
			sdn1, sdn2, sdn3 = sp1, sp2, sp3
			starttexture = os_planes[nplane2 + 1].texture
		end

		if startdist > enddist then
			-- moving into brush
			if enddist > 0.0 then
				return
			end
			if startdist >= 0 then
				-- enter
				imove = R(1 / R(startdist - enddist))
				f = R(startdist * imove)
				-- check if this will reduce the collision time range
				if enterfrac < f then
					-- reduced collision time range
					enterfrac = f
					-- if the collision time range is now empty, no collision
					if enterfrac > leavefrac then
						return
					end
					-- calculate the nudged fraction and impact normal we'll
					-- need if we accept this collision later
					enterfrac2 = R(R(startdist - impactnudge) * imove)
					-- if the collision would be further away than the trace's
					-- existing collision data, we don't care about this
					-- collision
					if enterfrac2 >= trace.fraction then
						return
					end
					ie = R(1.0 - enterfrac)
					ni1 = R(R(sp1 * ie) + R(ep1 * enterfrac))
					ni2 = R(R(sp2 * ie) + R(ep2 * enterfrac))
					ni3 = R(R(sp3 * ie) + R(ep3 * enterfrac))
					ni4 = R(R(sp4 * ie) + R(ep4 * enterfrac))
					if nplane < numplanes1 then
						-- use the plane from other
						nplane2 = nplane
						hitq3surfaceflags = os_planes[nplane2 + 1].q3surfaceflags
						hittexture = os_planes[nplane2 + 1].texture
					elseif nplane < numplanes2 then
						-- use the plane from trace
						nplane2 = nplane - numplanes1
						hitq3surfaceflags = ts_planes[nplane2 + 1].q3surfaceflags
						hittexture = ts_planes[nplane2 + 1].texture
					else
						hitq3surfaceflags = other_start.q3surfaceflags
						hittexture = other_start.texture
					end
				end
			end
		else
			-- moving out of brush
			if startdist >= 0 then
				return
			end
			if enddist > 0 then
				-- leave
				f = R(startdist / R(startdist - enddist))
				-- check if this will reduce the collision time range
				if leavefrac > f then
					-- reduced collision time range
					leavefrac = f
					-- if the collision time range is now empty, no collision
					if enterfrac > leavefrac then
						return
					end
				end
			end
		end
	end

	-- at this point we know the trace overlaps the brush because it was not
	-- rejected at any point in the loop above

	-- see if the trace started outside the brush or not
	if enterfrac > -1 then
		-- started outside, and overlaps, therefore there is a collision here
		-- store out the impact information
		if
			bit32.band(trace.hitsupercontentsmask, other_start.supercontents) ~= 0
			and bit32.band(trace.skipsupercontentsmask, other_start.supercontents) == 0
			and bit32.band(trace.skipmaterialflagsmask, currentmaterialflags(hittexture)) == 0
		then
			trace.hitsupercontents = other_start.supercontents
			trace.hitq3surfaceflags = hitq3surfaceflags
			trace.hittexture = hittexture
			trace.fraction = if enterfrac2 >= 0 then (if enterfrac2 < 1 then enterfrac2 else 1) else 0 -- bound(0, enterfrac2, 1)
			trace.plane.normal[1], trace.plane.normal[2], trace.plane.normal[3] = ni1, ni2, ni3
			trace.plane.dist = ni4
		end
	else
		-- started inside, update startsolid and friends
		trace.startsupercontents = bit32.bor(trace.startsupercontents, other_start.supercontents)
		if
			bit32.band(trace.hitsupercontentsmask, other_start.supercontents) ~= 0
			and bit32.band(trace.skipsupercontentsmask, other_start.supercontents) == 0
			and bit32.band(trace.skipmaterialflagsmask, currentmaterialflags(starttexture)) == 0
		then
			trace.startsolid = true
			if leavefrac < 1 then
				trace.allsolid = true
			end
			trace.plane.normal[1], trace.plane.normal[2], trace.plane.normal[3] = ni1, ni2, ni3
			trace.plane.dist = ni4
			if trace.startdepth > startdepth then
				trace.startdepth = startdepth
				trace.startdepthnormal[1], trace.startdepthnormal[2], trace.startdepthnormal[3] = sdn1, sdn2, sdn3
				trace.starttexture = starttexture
			end
		end
	end
end
local Collision_TraceBrushBrushFloat = collision.Collision_TraceBrushBrushFloat

-- collision.h colboxbrushf_t L130-137: the brush for a box (or a point). C embeds the arrays in the struct;
-- here Collision_BrushForBox returns the colbrushf_t itself.
-- port: collision.c Collision_BrushForBox L1143-1201 @xonotic-v0.8.6
function collision.Collision_BrushForBox(
	mins: { number },
	maxs: { number },
	supercontents: number,
	q3surfaceflags: number,
	texture: any
): colbrushf_t
	local points = buffer.create(8 * 12)
	local edgedirs = buffer.create(6 * 12)
	local planes: { colplanef_t } = table.create(6)
	for i = 1, 6 do
		planes[i] = { normal = { 0, 0, 0 }, dist = 0, q3surfaceflags = 0, texture = nil }
	end
	local brush: colbrushf_t = {
		mins = { 0, 0, 0 },
		maxs = { 0, 0, 0 },
		markframe = 0,
		supercontents = supercontents,
		numplanes = 0,
		planes = planes,
		numedgedirs = 0,
		edgedirs = edgedirs,
		numpoints = 0,
		points = points,
		numtriangles = 0,
		elements = buffer.create(0),
		texture = texture,
		q3surfaceflags = q3surfaceflags,
		isaabb = true,
		hasaabbplanes = true,
	}
	if mins[1] == maxs[1] and mins[2] == maxs[2] and mins[3] == maxs[3] then
		-- point brush
		brush.numpoints = 1
		brush.numedgedirs = 0
		brush.numplanes = 0
		writef32(points, 0, mins[1])
		writef32(points, 4, mins[2])
		writef32(points, 8, mins[3])
	else
		brush.numpoints = 8
		brush.numedgedirs = 3
		brush.numplanes = 6
		-- there are 8 points on a box
		-- there are 3 edgedirs on a box (both signs are tested in collision)
		-- there are 6 planes on a box
		for i = 0, 7 do
			writef32(points, i * 12, if bit32.band(i, 1) ~= 0 then maxs[1] else mins[1])
			writef32(points, i * 12 + 4, if bit32.band(i, 2) ~= 0 then maxs[2] else mins[2])
			writef32(points, i * 12 + 8, if bit32.band(i, 4) ~= 0 then maxs[3] else mins[3])
		end
		writef32(edgedirs, 0, 1)
		writef32(edgedirs, 16, 1)
		writef32(edgedirs, 32, 1)
		planes[1].normal[1] = -1
		planes[1].dist = -mins[1]
		planes[2].normal[1] = 1
		planes[2].dist = maxs[1]
		planes[3].normal[2] = -1
		planes[3].dist = -mins[2]
		planes[4].normal[2] = 1
		planes[4].dist = maxs[2]
		planes[5].normal[3] = -1
		planes[5].dist = -mins[3]
		planes[6].normal[3] = 1
		planes[6].dist = maxs[3]
		for i = 1, 6 do
			planes[i].q3surfaceflags = q3surfaceflags
			planes[i].texture = texture
		end
	end
	brush.mins[1], brush.mins[2], brush.mins[3] = R(mins[1] - 1), R(mins[2] - 1), R(mins[3] - 1)
	brush.maxs[1], brush.maxs[2], brush.maxs[3] = R(maxs[1] + 1), R(maxs[2] + 1), R(maxs[3] + 1)
	--Collision_ValidateBrush(&boxbrush->brush);
	return brush
end

-- port: collision.c Collision_TraceLineBrushFloat L761-909 @xonotic-v0.8.6
-- NOTE: start and end of each brush pair must have same numplanes/numpoints
function collision.Collision_TraceLineBrushFloat(
	trace: trace_t,
	linestart: { number },
	lineend: { number },
	other_start: colbrushf_t,
	other_end: colbrushf_t
)
	local hitq3surfaceflags = 0
	local numplanes = other_start.numplanes
	local enterfrac, leavefrac, enterfrac2 = -1, 1, -1
	local startdist: number, enddist: number, ie: number, f: number, imove: number
	local ni1, ni2, ni3, ni4 = 0, 0, 0, 0 -- newimpactplane
	local hittexture: any = nil
	local startdepth = 1
	local sdn1, sdn2, sdn3 = 0, 0, 0
	local starttexture: any = nil
	local impactnudge = cv.collision_impactnudge.value

	if cv.collision_debug_tracelineasbox.integer ~= 0 then
		local thisbrush_start = collision.Collision_BrushForBox(linestart, linestart, 0, 0, nil)
		local thisbrush_end = collision.Collision_BrushForBox(lineend, lineend, 0, 0, nil)
		Collision_TraceBrushBrushFloat(trace, thisbrush_start, thisbrush_end, other_start, other_end)
		return
	end

	local ls1, ls2, ls3 = linestart[1], linestart[2], linestart[3]
	local le1, le2, le3 = lineend[1], lineend[2], lineend[3]
	local os_planes, oe_planes = other_start.planes, other_end.planes

	-- (Separating Axis Theorem / Minkowski Sum, see Collision_TraceBrushBrushFloat)
	for nplane = 0, numplanes - 1 do
		local sp, ep = os_planes[nplane + 1], oe_planes[nplane + 1]
		local sn, en = sp.normal, ep.normal
		local sp4, ep4 = sp.dist, ep.dist
		startdist = R(R(R(R(ls1 * sn[1]) + R(ls2 * sn[2])) + R(ls3 * sn[3])) - sp4)
		enddist = R(R(R(R(le1 * en[1]) + R(le2 * en[2])) + R(le3 * en[3])) - ep4)

		-- aside from collisions, this is also used for error correction
		if startdist <= 0.0 and (startdepth < startdist or startdepth == 1) then
			startdepth = startdist
			sdn1, sdn2, sdn3 = sn[1], sn[2], sn[3]
			starttexture = sp.texture
		end

		if startdist > enddist then
			-- moving into brush
			if enddist > 0.0 then
				return
			end
			if startdist > 0 then
				-- enter
				imove = R(1 / R(startdist - enddist))
				f = R(startdist * imove)
				-- check if this will reduce the collision time range
				if enterfrac < f then
					-- reduced collision time range
					enterfrac = f
					-- if the collision time range is now empty, no collision
					if enterfrac > leavefrac then
						return
					end
					-- calculate the nudged fraction and impact normal we'll
					-- need if we accept this collision later
					enterfrac2 = R(R(startdist - impactnudge) * imove)
					-- if the collision would be further away than the trace's
					-- existing collision data, we don't care about this
					-- collision
					if enterfrac2 >= trace.fraction then
						return
					end
					ie = R(1.0 - enterfrac)
					ni1 = R(R(sn[1] * ie) + R(en[1] * enterfrac))
					ni2 = R(R(sn[2] * ie) + R(en[2] * enterfrac))
					ni3 = R(R(sn[3] * ie) + R(en[3] * enterfrac))
					ni4 = R(R(sp4 * ie) + R(ep4 * enterfrac))
					hitq3surfaceflags = sp.q3surfaceflags
					hittexture = sp.texture
				end
			end
		else
			-- moving out of brush
			if startdist > 0 then
				return
			end
			if enddist > 0 then
				-- leave
				f = R(startdist / R(startdist - enddist))
				-- check if this will reduce the collision time range
				if leavefrac > f then
					-- reduced collision time range
					leavefrac = f
					-- if the collision time range is now empty, no collision
					if enterfrac > leavefrac then
						return
					end
				end
			end
		end
	end

	-- at this point we know the trace overlaps the brush because it was not
	-- rejected at any point in the loop above

	-- see if the trace started outside the brush or not
	if enterfrac > -1 then
		-- started outside, and overlaps, therefore there is a collision here
		-- store out the impact information
		if
			bit32.band(trace.hitsupercontentsmask, other_start.supercontents) ~= 0
			and bit32.band(trace.skipsupercontentsmask, other_start.supercontents) == 0
			and bit32.band(trace.skipmaterialflagsmask, currentmaterialflags(hittexture)) == 0
		then
			trace.hitsupercontents = other_start.supercontents
			trace.hitq3surfaceflags = hitq3surfaceflags
			trace.hittexture = hittexture
			trace.fraction = if enterfrac2 >= 0 then (if enterfrac2 < 1 then enterfrac2 else 1) else 0 -- bound(0, enterfrac2, 1)
			trace.plane.normal[1], trace.plane.normal[2], trace.plane.normal[3] = ni1, ni2, ni3
			trace.plane.dist = ni4
		end
	else
		-- started inside, update startsolid and friends
		trace.startsupercontents = bit32.bor(trace.startsupercontents, other_start.supercontents)
		if
			bit32.band(trace.hitsupercontentsmask, other_start.supercontents) ~= 0
			and bit32.band(trace.skipsupercontentsmask, other_start.supercontents) == 0
			and bit32.band(trace.skipmaterialflagsmask, currentmaterialflags(starttexture)) == 0
		then
			trace.startsolid = true
			if leavefrac < 1 then
				trace.allsolid = true
			end
			trace.plane.normal[1], trace.plane.normal[2], trace.plane.normal[3] = ni1, ni2, ni3
			trace.plane.dist = ni4
			if trace.startdepth > startdepth then
				trace.startdepth = startdepth
				trace.startdepthnormal[1], trace.startdepthnormal[2], trace.startdepthnormal[3] = sdn1, sdn2, sdn3
				trace.starttexture = starttexture
			end
		end
	end
end

-- port: collision.c Collision_PointInsideBrushFloat L911-922 @xonotic-v0.8.6
function collision.Collision_PointInsideBrushFloat(point: { number }, brush: colbrushf_t): boolean
	-- BoxesOverlap(point, point, brush->mins, brush->maxs)
	if
		not (
			point[1] <= brush.maxs[1]
			and point[1] >= brush.mins[1]
			and point[2] <= brush.maxs[2]
			and point[2] >= brush.mins[2]
			and point[3] <= brush.maxs[3]
			and point[3] >= brush.mins[3]
		)
	then
		return false
	end
	for nplane = 1, brush.numplanes do
		local plane = brush.planes[nplane]
		local n = plane.normal
		if R(R(R(n[1] * point[1]) + R(n[2] * point[2])) + R(n[3] * point[3])) > plane.dist then
			return false
		end
	end
	return true
end

-- port: collision.c Collision_TracePointBrushFloat L924-984 @xonotic-v0.8.6
function collision.Collision_TracePointBrushFloat(trace: trace_t, linestart: { number }, other_start: colbrushf_t)
	local numplanes = other_start.numplanes
	local startdist: number
	local startdepth = 1
	local sdn1, sdn2, sdn3 = 0, 0, 0
	local starttexture: any = nil

	-- (Separating Axis Theorem / Minkowski Sum, see Collision_TraceBrushBrushFloat)
	for nplane = 1, numplanes do
		local sp = other_start.planes[nplane]
		local sn = sp.normal
		startdist = R(R(R(R(linestart[1] * sn[1]) + R(linestart[2] * sn[2])) + R(linestart[3] * sn[3])) - sp.dist)
		if startdist > 0 then
			return
		end

		-- aside from collisions, this is also used for error correction
		if startdepth < startdist or startdepth == 1 then
			startdepth = startdist
			sdn1, sdn2, sdn3 = sn[1], sn[2], sn[3]
			starttexture = sp.texture
		end
	end

	-- at this point we know the trace overlaps the brush because it was not
	-- rejected at any point in the loop above

	-- started inside, update startsolid and friends
	trace.startsupercontents = bit32.bor(trace.startsupercontents, other_start.supercontents)
	if
		bit32.band(trace.hitsupercontentsmask, other_start.supercontents) ~= 0
		and bit32.band(trace.skipsupercontentsmask, other_start.supercontents) == 0
		and bit32.band(trace.skipmaterialflagsmask, currentmaterialflags(starttexture)) == 0
	then
		trace.startsolid = true
		trace.allsolid = true
		-- VectorCopy(newimpactplane, trace->plane.normal): newimpactplane is all zero here
		trace.plane.normal[1], trace.plane.normal[2], trace.plane.normal[3] = 0, 0, 0
		trace.plane.dist = 0
		if trace.startdepth > startdepth then
			trace.startdepth = startdepth
			trace.startdepthnormal[1], trace.startdepthnormal[2], trace.startdepthnormal[3] = sdn1, sdn2, sdn3
			trace.starttexture = starttexture
		end
	end
end

-- The triangle brush of the Collision_TraceBrushTriangle* functions (C: locals on the stack). One scratch
-- brush is reused; every field the C code sets is set again for each triangle.
local tribrush: colbrushf_t = {
	mins = { 0, 0, 0 },
	maxs = { 0, 0, 0 },
	markframe = 0,
	supercontents = 0,
	numplanes = 5,
	planes = {
		{ normal = { 0, 0, 0 }, dist = 0, q3surfaceflags = 0, texture = nil },
		{ normal = { 0, 0, 0 }, dist = 0, q3surfaceflags = 0, texture = nil },
		{ normal = { 0, 0, 0 }, dist = 0, q3surfaceflags = 0, texture = nil },
		{ normal = { 0, 0, 0 }, dist = 0, q3surfaceflags = 0, texture = nil },
		{ normal = { 0, 0, 0 }, dist = 0, q3surfaceflags = 0, texture = nil },
	},
	numedgedirs = 3,
	edgedirs = buffer.create(36),
	numpoints = 3,
	points = buffer.create(36),
	numtriangles = 0,
	elements = buffer.create(0),
	texture = nil,
	q3surfaceflags = 0,
	isaabb = false,
	hasaabbplanes = false,
}

-- memset + the assignments at the top of Collision_TraceBrushTriangleMeshFloat / TraceBrushTriangleFloat
local function tribrush_init(supercontents: number, q3surfaceflags: number, texture: any)
	tribrush.isaabb = false
	tribrush.hasaabbplanes = false
	tribrush.numpoints = 3
	tribrush.numedgedirs = 3
	tribrush.numplanes = 5
	tribrush.supercontents = supercontents
	tribrush.q3surfaceflags = q3surfaceflags
	tribrush.texture = texture
	for i = 1, 5 do
		local pl = tribrush.planes[i]
		pl.normal[1], pl.normal[2], pl.normal[3] = 0, 0, 0
		pl.dist = 0
		pl.q3surfaceflags = q3surfaceflags
		pl.texture = texture
	end
	buffer.fill(tribrush.edgedirs, 0, 0)
end

-- VectorCopy of the three corners + port: collision.c Collision_SnapCopyPoints L986-996 @xonotic-v0.8.6
-- (in == out == the triangle brush's points; fractionprecision COLLISION_SNAPSCALE, inverse COLLISION_SNAP)
local function tribrush_points(vertex3f: buffer, a: number, b: number, c: number)
	local pts = tribrush.points
	for k = 0, 8, 4 do
		writef32(pts, k, math.floor(R(R(readf32(vertex3f, a + k) * COLLISION_SNAPSCALE) + 0.5)) * COLLISION_SNAP)
		writef32(pts, 12 + k, math.floor(R(R(readf32(vertex3f, b + k) * COLLISION_SNAPSCALE) + 0.5)) * COLLISION_SNAP)
		writef32(pts, 24 + k, math.floor(R(R(readf32(vertex3f, c + k) * COLLISION_SNAPSCALE) + 0.5)) * COLLISION_SNAP)
	end
end

-- one triangle of the mesh functions: snap, edge dirs, planes, trace
local function tribrush_trace(trace: trace_t, thisbrush_start: colbrushf_t, thisbrush_end: colbrushf_t)
	-- (numplanes / numedgedirs stay as the previous triangle left them, as in C: a degenerate triangle sets
	-- numplanes = 0 and nothing sets it back to 5 until a later triangle is not degenerate)
	Collision_CalcEdgeDirsForPolygonBrushFloat(tribrush)
	collision.Collision_CalcPlanesForTriangleBrushFloat(tribrush)
	Collision_TraceBrushBrushFloat(trace, thisbrush_start, thisbrush_end, tribrush, tribrush)
end

-- port: collision.c Collision_TraceBrushTriangleMeshFloat L998-1078 @xonotic-v0.8.6
-- (element3i: i32 buffer + byte offset; vertex3f: f32 buffer indexed from vertex 0; bbox6f: f32 buffer or nil)
function collision.Collision_TraceBrushTriangleMeshFloat(
	trace: trace_t,
	thisbrush_start: colbrushf_t,
	thisbrush_end: colbrushf_t,
	numtriangles: number,
	element3i: buffer,
	eofs: number,
	vertex3f: buffer,
	stride: number,
	bbox6f: buffer?,
	supercontents: number,
	q3surfaceflags: number,
	texture: any,
	segmentmins: { number },
	segmentmaxs: { number }
)
	local readi32 = buffer.readi32
	tribrush_init(supercontents, q3surfaceflags, texture)
	if stride > 0 then
		local bb = bbox6f :: buffer
		local cnt = (numtriangles + stride - 1) // stride
		for i = 0, cnt - 1 do
			local o = i * 24
			-- BoxesOverlap(bbox6f + i * 6, bbox6f + i * 6 + 3, segmentmins, segmentmaxs)
			if
				readf32(bb, o) <= segmentmaxs[1]
				and readf32(bb, o + 12) >= segmentmins[1]
				and readf32(bb, o + 4) <= segmentmaxs[2]
				and readf32(bb, o + 16) >= segmentmins[2]
				and readf32(bb, o + 8) <= segmentmaxs[3]
				and readf32(bb, o + 20) >= segmentmins[3]
			then
				for k = 0, stride - 1 do
					local tri = i * stride + k
					if tri >= numtriangles then
						break
					end
					local e = eofs + tri * 12
					tribrush_points(
						vertex3f,
						readi32(element3i, e) * 12,
						readi32(element3i, e + 4) * 12,
						readi32(element3i, e + 8) * 12
					)
					tribrush_trace(trace, thisbrush_start, thisbrush_end)
				end
			end
		end
	elseif stride == 0 then
		for i = 0, numtriangles - 1 do
			local e = eofs + i * 12
			local a, b, c = readi32(element3i, e) * 12, readi32(element3i, e + 4) * 12, readi32(element3i, e + 8) * 12
			-- TriangleBBoxOverlapsBox(v0, v1, v2, segmentmins, segmentmaxs)
			local overlap = true
			for k = 0, 2 do
				local x0, x1, x2 =
					readf32(vertex3f, a + k * 4), readf32(vertex3f, b + k * 4), readf32(vertex3f, c + k * 4)
				if
					not (
						math.min(x0, math.min(x1, x2)) < segmentmaxs[k + 1]
						and math.max(x0, math.max(x1, x2)) > segmentmins[k + 1]
					)
				then
					overlap = false
					break
				end
			end
			if overlap then
				tribrush_points(vertex3f, a, b, c)
				tribrush_trace(trace, thisbrush_start, thisbrush_end)
			end
		end
	else
		for i = 0, numtriangles - 1 do
			local e = eofs + i * 12
			tribrush_points(
				vertex3f,
				readi32(element3i, e) * 12,
				readi32(element3i, e + 4) * 12,
				readi32(element3i, e + 8) * 12
			)
			tribrush_trace(trace, thisbrush_start, thisbrush_end)
		end
	end
end

-- port: collision.c Collision_TraceLineTriangleFloat L1253-1367 @xonotic-v0.8.6
-- (the three corners are byte offsets p0 / p1 / p2 into vertex3f)
function collision.Collision_TraceLineTriangleFloat(
	trace: trace_t,
	linestart: { number },
	lineend: { number },
	vertex3f: buffer,
	p0: number,
	p1: number,
	p2: number,
	supercontents: number,
	q3surfaceflags: number,
	texture: any
)
	local a1, a2, a3 = readf32(vertex3f, p0), readf32(vertex3f, p0 + 4), readf32(vertex3f, p0 + 8) -- point0
	local b1, b2, b3 = readf32(vertex3f, p1), readf32(vertex3f, p1 + 4), readf32(vertex3f, p1 + 8) -- point1
	local c1, c2, c3 = readf32(vertex3f, p2), readf32(vertex3f, p2 + 4), readf32(vertex3f, p2 + 8) -- point2
	-- this code is designed for clockwise triangles (see the C source for the op counts)

	-- calculate the faceplanenormal of the triangle, this represents the front side
	local e01x, e01y, e01z = R(a1 - b1), R(a2 - b2), R(a3 - b3) -- edge01
	local e21x, e21y, e21z = R(c1 - b1), R(c2 - b2), R(c3 - b3) -- edge21
	local fx = R(R(e01y * e21z) - R(e01z * e21y))
	local fy = R(R(e01z * e21x) - R(e01x * e21z))
	local fz = R(R(e01x * e21y) - R(e01y * e21x))
	-- there's no point in processing a degenerate triangle (GIGO - Garbage In, Garbage Out)
	local faceplanenormallength2 = R(R(R(fx * fx) + R(fy * fy)) + R(fz * fz))
	if faceplanenormallength2 < R(0.0001) then
		return
	end
	-- calculate the distance
	local faceplanedist = R(R(R(a1 * fx) + R(a2 * fy)) + R(a3 * fz))
	-- if start point is on the back side there is no collision
	-- (we don't care about traces going through the triangle the wrong way)

	-- calculate the start distance
	local d1 = R(R(R(fx * linestart[1]) + R(fy * linestart[2])) + R(fz * linestart[3]))
	if d1 <= faceplanedist then
		return
	end

	-- calculate the end distance
	local d2 = R(R(R(fx * lineend[1]) + R(fy * lineend[2])) + R(fz * lineend[3]))
	-- if both are in front, there is no collision
	if d2 >= faceplanedist then
		return
	end

	-- from here on we know d1 is >= 0 and d2 is < 0
	-- this means the line starts infront and ends behind, passing through it

	-- calculate the recipricol of the distance delta,
	-- so we can use it multiple times cheaply (instead of division)
	local d = R(1.0 / R(d1 - d2))
	-- calculate the impact fraction by taking the start distance (> 0)
	-- and subtracting the face plane distance (this is the distance of the
	-- triangle along that same normal)
	-- then multiply by the recipricol distance delta
	local f = R(R(d1 - faceplanedist) * d)
	local f2 = R(f - R(cv.collision_impactnudge.value * d))
	-- skip out if this impact is further away than previous ones
	if f2 >= trace.fraction then
		return
	end
	-- calculate the perfect impact point for classification of insidedness
	local ix = R(linestart[1] + R(f * R(lineend[1] - linestart[1])))
	local iy = R(linestart[2] + R(f * R(lineend[2] - linestart[2])))
	local iz = R(linestart[3] + R(f * R(lineend[3] - linestart[3])))

	-- calculate the edge normal and reject if impact is outside triangle
	-- (an edge normal faces away from the triangle, to get the desired normal
	--  a crossproduct with the faceplanenormal is used, and because of the way
	-- the insidedness comparison is written it does not need to be normalized)

	-- first use the two edges from the triangle plane math
	-- the other edge only gets calculated if the point survives that long

	-- CrossProduct(edge01, faceplanenormal, edgenormal)
	local nx = R(R(e01y * fz) - R(e01z * fy))
	local ny = R(R(e01z * fx) - R(e01x * fz))
	local nz = R(R(e01x * fy) - R(e01y * fx))
	if R(R(R(ix * nx) + R(iy * ny)) + R(iz * nz)) > R(R(R(b1 * nx) + R(b2 * ny)) + R(b3 * nz)) then
		return
	end

	-- CrossProduct(faceplanenormal, edge21, edgenormal)
	nx = R(R(fy * e21z) - R(fz * e21y))
	ny = R(R(fz * e21x) - R(fx * e21z))
	nz = R(R(fx * e21y) - R(fy * e21x))
	if R(R(R(ix * nx) + R(iy * ny)) + R(iz * nz)) > R(R(R(c1 * nx) + R(c2 * ny)) + R(c3 * nz)) then
		return
	end

	local e02x, e02y, e02z = R(a1 - c1), R(a2 - c2), R(a3 - c3) -- edge02
	-- CrossProduct(faceplanenormal, edge02, edgenormal)
	nx = R(R(fy * e02z) - R(fz * e02y))
	ny = R(R(fz * e02x) - R(fx * e02z))
	nz = R(R(fx * e02y) - R(fy * e02x))
	if R(R(R(ix * nx) + R(iy * ny)) + R(iz * nz)) > R(R(R(a1 * nx) + R(a2 * ny)) + R(a3 * nz)) then
		return
	end

	-- skip if this trace should not be blocked by these contents
	if
		bit32.band(supercontents, trace.hitsupercontentsmask) == 0
		or bit32.band(supercontents, trace.skipsupercontentsmask) ~= 0
		or bit32.band(currentmaterialflags(texture), trace.skipmaterialflagsmask) ~= 0
	then
		return
	end

	-- store the new trace fraction
	trace.fraction = f2

	-- store the new trace plane (because collisions only happen from
	-- the front this is always simply the triangle normal, never flipped)
	d = R(1.0 / math.sqrt(faceplanenormallength2))
	trace.plane.normal[1] = R(fx * d)
	trace.plane.normal[2] = R(fy * d)
	trace.plane.normal[3] = R(fz * d)
	trace.plane.dist = R(faceplanedist * d)

	trace.hitsupercontents = supercontents
	trace.hitq3surfaceflags = q3surfaceflags
	trace.hittexture = texture
end

-- port: collision.c Collision_TraceLineTriangleMeshFloat L1080-1107 @xonotic-v0.8.6
function collision.Collision_TraceLineTriangleMeshFloat(
	trace: trace_t,
	linestart: { number },
	lineend: { number },
	numtriangles: number,
	element3i: buffer,
	eofs: number,
	vertex3f: buffer,
	stride: number,
	bbox6f: buffer?,
	supercontents: number,
	q3surfaceflags: number,
	texture: any,
	segmentmins: { number },
	segmentmaxs: { number }
)
	local readi32 = buffer.readi32
	-- FIXME: snap vertices?
	if stride > 0 then
		local bb = bbox6f :: buffer
		local cnt = (numtriangles + stride - 1) // stride
		for i = 0, cnt - 1 do
			local o = i * 24
			if
				readf32(bb, o) <= segmentmaxs[1]
				and readf32(bb, o + 12) >= segmentmins[1]
				and readf32(bb, o + 4) <= segmentmaxs[2]
				and readf32(bb, o + 16) >= segmentmins[2]
				and readf32(bb, o + 8) <= segmentmaxs[3]
				and readf32(bb, o + 20) >= segmentmins[3]
			then
				for k = 0, stride - 1 do
					local tri = i * stride + k
					if tri >= numtriangles then
						break
					end
					local e = eofs + tri * 12
					collision.Collision_TraceLineTriangleFloat(
						trace,
						linestart,
						lineend,
						vertex3f,
						readi32(element3i, e) * 12,
						readi32(element3i, e + 4) * 12,
						readi32(element3i, e + 8) * 12,
						supercontents,
						q3surfaceflags,
						texture
					)
				end
			end
		end
	else
		for i = 0, numtriangles - 1 do
			local e = eofs + i * 12
			collision.Collision_TraceLineTriangleFloat(
				trace,
				linestart,
				lineend,
				vertex3f,
				readi32(element3i, e) * 12,
				readi32(element3i, e + 4) * 12,
				readi32(element3i, e + 8) * 12,
				supercontents,
				q3surfaceflags,
				texture
			)
		end
	end
end

-- port: collision.c Collision_TraceBrushTriangleFloat L1109-1141 @xonotic-v0.8.6
-- (the three corners are byte offsets into vertex3f)
function collision.Collision_TraceBrushTriangleFloat(
	trace: trace_t,
	thisbrush_start: colbrushf_t,
	thisbrush_end: colbrushf_t,
	vertex3f: buffer,
	v0: number,
	v1: number,
	v2: number,
	supercontents: number,
	q3surfaceflags: number,
	texture: any
)
	tribrush_init(supercontents, q3surfaceflags, texture)
	tribrush_points(vertex3f, v0, v1, v2)
	tribrush_trace(trace, thisbrush_start, thisbrush_end)
end

-- port: collision.c Collision_BoundingBoxOfBrushTraceSegment L1369-1393 @xonotic-v0.8.6
-- (kept as in C: the "maxs" lines also use min(), so maxs comes out as the smallest corner + 1)
function collision.Collision_BoundingBoxOfBrushTraceSegment(
	start: colbrushf_t,
	end_: colbrushf_t,
	mins: { number },
	maxs: { number },
	startfrac: number,
	endfrac: number
)
	local ps, pe = start.points, end_.points
	local tempstart, tempend = { 0, 0, 0 }, { 0, 0, 0 }
	-- VectorLerp(v1, lerp, v2, out): out = v1 + lerp * (v2 - v1)
	for k = 1, 3 do
		local a, b = readf32(ps, (k - 1) * 4), readf32(pe, (k - 1) * 4)
		mins[k] = R(a + R(startfrac * R(b - a)))
		maxs[k] = mins[k]
	end
	for i = 0, start.numpoints - 1 do
		for k = 1, 3 do
			local a, b = readf32(ps, i * 12 + (k - 1) * 4), readf32(pe, i * 12 + (k - 1) * 4)
			tempstart[k] = R(a + R(startfrac * R(b - a)))
			tempend[k] = R(a + R(endfrac * R(b - a)))
		end
		for k = 1, 3 do
			mins[k] = math.min(mins[k], math.min(tempstart[k], tempend[k]))
		end
		for k = 1, 3 do
			maxs[k] = math.min(maxs[k], math.min(tempstart[k], tempend[k]))
		end
	end
	for k = 1, 3 do
		mins[k] = R(mins[k] - 1)
		maxs[k] = R(maxs[k] + 1)
	end
end

return collision
