--!strict
-- Roblox server entry point. Runs what the port can run so far, in DarkPlaces order:
--   Host_Init (dedicated) -> quake.rc config chain -> SV_VM_Setup (progs.dat, AOT-compiled QuakeC) ->
--   spawnfunc_worldspawn with self = world,
-- and prints a report between BEGIN/END markers (copy it into the session / HANDOFF).
-- The server frame loop (host.c Host_Main -> SV_Frame) is not ported yet: see HANDOFF §TASKS (M2-RUNNER, M4).
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local engine = ReplicatedStorage:WaitForChild("Xonotic"):WaitForChild("engine")
local serverGame = ServerScriptService:WaitForChild("XonoticServerGame")

local function req(inst: Instance): any
	return (require :: any)(inst)
end

local report: { string } = {}
local function line(s: string)
	table.insert(report, s)
end

local ok, err = pcall(function()
	local t0 = os.clock()
	local fs = req(engine:WaitForChild("fs"))
	local cvar = req(engine:WaitForChild("cvar"))
	local host = req(engine:WaitForChild("host"))
	local sv_main = req(engine:WaitForChild("sv_main"))
	local prvm_edict = req(engine:WaitForChild("prvm_edict"))
	local port = engine:WaitForChild("_port")
	local qcrt = req(port:WaitForChild("qcrt"))
	local f32 = req(port:WaitForChild("f32"))
	local vfs = req(serverGame:WaitForChild("vfs"))
	line(string.format("modules loaded: %.2f s", os.clock() - t0))

	-- Host_Init + config chain
	local t1 = os.clock()
	fs.SetProvider(vfs)
	host.Host_Init_Dedicated()
	local n = 0
	local v = cvar.cvar_vars
	while v do
		n += 1
		v = v.next
	end
	line(string.format("Host_Init + quake.rc chain: %d cvars in %.2f s", n, os.clock() - t1))

	-- SV_VM_Setup on progs.dat, compiled QuakeC installed
	local t2 = os.clock()
	local data = vfs.load("progs.dat")
	assert(data, "progs.dat missing from game/generated/vfs (run tools/build.sh)")
	local prog = sv_main.SV_VM_Setup(buffer.fromstring(data))
	prog.warning = function(_m: string) end
	req(serverGame:WaitForChild("progs")).install(prog, { qcrt = qcrt, f32 = f32 })
	local autocvars = 0
	for _, def in prog.globaldefs do
		if string.sub(prvm_edict.PRVM_GetString(prog, def.s_name), 1, 9) == "autocvar_" then
			autocvars += 1
		end
	end
	line(
		string.format(
			"SV_VM_Setup + AOT install: %d functions, %d autocvar globals in %.2f s",
			prog.numfunctions,
			autocvars,
			os.clock() - t2
		)
	)

	-- world spawn function, self = world
	local t3 = os.clock()
	local _, fnum = prvm_edict.PRVM_ED_FindFunction(prog, "spawnfunc_worldspawn")
	local selfdef = prvm_edict.PRVM_ED_FindGlobal(prog, "self")
	buffer.writei32(prog.globals, (selfdef :: any).ofs * 4, 0)
	local wok, werr = pcall(qcrt.ExecuteProgram, prog, fnum, "worldspawn")
	line(
		string.format(
			"spawnfunc_worldspawn: %s in %.2f s (headless reference: completed, interpreter == AOT)",
			if wok then "completed" else "stopped: " .. tostring(werr),
			os.clock() - t3
		)
	)
	line(string.format("total: %.2f s", os.clock() - t0))
end)
if not ok then
	line("ERROR: " .. tostring(err))
end
print("===== BEGIN XONOTIC SERVER BOOT REPORT =====")
for _, l in report do
	print(l)
end
print("===== END XONOTIC SERVER BOOT REPORT =====")
warn("NOT YET PORTED: server host loop (host.c Host_Main / sv_main.c SV_Frame) - see HANDOFF.md §TASKS M2-RUNNER/M4")
