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
