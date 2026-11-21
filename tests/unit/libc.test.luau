--!strict
-- engine/_port/libc.luau against real glibc vectors (tests/vectors/libc.tsv, tools/testgen/libc_vectors.sh).
local t = require("../_lib/t")
local libc = require("../../engine/_port/libc")
local f32 = require("../../engine/_port/f32")
local cvar = require("../../engine/cvar")

return function(ctx: t.Ctx)
	local b = buffer.create(8)
	local function bits64(x: number): string
		buffer.writef64(b, 0, x)
		return string.format("%08x%08x", buffer.readu32(b, 4), buffer.readu32(b, 0))
	end
	local function bits32(x: number): string
		buffer.writef32(b, 0, x)
		return string.format("%08x", buffer.readu32(b, 0))
	end
	local n = 0
	for line in string.gmatch(t.read("tests/vectors/libc.tsv"), "[^\n]+") do
		local hex, d, f, fi, ai, l, lend, val =
			string.match(line, "^(%x*)\t(%x+)\t(%x+)\t(%-?%d+)\t(%-?%d+)\t(%-?%d+)\t(%d+)\t(.*)$")
		assert(hex, "bad vector line " .. line)
		local s = string.gsub(hex :: string, "%x%x", function(h)
			return string.char(tonumber(h, 16) :: number)
		end)
		local q = string.format("%q", s)
		local v = libc.atof(s)
		local fv = f32.round(v)
		-- NaN payload/sign bits differ between libcs and Luau; compare NaN-ness only
		if v ~= v then
			t.ok(
				ctx,
				string.sub(d :: string, 1, 3) == "7ff" or string.sub(d :: string, 1, 3) == "fff",
				"atof nan " .. q
			)
		else
			t.eq(ctx, bits64(v), d, "atof " .. q)
			t.eq(ctx, bits32(fv), f, "(float)atof " .. q)
		end
		t.eq(ctx, libc.toint(fv), tonumber(fi), "(int)(float) " .. q)
		t.eq(ctx, libc.atoi(s), tonumber(ai), "atoi " .. q)
		local lv, le = libc.strtol10(s)
		t.eq(ctx, lv, tonumber(l), "strtol " .. q)
		t.eq(ctx, le - 1, tonumber(lend), "strtol end " .. q)
		if v == v then
			t.eq(ctx, cvar.formatvalue(fv), val, "Cvar_SetValue format " .. q)
		end
		n += 1
	end
	t.ok(ctx, n > 80, "vectors read")
	t.eq(ctx, libc.strcmp("a\200", "a\127"), 1, "strcmp unsigned bytes")
	t.eq(ctx, libc.strcasecmp("ABC", "abd"), -1, "strcasecmp")
end
