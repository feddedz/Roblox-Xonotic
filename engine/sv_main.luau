--!strict
--[[
Copyright (C) 1996-1997 Id Software, Inc. (DarkPlaces sv_main.c; GPLv2 or later, see engine/prvm_exec.luau)
]]
--[[
	Port of sv_main.c @xonotic-v0.8.6. PARTIAL: SV_VM_Setup up to PRVM_Prog_Load.
	NOT YET PORTED: the PROGHEADER_CRC branch that sets engine field offsets from entvars_t (applies to
	Xonotic: progs crc 5927), the remaining PRVM_Prog_Load steps (autocvar_* globals from cvars, .po
	translation, PRVM_Init_Exec, field/global offset lookup), the rest of SV_VM_Setup, and everything else.
]]
local prvm_edict = require("./prvm_edict")
local prvm_offsets = require("./prvm_offsets")
local svvm_cmds = require("./svvm_cmds")

local sv_main = {}

local MAX_EDICTS = 32768 -- quakedef.h (non-DP_SMALLMEMORY)

-- port: sv_main.c SV_VM_Setup L3736-3924 @xonotic-v0.8.6 (PARTIAL, see header)
function sv_main.SV_VM_Setup(progsdata: buffer, opts: { onStub: ((number, string, any) -> ())?, maxclients: number? }?)
	local prog: any = prvm_edict.NewProg("server")
	svvm_cmds.install(prog, opts and opts.onStub)
	prog.max_edicts = 512
	prog.limit_edicts = MAX_EDICTS
	prog.reserved_edicts = (opts and opts.maxclients) or 1
	prog.loadintoworld = true
	prvm_edict.PRVM_Prog_Load(prog, "progs.dat", progsdata, prvm_offsets.server_fields, prvm_offsets.server_globals)
	prvm_edict.SetMaxEdicts(prog, prog.max_edicts)
	return prog
end

return sv_main
