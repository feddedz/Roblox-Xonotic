--!strict
-- Debug runner: a headless Xonotic bot match (the boot of tests/integration/sv_botmatch.test.luau) that runs
-- the same under Lune and as a Roblox ModuleScript. Nothing is required by path here: the caller passes the
-- engine modules, the compiled progs and the file provider in `env`.
--
--   env = { engine = function(name) -> module   -- e.g. env.engine("host"), env.engine("_port/qcrt")
--           progs = <game/generated/progs>, vfs = <engine/fs.luau Provider>,
--           yield = function() end,             -- Roblox: task.wait
--           clock = os.clock, map = "stormkeep", bots = 4,
--           seed = 12345?, measure = false? }   -- measure: record the gaps between possible yield points
--
-- Boot is time-sliced: the provider's load, the console sink, the progs' lazy chunk loader and the builtin
-- stub hook call env.yield() once more than YIELD_EVERY seconds of env.clock() have passed since the last
-- yield (only during boot, and only where coroutine.isyieldable()). Frames never yield.
local BotMatch = {}

BotMatch.status = "idle"
BotMatch.sv = nil :: any
BotMatch.prog = nil :: any
BotMatch.frames = 0
BotMatch.onStatus = nil :: ((string) -> ())?
BotMatch.onFrame = nil :: ((sv: any, prog: any) -> ())?
-- console lines (the last MAXLINES), first QC warnings, builtins hit as stubs ("#n name" -> count)
BotMatch.lines = {} :: { string }
BotMatch.qcwarnings = {} :: { string }
BotMatch.stubs = {} :: { [string]: number }
BotMatch.yields = 0
-- env.measure: the longest stretches between two possible yield points, longest first:
-- { dt = seconds, from = "what ran at the start", to = "what ran at the end", phase = "boot" | "frames" }
BotMatch.gaps = {} :: { { dt: number, from: string, to: string, phase: string } }

local YIELD_EVERY = 0.5
local MAXLINES = 500
local MAXGAPS = 12

local clock: () -> number = os.clock
local yieldfn: () -> () = function() end
local measure = false
local booting = false
local phase = "boot"
local lastyield = 0
local lastpoint = 0
local lastkind, lastarg = "start", nil :: any
local mods: any = {}

local function setStatus(s: string)
	BotMatch.status = s
	local cb = BotMatch.onStatus
	if cb then
		cb(s)
	end
end

local function label(kind: string, arg: any): string
	if arg == nil then
		return kind
	end
	return kind .. " " .. tostring(arg)
end

local function record(dt: number, kind: string, arg: any)
	local gaps = BotMatch.gaps
	if #gaps >= MAXGAPS and dt <= gaps[#gaps].dt then
		return
	end
	table.insert(gaps, { dt = dt, from = label(lastkind, lastarg), to = label(kind, arg), phase = phase })
	table.sort(gaps, function(a, b)
		return a.dt > b.dt
	end)
	if #gaps > MAXGAPS then
		table.remove(gaps)
	end
end

-- a possible yield point: `kind`/`arg` say what is running here (kept unformatted until a gap is recorded)
local function tick(kind: string, arg: any)
	local now = clock()
	if measure then
		local dt = now - lastpoint
		if dt > 0.05 then
			record(dt, kind, arg)
		end
		lastpoint, lastkind, lastarg = now, kind, arg
	end
	if booting and now - lastyield > YIELD_EVERY and coroutine.isyieldable() then
		yieldfn()
		BotMatch.yields += 1
		lastyield = clock()
		lastpoint = lastyield -- (the time spent yielded is not a stretch)
	end
end

local function resetPoint(kind: string, arg: any)
	lastpoint, lastkind, lastarg = clock(), kind, arg
end

local function wrapProvider(p: any): any
	local load = p.load
	return {
		files = p.files,
		pack = p.pack,
		load = function(vpath: string): string?
			tick("load", vpath)
			local data = load(vpath)
			tick("loaded", vpath)
			return data
		end,
	}
end

function BotMatch.boot(e: any)
	clock = e.clock or os.clock
	yieldfn = e.yield or function() end
	measure = e.measure == true
	local engine = e.engine
	mods = {
		console = engine("console"),
		fs = engine("fs"),
		host = engine("host"),
		host_cmd = engine("host_cmd"),
		cmd = engine("cmd"),
		cvar = engine("cvar"),
		sv_main = engine("sv_main"),
		server = engine("server"),
		svvm_cmds = engine("svvm_cmds"),
		prvm_edict = engine("prvm_edict"),
		qcrt = engine("_port/qcrt"),
		f32 = engine("_port/f32"),
	}
	local m = mods
	-- model loading: Mod_Alias_CalculateBoundingBox animates every pose of a skeletal model (DPM/IQM), up to
	-- ~12 s for models/monsters/spider.dpm under Lune with no file load in between. The per-pose work goes
	-- through model_alias.Mod_Skeletal_AnimateVertices_Generic, which is looked up in the module table at each
	-- call (model_alias.luau L800), so wrapping it adds a yield point per pose without touching the engine.
	local ma = engine("model_alias")
	if not ma.__botmatch_wrapped then
		ma.__botmatch_wrapped = true
		local generic = ma.Mod_Skeletal_AnimateVertices_Generic
		ma.Mod_Skeletal_AnimateVertices_Generic = function(...: any)
			tick("Mod_Skeletal_AnimateVertices_Generic")
			generic(...)
		end
	end
	BotMatch.frames = 0
	BotMatch.sv, BotMatch.prog = nil, nil
	table.clear(BotMatch.lines)
	table.clear(BotMatch.qcwarnings)
	table.clear(BotMatch.stubs)
	table.clear(BotMatch.gaps)
	BotMatch.yields = 0
	booting, phase = true, "boot"
	lastyield = clock()
	resetPoint("boot start")

	local lines = BotMatch.lines
	m.console.sink = function(l: string)
		tick("console", l)
		table.insert(lines, l)
		if #lines > MAXLINES then
			table.remove(lines, 1)
		end
	end

	setStatus("init engine")
	m.fs.SetProvider(wrapProvider(e.vfs))
	m.host.Host_Init_Dedicated({ maxclients = 8 })
	tick("Host_Init_Dedicated done")
	-- a fresh server (as the test does: another run in this process may have left one)
	m.server.Clear()
	m.host_cmd.sv_active = false
	m.svvm_cmds.VM_CustomStats_Clear()
	local svs = m.host_cmd.svs :: any
	svs.clients = {}

	local progs = e.progs
	local stubs, qcwarnings = BotMatch.stubs, BotMatch.qcwarnings
	m.sv_main.vm_setup_opts = {
		onStub = function(n: number, cname: string, _p: any)
			local k = string.format("#%d %s", n, cname)
			stubs[k] = (stubs[k] or 0) + 1
			tick("stub", k)
		end,
		install = function(prog: any)
			prog.warning = function(msg: string)
				if #qcwarnings < 20 then
					table.insert(qcwarnings, msg)
				end
			end
			progs.install(prog, { qcrt = m.qcrt, f32 = m.f32 })
			-- the lazy chunk loader: a chunk require is a long, yield-free step on its own
			local inner = prog.aot_load
			prog.aot_load = function(fnum: number): any
				tick("aot_load", fnum)
				local fn = inner(fnum)
				tick("aot_loaded", fnum)
				return fn
			end
		end,
	}

	local map = e.map or "stormkeep"
	setStatus("map " .. map)
	m.cmd.Cbuf_AddText(
		string.format(
			"sv_random_seed %d\nbot_join_empty 1\nbot_number %d\nskill 5\nminplayers 0\ng_dm 1\ntimelimit_override 0\nfraglimit_override 0\nmap %s\n",
			e.seed or 12345,
			e.bots or 4,
			map
		)
	)
	m.cmd.Cbuf_Execute()
	tick("map done")
	booting, phase = false, "frames"
	local sv = m.server.sv
	local prog = m.cvar.prvm_prog_list[0]
	if not prog or not sv.active then
		setStatus("map did not start")
		error("BotMatch: map " .. map .. " did not start (server not active)")
	end
	BotMatch.sv, BotMatch.prog = sv, prog
	setStatus("running")
end

function BotMatch.frame(elapsed: number)
	local m = mods
	resetPoint("frame start", BotMatch.frames + 1)
	m.host.Host_Main_Frame(elapsed)
	BotMatch.frames += 1
	tick("frame end", BotMatch.frames)
	local sv = m.server.sv
	BotMatch.sv = sv
	local cb = BotMatch.onFrame
	if cb then
		cb(sv, BotMatch.prog)
	end
end

-- origins of the active bot clients: { [edict] = { x, y, z } } (debug views, comparisons)
function BotMatch.botOrigins(): { [number]: { number } }
	local prog = BotMatch.prog
	local out: { [number]: { number } } = {}
	if not prog then
		return out
	end
	local svs = mods.host_cmd.svs :: any
	local o = mods.prvm_edict.FieldOfs(prog, "origin")
	for i = 0, svs.maxclients - 1 do
		local c = svs.clients[i]
		if c and c.active and not c.netconnection then
			local a = ((i + 1) * prog.entityfields + o) * 4
			local b = prog.edictsfields
			out[i + 1] = { buffer.readf32(b, a), buffer.readf32(b, a + 4), buffer.readf32(b, a + 8) }
		end
	end
	return out
end

return BotMatch
