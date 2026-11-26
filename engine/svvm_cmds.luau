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
]]
local names = require("./_port/builtin_names")

local svvm_cmds = {}

-- C name -> implementation (prog) -> (); filled as builtins are ported.
local prvm_cmds = require("./prvm_cmds")
local prvm_edict = require("./prvm_edict")
local PORTED: { [string]: (prog: any) -> () } = table.clone(prvm_cmds.BUILTINS)

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
	require("./sv_phys").SV_LinkEdict(out) -- required here: sv_phys -> sv_main -> svvm_cmds
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
	common.MSG_WriteByte(sv.signon, libc.toint(vol * 255))
	common.MSG_WriteByte(sv.signon, libc.toint(attenuation * 64))
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
	require("./sv_phys").SV_LinkEdict(e)
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

	require("./sv_phys").SV_LinkEdict(e)
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

-- port: svvm_cmds.c VM_SV_traceline L640-662 @xonotic-v0.8.6
local function VM_SV_traceline(prog: any)
	SAFEPARMCOUNTRANGE(prog, 4, 8, "VM_SV_traceline") -- allow more parameters for future expansion

	local v1 = G_VECTOR(prog, OFS_PARM0)
	local v2 = G_VECTOR(prog, OFS_PARM1)
	local move = toint(G_FLOAT(prog, OFS_PARM2))
	local ent = G_INT(prog, OFS_PARM3)

	if isnan(v1[1]) or isnan(v1[2]) or isnan(v1[3]) or isnan(v2[1]) or isnan(v2[2]) or isnan(v2[3]) then
		prog.error_cmd(
			string.format(
				"%s: NAN errors detected in traceline('%f %f %f', '%f %f %f', %i, entity %i)\n",
				prog.name,
				v1[1],
				v1[2],
				v1[3],
				v2[1],
				v2[2],
				v2[3],
				move,
				ent
			)
		)
	end

	local sv_phys = require("./sv_phys")
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
				"%s: NAN errors detected in tracebox('%f %f %f', '%f %f %f', '%f %f %f', '%f %f %f', %i, entity %i)\n",
				prog.name,
				v1[1],
				v1[2],
				v1[3],
				m1[1],
				m1[2],
				m1[3],
				m2[1],
				m2[2],
				m2[3],
				v2[1],
				v2[2],
				v2[3],
				move,
				ent
			)
		)
	end

	local sv_phys = require("./sv_phys")
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
	local numtouchedicts = require("./sv_phys").SV_EntitiesInBox(mins, maxs, MAX_EDICTS, touchedicts)
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
	local sv_phys: any = require("./sv_phys")
	sv_phys.SV_NudgeOutOfSolid(ent)
end

-- port: svvm_cmds.c VM_SV_droptofloor L1130-1205 @xonotic-v0.8.6
local function VM_SV_droptofloor(prog: any)
	local sv_phys = require("./sv_phys")
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
	SET_G_FLOAT(
		prog,
		OFS_RETURN,
		Mod_Q1BSP_NativeContentsFromSuperContents(require("./sv_phys").SV_PointSuperContents(point))
	)
end
PORTED.VM_SV_pointcontents = VM_SV_pointcontents

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
