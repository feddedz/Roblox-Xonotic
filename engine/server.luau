--!strict
--[[
	DarkPlaces server.h (server_t sv), GPLv2 or later (see engine/cvar.luau).
]]
--[[
	The server state the ported builtins read and write. PARTIAL: precache lists, light styles, signon and
	reliable datagram buffers, custom stats, time/state/protocol. Filled by SV_SpawnServer (sv_main.c,
	M4) — until then sv.protocol keeps the value sv_protocolname "DP7" (the Xonotic default) selects.
	NOT YET PORTED: the rest of server_t (worldmodel, areagrid, entity frames, ...), added with their users.
]]
local common = require("./common")

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
	time: number,
	protocol: number,
	model_precache: { [number]: string },
	sound_precache: { [number]: string },
	lightstyles: { [number]: string },
	signon: common.SizeBuf,
	reliable_datagram: common.SizeBuf,
}

-- a cleared server_t (memset 0 in SV_SpawnServer, then the buffers are set up, sv_main.c L3431-3436)
function server.New(): Server
	return {
		active = false,
		state = server.ss_dead,
		time = 0,
		protocol = common.PROTOCOL.DARKPLACES7,
		model_precache = {},
		sound_precache = {},
		lightstyles = {},
		signon = common.SZ_New(server.NET_MAXMESSAGE),
		reliable_datagram = common.SZ_New(server.NET_MAXMESSAGE),
	}
end

server.sv = server.New()

-- vm_customstats (svvm_cmds.c L1690-1695): [i] = { type, fieldoffset }, i = stat - 32
server.vm_customstats = {} :: { [number]: { type: number, fieldoffset: number } }
server.vm_customstats_last = -1

return server
