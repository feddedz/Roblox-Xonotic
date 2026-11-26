--!strict
--[[
	DarkPlaces mathlib.c / mathlib.h, Copyright (C) 1996-1997 Id Software, Inc.; GPLv2 or later.
]]
--[[
	Port of mathlib.c @xonotic-v0.8.6. PARTIAL: the vector macros of mathlib.h used so far, AngleVectors,
	AnglesFromVectors, VectorVectors. A vec3_t is { x, y, z } (1-based); vec_t is float, so every float
	store and every float*float / float+float is rounded to float32 (D-004); double temporaries stay double.
	NOT YET PORTED: the rest of mathlib.c (planes, matrices, BoxOnPlaneSide, ...), added with their users.
]]
local f32 = require("./_port/f32")
local libm = require("./_port/libm")

local mathlib = {}

local R = f32.round
local M_PI = 3.14159265358979323846 -- mathlib.h L28

export type vec3 = { number }

-- mathlib.h DotProduct L112 (float operands: each product and sum is a float op)
function mathlib.DotProduct(a: vec3, b: vec3): number
	return R(R(R(a[1] * b[1]) + R(a[2] * b[2])) + R(a[3] * b[3]))
end
local DotProduct = mathlib.DotProduct

-- mathlib.h ANGLEMOD L84 (double result)
function mathlib.ANGLEMOD(a: number): number
	return a - 360.0 * math.floor(a / 360.0)
end

-- mathlib.h VectorNormalize L118 (in place)
function mathlib.VectorNormalize(v: vec3)
	local ilength = R(math.sqrt(DotProduct(v, v)))
	if ilength ~= 0 then
		ilength = R(1.0 / ilength)
	end
	v[1] = R(v[1] * ilength)
	v[2] = R(v[2] * ilength)
	v[3] = R(v[3] * ilength)
end

-- mathlib.h VectorNormalize2 L119
function mathlib.VectorNormalize2(v: vec3, dest: vec3)
	local ilength = R(math.sqrt(DotProduct(v, v)))
	if ilength ~= 0 then
		ilength = R(1.0 / ilength)
	end
	dest[1] = R(v[1] * ilength)
	dest[2] = R(v[2] * ilength)
	dest[3] = R(v[3] * ilength)
end

-- port: mathlib.c VectorVectors L199-227 @xonotic-v0.8.6
function mathlib.VectorVectors(forward: vec3, right: vec3, up: vec3)
	-- NOTE: this is consistent to AngleVectors applied to AnglesFromVectors
	if forward[1] == 0 and forward[2] == 0 then
		if forward[3] > 0 then
			right[1], right[2], right[3] = 0, -1, 0
			up[1], up[2], up[3] = -1, 0, 0
		else
			right[1], right[2], right[3] = 0, -1, 0
			up[1], up[2], up[3] = 1, 0, 0
		end
	else
		right[1] = forward[2]
		right[2] = -forward[1]
		right[3] = 0
		mathlib.VectorNormalize(right)
		up[1] = R(-forward[3] * forward[1])
		up[2] = R(-forward[3] * forward[2])
		up[3] = R(R(forward[1] * forward[1]) + R(forward[2] * forward[2]))
		mathlib.VectorNormalize(up)
	end
end

-- port: mathlib.c AngleVectors L444-496 @xonotic-v0.8.6 (PITCH 1, YAW 2, ROLL 3 here)
function mathlib.AngleVectors(angles: vec3, forward: vec3?, right: vec3?, up: vec3?)
	local angle = angles[2] * (M_PI * 2 / 360)
	local sy = libm.sin(angle)
	local cy = libm.cos(angle)
	angle = angles[1] * (M_PI * 2 / 360)
	local sp = libm.sin(angle)
	local cp = libm.cos(angle)
	if forward then
		forward[1] = R(cp * cy)
		forward[2] = R(cp * sy)
		forward[3] = R(-sp)
	end
	if right or up then
		if angles[3] ~= 0 then
			angle = angles[3] * (M_PI * 2 / 360)
			local sr = libm.sin(angle)
			local cr = libm.cos(angle)
			if right then
				right[1] = R(-1 * (sr * sp * cy + cr * -sy))
				right[2] = R(-1 * (sr * sp * sy + cr * cy))
				right[3] = R(-1 * (sr * cp))
			end
			if up then
				up[1] = R(cr * sp * cy + -sr * -sy)
				up[2] = R(cr * sp * sy + -sr * cy)
				up[3] = R(cr * cp)
			end
		else
			if right then
				right[1] = R(sy)
				right[2] = R(-cy)
				right[3] = 0
			end
			if up then
				up[1] = R(sp * cy)
				up[2] = R(sp * sy)
				up[3] = R(cp)
			end
		end
	end
end

-- port: mathlib.c AnglesFromVectors L650-728 @xonotic-v0.8.6 (the #if 0 debugging block is not compiled)
function mathlib.AnglesFromVectors(angles: vec3, forward: vec3, up: vec3?, flippitch: boolean)
	if forward[1] == 0 and forward[2] == 0 then
		if forward[3] > 0 then
			angles[1] = R(-M_PI * 0.5)
			angles[2] = if up then R(libm.atan2(-up[2], -up[1])) else 0
		else
			angles[1] = R(M_PI * 0.5)
			angles[2] = if up then R(libm.atan2(up[2], up[1])) else 0
		end
		angles[3] = 0
	else
		angles[2] = R(libm.atan2(forward[2], forward[1]))
		angles[1] = R(-libm.atan2(forward[3], math.sqrt(R(R(forward[1] * forward[1]) + R(forward[2] * forward[2])))))
		-- note: we know that angles[PITCH] is in ]-pi/2..pi/2[ due to atan2(anything, positive)
		if up then
			local cp, sp = R(libm.cos(angles[1])), R(libm.sin(angles[1]))
			-- note: we know cp > 0, due to the range angles[pitch] is in
			local cy, sy = R(libm.cos(angles[2])), R(libm.sin(angles[2]))
			local tleft = { -sy, cy, 0 }
			local tup = { R(sp * cy), R(sp * sy), cp }
			angles[3] = R(-libm.atan2(DotProduct(up, tleft), DotProduct(up, tup)))
			-- for up == '0 0 1', this is
			-- angles[ROLL] = -atan2(0, cp);
			-- which is 0
		else
			angles[3] = 0
		end
		-- so no up vector is equivalent to '1 0 0'!
	end
	-- now convert radians to degrees, and make all values positive
	angles[1] = R(angles[1] * (180.0 / M_PI))
	angles[2] = R(angles[2] * (180.0 / M_PI))
	angles[3] = R(angles[3] * (180.0 / M_PI))
	if flippitch then
		angles[1] = R(angles[1] * -1)
	end
	if angles[1] < 0 then
		angles[1] = R(angles[1] + 360)
	end
	if angles[2] < 0 then
		angles[2] = R(angles[2] + 360)
	end
	if angles[3] < 0 then
		angles[3] = R(angles[3] + 360)
	end
end

return mathlib
