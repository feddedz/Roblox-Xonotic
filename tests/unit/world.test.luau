--!strict
-- engine/world.luau (the entity area grid) against the release's world.c compiled unchanged
-- (tests/vectors/world.tsv, tools/testgen/world_vectors.sh): the grid values of World_SetSize bit for bit, and
-- the entity list of every World_EntitiesInBox call, in the same order.
local t = require("../_lib/t")
local cvar = require("../../engine/cvar")
local f32 = require("../../engine/_port/f32")
local world = require("../../engine/world")

return function(ctx: t.Ctx)
	local function fb(hex: string): number
		return f32.frombits(tonumber(hex, 16) :: number)
	end
	local function fh(v: number): string
		return string.format("%08x", f32.tobits(v))
	end
	local function v3(c: { string }, i: number): { number }
		return { fb(c[i]), fb(c[i + 1]), fb(c[i + 2]) }
	end
	local function num(s: string): number
		return tonumber(s) :: number
	end

	cvar.reset()
	local NED = 320
	local prog: any = { max_edicts = NED, num_edicts = NED, ed_free = {} }
	for i = 0, NED - 1 do
		prog.ed_free[i] = false
	end
	local w = world.new()
	local lineno = 0
	for line in string.gmatch(t.read("tests/vectors/world.tsv"), "[^\r\n]+") do
		lineno += 1
		local c = string.split(line, "\t")
		local kind = c[1]
		if kind == "W" then
			-- memset(privs, 0, ...) in the generator: every edict starts unlinked and not free
			prog.ed_area = nil
			for i = 0, NED - 1 do
				prog.ed_free[i] = false
			end
			world.World_SetSize(w, "testmap", v3(c, 2), v3(c, 5), prog)
		elseif kind == "G" then
			local parts = {}
			for _, v in { w.areagrid_mins, w.areagrid_maxs, w.areagrid_size, w.areagrid_bias, w.areagrid_scale } do
				table.insert(parts, fh(v[1]))
				table.insert(parts, fh(v[2]))
				table.insert(parts, fh(v[3]))
			end
			t.eq(ctx, table.concat(parts, "\t"), table.concat(c, "\t", 2), `line {lineno}: World_SetSize grid`)
		elseif kind == "L" then
			world.World_LinkEdict(w, num(c[2]), v3(c, 3), v3(c, 6))
		elseif kind == "F" then
			prog.ed_free[num(c[2])] = c[3] ~= "0"
		elseif kind == "U" then
			world.World_UnlinkEdict(prog, num(c[2]))
		elseif kind == "UA" then
			world.World_UnlinkAll(w)
		elseif kind == "Q" then
			local maxlist = num(c[8])
			local list: { number } = {}
			local n = world.World_EntitiesInBox(w, v3(c, 2), v3(c, 5), maxlist, list)
			local parts = { tostring(n) }
			for i = 1, math.min(n, maxlist) do
				table.insert(parts, tostring(list[i]))
			end
			t.eq(ctx, table.concat(parts, "\t"), table.concat(c, "\t", 9), `line {lineno}: World_EntitiesInBox`)
		elseif kind == "ST" then
			t.eq(
				ctx,
				`{w.areagrid_stats_calls}\t{w.areagrid_stats_nodechecks}\t{w.areagrid_stats_entitychecks}\t{w.areagrid_marknumber}`,
				table.concat(c, "\t", 2),
				`line {lineno}: area grid statistics`
			)
		elseif kind == "END" then
			t.ok(ctx, true, "reached the end of the vector file")
		end
	end
	cvar.reset()
end
