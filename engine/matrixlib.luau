--!strict
--[[
	DarkPlaces matrixlib.c / matrixlib.h (Forest Hale); GPLv2 or later like the rest of DarkPlaces.
]]
--[[
	Port of matrixlib.c @xonotic-v0.8.6. PARTIAL: Matrix4x4_Concat, CreateTranslate, CreateScale3,
	ConcatTranslate (the users so far: model_brush.c light grid). MATRIX4x4_OPENGLORIENTATION is not defined in
	the release (matrixlib.h L7), so the row-major branch is the one ported.
	A matrix4x4_t is { m = { {4}, {4}, {4}, {4} } } with m[row + 1][col + 1]; vec_t is float: every element is a
	float32, each product and sum is rounded like C float arithmetic (D-004). The double arguments of the
	Create functions are rounded when stored.
	NOT YET PORTED: everything else in matrixlib.c, added with its users.
]]
local f32 = require("./_port/f32")

local matrixlib = {}

local R = f32.round

export type matrix4x4_t = { m: { { number } } }

function matrixlib.new(): matrix4x4_t
	return { m = { { 0, 0, 0, 0 }, { 0, 0, 0, 0 }, { 0, 0, 0, 0 }, { 0, 0, 0, 0 } } }
end

-- port: matrixlib.c Matrix4x4_Concat L85-122 @xonotic-v0.8.6 (#else branch; out must not alias in1 / in2)
function matrixlib.Matrix4x4_Concat(out: matrix4x4_t, in1: matrix4x4_t, in2: matrix4x4_t)
	local a, b, o = in1.m, in2.m, out.m
	for r = 1, 4 do
		local ar = a[r]
		for c = 1, 4 do
			-- in1[r][0] * in2[0][c] + in1[r][1] * in2[1][c] + in1[r][2] * in2[2][c] + in1[r][3] * in2[3][c]
			o[r][c] = R(R(R(R(ar[1] * b[1][c]) + R(ar[2] * b[2][c])) + R(ar[3] * b[3][c])) + R(ar[4] * b[4][c]))
		end
	end
end

-- port: matrixlib.c Matrix4x4_CreateTranslate L586-623 @xonotic-v0.8.6 (#else branch)
function matrixlib.Matrix4x4_CreateTranslate(out: matrix4x4_t, x: number, y: number, z: number)
	local o = out.m
	o[1][1], o[1][2], o[1][3], o[1][4] = 1, 0, 0, R(x)
	o[2][1], o[2][2], o[2][3], o[2][4] = 0, 1, 0, R(y)
	o[3][1], o[3][2], o[3][3], o[3][4] = 0, 0, 1, R(z)
	o[4][1], o[4][2], o[4][3], o[4][4] = 0, 0, 0, 1
end

-- port: matrixlib.c Matrix4x4_CreateScale3 L697-715 @xonotic-v0.8.6
function matrixlib.Matrix4x4_CreateScale3(out: matrix4x4_t, x: number, y: number, z: number)
	local o = out.m
	o[1][1], o[1][2], o[1][3], o[1][4] = R(x), 0, 0, 0
	o[2][1], o[2][2], o[2][3], o[2][4] = 0, R(y), 0, 0
	o[3][1], o[3][2], o[3][3], o[3][4] = 0, 0, R(z), 0
	o[4][1], o[4][2], o[4][3], o[4][4] = 0, 0, 0, 1
end

-- port: matrixlib.c Matrix4x4_ConcatTranslate L1759-1765 @xonotic-v0.8.6
function matrixlib.Matrix4x4_ConcatTranslate(out: matrix4x4_t, x: number, y: number, z: number)
	local base = matrixlib.new()
	local temp = matrixlib.new()
	for r = 1, 4 do
		for c = 1, 4 do
			base.m[r][c] = out.m[r][c]
		end
	end
	matrixlib.Matrix4x4_CreateTranslate(temp, x, y, z)
	matrixlib.Matrix4x4_Concat(out, base, temp)
end

return matrixlib
