--!strict
--!native
--[[
	DarkPlaces collision.c / collision.h (Forest Hale); GPLv2 or later like the rest of DarkPlaces.
]]
--[[
	Port of collision.c @xonotic-v0.8.6. PARTIAL (task M3-BSPLOAD, part 1): Collision_NewBrushFromPlanes with
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
	NOT YET PORTED: everything else in collision.c (triangle brushes, all tracing, the trace cache, cvars).
]]
local console = require("./console")
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

return collision
