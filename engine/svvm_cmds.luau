--!strict
--[[
Copyright (C) 1996-1997 Id Software, Inc. (DarkPlaces svvm_cmds.c; GPLv2 or later, see engine/prvm_exec.luau)
]]
--[[
	Port of svvm_cmds.c @xonotic-v0.8.6: server builtins. PARTIAL: the builtin table (vm_sv_builtins[],
	transcribed in engine/_port/builtin_names.luau) is built here; every builtin is a stub that logs
	`NOT YET PORTED: builtin #n <C name>` once and returns zero, until ported (tasks M2-RUNNER / M4-*).
	Ported builtins are registered in PORTED below by C name.
	Edicts are numbers (0 = prog->edicts, the world), as in engine/sv_phys.luau. Per-edict private state
	this file touches: prog.ed_mark[n] = priv.required->mark (nil = 0), prog.ed_suspendedinairflag[n] =
	priv.server->suspendedinairflag (nil = false). sv_phys is required inside the functions (sv_phys ->
	sv_main -> svvm_cmds would be a require cycle).
	builtinsprofile counters (prog->xfunction->builtinsprofile) are profiling only and not ported.
	Also here: the message builtins (WriteDest, WriteByte .. WriteEntity #52-#59, WriteUnterminatedString #456,
	WritePicture #501 without Image_Compress), setattachment #443, setpause #531 and SV_GetEntityMatrix.
]]
local names = require("./_port/builtin_names")

local svvm_cmds = {}

-- C name -> implementation (prog) -> (); filled as builtins are ported.
local prvm_cmds = require("./prvm_cmds")
local prvm_edict = require("./prvm_edict")
local PORTED: { [string]: (prog: any) -> () } = table.clone(prvm_cmds.BUILTINS)

-- Modules that require this one (sv_phys -> sv_main -> svvm_cmds, host, sv_move) or that are needed on use only
-- are required on first use and kept: Lune resolves the path on every require() call (about 0.5 ms), so a
-- require inside a builtin cost more than the builtin (port support, no effect on results).
local lazymods: { [string]: any } = {}
local function SVPHYS(): any
	local m = lazymods.sv_phys
	if not m then
		m = require("./sv_phys")
		lazymods.sv_phys = m
	end
	return m
end
local function SVMAIN(): any
	local m = lazymods.sv_main
	if not m then
		m = require("./sv_main")
		lazymods.sv_main = m
	end
	return m
end
local function SVMOVE(): any
	local m = lazymods.sv_move
	if not m then
		m = require("./sv_move")
		lazymods.sv_move = m
	end
	return m
end
local function HOST(): any
	local m = lazymods.host
	if not m then
		m = require("./host")
		lazymods.host = m
	end
	return m
end
local function MATRIXLIB(): any
	local m = lazymods.matrixlib
	if not m then
		m = require("./matrixlib")
		lazymods.matrixlib = m
	end
	return m
end
local function MODELALIAS(): any
	local m = lazymods.model_alias
	if not m then
		m = require("./model_alias")
		lazymods.model_alias = m
	end
	return m
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
	SVPHYS().SV_LinkEdict(out) -- required here: sv_phys -> sv_main -> svvm_cmds
end
PORTED.VM_SV_copyentity = VM_SV_copyentity
local server = require("./server")
local common = require("./common")
local libc = require("./_port/libc")
local console = require("./console")
local host_cmd = require("./host_cmd")
local P = common.PROTOCOL

local function G_FLOAT(prog: any, ofs: number): number
	return buffer.readf32(prog.globals, ofs * 4)
end
local function G_STRING(prog: any, ofs: number): string
	return libc.cstr(prvm_edict.PRVM_GetString(prog, buffer.readi32(prog.globals, ofs * 4)))
end
local function SAFEPARMCOUNT(prog: any, p: number, f: string)
	if prog.argc ~= p then
		prog.error_cmd(string.format("%s wrong parameter count %i (%d expected ) !", f, prog.argc, p))
	end
end
local function oldprotocol(p: number): boolean
	return p == P.QUAKE
		or p == P.QUAKEDP
		or p == P.NEHAHRAMOVIE
		or p == P.NEHAHRABJP
		or p == P.NEHAHRABJP2
		or p == P.NEHAHRABJP3
end

-- port: sv_main.c SV_SoundIndex L2956-2996 @xonotic-v0.8.6
function svvm_cmds.SV_SoundIndex(s: string?, precachemode: number): number
	local sv = server.sv
	local limit = if oldprotocol(sv.protocol) then 256 else server.MAX_SOUNDS
	if not s or s == "" then
		return 0
	end
	local filename = string.sub(s :: string, 1, server.MAX_QPATH - 1)
	local i = 1
	while i < limit do
		local cur = sv.sound_precache[i]
		if not cur or cur == "" then
			if precachemode ~= 0 then
				if
					sv.state ~= server.ss_loading
					and (
						oldprotocol(sv.protocol)
						or sv.protocol == P.DARKPLACES1
						or sv.protocol == P.DARKPLACES2
						or sv.protocol == P.DARKPLACES3
						or sv.protocol == P.DARKPLACES4
						or sv.protocol == P.DARKPLACES5
					)
				then
					console.Con_Print(
						string.format(
							'SV_SoundIndex("%s"): precache_sound can only be done in spawn functions\n',
							filename
						)
					)
					return 0
				end
				if precachemode == 1 then
					console.Con_Print(
						string.format(
							'SV_SoundIndex("%s"): not precached (fix your code), precaching anyway\n',
							filename
						)
					)
				end
				sv.sound_precache[i] = filename
				if sv.state ~= server.ss_loading then
					common.MSG_WriteByte(sv.reliable_datagram, 54) -- svc_precache
					common.MSG_WriteShort(sv.reliable_datagram, i + 32768)
					common.MSG_WriteString(sv.reliable_datagram, filename)
				end
				return i
			end
			console.Con_Print(string.format('SV_SoundIndex("%s"): not precached\n', filename))
			return 0
		end
		if cur == filename then
			return i
		end
		i += 1
	end
	console.Con_Print(string.format('SV_SoundIndex("%s"): i (%i) == MAX_SOUNDS (%i)\n', filename, i, server.MAX_SOUNDS))
	return 0
end

-- port: svvm_cmds.c VM_SV_precache_sound L1052-1056 @xonotic-v0.8.6
PORTED.VM_SV_precache_sound = function(prog: any)
	SAFEPARMCOUNT(prog, 1, "VM_SV_precache_sound")
	buffer.writef32(prog.globals, 4, svvm_cmds.SV_SoundIndex(G_STRING(prog, 4), 2))
end

-- port: svvm_cmds.c VM_SV_ambientsound L465-505 @xonotic-v0.8.6
PORTED.VM_SV_ambientsound = function(prog: any)
	SAFEPARMCOUNT(prog, 4, "VM_SV_ambientsound")
	local sv = server.sv
	local pos = { G_FLOAT(prog, 4), G_FLOAT(prog, 5), G_FLOAT(prog, 6) }
	local samp = G_STRING(prog, 7)
	local vol = G_FLOAT(prog, 10)
	local attenuation = G_FLOAT(prog, 13)
	-- check to see if samp was properly precached
	local soundnum = svvm_cmds.SV_SoundIndex(samp, 1)
	if soundnum == 0 then
		return
	end
	local large = soundnum >= 256
	-- add an svc_spawnambient command to the level signon packet
	common.MSG_WriteByte(sv.signon, if large then 59 else 29) -- svc_spawnstaticsound2 / svc_spawnstaticsound
	common.MSG_WriteVector(sv.signon, pos, sv.protocol)
	if large or sv.protocol == P.NEHAHRABJP or sv.protocol == P.NEHAHRABJP2 or sv.protocol == P.NEHAHRABJP3 then
		common.MSG_WriteShort(sv.signon, soundnum)
	else
		common.MSG_WriteByte(sv.signon, soundnum)
	end
	-- (int)(vol*255), (int)(attenuation*64): float products, then truncated
	local fround = require("./_port/f32").round
	common.MSG_WriteByte(sv.signon, libc.toint(fround(vol * 255)))
	common.MSG_WriteByte(sv.signon, libc.toint(fround(attenuation * 64)))
end

-- port: svvm_cmds.c VM_SV_lightstyle L1214-1246 @xonotic-v0.8.6 (no clients connect yet, M6-NET)
PORTED.VM_SV_lightstyle = function(prog: any)
	SAFEPARMCOUNT(prog, 2, "VM_SV_lightstyle")
	local sv = server.sv
	local style = libc.toint(G_FLOAT(prog, 4))
	local val = G_STRING(prog, 7)
	if style % 4294967296 >= server.MAX_LIGHTSTYLES then
		prog.error_cmd(string.format("PF_lightstyle: style: %i >= 64", style))
	end
	-- change the string in sv
	sv.lightstyles[style] = string.sub(val, 1, 63)
	-- send message to all clients on this server
	if sv.state ~= server.ss_active then
		return
	end
	local svs = host_cmd.svs :: any
	for j = 0, svs.maxclients - 1 do
		local client = svs.clients and svs.clients[j]
		if client and client.active and client.netconnection then
			local m = client.netconnection.message
			common.MSG_WriteChar(m, 12) -- svc_lightstyle
			common.MSG_WriteChar(m, style)
			common.MSG_WriteString(m, val)
		end
	end
end

-- port: svvm_cmds.c VM_SV_AddStat L1697-1737 @xonotic-v0.8.6
PORTED.VM_SV_AddStat = function(prog: any)
	SAFEPARMCOUNT(prog, 3, "VM_SV_AddStat")
	local i = libc.toint(G_FLOAT(prog, 4))
	local stattype = libc.toint(G_FLOAT(prog, 7)) % 256 -- unsigned char
	local off = buffer.readi32(prog.globals, 10 * 4)
	i -= 32
	if i < 0 then
		prvm_cmds.VM_Warning(prog, "PF_SV_AddStat: index may not be less than 32\n")
		return
	end
	if i >= server.MAX_CL_STATS - 32 then
		prvm_cmds.VM_Warning(prog, "PF_SV_AddStat: index >= MAX_CL_STATS\n")
		return
	end
	if i > server.MAX_CL_STATS - 32 - 4 and stattype == 1 then
		prvm_cmds.VM_Warning(prog, "PF_SV_AddStat: index > (MAX_CL_STATS-4) with string\n")
		return
	end
	server.vm_customstats[i] = { type = stattype, fieldoffset = off }
	if server.vm_customstats_last < i then
		server.vm_customstats_last = i
	end
end

--[[
	Builtins on the world / trace code (engine/sv_phys.luau). vec_t is float (qtypes.h, VEC_64 off): every
	float result is rounded (D-004); trace_t.fraction / endpos are double (collision.h).
]]
local collision = require("./collision")
local cvar = require("./cvar")
local f32 = require("./_port/f32")
local libm = require("./_port/libm")
local R = f32.round
local toint = libc.toint
local FieldOfs = prvm_edict.FieldOfs
local GlobalOfs = prvm_cmds.GlobalOfs

local OFS_RETURN, OFS_PARM0, OFS_PARM1, OFS_PARM2, OFS_PARM3, OFS_PARM4, OFS_PARM5 = 1, 4, 7, 10, 13, 16, 19
local MOVE_NORMAL = 0 -- world.h L27
local SOLID_NOT = 0 -- server.h L342
local FL_ONGROUND = 512 -- server.h L376
local MAX_EDICTS = 32768 -- quakedef.h L139
local PRVM_EDICT_MARK_WAIT_FOR_SETORIGIN, PRVM_EDICT_MARK_SETORIGIN_CAUGHT = -1, -2 -- progsvm.h L75-76

-- cvars of sv_main.c (registered values, else the defaults sv_main.c registers them with)
local function cvarint(name: string, default: number): number
	local v = cvar.Cvar_FindVar(name)
	return if v then v.integer else default
end

-- VM_SAFEPARMCOUNTRANGE (prvm_cmds.h L206)
local function SAFEPARMCOUNTRANGE(prog: any, p1: number, p2: number, f: string)
	if prog.argc < p1 or prog.argc > p2 then
		prog.error_cmd(string.format("%s wrong parameter count %i (%d to %d expected ) !", f, prog.argc, p1, p2))
	end
end
local function G_INT(prog: any, ofs: number): number -- PRVM_G_INT / PRVM_G_EDICTNUM
	return buffer.readi32(prog.globals, ofs * 4)
end
local function G_VECTOR(prog: any, ofs: number): { number } -- a copy of PRVM_G_VECTOR
	local g = prog.globals
	return { buffer.readf32(g, ofs * 4), buffer.readf32(g, ofs * 4 + 4), buffer.readf32(g, ofs * 4 + 8) }
end
local function SET_G_FLOAT(prog: any, ofs: number, v: number)
	buffer.writef32(prog.globals, ofs * 4, v)
end
local function RETURN_EDICT(prog: any, e: number) -- VM_RETURN_EDICT
	buffer.writei32(prog.globals, OFS_RETURN * 4, e)
end
-- PRVM_serveredict* (see engine/sv_phys.luau)
local function EOFS(prog: any, ed: number, f: string): number
	return (ed * prog.entityfields + FieldOfs(prog, f)) * 4
end
local function EF(prog: any, ed: number, f: string): number
	return buffer.readf32(prog.edictsfields, EOFS(prog, ed, f))
end
local function SET_EF(prog: any, ed: number, f: string, v: number)
	buffer.writef32(prog.edictsfields, EOFS(prog, ed, f), v)
end
local function SET_EI(prog: any, ed: number, f: string, v: number)
	buffer.writei32(prog.edictsfields, EOFS(prog, ed, f), v)
end
local function EV(prog: any, ed: number, f: string): { number }
	local b, o = prog.edictsfields, EOFS(prog, ed, f)
	return { buffer.readf32(b, o), buffer.readf32(b, o + 4), buffer.readf32(b, o + 8) }
end
local function SET_EV(prog: any, ed: number, f: string, v: { number }) -- stores float (double values rounded)
	local b, o = prog.edictsfields, EOFS(prog, ed, f)
	buffer.writef32(b, o, v[1])
	buffer.writef32(b, o + 4, v[2])
	buffer.writef32(b, o + 8, v[3])
end
-- (int)flags | bit, stored back as float: the int result is signed
local function orflag(x: number, bit: number): number
	local r = bit32.bor(toint(x), bit)
	return if r >= 0x80000000 then r - 0x100000000 else r
end
local function isnan(x: number): boolean
	return x ~= x
end
-- printf "%f" of a float argument (promoted to double), as glibc prints it, non-finite values included
local function pf(x: number): string
	return libc.format1("", 0, -1, "f", x)
end

-- port: svvm_cmds.c VM_SV_setorigin L242-263 @xonotic-v0.8.6
local function VM_SV_setorigin(prog: any)
	SAFEPARMCOUNT(prog, 2, "VM_setorigin")

	local e = G_INT(prog, OFS_PARM0)
	if e == 0 then
		prvm_cmds.VM_Warning(prog, "setorigin: can not modify world entity\n")
		return
	end
	if prog.ed_free[e] then
		prvm_cmds.VM_Warning(prog, "setorigin: can not modify free entity\n")
		return
	end
	-- VectorCopy(PRVM_G_VECTOR(OFS_PARM1), PRVM_serveredictvector(e, origin)): the bits as they are
	buffer.copy(prog.edictsfields, EOFS(prog, e, "origin"), prog.globals, OFS_PARM1 * 4, 12)
	local marks = prog.ed_mark
	if marks and marks[e] == PRVM_EDICT_MARK_WAIT_FOR_SETORIGIN then
		marks[e] = PRVM_EDICT_MARK_SETORIGIN_CAUGHT
	end
	SVPHYS().SV_LinkEdict(e)
end
PORTED.VM_SV_setorigin = VM_SV_setorigin

-- TODO: rotate param isnt used.. could be a bug. please check this and remove it if possible [1/10/2008 Black]
-- port: svvm_cmds.c SetMinMaxSize L266-280 @xonotic-v0.8.6
local function SetMinMaxSize(prog: any, e: number, min: { number }, max: { number }, _rotate: boolean)
	for i = 1, 3 do
		if min[i] > max[i] then
			prog.error_cmd("SetMinMaxSize: backwards mins/maxs")
		end
	end

	-- set derived values
	SET_EV(prog, e, "mins", min)
	SET_EV(prog, e, "maxs", max)
	SET_EV(prog, e, "size", { R(max[1] - min[1]), R(max[2] - min[2]), R(max[3] - min[3]) })

	SVPHYS().SV_LinkEdict(e)
end
svvm_cmds.SetMinMaxSize = SetMinMaxSize

-- port: svvm_cmds.c VM_SV_setsize L292-313 @xonotic-v0.8.6
local function VM_SV_setsize(prog: any)
	SAFEPARMCOUNT(prog, 3, "VM_setsize")

	local e = G_INT(prog, OFS_PARM0)
	if e == 0 then
		prvm_cmds.VM_Warning(prog, "setsize: can not modify world entity\n")
		return
	end
	if prog.ed_free[e] then
		prvm_cmds.VM_Warning(prog, "setsize: can not modify free entity\n")
		return
	end
	local mins = G_VECTOR(prog, OFS_PARM1)
	local maxs = G_VECTOR(prog, OFS_PARM2)
	SetMinMaxSize(prog, e, mins, maxs, false)
end
PORTED.VM_SV_setsize = VM_SV_setsize

--[[
=================
VM_SV_setmodel

setmodel(entity, model)
=================
]]
-- SV_ModelIndex / SV_GetModelByIndex are in engine/sv_main.luau, which requires this module: required inside
local quakemins, quakemaxs = { -16, -16, -16 }, { 16, 16, 16 }
local vec3_origin = { 0, 0, 0 }
-- port: svvm_cmds.c VM_SV_setmodel L324-358 @xonotic-v0.8.6
local function VM_SV_setmodel(prog: any)
	local sv_main = SVMAIN() :: any
	local mod
	local i

	SAFEPARMCOUNT(prog, 2, "VM_setmodel")

	local e = G_INT(prog, OFS_PARM0)
	if e == 0 then
		prvm_cmds.VM_Warning(prog, "setmodel: can not modify world entity\n")
		return
	end
	if prog.ed_free[e] then
		prvm_cmds.VM_Warning(prog, "setmodel: can not modify free entity\n")
		return
	end
	i = sv_main.SV_ModelIndex(G_STRING(prog, OFS_PARM1), 1)
	SET_EI(
		prog,
		e,
		"model",
		prvm_edict.PRVM_SetEngineString(prog, server.CStrRef("model_precache " .. i, server.sv.model_precache[i] or ""))
	)
	SET_EF(prog, e, "modelindex", i)

	mod = sv_main.SV_GetModelByIndex(i)

	if mod then
		if mod.type ~= "mod_alias" or cvarint("sv_gameplayfix_setmodelrealbox", 1) ~= 0 then
			SetMinMaxSize(prog, e, mod.normalmins, mod.normalmaxs, true)
		else
			SetMinMaxSize(prog, e, quakemins, quakemaxs, true)
		end
	else
		SetMinMaxSize(prog, e, vec3_origin, vec3_origin, true)
	end
end
PORTED.VM_SV_setmodel = VM_SV_setmodel

-- port: svvm_cmds.c VM_SV_precache_model L1058-1063 @xonotic-v0.8.6
local function VM_SV_precache_model(prog: any)
	SAFEPARMCOUNT(prog, 1, "VM_SV_precache_model")
	SVMAIN().SV_ModelIndex(G_STRING(prog, OFS_PARM0), 2)
	buffer.writei32(prog.globals, OFS_RETURN * 4, G_INT(prog, OFS_PARM0))
end
PORTED.VM_SV_precache_model = VM_SV_precache_model

-- port: svvm_cmds.c VM_CustomStats_Clear L1636-1644 @xonotic-v0.8.6
function svvm_cmds.VM_CustomStats_Clear()
	-- (if(vm_customstats): the table always exists here; clearing it is the same as Z_Free + NULL)
	table.clear(server.vm_customstats)
	server.vm_customstats_last = -1
end

-- port: svvm_cmds.c VM_SV_UpdateCustomStats L1646-1688 @xonotic-v0.8.6
-- (ent: edict number; stats: the 0-based int table of SV_SendClientDatagram; client and msg are unused, as in C.
-- vm_customstats == NULL is the empty table here: vm_customstats_last is then -1 and the loop does nothing.)
function svvm_cmds.VM_SV_UpdateCustomStats(_client: any, ent: number, _msg: any, stats: { [number]: number })
	local prog: any = cvar.prvm_prog_list[0] -- SVVM_prog
	local customstats = server.vm_customstats
	local fields, base = prog.edictsfields, ent * prog.entityfields

	for i = 0, server.vm_customstats_last do
		local cs = customstats[i]
		if not cs or cs.type == 0 then
			continue
		end
		local stype = cs.type
		--string as 16 bytes
		if stype == 1 then
			-- memset(s, 0, 17); strlcpy(s, PRVM_E_STRING(ent, fieldoffset), 16): at most 15 characters, s[15] = 0
			local str = libc.cstr(prvm_edict.PRVM_GetString(prog, buffer.readi32(fields, (base + cs.fieldoffset) * 4)))
			local function sch(k: number): number -- s[k] as a (signed) char
				local b = string.byte(str, k + 1)
				if not b or k >= 15 then
					return 0
				end
				return if b >= 128 then b - 256 else b
			end
			local function word(k: number): number -- s[k] + s[k+1] * 256 + s[k+2] * 65536 + s[k+3] * 16777216 (int)
				local v = sch(k) + sch(k + 1) * 256 + sch(k + 2) * 65536 + sch(k + 3) * 16777216
				v = v % 4294967296
				return if v >= 0x80000000 then v - 0x100000000 else v
			end
			stats[i + 32] = word(0)
			stats[i + 33] = word(4)
			stats[i + 34] = word(8)
			stats[i + 35] = word(12)
		--float field sent as-is
		elseif stype == 8 then
			-- can't directly use PRVM_E_INT on the field because it may be PRVM_64 and a double is not the representation we want to send
			-- (u.f = PRVM_E_FLOAT(...); stats = u.i: the bits of the 32-bit float slot)
			stats[i + 32] = buffer.readi32(fields, (base + cs.fieldoffset) * 4)
		--integer value of float field
		elseif stype == 2 then
			stats[i + 32] = libc.toint(buffer.readf32(fields, (base + cs.fieldoffset) * 4))
		end
	end
end

-- #333 void(entity e, float mdlindex) setmodelindex (EXT_CSQC)
-- port: svvm_cmds.c VM_SV_setmodelindex L2733-2777 @xonotic-v0.8.6
local function VM_SV_setmodelindex(prog: any)
	local sv_main = SVMAIN() :: any
	local mod
	local i
	SAFEPARMCOUNT(prog, 2, "VM_SV_setmodelindex")

	local e = G_INT(prog, OFS_PARM0)
	if e == 0 then
		prvm_cmds.VM_Warning(prog, "setmodelindex: can not modify world entity\n")
		return
	end
	if prog.ed_free[e] then
		prvm_cmds.VM_Warning(prog, "setmodelindex: can not modify free entity\n")
		return
	end
	i = toint(G_FLOAT(prog, OFS_PARM1))
	if i <= 0 or i >= server.MAX_MODELS then
		prvm_cmds.VM_Warning(prog, "setmodelindex: invalid modelindex\n")
		return
	end
	local name = server.sv.model_precache[i]
	if not name or name == "" then
		prvm_cmds.VM_Warning(prog, "setmodelindex: model not precached\n")
		return
	end

	SET_EI(prog, e, "model", prvm_edict.PRVM_SetEngineString(prog, server.CStrRef("model_precache " .. i, name)))
	SET_EF(prog, e, "modelindex", i)

	mod = sv_main.SV_GetModelByIndex(i)

	if mod then
		if mod.type ~= "mod_alias" or cvarint("sv_gameplayfix_setmodelrealbox", 1) ~= 0 then
			SetMinMaxSize(prog, e, mod.normalmins, mod.normalmaxs, true)
		else
			SetMinMaxSize(prog, e, quakemins, quakemaxs, true)
		end
	else
		SetMinMaxSize(prog, e, vec3_origin, vec3_origin, true)
	end
end
PORTED.VM_SV_setmodelindex = VM_SV_setmodelindex

-- #334 string(float mdlindex) modelnameforindex (EXT_CSQC)
-- port: svvm_cmds.c VM_SV_modelnameforindex L2780-2800 @xonotic-v0.8.6
local function VM_SV_modelnameforindex(prog: any)
	local i
	SAFEPARMCOUNT(prog, 1, "VM_SV_modelnameforindex")

	buffer.writei32(prog.globals, OFS_RETURN * 4, 0) -- OFS_NULL

	i = toint(G_FLOAT(prog, OFS_PARM0))
	if i <= 0 or i >= server.MAX_MODELS then
		prvm_cmds.VM_Warning(prog, "modelnameforindex: invalid modelindex\n")
		return
	end
	local name = server.sv.model_precache[i]
	if not name or name == "" then
		prvm_cmds.VM_Warning(prog, "modelnameforindex: model not precached\n")
		return
	end

	buffer.writei32(
		prog.globals,
		OFS_RETURN * 4,
		prvm_edict.PRVM_SetEngineString(prog, server.CStrRef("model_precache " .. i, name))
	)
end
PORTED.VM_SV_modelnameforindex = VM_SV_modelnameforindex

-- port: svvm_cmds.c VM_SV_traceline L640-662 @xonotic-v0.8.6
local function VM_SV_traceline(prog: any)
	SAFEPARMCOUNTRANGE(prog, 4, 8, "VM_SV_traceline") -- allow more parameters for future expansion

	local v1 = G_VECTOR(prog, OFS_PARM0)
	local v2 = G_VECTOR(prog, OFS_PARM1)
	local move = toint(G_FLOAT(prog, OFS_PARM2))
	local ent = G_INT(prog, OFS_PARM3)

	if isnan(v1[1]) or isnan(v1[2]) or isnan(v1[3]) or isnan(v2[1]) or isnan(v2[2]) or isnan(v2[3]) then
		prog.error_cmd(
			-- %f of a NaN as glibc prints it ("nan" / "-nan"; string.format gives the host C runtime's text)
			string.format(
				"%s: NAN errors detected in traceline('%s %s %s', '%s %s %s', %i, entity %i)\n",
				prog.name,
				pf(v1[1]),
				pf(v1[2]),
				pf(v1[3]),
				pf(v2[1]),
				pf(v2[2]),
				pf(v2[3]),
				move,
				ent
			)
		)
	end

	local sv_phys = SVPHYS()
	local trace = sv_phys.SV_TraceLine(
		v1,
		v2,
		move,
		ent,
		sv_phys.SV_GenericHitSuperContentsMask(ent),
		0,
		0,
		collision.cv.collision_extendtracelinelength.value
	)

	prvm_cmds.VM_SetTraceGlobals(prog, trace)
end
PORTED.VM_SV_traceline = VM_SV_traceline

-- LordHavoc: added this for my own use, VERY useful, similar to traceline
-- port: svvm_cmds.c VM_SV_tracebox L677-701 @xonotic-v0.8.6
local function VM_SV_tracebox(prog: any)
	SAFEPARMCOUNTRANGE(prog, 6, 8, "VM_SV_tracebox") -- allow more parameters for future expansion

	local v1 = G_VECTOR(prog, OFS_PARM0)
	local m1 = G_VECTOR(prog, OFS_PARM1)
	local m2 = G_VECTOR(prog, OFS_PARM2)
	local v2 = G_VECTOR(prog, OFS_PARM3)
	local move = toint(G_FLOAT(prog, OFS_PARM4))
	local ent = G_INT(prog, OFS_PARM5)

	if isnan(v1[1]) or isnan(v1[2]) or isnan(v1[3]) or isnan(v2[1]) or isnan(v2[2]) or isnan(v2[3]) then
		prog.error_cmd(
			string.format(
				"%s: NAN errors detected in tracebox('%s %s %s', '%s %s %s', '%s %s %s', '%s %s %s', %i, entity %i)\n",
				prog.name,
				pf(v1[1]),
				pf(v1[2]),
				pf(v1[3]),
				pf(m1[1]),
				pf(m1[2]),
				pf(m1[3]),
				pf(m2[1]),
				pf(m2[2]),
				pf(m2[3]),
				pf(v2[1]),
				pf(v2[2]),
				pf(v2[3]),
				move,
				ent
			)
		)
	end

	local sv_phys = SVPHYS()
	local trace = sv_phys.SV_TraceBox(
		v1,
		m1,
		m2,
		v2,
		move,
		ent,
		sv_phys.SV_GenericHitSuperContentsMask(ent),
		0,
		0,
		collision.cv.collision_extendtraceboxlength.value
	)

	prvm_cmds.VM_SetTraceGlobals(prog, trace)
end
PORTED.VM_SV_tracebox = VM_SV_tracebox

local touchedicts_findradius: { number } = {} -- static prvm_edict_t *touchedicts[MAX_EDICTS]

-- port: svvm_cmds.c VM_SV_findradius L984-1050 @xonotic-v0.8.6
local function VM_SV_findradius(prog: any)
	local touchedicts = touchedicts_findradius

	SAFEPARMCOUNTRANGE(prog, 2, 3, "VM_SV_findradius")

	local chainfield
	if prog.argc == 3 then
		chainfield = G_INT(prog, OFS_PARM2)
	else
		chainfield = FieldOfs(prog, "chain")
	end
	if chainfield < 0 then
		prog.error_cmd(string.format("VM_findchain: %s doesnt have the specified chain field !", prog.name))
	end

	local chain = 0 -- prog->edicts

	local org = G_VECTOR(prog, OFS_PARM0)
	local radius = G_FLOAT(prog, OFS_PARM1)
	local radius2 = R(radius * radius)

	local r1 = R(radius + 1)
	local mins = { R(org[1] - r1), R(org[2] - r1), R(org[3] - r1) }
	local maxs = { R(org[1] + r1), R(org[2] + r1), R(org[3] + r1) }
	local numtouchedicts = SVPHYS().SV_EntitiesInBox(mins, maxs, MAX_EDICTS, touchedicts)
	if numtouchedicts > MAX_EDICTS then
		-- this never happens
		console.Con_Printf("SV_EntitiesInBox returned %i edicts, max was %i\n", numtouchedicts, MAX_EDICTS)
		numtouchedicts = MAX_EDICTS
	end
	local blowupfallenzombies = cvarint("sv_gameplayfix_blowupfallenzombies", 1)
	local distancetobox = cvarint("sv_gameplayfix_findradiusdistancetobox", 1)
	for i = 0, numtouchedicts - 1 do
		local ent = touchedicts[i + 1]
		-- Quake did not return non-solid entities but darkplaces does
		-- (note: this is the reason you can't blow up fallen zombies)
		if EF(prog, ent, "solid") == SOLID_NOT and blowupfallenzombies == 0 then
			continue
		end
		-- LordHavoc: compare against bounding box rather than center so it
		-- doesn't miss large objects, and use DotProduct instead of Length
		-- for a major speedup
		local origin = EV(prog, ent, "origin")
		local eorg = { R(org[1] - origin[1]), R(org[2] - origin[2]), R(org[3] - origin[3]) }
		local emins, emaxs = EV(prog, ent, "mins"), EV(prog, ent, "maxs")
		if distancetobox ~= 0 then
			for k = 1, 3 do
				-- bound(min, num, max) (mathlib.h L51)
				local b = if eorg[k] >= emins[k] then (if eorg[k] < emaxs[k] then eorg[k] else emaxs[k]) else emins[k]
				eorg[k] = R(eorg[k] - b)
			end
		else
			-- VectorMAMAM(1, eorg, -0.5f, mins, -0.5f, maxs, eorg)
			for k = 1, 3 do
				eorg[k] = R(R(eorg[k] + R(-0.5 * emins[k])) + R(-0.5 * emaxs[k]))
			end
		end
		if R(R(R(eorg[1] * eorg[1]) + R(eorg[2] * eorg[2])) + R(eorg[3] * eorg[3])) < radius2 then
			buffer.writei32(prog.edictsfields, (ent * prog.entityfields + chainfield) * 4, chain)
			chain = ent
		end
	end

	RETURN_EDICT(prog, chain)
end
PORTED.VM_SV_findradius = VM_SV_findradius

-- sv_phys.SV_NudgeOutOfSolid: droptofloor calls it when sv_gameplayfix_droptofloorstartsolid_nudgetocorrect is
-- set (default 1, Xonotic keeps it). (sv_phys is required here, not at the top: it requires sv_main.)
local function SV_NudgeOutOfSolid(ent: number)
	local sv_phys: any = SVPHYS()
	sv_phys.SV_NudgeOutOfSolid(ent)
end

-- port: svvm_cmds.c VM_SV_droptofloor L1130-1205 @xonotic-v0.8.6
local function VM_SV_droptofloor(prog: any)
	local sv_phys = SVPHYS()
	-- allow 2 parameters because the id1 defs.qc had an incorrect prototype
	SAFEPARMCOUNTRANGE(prog, 0, 2, "VM_SV_droptofloor")

	-- assume failure if it returns early
	SET_G_FLOAT(prog, OFS_RETURN, 0)

	local ent = buffer.readi32(prog.globals, GlobalOfs(prog, "self") * 4)
	if ent == 0 then
		prvm_cmds.VM_Warning(prog, "droptofloor: can not modify world entity\n")
		return
	end
	if prog.ed_free[ent] then
		prvm_cmds.VM_Warning(prog, "droptofloor: can not modify free entity\n")
		return
	end

	local end_ = EV(prog, ent, "origin")
	end_[3] = R(end_[3] - 256)

	local nudgetocorrect = cvarint("sv_gameplayfix_droptofloorstartsolid_nudgetocorrect", 1)
	if nudgetocorrect ~= 0 then
		SV_NudgeOutOfSolid(ent)
	end

	local entorigin = EV(prog, ent, "origin")
	local entmins = EV(prog, ent, "mins")
	local entmaxs = EV(prog, ent, "maxs")
	local extendmove = collision.cv.collision_extendmovelength.value
	local trace = sv_phys.SV_TraceBox(
		entorigin,
		entmins,
		entmaxs,
		end_,
		MOVE_NORMAL,
		ent,
		sv_phys.SV_GenericHitSuperContentsMask(ent),
		0,
		0,
		extendmove
	)
	if trace.startsolid and cvarint("sv_gameplayfix_droptofloorstartsolid", 1) ~= 0 then
		local emins, emaxs = EV(prog, ent, "mins"), EV(prog, ent, "maxs")
		local offset = { R(0.5 * R(emins[1] + emaxs[1])), R(0.5 * R(emins[2] + emaxs[2])), emins[3] }
		local origin = EV(prog, ent, "origin")
		local org = { R(origin[1] + offset[1]), R(origin[2] + offset[2]), R(origin[3] + offset[3]) }
		-- engine quirk kept: end is not offset, so the line is slanted by offset in x / y
		trace = sv_phys.SV_TraceLine(
			org,
			end_,
			MOVE_NORMAL,
			ent,
			sv_phys.SV_GenericHitSuperContentsMask(ent),
			0,
			0,
			extendmove
		)
		-- VectorSubtract(trace.endpos, offset, trace.endpos): double - float, stored as double
		trace.endpos[1] = trace.endpos[1] - offset[1]
		trace.endpos[2] = trace.endpos[2] - offset[2]
		trace.endpos[3] = trace.endpos[3] - offset[3]
		if trace.startsolid then
			local o = EV(prog, ent, "origin")
			console.Con_DPrintf("droptofloor at %f %f %f - COULD NOT FIX BADLY PLACED ENTITY\n", o[1], o[2], o[3])
			sv_phys.SV_LinkEdict(ent)
			SET_EF(prog, ent, "flags", orflag(EF(prog, ent, "flags"), FL_ONGROUND))
			SET_EI(prog, ent, "groundentity", 0)
			SET_G_FLOAT(prog, OFS_RETURN, 1)
		elseif trace.fraction < 1 then
			local o = EV(prog, ent, "origin")
			console.Con_DPrintf("droptofloor at %f %f %f - FIXED BADLY PLACED ENTITY\n", o[1], o[2], o[3])
			SET_EV(prog, ent, "origin", trace.endpos)
			if nudgetocorrect ~= 0 then
				SV_NudgeOutOfSolid(ent)
			end
			sv_phys.SV_LinkEdict(ent)
			SET_EF(prog, ent, "flags", orflag(EF(prog, ent, "flags"), FL_ONGROUND))
			-- trace.ent is set (at least the world) whenever fraction < 1
			SET_EI(prog, ent, "groundentity", trace.ent or 0)
			SET_G_FLOAT(prog, OFS_RETURN, 1)
			-- if support is destroyed, keep suspended (gross hack for floating items in various maps)
			prog.ed_suspendedinairflag = prog.ed_suspendedinairflag or {}
			prog.ed_suspendedinairflag[ent] = true
		end
	else
		if not trace.allsolid and trace.fraction < 1 then
			SET_EV(prog, ent, "origin", trace.endpos)
			sv_phys.SV_LinkEdict(ent)
			SET_EF(prog, ent, "flags", orflag(EF(prog, ent, "flags"), FL_ONGROUND))
			-- trace.ent is set (at least the world) whenever fraction < 1
			SET_EI(prog, ent, "groundentity", trace.ent or 0)
			SET_G_FLOAT(prog, OFS_RETURN, 1)
			-- if support is destroyed, keep suspended (gross hack for floating items in various maps)
			prog.ed_suspendedinairflag = prog.ed_suspendedinairflag or {}
			prog.ed_suspendedinairflag[ent] = true
		end
	end
end
PORTED.VM_SV_droptofloor = VM_SV_droptofloor

-- bspfile.h L128-133, L191-196
local CONTENTS_EMPTY, CONTENTS_SOLID, CONTENTS_WATER, CONTENTS_SLIME, CONTENTS_LAVA, CONTENTS_SKY =
	-1, -2, -3, -4, -5, -6
local SUPERCONTENTS_SOLID, SUPERCONTENTS_WATER, SUPERCONTENTS_SLIME = 0x01, 0x02, 0x04
local SUPERCONTENTS_LAVA, SUPERCONTENTS_SKY, SUPERCONTENTS_BODY = 0x08, 0x10, 0x20

-- port: model_brush.c Mod_Q1BSP_NativeContentsFromSuperContents L663-676 @xonotic-v0.8.6
-- (not in engine/model_brush.luau yet; kept here until it is)
local function Mod_Q1BSP_NativeContentsFromSuperContents(supercontents: number): number
	if bit32.band(supercontents, bit32.bor(SUPERCONTENTS_SOLID, SUPERCONTENTS_BODY)) ~= 0 then
		return CONTENTS_SOLID
	end
	if bit32.band(supercontents, SUPERCONTENTS_SKY) ~= 0 then
		return CONTENTS_SKY
	end
	if bit32.band(supercontents, SUPERCONTENTS_LAVA) ~= 0 then
		return CONTENTS_LAVA
	end
	if bit32.band(supercontents, SUPERCONTENTS_SLIME) ~= 0 then
		return CONTENTS_SLIME
	end
	if bit32.band(supercontents, SUPERCONTENTS_WATER) ~= 0 then
		return CONTENTS_WATER
	end
	return CONTENTS_EMPTY
end
svvm_cmds.Mod_Q1BSP_NativeContentsFromSuperContents = Mod_Q1BSP_NativeContentsFromSuperContents

-- port: svvm_cmds.c VM_SV_pointcontents L1264-1270 @xonotic-v0.8.6
local function VM_SV_pointcontents(prog: any)
	SAFEPARMCOUNT(prog, 1, "VM_SV_pointcontents")
	local point = G_VECTOR(prog, OFS_PARM0)
	SET_G_FLOAT(prog, OFS_RETURN, Mod_Q1BSP_NativeContentsFromSuperContents(SVPHYS().SV_PointSuperContents(point)))
end
PORTED.VM_SV_pointcontents = VM_SV_pointcontents

-- monster movement (engine/sv_move.luau; required inside the builtins: sv_move -> sv_phys -> sv_main -> svvm_cmds)
local FL_FLY, FL_SWIM = 1, 2 -- server.h L367-368
local M_PI = math.pi -- mathlib.h L28

--[[
===============
VM_SV_walkmove

float(float yaw, float dist[, settrace]) walkmove
===============
]]
-- port: svvm_cmds.c VM_SV_walkmove L1072-1120 @xonotic-v0.8.6
local function VM_SV_walkmove(prog: any)
	local move = { 0, 0, 0 }

	SAFEPARMCOUNTRANGE(prog, 2, 3, "VM_SV_walkmove")

	-- assume failure if it returns early
	SET_G_FLOAT(prog, OFS_RETURN, 0)

	local ent = buffer.readi32(prog.globals, GlobalOfs(prog, "self") * 4)
	if ent == 0 then
		prvm_cmds.VM_Warning(prog, "walkmove: can not modify world entity\n")
		return
	end
	if prog.ed_free[ent] then
		prvm_cmds.VM_Warning(prog, "walkmove: can not modify free entity\n")
		return
	end
	local yaw = G_FLOAT(prog, OFS_PARM0)
	local dist = G_FLOAT(prog, OFS_PARM1)
	local settrace = prog.argc >= 3 and G_FLOAT(prog, OFS_PARM2) ~= 0

	if bit32.band(toint(EF(prog, ent, "flags")), bit32.bor(FL_ONGROUND, FL_FLY, FL_SWIM)) == 0 then
		return
	end

	-- float * M_PI (double) * 2 / 360 in double, stored into the float yaw
	yaw = R(yaw * M_PI * 2 / 360)

	-- cos / sin take and return double; * dist (double), stored float
	move[1] = R(libm.cos(yaw) * dist)
	move[2] = R(libm.sin(yaw) * dist)
	move[3] = 0

	-- save program state, because SV_movestep may call other progs
	local oldf = prog.xfunction
	local oldself = buffer.readi32(prog.globals, GlobalOfs(prog, "self") * 4)

	SET_G_FLOAT(prog, OFS_RETURN, if SVMOVE().SV_movestep(ent, move, true, false, settrace) then 1 else 0)

	-- restore program state
	prog.xfunction = oldf
	buffer.writei32(prog.globals, GlobalOfs(prog, "self") * 4, oldself)
end
PORTED.VM_SV_walkmove = VM_SV_walkmove

--[[
=============
VM_SV_checkbottom
=============
]]
-- port: svvm_cmds.c VM_SV_checkbottom L1253-1257 @xonotic-v0.8.6
local function VM_SV_checkbottom(prog: any)
	SAFEPARMCOUNT(prog, 1, "VM_SV_checkbottom")
	SET_G_FLOAT(prog, OFS_RETURN, if SVMOVE().SV_CheckBottom(G_INT(prog, OFS_PARM0)) then 1 else 0)
end
PORTED.VM_SV_checkbottom = VM_SV_checkbottom

-- port: svvm_cmds.c VM_SV_tracetoss L750-771 @xonotic-v0.8.6
-- (SV_Trace_Toss, svvm_cmds.c L703-748, is in engine/sv_phys.luau for now: it needs that module's movers and
-- sv_phys requires this module, so it cannot be called from here at load time)
local function VM_SV_tracetoss(prog: any)
	SAFEPARMCOUNT(prog, 2, "VM_SV_tracetoss")

	local ent = G_INT(prog, OFS_PARM0)
	if ent == 0 then
		prvm_cmds.VM_Warning(prog, "tracetoss: can not use world entity\n")
		return
	end
	local ignore = G_INT(prog, OFS_PARM1)

	local trace = SVPHYS().SV_Trace_Toss(prog, ent, ignore)

	prvm_cmds.VM_SetTraceGlobals(prog, trace)
end
PORTED.VM_SV_tracetoss = VM_SV_tracetoss

-- #67 movetogoal: sv_move.c VM_SV_MoveToGoal (engine/sv_move.luau)
PORTED.VM_SV_MoveToGoal = function(prog: any)
	SVMOVE().VM_SV_MoveToGoal(prog)
end

local notported: { [string]: boolean } = {}
local function NOT_YET_PORTED(what: string)
	if not notported[what] then
		notported[what] = true
		print("NOT YET PORTED: " .. what)
	end
end

--[[
===============================================================================

MESSAGE WRITING

===============================================================================

	svs.clients is host_cmd.svs.clients (0-based: svs.clients[i] is C svs.clients + i; nil = zeroed memory); a
	client's netconnection is a table whose `message` is its sizebuf_t (nil netconnection = NULL). Nothing
	creates netconnections yet (M6-NET), so MSG_ONE takes the "non-client" branch until clients connect.
	sv.writeentitiestoclient_msg is the sizebuf_t * the entity sender points at the message being built (nil =
	NULL, as it is outside SendEntity calls in this port).
]]
local MSG_BROADCAST = 0 -- unreliable to all
local MSG_ONE = 1 -- reliable to one (msg_entity)
local MSG_ALL = 2 -- reliable to all
local MSG_INIT = 3 -- write to the init string
local MSG_ENTITY = 5

-- port: svvm_cmds.c WriteDest L1385-1421 @xonotic-v0.8.6
local function WriteDest(prog: any): common.SizeBuf
	local entnum
	local dest
	local ent
	local sv = server.sv :: any
	local svs = host_cmd.svs :: any

	dest = toint(G_FLOAT(prog, OFS_PARM0))
	if dest == MSG_BROADCAST then
		return sv.datagram
	elseif dest == MSG_ONE then
		ent = G_INT(prog, GlobalOfs(prog, "msg_entity")) -- PRVM_PROG_TO_EDICT(PRVM_serverglobaledict(msg_entity))
		entnum = ent -- PRVM_NUM_FOR_EDICT
		local client = if svs.clients then svs.clients[entnum - 1] else nil
		if
			entnum < 1
			or entnum > svs.maxclients
			or not (client and client.active)
			or not (client and client.netconnection)
		then
			prvm_cmds.VM_Warning(prog, "WriteDest: tried to write to non-client\n")
			return sv.reliable_datagram
		else
			return client.netconnection.message
		end
	elseif dest == MSG_ALL then
		return sv.reliable_datagram
	elseif dest == MSG_INIT then
		return sv.signon
	elseif dest == MSG_ENTITY then
		local msg = sv.writeentitiestoclient_msg
		if msg == nil then
			-- the C returns the NULL pointer and the MSG_Write* call after it dereferences it
			error("WriteDest: MSG_ENTITY outside an entity send (sv.writeentitiestoclient_msg is NULL)", 0)
		end
		return msg
	else
		prvm_cmds.VM_Warning(prog, "WriteDest: bad destination\n")
		-- (falls through to case MSG_ALL)
		return sv.reliable_datagram
	end

	--return NULL;
end

-- port: svvm_cmds.c VM_SV_WriteByte L1423-1427 @xonotic-v0.8.6
local function VM_SV_WriteByte(prog: any)
	SAFEPARMCOUNT(prog, 2, "VM_SV_WriteByte")
	common.MSG_WriteByte(WriteDest(prog), toint(G_FLOAT(prog, OFS_PARM1)))
end
PORTED.VM_SV_WriteByte = VM_SV_WriteByte

-- port: svvm_cmds.c VM_SV_WriteChar L1429-1433 @xonotic-v0.8.6
local function VM_SV_WriteChar(prog: any)
	SAFEPARMCOUNT(prog, 2, "VM_SV_WriteChar")
	common.MSG_WriteChar(WriteDest(prog), toint(G_FLOAT(prog, OFS_PARM1)))
end
PORTED.VM_SV_WriteChar = VM_SV_WriteChar

-- port: svvm_cmds.c VM_SV_WriteShort L1435-1439 @xonotic-v0.8.6
local function VM_SV_WriteShort(prog: any)
	SAFEPARMCOUNT(prog, 2, "VM_SV_WriteShort")
	common.MSG_WriteShort(WriteDest(prog), toint(G_FLOAT(prog, OFS_PARM1)))
end
PORTED.VM_SV_WriteShort = VM_SV_WriteShort

-- port: svvm_cmds.c VM_SV_WriteLong L1441-1445 @xonotic-v0.8.6
local function VM_SV_WriteLong(prog: any)
	SAFEPARMCOUNT(prog, 2, "VM_SV_WriteLong")
	common.MSG_WriteLong(WriteDest(prog), toint(G_FLOAT(prog, OFS_PARM1)))
end
PORTED.VM_SV_WriteLong = VM_SV_WriteLong

-- port: svvm_cmds.c VM_SV_WriteAngle L1447-1451 @xonotic-v0.8.6
local function VM_SV_WriteAngle(prog: any)
	SAFEPARMCOUNT(prog, 2, "VM_SV_WriteAngle")
	common.MSG_WriteAngle(WriteDest(prog), G_FLOAT(prog, OFS_PARM1), server.sv.protocol)
end
PORTED.VM_SV_WriteAngle = VM_SV_WriteAngle

-- port: svvm_cmds.c VM_SV_WriteCoord L1453-1457 @xonotic-v0.8.6
local function VM_SV_WriteCoord(prog: any)
	SAFEPARMCOUNT(prog, 2, "VM_SV_WriteCoord")
	common.MSG_WriteCoord(WriteDest(prog), G_FLOAT(prog, OFS_PARM1), server.sv.protocol)
end
PORTED.VM_SV_WriteCoord = VM_SV_WriteCoord

-- port: svvm_cmds.c VM_SV_WriteString L1459-1463 @xonotic-v0.8.6
local function VM_SV_WriteString(prog: any)
	SAFEPARMCOUNT(prog, 2, "VM_SV_WriteString")
	common.MSG_WriteString(WriteDest(prog), G_STRING(prog, OFS_PARM1))
end
PORTED.VM_SV_WriteString = VM_SV_WriteString

-- port: svvm_cmds.c VM_SV_WriteUnterminatedString L1465-1469 @xonotic-v0.8.6
local function VM_SV_WriteUnterminatedString(prog: any)
	SAFEPARMCOUNT(prog, 2, "VM_SV_WriteUnterminatedString")
	common.MSG_WriteUnterminatedString(WriteDest(prog), G_STRING(prog, OFS_PARM1))
end
PORTED.VM_SV_WriteUnterminatedString = VM_SV_WriteUnterminatedString

-- port: svvm_cmds.c VM_SV_WriteEntity L1472-1476 @xonotic-v0.8.6
local function VM_SV_WriteEntity(prog: any)
	SAFEPARMCOUNT(prog, 2, "VM_SV_WriteEntity")
	common.MSG_WriteShort(WriteDest(prog), G_INT(prog, OFS_PARM1)) -- PRVM_G_EDICTNUM
end
PORTED.VM_SV_WriteEntity = VM_SV_WriteEntity

-- writes a picture as at most size bytes of data
-- message:
--   IMGNAME \0 SIZE(short) IMGDATA
-- if failed to read/compress:
--   IMGNAME \0 \0 \0
--#501 void(float dest, string name, float maxsize) WritePicture (DP_SV_WRITEPICTURE))
-- port: svvm_cmds.c VM_SV_WritePicture L1484-1509 @xonotic-v0.8.6
-- NOT YET PORTED: Image_Compress (image.c: load the image, JPEG-encode it into at most size bytes). Until it is
-- ported it logs once and reports failure, so the placeholder is written (the C writes the picture data when
-- the image loads and compresses).
local function VM_SV_WritePicture(prog: any)
	local imgname
	local size

	SAFEPARMCOUNT(prog, 3, "VM_SV_WritePicture")

	imgname = G_STRING(prog, OFS_PARM1)
	-- size = (size_t) PRVM_G_FLOAT(OFS_PARM2): gcc on x86-64 converts a float below 2^63 with the signed
	-- cvttss2si, so values <= -1 and NaN become huge unsigned numbers (clamped to 65535 below)
	local f = G_FLOAT(prog, OFS_PARM2)
	size = if f ~= f or f <= -1 then math.huge else math.floor(f) -- (math.huge: any value > 65535)
	if size > 65535 then
		size = 65535
	end

	common.MSG_WriteString(WriteDest(prog), imgname)
	NOT_YET_PORTED("Image_Compress (image.c) in VM_SV_WritePicture: the placeholder is written")
	local compressed = false -- Image_Compress(imgname, size, &buf, &size)
	if compressed then
		-- actual picture: MSG_WriteShort(WriteDest(prog), (int)size); SZ_Write(WriteDest(prog), buf, (int)size)
		common.MSG_WriteShort(WriteDest(prog), size)
	else
		-- placeholder
		common.MSG_WriteShort(WriteDest(prog), 0)
	end
end
PORTED.VM_SV_WritePicture = VM_SV_WritePicture

--void(entity e, entity tagentity, string tagname) setattachment = #443; // attachs e to a tag on tagentity (note: use "" to attach to entity origin/angles instead of a tag)
-- port: svvm_cmds.c VM_SV_setattachment L2354-2394 @xonotic-v0.8.6
-- Mod_Alias_GetTagIndexForName (model_alias.c L585-599) comes from engine/model_alias.luau, required on first
-- use. While that module or function is missing it logs NOT YET PORTED once and the tag index is 0, the
-- result the C function gives for a model with no bone and no tag of that name (it then prints the "could not
-- find it" developer message, as C does).
local function Mod_Alias_GetTagIndexForName(model: any, skin: number, tagname: string): number
	local ok, model_alias = pcall(MODELALIAS)
	local fn = if ok and type(model_alias) == "table" then model_alias.Mod_Alias_GetTagIndexForName else nil
	if not fn then
		NOT_YET_PORTED("Mod_Alias_GetTagIndexForName (model_alias.c) in VM_SV_setattachment: tag index 0")
		return 0
	end
	return fn(model, skin, tagname)
end

local function VM_SV_setattachment(prog: any)
	local e = G_INT(prog, OFS_PARM0)
	local tagentity = G_INT(prog, OFS_PARM1)
	local tagname = G_STRING(prog, OFS_PARM2)
	local model
	local tagindex
	SAFEPARMCOUNT(prog, 3, "VM_SV_setattachment")

	if e == 0 then
		prvm_cmds.VM_Warning(prog, "setattachment: can not modify world entity\n")
		return
	end
	if prog.ed_free[e] then
		prvm_cmds.VM_Warning(prog, "setattachment: can not modify free entity\n")
		return
	end

	-- (tagentity == NULL: PRVM_G_EDICT is never NULL; tagentity = prog->edicts)

	tagindex = 0

	if tagentity ~= 0 and tagname ~= "" then
		model = SVMAIN().SV_GetModelFromEdict(tagentity) -- sv_main requires this module
		if model then
			-- (int)skin converted to the unsigned int parameter
			tagindex = Mod_Alias_GetTagIndexForName(model, toint(EF(prog, tagentity, "skin")) % 4294967296, tagname)
			if tagindex == 0 then
				console.Con_DPrintf(
					'setattachment(edict %i, edict %i, string "%s"): tried to find tag named "%s" on entity %i (model "%s") but could not find it\n',
					e,
					tagentity,
					tagname,
					tagname,
					tagentity,
					model.name
				)
			end
		else
			console.Con_DPrintf(
				'setattachment(edict %i, edict %i, string "%s"): tried to find tag named "%s" on entity %i but it has no model\n',
				e,
				tagentity,
				tagname,
				tagname,
				tagentity
			)
		end
	end

	SET_EI(prog, e, "tag_entity", tagentity) -- PRVM_EDICT_TO_PROG(tagentity)
	SET_EF(prog, e, "tag_index", tagindex)
end
PORTED.VM_SV_setattachment = VM_SV_setattachment

-- DP_MD3_TAGINFO extension coded by VorteX
-- port: svvm_cmds.c SV_GetTagIndex L2399-2408 @xonotic-v0.8.6
local function SV_GetTagIndex(prog: any, e: number, tagname: string): number
	local i = toint(EF(prog, e, "modelindex"))
	if i < 1 or i >= 8192 then -- MAX_MODELS
		return -1
	end

	return Mod_Alias_GetTagIndexForName(
		SVMAIN().SV_GetModelByIndex(i),
		toint(EF(prog, e, "skin")) % 4294967296,
		tagname
	)
end

--float(entity ent, string tagname) gettagindex;
-- port: svvm_cmds.c VM_SV_gettagindex L2561-2594 @xonotic-v0.8.6
local function VM_SV_gettagindex(prog: any)
	SAFEPARMCOUNT(prog, 2, "VM_SV_gettagindex")

	local ent = G_INT(prog, OFS_PARM0)
	local tag_name = G_STRING(prog, OFS_PARM1)

	if ent == 0 then
		prvm_cmds.VM_Warning(prog, string.format("VM_SV_gettagindex(entity #%i): can't affect world entity\n", ent))
		return
	end
	if prog.ed_free[ent] then
		prvm_cmds.VM_Warning(prog, string.format("VM_SV_gettagindex(entity #%i): can't affect free entity\n", ent))
		return
	end

	local tag_index = 0
	if not SVMAIN().SV_GetModelFromEdict(ent) then
		console.Con_DPrintf("VM_SV_gettagindex(entity #%i): null or non-precached model\n", ent)
	else
		tag_index = SV_GetTagIndex(prog, ent, tag_name)
		if tag_index == 0 then
			if cvarint("developer_extra", 0) ~= 0 then
				console.Con_DPrintf('VM_SV_gettagindex(entity #%i): tag "%s" not found\n', ent, tag_name)
			end
		end
	end
	SET_G_FLOAT(prog, OFS_RETURN, tag_index)
end
PORTED.VM_SV_gettagindex = VM_SV_gettagindex

-- #276 float(float modlindex, string framename) frameforname = #276; // (FTE_CSQC_SKELETONOBJECTS) finds number of a specified frame in the animation, returns -1 if no match found
-- port: svvm_cmds.c VM_SV_frameforname L3158-3175 @xonotic-v0.8.6
local function VM_SV_frameforname(prog: any)
	local modelindex = toint(G_FLOAT(prog, OFS_PARM0))
	local model = SVMAIN().SV_GetModelByIndex(modelindex)
	local name = string.lower(G_STRING(prog, OFS_PARM1))
	SET_G_FLOAT(prog, OFS_RETURN, -1)
	if not model or not model.animscenes then
		return
	end
	for i = 0, model.numframes - 1 do
		if string.lower(model.animscenes[i + 1].name) == name then
			SET_G_FLOAT(prog, OFS_RETURN, i)
			break
		end
	end
end
PORTED.VM_SV_frameforname = VM_SV_frameforname

-- #277 float(float modlindex, float framenum) frameduration = #277; // (FTE_CSQC_SKELETONOBJECTS) returns the intended play time (in seconds) of the specified framegroup, if it does not exist the result is 0, if it is a single frame it may be a small value around 0.1 or 0.
-- port: svvm_cmds.c VM_SV_frameduration L3178-3188 @xonotic-v0.8.6
local function VM_SV_frameduration(prog: any)
	local modelindex = toint(G_FLOAT(prog, OFS_PARM0))
	local model = SVMAIN().SV_GetModelByIndex(modelindex)
	local framenum = toint(G_FLOAT(prog, OFS_PARM1))
	SET_G_FLOAT(prog, OFS_RETURN, 0)
	if not model or not model.animscenes or framenum < 0 or framenum >= model.numframes then
		return
	end
	local scene = model.animscenes[framenum + 1]
	if scene.framerate ~= 0 then
		SET_G_FLOAT(prog, OFS_RETURN, R(scene.framecount / scene.framerate))
	end
end
PORTED.VM_SV_frameduration = VM_SV_frameduration

local svc_setpause = 24 -- protocol.h L220: [byte] on / off

-- #531 void(float pause) setpause
-- port: svvm_cmds.c VM_SV_setpause L2867-2882 @xonotic-v0.8.6
local function VM_SV_setpause(prog: any)
	local sv = server.sv :: any
	local pauseValue
	pauseValue = toint(G_FLOAT(prog, OFS_PARM0))
	if pauseValue ~= 0 then --pause the game
		sv.paused = true
		sv.pausedstart = prvm_edict.realtime
	else --disable pause, in case it was enabled
		if sv.paused then
			sv.paused = false
			sv.pausedstart = 0
		end
	end
	-- send notification to all clients
	common.MSG_WriteByte(sv.reliable_datagram, svc_setpause)
	common.MSG_WriteByte(sv.reliable_datagram, if sv.paused then 1 else 0)
end
PORTED.VM_SV_setpause = VM_SV_setpause

-- port: svvm_cmds.c SV_GetEntityMatrix L2432-2448 @xonotic-v0.8.6
-- (out: a matrixlib matrix4x4_t; the Matrix4x4_CreateFromQuakeEntity parameters are doubles: the float values
-- are passed exactly, the float products are rounded first)
function svvm_cmds.SV_GetEntityMatrix(prog: any, ent: number, out: any, viewmatrix: boolean)
	local matrixlib = MATRIXLIB()
	local scale
	local pitchsign = 1

	scale = EF(prog, ent, "scale")
	if scale == 0 then
		scale = 1.0
	end

	if viewmatrix then
		-- cl_viewmodel_scale (view.c) is registered by V_Init from CL_Init, which a dedicated server never runs:
		-- the unregistered cvar_t has value 0
		local c = cvar.Cvar_FindVar("cl_viewmodel_scale")
		local cl_viewmodel_scale = if c then c.value else 0
		local origin, view_ofs, v_angle = EV(prog, ent, "origin"), EV(prog, ent, "view_ofs"), EV(prog, ent, "v_angle")
		matrixlib.Matrix4x4_CreateFromQuakeEntity(
			out,
			origin[1],
			origin[2],
			R(origin[3] + view_ofs[3]),
			v_angle[1],
			v_angle[2],
			v_angle[3],
			R(scale * cl_viewmodel_scale)
		)
	else
		pitchsign = SVPHYS().SV_GetPitchSign(prog, ent) -- sv_phys requires this module
		local origin, angles = EV(prog, ent, "origin"), EV(prog, ent, "angles")
		matrixlib.Matrix4x4_CreateFromQuakeEntity(
			out,
			origin[1],
			origin[2],
			origin[3],
			R(pitchsign * angles[1]),
			angles[2],
			angles[3],
			scale
		)
	end
end

--[[
===============================================================================

	Client builtins (sprint, centerprint, stuffcmd, setspawnparms, setcolor, clientcommand, dropclient,
	spawnclient, clienttype), the sound / effect builtins and gettaginfo. host_client is server.host_client;
	svs.clients[i] is client i (0-based, engine/sv_main.luau). sv_main / host are required on use (sv_main requires
	this module). A bot has no netconnection: the C returns before writing to it, as here.

===============================================================================
]]
local cmdmod = require("./cmd")
local VM_STRINGTEMP_LENGTH = 16384 -- prvm_cmds.h (MAX_INPUTLINE)
local svc_print, svc_centerprint = 8, 26 -- protocol.h L196, L223
local svc_trailparticles, svc_pointparticles, svc_pointparticles1 = 60, 61, 62 -- protocol.h L254-256
-- sound.h L37-41
local CHANNELFLAG_RELIABLE, CHANNELFLAG_FORCELOOP, CHANNELFLAG_PAUSED, CHANNELFLAG_FULLVOLUME = 1, 2, 8, 16
local NUM_SPAWN_PARMS = 16 -- server.h L185

local function svs_clients(): any -- svs (host_cmd.svs) with its clients table
	local svs = host_cmd.svs :: any
	svs.clients = svs.clients or {}
	return svs
end
-- svs.clients[i].active (a slot not created yet is zeroed memory)
local function client_active(svs: any, i: number): boolean
	local c = svs.clients[i]
	return c ~= nil and c.active == true
end
-- svs.clients + i (created zeroed on first use, see engine/sv_main.luau)
local function svs_client(i: number): any
	return SVMAIN().client(i)
end

--[[
=================
VM_SV_sprint

single print to a specific client

sprint(clientent, value)
=================
]]
-- port: svvm_cmds.c VM_SV_sprint L369-399 @xonotic-v0.8.6
local function VM_SV_sprint(prog: any)
	local c
	local entnum
	local s
	local svs = svs_clients()

	SAFEPARMCOUNTRANGE(prog, 2, 8, "VM_SV_sprint")

	s = prvm_cmds.VM_VarString(prog, 1, VM_STRINGTEMP_LENGTH)

	entnum = G_INT(prog, OFS_PARM0) -- PRVM_G_EDICTNUM
	-- LordHavoc: div0 requested that sprintto world  operate like print
	if entnum == 0 then
		console.Con_Print(s)
		return
	end

	if entnum < 1 or entnum > svs.maxclients or not client_active(svs, entnum - 1) then
		prvm_cmds.VM_Warning(prog, "tried to centerprint to a non-client\n")
		return
	end

	c = svs.clients[entnum - 1]
	if not c.netconnection then
		return
	end

	common.MSG_WriteChar(c.netconnection.message, svc_print)
	common.MSG_WriteString(c.netconnection.message, s)
end
PORTED.VM_SV_sprint = VM_SV_sprint

--[[
=================
VM_SV_centerprint

single print to a specific client

centerprint(clientent, value)
=================
]]
-- port: svvm_cmds.c VM_SV_centerprint L411-434 @xonotic-v0.8.6
local function VM_SV_centerprint(prog: any)
	local c
	local entnum
	local s
	local svs = svs_clients()

	SAFEPARMCOUNTRANGE(prog, 2, 8, "VM_SV_centerprint")

	entnum = G_INT(prog, OFS_PARM0) -- PRVM_G_EDICTNUM

	if entnum < 1 or entnum > svs.maxclients or not client_active(svs, entnum - 1) then
		prvm_cmds.VM_Warning(prog, "tried to centerprint to a non-client\n")
		return
	end

	c = svs.clients[entnum - 1]
	if not c.netconnection then
		return
	end

	s = prvm_cmds.VM_VarString(prog, 1, VM_STRINGTEMP_LENGTH)
	common.MSG_WriteChar(c.netconnection.message, svc_centerprint)
	common.MSG_WriteString(c.netconnection.message, s)
end
PORTED.VM_SV_centerprint = VM_SV_centerprint

--[[
=================
VM_SV_particle

particle(origin, color, count)
=================
]]
-- port: svvm_cmds.c VM_SV_particle L443-456 @xonotic-v0.8.6
local function VM_SV_particle(prog: any)
	local org, dir
	local color
	local count

	SAFEPARMCOUNT(prog, 4, "VM_SV_particle")

	org = G_VECTOR(prog, OFS_PARM0)
	dir = G_VECTOR(prog, OFS_PARM1)
	color = toint(G_FLOAT(prog, OFS_PARM2))
	count = toint(G_FLOAT(prog, OFS_PARM3))
	SVMAIN().SV_StartParticle(org, dir, color, count)
end
PORTED.VM_SV_particle = VM_SV_particle

--[[
=================
VM_SV_sound

Each entity can have eight independant sound sources, like voice,
weapon, feet, etc.

Channel 0 is an auto-allocate channel, the others override anything
already running on that entity/channel pair.

An attenuation of 0 will play full volume everywhere in the level.
Larger attenuations will drop off.

=================
]]
-- port: svvm_cmds.c VM_SV_sound L522-586 @xonotic-v0.8.6
local function VM_SV_sound(prog: any)
	local sample
	local channel
	local entity
	local nvolume
	local flags
	local attenuation
	local pitchchange

	SAFEPARMCOUNTRANGE(prog, 4, 7, "VM_SV_sound")

	entity = G_INT(prog, OFS_PARM0) -- PRVM_G_EDICT
	channel = toint(G_FLOAT(prog, OFS_PARM1))
	sample = G_STRING(prog, OFS_PARM2)
	nvolume = toint(R(G_FLOAT(prog, OFS_PARM3) * 255))
	if prog.argc < 5 then
		console.Con_DPrintf("VM_SV_sound: given only 4 parameters, expected 5, assuming attenuation = ATTN_NORMAL\n")
		attenuation = 1
	else
		attenuation = G_FLOAT(prog, OFS_PARM4)
	end
	if prog.argc < 6 then
		pitchchange = 0
	else
		pitchchange = R(G_FLOAT(prog, OFS_PARM5) * R(0.01))
	end

	if prog.argc < 7 then
		flags = 0
		if channel >= 8 and channel <= 15 then -- weird QW feature
			flags = bit32.bor(flags, CHANNELFLAG_RELIABLE)
			channel -= 8
		end
	else
		-- LordHavoc: we only let the qc set certain flags, others are off-limits
		flags = bit32.band(
			toint(G_FLOAT(prog, OFS_PARM0 + 6 * 3)),
			bit32.bor(CHANNELFLAG_RELIABLE, CHANNELFLAG_FORCELOOP, CHANNELFLAG_PAUSED, CHANNELFLAG_FULLVOLUME)
		)
	end

	if nvolume < 0 or nvolume > 255 then
		prvm_cmds.VM_Warning(prog, "SV_StartSound: volume must be in range 0-1\n")
		return
	end

	if attenuation < 0 or attenuation > 4 then
		prvm_cmds.VM_Warning(prog, "SV_StartSound: attenuation must be in range 0-4\n")
		return
	end

	channel = channel -- CHAN_USER2ENGINE(channel)

	if not (channel >= -128 and channel <= 127) then -- !IS_CHAN(channel)
		prvm_cmds.VM_Warning(prog, "SV_StartSound: channel must be in range 0-127\n")
		return
	end

	SVMAIN().SV_StartSound(
		entity,
		channel,
		sample,
		nvolume,
		attenuation,
		bit32.band(flags, CHANNELFLAG_RELIABLE) ~= 0,
		pitchchange
	)
end
PORTED.VM_SV_sound = VM_SV_sound

--[[
=================
VM_SV_pointsound

Follows the same logic as VM_SV_sound, except instead of
an entity, an origin for the sound is provided, and channel
is omitted (since no entity is being tracked).

=================
]]
-- port: svvm_cmds.c VM_SV_pointsound L598-627 @xonotic-v0.8.6
local function VM_SV_pointsound(prog: any)
	local sample
	local nvolume
	local attenuation
	local pitchchange
	local org

	SAFEPARMCOUNTRANGE(prog, 4, 5, "VM_SV_pointsound")

	org = G_VECTOR(prog, OFS_PARM0)
	sample = G_STRING(prog, OFS_PARM1)
	nvolume = toint(R(G_FLOAT(prog, OFS_PARM2) * 255))
	attenuation = G_FLOAT(prog, OFS_PARM3)
	pitchchange = if prog.argc < 5 then 0 else R(G_FLOAT(prog, OFS_PARM4) * R(0.01))

	if nvolume < 0 or nvolume > 255 then
		prvm_cmds.VM_Warning(prog, "SV_StartPointSound: volume must be in range 0-1\n")
		return
	end

	if attenuation < 0 or attenuation > 4 then
		prvm_cmds.VM_Warning(prog, "SV_StartPointSound: attenuation must be in range 0-4\n")
		return
	end

	SVMAIN().SV_StartPointSound(org, sample, nvolume, attenuation, pitchchange)
end
PORTED.VM_SV_pointsound = VM_SV_pointsound

--[[
=================
VM_SV_checkpvs

Checks if an entity is in a point's PVS.
Should be fast but can be inexact.

float checkpvs(vector viewpos, entity viewee) = #240;
=================
]]
-- port: svvm_cmds.c VM_SV_checkpvs L882-940 @xonotic-v0.8.6 (the #if 1 branch: the viewpos leaf PVS)
local function VM_SV_checkpvs(prog: any)
	local viewpos, absmin, absmax
	local viewee
	local sv = server.sv

	SAFEPARMCOUNT(prog, 2, "VM_SV_checkpvs")
	viewpos = G_VECTOR(prog, OFS_PARM0)
	viewee = G_INT(prog, OFS_PARM1) -- PRVM_G_EDICT

	if prog.ed_free[viewee] then
		prvm_cmds.VM_Warning(prog, "checkpvs: can not check free entity\n")
		SET_G_FLOAT(prog, OFS_RETURN, 4)
		return
	end

	if not sv.worldmodel or not sv.worldmodel.brush.GetPVS or not sv.worldmodel.brush.BoxTouchingPVS then
		-- no PVS support on this worldmodel... darn
		SET_G_FLOAT(prog, OFS_RETURN, 3)
		return
	end
	local pvs, pvsofs = sv.worldmodel.brush.GetPVS(sv.worldmodel, viewpos)
	if not pvs then
		-- viewpos isn't in any PVS... darn
		SET_G_FLOAT(prog, OFS_RETURN, 2)
		return
	end
	absmin = EV(prog, viewee, "absmin")
	absmax = EV(prog, viewee, "absmax")
	SET_G_FLOAT(prog, OFS_RETURN, sv.worldmodel.brush.BoxTouchingPVS(sv.worldmodel, pvs, pvsofs, absmin, absmax))
end
PORTED.VM_SV_checkpvs = VM_SV_checkpvs

--[[
=================
VM_SV_stuffcmd

Sends text over to the client's execution buffer

stuffcmd (clientent, value, ...)
=================
]]
-- port: svvm_cmds.c VM_SV_stuffcmd L952-973 @xonotic-v0.8.6
local function VM_SV_stuffcmd(prog: any)
	local entnum
	local old
	local s
	local svs = svs_clients()

	SAFEPARMCOUNTRANGE(prog, 2, 8, "VM_SV_stuffcmd")

	entnum = G_INT(prog, OFS_PARM0) -- PRVM_G_EDICTNUM
	if entnum < 1 or entnum > svs.maxclients or not client_active(svs, entnum - 1) then
		prvm_cmds.VM_Warning(prog, "Can't stuffcmd to a non-client\n")
		return
	end

	s = prvm_cmds.VM_VarString(prog, 1, VM_STRINGTEMP_LENGTH)

	old = server.host_client
	server.host_client = svs.clients[entnum - 1]
	HOST().Host_ClientCommands("%s", s)
	server.host_client = old
end
PORTED.VM_SV_stuffcmd = VM_SV_stuffcmd

--[[
==============
VM_SV_setspawnparms
==============
]]
-- port: svvm_cmds.c VM_SV_setspawnparms L1579-1599 @xonotic-v0.8.6
local function VM_SV_setspawnparms(prog: any)
	local ent
	local i
	local c
	local svs = svs_clients()

	SAFEPARMCOUNT(prog, 1, "VM_SV_setspawnparms")

	ent = G_INT(prog, OFS_PARM0) -- PRVM_G_EDICT
	i = ent -- PRVM_NUM_FOR_EDICT(ent)
	if i < 1 or i > svs.maxclients or not client_active(svs, i - 1) then
		console.Con_Print("tried to setspawnparms on a non-client\n")
		return
	end

	-- copy spawn parms out of the client_t
	c = svs.clients[i - 1]
	local parm1 = GlobalOfs(prog, "parm1")
	for j = 0, NUM_SPAWN_PARMS - 1 do
		buffer.writef32(prog.globals, (parm1 + j) * 4, c.spawn_parms[j] or 0)
	end
end
PORTED.VM_SV_setspawnparms = VM_SV_setspawnparms

--[[
=================
VM_SV_setcolor

sets the color of a client and broadcasts the update to all connected clients

setcolor(clientent, value)
=================
]]
-- port: svvm_cmds.c VM_SV_setcolor L1790-1820 @xonotic-v0.8.6
local function VM_SV_setcolor(prog: any)
	local c
	local entnum, i
	local svs = svs_clients()

	SAFEPARMCOUNT(prog, 2, "VM_SV_setcolor")
	entnum = G_INT(prog, OFS_PARM0) -- PRVM_G_EDICTNUM
	i = toint(G_FLOAT(prog, OFS_PARM1))

	if entnum < 1 or entnum > svs.maxclients or not client_active(svs, entnum - 1) then
		console.Con_Print("tried to setcolor a non-client\n")
		return
	end

	c = svs.clients[entnum - 1]
	if c.edict then
		SET_EF(prog, c.edict, "clientcolors", i)
		SET_EF(prog, c.edict, "team", bit32.band(i, 15) + 1)
	end
	c.colors = i
	if c.old_colors ~= c.colors then
		c.old_colors = c.colors
		-- send notification to all clients
		local sv = server.sv
		common.MSG_WriteByte(sv.reliable_datagram, 17) -- svc_updatecolors
		common.MSG_WriteByte(sv.reliable_datagram, entnum - 1) -- client - svs.clients
		common.MSG_WriteByte(sv.reliable_datagram, c.colors)
	end
end
PORTED.VM_SV_setcolor = VM_SV_setcolor

--void(entity e, string s) clientcommand = #440; // executes a command string as if it came from the specified client
--this function originally written by KrimZon, made shorter by LordHavoc
-- port: svvm_cmds.c VM_SV_clientcommand L2333-2351 @xonotic-v0.8.6
local function VM_SV_clientcommand(prog: any)
	local temp_client
	local i
	local svs = svs_clients()
	SAFEPARMCOUNT(prog, 2, "VM_SV_clientcommand")

	--find client for this entity
	i = G_INT(prog, OFS_PARM0) - 1 -- PRVM_NUM_FOR_EDICT(PRVM_G_EDICT(OFS_PARM0)) - 1
	if i < 0 or i >= svs.maxclients or not client_active(svs, i) then
		console.Con_Print("PF_clientcommand: entity is not a client\n")
		return
	end

	temp_client = server.host_client
	server.host_client = svs.clients[i]
	local cmd = cmdmod
	cmd.Cmd_ExecuteString(G_STRING(prog, OFS_PARM1), cmd.src_client, true)
	server.host_client = temp_client
end
PORTED.VM_SV_clientcommand = VM_SV_clientcommand

-- port: matrixlib.c Matrix4x4_ToVectors L941-970 @xonotic-v0.8.6 (#else branch; matrixlib.luau lacks it)
local function Matrix4x4_ToVectors(m: any, vx: { number }, vy: { number }, vz: { number }, t: { number })
	local a = m.m
	vx[1], vx[2], vx[3] = a[1][1], a[2][1], a[3][1]
	vy[1], vy[2], vy[3] = a[1][2], a[2][2], a[3][2]
	vz[1], vz[2], vz[3] = a[1][3], a[2][3], a[3][3]
	t[1], t[2], t[3] = a[1][4], a[2][4], a[3][4]
end

local function mcopy(out: any, in_: any) -- *out = *in (matrix4x4_t assignment)
	for r = 1, 4 do
		local o, i = out.m[r], in_.m[r]
		o[1], o[2], o[3], o[4] = i[1], i[2], i[3], i[4]
	end
end

-- the three frame blend calls of the tag functions, on ent's priv.server data (engine/prvm_cmds.luau)
local function UpdateFrameBlend(prog: any, ent: number, model: any): (any, any)
	local framegroupblend, frameblend, skeleton = prvm_cmds.EdictFrameBlend(prog, ent)
	prvm_cmds.VM_GenerateFrameGroupBlend(prog, framegroupblend, ent)
	prvm_cmds.VM_FrameBlendFromFrameGroupBlend(frameblend, framegroupblend, model, server.sv.time)
	prvm_cmds.VM_UpdateEdictSkeleton(prog, ent, model, frameblend)
	return frameblend, skeleton
end

-- port: svvm_cmds.c SV_GetExtendedTagInfo L2410-2430 @xonotic-v0.8.6
-- (returns r, *parentindex, *tagname; tag_localmatrix written in place)
local function SV_GetExtendedTagInfo(
	prog: any,
	e: number,
	tagindex: number,
	tag_localmatrix: any
): (number, number, string?)
	local r
	local model
	local parentindex, tagname = 0, nil

	-- *tagname = NULL; *parentindex = 0;
	MATRIXLIB().Matrix4x4_CreateIdentity(tag_localmatrix)

	model = if tagindex >= 0 then SVMAIN().SV_GetModelFromEdict(e) else nil
	if tagindex >= 0 and model and (model.num_bones or 0) ~= 0 then
		local _, frameblend, skeleton = prvm_cmds.EdictFrameBlend(prog, e)
		local pi, tn
		r, pi, tn = MODELALIAS().Mod_Alias_GetExtendedTagInfoForIndex(
			model,
			toint(EF(prog, e, "skin")),
			frameblend,
			skeleton,
			tagindex - 1,
			tag_localmatrix
		)
		if pi ~= nil then
			parentindex = pi
		end
		if tn ~= nil then
			tagname = tn
		end

		if r == 0 then -- success?
			parentindex += 1
		end

		return r, parentindex, tagname
	end

	return 1, parentindex, tagname
end

-- port: svvm_cmds.c SV_GetEntityLocalTagMatrix L2450-2462 @xonotic-v0.8.6
local function SV_GetEntityLocalTagMatrix(prog: any, ent: number, tagindex: number, out: any): number
	local model
	model = if tagindex >= 0 then SVMAIN().SV_GetModelFromEdict(ent) else nil
	if tagindex >= 0 and model and model.animscenes then
		local frameblend, skeleton = UpdateFrameBlend(prog, ent, model)
		return MODELALIAS().Mod_Alias_GetTagMatrix(model, frameblend, skeleton, tagindex, out)
	end
	mcopy(out, MATRIXLIB().identitymatrix)
	return 0
end

-- Warnings/errors code:
-- 0 - normal (everything all-right)
-- 1 - world entity
-- 2 - free entity
-- 3 - null or non-precached model
-- 4 - no tags with requested index
-- 5 - runaway loop at attachment chain
-- port: svvm_cmds.c SV_GetTagMatrix L2474-2557 @xonotic-v0.8.6
local function SV_GetTagMatrix(prog: any, out: any, ent: number, tagindex: number): number
	local matrixlib = MATRIXLIB()
	local ret
	local modelindex, attachloop
	local entitymatrix, tagmatrix, attachmatrix = matrixlib.new(), matrixlib.new(), matrixlib.new()
	local model

	mcopy(out, matrixlib.identitymatrix) -- warnings and errors return identical matrix

	if ent == 0 then
		return 1
	end
	if prog.ed_free[ent] then
		return 2
	end

	modelindex = toint(EF(prog, ent, "modelindex"))
	if modelindex <= 0 or modelindex >= server.MAX_MODELS then
		return 3
	end

	model = SVMAIN().SV_GetModelByIndex(modelindex)

	UpdateFrameBlend(prog, ent, model)

	mcopy(tagmatrix, matrixlib.identitymatrix)
	-- DP_GFX_QUAKE3MODELTAGS, scan all chain and stop on unattached entity
	attachloop = 0
	while true do
		if attachloop >= 256 then -- prevent runaway looping
			return 5
		end
		-- apply transformation by child's tagindex on parent entity and then
		-- by parent entity itself
		ret = SV_GetEntityLocalTagMatrix(prog, ent, tagindex - 1, attachmatrix)
		if ret ~= 0 and attachloop == 0 then
			return ret
		end
		svvm_cmds.SV_GetEntityMatrix(prog, ent, entitymatrix, false)
		matrixlib.Matrix4x4_Concat(tagmatrix, attachmatrix, out)
		matrixlib.Matrix4x4_Concat(out, entitymatrix, tagmatrix)
		-- next iteration we process the parent entity
		local tag_entity = buffer.readi32(prog.edictsfields, EOFS(prog, ent, "tag_entity"))
		if tag_entity ~= 0 then
			tagindex = toint(EF(prog, ent, "tag_index"))
			ent = tag_entity -- PRVM_EDICT_NUM(PRVM_serveredictedict(ent, tag_entity))
		else
			break
		end
		attachloop += 1
	end

	-- RENDER_VIEWMODEL magic
	local viewmodelforclient = buffer.readi32(prog.edictsfields, EOFS(prog, ent, "viewmodelforclient"))
	if viewmodelforclient ~= 0 then
		mcopy(tagmatrix, out)
		ent = viewmodelforclient

		svvm_cmds.SV_GetEntityMatrix(prog, ent, entitymatrix, true)
		matrixlib.Matrix4x4_Concat(out, entitymatrix, tagmatrix)

		--[[
		// Cl_bob, ported from rendering code
		(the C keeps this block commented out: no view bob on the server)
		]]
	end
	return 0
end

local function SET_GV(prog: any, g: string, x: number, y: number, z: number) -- PRVM_serverglobalvector(g) = v
	local o = GlobalOfs(prog, g)
	if o >= 0 then
		buffer.writef32(prog.globals, o * 4, x)
		buffer.writef32(prog.globals, o * 4 + 4, y)
		buffer.writef32(prog.globals, o * 4 + 8, z)
	end
end

--vector(entity ent, float tagindex) gettaginfo;
-- port: svvm_cmds.c VM_SV_gettaginfo L2597-2652 @xonotic-v0.8.6
local function VM_SV_gettaginfo(prog: any)
	local matrixlib = MATRIXLIB()
	local e
	local tagindex
	local tag_matrix = matrixlib.new()
	local tag_localmatrix = matrixlib.new()
	local parentindex
	local tagname
	local returncode
	local forward, left, up, origin = { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 }
	local model

	SAFEPARMCOUNT(prog, 2, "VM_SV_gettaginfo")

	e = G_INT(prog, OFS_PARM0) -- PRVM_G_EDICT
	tagindex = toint(G_FLOAT(prog, OFS_PARM1))

	returncode = SV_GetTagMatrix(prog, tag_matrix, e, tagindex)
	Matrix4x4_ToVectors(tag_matrix, forward, left, up, origin)
	SET_GV(prog, "v_forward", forward[1], forward[2], forward[3])
	SET_GV(prog, "v_right", -left[1], -left[2], -left[3])
	SET_GV(prog, "v_up", up[1], up[2], up[3])
	buffer.writef32(prog.globals, OFS_RETURN * 4, origin[1])
	buffer.writef32(prog.globals, OFS_RETURN * 4 + 4, origin[2])
	buffer.writef32(prog.globals, OFS_RETURN * 4 + 8, origin[3])
	model = SVMAIN().SV_GetModelFromEdict(e)
	UpdateFrameBlend(prog, e, model)
	local _
	_, parentindex, tagname = SV_GetExtendedTagInfo(prog, e, tagindex, tag_localmatrix)
	Matrix4x4_ToVectors(tag_localmatrix, forward, left, up, origin)

	local gp = GlobalOfs(prog, "gettaginfo_parent")
	if gp >= 0 then
		buffer.writef32(prog.globals, gp * 4, parentindex)
	end
	local gn = GlobalOfs(prog, "gettaginfo_name")
	if gn >= 0 then
		buffer.writei32(prog.globals, gn * 4, if tagname then prvm_edict.PRVM_SetTempString(prog, tagname) else 0)
	end
	SET_GV(prog, "gettaginfo_forward", forward[1], forward[2], forward[3])
	SET_GV(prog, "gettaginfo_right", -left[1], -left[2], -left[3])
	SET_GV(prog, "gettaginfo_up", up[1], up[2], up[3])
	SET_GV(prog, "gettaginfo_offset", origin[1], origin[2], origin[3])

	if returncode == 1 then
		prvm_cmds.VM_Warning(prog, "gettagindex: can't affect world entity\n")
	elseif returncode == 2 then
		prvm_cmds.VM_Warning(prog, "gettagindex: can't affect free entity\n")
	elseif returncode == 3 then
		console.Con_DPrintf("SV_GetTagMatrix(entity #%i): null or non-precached model\n", e)
	elseif returncode == 4 then
		console.Con_DPrintf("SV_GetTagMatrix(entity #%i): model has no tag with requested index %i\n", e, tagindex)
	elseif returncode == 5 then
		console.Con_DPrintf("SV_GetTagMatrix(entity #%i): runaway loop at attachment chain\n", e)
	end
end
PORTED.VM_SV_gettaginfo = VM_SV_gettaginfo

--void(entity clent) dropclient (DP_SV_DROPCLIENT)
-- port: svvm_cmds.c VM_SV_dropclient L2655-2675 @xonotic-v0.8.6
local function VM_SV_dropclient(prog: any)
	local clientnum
	local oldhostclient
	local svs = svs_clients()
	SAFEPARMCOUNT(prog, 1, "VM_SV_dropclient")
	clientnum = G_INT(prog, OFS_PARM0) - 1 -- PRVM_G_EDICTNUM(OFS_PARM0) - 1
	if clientnum < 0 or clientnum >= svs.maxclients then
		prvm_cmds.VM_Warning(prog, "dropclient: not a client\n")
		return
	end
	if not client_active(svs, clientnum) then
		prvm_cmds.VM_Warning(prog, "dropclient: that client slot is not connected\n")
		return
	end
	oldhostclient = server.host_client
	server.host_client = svs.clients[clientnum]
	HOST().SV_DropClient(false)
	server.host_client = oldhostclient
end
PORTED.VM_SV_dropclient = VM_SV_dropclient

--entity() spawnclient (DP_SV_BOTCLIENT)
-- port: svvm_cmds.c VM_SV_spawnclient L2678-2699 @xonotic-v0.8.6
-- (prog->xfunction->builtinsprofile += 2 / += 100: profiling counters, not ported)
local function VM_SV_spawnclient(prog: any)
	local ed
	local svs = svs_clients()
	SAFEPARMCOUNT(prog, 0, "VM_SV_spawnclient")
	ed = 0 -- prog->edicts
	for i = 0, svs.maxclients - 1 do
		if not client_active(svs, i) then
			SVMAIN().SV_ConnectClient(i, nil)
			-- this has to be set or else ClientDisconnect won't be called
			-- we assume the qc will call ClientConnect...
			svs_client(i).clientconnectcalled = true
			ed = i + 1 -- PRVM_EDICT_NUM(i + 1)
			break
		end
	end
	RETURN_EDICT(prog, ed)
end
PORTED.VM_SV_spawnclient = VM_SV_spawnclient

--float(entity clent) clienttype (DP_SV_BOTCLIENT)
-- port: svvm_cmds.c VM_SV_clienttype L2702-2715 @xonotic-v0.8.6
local function VM_SV_clienttype(prog: any)
	local clientnum
	local svs = svs_clients()
	SAFEPARMCOUNT(prog, 1, "VM_SV_clienttype")
	clientnum = G_INT(prog, OFS_PARM0) - 1 -- PRVM_G_EDICTNUM(OFS_PARM0) - 1
	if clientnum < 0 or clientnum >= svs.maxclients then
		SET_G_FLOAT(prog, OFS_RETURN, 3)
	elseif not client_active(svs, clientnum) then
		SET_G_FLOAT(prog, OFS_RETURN, 0)
	elseif svs.clients[clientnum].netconnection then
		SET_G_FLOAT(prog, OFS_RETURN, 1)
	else
		SET_G_FLOAT(prog, OFS_RETURN, 2)
	end
end
PORTED.VM_SV_clienttype = VM_SV_clienttype

--#335 float(string effectname) particleeffectnum (EXT_CSQC)
-- port: svvm_cmds.c VM_SV_particleeffectnum L2803-2811 @xonotic-v0.8.6
local function VM_SV_particleeffectnum(prog: any)
	local i
	SAFEPARMCOUNT(prog, 1, "VM_SV_particleeffectnum")
	i = SVMAIN().SV_ParticleEffectIndex(G_STRING(prog, OFS_PARM0))
	if i == 0 then
		i = -1
	end
	SET_G_FLOAT(prog, OFS_RETURN, i)
end
PORTED.VM_SV_particleeffectnum = VM_SV_particleeffectnum

-- #336 void(entity ent, float effectnum, vector start, vector end) trailparticles (EXT_CSQC)
-- port: svvm_cmds.c VM_SV_trailparticles L2814-2830 @xonotic-v0.8.6
-- engine quirk kept: the `< 0` test reads PARM0 (the entity) as a float, not the effect number
local function VM_SV_trailparticles(prog: any)
	local sv = server.sv
	local start, end_
	SAFEPARMCOUNT(prog, 4, "VM_SV_trailparticles")

	if toint(G_FLOAT(prog, OFS_PARM0)) < 0 then
		return
	end

	common.MSG_WriteByte(sv.datagram, svc_trailparticles)
	common.MSG_WriteShort(sv.datagram, G_INT(prog, OFS_PARM0)) -- PRVM_G_EDICTNUM
	common.MSG_WriteShort(sv.datagram, toint(G_FLOAT(prog, OFS_PARM1)))
	start = G_VECTOR(prog, OFS_PARM2)
	end_ = G_VECTOR(prog, OFS_PARM3)
	common.MSG_WriteVector(sv.datagram, start, sv.protocol)
	common.MSG_WriteVector(sv.datagram, end_, sv.protocol)
	SVMAIN().SV_FlushBroadcastMessages()
end
PORTED.VM_SV_trailparticles = VM_SV_trailparticles

--#337 void(float effectnum, vector origin, vector dir, float count) pointparticles (EXT_CSQC)
-- port: svvm_cmds.c VM_SV_pointparticles L2833-2864 @xonotic-v0.8.6
local function VM_SV_pointparticles(prog: any)
	local sv = server.sv
	local effectnum, count
	local org, vel
	SAFEPARMCOUNTRANGE(prog, 4, 8, "VM_SV_pointparticles")

	if toint(G_FLOAT(prog, OFS_PARM0)) < 0 then
		return
	end

	effectnum = toint(G_FLOAT(prog, OFS_PARM0))
	org = G_VECTOR(prog, OFS_PARM1)
	vel = G_VECTOR(prog, OFS_PARM2)
	count = toint(G_FLOAT(prog, OFS_PARM3))
	count = if count >= 0 then (if count < 65535 then count else 65535) else 0 -- bound(0, count, 65535)
	-- VectorLength2(vel): float products and sums
	if count == 1 and R(R(R(vel[1] * vel[1]) + R(vel[2] * vel[2])) + R(vel[3] * vel[3])) == 0 then
		-- 1+2+12=15 bytes
		common.MSG_WriteByte(sv.datagram, svc_pointparticles1)
		common.MSG_WriteShort(sv.datagram, effectnum)
		common.MSG_WriteVector(sv.datagram, org, sv.protocol)
	else
		-- 1+2+12+12+2=29 bytes
		common.MSG_WriteByte(sv.datagram, svc_pointparticles)
		common.MSG_WriteShort(sv.datagram, effectnum)
		common.MSG_WriteVector(sv.datagram, org, sv.protocol)
		common.MSG_WriteVector(sv.datagram, vel, sv.protocol)
		common.MSG_WriteShort(sv.datagram, count)
	end

	SVMAIN().SV_FlushBroadcastMessages()
end
PORTED.VM_SV_pointparticles = VM_SV_pointparticles

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
