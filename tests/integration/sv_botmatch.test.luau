--!strict
-- M4-CLIENT: a bot match on stormkeep. The `map` command starts the map with the real config chain and the
-- compiled QuakeC; the QC spawns bots through spawnclient (DP_SV_BOTCLIENT) and runs their player physics
-- (SV_PlayerPhysics) from SV_ClientThink. The server runs through host.Host_Main_Frame with a fixed timestep
-- (sys_ticrate), like the Roblox server's Heartbeat will. Checks: bot clients connect (svs.clients[i].active,
-- classname "player", clienttype 2 = bot), they move and stay inside the world and out of solid, entities are
-- spawned and removed, no QC or engine error. Prints frame times, edict counts, per-bot distance / frags /
-- damage, and the builtins still hit as stubs (the NOT YET PORTED lines of the engine are printed to stdout by
-- the engine itself the first time they are reached: run this test alone to see them all).
-- Needs game data (work/vfs-high) and the compiled QuakeC (game/generated/progs); skips without them.
local t = require("../_lib/t")
local lfs = require("@lune/fs")
local console = require("../../engine/console")
local fs = require("../../engine/fs")
local host = require("../../engine/host")
local host_cmd = require("../../engine/host_cmd")
local cmd = require("../../engine/cmd")
local cvar = require("../../engine/cvar")
local sv_main = require("../../engine/sv_main")
local sv_phys = require("../../engine/sv_phys")
local server = require("../../engine/server")
local prvm_edict = require("../../engine/prvm_edict")
local qcrt = require("../../engine/_port/qcrt")
local f32 = require("../../engine/_port/f32")
local provider = require("../_lib/vfs_provider")

local MOVE_NOMONSTERS = 1
local SUPERCONTENTS_SOLID = 0x1

local function sorted(counts: { [string]: number }): string
	local names = {}
	for k, v in counts do
		table.insert(names, { k = k, v = v })
	end
	table.sort(names, function(a, b)
		if a.v ~= b.v then
			return a.v > b.v
		end
		return a.k < b.k
	end)
	local out = {}
	for _, e in names do
		table.insert(out, string.format("%s x%d", e.k, e.v))
	end
	return table.concat(out, ", ")
end

return function(ctx: t.Ctx)
	local dat, gen = "work/vfs-high/progs.dat", "game/generated/progs/init.luau"
	local p = provider("high")
	if not (p and lfs.isFile(dat) and lfs.isFile(gen)) then
		t.skip(ctx, "needs work/vfs-high and the compiled QuakeC (game/generated/progs)")
		return
	end
	local lines: { string } = {}
	console.sink = function(l: string)
		table.insert(lines, l)
	end
	fs.SetProvider(p)
	host.Host_Init_Dedicated({ maxclients = 8 })
	-- a fresh server (another test in this Lune process may have left one running)
	server.Clear()
	host_cmd.sv_active = false
	require("../../engine/svvm_cmds").VM_CustomStats_Clear()
	local svs = host_cmd.svs :: any
	svs.clients = {}

	local stubs: { [string]: number } = {}
	local generated = (require :: any)("../../game/generated/progs")
	local qcwarnings: { string } = {}
	sv_main.vm_setup_opts = {
		onStub = function(n: number, cname: string, _p: any)
			local k = string.format("#%d %s", n, cname)
			stubs[k] = (stubs[k] or 0) + 1
		end,
		install = function(prog: any)
			prog.warning = function(m: string)
				if #qcwarnings < 20 then
					table.insert(qcwarnings, m)
				end
			end
			generated.install(prog, { qcrt = qcrt, f32 = f32 })
		end,
	}

	-- the cvars of a bot match (as serverbench.cfg of the release sets them, with 4 bots and no time limit;
	-- bot_join_empty: bots play without a human, sv_random_seed: reproducible)
	local ok, err = pcall(function()
		cmd.Cbuf_AddText(
			"sv_random_seed 12345\nbot_join_empty 1\nbot_number 4\nskill 5\nminplayers 0\ng_dm 1\ntimelimit_override 0\nfraglimit_override 0\nmap stormkeep\n"
		)
		cmd.Cbuf_Execute()
	end)
	t.ok(ctx, ok, "map stormkeep starts without an error: " .. tostring(err))
	local sv = server.sv
	local prog: any = cvar.prvm_prog_list[0]
	if not ok or not prog or not sv.active then
		print("  stopped while spawning: " .. tostring(err))
		print("  stubs while spawning: " .. sorted(stubs))
		sv_main.vm_setup_opts = nil
		fs.SetProvider(nil)
		return
	end
	local spawnstubs = table.clone(stubs)
	print("  stubs while spawning: " .. sorted(spawnstubs))

	local function FO(f: string): number
		return prvm_edict.FieldOfs(prog, f)
	end
	local o_origin, o_health, o_frags, o_classname, o_netname, o_deadflag =
		FO("origin"), FO("health"), FO("frags"), FO("classname"), FO("netname"), FO("deadflag")
	local o_mins, o_maxs = FO("mins"), FO("maxs")
	local function F(e: number, o: number): number
		return buffer.readf32(prog.edictsfields, (e * prog.entityfields + o) * 4)
	end
	local function V(e: number, o: number): { number }
		local a = (e * prog.entityfields + o) * 4
		local b = prog.edictsfields
		return { buffer.readf32(b, a), buffer.readf32(b, a + 4), buffer.readf32(b, a + 8) }
	end
	local function S(e: number, o: number): string
		return prvm_edict.PRVM_GetString(prog, buffer.readi32(prog.edictsfields, (e * prog.entityfields + o) * 4))
	end
	-- clienttype(e) through the builtin (#455)
	local function clienttype(e: number): number
		local saveargc = prog.argc
		local save = buffer.readi32(prog.globals, 4 * 4)
		local saver = buffer.readi32(prog.globals, 1 * 4)
		buffer.writei32(prog.globals, 4 * 4, e)
		prog.argc = 1
		prog.builtins[455](prog)
		local r = buffer.readf32(prog.globals, 1 * 4)
		buffer.writei32(prog.globals, 4 * 4, save)
		buffer.writei32(prog.globals, 1 * 4, saver)
		prog.argc = saveargc
		return r
	end

	local wmins, wmaxs = sv.worldmodel.normalmins, sv.worldmodel.normalmaxs
	local ticrate = host.cv.sys_ticrate.value
	-- BOTMATCH_FRAMES overrides the frame count for quick local runs (the checks expect 3000)
	local frames = tonumber(require("@lune/process").env.BOTMATCH_FRAMES) or 3000
	local times: { number } = {}
	local liveover: { string } = {}
	local spawned, removed = 0, 0
	local spawnedclasses: { [string]: number } = {}
	local prevfree: { [number]: boolean } = {}
	for e = 0, prog.max_edicts - 1 do
		prevfree[e] = prog.ed_free[e] == true or e >= prog.num_edicts
	end
	local bots: { [number]: any } = {} -- edict -> stats
	local outside, insolid, startsolid, checked = 0, 0, 0, 0
	local firstbad: string? = nil
	local frameerr: any = nil
	local framesrun = 0
	local physframes0 = sv.time
	table.clear(stubs)

	local mask = SUPERCONTENTS_SOLID
	for f = 1, frames do
		local t0 = os.clock()
		local okf, e1 = pcall(host.Host_Main_Frame, ticrate)
		local dt = os.clock() - t0
		times[f] = dt
		if not okf then
			frameerr = e1
			break
		end
		framesrun = f
		-- edicts spawned / removed this frame
		local n = prog.num_edicts
		for e = 1, prog.max_edicts - 1 do
			local free = prog.ed_free[e] == true or e >= n
			if prevfree[e] ~= free then
				if free then
					removed += 1
				else
					spawned += 1
					local c = S(e, o_classname)
					spawnedclasses[c] = (spawnedclasses[c] or 0) + 1
				end
				prevfree[e] = free
			end
		end
		-- bot clients
		for i = 0, svs.maxclients - 1 do
			local c = svs.clients[i]
			local e = i + 1
			if c and c.active and not c.netconnection then
				local b = bots[e]
				local o = V(e, o_origin)
				if not b then
					b = { first = f, dist = 0, last = o, start = o, name = "", maxdamage = 0, deaths = 0, frags = 0 }
					b.lasthealth = F(e, o_health)
					bots[e] = b
				end
				local dx, dy, dz = o[1] - b.last[1], o[2] - b.last[2], o[3] - b.last[3]
				local step = math.sqrt(dx * dx + dy * dy + dz * dz)
				if step < 200 then -- (a respawn / teleport is not travel)
					b.dist += step
				end
				b.last = o
				b.name = c.name.str
				b.frags = F(e, o_frags)
				local h = F(e, o_health)
				if h < b.lasthealth and F(e, o_deadflag) == 0 then
					b.maxdamage = math.max(b.maxdamage, b.lasthealth - h)
					b.damaged = (b.damaged or 0) + 1
				end
				if h <= 0 and b.lasthealth > 0 then
					b.deaths += 1
				end
				b.lasthealth = h
				-- inside the world box and out of solid (alive bots, every 10th frame)
				if f % 10 == 0 and h > 0 and S(e, o_classname) == "player" then
					checked += 1
					for k = 1, 3 do
						if o[k] < wmins[k] or o[k] > wmaxs[k] then
							outside += 1
							firstbad = firstbad
								or string.format("frame %d bot %d outside: %.1f %.1f %.1f", f, e, o[1], o[2], o[3])
							break
						end
					end
					if bit32.band(sv_phys.SV_PointSuperContents(o), SUPERCONTENTS_SOLID) ~= 0 then
						insolid += 1
						firstbad = firstbad
							or string.format("frame %d bot %d origin in solid: %.1f %.1f %.1f", f, e, o[1], o[2], o[3])
					end
					local tr = sv_phys.SV_TraceBox(o, V(e, o_mins), V(e, o_maxs), o, MOVE_NOMONSTERS, e, mask, 0, 0, 0)
					if tr.startsolid then
						startsolid += 1
						firstbad = firstbad
							or string.format("frame %d bot %d box startsolid: %.1f %.1f %.1f", f, e, o[1], o[2], o[3])
					end
				end
			end
		end
		if f % 300 == 0 then
			local live = 0
			for e = 0, prog.num_edicts - 1 do
				if not prog.ed_free[e] then
					live += 1
				end
			end
			table.insert(liveover, string.format("%d:%d", f, live))
			local nb = 0
			for _ in bots do
				nb += 1
			end
			print(
				string.format(
					"  ... frame %d, sv.time %.2f, %d live edicts, %d bots, last frame %.1f ms",
					f,
					sv.time,
					live,
					nb,
					dt * 1000
				)
			)
		end
	end

	-- results
	t.ok(ctx, frameerr == nil, frames .. " host frames run without a QC or engine error: " .. tostring(frameerr))
	t.eq(ctx, framesrun, frames, "frames run")
	local total, worst = 0, 0
	for _, dt in times do
		total += dt
		if dt > worst then
			worst = dt
		end
	end
	local sorteddt = table.clone(times)
	table.sort(sorteddt)
	print(
		string.format(
			"  %d host frames (sys_ticrate %.7f, sv.time %.3f -> %.3f): wall %.2f s, %.3f ms/frame average, median %.3f ms, worst %.3f ms",
			framesrun,
			ticrate,
			physframes0,
			sv.time,
			total,
			total / math.max(#times, 1) * 1000,
			(sorteddt[math.max(1, #sorteddt // 2)] or 0) * 1000,
			worst * 1000
		)
	)
	if frameerr then
		print("  stopped at frame " .. (framesrun + 1) .. ": " .. tostring(frameerr))
	end
	print("  live edicts (frame:count): " .. table.concat(liveover, " "))
	print(
		string.format("  edicts spawned %d, removed %d; spawned classes: %s", spawned, removed, sorted(spawnedclasses))
	)

	local nbots, nplayers, nbottype, moved = 0, 0, 0, 0
	for e, b in bots do
		nbots += 1
		local cn = S(e, o_classname)
		if cn == "player" then
			nplayers += 1
		end
		local ct = clienttype(e)
		if ct == 2 then
			nbottype += 1
		end
		if b.dist > 100 then
			moved += 1
		end
		print(
			string.format(
				"  bot %d %q (classname %s, clienttype %d, netname %q): joined frame %d, travelled %.0f units, frags %d, deaths %d, damaged %d times (max %.0f), health %.0f",
				e,
				b.name,
				cn,
				ct,
				S(e, o_netname),
				b.first,
				b.dist,
				b.frags,
				b.deaths,
				b.damaged or 0,
				b.maxdamage,
				F(e, o_health)
			)
		)
	end
	t.ok(ctx, nbots > 0, "bot clients are spawned (svs.clients[i].active without a netconnection)")
	t.eq(ctx, nplayers, nbots, "every bot client edict is a player")
	t.eq(ctx, nbottype, nbots, "clienttype of every bot is 2 (bot)")
	t.ok(ctx, moved > 0, "bots move")
	t.eq(ctx, moved, nbots, "every bot moves more than 100 units")
	print(
		string.format(
			"  position checks of alive bots: %d; outside the world box %d, origin in solid %d, box startsolid %d%s",
			checked,
			outside,
			insolid,
			startsolid,
			if firstbad then " (first: " .. firstbad .. ")" else ""
		)
	)
	t.ok(ctx, checked > 0, "alive bots were checked")
	t.eq(ctx, outside, 0, "bots stay inside the world box")
	t.eq(ctx, insolid, 0, "bot origins stay out of solid")
	t.eq(ctx, startsolid, 0, "bot boxes stay out of solid (zero-length tracebox)")
	t.ok(ctx, spawned > 0 and removed > 0, "entities are spawned and removed during the match")
	print(
		string.format(
			"  sv.datagram %d bytes, sv.reliable_datagram %d bytes after the last frame (cleared every frame); host_framecount %d",
			sv.datagram.cursize,
			sv.reliable_datagram.cursize,
			cmd.host_framecount
		)
	)
	if #qcwarnings > 0 then
		print("  first QC warnings: " .. table.concat(qcwarnings, " | "))
	end
	print("  builtins hit as stubs while running frames: " .. sorted(stubs))
	local all = table.clone(spawnstubs)
	for k, v in stubs do
		all[k] = (all[k] or 0) + v
	end
	print("  builtins hit as stubs (spawn + frames): " .. sorted(all))

	sv_main.vm_setup_opts = nil
	fs.SetProvider(nil)
	console.sink = function(l: string)
		print(l)
	end
	local shown = 0
	for _, l in lines do
		if
			shown < 40
			and l ~= ""
			and string.sub(l, 1, 8) ~= "execing "
			and string.sub(l, 1, 26) ~= "Warning: Could not expand "
		then
			print("  console: " .. l)
			shown += 1
		end
	end
end
