--!strict
--[[
Copyright (C) 1996-1997 Id Software, Inc. (DarkPlaces svvm_cmds.c; GPLv2 or later, see engine/prvm_exec.luau)
]]
--[[
	Port of svvm_cmds.c @xonotic-v0.8.6: server builtins. PARTIAL: the builtin table (vm_sv_builtins[],
	transcribed in engine/_port/builtin_names.luau) is built here; every builtin is a stub that logs
	`NOT YET PORTED: builtin #n <C name>` once and returns zero, until ported (tasks M2-RUNNER / M4-*).
	Ported builtins are registered in PORTED below by C name.
]]
local names = require("./_port/builtin_names")

local svvm_cmds = {}

-- C name -> implementation (prog) -> (); filled as builtins are ported.
local prvm_cmds = require("./prvm_cmds")
local prvm_edict = require("./prvm_edict")
local PORTED: { [string]: (prog: any) -> () } = table.clone(prvm_cmds.BUILTINS)

local warnedNP: { [string]: boolean } = {}
local function notPorted(what: string)
	if not warnedNP[what] then
		warnedNP[what] = true
		print("NOT YET PORTED: " .. what)
	end
end

-- port: svvm_cmds.c VM_SV_copyentity L1748-1778 @xonotic-v0.8.6
local function VM_SV_copyentity(prog: any)
	if prog.argc ~= 2 then
		prog.error_cmd(string.format("VM_SV_copyentity wrong parameter count %i (2 expected ) !", prog.argc))
	end
	local inn = buffer.readi32(prog.globals, 4 * 4)
	if inn == 0 then
		prvm_cmds.VM_Warning(prog, "copyentity: can not read world entity\n")
		return
	end
	if prog.ed_free[inn] then
		prvm_cmds.VM_Warning(prog, "copyentity: can not read free entity\n")
		return
	end
	local out = buffer.readi32(prog.globals, 7 * 4)
	if out == 0 then
		prvm_cmds.VM_Warning(prog, "copyentity: can not modify world entity\n")
		return
	end
	if prog.ed_free[out] then
		prvm_cmds.VM_Warning(prog, "copyentity: can not modify free entity\n")
		return
	end
	local n = prog.entityfields * 4
	buffer.copy(prog.edictsfields, out * n, prog.edictsfields, inn * n, n)
	local amin, amax = prvm_edict.FieldOfs(prog, "absmin"), prvm_edict.FieldOfs(prog, "absmax")
	local f = prog.edictsfields
	local base = out * prog.entityfields
	if
		buffer.readf32(f, (base + amin) * 4) == buffer.readf32(f, (base + amax) * 4)
		and buffer.readf32(f, (base + amin + 1) * 4) == buffer.readf32(f, (base + amax + 1) * 4)
		and buffer.readf32(f, (base + amin + 2) * 4) == buffer.readf32(f, (base + amax + 2) * 4)
	then
		return
	end
	notPorted("SV_LinkEdict (sv_phys.c) in copyentity")
end
PORTED.VM_SV_copyentity = VM_SV_copyentity
svvm_cmds.PORTED = PORTED

-- Builds prog.builtins / prog.numbuiltins like `prog->builtins = vm_sv_builtins` (sv_main.c SV_VM_Setup).
-- `onStub(n, cname, prog)` is called on every stub call (tests use it to record which builtins run).
function svvm_cmds.install(prog: any, onStub: ((n: number, cname: string, prog: any) -> ())?)
	local warned: { [number]: boolean } = {}
	prog.numbuiltins = #names.sv
	prog.builtins = {}
	for i, cname in names.sv do
		local n = i - 1
		if cname then
			local impl = PORTED[cname :: string]
			if impl then
				prog.builtins[n] = impl
			else
				prog.builtins[n] = function(p: any)
					if onStub then
						onStub(n, cname :: string, p)
					end
					if not warned[n] then
						warned[n] = true
						print(string.format("NOT YET PORTED: builtin #%d %s", n, cname :: string))
					end
					buffer.writei32(p.globals, 4, 0)
					buffer.writei32(p.globals, 8, 0)
					buffer.writei32(p.globals, 12, 0)
				end
			end
		end
	end
end

return svvm_cmds
