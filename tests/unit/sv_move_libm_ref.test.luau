--!strict
-- engine/_port/libm.luau's cos / sin against glibc's cos / sin (tests/vectors/svmove.tsv CS lines, written by
-- tools/testgen/svmove_vectors.c on the Linux runner) for the radian yaws VM_SV_walkmove and SV_StepDirection
-- compute (degrees * M_PI * 2 / 360 rounded to float). Every result must have glibc's bits (HANDOFF G-058,
-- task PORT-LIBM); the host's math.cos / math.sin differences on the same yaws are printed for comparison.
local t = require("../_lib/t")
local f32 = require("../../engine/_port/f32")
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
	local n, badcos, badsin, hostcos, hostsin = 0, 0, 0, 0, 0
	for line in string.gmatch(t.read("tests/vectors/svmove.tsv"), "[^\r\n]+") do
		if string.sub(line, 1, 3) == "CS\t" then
			local c = string.split(line, "\t")
			local yaw = f32.frombits(tonumber(c[2], 16) :: number)
			local gc, gs = dh(libm.cos(yaw)), dh(libm.sin(yaw))
			n += 1
			if gc ~= c[3] then
				badcos += 1
				t.eq(ctx, gc, c[3], `libm.cos(yaw {c[2]})`)
			end
			if gs ~= c[4] then
				badsin += 1
				t.eq(ctx, gs, c[4], `libm.sin(yaw {c[2]})`)
			end
			if math.cos(yaw) ~= db(c[3]) then
				hostcos += 1
			end
			if math.sin(yaw) ~= db(c[4]) then
				hostsin += 1
			end
		end
	end
	t.ok(ctx, n > 0, "the vector file has CS lines")
	t.eq(ctx, badcos + badsin, 0, "libm.cos / libm.sin results that differ from glibc")
	print(
		`    sv_move_libm_ref: libm.cos / libm.sin match glibc for all {n} yaws (host math.cos differs for {hostcos}, math.sin for {hostsin})`
	)
end
