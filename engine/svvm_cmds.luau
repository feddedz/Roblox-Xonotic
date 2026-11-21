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
local PORTED: { [string]: (prog: any) -> () } = {}
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
