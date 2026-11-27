--!strict
-- M2-RUNNER: dedicated Host_Init + quake.rc config chain, then SV_SpawnServer("stormkeep") (which runs
-- SV_VM_Setup on the real progs.dat) on a cleared server, stopped where the map's entities would load.
-- 1. every autocvar_* global holds its cvar's value (PRVM_Prog_Load autocvar pass);
-- 2. spawnfunc_worldspawn runs on a fresh engine with the interpreter and with AOT, and both leave
--    identical globals, builtin sequences and cvars. Needs game data (skips in CI).
local t = require("../_lib/t")
local lfs = require("@lune/fs")
local console = require("../../engine/console")
local cvar = require("../../engine/cvar")
local fs = require("../../engine/fs")
local host = require("../../engine/host")
local host_cmd = require("../../engine/host_cmd")
local server = require("../../engine/server")
local sv_main = require("../../engine/sv_main")
local svvm_cmds = require("../../engine/svvm_cmds")
local prvm_edict = require("../../engine/prvm_edict")
local prvm_exec = require("../../engine/prvm_exec")
local qcrt = require("../../engine/_port/qcrt")
local f32 = require("../../engine/_port/f32")
local libc = require("../../engine/_port/libc")
local provider = require("../_lib/vfs_provider")

local function cvardump(): string
	local out = {}
	local v = cvar.cvar_vars
	while v do
		table.insert(out, v.name .. "=" .. v.string.str)
		v = v.next
	end
	return table.concat(out, "\n")
end

-- SV_SpawnServer on a cleared server (as in a fresh process: sv zeroed), stopped at its PRVM_ED_LoadFromFile
-- call (sv_main.c L3518-3521): world model, submodels, area grid, precache slots, world edict and globals are
-- set up, sv.state is ss_loading, no entity has spawned yet
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
	local results = {}
	for k = 1, 2 do
		local lines: { string } = {}
		console.sink = function(l: string)
			table.insert(lines, l)
		end
		fs.SetProvider(p)
		host.Host_Init_Dedicated()
		local log: { string } = {}
		-- the prog SV_SpawnServer makes (SV_VM_Setup reads sv_progs through the VFS) on a cleared server, stopped
		-- where the map's entities would load: worldspawn then runs in the server state C runs it in
		local installed: any = nil
		sv_main.vm_setup_opts = {
			onStub = function(n: number, cname: string, _p: any)
				table.insert(log, string.format("#%d %s", n, cname))
			end,
			install = function(pr: any)
				installed = pr
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
			return
		end
		local prog = installed
		t.ok(ctx, prog == cvar.prvm_prog_list[0], "the prog SV_VM_Setup made is the server prog")
		prog.warning = function(_m: string) end
		-- the autocvar check below is made after SV_SpawnServer set its cvars (sv_worldname, ...); the
		-- PRVM_Prog_Load pass ran in SV_VM_Setup before that
		table.clear(log) -- only the builtins worldspawn calls
		if k == 1 then
			-- autocvar globals == cvar values
			local n, bad, firstbad = 0, 0, nil
			for _, def in prog.globaldefs do
				local name = prvm_edict.PRVM_GetString(prog, def.s_name)
				local typ = bit32.band(def.type, 0x7fff)
				if string.sub(name, 1, 9) == "autocvar_" and string.match(name, "_[xyz]$") == nil then
					local c = cvar.Cvar_FindVar(string.sub(name, 10)) :: any
					n += 1
					local ok = c ~= nil
					if ok and typ == 2 then
						ok = buffer.readf32(prog.globals, def.ofs * 4) == f32.round(libc.atof(c.string.str))
					elseif ok and typ == 1 then
						ok = prvm_edict.PRVM_GetString(prog, buffer.readi32(prog.globals, def.ofs * 4)) == c.string.str
					end
					if not ok then
						bad += 1
						firstbad = firstbad or name
					end
				end
			end
			print(
				string.format(
					"  autocvars: %d globals, %d mismatches%s",
					n,
					bad,
					if firstbad then " (first " .. firstbad .. ")" else ""
				)
			)
			t.ok(ctx, n > 1000, "autocvar globals found")
			t.eq(ctx, bad, 0, "autocvar globals equal their cvars")
			local g = cvar.Cvar_FindVar("g_balance_blaster_primary_damage")
			t.ok(ctx, g ~= nil and g.string.str ~= "0", "balance cvar from config")
		end
		local _, fnum = prvm_edict.PRVM_ED_FindFunction(prog, "spawnfunc_worldspawn")
		local selfdef = prvm_edict.PRVM_ED_FindGlobal(prog, "self")
		buffer.writei32(prog.globals, (selfdef :: any).ofs * 4, 0)
		local pre = buffer.tostring(prog.globals)
		-- the same rand() sequence for both runs (C: each process seeds it at startup; here the glibc state is
		-- shared by every test in this Lune process, and the first run advances it)
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
		local ok, err
		if k == 1 then
			ok, err = pcall(prvm_exec.PRVM_ExecuteProgram, prog, fnum, "worldspawn")
		else
			ok, err = pcall(qcrt.ExecuteProgram, prog, fnum, "worldspawn")
		end
		prvm_cmds.Sys_DirtyTime, prvm_cmds.time = dirtytime, walltime
		fs.SetProvider(nil)
		results[k] = {
			ok = ok,
			err = tostring(err),
			pre = pre,
			globals = buffer.tostring(prog.globals),
			log = log,
			cvars = cvardump(),
			lines = lines,
		}
	end
	console.sink = function(l: string)
		print(l)
	end
	local a, b = results[1], results[2]
	t.ok(ctx, a.pre == b.pre, "both runs start worldspawn from the same globals")
	t.ok(ctx, a.ok, "worldspawn completes (interpreter): " .. a.err)
	t.eq(ctx, b.ok, a.ok, "worldspawn: same outcome")
	t.eq(ctx, b.err, a.err, "worldspawn: same error")
	t.ok(ctx, a.globals == b.globals, "worldspawn: same globals")
	t.eq(ctx, table.concat(b.log, "|"), table.concat(a.log, "|"), "worldspawn: same builtin sequence")
	t.ok(ctx, a.cvars == b.cvars, "worldspawn: same cvars afterwards")
	local seen, order = {}, {}
	for _, l in a.log do
		if not seen[l] then
			seen[l] = true
			table.insert(order, l)
		end
	end
	print(
		string.format(
			"  worldspawn with real cvars: ok=%s, %d stub calls, %d distinct stubs; result: %s",
			tostring(a.ok),
			#a.log,
			#order,
			if a.ok then "completed" else a.err
		)
	)
	print("  first stubs: " .. table.concat(order, ", ", 1, math.min(#order, 30)))
end
