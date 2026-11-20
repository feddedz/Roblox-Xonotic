--!strict
-- Verifies engine/_port/f32.luau bit-exactly against numpy float32 reference vectors
-- (tests/vectors/f32.txt, regenerate with tools/testgen/f32_vectors.py).
local t = require("../_lib/t")
local f32 = require("../../engine/_port/f32")

return function(ctx: t.Ctx)
	local b = buffer.create(8)
	local function f64(hex: string): number
		buffer.writeu32(b, 0, tonumber(string.sub(hex, 9, 16), 16) :: number)
		buffer.writeu32(b, 4, tonumber(string.sub(hex, 1, 8), 16) :: number)
		return buffer.readf64(b, 0)
	end
	local function u(hex: string): number
		return tonumber(hex, 16) :: number
	end
	local ops = {
		A = function(x: number, y: number)
			return f32.add(x, y)
		end,
		S = function(x: number, y: number)
			return f32.sub(x, y)
		end,
		M = function(x: number, y: number)
			return f32.mul(x, y)
		end,
		D = function(x: number, y: number)
			return f32.div(x, y)
		end,
	}
	-- Alternative rounding route (Luau vector components are float32); must agree too.
	local function viaVector(x: number): number
		return vector.create(x, 0, 0).x
	end
	for line in string.gmatch(t.read("tests/vectors/f32.txt"), "[^\n]+") do
		local parts = string.split(line, " ")
		local kind = parts[1]
		if kind == "C" then
			local x = f64(parts[2])
			t.eq(ctx, f32.tobits(f32.round(x)), u(parts[3]), "round " .. line)
			t.eq(ctx, f32.tobits(viaVector(x)), u(parts[3]), "vector round " .. line)
		elseif kind == "Q" then
			t.eq(ctx, f32.tobits(f32.sqrt(f32.frombits(u(parts[2])))), u(parts[3]), "sqrt " .. line)
		else
			local a, c = f32.frombits(u(parts[2])), f32.frombits(u(parts[3]))
			t.eq(ctx, f32.tobits(ops[kind](a, c)), u(parts[4]), "op " .. line)
		end
	end
end
