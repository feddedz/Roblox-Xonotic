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
local libm = require("./_port/libm")

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

-- port: matrixlib.c Matrix4x4_Invert_Simple L424-475 @xonotic-v0.8.6 (#else branch; out must not alias in1)
function matrixlib.Matrix4x4_Invert_Simple(out: matrix4x4_t, in1: matrix4x4_t)
	local a, o = in1.m, out.m
	-- we only support uniform scaling, so assume the first row is enough
	-- (note the lack of sqrt here, because we're trying to undo the scaling,
	-- this means multiplying by the inverse scale twice - squaring it, which
	-- makes the sqrt a waste of time)
	local scale = 1.0 / R(R(R(a[1][1] * a[1][1]) + R(a[1][2] * a[1][2])) + R(a[1][3] * a[1][3])) -- double

	-- invert the rotation by transposing and multiplying by the squared
	-- recipricol of the input matrix scale as described above
	o[1][1] = R(a[1][1] * scale)
	o[1][2] = R(a[2][1] * scale)
	o[1][3] = R(a[3][1] * scale)
	o[2][1] = R(a[1][2] * scale)
	o[2][2] = R(a[2][2] * scale)
	o[2][3] = R(a[3][2] * scale)
	o[3][1] = R(a[1][3] * scale)
	o[3][2] = R(a[2][3] * scale)
	o[3][3] = R(a[3][3] * scale)

	-- invert the translate
	o[1][4] = -R(R(R(a[1][4] * o[1][1]) + R(a[2][4] * o[1][2])) + R(a[3][4] * o[1][3]))
	o[2][4] = -R(R(R(a[1][4] * o[2][1]) + R(a[2][4] * o[2][2])) + R(a[3][4] * o[2][3]))
	o[3][4] = -R(R(R(a[1][4] * o[3][1]) + R(a[2][4] * o[3][2])) + R(a[3][4] * o[3][3]))

	-- don't know if there's anything worth doing here
	o[4][1] = 0
	o[4][2] = 0
	o[4][3] = 0
	o[4][4] = 1
end

-- port: matrixlib.c Matrix4x4_CreateIdentity L566-584 @xonotic-v0.8.6
function matrixlib.Matrix4x4_CreateIdentity(out: matrix4x4_t)
	local o = out.m
	o[1][1], o[1][2], o[1][3], o[1][4] = 1, 0, 0, 0
	o[2][1], o[2][2], o[2][3], o[2][4] = 0, 1, 0, 0
	o[3][1], o[3][2], o[3][3], o[3][4] = 0, 0, 1, 0
	o[4][1], o[4][2], o[4][3], o[4][4] = 0, 0, 0, 1
end

-- port: matrixlib.c Matrix4x4_CreateFromQuakeEntity L717-891 @xonotic-v0.8.6 (#else branches)
-- (all parameters are doubles; sin / cos are the platform's, as in engine/mathlib.luau)
function matrixlib.Matrix4x4_CreateFromQuakeEntity(
	out: matrix4x4_t,
	x: number,
	y: number,
	z: number,
	pitch: number,
	yaw: number,
	roll: number,
	scale: number
)
	local o = out.m
	local PI2_360 = math.pi * 2 / 360
	if roll ~= 0 then
		local angle = yaw * PI2_360
		local sy = libm.sin(angle)
		local cy = libm.cos(angle)
		angle = pitch * PI2_360
		local sp = libm.sin(angle)
		local cp = libm.cos(angle)
		angle = roll * PI2_360
		local sr = libm.sin(angle)
		local cr = libm.cos(angle)
		o[1][1] = R((cp * cy) * scale)
		o[1][2] = R((sr * sp * cy + cr * -sy) * scale)
		o[1][3] = R((cr * sp * cy + -sr * -sy) * scale)
		o[1][4] = R(x)
		o[2][1] = R((cp * sy) * scale)
		o[2][2] = R((sr * sp * sy + cr * cy) * scale)
		o[2][3] = R((cr * sp * sy + -sr * cy) * scale)
		o[2][4] = R(y)
		o[3][1] = R(-sp * scale)
		o[3][2] = R((sr * cp) * scale)
		o[3][3] = R((cr * cp) * scale)
		o[3][4] = R(z)
	elseif pitch ~= 0 then
		local angle = yaw * PI2_360
		local sy = libm.sin(angle)
		local cy = libm.cos(angle)
		angle = pitch * PI2_360
		local sp = libm.sin(angle)
		local cp = libm.cos(angle)
		o[1][1] = R((cp * cy) * scale)
		o[1][2] = R(-sy * scale)
		o[1][3] = R((sp * cy) * scale)
		o[1][4] = R(x)
		o[2][1] = R((cp * sy) * scale)
		o[2][2] = R(cy * scale)
		o[2][3] = R((sp * sy) * scale)
		o[2][4] = R(y)
		o[3][1] = R(-sp * scale)
		o[3][2] = 0
		o[3][3] = R(cp * scale)
		o[3][4] = R(z)
	elseif yaw ~= 0 then
		local angle = yaw * PI2_360
		local sy = libm.sin(angle)
		local cy = libm.cos(angle)
		o[1][1] = R(cy * scale)
		o[1][2] = R(-sy * scale)
		o[1][3] = 0
		o[1][4] = R(x)
		o[2][1] = R(sy * scale)
		o[2][2] = R(cy * scale)
		o[2][3] = 0
		o[2][4] = R(y)
		o[3][1] = 0
		o[3][2] = 0
		o[3][3] = R(scale)
		o[3][4] = R(z)
	else
		o[1][1] = R(scale)
		o[1][2] = 0
		o[1][3] = 0
		o[1][4] = R(x)
		o[2][1] = 0
		o[2][2] = R(scale)
		o[2][3] = 0
		o[2][4] = R(y)
		o[3][1] = 0
		o[3][2] = 0
		o[3][3] = R(scale)
		o[3][4] = R(z)
	end
	o[4][1] = 0
	o[4][2] = 0
	o[4][3] = 0
	o[4][4] = 1
end

-- port: matrixlib.c Matrix4x4_Transform L1659-1670 @xonotic-v0.8.6 (#else branch; out must not alias v)
function matrixlib.Matrix4x4_Transform(in_: matrix4x4_t, v: { number }, out: { number })
	local m = in_.m
	local v1, v2, v3 = v[1], v[2], v[3]
	out[1] = R(R(R(R(v1 * m[1][1]) + R(v2 * m[1][2])) + R(v3 * m[1][3])) + m[1][4])
	out[2] = R(R(R(R(v1 * m[2][1]) + R(v2 * m[2][2])) + R(v3 * m[2][3])) + m[2][4])
	out[3] = R(R(R(R(v1 * m[3][1]) + R(v2 * m[3][2])) + R(v3 * m[3][3])) + m[3][4])
end

-- port: matrixlib.c Matrix4x4_TransformPositivePlane L1701-1716 @xonotic-v0.8.6 (#else branch)
-- (returns o[0], o[1], o[2], o[3] instead of writing through the float pointer)
function matrixlib.Matrix4x4_TransformPositivePlane(
	in_: matrix4x4_t,
	x: number,
	y: number,
	z: number,
	d: number
): (number, number, number, number)
	local m = in_.m
	local scale = R(math.sqrt(R(R(R(m[1][1] * m[1][1]) + R(m[1][2] * m[1][2])) + R(m[1][3] * m[1][3]))))
	local iscale = R(1.0 / scale)
	local o1 = R(R(R(R(x * m[1][1]) + R(y * m[1][2])) + R(z * m[1][3])) * iscale)
	local o2 = R(R(R(R(x * m[2][1]) + R(y * m[2][2])) + R(z * m[2][3])) * iscale)
	local o3 = R(R(R(R(x * m[3][1]) + R(y * m[3][2])) + R(z * m[3][3])) * iscale)
	local o4 = R(R(d * scale) + R(R(R(o1 * m[1][4]) + R(o2 * m[2][4])) + R(o3 * m[3][4])))
	return o1, o2, o3, o4
end

return matrixlib
