--!strict
-- Lists the game files the headless bot match reads (boot + N host frames), for tools/pk3/pack_runtime.py --also.
--   lune run tools/studio/list_botmatch_files.luau [frames=1500] [--packed] [--nolist] [--dump <file>]
-- Boots through tools/studio/botmatch/BotMatch.luau inside a Lune task with env.yield = task.wait (as on
-- Roblox) and env.measure on, so it also prints the longest stretches between two possible yield points.
-- Writes work/studio/botmatch_files.txt (every vpath that loaded, sorted, unique) unless --packed or --nolist.
-- (Fewer frames read fewer files: 300 frames read 755 files, 1500 frames 756. Pack from the 1500-frame list.)
-- --packed: read from game/generated/vfs instead of work/vfs-high. --dump <file>: write each bot's origin every
-- 50 frames to <file> (disk vs packed comparison).
local lfs = require("@lune/fs")
local process = require("@lune/process")
local task = require("@lune/task")
local BotMatch = require("./botmatch/BotMatch")

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
	prvm_cmds = require("../../engine/prvm_cmds"),
	model_alias = require("../../engine/model_alias"),
	["_port/qcrt"] = require("../../engine/_port/qcrt"),
	["_port/f32"] = require("../../engine/_port/f32"),
}

local frames = 1500
local packed = false
local nolist = false
local dumpfile: string? = nil
local i = 1
while i <= #process.args do
	local a = process.args[i]
	if a == "--packed" then
		packed = true
	elseif a == "--nolist" then
		nolist = true
	elseif a == "--dump" then
		i += 1
		dumpfile = process.args[i]
	elseif tonumber(a) then
		frames = tonumber(a) :: number
	end
	i += 1
end

local base: any
if packed then
	base = (require :: any)("../../game/generated/vfs")
else
	base = (require :: any)("../../tests/_lib/vfs_provider")("high")
end
assert(base, "no game data (work/vfs-high or game/generated/vfs)")
local progs = (require :: any)("../../game/generated/progs")

-- every vpath that loaded, with its size
local loaded: { [string]: number } = {}
local inner = base.load
local provider = {
	files = base.files,
	pack = base.pack,
	load = function(vpath: string): string?
		local d = inner(vpath)
		if d then
			loaded[vpath] = #d
		end
		return d
	end,
}

-- reproducible wall clock for QC (time(NULL)); Sys_DirtyTime stays real
E.prvm_cmds.time = function(): number
	return 1700000000
end

local dump: { string } = {}
local function dumpOrigins(f: number)
	local o = BotMatch.botOrigins()
	local keys = {}
	for e in o do
		table.insert(keys, e)
	end
	table.sort(keys)
	for _, e in keys do
		local v = o[e]
		table.insert(dump, string.format("frame %d bot %d %.6f %.6f %.6f", f, e, v[1], v[2], v[3]))
	end
end

local done, err = false, nil :: any
local t0 = os.clock()
local bootdt = 0
task.spawn(function()
	local ok, e = pcall(function()
		BotMatch.boot({
			engine = function(name: string): any
				return E[name]
			end,
			progs = progs,
			vfs = provider,
			yield = function()
				task.wait()
			end,
			clock = os.clock,
			map = "stormkeep",
			bots = 4,
			measure = true,
		})
		bootdt = os.clock() - t0
		print(string.format("boot %.1f s (%d yields), status %s", bootdt, BotMatch.yields, BotMatch.status))
		print("longest stretches between possible yield points, boot:")
		for _, g in BotMatch.gaps do
			print(string.format("  %6.3f s  %s  ->  %s", g.dt, g.from, g.to))
		end
		table.clear(BotMatch.gaps)
		local ticrate = E.host.cv.sys_ticrate.value
		for f = 1, frames do
			BotMatch.frame(ticrate)
			if dumpfile and f % 50 == 0 then
				dumpOrigins(f)
			end
			if f == math.min(300, frames) then
				print("longest stretches, frames 1-" .. f .. " (a frame start/end is a yield point):")
				for _, g in BotMatch.gaps do
					print(string.format("  %6.3f s  %s  ->  %s", g.dt, g.from, g.to))
				end
			end
		end
	end)
	done, err = true, if ok then nil else e
end)
while not done do
	task.wait()
end
E.console.sink = function(l: string)
	print(l)
end
if err then
	print("FAILED: " .. tostring(err))
	for _, l in BotMatch.lines do
		print("  console: " .. l)
	end
	process.exit(1)
end
print(string.format("%d frames done (%.1f s total)", BotMatch.frames, os.clock() - t0))
for k, v in BotMatch.qcwarnings do
	if k <= 5 then
		print("  QC warning: " .. v)
	end
end

if dumpfile then
	lfs.writeFile(dumpfile, table.concat(dump, "\n") .. "\n")
	print("wrote " .. #dump .. " origin lines to " .. dumpfile)
end

local names: { string } = {}
local total = 0
for n, sz in loaded do
	table.insert(names, n)
	total += sz
end
table.sort(names)
print(string.format("%d files loaded, %.2f MB", #names, total / 1e6))
local bysize = table.clone(names)
table.sort(bysize, function(a, b)
	return loaded[a] > loaded[b]
end)
for k = 1, math.min(15, #bysize) do
	print(string.format("  %10d  %s", loaded[bysize[k]], bysize[k]))
end
if not packed and not nolist then
	if not lfs.isDir("work/studio") then
		lfs.writeDir("work/studio")
	end
	lfs.writeFile("work/studio/botmatch_files.txt", table.concat(names, "\n") .. "\n")
	print("wrote work/studio/botmatch_files.txt")
end
