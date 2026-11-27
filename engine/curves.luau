--!strict
--!native
--[[
	DarkPlaces curves.c / curves.h: "this code written by Forest Hale, on 2004-10-17, and placed into public
	domain; this implements Quadratic BSpline surfaces as seen in Quake3 by id Software".
]]
--[[
	Port of curves.c @xonotic-v0.8.6 (complete).
	Float arrays (float *) are f32 buffers passed as (buffer, byte offset); strides are in bytes as in C.
	Element arrays (int *) are i32 buffers passed the same way. Every float operation is rounded like C float
	arithmetic (D-004); pow() and log() are C double functions (libm.pow / libm.log).
	patchinfo_t: { xsize, ysize, lods = { { xtess, ytess }, { xtess, ytess } } } with lods[PATCH_LOD_x + 1].
]]
local f32 = require("./_port/f32")
local libm = require("./_port/libm")

local curves = {}

local R = f32.round
local readf32, writef32, writei32 = buffer.readf32, buffer.writef32, buffer.writei32

-- curves.h L4-6
curves.PATCH_LODS_NUM = 2
curves.PATCH_LOD_COLLISION = 0
curves.PATCH_LOD_VISUAL = 1
local PATCH_LODS_NUM = 2

-- curves.h patchinfo_t L8-14
export type patchinfo_t = {
	xsize: number,
	ysize: number,
	lods: { { xtess: number, ytess: number } },
}

-- port: curves.c Q3PatchDimForTess L52-60 @xonotic-v0.8.6
-- Calculate number of resulting vertex rows/columns by given patch size and tesselation factor
-- tess=0 means that we reduce detalization of base 3x3 patches by removing middle row and column of vertices
function curves.Q3PatchDimForTess(size: number, tess: number): number
	if tess > 0 then
		return (size - 1) * tess + 1
	elseif tess == 0 then
		return (size - 1) // 2 + 1
	else
		return 0 -- Maybe warn about wrong tess here?
	end
end
local Q3PatchDimForTess = curves.Q3PatchDimForTess

-- port: curves.c Q3PatchTesselateFloat L65-137 @xonotic-v0.8.6
function curves.Q3PatchTesselateFloat(
	numcomponents: number,
	outputstride: number,
	outputvertices: buffer,
	outofs: number,
	patchwidth: number,
	patchheight: number,
	inputstride: number,
	patchvertices: buffer,
	patchofs: number,
	tesselationwidth: number,
	tesselationheight: number
)
	local outputwidth = Q3PatchDimForTess(patchwidth, tesselationwidth)
	local px: number, py: number, a: number, b: number, c: number
	local cp = { { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 } } -- byte offsets of the control points in patchvertices
	local temp = { table.create(64, 0), table.create(64, 0), table.create(64, 0) }
	local xmax = math.max(1, 2 * tesselationwidth)
	local ymax = math.max(1, 2 * tesselationheight)
	-- iterate over the individual 3x3 quadratic spline surfaces one at a time
	-- expanding them to fill the output array (with some overlap to ensure
	-- the edges are filled)
	for k = 0, patchheight - 2, 2 do
		for l = 0, patchwidth - 2, 2 do
			-- set up control point pointers for quicker lookup later
			for y = 0, 2 do
				for x = 0, 2 do
					cp[y + 1][x + 1] = patchofs + ((k + y) * patchwidth + (l + x)) * inputstride
				end
			end
			-- for each row...
			for y = 0, ymax do
				-- calculate control points for this row by collapsing the 3
				-- rows of control points to one row using py
				py = R(y / ymax)
				-- calculate quadratic spline weights for py
				a = R(R(1.0 - py) * R(1.0 - py))
				b = R(R(1.0 - py) * R(2.0 * py))
				c = R(py * py)
				for component = 0, numcomponents - 1 do
					local o = component * 4
					for col = 1, 3 do
						temp[col][component + 1] = R(
							R(
								R(readf32(patchvertices, cp[1][col] + o) * a)
									+ R(readf32(patchvertices, cp[2][col] + o) * b)
							) + R(readf32(patchvertices, cp[3][col] + o) * c)
						)
					end
				end
				-- fetch a pointer to the beginning of the output vertex row
				local v = outofs + ((k * ymax // 2 + y) * outputwidth + l * xmax // 2) * outputstride
				-- for each column of the row...
				for x = 0, xmax do
					-- calculate point based on the row control points
					px = R(x / xmax)
					-- calculate quadratic spline weights for px
					-- (could be precalculated)
					a = R(R(1.0 - px) * R(1.0 - px))
					b = R(R(1.0 - px) * R(2.0 * px))
					c = R(px * px)
					for component = 0, numcomponents - 1 do
						local ci = component + 1
						writef32(
							outputvertices,
							v + component * 4,
							R(R(temp[1][ci] * a) + R(temp[2][ci] * b)) + R(temp[3][ci] * c)
						)
					end
					-- advance to next output vertex using outputstride
					-- (the next vertex may not be directly following this
					-- one, as this may be part of a larger structure)
					v += outputstride
				end
			end
		end
	end
end

-- port: curves.c Q3PatchTesselation L139-157 @xonotic-v0.8.6
local function Q3PatchTesselation(largestsquared3xcurvearea: number, tolerance: number): number
	local f: number
	-- f is actually a squared 2x curve area... so the formula had to be adjusted to give roughly the same subdivisions
	f = R(libm.pow(R(largestsquared3xcurvearea / 64.0), 0.25) / tolerance)
	--if(f < 0.25) // VERY flat patches
	if f < 0.0001 then -- TOTALLY flat patches
		return 0
	elseif f < 2 then
		return 1
	else
		return math.floor(libm.log(f) / libm.log(2.0)) + 1
		-- this is always at least 2
		-- maps [0.25..0.5[ to -1 (actually, 1 is returned)
		-- maps [0.5..1[ to 0 (actually, 1 is returned)
		-- maps [1..2[ to 1
		-- maps [2..4[ to 2
		-- maps [4..8[ to 4
	end
end

-- port: curves.c Squared3xCurveArea L159-230 @xonotic-v0.8.6 (#else branch)
-- a / control / b are byte offsets into `inb`
local function Squared3xCurveArea(inb: buffer, a: number, control: number, b: number, components: number): number
	-- (see the C source for the derivation: an upper bound of the area between the spline and the line a->b)
	local aa, bb, ab = 0, 0, 0
	for c = 0, components - 1 do
		local cc = readf32(inb, control + c * 4)
		local xa = R(readf32(inb, a + c * 4) - cc)
		local xb = R(readf32(inb, b + c * 4) - cc)
		aa = R(aa + R(xa * xa))
		ab = R(ab + R(xa * xb))
		bb = R(bb + R(xb * xb))
	end
	-- area is 0.5 * sqrt(aa*bb - ab*ab)
	-- 2x TRIANGLE area is sqrt(aa*bb - ab*ab)
	-- 3x CURVE area is sqrt(aa*bb - ab*ab)
	return R(R(aa * bb) - R(ab * ab))
end

-- port: curves.c Q3PatchTesselationOnX L233-250 @xonotic-v0.8.6
-- returns how much tesselation of each segment is needed to remain under tolerance
function curves.Q3PatchTesselationOnX(
	patchwidth: number,
	patchheight: number,
	components: number,
	inb: buffer,
	inofs: number,
	tolerance: number
): number
	local squared3xcurvearea: number
	local largestsquared3xcurvearea = 0
	for y = 0, patchheight - 1 do
		for x = 0, patchwidth - 2, 2 do
			local patch = inofs + ((y * patchwidth) + x) * components * 4
			squared3xcurvearea =
				Squared3xCurveArea(inb, patch, patch + components * 4, patch + 2 * components * 4, components)
			if largestsquared3xcurvearea < squared3xcurvearea then
				largestsquared3xcurvearea = squared3xcurvearea
			end
		end
	end
	return Q3PatchTesselation(largestsquared3xcurvearea, tolerance)
end

-- port: curves.c Q3PatchTesselationOnY L253-270 @xonotic-v0.8.6
-- returns how much tesselation of each segment is needed to remain under tolerance
function curves.Q3PatchTesselationOnY(
	patchwidth: number,
	patchheight: number,
	components: number,
	inb: buffer,
	inofs: number,
	tolerance: number
): number
	local squared3xcurvearea: number
	local largestsquared3xcurvearea = 0
	for y = 0, patchheight - 2, 2 do
		for x = 0, patchwidth - 1 do
			local patch = inofs + ((y * patchwidth) + x) * components * 4
			squared3xcurvearea = Squared3xCurveArea(
				inb,
				patch,
				patch + patchwidth * components * 4,
				patch + 2 * patchwidth * components * 4,
				components
			)
			if largestsquared3xcurvearea < squared3xcurvearea then
				largestsquared3xcurvearea = squared3xcurvearea
			end
		end
	end
	return Q3PatchTesselation(largestsquared3xcurvearea, tolerance)
end

-- port: curves.c FindEqualOddVertexInArray L273-297 @xonotic-v0.8.6
-- Find an equal vertex in array. Check only vertices with odd X and Y
-- (vertex: byte offset in vb; vertices: byte offset in vsb)
local function FindEqualOddVertexInArray(
	numcomponents: number,
	vb: buffer,
	vertex: number,
	vsb: buffer,
	vertices: number,
	width: number,
	height: number
): number
	for y = 0, height - 1, 2 do
		for x = 0, width - 1, 2 do
			local found = true
			for j = 0, numcomponents - 1 do
				if math.abs(R(readf32(vb, vertex + j * 4) - readf32(vsb, vertices + j * 4))) > 0.05 then
					-- div0: this is notably smaller than the smallest radiant grid
					-- but large enough so we don't need to get scared of roundoff
					-- errors
					found = false
					break
				end
			end
			if found then
				return y * width + x
			end
			vertices += numcomponents * 2 * 4
		end
		vertices += numcomponents * (width - 1) * 4
	end
	return -1
end

local SIDE_INVALID = -1
local SIDE_X = 0
local SIDE_Y = 1

-- port: curves.c GetSide L303-326 @xonotic-v0.8.6 (returns the side and *pointdist, nil when not set)
local function GetSide(p1: number, p2: number, width: number, _height: number): (number, number?)
	if p1 < 0 or p2 < 0 then
		return SIDE_INVALID, nil
	end
	local x1, y1 = p1 % width, p1 // width
	local x2, y2 = p2 % width, p2 // width
	if x1 == x2 then
		if y1 ~= y2 then
			return SIDE_Y, math.abs(y2 - y1)
		else
			return SIDE_INVALID, nil
		end
	elseif y1 == y2 then
		return SIDE_X, math.abs(x2 - x1)
	else
		return SIDE_INVALID, nil
	end
end

-- port: curves.c Q3PatchAdjustTesselation L330-390 @xonotic-v0.8.6
-- Increase tesselation of one of two touching patches to make a seamless connection between them
-- Returns false in case if patches were not modified, otherwise true
function curves.Q3PatchAdjustTesselation(
	numcomponents: number,
	patch1: patchinfo_t,
	patchvertices1: buffer,
	ofs1: number,
	patch2: patchinfo_t,
	patchvertices2: buffer,
	ofs2: number
): boolean
	-- what we are doing here is:
	--   we take for each corner of one patch
	--   and check if the other patch contains that corner
	--   once we have a pair of such matches
	local id1 = table.create(8, 0)
	local id2 = table.create(8, 0)
	local dist1, dist2 = 0, 0
	local modified = false

	-- Potential paired vertices (corners of the first patch)
	id1[1] = 0
	id1[2] = patch1.xsize - 1
	id1[3] = patch1.xsize * (patch1.ysize - 1)
	id1[4] = patch1.xsize * patch1.ysize - 1
	for i = 1, 4 do
		id2[i] = FindEqualOddVertexInArray(
			numcomponents,
			patchvertices1,
			ofs1 + numcomponents * id1[i] * 4,
			patchvertices2,
			ofs2,
			patch2.xsize,
			patch2.ysize
		)
	end

	-- Corners of the second patch
	id2[5] = 0
	id2[6] = patch2.xsize - 1
	id2[7] = patch2.xsize * (patch2.ysize - 1)
	id2[8] = patch2.xsize * patch2.ysize - 1
	for i = 5, 8 do
		id1[i] = FindEqualOddVertexInArray(
			numcomponents,
			patchvertices2,
			ofs2 + numcomponents * id2[i] * 4,
			patchvertices1,
			ofs1,
			patch1.xsize,
			patch1.ysize
		)
	end

	for i = 1, 8 do
		for j = i + 1, 8 do
			local side1, d1 = GetSide(id1[i], id1[j], patch1.xsize, patch1.ysize)
			if d1 then
				dist1 = d1
			end
			local side2, d2 = GetSide(id2[i], id2[j], patch2.xsize, patch2.ysize)
			if d2 then
				dist2 = d2
			end

			if side1 == SIDE_INVALID or side2 == SIDE_INVALID then
				continue
			end

			if dist1 ~= dist2 then
				-- no patch welding if the resolutions mismatch
				continue
			end

			-- Update every lod level
			for k = 1, PATCH_LODS_NUM do
				local l1, l2 = patch1.lods[k], patch2.lods[k]
				local tess1 = if side1 == SIDE_X then l1.xtess else l1.ytess
				local tess2 = if side2 == SIDE_X then l2.xtess else l2.ytess
				if tess1 ~= tess2 then
					if tess1 < tess2 then
						if side1 == SIDE_X then
							l1.xtess = tess2
						else
							l1.ytess = tess2
						end
					else
						if side2 == SIDE_X then
							l2.xtess = tess1
						else
							l2.ytess = tess1
						end
					end
					modified = true
				end
			end
		end
	end

	return modified
end

-- port: curves.c Q3PatchTriangleElements L400-439 @xonotic-v0.8.6
-- calculates elements for a grid of vertices
-- (such as those produced by Q3PatchTesselate)
-- (note: width and height are the actual vertex size, this produces
-- (width-1)*(height-1)*2 triangles, 3 elements each)
function curves.Q3PatchTriangleElements(
	elements: buffer,
	eofs: number,
	width: number,
	height: number,
	firstvertex: number
)
	local row0: number, row1: number
	local e = eofs
	for y = 0, height - 2 do
		if y % 2 ~= 0 then
			-- swap the triangle order in odd rows as optimization for collision stride
			row0 = firstvertex + (y + 0) * width + width - 2
			row1 = firstvertex + (y + 1) * width + width - 2
			for _ = 0, width - 2 do
				writei32(elements, e, row1)
				writei32(elements, e + 4, row1 + 1)
				writei32(elements, e + 8, row0 + 1)
				writei32(elements, e + 12, row0)
				writei32(elements, e + 16, row1)
				writei32(elements, e + 20, row0 + 1)
				e += 24
				row0 -= 1
				row1 -= 1
			end
		else
			row0 = firstvertex + (y + 0) * width
			row1 = firstvertex + (y + 1) * width
			for _ = 0, width - 2 do
				writei32(elements, e, row0)
				writei32(elements, e + 4, row1)
				writei32(elements, e + 8, row0 + 1)
				writei32(elements, e + 12, row1)
				writei32(elements, e + 16, row1 + 1)
				writei32(elements, e + 20, row0 + 1)
				e += 24
				row0 += 1
				row1 += 1
			end
		end
	end
end

return curves
