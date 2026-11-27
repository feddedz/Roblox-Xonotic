--!strict
-- The Studio bot match under Lune: tools/studio/botmatch/BotMatch.luau boots `map stormkeep` with 4 bots from
-- the packed files (game/generated/vfs, built by `python tools/pk3/pack_runtime.py --also
-- work/studio/botmatch_files.txt`) instead of work/vfs-high, inside a Lune task with env.yield = task.wait as on
-- Roblox (so every yield point must be legal), then runs 600 host frames through BotMatch.frame. Checks: the
-- server is active, 4 bot clients are connected and move, no QC or engine error, boot yielded.
-- Skips without the compiled QuakeC or without a packed vfs that holds the map.
local t = require("../_lib/t")
local lfs = require("@lune/fs")
local task = require("@lune/task")
local BotMatch = require("../../tools/studio/botmatch/BotMatch")

local E: { [string]: any } = {
	console = require("../../engine/console"),
	fs = require("../../engine/fs"),
	host = require("../../engine/host"),
	host_cmd = require("../../engine/host_cmd"),
	cmd = require("../../engine/cmd"),
	cvar = require("../../engine/cvar"),
	sv_main = require("../../engine/sv_main"),
	server = require("../../engine/server"),
	svvm_cmds = require("../../engine/svvm_cmds"),
	prvm_edict = require("../../engine/prvm_edict"),
	model_alias = require("../../engine/model_alias"),
	["_port/qcrt"] = require("../../engine/_port/qcrt"),
	["_port/f32"] = require("../../engine/_port/f32"),
}

-- (the bots stand at their spawn points through the warmup countdown and first move at about frame 420,
-- so 300 frames cannot show movement)
local FRAMES = 600

return function(ctx: t.Ctx)
	if not (lfs.isFile("game/generated/vfs/init.luau") and lfs.isFile("game/generated/progs/init.luau")) then
		t.skip(ctx, "needs game/generated/vfs (pack_runtime.py --also) and game/generated/progs")
		return
	end
	local vfs = (require :: any)("../../game/generated/vfs")
	if not vfs.load("maps/stormkeep.bsp") then
		t.skip(
			ctx,
			"game/generated/vfs has no maps/stormkeep.bsp (pack_runtime.py --also work/studio/botmatch_files.txt)"
		)
		return
	end
	local progs = (require :: any)("../../game/generated/progs")

	-- bot travel, accumulated per frame like sv_botmatch.test.luau (a step >= 200 is a respawn, not travel)
	local dist: { [number]: number } = {}
	local last: { [number]: { number } } = {}
	BotMatch.onFrame = function(_sv: any, _prog: any)
		for e, o in BotMatch.botOrigins() do
			local l = last[e]
			if l then
				local dx, dy, dz = o[1] - l[1], o[2] - l[2], o[3] - l[3]
				local step = math.sqrt(dx * dx + dy * dy + dz * dz)
				if step < 200 then
					dist[e] = (dist[e] or 0) + step
				end
			end
			last[e] = o
		end
	end

	local done, err, framesrun = false, nil :: any, 0
	task.spawn(function()
		local ok, e = pcall(function()
			BotMatch.boot({
				engine = function(name: string): any
					return E[name]
				end,
				progs = progs,
				vfs = vfs,
				yield = function()
					task.wait()
				end,
				clock = os.clock,
				map = "stormkeep",
				bots = 4,
			})
			local ticrate = E.host.cv.sys_ticrate.value
			for _ = 1, FRAMES do
				BotMatch.frame(ticrate)
				framesrun += 1
			end
		end)
		done, err = true, if ok then nil else e
	end)
	while not done do
		task.wait()
	end
	BotMatch.onFrame = nil
	E.sv_main.vm_setup_opts = nil
	E.fs.SetProvider(nil)
	E.console.sink = function(l: string)
		print(l)
	end

	t.ok(ctx, err == nil, "boot + " .. FRAMES .. " frames without a QC or engine error: " .. tostring(err))
	t.eq(ctx, framesrun, FRAMES, "frames run")
	t.eq(ctx, BotMatch.frames, FRAMES, "BotMatch.frames")
	t.eq(ctx, BotMatch.status, "running", "BotMatch.status")
	t.ok(ctx, BotMatch.yields > 0, "boot yielded (env.yield called inside the engine code)")
	local sv = BotMatch.sv
	t.ok(ctx, sv ~= nil and sv.active, "server active")
	t.ok(ctx, BotMatch.prog ~= nil, "server prog set")
	local nbots, moved = 0, 0
	for e in BotMatch.botOrigins() do
		nbots += 1
		if (dist[e] or 0) > 100 then
			moved += 1
		end
		print(string.format("  bot %d travelled %.0f units", e, dist[e] or 0))
	end
	t.eq(ctx, nbots, 4, "bot clients connected")
	t.eq(ctx, moved, nbots, "every bot moves more than 100 units")
	print(string.format("  boot yielded %d times; %d QC warnings", BotMatch.yields, #BotMatch.qcwarnings))
	if err then
		for _, l in BotMatch.lines do
			print("  console: " .. l)
		end
	end
end
