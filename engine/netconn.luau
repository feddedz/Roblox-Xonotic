--!strict
--[[
Copyright (C) 1996-1997 Id Software, Inc.
Copyright (C) 2002 Mathieu Olivier
Copyright (C) 2003 Forest Hale
(DarkPlaces netconn.c / netconn.h; GPLv2 or later, see engine/prvm_exec.luau)
]]
--[[
	Port of netconn.c @xonotic-v0.8.6: the shared packet layer and the SERVER side of the DarkPlaces
	connection protocol, in the C file's order. The same packets DarkPlaces puts on UDP go through engine/lhnet.luau
	(loopback queue, or lhnet.backend: the Roblox RemoteEvent transport of platform/net).
	Ported: NetConn_Read, NetConn_Write, NetConn_WriteString, NetConn_CanSend, NetConn_UpdateCleartime,
	NetConn_AddCryptoFlag, NetConn_SendUnreliableMessage (NQ / DarkPlaces branch), NetConn_HaveClientPorts,
	NetConn_HaveServerPorts, NetConn_CloseClientPorts, NetConn_OpenClientPort, NetConn_OpenClientPorts,
	NetConn_CloseServerPorts, NetConn_OpenServerPort, NetConn_OpenServerPorts,
	NetConn_ChooseClientSocketForAddress, NetConn_ChooseServerSocketForAddress, NetConn_Open, NetConn_Close,
	NetConn_UpdateSockets, NetConn_ReceivedMessage (NQ / DarkPlaces branch), NetConn_BuildChallengeString,
	NetConn_BuildStatusResponse, NetConn_PreventFlood, NetConn_ClearFlood, NetConn_ServerParsePacket
	(getchallenge, connect, getinfo, getstatus, extResponse, ping, ack, the NetQuake CCREQ_* control packets, the
	per-client routing), NetConn_ServerFrame, NetConn_SleepMicroseconds, NetConn_Heartbeat, Net_Heartbeat_f,
	PrintStats, Net_Stats_f, NetConn_Init, NetConn_Shutdown.
	crypto.c is reached the way a build without the d0_blind_id library behaves (Crypto_* below, ported from
	crypto.c: no keys, no authenticated connection): packets pass through unencrypted, connect needs the challenge.
	NOT YET PORTED (logged once when reached): the QuakeWorld branches of NetConn_SendUnreliableMessage /
	NetConn_ReceivedMessage, rcon / srcon (RCon_Authenticate, RCon_Execute, the hmac comparators), the
	authenticated-crypto paths, Com_HexDumpToConsole / SZ_HexDumpToConsole of developer_networking.
	Client side, not in scope (not ported): the server list (ServerList_*, NetConn_UpdateFavorites, _ServerList_*),
	NetConn_ConnectionEstablished, NetConn_IsLocalGame, NetConn_ClientParsePacket and its ServerList helpers,
	NetConn_QueryQueueFrame, NetConn_ClientFrame, NetConn_QueryMasters, Net_Refresh_f, Net_Slist_f,
	Net_SlistQW_f.

	State: netconn_t is a table with the C member names (netconn.NetConn_Open makes one, zeroed as Mem_Alloc):
	message (sizebuf_t over messagedata), sendMessage / receiveMessage (buffers of NET_MAXMESSAGE),
	nq = { ackSequence, sendSequence, receiveSequence, unreliableReceiveSequence } (unsigned ints),
	incoming_netgraph / outgoing_netgraph (0-based tables of { time, reliablebytes, unreliablebytes, ackbytes,
	cleartime }), address (the char[128] text), crypto (crypto_t: authenticated false), peeraddress (lhnetaddress_t
	of engine/lhnet.luau), mysocket (lhnetsocket_t), next (netconn_list). Sockets: sv_sockets / cl_sockets hold
	C element i at [i + 1]. sv_message / cl_message (netconn.c's globals, sizebuf_t of NET_MAXMESSAGE) are
	netconn.sv_message / netconn.cl_message: NetConn_ReceivedMessage puts a complete message there
	(SZ_Clear + SZ_Write + MSG_BeginReading) and NetConn_ServerParsePacket then calls SV_ReadClientMessage
	(engine/sv_user.luau, resolved on first use). cls.netcon (the client's connection; nil on a dedicated server)
	is netconn.cls_netcon. challenges[MAX_CHALLENGES] is netconn.challenges (C element i at [i + 1]).
	The server functions netconn.c calls (SV_ConnectClient, SV_SendServerinfo, SV_ReadClientMessage,
	SV_DropClient) can be replaced through netconn.hooks (tests); otherwise they are engine/sv_main.luau's,
	engine/sv_user.luau's and engine/host.luau's.
]]
local common = require("./common")
local console = require("./console")
local cvar = require("./cvar")
local cmd = require("./cmd")
local libc = require("./_port/libc")
local lhnet = require("./lhnet")
local prvm_edict = require("./prvm_edict")
local prvm_cmds = require("./prvm_cmds")
local host_cmd = require("./host_cmd")
local server = require("./server")
local R = require("./_port/f32").round

local netconn = {}

local warned: { [string]: boolean } = {}
local function notPorted(what: string)
	if not warned[what] then
		warned[what] = true
		print("NOT YET PORTED: " .. what)
	end
end

local band, bor, bnot = bit32.band, bit32.bor, bit32.bnot

local LHNETADDRESSTYPE_NONE, LHNETADDRESSTYPE_LOOP = lhnet.LHNETADDRESSTYPE_NONE, lhnet.LHNETADDRESSTYPE_LOOP
local LHNETADDRESSTYPE_INET4, LHNETADDRESSTYPE_INET6 = lhnet.LHNETADDRESSTYPE_INET4, lhnet.LHNETADDRESSTYPE_INET6
local LHNETADDRESS_New, LHNETADDRESS_Copy = lhnet.LHNETADDRESS_New, lhnet.LHNETADDRESS_Copy
local LHNETADDRESS_ToString, LHNETADDRESS_FromString = lhnet.LHNETADDRESS_ToString, lhnet.LHNETADDRESS_FromString
local LHNETADDRESS_FromPort, LHNETADDRESS_Compare = lhnet.LHNETADDRESS_FromPort, lhnet.LHNETADDRESS_Compare
local LHNETADDRESS_GetAddressType, LHNETADDRESS_SetPort = lhnet.LHNETADDRESS_GetAddressType, lhnet.LHNETADDRESS_SetPort
local LHNETADDRESS_GetPort, LHNET_AddressFromSocket = lhnet.LHNETADDRESS_GetPort, lhnet.LHNET_AddressFromSocket

-- netconn.h
local NET_HEADERSIZE = 8 -- (2 * sizeof(unsigned int))
local NETFLAG_LENGTH_MASK = 0x0000ffff
local NETFLAG_DATA = 0x00010000
local NETFLAG_ACK = 0x00020000
local NETFLAG_EOM = 0x00080000
local NETFLAG_UNRELIABLE = 0x00100000
local NETFLAG_CRYPTO0 = 0x10000000
local NETFLAG_CRYPTO1 = 0x20000000
local NETFLAG_CRYPTO2 = 0x40000000
local NETFLAG_CTL = 0x80000000
local NET_PROTOCOL_VERSION = 3
local NET_EXTRESPONSE_MAX = 16
local CCREQ_CONNECT, CCREQ_SERVER_INFO, CCREQ_PLAYER_INFO, CCREQ_RULE_INFO, CCREQ_RCON = 0x01, 0x02, 0x03, 0x04, 0x05
local CCREP_ACCEPT, CCREP_REJECT, CCREP_SERVER_INFO, CCREP_PLAYER_INFO, CCREP_RULE_INFO = 0x81, 0x82, 0x83, 0x84, 0x85
local NETGRAPH_PACKETS, NETGRAPH_NOPACKET, NETGRAPH_LOSTPACKET, NETGRAPH_CHOKEDPACKET = 256, 0, -1, -2
local MAX_CHALLENGES = 128
-- quakedef.h / server.h / client.h / crypto.h
local NET_MAXMESSAGE = 65536
local MAX_PACKETFRAGMENT = 1024
local MAX_INPUTLINE = 16384
local MAX_CONNECTFLOODADDRESSES, MAX_GETSTATUSFLOODADDRESSES = 16, 128
local MAX_RCONS = 16
local CRYPTO_HEADERSIZE = 31
local CRYPTO_NOMATCH, CRYPTO_MATCH, CRYPTO_DISCARD, CRYPTO_REPLACE = 0, 1, 2, 3
local DPMASTER_PORT = 27950 -- netconn.c L33
local P = common.PROTOCOL
local CVAR_NOTIFY = cvar.CVAR_NOTIFY
-- the game names of GAME_XONOTIC: gamenetworkfiltername (common.c gamemode_info) and com_modname (fs.c FS_Init:
-- gamedirname1 "data")
local gamenetworkfiltername = "Xonotic"
local com_modname = "data"
local IS_NEXUIZ_DERIVED = true -- IS_NEXUIZ_DERIVED(gamemode) for GAME_XONOTIC (common.h L306)

-- C unsigned int arithmetic
local function u32(x: number): number
	return x % 4294967296
end
-- an unsigned int printed with %i / stored into an int
local function toint32(u: number): number
	u = u % 4294967296
	return if u >= 0x80000000 then u - 0x100000000 else u
end

-- port: common.c BuffBigLong L70-73 @xonotic-v0.8.6 (local copy: common.luau has no BuffBigLong yet; move there)
local function BuffBigLong(b: buffer, o: number): number
	return toint32(
		buffer.readu8(b, o) * 16777216
			+ buffer.readu8(b, o + 1) * 65536
			+ buffer.readu8(b, o + 2) * 256
			+ buffer.readu8(b, o + 3)
	)
end

-- port: common.c StoreBigLong L102-108 @xonotic-v0.8.6 (local copy: common.luau has no StoreBigLong yet; move there)
local function StoreBigLong(b: buffer, o: number, i: number)
	i = u32(i)
	buffer.writeu8(b, o, band(i // 16777216, 0xFF))
	buffer.writeu8(b, o + 1, band(i // 65536, 0xFF))
	buffer.writeu8(b, o + 2, band(i // 256, 0xFF))
	buffer.writeu8(b, o + 3, band(i, 0xFF))
end

-- SZ_Write(buf, data, length) from a buffer (common.c SZ_Write: memcpy(SZ_GetSpace(buf, length), data, length))
local function SZ_WriteBuf(sb: any, data: buffer, offset: number, length: number)
	local o = common.SZ_GetSpace(sb, length)
	buffer.copy(sb.data, o, data, offset, length)
end

local MSG_BeginReading = common.MSG_BeginReading -- (common.c)

-- the cvar_t of the C files by C variable name (host.cv, registered by host.Host_Init_Dedicated from the init
-- table; netconn.c's cvars are among them)
local hostmod: any = nil
local function HOST(): any
	if not hostmod then
		hostmod = require("./host")
	end
	return hostmod
end
local function CV(var: string): any
	local c = HOST().cv[var]
	if not c then
		error("netconn: cvar " .. var .. " is not registered (run host.Host_Init_Dedicated first)", 0)
	end
	return c
end
-- a cvar the dedicated server may not register: its static cvar_t (default value) otherwise
local function CVopt(var: string, default: number): number
	local c = HOST().cv[var]
	return if c then c.integer else default
end

local svmainmod: any = nil
local function SVMAIN(): any
	if not svmainmod then
		svmainmod = require("./sv_main")
	end
	return svmainmod
end

-- the server functions netconn.c calls (tests can replace them here)
netconn.hooks = {} :: { [string]: any }

local function SV_ConnectClient(clientnum: number, conn: any)
	local f = netconn.hooks.SV_ConnectClient or SVMAIN().SV_ConnectClient
	f(clientnum, conn)
end
local function SV_SendServerinfo(client: any)
	local f = netconn.hooks.SV_SendServerinfo or SVMAIN().SV_SendServerinfo
	f(client)
end
local function SV_DropClient(crash: boolean)
	local f = netconn.hooks.SV_DropClient or HOST().SV_DropClient
	f(crash)
end
-- sv_user.c SV_ReadClientMessage (engine/sv_user.luau), resolved once. sv_user reads the message from its field
-- sv_user.sv_message: that field is pointed at this module's sv_message (the one C sizebuf_t).
local svusermod: any = nil
local readclientmessage: any = nil
local readclientmessage_resolved = false
local function SV_ReadClientMessage()
	local f = netconn.hooks.SV_ReadClientMessage
	if not f then
		if not readclientmessage_resolved then
			readclientmessage_resolved = true
			local ok, m = pcall(require, "./sv_user")
			if ok and type(m) == "table" then
				svusermod = m
				readclientmessage = (m :: any).SV_ReadClientMessage
			end
		end
		f = readclientmessage
		if svusermod and svusermod.sv_message ~= netconn.sv_message then
			svusermod.sv_message = netconn.sv_message
		end
	end
	if not f then
		notPorted("SV_ReadClientMessage (sv_user.c; the received message stays in netconn.sv_message)")
		return
	end
	f()
end

local function svs(): any
	return host_cmd.svs
end
-- svs.clients + i (a zeroed client_t until used: sv_main.client creates cleared slots)
local function clientslot(i: number): any
	local s = host_cmd.svs :: any
	local c = s.clients and s.clients[i]
	if c then
		return c
	end
	return SVMAIN().client(i)
end

--[[
	crypto.c, as built without the d0_blind_id library (d0_blind_id_dll == NULL): Crypto_* entry points that
	netconn.c calls. A crypto_t is { authenticated = false } (Crypto_ServerGetInstance never returns one).
]]
local crypto_servercpu_accumulator = 0
local crypto_servercpu_lastrealtime = 0
local crypto_complain_time = 0

-- port: crypto.c Crypto_ServerGetInstance L552-556 @xonotic-v0.8.6
local function Crypto_ServerGetInstance(_peeraddress: any): any
	-- no check needed here (returned pointers are only used in prefilled fields)
	-- Crypto_ServerFindInstance: if(!d0_blind_id_dll) return NULL; // no support
	return nil
end

-- port: crypto.c Crypto_LoadKeys L834-962 @xonotic-v0.8.6
local function Crypto_LoadKeys()
	-- if(!d0_blind_id_dll) return; // don't if we can't
end

-- port: crypto.c Crypto_EncryptPacket L1505-1560 @xonotic-v0.8.6
-- returns (data, length) of the packet to send (nil = failure)
local function Crypto_EncryptPacket(crypto: any, data_src: buffer, len_src: number): (buffer?, number)
	if crypto.authenticated then
		notPorted("Crypto_EncryptPacket of an authenticated connection (crypto.c HMAC / AES)")
		return nil, 0
	else
		return data_src, len_src
	end
end

-- port: crypto.c Crypto_DecryptPacket L1562-1664 @xonotic-v0.8.6
-- returns (data, length) of the decrypted packet (nil = drop)
local function Crypto_DecryptPacket(crypto: any, data_src: buffer, len_src: number): (buffer?, number)
	local i
	-- silently handle non-crypto packets
	i = BuffBigLong(data_src, 0)
	if
		i == toint32(0xFFFFFFFF) -- avoid QW control packet
		or i == toint32(0x80000000 + len_src) -- avoid NQ control packet
	then
		return nil, 0
	end

	if crypto.authenticated then
		notPorted("Crypto_DecryptPacket of an authenticated connection (crypto.c HMAC / AES)")
		return nil, 0
	else
		return data_src, len_src
	end
end

-- port: crypto.c Crypto_GetInfoResponseDataString L1667-1671 @xonotic-v0.8.6
local function Crypto_GetInfoResponseDataString(): string?
	-- crypto_idstring_buf[0] = '0' + crypto_aeslevel.integer; return crypto_idstring; (NULL without keys)
	return nil
end

-- port: crypto.c Crypto_ServerAppendToChallenge L1674-1685 @xonotic-v0.8.6
local function Crypto_ServerAppendToChallenge(): boolean
	-- if(!d0_blind_id_dll) return false; // no support
	return false
end

-- port: crypto.c Crypto_ServerParsePacket_Internal L1705-2014 @xonotic-v0.8.6
local function Crypto_ServerParsePacket_Internal(): number
	-- if(!d0_blind_id_dll) return CRYPTO_NOMATCH; // no support
	return CRYPTO_NOMATCH
end

-- port: crypto.c Crypto_ServerParsePacket L2016-2071 @xonotic-v0.8.6
-- returns (result, the reply length *len_out: 0 when nothing is to be sent)
local function Crypto_ServerParsePacket(data_in: string, len_in: number): (number, number)
	local ret
	local t = 0
	local do_time = false
	local do_reject = false
	local len_out = 0
	local realtime = prvm_edict.realtime
	local percent = HOST().cv.crypto_servercpupercent
	local maxtime = HOST().cv.crypto_servercpumaxtime
	local percentvalue = if percent then percent.value else R(10)
	local maxtimevalue = if maxtime then maxtime.value else R(0.01)
	if percentvalue > 0 or maxtimevalue > 0 then
		if len_in > 5 and string.sub(data_in, 1, 5) == "d0pk\\" then
			do_time = true
			local cnt = common.InfoString_GetValue(string.sub(data_in, 5), "cnt", MAX_INPUTLINE)
			if cnt then
				if cnt == "0" then
					do_reject = true
				end
			end
		end
	end
	if do_time then
		-- check if we may perform crypto...
		if percentvalue > 0 then
			crypto_servercpu_accumulator += (realtime - crypto_servercpu_lastrealtime) * percentvalue * 0.01
			if maxtimevalue ~= 0 then
				if crypto_servercpu_accumulator > maxtimevalue then
					crypto_servercpu_accumulator = maxtimevalue
				end
			end
		else
			if maxtimevalue > 0 then
				if realtime ~= crypto_servercpu_lastrealtime then
					crypto_servercpu_accumulator = maxtimevalue
				end
			end
		end
		crypto_servercpu_lastrealtime = realtime
		if do_reject and crypto_servercpu_accumulator < 0 then
			if realtime > crypto_complain_time + 5 then
				console.Con_Printf(
					"crypto: cannot perform requested crypto operations; denial service attack or crypto_servercpupercent/crypto_servercpumaxtime are too low\n"
				)
			end
			len_out = 0
			return CRYPTO_DISCARD, len_out
		end
		t = prvm_cmds.Sys_DirtyTime()
	end
	ret = Crypto_ServerParsePacket_Internal()
	if do_time then
		t = prvm_cmds.Sys_DirtyTime() - t
		if t < 0.0 then
			t = 0.0 -- dirtytime can step backwards
		end
		if CVopt("crypto_servercpudebug", 0) ~= 0 then
			console.Con_Printf(
				"crypto: accumulator was %.1f ms, used %.1f ms for crypto, ",
				crypto_servercpu_accumulator * 1000,
				t * 1000
			)
		end
		crypto_servercpu_accumulator -= t
		if CVopt("crypto_servercpudebug", 0) ~= 0 then
			console.Con_Printf("is %.1f ms\n", crypto_servercpu_accumulator * 1000)
		end
	end
	return ret, len_out
end

-- ENCRYPTION_REQUIRED (crypto.h L6)
local function ENCRYPTION_REQUIRED(): boolean
	return CVopt("crypto_aeslevel", 1) >= 3
end

-- netconn.c statics and globals (L68-146)
local nextheartbeattime = 0

-- sizebuf_t cl_message / sv_message over cl_message_buf / sv_message_buf (set up by NetConn_Init)
netconn.cl_message = common.SZ_New(NET_MAXMESSAGE) :: any
netconn.sv_message = common.SZ_New(NET_MAXMESSAGE) :: any

-- challenge_t challenges[MAX_CHALLENGES] (netconn.h L476-485): { address, time, string (char[12]) }
local function newchallenges(): { any }
	local t = table.create(MAX_CHALLENGES)
	for i = 1, MAX_CHALLENGES do
		t[i] = { address = LHNETADDRESS_New(), time = 0, string = "" }
	end
	return t
end
netconn.challenges = newchallenges()

local cl_numsockets = 0
local cl_sockets: { [number]: any } = {} -- lhnetsocket_t *cl_sockets[16], C element i at [i + 1]
local sv_numsockets = 0
local sv_sockets: { [number]: any } = {} -- lhnetsocket_t *sv_sockets[16]

netconn.netconn_list = nil :: any -- netconn_t *netconn_list

-- cls (client.h client_static_t) members netconn.c reads on the server path: cls.netcon (nil on a dedicated
-- server), cls.rcon_* of the client rcon ring (empty)
netconn.cls_netcon = nil :: any
local cls_rcon_ringpos = 0
local cls_rcon_commands: { [number]: string } = {}
local cls_rcon_timeout: { [number]: number } = {}
for i = 0, MAX_RCONS - 1 do
	cls_rcon_commands[i] = ""
	cls_rcon_timeout[i] = 0
end

-- char cl_net_extresponse / sv_net_extresponse[NET_EXTRESPONSE_MAX][1400] (0-based)
netconn.sv_net_extresponse = {} :: { [number]: string }
netconn.sv_net_extresponse_count = 0
netconn.sv_net_extresponse_last = 0
for i = 0, NET_EXTRESPONSE_MAX - 1 do
	netconn.sv_net_extresponse[i] = ""
end

-- rest

-- port: netconn.c NetConn_Read L611-640 @xonotic-v0.8.6
function netconn.NetConn_Read(mysocket: any, data: buffer, maxlength: number, peeraddress: any): number
	local length
	local i
	-- (netconn_mutex: no threads)
	length = lhnet.LHNET_Read(mysocket, data, maxlength, peeraddress)
	if length == 0 then
		return 0
	end
	local loss = CV("cl_netpacketloss_receive").integer
	if loss ~= 0 then
		i = 0
		while i < cl_numsockets do
			if cl_sockets[i + 1] == mysocket and (libc.rand() % 100) < loss then
				return 0
			end
			i += 1
		end
	end
	if CV("developer_networking").integer ~= 0 then
		local _, addressstring = LHNETADDRESS_ToString(LHNET_AddressFromSocket(mysocket), 128, true)
		if length > 0 then
			local _, addressstring2 = LHNETADDRESS_ToString(peeraddress, 128, true)
			console.Con_Printf(
				"LHNET_Read(%s (%s), %s, %i, %s) = %i from %s:\n",
				"(socket)",
				addressstring,
				"(data)",
				maxlength,
				"(address)",
				length,
				addressstring2
			)
			notPorted("Com_HexDumpToConsole (common.c) for developer_networking")
		else
			console.Con_Printf(
				"LHNET_Read(%s (%s), %s, %i, %s) = %i\n",
				"(socket)",
				addressstring,
				"(data)",
				maxlength,
				"(address)",
				length
			)
		end
	end
	return length
end
local NetConn_Read = netconn.NetConn_Read

-- port: netconn.c NetConn_Write L642-664 @xonotic-v0.8.6
function netconn.NetConn_Write(mysocket: any, data: buffer, length: number, peeraddress: any): number
	local ret
	local i
	local loss = CV("cl_netpacketloss_send").integer
	if loss ~= 0 then
		i = 0
		while i < cl_numsockets do
			if cl_sockets[i + 1] == mysocket and (libc.rand() % 100) < loss then
				return length
			end
			i += 1
		end
	end
	ret = lhnet.LHNET_Write(mysocket, data, length, peeraddress)
	if CV("developer_networking").integer ~= 0 then
		local _, addressstring = LHNETADDRESS_ToString(LHNET_AddressFromSocket(mysocket), 128, true)
		local _, addressstring2 = LHNETADDRESS_ToString(peeraddress, 128, true)
		console.Con_Printf(
			"LHNET_Write(%s (%s), %s, %i, %s (%s)) = %i%s\n",
			"(socket)",
			addressstring,
			"(data)",
			length,
			"(address)",
			addressstring2,
			length,
			if ret == length then "" else " (ERROR)"
		)
		notPorted("Com_HexDumpToConsole (common.c) for developer_networking")
	end
	return ret
end
local NetConn_Write = netconn.NetConn_Write

-- port: netconn.c NetConn_WriteString L666-670 @xonotic-v0.8.6
function netconn.NetConn_WriteString(mysocket: any, str: string, peeraddress: any): number
	-- note this does not include the trailing NULL because we add that in the parser
	local s = libc.cstr(str)
	return NetConn_Write(mysocket, buffer.fromstring(s), #s, peeraddress)
end
local NetConn_WriteString = netconn.NetConn_WriteString

-- port: netconn.c NetConn_CanSend L672-687 @xonotic-v0.8.6
function netconn.NetConn_CanSend(conn: any): boolean
	conn.outgoing_packetcounter = (conn.outgoing_packetcounter + 1) % NETGRAPH_PACKETS
	local g = conn.outgoing_netgraph[conn.outgoing_packetcounter]
	g.time = prvm_edict.realtime
	g.unreliablebytes = NETGRAPH_NOPACKET
	g.reliablebytes = NETGRAPH_NOPACKET
	g.ackbytes = NETGRAPH_NOPACKET
	g.cleartime = conn.cleartime
	if prvm_edict.realtime > conn.cleartime then
		return true
	else
		g.unreliablebytes = NETGRAPH_CHOKEDPACKET
		return false
	end
end

-- port: netconn.c NetConn_UpdateCleartime L689-704 @xonotic-v0.8.6
-- (C: double *cleartime; here the new value is returned)
local function NetConn_UpdateCleartime(cleartime: number, rate: number, burstsize: number, len: number): number
	local realtime = prvm_edict.realtime
	local bursttime = burstsize / rate

	-- delay later packets to obey rate limit
	if cleartime < realtime - bursttime then
		cleartime = realtime - bursttime
	end
	cleartime = cleartime + len / rate

	-- limit bursts to one packet in size ("dialup mode" emulating old behaviour)
	if CV("net_test").integer ~= 0 then
		if cleartime < realtime then
			cleartime = realtime
		end
	end
	return cleartime
end

-- port: netconn.c NetConn_AddCryptoFlag L706-725 @xonotic-v0.8.6
local function NetConn_AddCryptoFlag(crypto: any): number
	-- HACK: if an encrypted connection is used, randomly set some unused
	-- flags. When AES encryption is enabled, that will make resends differ
	-- from the original, so that e.g. substring filters in a router/IPS
	-- are unlikely to match a second time. See also "startkeylogger".
	local flag = 0
	if crypto.authenticated then
		-- Let's always set at least one of the bits.
		local r = libc.rand() % 7 + 1
		if band(r, 1) ~= 0 then
			flag = bor(flag, NETFLAG_CRYPTO0)
		end
		if band(r, 2) ~= 0 then
			flag = bor(flag, NETFLAG_CRYPTO1)
		end
		if band(r, 4) ~= 0 then
			flag = bor(flag, NETFLAG_CRYPTO2)
		end
	end
	return flag
end

local sendbuffer = buffer.create(NET_HEADERSIZE + NET_MAXMESSAGE) -- (a stack array in C)

-- port: netconn.c NetConn_SendUnreliableMessage L727-933 @xonotic-v0.8.6
function netconn.NetConn_SendUnreliableMessage(
	conn: any,
	data: any,
	protocol: number,
	rate: number,
	burstsize: number,
	quakesignon_suppressreliables: boolean
): number
	local totallen = 0
	local realtime = prvm_edict.realtime
	local og = conn.outgoing_netgraph[conn.outgoing_packetcounter]

	-- if this packet was supposedly choked, but we find ourselves sending one
	-- anyway, make sure the size counting starts at zero
	-- (this mostly happens on level changes and disconnects and such)
	if og.unreliablebytes == NETGRAPH_CHOKEDPACKET then
		og.unreliablebytes = NETGRAPH_NOPACKET
	end

	og.cleartime = conn.cleartime

	if protocol == P.QUAKEWORLD then
		notPorted("NetConn_SendUnreliableMessage QuakeWorld branch (netconn.c L741-807)")
		return -1
	else
		local packetLen
		local dataLen
		local eom
		local sendme: buffer?
		local sendmelen

		-- if a reliable message fragment has been lost, send it again
		if conn.sendMessageLength ~= 0 and (realtime - conn.lastSendTime) > 1.0 then
			if conn.sendMessageLength <= MAX_PACKETFRAGMENT then
				dataLen = conn.sendMessageLength
				eom = NETFLAG_EOM
			else
				dataLen = MAX_PACKETFRAGMENT
				eom = 0
			end

			packetLen = NET_HEADERSIZE + dataLen

			StoreBigLong(sendbuffer, 0, bor(packetLen, bor(NETFLAG_DATA, eom, NetConn_AddCryptoFlag(conn.crypto))))
			StoreBigLong(sendbuffer, 4, u32(conn.nq.sendSequence - 1))
			buffer.copy(sendbuffer, NET_HEADERSIZE, conn.sendMessage, 0, dataLen)

			og.reliablebytes += packetLen + 28

			sendme, sendmelen = Crypto_EncryptPacket(conn.crypto, sendbuffer, packetLen)
			if sendme and NetConn_Write(conn.mysocket, sendme, sendmelen, conn.peeraddress) == sendmelen then
				conn.lastSendTime = realtime
				conn.packetsReSent += 1
			end

			totallen += sendmelen + 28
		end

		-- if we have a new reliable message to send, do so
		if conn.sendMessageLength == 0 and conn.message.cursize ~= 0 and not quakesignon_suppressreliables then
			if conn.message.cursize > NET_MAXMESSAGE then
				console.Con_Printf(
					"NetConn_SendUnreliableMessage: reliable message too big (%u > %u)\n",
					conn.message.cursize,
					NET_MAXMESSAGE
				)
				conn.message.overflowed = true
				return -1
			end

			if CV("developer_networking").integer ~= 0 and conn == netconn.cls_netcon then
				console.Con_Print("client sending reliable message to server:\n")
				notPorted("SZ_HexDumpToConsole (common.c) for developer_networking")
			end

			buffer.copy(conn.sendMessage, 0, conn.message.data, 0, conn.message.cursize)
			conn.sendMessageLength = conn.message.cursize
			common.SZ_Clear(conn.message)

			if conn.sendMessageLength <= MAX_PACKETFRAGMENT then
				dataLen = conn.sendMessageLength
				eom = NETFLAG_EOM
			else
				dataLen = MAX_PACKETFRAGMENT
				eom = 0
			end

			packetLen = NET_HEADERSIZE + dataLen

			StoreBigLong(sendbuffer, 0, bor(packetLen, bor(NETFLAG_DATA, eom, NetConn_AddCryptoFlag(conn.crypto))))
			StoreBigLong(sendbuffer, 4, conn.nq.sendSequence)
			buffer.copy(sendbuffer, NET_HEADERSIZE, conn.sendMessage, 0, dataLen)

			conn.nq.sendSequence = u32(conn.nq.sendSequence + 1)

			og.reliablebytes += packetLen + 28

			sendme, sendmelen = Crypto_EncryptPacket(conn.crypto, sendbuffer, packetLen)
			if sendme then
				NetConn_Write(conn.mysocket, sendme, sendmelen, conn.peeraddress)
			end

			conn.lastSendTime = realtime
			conn.packetsSent += 1
			conn.reliableMessagesSent += 1

			totallen += sendmelen + 28
		end

		-- if we have an unreliable message to send, do so
		if data.cursize ~= 0 then
			packetLen = NET_HEADERSIZE + data.cursize

			if packetLen > NET_HEADERSIZE + NET_MAXMESSAGE then
				console.Con_Printf("NetConn_SendUnreliableMessage: message too big %u\n", data.cursize)
				return -1
			end

			StoreBigLong(sendbuffer, 0, bor(packetLen, NETFLAG_UNRELIABLE, NetConn_AddCryptoFlag(conn.crypto)))
			StoreBigLong(sendbuffer, 4, conn.outgoing_unreliable_sequence)
			buffer.copy(sendbuffer, NET_HEADERSIZE, data.data, 0, data.cursize)

			conn.outgoing_unreliable_sequence = u32(conn.outgoing_unreliable_sequence + 1)

			og.unreliablebytes += packetLen + 28

			sendme, sendmelen = Crypto_EncryptPacket(conn.crypto, sendbuffer, packetLen)
			if sendme then
				NetConn_Write(conn.mysocket, sendme, sendmelen, conn.peeraddress)
			end

			conn.packetsSent += 1
			conn.unreliableMessagesSent += 1

			totallen += sendmelen + 28
		end
	end

	conn.cleartime = NetConn_UpdateCleartime(conn.cleartime, rate, burstsize, totallen)

	return 0
end

-- port: netconn.c NetConn_HaveClientPorts L935-938 @xonotic-v0.8.6
function netconn.NetConn_HaveClientPorts(): boolean
	return cl_numsockets ~= 0
end

-- port: netconn.c NetConn_HaveServerPorts L940-943 @xonotic-v0.8.6
function netconn.NetConn_HaveServerPorts(): boolean
	return sv_numsockets ~= 0
end

-- port: netconn.c NetConn_CloseClientPorts L945-950 @xonotic-v0.8.6
function netconn.NetConn_CloseClientPorts()
	while cl_numsockets > 0 do
		if cl_sockets[cl_numsockets] then
			lhnet.LHNET_CloseSocket(cl_sockets[cl_numsockets])
		end
		cl_numsockets -= 1
	end
end

-- port: netconn.c NetConn_OpenClientPort L952-979 @xonotic-v0.8.6
function netconn.NetConn_OpenClientPort(addressstring: string?, addresstype: number, defaultport: number)
	local address = LHNETADDRESS_New()
	local s
	local success
	if addressstring and libc.cstr(addressstring) ~= "" then
		success = LHNETADDRESS_FromString(address, addressstring, defaultport)
	else
		success = LHNETADDRESS_FromPort(address, addresstype, defaultport)
	end
	if success ~= 0 then
		s = lhnet.LHNET_OpenSocket_Connectionless(address)
		if s then
			cl_numsockets += 1
			cl_sockets[cl_numsockets] = s
			local _, addressstring2 = LHNETADDRESS_ToString(LHNET_AddressFromSocket(s), 1024, true)
			if addresstype ~= LHNETADDRESSTYPE_LOOP then
				console.Con_Printf("Client opened a socket on address %s\n", addressstring2)
			end
		else
			local _, addressstring2 = LHNETADDRESS_ToString(address, 1024, true)
			console.Con_Printf("Client failed to open a socket on address %s\n", addressstring2)
		end
	else
		console.Con_Printf("Client unable to parse address %s\n", addressstring or "(null)")
	end
end

-- port: netconn.c NetConn_OpenClientPorts L981-1002 @xonotic-v0.8.6
function netconn.NetConn_OpenClientPorts()
	local port
	netconn.NetConn_CloseClientPorts()

	Crypto_LoadKeys() -- client sockets

	local cl_netport = CV("cl_netport")
	port = if cl_netport.integer >= 0 then (if cl_netport.integer < 65535 then cl_netport.integer else 65535) else 0
	if cl_netport.integer ~= port then
		cvar.Cvar_SetValueQuick(cl_netport, port)
	end
	if port == 0 then
		console.Con_Printf("Client using an automatically assigned port\n")
	else
		console.Con_Printf("Client using port %i\n", port)
	end
	netconn.NetConn_OpenClientPort(nil, LHNETADDRESSTYPE_LOOP, 2)
	netconn.NetConn_OpenClientPort(CV("net_address").string.str, LHNETADDRESSTYPE_INET4, port)
	netconn.NetConn_OpenClientPort(CV("net_address_ipv6").string.str, LHNETADDRESSTYPE_INET6, port)
end

-- port: netconn.c NetConn_CloseServerPorts L1004-1009 @xonotic-v0.8.6
function netconn.NetConn_CloseServerPorts()
	while sv_numsockets > 0 do
		if sv_sockets[sv_numsockets] then
			lhnet.LHNET_CloseSocket(sv_sockets[sv_numsockets])
		end
		sv_numsockets -= 1
	end
end

-- port: netconn.c NetConn_OpenServerPort L1011-1049 @xonotic-v0.8.6
function netconn.NetConn_OpenServerPort(
	addressstring: string?,
	addresstype: number,
	defaultport: number,
	range: number
): boolean
	local address = LHNETADDRESS_New()
	local s
	local port
	local success

	port = defaultport
	while port <= defaultport + range do
		if addressstring and libc.cstr(addressstring) ~= "" then
			success = LHNETADDRESS_FromString(address, addressstring, port)
		else
			success = LHNETADDRESS_FromPort(address, addresstype, port)
		end
		if success ~= 0 then
			s = lhnet.LHNET_OpenSocket_Connectionless(address)
			if s then
				sv_numsockets += 1
				sv_sockets[sv_numsockets] = s
				local _, addressstring2 = LHNETADDRESS_ToString(LHNET_AddressFromSocket(s), 1024, true)
				if addresstype ~= LHNETADDRESSTYPE_LOOP then
					console.Con_Printf("Server listening on address %s\n", addressstring2)
				end
				return true
			else
				local _, addressstring2 = LHNETADDRESS_ToString(address, 1024, true)
				console.Con_Printf("Server failed to open socket on address %s\n", addressstring2)
			end
		else
			console.Con_Printf("Server unable to parse address %s\n", addressstring or "(null)")
			-- if it cant parse one address, it wont be able to parse another for sure
			return false
		end
		port += 1
	end
	return false
end

-- port: netconn.c NetConn_OpenServerPorts L1051-1080 @xonotic-v0.8.6
function netconn.NetConn_OpenServerPorts(opennetports: boolean)
	local port
	netconn.NetConn_CloseServerPorts()

	Crypto_LoadKeys() -- server sockets

	netconn.NetConn_UpdateSockets()
	local sv_netport = CV("sv_netport")
	port = if sv_netport.integer >= 0 then (if sv_netport.integer < 65535 then sv_netport.integer else 65535) else 0
	if port == 0 then
		port = 26000
	end
	console.Con_Printf("Server using port %i\n", port)
	if sv_netport.integer ~= port then
		cvar.Cvar_SetValueQuick(sv_netport, port)
	end
	if not cvar.cls_state_dedicated then
		netconn.NetConn_OpenServerPort(nil, LHNETADDRESSTYPE_LOOP, 1, 1)
	end
	if opennetports then
		local ip4success =
			netconn.NetConn_OpenServerPort(CV("net_address").string.str, LHNETADDRESSTYPE_INET4, port, 100)
		netconn.NetConn_OpenServerPort(
			CV("net_address_ipv6").string.str,
			LHNETADDRESSTYPE_INET6,
			port,
			if ip4success then 1 else 100
		)
	end
	if sv_numsockets == 0 then
		error("Host_Error: NetConn_OpenServerPorts: unable to open any ports!", 0)
	end
end

-- port: netconn.c NetConn_ChooseClientSocketForAddress L1082-1089 @xonotic-v0.8.6
function netconn.NetConn_ChooseClientSocketForAddress(address: any): any
	local i, a = 0, LHNETADDRESS_GetAddressType(address)
	while i < cl_numsockets do
		if cl_sockets[i + 1] and LHNETADDRESS_GetAddressType(LHNET_AddressFromSocket(cl_sockets[i + 1])) == a then
			return cl_sockets[i + 1]
		end
		i += 1
	end
	return nil
end

-- port: netconn.c NetConn_ChooseServerSocketForAddress L1091-1098 @xonotic-v0.8.6
function netconn.NetConn_ChooseServerSocketForAddress(address: any): any
	local i, a = 0, LHNETADDRESS_GetAddressType(address)
	while i < sv_numsockets do
		if sv_sockets[i + 1] and LHNETADDRESS_GetAddressType(LHNET_AddressFromSocket(sv_sockets[i + 1])) == a then
			return sv_sockets[i + 1]
		end
		i += 1
	end
	return nil
end

local function newnetgraph(): { [number]: any }
	local g = {}
	for i = 0, NETGRAPH_PACKETS - 1 do
		g[i] = { time = 0, reliablebytes = 0, unreliablebytes = 0, ackbytes = 0, cleartime = 0 }
	end
	return g
end

-- port: netconn.c NetConn_Open L1100-1117 @xonotic-v0.8.6
function netconn.NetConn_Open(mysocket: any, peeraddress: any): any
	local realtime = prvm_edict.realtime
	-- (Mem_Alloc: zeroed memory)
	local conn: any = {
		next = nil,
		mysocket = nil,
		peeraddress = LHNETADDRESS_New(),
		connecttime = 0,
		timeout = 0,
		lastMessageTime = 0,
		lastSendTime = 0,
		message = nil,
		sendMessageLength = 0,
		sendMessage = buffer.create(NET_MAXMESSAGE),
		receiveMessageLength = 0,
		receiveMessage = buffer.create(NET_MAXMESSAGE),
		outgoing_unreliable_sequence = 0,
		nq = { ackSequence = 0, sendSequence = 0, receiveSequence = 0, unreliableReceiveSequence = 0 },
		qw = {
			fatal_error = false,
			last_received = 0,
			frame_latency = 0,
			frame_rate = 0,
			drop_count = 0,
			good_count = 0,
			qport = 0,
			incoming_sequence = 0,
			incoming_acknowledged = 0,
			incoming_reliable_acknowledged = false,
			incoming_reliable_sequence = false,
			reliable_sequence = false,
			last_reliable_sequence = 0,
		},
		cleartime = 0,
		incoming_cleartime = 0,
		incoming_packetcounter = 0,
		incoming_netgraph = newnetgraph(),
		outgoing_packetcounter = 0,
		outgoing_netgraph = newnetgraph(),
		address = "",
		crypto = { authenticated = false, use_aes = false },
		packetsSent = 0,
		packetsReSent = 0,
		packetsReceived = 0,
		receivedDuplicateCount = 0,
		droppedDatagrams = 0,
		unreliableMessagesSent = 0,
		unreliableMessagesReceived = 0,
		reliableMessagesSent = 0,
		reliableMessagesReceived = 0,
	}
	conn.mysocket = mysocket
	LHNETADDRESS_Copy(conn.peeraddress, peeraddress)
	conn.lastMessageTime = realtime
	conn.message = common.SZ_New(NET_MAXMESSAGE) -- data = messagedata, maxsize = sizeof(messagedata), cursize = 0
	-- LordHavoc: (inspired by ProQuake) use a short connect timeout to
	-- reduce effectiveness of connection request floods
	conn.timeout = realtime + CV("net_connecttimeout").value
	local _, a = LHNETADDRESS_ToString(conn.peeraddress, 128, true)
	conn.address = a
	conn.next = netconn.netconn_list
	netconn.netconn_list = conn
	return conn
end
local NetConn_Open = netconn.NetConn_Open

-- server_floodaddress_t sv.<name>[n] (server.h L70-75, L141-142): { address, lasttime }, C element i at [i + 1];
-- created zeroed on first use (server.Clear empties sv like the memset of SV_SpawnServer)
local function floodlist(name: string, n: number): { any }
	local sv = server.sv :: any
	local l = sv[name]
	if not l then
		l = table.create(n)
		for i = 1, n do
			l[i] = { address = LHNETADDRESS_New(), lasttime = 0 }
		end
		sv[name] = l
	end
	return l
end

-- port: netconn.c NetConn_Close L1120-1146 @xonotic-v0.8.6
function netconn.NetConn_Close(conn: any)
	local c
	-- remove connection from list

	-- allow the client to reconnect immediately
	netconn.NetConn_ClearFlood(
		conn.peeraddress,
		floodlist("connectfloodaddresses", MAX_CONNECTFLOODADDRESSES),
		MAX_CONNECTFLOODADDRESSES
	)

	if conn == netconn.netconn_list then
		netconn.netconn_list = conn.next
	else
		c = netconn.netconn_list
		while c do
			if c.next == conn then
				c.next = conn.next
				break
			end
			c = c.next
		end
		-- not found in list, we'll avoid crashing here...
		if not c then
			return
		end
	end
	-- free connection (Mem_Free)
end

local clientport = -1
local clientport2 = -1
local hostport = -1
-- port: netconn.c NetConn_UpdateSockets L1151-1198 @xonotic-v0.8.6
function netconn.NetConn_UpdateSockets()
	local i, j

	-- TODO add logic to automatically close sockets if needed
	lhnet.LHNET_DefaultDSCP(CV("net_tos_dscp").integer)

	if not cvar.cls_state_dedicated then
		local cl_netport = CV("cl_netport")
		if clientport2 ~= cl_netport.integer then
			clientport2 = cl_netport.integer
			if cmd.cls_state_connected then
				console.Con_Print('Changing "cl_port" will not take effect until you reconnect.\n')
			end
		end
		if not cmd.cls_state_connected and clientport ~= clientport2 then -- (cls.state == ca_disconnected)
			clientport = clientport2
			netconn.NetConn_CloseClientPorts()
		end
		if cl_numsockets == 0 then
			netconn.NetConn_OpenClientPorts()
		end
	end

	local sv_netport = CV("sv_netport")
	if hostport ~= sv_netport.integer then
		hostport = sv_netport.integer
		if (server.sv :: any).active then
			console.Con_Print('Changing "port" will not take effect until "map" command is executed.\n')
		end
	end

	j = 0
	while j < MAX_RCONS do
		i = (cls_rcon_ringpos + j + 1) % MAX_RCONS
		if cls_rcon_commands[i] ~= "" then
			if prvm_edict.realtime > cls_rcon_timeout[i] then
				console.Con_Printf(
					"rcon to %s (for command %s) failed: challenge request timed out\n",
					"(address)",
					cls_rcon_commands[i]
				)
				cls_rcon_commands[i] = ""
				break
			end
		end
		j += 1
	end
end

-- the incoming netgraph entries of the dropped datagrams and the received one (NetConn_ReceivedMessage)
local function netgraph_incoming(conn: any, unreliablebytes: number)
	conn.incoming_packetcounter = (conn.incoming_packetcounter + 1) % NETGRAPH_PACKETS
	local g = conn.incoming_netgraph[conn.incoming_packetcounter]
	g.time = prvm_edict.realtime
	g.cleartime = conn.incoming_cleartime
	g.unreliablebytes = unreliablebytes
	g.reliablebytes = NETGRAPH_NOPACKET
	g.ackbytes = NETGRAPH_NOPACKET
end

-- the received message into cl_message / sv_message (SZ_Clear, SZ_Write, MSG_BeginReading)
local function deliver(conn: any, data: buffer, offset: number, length: number)
	local m = if conn == netconn.cls_netcon then netconn.cl_message else netconn.sv_message
	common.SZ_Clear(m)
	SZ_WriteBuf(m, data, offset, length)
	MSG_BeginReading(m)
end

local temppacket = buffer.create(8)
local acksendbuffer = buffer.create(NET_HEADERSIZE + NET_MAXMESSAGE)

-- port: netconn.c NetConn_ReceivedMessage L1200-1508 @xonotic-v0.8.6
-- (data: the packet, at offset 0)
function netconn.NetConn_ReceivedMessage(
	conn: any,
	data: buffer,
	length: number,
	protocol: number,
	newtimeout: number
): number
	local originallength = length
	local realtime = prvm_edict.realtime
	if length < 8 then
		return 0
	end

	if protocol == P.QUAKEWORLD then
		notPorted("NetConn_ReceivedMessage QuakeWorld branch (netconn.c L1209-1307)")
		return 0
	else
		local count
		local flags
		local sequence
		local qlength
		local sendme: buffer?
		local sendmelen
		local d = 0 -- data offset (C: data += ...)
		local cl_rate = CV("cl_rate").integer
		local cl_rate_burstsize = CV("cl_rate_burstsize").integer

		originallength = length
		local dec
		dec, length = Crypto_DecryptPacket(conn.crypto, data, length)
		if not dec then
			return 0
		end
		data = dec
		if length < 8 then
			return 0
		end

		qlength = u32(BuffBigLong(data, d))
		flags = band(qlength, bnot(NETFLAG_LENGTH_MASK))
		qlength = band(qlength, NETFLAG_LENGTH_MASK)
		-- control packets were already handled
		if band(flags, NETFLAG_CTL) == 0 and qlength == length then
			sequence = u32(BuffBigLong(data, d + 4))
			conn.packetsReceived += 1
			d += 8
			length -= 8
			if band(flags, NETFLAG_UNRELIABLE) ~= 0 then
				if sequence >= conn.nq.unreliableReceiveSequence then
					if sequence > conn.nq.unreliableReceiveSequence then
						count = sequence - conn.nq.unreliableReceiveSequence
						conn.droppedDatagrams = toint32(conn.droppedDatagrams + count)
						--Con_DPrintf("Dropped %u datagram(s)\n", count);
						-- If too may packets have been dropped, only write the
						-- last NETGRAPH_PACKETS ones to the netgraph. Why?
						-- Because there's no point in writing more than
						-- these as the netgraph is going to be full anyway.
						if count > NETGRAPH_PACKETS then
							count = NETGRAPH_PACKETS
						end
						while count > 0 do
							count -= 1
							netgraph_incoming(conn, NETGRAPH_LOSTPACKET)
						end
					end
					netgraph_incoming(conn, originallength + 28)
					conn.incoming_cleartime = NetConn_UpdateCleartime(
						conn.incoming_cleartime,
						cl_rate,
						cl_rate_burstsize,
						originallength + 28
					)

					conn.nq.unreliableReceiveSequence = u32(sequence + 1)
					conn.lastMessageTime = realtime
					conn.timeout = realtime + newtimeout
					conn.unreliableMessagesReceived += 1
					if length > 0 then
						deliver(conn, data, d, length)
						return 2
					end
				end
				--else
				--	Con_DPrint("Got a stale datagram\n");
				return 1
			elseif band(flags, NETFLAG_ACK) ~= 0 then
				local ig = conn.incoming_netgraph[conn.incoming_packetcounter]
				ig.ackbytes += originallength + 28
				conn.incoming_cleartime =
					NetConn_UpdateCleartime(conn.incoming_cleartime, cl_rate, cl_rate_burstsize, originallength + 28)

				if sequence == u32(conn.nq.sendSequence - 1) then
					if sequence == conn.nq.ackSequence then
						conn.nq.ackSequence = u32(conn.nq.ackSequence + 1)
						if conn.nq.ackSequence ~= conn.nq.sendSequence then
							console.Con_DPrint("ack sequencing error\n")
						end
						conn.lastMessageTime = realtime
						conn.timeout = realtime + newtimeout
						if conn.sendMessageLength > MAX_PACKETFRAGMENT then
							local packetLen
							local dataLen
							local eom

							conn.sendMessageLength -= MAX_PACKETFRAGMENT
							buffer.copy(
								conn.sendMessage,
								0,
								conn.sendMessage,
								MAX_PACKETFRAGMENT,
								conn.sendMessageLength
							)

							if conn.sendMessageLength <= MAX_PACKETFRAGMENT then
								dataLen = conn.sendMessageLength
								eom = NETFLAG_EOM
							else
								dataLen = MAX_PACKETFRAGMENT
								eom = 0
							end

							packetLen = NET_HEADERSIZE + dataLen

							StoreBigLong(
								acksendbuffer,
								0,
								bor(packetLen, bor(NETFLAG_DATA, eom, NetConn_AddCryptoFlag(conn.crypto)))
							)
							StoreBigLong(acksendbuffer, 4, conn.nq.sendSequence)
							buffer.copy(acksendbuffer, NET_HEADERSIZE, conn.sendMessage, 0, dataLen)

							conn.nq.sendSequence = u32(conn.nq.sendSequence + 1)

							sendme, sendmelen = Crypto_EncryptPacket(conn.crypto, acksendbuffer, packetLen)
							if
								sendme
								and NetConn_Write(conn.mysocket, sendme, sendmelen, conn.peeraddress) == sendmelen
							then
								conn.lastSendTime = realtime
								conn.packetsSent += 1
							end
						else
							conn.sendMessageLength = 0
						end
					end
					--else
					--	Con_DPrint("Duplicate ACK received\n");
				end
				--else
				--	Con_DPrint("Stale ACK received\n");
				return 1
			elseif band(flags, NETFLAG_DATA) ~= 0 then
				local ig = conn.incoming_netgraph[conn.incoming_packetcounter]
				ig.reliablebytes += originallength + 28
				conn.incoming_cleartime =
					NetConn_UpdateCleartime(conn.incoming_cleartime, cl_rate, cl_rate_burstsize, originallength + 28)

				conn.outgoing_netgraph[conn.outgoing_packetcounter].ackbytes += 8 + 28

				StoreBigLong(temppacket, 0, bor(8, NETFLAG_ACK, NetConn_AddCryptoFlag(conn.crypto)))
				StoreBigLong(temppacket, 4, sequence)
				sendme, sendmelen = Crypto_EncryptPacket(conn.crypto, temppacket, 8)
				if sendme then
					NetConn_Write(conn.mysocket, sendme, sendmelen, conn.peeraddress)
				end
				if sequence == conn.nq.receiveSequence then
					conn.lastMessageTime = realtime
					conn.timeout = realtime + newtimeout
					conn.nq.receiveSequence = u32(conn.nq.receiveSequence + 1)
					if conn.receiveMessageLength + length <= NET_MAXMESSAGE then
						buffer.copy(conn.receiveMessage, conn.receiveMessageLength, data, d, length)
						conn.receiveMessageLength += length
					else
						console.Con_Printf(
							"Reliable message (seq: %i) too big for message buffer!\nDropping the message!\n",
							toint32(sequence)
						)
						conn.receiveMessageLength = 0
						return 1
					end
					if band(flags, NETFLAG_EOM) ~= 0 then
						conn.reliableMessagesReceived += 1
						length = conn.receiveMessageLength
						conn.receiveMessageLength = 0
						if length > 0 then
							deliver(conn, conn.receiveMessage, 0, length)
							return 2
						end
					end
				else
					conn.receivedDuplicateCount += 1
				end
				return 1
			end
		end
	end
	return 0
end
local NetConn_ReceivedMessage = netconn.NetConn_ReceivedMessage

-- port: netconn.c NetConn_BuildChallengeString L2490-2503 @xonotic-v0.8.6
local function NetConn_BuildChallengeString(bufferlength: number): string
	local i
	local c
	local out = table.create(bufferlength)
	i = 0
	while i < bufferlength - 1 do
		repeat
			c = libc.rand() % (127 - 33) + 33
		until not (c == 92 or c == 59 or c == 34 or c == 37 or c == 47) -- '\\' ';' '"' '%' '/'
		out[i + 1] = string.char(c)
		i += 1
	end
	return table.concat(out)
end
netconn.NetConn_BuildChallengeString = NetConn_BuildChallengeString

-- dpsnprintf into a buffer of size bytes: (the C return value, the text the buffer holds)
local function dpsnprintf(size: number, s: string): (number, string)
	if #s >= size then
		return -1, string.sub(s, 1, size - 1)
	end
	return #s, s
end

-- PRVM_GetString of a string global / edict field (prog->globaloffsets / fieldoffsets; -1 = missing: C prints and
-- reads prvm_badvalue, string 0)
local function globalstring(prog: any, name: string, line: number): string
	local o = prvm_cmds.GlobalOfs(prog, name)
	if o < 0 then
		console.Con_Printf("Invalid fieldoffset at %s:%i\n", "netconn.c", line)
		return prvm_edict.PRVM_GetString(prog, 0)
	end
	return prvm_edict.PRVM_GetString(prog, buffer.readi32(prog.globals, o * 4))
end
local function edictstring(prog: any, ed: number, name: string, line: number): string
	local o = prvm_edict.FieldOfs(prog, name)
	if o < 0 then
		console.Con_Printf("Invalid fieldoffset at %s:%i\n", "netconn.c", line)
		return prvm_edict.PRVM_GetString(prog, 0)
	end
	if ed >= prog.max_edicts then
		error(string.format("Host_Error: PRVM_EDICT_NUM: %s: bad number %i", prog.name or "server", ed), 0)
	end
	return prvm_edict.PRVM_GetString(prog, buffer.readi32(prog.edictsfields, (ed * prog.entityfields + o) * 4))
end

-- port: netconn.c NetConn_BuildStatusResponse L2506-2670 @xonotic-v0.8.6
-- (div0) build the full response only if possible; better a getinfo response than no response at all if getstatus
-- won't fit. Returns (success, the response text).
local function NetConn_BuildStatusResponse(challenge: string?, out_size: number, fullstatus: boolean): (boolean, string)
	local prog: any = cvar.prvm_prog_list[0] -- SVVM_prog
	local sv = server.sv :: any
	local s = svs()
	local qcstatus
	local nb_clients, nb_bots, i = 0, 0, 0
	local length
	local teambuf
	local crypto_idstring
	local worldstatusstr
	local out_msg

	-- How many clients are there?
	i = 0
	while i < s.maxclients do
		local c = clientslot(i)
		if c.active then
			nb_clients += 1
			if not c.netconnection then
				nb_bots += 1
			end
		end
		i += 1
	end

	qcstatus = ""
	worldstatusstr = globalstring(prog, "worldstatus", 2528)
	if worldstatusstr ~= "" then
		local p = table.create(255)
		for k = 1, #worldstatusstr do
			if #p >= 256 - 1 then
				break
			end
			local q = string.byte(worldstatusstr, k)
			if q ~= 92 and q ~= 10 then
				table.insert(p, string.char(q))
			end
		end
		qcstatus = table.concat(p)
	end

	--/ \TODO: we should add more information for the full status string
	crypto_idstring = Crypto_GetInfoResponseDataString()
	length, out_msg = dpsnprintf(
		out_size,
		"\255\255\255\255"
			.. (if fullstatus then "statusResponse" else "infoResponse")
			.. "\n"
			.. "\\gamename\\"
			.. gamenetworkfiltername
			.. "\\modname\\"
			.. com_modname
			.. string.format("\\gameversion\\%d\\sv_maxclients\\%d", CV("gameversion").integer, s.maxclients)
			.. string.format("\\clients\\%d\\bots\\%d\\mapname\\", nb_clients, nb_bots)
			.. sv.worldbasename
			.. "\\hostname\\"
			.. CV("hostname").string.str
			.. string.format("\\protocol\\%d", NET_PROTOCOL_VERSION)
			.. (if qcstatus ~= "" then "\\qcstatus\\" else "")
			.. qcstatus
			.. (if challenge then "\\challenge\\" else "")
			.. (challenge or "")
			.. (if crypto_idstring then "\\d0_blind_id\\" else "")
			.. (crypto_idstring or "")
			.. (if fullstatus then "\n" else "")
	)

	-- Make sure it fits in the buffer
	if length < 0 then
		return false, out_msg
	end

	if fullstatus then
		local left
		local savelength
		local parts = { out_msg }

		savelength = length

		left = out_size - length

		i = 0
		while i < s.maxclients do
			local client = clientslot(i)
			if client.active then
				local pingvalue
				local statusstr

				-- Remove all characters '"' and '\' in the player name
				local cleanname = string.sub(string.gsub(libc.cstr(client.name.str), '["\\]', ""), 1, 128 - 1)

				pingvalue = libc.toint(R(client.ping * R(1000.0)))
				if client.netconnection then
					pingvalue = if pingvalue >= 1 then (if pingvalue < 9999 then pingvalue else 9999) else 1
				else
					pingvalue = 0
				end

				qcstatus = ""
				statusstr = edictstring(prog, i + 1, "clientstatus", 2607)
				if statusstr ~= "" then
					local p = table.create(255)
					for k = 1, #statusstr do
						if #p >= 256 - 1 then
							break
						end
						local q = string.byte(statusstr, k)
						if q ~= 92 and q ~= 34 and not common.ISWHITESPACE(q) then
							table.insert(p, string.char(q))
						end
					end
					qcstatus = table.concat(p)
				end

				if IS_NEXUIZ_DERIVED and (CV("teamplay").integer > 0) then
					-- selene: allow(if_same_then_else)
					if client.frags == -666 then -- spectator
						teambuf = " 0"
					elseif client.colors == 0x44 then -- red team
						teambuf = " 1"
					elseif client.colors == 0xDD then -- blue team
						teambuf = " 2"
					elseif client.colors == 0xCC then -- yellow team
						teambuf = " 3"
					elseif client.colors == 0x99 then -- pink team
						teambuf = " 4"
					else
						teambuf = " 0"
					end
				else
					teambuf = ""
				end

				-- note: team number is inserted according to SoF2 protocol
				local line
				if qcstatus ~= "" then
					line = qcstatus .. string.format(" %d", pingvalue) .. teambuf .. ' "' .. cleanname .. '"\n'
				else
					line = string.format("%d %d", client.frags, pingvalue) .. teambuf .. ' "' .. cleanname .. '"\n'
				end
				length = dpsnprintf(left, line)

				if length < 0 then
					-- out of space?
					-- turn it into an infoResponse!
					-- (out_msg[savelength] = 0; memcpy(out_msg + 4, "infoResponse\n", 13);
					--  memmove(out_msg + 17, out_msg + 19, savelength - 19): the last two bytes stay)
					local h = out_msg
					return true,
						string.sub(h, 1, 4) .. "infoResponse\n" .. string.sub(h, 20, savelength) .. string.sub(
							h,
							savelength - 1,
							savelength
						)
				end
				table.insert(parts, line)
				left -= length
			end
			i += 1
		end
		out_msg = table.concat(parts)
	end

	return true, out_msg
end
netconn.NetConn_BuildStatusResponse = NetConn_BuildStatusResponse

-- port: netconn.c NetConn_PreventFlood L2672-2713 @xonotic-v0.8.6
local function NetConn_PreventFlood(
	peeraddress: any,
	floodlist: { any },
	floodlength: number,
	floodtime: number,
	renew: boolean
): boolean
	local floodslotnum, bestfloodslotnum
	local bestfloodtime
	local noportpeeraddress = LHNETADDRESS_New()
	local realtime = prvm_edict.realtime
	-- see if this is a connect flood
	LHNETADDRESS_Copy(noportpeeraddress, peeraddress)
	LHNETADDRESS_SetPort(noportpeeraddress, 0)
	bestfloodslotnum = 0
	bestfloodtime = floodlist[bestfloodslotnum + 1].lasttime
	floodslotnum = 0
	while floodslotnum < floodlength do
		local f = floodlist[floodslotnum + 1]
		if bestfloodtime >= f.lasttime then
			bestfloodtime = f.lasttime
			bestfloodslotnum = floodslotnum
		end
		if f.lasttime ~= 0 and LHNETADDRESS_Compare(noportpeeraddress, f.address) == 0 then
			-- this address matches an ongoing flood address
			if realtime < f.lasttime + floodtime then
				if renew then
					-- renew the ban on this address so it does not expire
					-- until the flood has subsided
					f.lasttime = realtime
				end
				--Con_Printf("Flood detected!\n");
				return true
			end
			-- the flood appears to have subsided, so allow this
			bestfloodslotnum = floodslotnum -- reuse the same slot
			break
		end
		floodslotnum += 1
	end
	-- begin a new timeout on this address
	LHNETADDRESS_Copy(floodlist[bestfloodslotnum + 1].address, noportpeeraddress)
	floodlist[bestfloodslotnum + 1].lasttime = realtime
	--Con_Printf("Flood detection initiated!\n");
	return false
end

-- port: netconn.c NetConn_ClearFlood L2715-2733 @xonotic-v0.8.6
function netconn.NetConn_ClearFlood(peeraddress: any, floodlist: { any }, floodlength: number)
	local floodslotnum
	local noportpeeraddress = LHNETADDRESS_New()
	-- see if this is a connect flood
	LHNETADDRESS_Copy(noportpeeraddress, peeraddress)
	LHNETADDRESS_SetPort(noportpeeraddress, 0)
	floodslotnum = 0
	while floodslotnum < floodlength do
		local f = floodlist[floodslotnum + 1]
		if f.lasttime ~= 0 and LHNETADDRESS_Compare(noportpeeraddress, f.address) == 0 then
			-- this address matches an ongoing flood address
			-- remove the ban
			f.address.addresstype = LHNETADDRESSTYPE_NONE
			f.lasttime = 0
			--Con_Printf("Flood cleared!\n");
		end
		floodslotnum += 1
	end
end

-- port: netconn.c RCon_Execute L2901-2937 @xonotic-v0.8.6
local function RCon_Execute()
	-- RCon_Authenticate (rcon_password / rcon_restricted_password, hmac_mdfour_* / plaintext comparators),
	-- Con_Rcon_Redirect_Init, Cmd_ExecuteString of the commands: not ported
	notPorted("rcon / srcon (netconn.c RCon_Authenticate, RCon_Execute: the packet is dropped)")
end

local function str_eq_prefix(s: string, prefix: string): boolean
	return string.sub(s, 1, #prefix) == prefix
end

local MSG_ReadByte, MSG_ReadString = common.MSG_ReadByte, common.MSG_ReadString -- (common.c)

-- the CCREP_* reply in sv_message: header placeholder, the body written by fill, the header, the write
local function ctlreply(mysocket: any, peeraddress: any, fill: (any) -> ())
	local m = netconn.sv_message
	common.SZ_Clear(m)
	-- save space for the header, filled in later
	common.MSG_WriteLong(m, 0)
	fill(m)
	StoreBigLong(m.data, 0, bor(NETFLAG_CTL, band(m.cursize, NETFLAG_LENGTH_MASK)))
	NetConn_Write(mysocket, m.data, m.cursize, peeraddress)
	common.SZ_Clear(m)
end

-- port: netconn.c NetConn_ServerParsePacket L2939-3602 @xonotic-v0.8.6
-- (returns the C int: false / true as 0 / 1, or NetConn_ReceivedMessage's 2)
function netconn.NetConn_ServerParsePacket(mysocket: any, data: buffer, length: number, peeraddress: any): number
	local i, ret, clientnum, best
	local besttime
	local str
	local sv = server.sv :: any
	local s = svs()
	local realtime = prvm_edict.realtime
	local islocal = (LHNETADDRESS_GetAddressType(peeraddress) == LHNETADDRESSTYPE_LOOP)
	local sendlength
	local challenges = netconn.challenges

	if not sv.active then
		return 0
	end

	-- convert the address to a string incase we need it
	local _, addressstring2 = LHNETADDRESS_ToString(peeraddress, 128, true)

	-- see if we can identify the sender as a local player
	-- (this is necessary for rcon to send a reliable reply if the client is
	--  actually on the server, not sending remotely)
	i = 0
	local host_client: any = nil
	while i < s.maxclients do
		host_client = clientslot(i)
		if
			host_client.netconnection
			and host_client.netconnection.mysocket == mysocket
			and LHNETADDRESS_Compare(host_client.netconnection.peeraddress, peeraddress) == 0
		then
			break
		end
		i += 1
	end
	if i == s.maxclients then
		host_client = nil
	end
	server.host_client = host_client

	if
		length >= 5
		and buffer.readu8(data, 0) == 255
		and buffer.readu8(data, 1) == 255
		and buffer.readu8(data, 2) == 255
		and buffer.readu8(data, 3) == 255
	then
		-- received a command string - strip off the packaging and put it
		-- into our string buffer with NULL termination
		length -= 4
		length = if length < 16384 - 1 then length else 16384 - 1
		str = buffer.readstring(data, 4, length) -- (stringbuf[length] = 0)

		if CVopt("developer_extra", 0) ~= 0 then
			console.Con_Printf("NetConn_ServerParsePacket: %s sent us a command:\n", addressstring2)
			notPorted("Com_HexDumpToConsole (common.c) for developer_extra")
		end

		local cret
		cret, sendlength = Crypto_ServerParsePacket(str, length)
		-- (CRYPTO_NOMATCH: nothing to do)
		if cret == CRYPTO_MATCH then
			if sendlength ~= 0 then
				notPorted("Crypto_ServerParsePacket reply (crypto.c)")
			end
		elseif cret == CRYPTO_DISCARD then
			if sendlength ~= 0 then
				notPorted("Crypto_ServerParsePacket reply (crypto.c)")
			end
			return 1
		elseif cret == CRYPTO_REPLACE then
			notPorted("Crypto_ServerParsePacket CRYPTO_REPLACE (crypto.c)")
		end

		if length >= 12 and str_eq_prefix(str, "getchallenge") and (islocal or CV("sv_public").integer > -3) then
			i, best, besttime = 0, 0, realtime
			while i < MAX_CHALLENGES do
				if challenges[i + 1].time > 0 then
					if LHNETADDRESS_Compare(peeraddress, challenges[i + 1].address) == 0 then
						break
					end
				end
				if besttime > challenges[i + 1].time then
					best = i
					besttime = challenges[best + 1].time
				end
				i += 1
			end
			-- if we did not find an exact match, choose the oldest and
			-- update address and string
			if i == MAX_CHALLENGES then
				i = best
				LHNETADDRESS_Copy(challenges[i + 1].address, peeraddress)
				challenges[i + 1].string = NetConn_BuildChallengeString(12)
			else
				-- flood control: drop if requesting challenge too often
				if challenges[i + 1].time > realtime - CV("net_challengefloodblockingtimeout").value then
					return 1
				end
			end
			challenges[i + 1].time = realtime
			-- send the challenge
			local _, body = dpsnprintf(2800 - 4, "challenge " .. challenges[i + 1].string)
			local response = "\255\255\255\255" .. body .. "\0" -- response_len = strlen(response) + 1
			Crypto_ServerAppendToChallenge()
			NetConn_Write(mysocket, buffer.fromstring(response), #response, peeraddress)
			return 1
		end
		if length > 8 and str_eq_prefix(str, "connect\\") then
			local sv_
			local client
			local crypto = Crypto_ServerGetInstance(peeraddress)
			str = string.sub(str, 8)
			length -= 7

			if crypto and crypto.authenticated then
				-- no need to check challenge
				notPorted("connect of an authenticated crypto connection (crypto.c)")
			else
				sv_ = common.InfoString_GetValue(str, "challenge", MAX_INPUTLINE)
				if sv_ then
					-- validate the challenge
					i = 0
					while i < MAX_CHALLENGES do
						if challenges[i + 1].time > 0 then
							if
								LHNETADDRESS_Compare(peeraddress, challenges[i + 1].address) == 0
								and challenges[i + 1].string == sv_
							then
								break
							end
						end
						i += 1
					end
					-- if the challenge is not recognized, drop the packet
					if i == MAX_CHALLENGES then
						return 1
					end
				end
			end

			sv_ = common.InfoString_GetValue(str, "message", MAX_INPUTLINE)
			if sv_ then
				console.Con_DPrintf("Connecting client %s sent us the message: %s\n", addressstring2, sv_)
			end

			if not (islocal or CV("sv_public").integer > -2) then
				local reason = CV("sv_public_rejectreason").string.str
				if CVopt("developer_extra", 0) ~= 0 then
					console.Con_Printf(
						'Datagram_ParseConnectionless: sending "reject %s" to %s.\n',
						reason,
						addressstring2
					)
				end
				local _, body = dpsnprintf(2800 - 4, "reject " .. reason)
				NetConn_WriteString(mysocket, "\255\255\255\255" .. body, peeraddress)
				return 1
			end

			-- check engine protocol
			sv_ = common.InfoString_GetValue(str, "protocol", MAX_INPUTLINE)
			if not sv_ or sv_ ~= "darkplaces 3" then
				if CVopt("developer_extra", 0) ~= 0 then
					console.Con_Printf(
						'Datagram_ParseConnectionless: sending "reject Wrong game protocol." to %s.\n',
						addressstring2
					)
				end
				NetConn_WriteString(mysocket, "\255\255\255\255reject Wrong game protocol.", peeraddress)
				return 1
			end

			-- see if this is a duplicate connection request or a disconnected
			-- client who is rejoining to the same client slot
			clientnum = 0
			while clientnum < s.maxclients do
				client = clientslot(clientnum)
				if
					client.netconnection
					and LHNETADDRESS_Compare(peeraddress, client.netconnection.peeraddress) == 0
				then
					-- this is a known client...
					if crypto and crypto.authenticated then
						notPorted("connect of an authenticated crypto connection (crypto.c)")
					else
						-- reject if downgrading!
						if client.netconnection.crypto and client.netconnection.crypto.authenticated then
							if CVopt("developer_extra", 0) ~= 0 then
								console.Con_Printf(
									'Datagram_ParseConnectionless: sending "reject Attempt to downgrade crypto." to %s.\n',
									addressstring2
								)
							end
							NetConn_WriteString(
								mysocket,
								"\255\255\255\255reject Attempt to downgrade crypto.",
								peeraddress
							)
							return 1
						end
					end
					if client.begun then
						-- client crashed and is coming back,
						-- keep their stuff intact
						if CVopt("developer_extra", 0) ~= 0 then
							console.Con_Printf(
								'Datagram_ParseConnectionless: sending "accept" to %s.\n',
								addressstring2
							)
						end
						NetConn_WriteString(mysocket, "\255\255\255\255accept", peeraddress)
						SV_SendServerinfo(client)
					else
						-- client is still trying to connect,
						-- so we send a duplicate reply
						if CVopt("developer_extra", 0) ~= 0 then
							console.Con_Printf(
								"Datagram_ParseConnectionless: sending duplicate accept to %s.\n",
								addressstring2
							)
						end
						NetConn_WriteString(mysocket, "\255\255\255\255accept", peeraddress)
					end
					return 1
				end
				clientnum += 1
			end

			if
				NetConn_PreventFlood(
					peeraddress,
					floodlist("connectfloodaddresses", MAX_CONNECTFLOODADDRESSES),
					MAX_CONNECTFLOODADDRESSES,
					CV("net_connectfloodblockingtimeout").value,
					true
				)
			then
				return 1
			end

			-- find an empty client slot for this new client
			clientnum = 0
			while clientnum < s.maxclients do
				client = clientslot(clientnum)
				local conn
				if not client.active then
					conn = NetConn_Open(mysocket, peeraddress)
				end
				if conn then
					-- allocated connection
					if CVopt("developer_extra", 0) ~= 0 then
						console.Con_Printf('Datagram_ParseConnectionless: sending "accept" to %s.\n', conn.address)
					end
					NetConn_WriteString(mysocket, "\255\255\255\255accept", peeraddress)
					-- now set up the client
					SV_ConnectClient(clientnum, conn)
					netconn.NetConn_Heartbeat(1)
					return 1
				end
				clientnum += 1
			end

			-- no empty slots found - server is full
			if CVopt("developer_extra", 0) ~= 0 then
				console.Con_Printf(
					'Datagram_ParseConnectionless: sending "reject Server is full." to %s.\n',
					addressstring2
				)
			end
			NetConn_WriteString(mysocket, "\255\255\255\255reject Server is full.", peeraddress)

			return 1
		end
		if length >= 7 and str_eq_prefix(str, "getinfo") and (islocal or CV("sv_public").integer > -1) then
			local challenge: string? = nil

			if
				NetConn_PreventFlood(
					peeraddress,
					floodlist("getstatusfloodaddresses", MAX_GETSTATUSFLOODADDRESSES),
					MAX_GETSTATUSFLOODADDRESSES,
					CV("net_getstatusfloodblockingtimeout").value,
					false
				)
			then
				return 1
			end

			-- If there was a challenge in the getinfo message
			if length > 8 and string.byte(str, 8) == 32 then
				challenge = libc.cstr(string.sub(str, 9))
			end

			local ok, response = NetConn_BuildStatusResponse(challenge, 2800, false)
			if ok then
				if CVopt("developer_extra", 0) ~= 0 then
					console.Con_DPrintf("Sending reply to master %s - %s\n", addressstring2, response)
				end
				NetConn_WriteString(mysocket, response, peeraddress)
			end
			return 1
		end
		if length >= 9 and str_eq_prefix(str, "getstatus") and (islocal or CV("sv_public").integer > -1) then
			local challenge: string? = nil

			if
				NetConn_PreventFlood(
					peeraddress,
					floodlist("getstatusfloodaddresses", MAX_GETSTATUSFLOODADDRESSES),
					MAX_GETSTATUSFLOODADDRESSES,
					CV("net_getstatusfloodblockingtimeout").value,
					false
				)
			then
				return 1
			end

			-- If there was a challenge in the getinfo message
			if length > 10 and string.byte(str, 10) == 32 then
				challenge = libc.cstr(string.sub(str, 11))
			end

			local ok, response = NetConn_BuildStatusResponse(challenge, 2800, true)
			if ok then
				if CVopt("developer_extra", 0) ~= 0 then
					console.Con_DPrintf("Sending reply to client %s - %s\n", addressstring2, response)
				end
				NetConn_WriteString(mysocket, response, peeraddress)
			end
			return 1
		end
		if length >= 37 and str_eq_prefix(str, "srcon HMAC-MD4 TIME ") then
			if CV("rcon_secure").integer > 1 then
				return 1
			end
			if not string.find(libc.cstr(string.sub(str, 38)), " ", 1, true) then
				return 1 -- invalid packet
			end
			RCon_Execute()
			return 1
		end
		if length >= 42 and str_eq_prefix(str, "srcon HMAC-MD4 CHALLENGE ") then
			if not string.find(libc.cstr(string.sub(str, 43)), " ", 1, true) then
				return 1 -- invalid packet
			end
			RCon_Execute()
			return 1
		end
		if length >= 5 and str_eq_prefix(str, "rcon ") then
			if CV("rcon_secure").integer > 0 then
				return 1
			end
			RCon_Execute()
			return 1
		end
		if libc.strneq(str, "extResponse ", 12) then
			netconn.sv_net_extresponse_count += 1
			if netconn.sv_net_extresponse_count > NET_EXTRESPONSE_MAX then
				netconn.sv_net_extresponse_count = NET_EXTRESPONSE_MAX
			end
			netconn.sv_net_extresponse_last = (netconn.sv_net_extresponse_last + 1) % NET_EXTRESPONSE_MAX
			local _, t = dpsnprintf(1400, "'" .. addressstring2 .. "' " .. libc.cstr(string.sub(str, 13)))
			netconn.sv_net_extresponse[netconn.sv_net_extresponse_last] = t
			return 1
		end
		if libc.strneq(str, "ping", 4) then
			if CVopt("developer_extra", 0) ~= 0 then
				console.Con_DPrintf("Received ping from %s, sending ack\n", addressstring2)
			end
			NetConn_WriteString(mysocket, "\255\255\255\255ack", peeraddress)
			return 1
		end
		if libc.strneq(str, "ack", 3) then
			return 1
		end
		-- we may not have liked the packet, but it was a command packet, so
		-- we're done processing this packet now
		return 1
	end
	-- netquake control packets, supported for compatibility only, and only
	-- when running game protocols that are normally served via this connection
	-- protocol
	-- (this protects more modern protocols against being used for
	--  Quake packet flood Denial Of Service attacks)
	if length >= 5 then
		i = BuffBigLong(data, 0)
	end
	if
		length >= 5
		and i ~= 0
		and band(i, bnot(NETFLAG_LENGTH_MASK)) == NETFLAG_CTL
		and band(i, NETFLAG_LENGTH_MASK) == length
		and (sv.protocol == P.QUAKE or sv.protocol == P.QUAKEDP or sv.protocol == P.NEHAHRAMOVIE or sv.protocol == P.NEHAHRABJP or sv.protocol == P.NEHAHRABJP2 or sv.protocol == P.NEHAHRABJP3 or sv.protocol == P.DARKPLACES1 or sv.protocol == P.DARKPLACES2 or sv.protocol == P.DARKPLACES3)
		and not ENCRYPTION_REQUIRED()
	then
		local c
		local protocolnumber
		local protocolname
		local m = netconn.sv_message
		length -= 4
		common.SZ_Clear(m)
		SZ_WriteBuf(m, data, 4, length)
		MSG_BeginReading(m)
		c = MSG_ReadByte(m)
		if c == CCREQ_CONNECT then
			console.Con_DPrintf("Datagram_ParseConnectionless: received CCREQ_CONNECT from %s.\n", addressstring2)
			if not (islocal or CV("sv_public").integer > -2) then
				local reason = CV("sv_public_rejectreason").string.str
				console.Con_DPrintf(
					'Datagram_ParseConnectionless: sending CCREP_REJECT "%s" to %s.\n',
					reason,
					addressstring2
				)
				ctlreply(mysocket, peeraddress, function(mm: any)
					common.MSG_WriteByte(mm, CCREP_REJECT)
					common.MSG_WriteUnterminatedString(mm, reason)
					common.MSG_WriteString(mm, "\n")
				end)
			else
				protocolname = MSG_ReadString(m, MAX_INPUTLINE)
				protocolnumber = MSG_ReadByte(m)
				if protocolname ~= "QUAKE" or protocolnumber ~= NET_PROTOCOL_VERSION then
					console.Con_DPrintf(
						'Datagram_ParseConnectionless: sending CCREP_REJECT "Incompatible version." to %s.\n',
						addressstring2
					)
					ctlreply(mysocket, peeraddress, function(mm: any)
						common.MSG_WriteByte(mm, CCREP_REJECT)
						common.MSG_WriteString(mm, "Incompatible version.\n")
					end)
				else
					-- see if this connect request comes from a known client
					clientnum = 0
					while clientnum < s.maxclients do
						local knownclient = clientslot(clientnum)
						if
							knownclient.netconnection
							and LHNETADDRESS_Compare(peeraddress, knownclient.netconnection.peeraddress) == 0
						then
							-- this is either a duplicate connection request
							-- or coming back from a timeout
							-- (if so, keep their stuff intact)

							local crypto = Crypto_ServerGetInstance(peeraddress)
							if
								(crypto and crypto.authenticated)
								or (knownclient.netconnection.crypto and knownclient.netconnection.crypto.authenticated)
							then
								if CVopt("developer_extra", 0) ~= 0 then
									console.Con_Printf(
										'Datagram_ParseConnectionless: sending CCREP_REJECT "Attempt to downgrade crypto." to %s.\n',
										addressstring2
									)
								end
								ctlreply(mysocket, peeraddress, function(mm: any)
									common.MSG_WriteByte(mm, CCREP_REJECT)
									common.MSG_WriteString(mm, "Attempt to downgrade crypto.\n")
								end)
								return 1
							end

							-- send a reply
							console.Con_DPrintf(
								"Datagram_ParseConnectionless: sending duplicate CCREP_ACCEPT to %s.\n",
								addressstring2
							)
							ctlreply(mysocket, peeraddress, function(mm: any)
								common.MSG_WriteByte(mm, CCREP_ACCEPT)
								common.MSG_WriteLong(
									mm,
									LHNETADDRESS_GetPort(LHNET_AddressFromSocket(knownclient.netconnection.mysocket))
								)
							end)

							-- if client is already spawned, re-send the
							-- serverinfo message as they'll need it to play
							if knownclient.begun then
								SV_SendServerinfo(knownclient)
							end
							return 1
						end
						clientnum += 1
					end

					-- this is a new client, check for connection flood
					if
						not NetConn_PreventFlood(
							peeraddress,
							floodlist("connectfloodaddresses", MAX_CONNECTFLOODADDRESSES),
							MAX_CONNECTFLOODADDRESSES,
							CV("net_connectfloodblockingtimeout").value,
							true
						)
					then
						-- find a slot for the new client
						local found = false
						clientnum = 0
						while clientnum < s.maxclients do
							local newclient = clientslot(clientnum)
							local conn
							if not newclient.active then
								conn = NetConn_Open(mysocket, peeraddress)
								newclient.netconnection = conn
							end
							if conn then
								-- connect to the client
								-- everything is allocated, just fill in the details
								conn.address = string.sub(addressstring2, 1, 127)
								console.Con_DPrintf(
									"Datagram_ParseConnectionless: sending CCREP_ACCEPT to %s.\n",
									addressstring2
								)
								-- send back the info about the server connection
								ctlreply(mysocket, peeraddress, function(mm: any)
									common.MSG_WriteByte(mm, CCREP_ACCEPT)
									common.MSG_WriteLong(
										mm,
										LHNETADDRESS_GetPort(LHNET_AddressFromSocket(conn.mysocket))
									)
								end)
								-- now set up the client struct
								SV_ConnectClient(clientnum, conn)
								netconn.NetConn_Heartbeat(1)
								found = true
								break
							end
							clientnum += 1
						end
						if found then
							return 1
						end

						console.Con_DPrintf(
							'Datagram_ParseConnectionless: sending CCREP_REJECT "Server is full." to %s.\n',
							addressstring2
						)
						-- no room; try to let player know
						ctlreply(mysocket, peeraddress, function(mm: any)
							common.MSG_WriteByte(mm, CCREP_REJECT)
							common.MSG_WriteString(mm, "Server is full.\n")
						end)
					end
				end
			end
		elseif c == CCREQ_SERVER_INFO then
			console.Con_DPrintf("Datagram_ParseConnectionless: received CCREQ_SERVER_INFO from %s.\n", addressstring2)
			if
				(islocal or CV("sv_public").integer > -1)
				and not NetConn_PreventFlood(
					peeraddress,
					floodlist("getstatusfloodaddresses", MAX_GETSTATUSFLOODADDRESSES),
					MAX_GETSTATUSFLOODADDRESSES,
					CV("net_getstatusfloodblockingtimeout").value,
					false
				)
			then
				if sv.active and MSG_ReadString(m, MAX_INPUTLINE) == "QUAKE" then
					local numclients
					console.Con_DPrintf(
						"Datagram_ParseConnectionless: sending CCREP_SERVER_INFO to %s.\n",
						addressstring2
					)
					ctlreply(mysocket, peeraddress, function(mm: any)
						common.MSG_WriteByte(mm, CCREP_SERVER_INFO)
						local _, myaddressstring = LHNETADDRESS_ToString(LHNET_AddressFromSocket(mysocket), 128, true)
						common.MSG_WriteString(mm, myaddressstring)
						common.MSG_WriteString(mm, CV("hostname").string.str)
						common.MSG_WriteString(mm, sv.name)
						-- How many clients are there?
						numclients = 0
						for k = 0, s.maxclients - 1 do
							if clientslot(k).active then
								numclients += 1
							end
						end
						common.MSG_WriteByte(mm, numclients)
						common.MSG_WriteByte(mm, s.maxclients)
						common.MSG_WriteByte(mm, NET_PROTOCOL_VERSION)
					end)
				end
			end
		elseif c == CCREQ_PLAYER_INFO then
			console.Con_DPrintf("Datagram_ParseConnectionless: received CCREQ_PLAYER_INFO from %s.\n", addressstring2)
			if
				(islocal or CV("sv_public").integer > -1)
				and not NetConn_PreventFlood(
					peeraddress,
					floodlist("getstatusfloodaddresses", MAX_GETSTATUSFLOODADDRESSES),
					MAX_GETSTATUSFLOODADDRESSES,
					CV("net_getstatusfloodblockingtimeout").value,
					false
				)
			then
				if sv.active then
					local playerNumber, activeNumber, clientNumber
					local client

					playerNumber = MSG_ReadByte(m)
					activeNumber = -1
					clientNumber = 0
					while clientNumber < s.maxclients do
						client = clientslot(clientNumber)
						if client.active then
							activeNumber += 1
							if activeNumber == playerNumber then
								break
							end
						end
						clientNumber += 1
					end
					if clientNumber ~= s.maxclients then
						ctlreply(mysocket, peeraddress, function(mm: any)
							common.MSG_WriteByte(mm, CCREP_PLAYER_INFO)
							common.MSG_WriteByte(mm, playerNumber)
							common.MSG_WriteString(mm, client.name.str)
							common.MSG_WriteLong(mm, client.colors)
							common.MSG_WriteLong(mm, client.frags)
							common.MSG_WriteLong(mm, libc.toint(realtime - client.connecttime))
							if CV("sv_status_privacy").integer ~= 0 then
								common.MSG_WriteString(mm, if client.netconnection then "hidden" else "botclient")
							else
								common.MSG_WriteString(
									mm,
									if client.netconnection then client.netconnection.address else "botclient"
								)
							end
						end)
					end
				end
			end
		elseif c == CCREQ_RULE_INFO then
			console.Con_DPrintf("Datagram_ParseConnectionless: received CCREQ_RULE_INFO from %s.\n", addressstring2)
			-- no flood check here, as it only returns one cvar for one cvar and clients may iterate quickly
			if (islocal or CV("sv_public").integer > -1) and sv.active then
				local prevCvarName
				local var

				-- find the search start location
				prevCvarName = MSG_ReadString(m, MAX_INPUTLINE)
				var = cvar.Cvar_FindVarAfter(prevCvarName, CVAR_NOTIFY)

				-- send the response
				ctlreply(mysocket, peeraddress, function(mm: any)
					common.MSG_WriteByte(mm, CCREP_RULE_INFO)
					if var then
						common.MSG_WriteString(mm, var.name)
						common.MSG_WriteString(mm, var.string.str)
					end
				end)
			end
		elseif c == CCREQ_RCON then
			console.Con_DPrintf("Datagram_ParseConnectionless: received CCREQ_RCON from %s.\n", addressstring2)
			if sv.active and CV("rcon_secure").integer == 0 then
				RCon_Execute()
				return 1
			end
		end
		common.SZ_Clear(m)
		-- we may not have liked the packet, but it was a valid control
		-- packet, so we're done processing this packet now
		return 1
	end
	if host_client then
		ret = NetConn_ReceivedMessage(
			host_client.netconnection,
			data,
			length,
			sv.protocol,
			if host_client.begun then CV("net_messagetimeout").value else CV("net_connecttimeout").value
		)
		if ret == 2 then
			SV_ReadClientMessage()
			return ret
		end
	end
	return 0
end
local NetConn_ServerParsePacket = netconn.NetConn_ServerParsePacket

local readbuffer = buffer.create(NET_HEADERSIZE + NET_MAXMESSAGE)
local serverframe_peeraddress = LHNETADDRESS_New()

-- port: netconn.c NetConn_ServerFrame L3604-3621 @xonotic-v0.8.6
function netconn.NetConn_ServerFrame()
	local i, length
	local peeraddress = serverframe_peeraddress
	local s = svs()
	i = 0
	while i < sv_numsockets do
		while sv_sockets[i + 1] do
			length = NetConn_Read(sv_sockets[i + 1], readbuffer, NET_HEADERSIZE + NET_MAXMESSAGE, peeraddress)
			if length <= 0 then
				break
			end
			NetConn_ServerParsePacket(sv_sockets[i + 1], readbuffer, length, peeraddress)
		end
		i += 1
	end
	i = 0
	while i < s.maxclients do
		local host_client = clientslot(i)
		server.host_client = host_client
		-- never timeout loopback connections
		if
			host_client.netconnection
			and prvm_edict.realtime > host_client.netconnection.timeout
			and LHNETADDRESS_GetAddressType(host_client.netconnection.peeraddress) ~= LHNETADDRESSTYPE_LOOP
		then
			console.Con_Printf('Client "%s" connection timed out\n', host_client.name.str)
			SV_DropClient(false)
		end
		i += 1
	end
	server.host_client = {} -- (C leaves host_client at svs.clients + svs.maxclients, one past the last client)
end

-- port: netconn.c NetConn_SleepMicroseconds L3623-3626 @xonotic-v0.8.6
function netconn.NetConn_SleepMicroseconds(microseconds: number)
	lhnet.LHNET_SleepUntilPacket_Microseconds(microseconds)
end

-- sv_masters[] (netconn.c L41-51: sv_master1..4, sv_masterextra1..3, then the NULL entry): host.cv names
local NUM_SV_MASTERS = 7
local sv_masters = table.create(NUM_SV_MASTERS)
for k = 0, NUM_SV_MASTERS - 1 do
	sv_masters[k + 1] = "sv_masters[" .. k .. "]"
end

local heartbeat_masteraddress = LHNETADDRESS_New()

-- port: netconn.c NetConn_Heartbeat L3766-3795 @xonotic-v0.8.6
function netconn.NetConn_Heartbeat(priority: number)
	local masteraddress = heartbeat_masteraddress
	local mysocket
	local realtime = prvm_edict.realtime
	local sv = server.sv :: any

	-- if it's a state change (client connected), limit next heartbeat to no
	-- more than 30 sec in the future
	if priority == 1 and nextheartbeattime > realtime + 30.0 then
		nextheartbeattime = realtime + 30.0
	end

	-- limit heartbeatperiod to 30 to 270 second range,
	-- lower limit is to avoid abusing master servers with excess traffic,
	-- upper limit is to avoid timing out on the master server (which uses
	-- 300 sec timeout)
	local sv_heartbeatperiod = CV("sv_heartbeatperiod")
	if sv_heartbeatperiod.value < 30 then
		cvar.Cvar_SetValueQuick(sv_heartbeatperiod, 30)
	end
	if sv_heartbeatperiod.value > 270 then
		cvar.Cvar_SetValueQuick(sv_heartbeatperiod, 270)
	end

	-- make advertising optional and don't advertise singleplayer games, and
	-- only send a heartbeat as often as the admin wants
	if
		sv.active
		and CV("sv_public").integer > 0
		and svs().maxclients >= 2
		and (priority > 1 or realtime > nextheartbeattime)
	then
		nextheartbeattime = realtime + sv_heartbeatperiod.value
		for masternum = 0, NUM_SV_MASTERS - 1 do
			local var = HOST().cv[sv_masters[masternum + 1]]
			local str = if var then var.string.str else ""
			if str ~= "" and LHNETADDRESS_FromString(masteraddress, str, DPMASTER_PORT) ~= 0 then
				mysocket = netconn.NetConn_ChooseServerSocketForAddress(masteraddress)
				if mysocket then
					-- (master servers do not exist on Roblox: this goes to the socket's backend, see lhnet.backend)
					NetConn_WriteString(mysocket, "\255\255\255\255heartbeat DarkPlaces\n", masteraddress)
				end
			end
		end
	end
end

-- port: netconn.c Net_Heartbeat_f L3797-3803 @xonotic-v0.8.6
local function Net_Heartbeat_f()
	if (server.sv :: any).active then
		netconn.NetConn_Heartbeat(2)
	else
		console.Con_Print("No server running, can not heartbeat to master server.\n")
	end
end

-- port: netconn.c PrintStats L3805-3820 @xonotic-v0.8.6
local function PrintStats(conn: any)
	local sv = server.sv :: any
	if sv.active and sv.protocol == P.QUAKEWORLD then -- (|| cls.state == ca_connected && cls.protocol == QW)
		console.Con_Printf(
			"address=%21s canSend=%u sendSeq=%6u recvSeq=%6u\n",
			conn.address,
			if conn.sendMessageLength == 0 then 1 else 0,
			conn.outgoing_unreliable_sequence,
			conn.qw.incoming_sequence
		)
	else
		console.Con_Printf(
			"address=%21s canSend=%u sendSeq=%6u recvSeq=%6u\n",
			conn.address,
			if conn.sendMessageLength == 0 then 1 else 0,
			conn.nq.sendSequence,
			conn.nq.receiveSequence
		)
	end
	console.Con_Printf("unreliable messages sent   = %i\n", conn.unreliableMessagesSent)
	console.Con_Printf("unreliable messages recv   = %i\n", conn.unreliableMessagesReceived)
	console.Con_Printf("reliable messages sent     = %i\n", conn.reliableMessagesSent)
	console.Con_Printf("reliable messages received = %i\n", conn.reliableMessagesReceived)
	console.Con_Printf("packetsSent                = %i\n", conn.packetsSent)
	console.Con_Printf("packetsReSent              = %i\n", conn.packetsReSent)
	console.Con_Printf("packetsReceived            = %i\n", conn.packetsReceived)
	console.Con_Printf("receivedDuplicateCount     = %i\n", conn.receivedDuplicateCount)
	console.Con_Printf("droppedDatagrams           = %i\n", conn.droppedDatagrams)
end

-- port: netconn.c Net_Stats_f L3822-3828 @xonotic-v0.8.6
function netconn.Net_Stats_f()
	local conn
	console.Con_Print("connections                =\n")
	conn = netconn.netconn_list
	while conn do
		PrintStats(conn)
		conn = conn.next
	end
end

-- the console commands of NetConn_Init (Cmd_AddCommand "net_stats" / "heartbeat"): host.Host_Init_Dedicated
-- registers the commands of its init table with host_cmd.PORTED's functions
host_cmd.PORTED.net_stats = netconn.Net_Stats_f
host_cmd.PORTED.heartbeat = Net_Heartbeat_f

-- sv_main.netconn / sv_main.lhnet: the hooks engine/sv_main.luau calls netconn.c / lhnet.c through
function netconn.install()
	local sv_main = SVMAIN()
	sv_main.netconn = {
		NetConn_CanSend = netconn.NetConn_CanSend,
		NetConn_SendUnreliableMessage = netconn.NetConn_SendUnreliableMessage,
	}
	sv_main.lhnet = {
		LHNETADDRESS_GetAddressType = lhnet.LHNETADDRESS_GetAddressType,
	}
end

-- port: netconn.c NetConn_Init L3869-3952 @xonotic-v0.8.6
-- (the cvars and the net_stats / heartbeat commands are registered by host.Host_Init_Dedicated from its init
-- table, net_tos_dscp included: LHNET_DefaultDSCP(-1) >= 0 with IP_TOS. Called by host.Host_Init_Dedicated.)
function netconn.NetConn_Init()
	local i
	local tempaddress = LHNETADDRESS_New()
	-- netconn_mempool = Mem_AllocPool("network connections", 0, NULL); (no pools)
	-- COMMANDLINEOPTION: Server: -ip <ipaddress> sets the ip address of this machine for purposes of networking
	-- (default 0.0.0.0 also known as INADDR_ANY), use only if you have multiple network adapters and need to choose
	-- one specifically.
	local argv = cmd.com_argv
	local argc = #argv
	i = cmd.Cmd_CheckParm("-ip")
	if i ~= 0 and i + 1 < argc then
		if LHNETADDRESS_FromString(tempaddress, argv[i + 2], 0) == 1 then
			console.Con_Printf('-ip option used, setting net_address to "%s"\n', argv[i + 2])
			cvar.Cvar_SetQuick(CV("net_address"), argv[i + 2])
		else
			console.Con_Printf('-ip option used, but unable to parse the address "%s"\n', argv[i + 2])
		end
	end
	-- COMMANDLINEOPTION: Server: -port <portnumber> sets the port to use for a server (default 26000, the same port
	-- as QUAKE itself), useful if you host multiple servers on your machine
	i = cmd.Cmd_CheckParm("-port")
	if i == 0 then
		i = cmd.Cmd_CheckParm("-ipport")
	end
	if i == 0 then
		i = cmd.Cmd_CheckParm("-udpport")
	end
	if i ~= 0 and i + 1 < argc then
		i = libc.atoi(argv[i + 2])
		if i >= 0 and i < 65536 then
			console.Con_Printf("-port option used, setting port cvar to %i\n", i)
			cvar.Cvar_SetValueQuick(CV("sv_netport"), i)
		else
			console.Con_Printf("-port option used, but %i is not a valid port number\n", i)
		end
	end
	cl_numsockets = 0
	sv_numsockets = 0
	table.clear(cl_sockets)
	table.clear(sv_sockets)
	netconn.cl_message.cursize = 0
	netconn.sv_message.cursize = 0
	lhnet.cl_netlocalping = CV("cl_netlocalping")
	lhnet.LHNET_Init()
	-- (Thread_HasThreads: no netconn_mutex)
	netconn.install()
end

-- port: netconn.c NetConn_Shutdown L3954-3962 @xonotic-v0.8.6
function netconn.NetConn_Shutdown()
	netconn.NetConn_CloseClientPorts()
	netconn.NetConn_CloseServerPorts()
	lhnet.LHNET_Shutdown()
end

-- test support: the socket arrays (lhnetsocket_t *sv_sockets[16] / cl_sockets[16], C element i at [i + 1])
function netconn.sockets(): ({ [number]: any }, number, { [number]: any }, number)
	return sv_sockets, sv_numsockets, cl_sockets, cl_numsockets
end

-- test support: reset the module state a fresh process has (statics zeroed)
function netconn.reset_state()
	netconn.NetConn_CloseClientPorts()
	netconn.NetConn_CloseServerPorts()
	netconn.netconn_list = nil
	netconn.challenges = newchallenges()
	nextheartbeattime = 0
	clientport, clientport2, hostport = -1, -1, -1
	crypto_servercpu_accumulator, crypto_servercpu_lastrealtime, crypto_complain_time = 0, 0, 0
	netconn.sv_net_extresponse_count = 0
	netconn.sv_net_extresponse_last = 0
	for k = 0, NET_EXTRESPONSE_MAX - 1 do
		netconn.sv_net_extresponse[k] = ""
	end
end

-- (the netconn.c constants tests and other modules use)
netconn.NET_HEADERSIZE = NET_HEADERSIZE
netconn.NET_MAXMESSAGE = NET_MAXMESSAGE
netconn.MAX_PACKETFRAGMENT = MAX_PACKETFRAGMENT
netconn.NETFLAG_CTL = NETFLAG_CTL
netconn.LHNETADDRESSTYPE_INET4 = LHNETADDRESSTYPE_INET4
netconn.LHNETADDRESSTYPE_INET6 = LHNETADDRESSTYPE_INET6
netconn.CRYPTO_HEADERSIZE = CRYPTO_HEADERSIZE
netconn.SV_ReadClientMessage = SV_ReadClientMessage

return netconn
