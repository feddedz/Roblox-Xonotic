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
local host_cmd = require("./host_cmd")
local cvar = require("./cvar")
local libc = require("./_port/libc")

local sv_main = {}

local warned: { [string]: boolean } = {}
local function notPorted(what: string)
	if not warned[what] then
		warned[what] = true
		print("NOT YET PORTED: " .. what)
	end
end

-- client_t data the edict hooks read (svs.clients[num]); no clients connect yet (M6-NET). Each char array
-- of a client_t is one C pointer, so each is one string reference for PRVM_SetEngineString.
local NULL_BOTCLIENT = { str = "null/botclient" } -- string literal in SVVM_init_edict
local function client(num: number): any
	local svs = host_cmd.svs :: any
	svs.clients = svs.clients or {}
	local c = svs.clients[num]
	if not c then
		c = {
			colors = 0,
			name = { str = "" },
			playermodel = { str = "" },
			playerskin = { str = "" },
			netconnection = nil,
		}
		svs.clients[num] = c
	end
	return c
end

local function setf(prog: any, e: number, field: string, v: number)
	local o = prvm_edict.FieldOfs(prog, field)
	if o >= 0 then
		buffer.writef32(prog.edictsfields, (e * prog.entityfields + o) * 4, v)
	end
end
local function seti(prog: any, e: number, field: string, v: number)
	local o = prvm_edict.FieldOfs(prog, field)
	if o >= 0 then
		buffer.writei32(prog.edictsfields, (e * prog.entityfields + o) * 4, v)
	end
end

-- port: sv_main.c SVVM_init_edict L3604-3655 @xonotic-v0.8.6 (priv.server->move: not ported yet, sv_phys)
function sv_main.SVVM_init_edict(prog: any, e: number)
	local num = e - 1
	if num >= 0 and num < host_cmd.svs.maxclients then
		local c = client(num)
		-- set colormap and team on newly created player entity
		setf(prog, e, "colormap", num + 1)
		setf(prog, e, "team", bit32.band(c.colors, 15) + 1)
		seti(prog, e, "netname", prvm_edict.PRVM_SetEngineString(prog, c.name))
		setf(prog, e, "clientcolors", c.colors)
		seti(prog, e, "playermodel", prvm_edict.PRVM_SetEngineString(prog, c.playermodel))
		seti(prog, e, "playerskin", prvm_edict.PRVM_SetEngineString(prog, c.playerskin))
		if c.netconnection ~= nil then
			notPorted("SVVM_init_edict netaddress/crypto of connected clients (needs netconn, M6-NET)")
		else
			seti(prog, e, "netaddress", prvm_edict.PRVM_SetEngineString(prog, NULL_BOTCLIENT))
		end
		seti(prog, e, "crypto_idfp", 0)
		setf(prog, e, "crypto_idfp_signed", 0)
		seti(prog, e, "crypto_keyfp", 0)
		seti(prog, e, "crypto_mykeyfp", 0)
		seti(prog, e, "crypto_encryptmethod", 0)
		seti(prog, e, "crypto_signmethod", 0)
	end
end

-- port: sv_main.c SVVM_free_edict L3657-3684 @xonotic-v0.8.6
function sv_main.SVVM_free_edict(prog: any, e: number)
	notPorted("World_UnlinkEdict (world.c) in SVVM_free_edict")
	seti(prog, e, "model", 0)
	setf(prog, e, "takedamage", 0)
	setf(prog, e, "modelindex", 0)
	setf(prog, e, "colormap", 0)
	setf(prog, e, "skin", 0)
	setf(prog, e, "frame", 0)
	for _, f in { "origin", "angles" } do
		local o = prvm_edict.FieldOfs(prog, f)
		if o >= 0 then
			buffer.fill(prog.edictsfields, (e * prog.entityfields + o) * 4, 0, 12)
		end
	end
	setf(prog, e, "nextthink", -1)
	setf(prog, e, "solid", 0)
	notPorted("VM_RemoveEdictSkeleton, World_Physics_Remove*, csqc entity versions in SVVM_free_edict")
end

-- sv.time and current_skill (server.h / sv_main.c L3377: set by SV_SpawnServer, M4)
sv_main.sv = { time = 0 }
sv_main.current_skill = 0
prvm_edict.sv_time = function(): number
	return sv_main.sv.time
end

local SPAWNFLAG_NOT_EASY, SPAWNFLAG_NOT_MEDIUM, SPAWNFLAG_NOT_HARD, SPAWNFLAG_NOT_DEATHMATCH = 256, 512, 1024, 2048 -- server.h L381-384

-- port: sv_main.c SVVM_load_edict L3714-3734 @xonotic-v0.8.6 (gamemode is GAME_XONOTIC, not Transfusion)
function sv_main.SVVM_load_edict(prog: any, ent: number): boolean
	-- remove things from different skill levels or deathmatch
	local sf = prvm_edict.FieldOfs(prog, "spawnflags")
	local flags = libc.toint(buffer.readf32(prog.edictsfields, (ent * prog.entityfields + sf) * 4))
	local dm = cvar.Cvar_FindVar("deathmatch")
	if dm and dm.integer ~= 0 then
		if bit32.band(flags, SPAWNFLAG_NOT_DEATHMATCH) ~= 0 then
			return false
		end
	elseif
		(sv_main.current_skill <= 0 and bit32.band(flags, SPAWNFLAG_NOT_EASY) ~= 0)
		or (sv_main.current_skill == 1 and bit32.band(flags, SPAWNFLAG_NOT_MEDIUM) ~= 0)
		or (sv_main.current_skill >= 2 and bit32.band(flags, SPAWNFLAG_NOT_HARD) ~= 0)
	then
		return false
	end
	return true
end

local MAX_EDICTS = 32768 -- quakedef.h (non-DP_SMALLMEMORY)

-- port: sv_main.c SV_VM_Setup L3736-3924 @xonotic-v0.8.6 (PARTIAL, see header)
function sv_main.SV_VM_Setup(progsdata: buffer, opts: { onStub: ((number, string, any) -> ())?, maxclients: number? }?)
	local prog: any = prvm_edict.NewProg("server")
	svvm_cmds.install(prog, opts and opts.onStub)
	prog.max_edicts = 512
	prog.limit_edicts = MAX_EDICTS
	prog.reserved_edicts = (opts and opts.maxclients) or host_cmd.svs.maxclients
	prog.extensionstring = require("./_port/extensions").sv
	prog.init_edict = sv_main.SVVM_init_edict
	prog.free_edict = sv_main.SVVM_free_edict
	prog.load_edict = sv_main.SVVM_load_edict
	prog.begin_increase_edicts = function(_p: any)
		notPorted("SVVM_begin_increase_edicts: World_UnlinkEdict of all edicts (world.c)")
	end
	prog.end_increase_edicts = function(_p: any)
		notPorted("SVVM_end_increase_edicts: SV_LinkEdict of all edicts (sv_phys.c)")
	end
	prog.loadintoworld = true
	prvm_edict.PRVM_Prog_Load(prog, "progs.dat", progsdata, prvm_offsets.server_fields, prvm_offsets.server_globals)
	return prog
end

return sv_main
