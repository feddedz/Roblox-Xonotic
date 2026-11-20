--!strict
--!native
--[[
	Port support (not a DarkPlaces source file): exact IEEE-754 single-precision rounding.

	DarkPlaces and QuakeC compute in C `float` (32-bit). Luau numbers are 64-bit doubles.
	Rule (HANDOFF §DECISIONS D-004): wherever the C code stores or computes a float,
	the Luau port rounds the result to float32 exactly as C does:

	  * one rounding per C arithmetic operation:  c = a*b + d  ->  f32.round(f32.round(a*b) + d)
	    (computing a single +,-,*,/ or sqrt in double and rounding once to float gives the
	    correctly rounded float result; proven for binary64 -> binary32, see docs/subsystems/float32.md)
	  * every store into a float variable/field/global rounds (buffer f32 slots do this implicitly)
	  * C `double` values (e.g. realtime, sv.time) are NOT rounded.

	Verified bit-exact against numpy float32 by tests/unit/f32.test.luau (12k vectors).
]]

local f32 = {}

local scratch = buffer.create(4)

-- Round a double to the nearest float32 (round-half-even), like a C (float) cast on x86-64 SSE.
function f32.round(x: number): number
	buffer.writef32(scratch, 0, x)
	return buffer.readf32(scratch, 0)
end
local round = f32.round

-- Single float operations, each correctly rounded like C `float` arithmetic.
function f32.add(a: number, b: number): number
	return round(a + b)
end
function f32.sub(a: number, b: number): number
	return round(a - b)
end
function f32.mul(a: number, b: number): number
	return round(a * b)
end
function f32.div(a: number, b: number): number
	return round(a / b)
end
function f32.sqrt(a: number): number -- sqrtf()
	return round(math.sqrt(a))
end

-- Bit pattern helpers (tests, network messages, file formats).
function f32.tobits(x: number): number
	buffer.writef32(scratch, 0, x)
	return buffer.readu32(scratch, 0)
end
function f32.frombits(u: number): number
	buffer.writeu32(scratch, 0, u)
	return buffer.readf32(scratch, 0)
end

return f32
