--!strict
-- The host's math.cos / math.sin against glibc's cos / sin (tests/vectors/svmove.tsv CS lines, written by
-- tools/testgen/svmove_vectors.c on the Linux runner) for the radian yaws VM_SV_walkmove and SV_StepDirection
-- compute (degrees * M_PI * 2 / 360 rounded to float). engine/sv_move.luau and engine/svvm_cmds.luau call
-- math.cos / math.sin there, so a host libm that rounds differently from glibc can change a move by one float
-- step whenever cos(yaw) * dist lands next to a float rounding boundary. This test fails on such a host and
-- says how often the results differ and whether they change the float move for the distances monsters use.
local t = require("../_lib/t")
local f32 = require("../../engine/_port/f32")

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
	local R = f32.round
	-- the walk / step distances of the vectors and of Xonotic's monsters
	local dists = { 0.5, 2, 4, 8, 16, 20, 20.5, 24, 31, 32, 40, 64 }
	local n, badcos, badsin, moves = 0, 0, 0, 0
	local examples: { string } = {}
	for line in string.gmatch(t.read("tests/vectors/svmove.tsv"), "[^\r\n]+") do
		if string.sub(line, 1, 3) == "CS\t" then
			local c = string.split(line, "\t")
			local yaw = f32.frombits(tonumber(c[2], 16) :: number)
			local wc, ws = db(c[3]), db(c[4])
			local gc, gs = math.cos(yaw), math.sin(yaw)
			n += 1
			if gc ~= wc then
				badcos += 1
			end
			if gs ~= ws then
				badsin += 1
			end
			if gc ~= wc or gs ~= ws then
				for _, d in dists do
					if R(gc * d) ~= R(wc * d) or R(gs * d) ~= R(ws * d) then
						moves += 1
					end
				end
				if #examples < 4 then
					table.insert(examples, `yaw {c[2]}: cos {dh(gc)} (glibc {c[3]}), sin {dh(gs)} (glibc {c[4]})`)
				end
			end
		end
	end
	t.ok(ctx, n > 0, "the vector file has CS lines")
	-- What must hold on every host: no float move changes. The last-bit differences of the doubles themselves
	-- are a known open point (HANDOFF G-058, task PORT-LIBM: a glibc-exact sin / cos in engine/_port); they are
	-- printed, not failed, so the suite stays green on the owner's Windows PC.
	t.eq(
		ctx,
		moves,
		0,
		`float moves (R(cos * dist), dist in {#dists} values) that differ from glibc; e.g. {table.concat(examples, "; ")}`
	)
	if badcos + badsin > 0 then
		print(
			`    sv_move_libm_ref: host math.cos differs from glibc by one ulp for {badcos}, math.sin for {badsin} of {n} yaws (no float move changes); see G-058`
		)
	end
end
