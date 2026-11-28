--!strict
-- A network client over engine/netconn.luau: the stormkeep bot match of sv_send_client.test.luau (4 bots, compiled
-- QuakeC, host.Host_Main_Frame), and ONE client that talks to the server only through packets on the loopback
-- socket, as a DarkPlaces client does over UDP: connectionless "getchallenge" + "connect", then the NetQuake /
-- DarkPlaces packet layer (the client's own netconn_t: it acks the reliable fragments, reassembles the serverinfo
-- and receives the unreliable datagrams; it sends a clc_nop datagram every frame during signon, the signon commands
-- prespawn / userinfo + spawn / begin as reliable clc_stringcmd messages, then in game a clc_ackframe + clc_move
-- datagram every frame). The server side is the real one: NetConn_ServerFrame reads the packets (Host_Main_Frame),
-- NetConn_ServerParsePacket answers and calls SV_ConnectClient, complete messages go to SV_ReadClientMessage
-- (engine/sv_user.luau), the server's datagrams go out through NetConn_SendUnreliableMessage. A dedicated server
-- opens no loopback port, so the test opens one (NetConn_OpenServerPort(NULL, LHNETADDRESSTYPE_LOOP, 1, 1), what a
-- listen server does). NETCLIENT_FRAMES overrides the in-game frame count (default 150).
-- Needs work/vfs-high and game/generated/progs; skips without them.
local t = require("../_lib/t")
local lfs = require("@lune/fs")
local common = require("../../engine/common")
local console = require("../../engine/console")
local fs = require("../../engine/fs")
local host = require("../../engine/host")
local host_cmd = require("../../engine/host_cmd")
local cmd = require("../../engine/cmd")
local lhnet = require("../../engine/lhnet")
local netconn = require("../../engine/netconn")
local sv_main = require("../../engine/sv_main")
local server = require("../../engine/server")
local qcrt = require("../../engine/_port/qcrt")
local f32 = require("../../engine/_port/f32")
local provider = require("../_lib/vfs_provider")

local LOOP = lhnet.LHNETADDRESSTYPE_LOOP
local PROTOCOL_DARKPLACES7 = common.PROTOCOL.DARKPLACES7
local NETFLAG_DATA, NETFLAG_UNRELIABLE = 0x00010000, 0x00100000
local svc_print, svc_serverinfo, svc_time, svc_clientdata, svc_setangle = 8, 11, 7, 15, 10
local clc_nop, clc_move, clc_stringcmd, clc_ackframe = 1, 3, 4, 50

return function(ctx: t.Ctx)
	local dat, gen = "work/vfs-high/progs.dat", "game/generated/progs/init.luau"
	local p = provider("high")
	if not (p and lfs.isFile(dat) and lfs.isFile(gen)) then
		t.skip(ctx, "needs work/vfs-high and the compiled QuakeC (game/generated/progs)")
		return
	end
	local lines: { string } = {}
	console.sink = function(l: string)
		table.insert(lines, l)
	end
	fs.SetProvider(p)
	host.Host_Init_Dedicated({ maxclients = 8 })
	server.Clear()
	host_cmd.sv_active = false
	require("../../engine/svvm_cmds").VM_CustomStats_Clear()
	local svs = host_cmd.svs :: any
	svs.clients = {}

	local generated = (require :: any)("../../game/generated/progs")
	local qcwarnings: { string } = {}
	sv_main.vm_setup_opts = {
		install = function(prog: any)
			prog.warning = function(m: string)
				if #qcwarnings < 20 then
					table.insert(qcwarnings, m)
				end
			end
			generated.install(prog, { qcrt = qcrt, f32 = f32 })
		end,
	}

	local clientconn: any = nil
	local function finish()
		sv_main.vm_setup_opts = nil
		if clientconn then
			netconn.NetConn_Close(clientconn)
		end
		netconn.cls_netcon = nil
		netconn.NetConn_CloseClientPorts()
		netconn.NetConn_CloseServerPorts()
		fs.SetProvider(nil)
		console.sink = function(l: string)
			print(l)
		end
	end

	print("  --- phase: map start ---")
	local ok, err = pcall(function()
		cmd.Cbuf_AddText(
			"sv_random_seed 12345\nbot_join_empty 1\nbot_number 4\nskill 5\nminplayers 0\ng_dm 1\ntimelimit_override 0\nfraglimit_override 0\nmap stormkeep\n"
		)
		cmd.Cbuf_Execute()
	end)
	t.ok(ctx, ok, "map stormkeep starts without an error: " .. tostring(err))
	local sv = server.sv :: any
	if not ok or not sv.active then
		finish()
		return
	end
	t.ok(
		ctx,
		sv_main.netconn ~= nil
			and sv_main.netconn.NetConn_SendUnreliableMessage == netconn.NetConn_SendUnreliableMessage,
		"sv_main uses engine/netconn.luau"
	)

	local ticrate = host.cv.sys_ticrate.value
	local frameerr: any = nil
	local function frame(): boolean
		local okf, e = pcall(host.Host_Main_Frame, ticrate)
		if not okf then
			frameerr = e
		end
		return okf
	end
	for _ = 1, 30 do
		if not frame() then
			break
		end
	end
	t.ok(ctx, frameerr == nil, "30 bot frames before the client connects: " .. tostring(frameerr))

	-- the sockets: the server's loopback port 1, the client's port 2
	t.ok(ctx, netconn.NetConn_OpenServerPort(nil, LOOP, 1, 1), "server loopback port opened")
	netconn.NetConn_OpenClientPort(nil, LOOP, 2)
	local _, _, clsockets, ncl = netconn.sockets()
	local clsock = clsockets[ncl]
	t.ok(ctx, clsock ~= nil and clsock.address.port == 2, "client loopback socket on port 2")
	local svaddr = lhnet.LHNETADDRESS_New()
	lhnet.LHNETADDRESS_FromPort(svaddr, LOOP, 1)
	local readbuf = buffer.create(netconn.NET_HEADERSIZE + netconn.NET_MAXMESSAGE)
	local peer = lhnet.LHNETADDRESS_New()

	local function sendstring(s: string)
		netconn.NetConn_Write(clsock, buffer.fromstring(s), #s, svaddr)
	end
	local c: any = nil -- the client's client_t on the server
	local function hexhead(s: string): string
		local o = {}
		for i = 1, math.min(#s, 24) do
			table.insert(o, string.format("%02x", string.byte(s, i)))
		end
		return table.concat(o, " ")
	end
	local moveseq = 0
	local stats =
		{ packets = 0, datagrams = 0, reliables = 0, acks = 0, maxpacket = 0, badtime = 0, ingame = 0, setangle = 0 }
	local reliables: { string } = {}
	local lastdatagram = ""
	-- a packet of the connection (the client side of NetConn_ClientParsePacket's routing into
	-- NetConn_ReceivedMessage)
	local function handlepacket(len: number)
		stats.packets += 1
		stats.maxpacket = math.max(stats.maxpacket, len)
		local flags =
			bit32.band(bit32.bor(buffer.readu8(readbuf, 0) * 16777216, buffer.readu8(readbuf, 1) * 65536), 0xFFFF0000)
		local r = netconn.NetConn_ReceivedMessage(clientconn, readbuf, len, PROTOCOL_DARKPLACES7, 15)
		if r == 2 then
			local m = netconn.cl_message
			local s = buffer.readstring(m.data, 0, m.cursize)
			if bit32.band(flags, NETFLAG_UNRELIABLE) ~= 0 then
				stats.datagrams += 1
				lastdatagram = s
				if c and c.begun then
					stats.ingame += 1
					-- svc_time, then svc_clientdata (after an svc_setangle of 1 + 3 angle16 when fixangle is set)
					local b6 = string.byte(s, 6)
					if b6 == svc_setangle then
						stats.setangle += 1
					end
					if
						string.byte(s, 1) ~= svc_time
						or not (b6 == svc_clientdata or (b6 == svc_setangle and string.byte(s, 13) == svc_clientdata))
					then
						stats.badtime += 1
						if stats.badtime <= 3 then
							print("  unexpected datagram start: " .. hexhead(s))
						end
					end
				end
			elseif bit32.band(flags, NETFLAG_DATA) ~= 0 then
				stats.reliables += 1
				table.insert(reliables, s)
			end
		end
	end
	-- connectionless replies to the client ("\377\377\377\377..."); after "accept" the client opens its connection
	-- (cls.netcon: complete messages go to netconn.cl_message) and the packets that follow go to it
	local function readconnectionless(): { string }
		local r = {}
		while true do
			local len = netconn.NetConn_Read(clsock, readbuf, buffer.len(readbuf), peer)
			if len <= 0 then
				break
			end
			if len >= 4 and buffer.readu32(readbuf, 0) == 0xFFFFFFFF then
				local s = buffer.readstring(readbuf, 0, len)
				table.insert(r, s)
				if s == "\255\255\255\255accept" and not clientconn then
					clientconn = netconn.NetConn_Open(clsock, svaddr)
					netconn.cls_netcon = clientconn
				end
			elseif clientconn then
				handlepacket(len)
			end
		end
		return r
	end

	print("  --- phase: getchallenge / connect ---")
	sendstring("\255\255\255\255getchallenge")
	frame()
	local replies = readconnectionless()
	local challenge = replies[1] and string.match(replies[1], "^\255\255\255\255challenge ([^%z]+)%z$")
	t.ok(ctx, challenge ~= nil and #challenge == 11, "challenge reply: " .. string.format("%q", replies[1] or ""))
	sendstring(
		"\255\255\255\255connect\\protocol\\darkplaces 3\\challenge\\" .. (challenge or "") .. "\\name\\netclient"
	)
	frame()
	replies = readconnectionless()
	t.eq(ctx, replies[1], "\255\255\255\255accept", "connect accepted")
	local slot = -1
	for i = 0, svs.maxclients - 1 do
		local c = svs.clients[i]
		if c and c.active and c.netconnection and c.netconnection.address == "local:2" then
			slot = i
		end
	end
	t.ok(ctx, slot >= 0, "SV_ConnectClient gave the client a slot with a netconnection")
	if slot < 0 then
		finish()
		return
	end
	c = svs.clients[slot]
	local svconn = c.netconnection
	print(
		string.format(
			"  client in slot %d, server-side connection %s, serverinfo %d bytes queued",
			slot,
			svconn.address,
			svconn.message.cursize
		)
	)

	local function clientframe()
		while true do
			local len = netconn.NetConn_Read(clsock, readbuf, buffer.len(readbuf), peer)
			if len <= 0 then
				break
			end
			handlepacket(len)
		end
		-- the client's datagram: clc_nop during signon; in game clc_ackframe of the last entity frame and a clc_move
		-- in the DP7 layout (CL_SendMove, cl_input.c); then its queued reliable message goes out with it
		local msg = common.SZ_New(256)
		if c and c.begun then
			moveseq += 1
			local db = c.entitydatabase5
			-- (the frame number a client parses out of svc_entities: read here from the server's entity database)
			local framenum = if db and db.latestframenum then db.latestframenum else 0
			if framenum > 0 then
				common.MSG_WriteByte(msg, clc_ackframe)
				common.MSG_WriteLong(msg, framenum)
				stats.acks += 1
			end
			common.MSG_WriteByte(msg, clc_move)
			common.MSG_WriteLong(msg, moveseq)
			common.MSG_WriteFloat(msg, f32.round(sv.time))
			common.MSG_WriteAngle16i(msg, 0)
			common.MSG_WriteAngle16i(msg, (moveseq * 2) % 360)
			common.MSG_WriteAngle16i(msg, 0)
			common.MSG_WriteCoord16i(msg, 400)
			common.MSG_WriteCoord16i(msg, 0)
			common.MSG_WriteCoord16i(msg, 0)
			common.MSG_WriteLong(msg, if moveseq <= 20 and moveseq % 2 == 1 then 1 else 0)
			common.MSG_WriteByte(msg, 0)
			common.MSG_WriteShort(msg, 0)
			common.MSG_WriteShort(msg, 0)
			for _ = 1, 6 do
				common.MSG_WriteFloat(msg, 0)
			end
			common.MSG_WriteShort(msg, 0)
		else
			common.MSG_WriteByte(msg, clc_nop)
		end
		netconn.NetConn_SendUnreliableMessage(clientconn, msg, PROTOCOL_DARKPLACES7, 1000000, 0, false)
	end
	local function stringcmd(s: string)
		common.MSG_WriteByte(clientconn.message, clc_stringcmd)
		common.MSG_WriteString(clientconn.message, s)
	end

	print("  --- phase: serverinfo over reliable fragments ---")
	local n = 0
	while #reliables == 0 and n < 100 do
		frame()
		clientframe()
		n += 1
	end
	t.ok(ctx, frameerr == nil, "frames run without an error: " .. tostring(frameerr))
	t.ok(ctx, #reliables >= 1, "the client reassembled the first reliable message")
	local serverinfo = reliables[1] or ""
	print(
		string.format(
			"  serverinfo: %d bytes after %d frames (%d fragments of 1024 bytes), %d packets received",
			#serverinfo,
			n,
			(#serverinfo + 1023) // 1024,
			stats.packets
		)
	)
	t.eq(ctx, string.byte(serverinfo, 1), svc_print, "serverinfo starts with svc_print")
	local si = string.find(serverinfo, string.char(svc_serverinfo) .. string.pack("<i4", 3504), 1, true)
	t.ok(ctx, si ~= nil, "svc_serverinfo with protocol 3504 (DP7) in the reliable message")
	t.ok(ctx, string.find(serverinfo, "csqc_progname csprogs.dat\n", 1, true) ~= nil, "csqc_progname stufftext")
	t.eq(ctx, c.sendsignon, 2, "the server is in the keepalive phase (sendsignon 2)")

	print("  --- phase: signon (reliable clc_stringcmd prespawn / userinfo + spawn / begin) ---")
	local function signon(cmds: { string }, field: string)
		for _, cm in cmds do
			stringcmd(cm)
		end
		local k = 0
		while not c[field] and k < 60 do
			frame()
			clientframe()
			k += 1
		end
		t.ok(ctx, c[field], cmds[#cmds] .. " arrived through the packets and took effect (" .. k .. " frames)")
	end
	signon({ "prespawn" }, "prespawned")
	-- CL_SignonReply (cl_parse.c) at signon 2: the userinfo, then "spawn"
	signon({
		'name "netclient"',
		"color 4 4",
		"rate 20000",
		"rate_burstsize 1024",
		"playermodel models/player/erebus.iqm",
		"playerskin 0",
		"spawn",
	}, "spawned")
	signon({ "begin" }, "begun")
	print(
		string.format(
			"  after signon: name %q, rate %d (the userinfo commands, as far as they are ported)",
			c.name.str,
			c.rate
		)
	)
	t.ok(ctx, frameerr == nil, "signon frames run without an error: " .. tostring(frameerr))

	print("  --- phase: in game ---")
	local frames = tonumber(require("@lune/process").env.NETCLIENT_FRAMES) or 150
	local before = stats.ingame
	for _ = 1, frames do
		if not frame() then
			break
		end
		clientframe()
	end
	t.ok(ctx, frameerr == nil, "in-game frames run without an error: " .. tostring(frameerr))
	local got = stats.ingame - before
	print(
		string.format(
			"  client received: %d packets (largest %d bytes), %d unreliable datagrams (%d in game), %d reliable messages (sizes %s)",
			stats.packets,
			stats.maxpacket,
			stats.datagrams,
			stats.ingame,
			stats.reliables,
			(function()
				local s = {}
				for _, m in reliables do
					table.insert(s, tostring(#m))
				end
				return table.concat(s, " ")
			end)()
		)
	)
	print(
		string.format(
			"  server connection: sendSeq %d ackSeq %d recvSeq %d, sent %d / resent %d / received %d packets; client connection: sent %d, received %d, dropped %d",
			svconn.nq.sendSequence,
			svconn.nq.ackSequence,
			svconn.nq.receiveSequence,
			svconn.packetsSent,
			svconn.packetsReSent,
			svconn.packetsReceived,
			clientconn.packetsSent,
			clientconn.packetsReceived,
			clientconn.droppedDatagrams
		)
	)
	t.ok(
		ctx,
		got >= frames * 9 // 10,
		string.format("an unreliable datagram nearly every in-game frame (%d of %d)", got, frames)
	)
	t.eq(ctx, stats.badtime, 0, "every in-game datagram starts with svc_time, then svc_clientdata")
	t.ok(
		ctx,
		stats.maxpacket <= netconn.NET_HEADERSIZE + netconn.NET_MAXMESSAGE,
		"packets within NET_HEADERSIZE + NET_MAXMESSAGE (a loopback client gets unlimited datagrams, sv_main.c)"
	)
	t.eq(ctx, clientconn.droppedDatagrams, 0, "no datagram lost on the loopback socket")
	t.ok(ctx, c.active and c.begun and c.netconnection == svconn, "the client is still connected")
	t.ok(ctx, #lastdatagram > 0, "datagrams carry data")
	-- (the clc_move of the last client frame is still on the wire: the server reads it next frame)
	t.eq(ctx, c.cmd.sequence, moveseq - 1, "the last clc_move the server read is the client's usercmd (cmd.sequence)")
	t.ok(ctx, c.latestframenum > 0, "clc_ackframe acknowledged entity frames")
	print(
		string.format(
			"  server side of the client: cmd.sequence %d, movesequence %d, %d datagrams with svc_setangle, latestframenum %d (%d acks sent), ping %.1f ms, rate %d",
			c.cmd.sequence or 0,
			c.movesequence,
			stats.setangle,
			c.latestframenum,
			stats.acks,
			c.ping * 1000,
			c.rate
		)
	)
	if #qcwarnings > 0 then
		print("  first QC warnings: " .. table.concat(qcwarnings, " | "))
	end

	-- leave no network client behind
	c.netconnection = nil
	c.active = false
	netconn.NetConn_Close(svconn)
	finish()
	local shown = 0
	for _, l in lines do
		if
			shown < 20
			and l ~= ""
			and string.sub(l, 1, 8) ~= "execing "
			and string.sub(l, 1, 26) ~= "Warning: Could not expand "
		then
			print("  console: " .. l)
			shown += 1
		end
	end
end
