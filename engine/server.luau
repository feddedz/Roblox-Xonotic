--!strict
--[[
	DarkPlaces server.h (server_t sv), GPLv2 or later (see engine/cvar.luau).
]]
--[[
	The server state the ported builtins read and write. PARTIAL: precache lists, light styles, datagram,
	signon and reliable datagram buffers, custom stats, time/state/paused/protocol, the level names, world (the
	area grid), worldmodel and models. Filled by SV_SpawnServer (sv_main.c) — before the first one sv.protocol
	keeps the value sv_protocolname "DP7" (the Xonotic default) selects.
	Strings of char arrays are Luau strings (truncated to the array size - 1 by the writer, as strlcpy does).
	sv.models is `dp_model_t *models[MAX_MODELS]`: C element i at [i] (nil = NULL), like the precache lists.
	NOT YET PORTED: the rest of server_t (entity frames, ...), added with their users.
]]
local common = require("./common")
local world = require("./world")

local server = {}

server.MAX_MODELS = 8192 -- quakedef.h L140
server.MAX_SOUNDS = 4096 -- quakedef.h L141
server.MAX_LIGHTSTYLES = 256 -- quakedef.h L142
server.MAX_QPATH = 128 -- quakedef.h L205
server.MAX_CL_STATS = 256 -- quakedef.h L221
server.NET_MAXMESSAGE = 65536 -- quakedef.h L137
server.ss_dead, server.ss_loading, server.ss_active = 0, 1, 2 -- server_state_t (server.h)

export type Server = {
	active: boolean,
	state: number,
	paused: boolean, -- server.h L82
	pausedstart: number, -- double pausedstart (server.h L83)
	time: number,
	frametime: number, -- double frametime (server.h L92)
	protocol: number,
	name: string, -- char name[64] (server.h L107)
	worldmessage: string, -- char worldmessage[40] (server.h L109)
	worldbasename: string, -- char [MAX_QPATH] (server.h L110)
	worldname: string, -- char [MAX_QPATH] (server.h L111)
	worldnamenoextension: string, -- char [MAX_QPATH] (server.h L112)
	model_precache: { [number]: string },
	sound_precache: { [number]: string },
	lightstyles: { [number]: string },
	datagram: common.SizeBuf, -- server.h L127-128
	signon: common.SizeBuf,
	reliable_datagram: common.SizeBuf,
	world: world.world_t, -- collision culling data
	worldmodel: any, -- dp_model_t * (nil = NULL)
	models: { [number]: any }, -- dp_model_t *models[MAX_MODELS], C index i at [i]
	writeentitiestoclient_msg: common.SizeBuf?, -- sizebuf_t * of the entity message being built (server.h L153; nil = NULL)
	-- port support: the address of a char array of this struct as an engine string reference (see CStrRef)
	stringrefs: { [string]: { str: string } },
}

-- a cleared server_t (memset 0 in SV_SpawnServer, then the buffers are set up, sv_main.c L3423-3433)
function server.New(): Server
	return {
		active = false,
		state = server.ss_dead,
		paused = false,
		pausedstart = 0,
		time = 0,
		frametime = 0,
		protocol = common.PROTOCOL.DARKPLACES7,
		name = "",
		worldmessage = "",
		worldbasename = "",
		worldname = "",
		worldnamenoextension = "",
		model_precache = {},
		sound_precache = {},
		lightstyles = {},
		datagram = common.SZ_New(server.NET_MAXMESSAGE),
		signon = common.SZ_New(server.NET_MAXMESSAGE),
		reliable_datagram = common.SZ_New(server.NET_MAXMESSAGE),
		world = world.new(),
		worldmodel = nil,
		models = {},
		writeentitiestoclient_msg = nil,
		stringrefs = {},
	}
end

server.sv = server.New()

-- memset(&sv, 0, sizeof(sv)) and the buffer setup after it (sv_main.c L3382, L3423-3433), in place: modules
-- that hold the server.sv table keep seeing the same `sv`, as C code sees the same global.
function server.Clear()
	local sv = server.sv :: any
	local refs = sv.stringrefs
	table.clear(sv)
	for k, v in server.New() :: any do
		sv[k] = v
	end
	-- the arrays keep their addresses; their text is zeroed
	for _, r in refs or {} do
		r.str = ""
	end
	sv.stringrefs = refs or {}
end

-- PRVM_SetEngineString(prog, sv.<array>) passes the address of a char array of server_t. The reference for
-- `key` ("worldname", "name", "model_precache 5", ...) is one table per array (identity = the address, kept by
-- server.Clear) whose str is set to the array's current text whenever the address is taken.
function server.CStrRef(key: string, text: string): { str: string }
	local refs = server.sv.stringrefs
	local r = refs[key]
	if not r then
		r = { str = text }
		refs[key] = r
	else
		r.str = text
	end
	return r
end

-- host.c `client_t *host_client` (the client being processed; nil = NULL). Its client_t is a table of
-- host_cmd.svs.clients; the fields sv_phys.c reads are begun, edict (edict number), clmovement_inputtimeout
-- (float), cmd (usercmd_t), fixangle_angles, fixangle_angles_set (nil = the zeroed C memory).
server.host_client = nil :: any

-- vm_customstats (svvm_cmds.c L1690-1695): [i] = { type, fieldoffset }, i = stat - 32
server.vm_customstats = {} :: { [number]: { type: number, fieldoffset: number } }
server.vm_customstats_last = -1

return server
