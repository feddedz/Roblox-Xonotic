--!strict
-- M2-RUNNER progress test: real progs.dat through SV_VM_Setup (engine/sv_main.luau), layout checks, and a
-- run of the world spawn function on interpreter and AOT (builtins not ported yet are stubs). Both must agree
-- exactly; the printout shows which stubs worldspawn calls. Each prog is made by SV_SpawnServer("stormkeep")
-- on a freshly initialised engine (dedicated Host_Init + configs) and a cleared server, stopped where the map's
-- entities would load, so worldspawn runs in the server state C runs it in (world model, area grid, precache
-- slots, sv.state ss_loading). Needs game data (skips in CI).
local t = require("../_lib/t")
local lfs = require("@lune/fs")
local console = require("../../engine/console")
local fs = require("../../engine/fs")
local host = require("../../engine/host")
local host_cmd = require("../../engine/host_cmd")
local server = require("../../engine/server")
local sv_main = require("../../engine/sv_main")
local svvm_cmds = require("../../engine/svvm_cmds")
local prvm_edict = require("../../engine/prvm_edict")
local prvm_exec = require("../../engine/prvm_exec")
local prvm_offsets = require("../../engine/prvm_offsets")
local qcrt = require("../../engine/_port/qcrt")
local f32 = require("../../engine/_port/f32")
local libc = require("../../engine/_port/libc")
local cvar = require("../../engine/cvar")
local provider = require("../_lib/vfs_provider")

-- SV_SpawnServer on a cleared server (as in a fresh process: sv zeroed), stopped at its PRVM_ED_LoadFromFile
-- call (sv_main.c L3518-3521)
local function spawnUntilEntities(mapname: string)
	server.Clear()
	host_cmd.sv_active = false
	svvm_cmds.VM_CustomStats_Clear()
	local real = prvm_edict.PRVM_ED_LoadFromFile
	local STOP = {}
	prvm_edict.PRVM_ED_LoadFromFile = function(_prog: any, _data: string)
		error(STOP)
	end
	local ok, err = pcall(sv_main.SV_SpawnServer, mapname)
	prvm_edict.PRVM_ED_LoadFromFile = real
	if ok or err ~= STOP then
		error("SV_SpawnServer did not reach PRVM_ED_LoadFromFile: " .. tostring(err), 0)
	end
end

return function(ctx: t.Ctx)
	local dat, gen = "work/vfs-high/progs.dat", "game/generated/progs/init.luau"
	local p = provider("high")
	if not (p and lfs.isFile(dat) and lfs.isFile(gen)) then
		t.skip(ctx, "needs work/vfs-high and tools/build.sh output")
		return
	end
	local logs: { { string } } = { {}, {} }
	local progs = {}
	local runs = {}
	for k = 1, 2 do
		console.sink = function(_l: string) end
		fs.SetProvider(p)
		host.Host_Init_Dedicated()
		local installed: any = nil
		sv_main.vm_setup_opts = {
			onStub = function(n: number, cname: string, _p: any)
				table.insert(logs[k], string.format("#%d %s", n, cname))
			end,
			install = function(pr: any)
				installed = pr
				pr.warning = function(_m: string) end
				if k == 2 then
					(require :: any)("../../game/generated/progs").install(pr, { qcrt = qcrt, f32 = f32 })
				end
			end,
		}
		local okspawn, spawnerr = pcall(spawnUntilEntities, "stormkeep")
		sv_main.vm_setup_opts = nil
		t.ok(ctx, okspawn, "SV_SpawnServer sets up the server up to the entity load: " .. tostring(spawnerr))
		if not okspawn then
			fs.SetProvider(nil)
			console.sink = function(l: string)
				print(l)
			end
			return
		end
		progs[k] = installed
		t.ok(ctx, installed == cvar.prvm_prog_list[0], "the prog SV_VM_Setup made is the server prog")
		-- world spawn function, self = world (run now: the next SV_SpawnServer replaces the server state)
		table.clear(logs[k])
		local _, fnum = prvm_edict.PRVM_ED_FindFunction(installed, "spawnfunc_worldspawn")
		local selfdef = prvm_edict.PRVM_ED_FindGlobal(installed, "self")
		local r: any = { fnum = fnum, selfdef = selfdef }
		if fnum ~= nil and selfdef ~= nil then
			buffer.writei32(installed.globals, selfdef.ofs * 4, 0)
			r.pre = buffer.tostring(installed.globals)
			-- the same rand() sequence for both runs (C: each process seeds it at startup; here the glibc
			-- state is shared by every test in this Lune process, and the first run advances it)
			libc.srand(1)
			-- and the same wall clock: worldspawn formats strftime() dates and gettime(GETTIME_REALTIME / HIRES)
			-- values into temp strings; when they differ, the lengths of strings made from them move later temp
			-- string offsets (seen in OFS_PARM1 after the run)
			local prvm_cmds = require("../../engine/prvm_cmds")
			local dirtytime, walltime = prvm_cmds.Sys_DirtyTime, prvm_cmds.time
			prvm_cmds.Sys_DirtyTime = function(): number
				return 1000.25
			end
			prvm_cmds.time = function(): number
				return 1795000000
			end
			if k == 1 then
				r.ok, r.err = pcall(prvm_exec.PRVM_ExecuteProgram, installed, fnum, "worldspawn")
			else
				r.ok, r.err = pcall(qcrt.ExecuteProgram, installed, fnum, "worldspawn")
			end
			prvm_cmds.Sys_DirtyTime, prvm_cmds.time = dirtytime, walltime
			r.globals = buffer.tostring(installed.globals)
		end
		runs[k] = r
		fs.SetProvider(nil)
		console.sink = function(l: string)
			print(l)
		end
	end
	local pI = progs[1]

	-- layout: required fields/globals appended unconditionally (prvm_edict.c L2049-2083)
	local reqF, reqG = 0, 0
	for _, d in prvm_offsets.server_fields do
		reqF += if d.type == 3 then 3 else 1
	end
	for _, d in prvm_offsets.server_globals do
		reqG += if d.type == 3 then 3 else 1
	end
	t.eq(ctx, pI.entityfields, pI.progs_entityfields + reqF, "entityfields = file + required fields")
	t.eq(ctx, pI.numglobals, pI.progs_numglobals + reqG, "numglobals = file + required globals")
	t.eq(ctx, pI.numbuiltins, 644, "vm_sv_numbuiltins")

	-- every builtin number progs.dat references exists in vm_sv_builtins[]
	local missing = {}
	for fnum = 0, pI.numfunctions - 1 do
		local f = pI.functions[fnum + 1]
		if f.first_statement < 0 then
			local n = -f.first_statement
			if not (n < pI.numbuiltins and pI.builtins[n]) then
				table.insert(missing, string.format("#%d %s", n, prvm_edict.PRVM_GetString(pI, f.s_name)))
			end
		end
	end
	-- Verified 2026-11-20: these are NULL in vm_sv_builtins[] @xonotic-v0.8.6 although progs.dat declares them,
	-- so calling one is "No such builtin" in real DarkPlaces too (the QC checks extensions first). Pinned so a
	-- change is noticed; the port must keep them NULL.
	table.sort(missing)
	t.eq(
		ctx,
		table.concat(missing, ", "),
		"#352 registercommand, #566 findbox, #566 findbox_tofield, #608 parseentitydata",
		"builtins declared by progs.dat that are NULL in the engine"
	)

	-- world spawn function, self = world (each run starts from the same freshly initialised engine; ported
	-- cvar builtins change the cvars, so the second run gets its own Host_Init)
	local rI, rA = runs[1], runs[2]
	t.ok(ctx, rI.fnum ~= nil, "spawnfunc_worldspawn exists")
	t.ok(ctx, rI.selfdef ~= nil, "global self exists")
	if rI.fnum == nil or rI.selfdef == nil then
		return
	end
	local okI, errI, okA, errA = rI.ok, rI.err, rA.ok, rA.err
	t.ok(ctx, rA.pre == rI.pre, "both runs start worldspawn from the same globals")
	t.ok(ctx, okI, "worldspawn completes (interpreter): " .. tostring(errI))
	t.eq(ctx, okA, okI, "worldspawn: same outcome")
	t.eq(ctx, tostring(errA), tostring(errI), "worldspawn: same error")
	t.ok(ctx, rA.globals == rI.globals, "worldspawn: same globals")
	t.eq(ctx, table.concat(logs[2], "|"), table.concat(logs[1], "|"), "worldspawn: same builtin sequence")
	local seen, order = {}, {}
	for _, l in logs[1] do
		if not seen[l] then
			seen[l] = true
			table.insert(order, l)
		end
	end
	print(
		string.format(
			"  worldspawn (all builtins stubbed): ok=%s, %d builtin calls, %d distinct; result: %s",
			tostring(okI),
			#logs[1],
			#order,
			if okI then "completed" else tostring(errI)
		)
	)
	print("  first distinct builtins: " .. table.concat(order, ", ", 1, math.min(#order, 24)))
end
