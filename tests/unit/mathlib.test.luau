--!strict
-- engine/mathlib.luau against mathlib.c compiled from the release source (tests/vectors/mathlib.tsv,
-- tools/testgen/mathlib_vectors.sh); float results compared bit for bit.
local t = require("../_lib/t")
local mathlib = require("../../engine/mathlib")
local f32 = require("../../engine/_port/f32")

return function(ctx: t.Ctx)
	local function vec(s: string): { number }
		local a, b, c = string.match(s, "^(%x+) (%x+) (%x+)$")
		return {
			f32.frombits(tonumber(a, 16) :: number),
			f32.frombits(tonumber(b, 16) :: number),
			f32.frombits(tonumber(c, 16) :: number),
		}
	end
	local function bits(v: { number }): string
		return string.format("%08x %08x %08x", f32.tobits(v[1]), f32.tobits(v[2]), f32.tobits(v[3]))
	end
	local n = 0
	for line in string.gmatch(t.read("tests/vectors/mathlib.tsv"), "[^\n]+") do
		local cols = string.split(line, "\t")
		local kind = cols[1]
		if kind == "AV" then
			local f, r, u = {}, {}, {}
			mathlib.AngleVectors(vec(cols[2]), f, r, u)
			t.eq(
				ctx,
				bits(f) .. "|" .. bits(r) .. "|" .. bits(u),
				cols[3] .. "|" .. cols[4] .. "|" .. cols[5],
				"AngleVectors " .. cols[2]
			)
		elseif kind == "AFV" then
			local a = {}
			mathlib.AnglesFromVectors(a, vec(cols[2]), vec(cols[3]), true)
			t.eq(ctx, bits(a), cols[4], "AnglesFromVectors " .. cols[2] .. " / " .. cols[3])
		elseif kind == "AFV0" then
			local a = {}
			mathlib.AnglesFromVectors(a, vec(cols[2]), nil, false)
			t.eq(ctx, bits(a), cols[3], "AnglesFromVectors no up " .. cols[2])
		elseif kind == "N2" then
			local d = {}
			mathlib.VectorNormalize2(vec(cols[2]), d)
			t.eq(ctx, bits(d), cols[3], "VectorNormalize2 " .. cols[2])
		elseif kind == "VV" then
			local r, u = {}, {}
			mathlib.VectorVectors(vec(cols[2]), r, u)
			t.eq(ctx, bits(r) .. "|" .. bits(u), cols[3] .. "|" .. cols[4], "VectorVectors " .. cols[2])
		end
		n += 1
	end
	t.eq(ctx, n, 50, "mathlib vectors")
end
