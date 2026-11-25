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
	-- glibc srand/rand
	local nr = 0
	for line in string.gmatch(t.read("tests/vectors/rand.tsv"), "[^\n]+") do
		local seed, list = string.match(line, "^(%d+)\t(.*)$")
		libc.srand(tonumber(seed) :: number)
		local got = {}
		for _ = 1, 40 do
			table.insert(got, tostring(libc.rand()))
		end
		t.eq(ctx, table.concat(got, ","), list, "rand after srand(" .. (seed :: string) .. ")")
		nr += 1
	end
	t.eq(ctx, nr, 9, "rand vectors")
	-- glibc strftime, C locale, gmtime
	local ns = 0
	for line in string.gmatch(t.read("tests/vectors/strftime.tsv"), "[^\n]+") do
		local ts, c, hex = string.match(line, "^(%d+)\t(.)\t(%x*)$")
		local want = string.gsub(hex :: string, "%x%x", function(h)
			return string.char(tonumber(h, 16) :: number)
		end)
		local tm = libc.gmtime(tonumber(ts) :: number)
		t.eq(
			ctx,
			libc.strftime("%" .. (c :: string), tm, 256),
			want,
			"strftime %" .. (c :: string) .. " at " .. (ts :: string)
		)
		ns += 1
	end
	t.eq(ctx, ns, 451, "strftime vectors")
	t.eq(ctx, libc.strftime("%Y-%m-%d", libc.gmtime(0), 5), "", "does not fit -> 0")
	-- one printf conversion (libc.format1) against glibc, intmax_t / double values
	local function hexfloat(v: string): number
		if v == "inf" then
			return math.huge
		elseif v == "-inf" then
			return -math.huge
		elseif v == "nan" then
			return math.abs(0 / 0) -- 0/0 is the x86 default NaN, which has the sign bit set
		elseif v == "-nan" then
			return -math.abs(0 / 0)
		end
		local sign, int, frac, ex = string.match(v, "^(%-?)0x(%x)%.?(%x*)p([+-]%d+)$")
		assert(int, "bad hex float " .. v)
		local m = tonumber(int :: string, 16) :: number
		for k = 1, #(frac :: string) do
			m += (tonumber(string.sub(frac :: string, k, k), 16) :: number) / 16 ^ k
		end
		local r = m * 2 ^ (tonumber(ex) :: number)
		return if sign == "-" then -r else r
	end
	local np, bad = 0, 0
	for line in string.gmatch(t.read("tests/vectors/printf.tsv"), "[^\n]+") do
		local fl, w, p, c, v, hex = string.match(line, "^([^\t]*)\t(%d+)\t(%-?%d+)\t(.)\t([^\t]+)\t(%x*)$")
		assert(fl, "bad printf vector " .. line)
		local want = string.gsub(hex :: string, "%x%x", function(h)
			return string.char(tonumber(h, 16) :: number)
		end)
		local val = if string.find("dxXou", c :: string, 1, true) then tonumber(v) :: number else hexfloat(v :: string)
		local got = libc.format1(fl :: string, tonumber(w) :: number, tonumber(p) :: number, c :: string, val)
		if got ~= want and bad < 10 then
			t.eq(
				ctx,
				got,
				want,
				string.format("%%%s*.%sj%s w=%s %s", fl :: string, p :: string, c :: string, w :: string, v :: string)
			)
		end
		if got ~= want then
			bad += 1
		end
		np += 1
	end
	t.eq(ctx, bad, 0, "printf vectors mismatching")
	t.eq(ctx, np, 19000, "printf vectors")
end
