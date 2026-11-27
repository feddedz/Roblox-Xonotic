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

-- ---------------------------------------------------------------------------------------------------------
-- Added for model_alias.c (task M4-ALIAS). Float arrays (float in[12], short pose7s[7]) are buffers passed as
-- (buffer, byte offset), as the C code passes a pointer into a bigger array.

-- matrixlib.c L19: const matrix4x4_t identitymatrix (row-major, #else branch)
matrixlib.identitymatrix = { m = { { 1, 0, 0, 0 }, { 0, 1, 0, 0 }, { 0, 0, 1, 0 }, { 0, 0, 0, 1 } } } :: matrix4x4_t

-- port: matrixlib.c Matrix4x4_Copy L21-24 @xonotic-v0.8.6 (*out = *in)
function matrixlib.Matrix4x4_Copy(out: matrix4x4_t, in_: matrix4x4_t)
	local o, a = out.m, in_.m
	for r = 1, 4 do
		local orow, arow = o[r], a[r]
		orow[1], orow[2], orow[3], orow[4] = arow[1], arow[2], arow[3], arow[4]
	end
end

-- port: matrixlib.c Matrix4x4_Clear L485-491 @xonotic-v0.8.6
function matrixlib.Matrix4x4_Clear(out: matrix4x4_t)
	for i = 1, 4 do
		for j = 1, 4 do
			out.m[i][j] = 0
		end
	end
end

-- port: matrixlib.c Matrix4x4_Accumulate L493-499 @xonotic-v0.8.6
-- (weight is a double: in * weight is a double product, the sum is rounded once when stored)
function matrixlib.Matrix4x4_Accumulate(out: matrix4x4_t, in_: matrix4x4_t, weight: number)
	for i = 1, 4 do
		for j = 1, 4 do
			out.m[i][j] = R(out.m[i][j] + in_.m[i][j] * weight)
		end
	end
end

-- port: matrixlib.c Matrix4x4_Normalize3 L510-535 @xonotic-v0.8.6 (#else branch; out may be in1)
function matrixlib.Matrix4x4_Normalize3(out: matrix4x4_t, in1: matrix4x4_t)
	local scale: number
	-- scale each rotation matrix vector to a length of 1
	-- intended for use after Matrix4x4_Interpolate or Matrix4x4_Accumulate
	if out ~= in1 then
		matrixlib.Matrix4x4_Copy(out, in1)
	end
	local a, o = in1.m, out.m
	for i = 1, 3 do
		-- float products and sums, sqrt and the scale in double
		scale = math.sqrt(R(R(R(a[1][i] * a[1][i]) + R(a[2][i] * a[2][i])) + R(a[3][i] * a[3][i])))
		if scale ~= 0 then
			scale = 1.0 / scale
		end
		o[1][i] = R(o[1][i] * scale)
		o[2][i] = R(o[2][i] * scale)
		o[3][i] = R(o[3][i] * scale)
	end
end

-- port: matrixlib.c Matrix4x4_FromArray12FloatGL L1354-1391 @xonotic-v0.8.6 (#else branch)
function matrixlib.Matrix4x4_FromArray12FloatGL(out: matrix4x4_t, b: buffer, o: number)
	local m = out.m
	local f = buffer.readf32
	m[1][1] = f(b, o)
	m[2][1] = f(b, o + 4)
	m[3][1] = f(b, o + 8)
	m[4][1] = 0
	m[1][2] = f(b, o + 12)
	m[2][2] = f(b, o + 16)
	m[3][2] = f(b, o + 20)
	m[4][2] = 0
	m[1][3] = f(b, o + 24)
	m[2][3] = f(b, o + 28)
	m[3][3] = f(b, o + 32)
	m[4][3] = 0
	m[1][4] = f(b, o + 36)
	m[2][4] = f(b, o + 40)
	m[3][4] = f(b, o + 44)
	m[4][4] = 1
end

-- port: matrixlib.c Matrix4x4_ToArray12FloatD3D L1393-1422 @xonotic-v0.8.6 (#else branch)
function matrixlib.Matrix4x4_ToArray12FloatD3D(in_: matrix4x4_t, b: buffer, o: number)
	local m = in_.m
	local w = buffer.writef32
	w(b, o, m[1][1])
	w(b, o + 4, m[1][2])
	w(b, o + 8, m[1][3])
	w(b, o + 12, m[1][4])
	w(b, o + 16, m[2][1])
	w(b, o + 20, m[2][2])
	w(b, o + 24, m[2][3])
	w(b, o + 28, m[2][4])
	w(b, o + 32, m[3][1])
	w(b, o + 36, m[3][2])
	w(b, o + 40, m[3][3])
	w(b, o + 44, m[3][4])
end

-- port: matrixlib.c Matrix4x4_FromArray12FloatD3D L1424-1461 @xonotic-v0.8.6 (#else branch)
function matrixlib.Matrix4x4_FromArray12FloatD3D(out: matrix4x4_t, b: buffer, o: number)
	local m = out.m
	local f = buffer.readf32
	m[1][1] = f(b, o)
	m[1][2] = f(b, o + 4)
	m[1][3] = f(b, o + 8)
	m[1][4] = f(b, o + 12)
	m[2][1] = f(b, o + 16)
	m[2][2] = f(b, o + 20)
	m[2][3] = f(b, o + 24)
	m[2][4] = f(b, o + 28)
	m[3][1] = f(b, o + 32)
	m[3][2] = f(b, o + 36)
	m[3][3] = f(b, o + 40)
	m[3][4] = f(b, o + 44)
	m[4][1] = 0
	m[4][2] = 0
	m[4][3] = 0
	m[4][4] = 1
end

-- port: matrixlib.c Matrix4x4_FromOriginQuat L1463-1476 @xonotic-v0.8.6 (#else branch; all doubles)
function matrixlib.Matrix4x4_FromOriginQuat(
	m4: matrix4x4_t,
	ox: number,
	oy: number,
	oz: number,
	x: number,
	y: number,
	z: number,
	w: number
)
	local m = m4.m
	m[1][1] = R(1 - 2 * (y * y + z * z))
	m[1][2] = R(2 * (x * y - z * w))
	m[1][3] = R(2 * (x * z + y * w))
	m[1][4] = R(ox)
	m[2][1] = R(2 * (x * y + z * w))
	m[2][2] = R(1 - 2 * (x * x + z * z))
	m[2][3] = R(2 * (y * z - x * w))
	m[2][4] = R(oy)
	m[3][1] = R(2 * (x * z - y * w))
	m[3][2] = R(2 * (y * z + x * w))
	m[3][3] = R(1 - 2 * (x * x + y * y))
	m[3][4] = R(oz)
	m[4][1] = 0
	m[4][2] = 0
	m[4][3] = 0
	m[4][4] = 1
end

-- see http://www.euclideanspace.com/maths/geometry/rotations/conversions/matrixToQuaternion/index.htm
-- port: matrixlib.c Matrix4x4_ToOrigin3Quat4Float L1479-1580 @xonotic-v0.8.6 (the #else of #if 0, #else branch
-- of MATRIX4x4_OPENGLORIENTATION; origin and quat are Luau arrays, C element i at [i + 1])
function matrixlib.Matrix4x4_ToOrigin3Quat4Float(m4: matrix4x4_t, origin: { number }, quat: { number })
	local m = m4.m
	local trace = R(R(m[1][1] + m[2][2]) + m[3][3])
	origin[1] = m[1][4]
	origin[2] = m[2][4]
	origin[3] = m[3][4]
	if trace > 0 then
		local r = R(math.sqrt(R(1.0 + trace)))
		local inv = R(0.5 / r)
		quat[1] = R(R(m[3][2] - m[2][3]) * inv)
		quat[2] = R(R(m[1][3] - m[3][1]) * inv)
		quat[3] = R(R(m[2][1] - m[1][2]) * inv)
		quat[4] = R(0.5 * r)
	elseif m[1][1] > m[2][2] and m[1][1] > m[3][3] then
		local r = R(math.sqrt(R(R(R(1.0 + m[1][1]) - m[2][2]) - m[3][3])))
		local inv = R(0.5 / r)
		quat[1] = R(0.5 * r)
		quat[2] = R(R(m[2][1] + m[1][2]) * inv)
		quat[3] = R(R(m[1][3] + m[3][1]) * inv)
		quat[4] = R(R(m[3][2] - m[2][3]) * inv)
	elseif m[2][2] > m[3][3] then
		local r = R(math.sqrt(R(R(R(1.0 + m[2][2]) - m[1][1]) - m[3][3])))
		local inv = R(0.5 / r)
		quat[1] = R(R(m[2][1] + m[1][2]) * inv)
		quat[2] = R(0.5 * r)
		quat[3] = R(R(m[3][2] + m[2][3]) * inv)
		quat[4] = R(R(m[1][3] - m[3][1]) * inv)
	else
		local r = R(math.sqrt(R(R(R(1.0 + m[3][3]) - m[1][1]) - m[2][2])))
		local inv = R(0.5 / r)
		quat[1] = R(R(m[1][3] + m[3][1]) * inv)
		quat[2] = R(R(m[3][2] + m[2][3]) * inv)
		quat[3] = R(0.5 * r)
		quat[4] = R(R(m[2][1] - m[1][2]) * inv)
	end
end

-- LordHavoc: I got this code from:
--http://www.doom3world.org/phpbb2/viewtopic.php?t=2884
-- port: matrixlib.c Matrix4x4_FromDoom3Joint L1584-1599 @xonotic-v0.8.6 (#else branch; all doubles)
function matrixlib.Matrix4x4_FromDoom3Joint(
	m4: matrix4x4_t,
	ox: number,
	oy: number,
	oz: number,
	x: number,
	y: number,
	z: number
)
	local w = 1.0 - (x * x + y * y + z * z)
	w = if w > 0.0 then -math.sqrt(w) else 0.0
	local m = m4.m
	m[1][1] = R(1 - 2 * (y * y + z * z))
	m[1][2] = R(2 * (x * y - z * w))
	m[1][3] = R(2 * (x * z + y * w))
	m[1][4] = R(ox)
	m[2][1] = R(2 * (x * y + z * w))
	m[2][2] = R(1 - 2 * (x * x + z * z))
	m[2][3] = R(2 * (y * z - x * w))
	m[2][4] = R(oy)
	m[3][1] = R(2 * (x * z - y * w))
	m[3][2] = R(2 * (y * z + x * w))
	m[3][3] = R(1 - 2 * (x * x + y * y))
	m[3][4] = R(oz)
	m[4][1] = 0
	m[4][2] = 0
	m[4][3] = 0
	m[4][4] = 1
end

-- port: matrixlib.c Matrix4x4_FromBonePose7s L1601-1614 @xonotic-v0.8.6 (pose7s: i16 buffer + byte offset)
function matrixlib.Matrix4x4_FromBonePose7s(m: matrix4x4_t, originscale: number, b: buffer, o: number)
	local s = buffer.readi16
	local quatscale = if s(b, o + 12) > 0 then R(-1.0 / 32767.0) else R(1.0 / 32767.0)
	local origin0 = R(s(b, o) * originscale)
	local origin1 = R(s(b, o + 2) * originscale)
	local origin2 = R(s(b, o + 4) * originscale)
	local quat0 = R(s(b, o + 6) * quatscale)
	local quat1 = R(s(b, o + 8) * quatscale)
	local quat2 = R(s(b, o + 10) * quatscale)
	local quat3 = R(s(b, o + 12) * quatscale)
	matrixlib.Matrix4x4_FromOriginQuat(m, origin0, origin1, origin2, quat0, quat1, quat2, quat3)
end

-- (short) of a float: gcc converts through a 32-bit cvttss2si (out of range and NaN give 0x80000000), then keeps
-- the low 16 bits
local function toshort(x: number): number
	if x ~= x or x >= 2147483648 or x < -2147483648 then
		return 0
	end
	local i = if x < 0 then math.ceil(x) else math.floor(x)
	i = i % 65536
	if i >= 32768 then
		i -= 65536
	end
	return i
end
matrixlib.toshort = toshort

-- port: matrixlib.c Matrix4x4_ToBonePose7s L1616-1635 @xonotic-v0.8.6 (pose7s: i16 buffer + byte offset)
function matrixlib.Matrix4x4_ToBonePose7s(m: matrix4x4_t, origininvscale: number, b: buffer, o: number)
	local origin = { 0, 0, 0 }
	local quat = { 0, 0, 0, 0 }
	local quatscale: number
	matrixlib.Matrix4x4_ToOrigin3Quat4Float(m, origin, quat)
	-- normalize quaternion so that it is unit length
	quatscale = R(R(R(R(quat[1] * quat[1]) + R(quat[2] * quat[2])) + R(quat[3] * quat[3])) + R(quat[4] * quat[4]))
	if quatscale ~= 0 then
		quatscale = R((if quat[4] >= 0 then -32767.0 else 32767.0) / math.sqrt(quatscale))
	end
	-- use a negative scale on the quat because the above function produces a
	-- positive quat[3] and canonical quaternions have negative quat[3]
	local w = buffer.writei16
	w(b, o, toshort(R(origin[1] * origininvscale)))
	w(b, o + 2, toshort(R(origin[2] * origininvscale)))
	w(b, o + 4, toshort(R(origin[3] * origininvscale)))
	w(b, o + 6, toshort(R(quat[1] * quatscale)))
	w(b, o + 8, toshort(R(quat[2] * quatscale)))
	w(b, o + 10, toshort(R(quat[3] * quatscale)))
	w(b, o + 12, toshort(R(quat[4] * quatscale)))
end

return matrixlib
