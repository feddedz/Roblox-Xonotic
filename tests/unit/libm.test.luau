--!strict
-- engine/_port/libm.luau against the GitHub runner's glibc (tests/vectors/libm.tsv, tools/testgen/libm_vectors.sh):
-- every vector line bit for bit. Also counts how often the host's math.* differs from glibc on the same inputs
-- (printed, not failed: that is the reason the port exists, HANDOFF G-058). sqrt and fmod are exact IEEE
-- operations; they are checked against the host's math.sqrt / math.fmod, which the engine keeps using.
local t = require("../_lib/t")
local libm = require("../../engine/_port/libm")

return function(ctx: t.Ctx)
	local scratch = buffer.create(8)
	local function db(hex: string): number
		buffer.writeu32(scratch, 4, tonumber(string.sub(hex, 1, 8), 16) :: number)
		buffer.writeu32(scratch, 0, tonumber(string.sub(hex, 9, 16), 16) :: number)
		return buffer.readf64(scratch, 0)
	end
	local function dh(v: number): string
		buffer.writef64(scratch, 0, v)
		return string.format("%08x%08x", buffer.readu32(scratch, 4), buffer.readu32(scratch, 0))
	end
	local port: { [string]: (...number) -> number } = {
		sin = libm.sin,
		cos = libm.cos,
		tan = libm.tan,
		asin = libm.asin,
		acos = libm.acos,
		atan = libm.atan,
		atan2 = libm.atan2,
		pow = libm.pow,
		log = libm.log,
		sqrt = math.sqrt,
		fmod = libm.fmod,
	}
	local host: { [string]: (...number) -> number } = {
		sin = math.sin,
		cos = math.cos,
		tan = math.tan,
		asin = math.asin,
		acos = math.acos,
		atan = math.atan,
		atan2 = math.atan2,
		pow = math.pow,
		log = math.log,
		sqrt = math.sqrt,
		fmod = math.fmod,
	}
	local order = { "sin", "cos", "tan", "asin", "acos", "atan", "atan2", "pow", "log", "sqrt", "fmod" }
	local n: { [string]: number } = {}
	local bad: { [string]: number } = {}
	local hostbad: { [string]: number } = {}
	local version, fmaflag = "?", "?"
	for line in string.gmatch(t.read("tests/vectors/libm.tsv"), "[^\r\n]+") do
		local c = string.split(line, "\t")
		local fn = c[1]
		if fn == "V" then
			version = c[2]
		elseif fn == "CPU" then
			fmaflag = c[2]
		else
			local p, h = port[fn], host[fn]
			t.ok(ctx, h ~= nil, `known function in line: {line}`)
			if h then
				local want = c[#c]
				local a = db(c[2])
				local got, hgot
				if #c == 4 then
					local b = db(c[3])
					got = if p then dh(p(a, b)) else want
					hgot = dh(h(a, b))
				else
					got = if p then dh(p(a)) else want
					hgot = dh(h(a))
				end
				n[fn] = (n[fn] or 0) + 1
				if got ~= want then
					bad[fn] = (bad[fn] or 0) + 1
					t.eq(ctx, got, want, `libm.{fn}({table.concat(c, ", ", 2, #c - 1)})`)
				end
				if hgot ~= want then
					hostbad[fn] = (hostbad[fn] or 0) + 1
				end
			end
		end
	end
	t.eq(ctx, fmaflag, "1", "the vectors come from glibc's FMA build (CPU line)")
	local parts = {}
	for _, fn in order do
		t.ok(ctx, (n[fn] or 0) > 0, `vectors for {fn}`)
		t.ok(ctx, port[fn] ~= nil, `libm.{fn} is ported`)
		table.insert(parts, `{fn} {n[fn] or 0}/{bad[fn] or 0}/{hostbad[fn] or 0}`)
	end
	print(`    libm: glibc {version}; vectors / port differs / host math differs: {table.concat(parts, ", ")}`)
end
