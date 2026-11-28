--!strict
-- engine/netconn.luau + engine/lhnet.luau against the release's netconn.c / lhnet.c compiled unchanged
-- (tests/vectors/netconn.tsv, tools/testgen/netconn_vectors.sh). The vector file is a script: its action rows
-- (T, CV, OPENSV, CONN, Q, SEND, RECV, PKT, SVFRAME, ...: see tools/testgen/netconn_vectors.c) are replayed here
-- through the port and every result row (packets on the wire, return values, connection counters, cl_message /
-- sv_message contents, console output, the calls of SV_ConnectClient / SV_SendServerinfo / SV_ReadClientMessage /
-- SV_DropClient, stubbed exactly as in the generator) must come out byte-identical, in the same order.
-- Scenario A: two connections back to back over the loopback socket (reliable fragments, several queued messages,
-- dropped / duplicated / reordered packets, acks, rate / burst cleartime, net_test, resends after stalls).
-- Scenario B: the connectionless server packets (getchallenge, connect, getinfo, getstatus, ping, extResponse, the
-- NetQuake CCREQ_* packets), a connected client's data packets, the heartbeat and a connection timeout.
local t = require("../_lib/t")
local lfs = require("@lune/fs")
local common = require("../../engine/common")
local console = require("../../engine/console")
local cvar = require("../../engine/cvar")
local fs = require("../../engine/fs")
local f32 = require("../../engine/_port/f32")
local libc = require("../../engine/_port/libc")
local host = require("../../engine/host")
local host_cmd = require("../../engine/host_cmd")
local lhnet = require("../../engine/lhnet")
local netconn = require("../../engine/netconn")
local prvm_edict = require("../../engine/prvm_edict")
local server = require("../../engine/server")
local sv_main = require("../../engine/sv_main")

local VECTORS = "tests/vectors/netconn.tsv"
local LOOP = lhnet.LHNETADDRESSTYPE_LOOP

local function unhex(h: string): string
	if h == "-" then
		return ""
	end
	return (string.gsub(h, "%x%x", function(x: string): string
		return string.char(tonumber(x, 16) :: number)
	end))
end
local function hex(s: string): string
	if s == "" then
		return "-"
	end
	return (string.gsub(s, ".", function(c: string): string
		return string.format("%02x", string.byte(c))
	end))
end
local function bhex(b: buffer, off: number, n: number): string
	if n <= 0 then
		return "-"
	end
	return hex(buffer.readstring(b, off, n))
end
local dbuf = buffer.create(8)
local function dbits(x: number): string
	buffer.writef64(dbuf, 0, x)
	return string.format("%08x%08x", buffer.readu32(dbuf, 4), buffer.readu32(dbuf, 0))
end
local function fromdbits(h: string): number
	buffer.writeu32(dbuf, 4, tonumber(string.sub(h, 1, 8), 16) :: number)
	buffer.writeu32(dbuf, 0, tonumber(string.sub(h, 9, 16), 16) :: number)
	return buffer.readf64(dbuf, 0)
end
local function u32(x: number): string
	return string.format("%u", x % 4294967296)
end

local ACTIONS = {}
for _, k in
	{
		"T",
		"CV",
		"SRAND",
		"OPENSV",
		"OPENCL",
		"CONN",
		"CLSNETCON",
		"Q",
		"CS",
		"SEND",
		"WIRE",
		"DROP",
		"DUP",
		"MOVE",
		"RECV",
		"ST",
		"SV",
		"PROG",
		"GSTR",
		"EDSTR",
		"CLI",
		"CLIX",
		"BEGUN",
		"SVPROTO",
		"PKT",
		"SVFRAME",
		"CLREAD",
		"STC",
		"ATTACH",
		"CLEARSLOT",
		"HB",
		"NETSTATS",
		"EXT",
		"SVQ",
		"SVSEND",
		"END",
	}
do
	ACTIONS[k] = true
end

return function(ctx: t.Ctx)
	if not lfs.isFile(VECTORS) then
		t.skip(ctx, VECTORS .. " missing (tools/testgen/netconn_vectors.sh)")
		return
	end
	local lines = string.split(t.read(VECTORS), "\n")
	if lines[#lines] == "" then
		table.remove(lines)
	end

	-- the engine as the generator has it: cvars registered, no network state
	local savedsink, savedprint = console.sink, console.Con_Print
	console.sink = function(_l: string) end
	fs.SetProvider({
		files = {},
		load = function(_p: string): string?
			return nil
		end,
	})
	host.Host_Init_Dedicated({ maxclients = 2 })
	server.Clear()
	netconn.reset_state()
	lhnet.LHNET_Shutdown()
	lhnet.LHNET_Init()
	netconn.NetConn_Init()
	lhnet.time = function(): number
		return 0
	end
	local svs = host_cmd.svs :: any
	local sv = server.sv :: any
	local saved = {
		clients = svs.clients,
		maxclients = svs.maxclients,
		prog = cvar.prvm_prog_list[0],
		realtime = prvm_edict.realtime,
		host_client = server.host_client,
	}
	svs.clients = {}
	svs.maxclients = 0

	local out: { string } = {}
	local function emit(s: string)
		table.insert(out, s)
	end
	console.Con_Print = function(msg: string)
		emit("CON\t" .. hex(msg))
	end

	-- the stubs of the generator
	local function slotof(c: any): number
		for i = 0, svs.maxclients - 1 do
			if svs.clients[i] == c then
				return i
			end
		end
		return -1
	end
	netconn.hooks.SV_ConnectClient = function(clientnum: number, conn: any)
		local c = sv_main.client(clientnum)
		emit(string.format("SVCC\t%d\t%s", clientnum, conn.address))
		c.active = true
		c.netconnection = conn
		c.name.str = "unconnected"
		c.begun = false
		c.ping = 0
		c.frags = 0
		c.colors = 0
		c.connecttime = prvm_edict.realtime
	end
	netconn.hooks.SV_SendServerinfo = function(c: any)
		emit(string.format("SVSI\t%d", slotof(c)))
	end
	netconn.hooks.SV_ReadClientMessage = function()
		local m = netconn.sv_message
		emit(
			string.format(
				"SVRM\t%d\t%s\t%d\t%d",
				slotof(server.host_client),
				bhex(m.data, 0, m.cursize),
				m.readcount or 0,
				if m.badread then 1 else 0
			)
		)
	end
	netconn.hooks.SV_DropClient = function(crash: boolean)
		local c = server.host_client
		emit(string.format("SVDROP\t%d\t%d", slotof(c), if crash then 1 else 0))
		netconn.NetConn_Close(c.netconnection)
		c.netconnection = nil
		c.active = false
	end

	local conns: { [number]: any } = {}
	local svsock: any = nil
	local readbuf = buffer.create(netconn.NET_HEADERSIZE + netconn.NET_MAXMESSAGE)
	local peer = lhnet.LHNETADDRESS_New()
	local svaddr = lhnet.LHNETADDRESS_New()
	lhnet.LHNETADDRESS_FromPort(svaddr, LOOP, 1)

	local function clsock(k: number): any
		local _, _, cl = netconn.sockets()
		return cl[k + 1]
	end
	local function state(id: number, c: any): string
		local og = c.outgoing_netgraph[c.outgoing_packetcounter]
		local ig = c.incoming_netgraph[c.incoming_packetcounter]
		return table.concat({
			"S",
			tostring(id),
			u32(c.nq.sendSequence),
			u32(c.nq.ackSequence),
			u32(c.nq.receiveSequence),
			u32(c.nq.unreliableReceiveSequence),
			u32(c.outgoing_unreliable_sequence),
			tostring(c.sendMessageLength),
			tostring(c.receiveMessageLength),
			tostring(c.message.cursize),
			dbits(c.cleartime),
			dbits(c.incoming_cleartime),
			dbits(c.lastSendTime),
			dbits(c.lastMessageTime),
			dbits(c.timeout),
			tostring(c.packetsSent),
			tostring(c.packetsReSent),
			tostring(c.packetsReceived),
			tostring(c.receivedDuplicateCount),
			tostring(c.droppedDatagrams),
			tostring(c.unreliableMessagesSent),
			tostring(c.unreliableMessagesReceived),
			tostring(c.reliableMessagesSent),
			tostring(c.reliableMessagesReceived),
			tostring(c.outgoing_packetcounter),
			tostring(c.incoming_packetcounter),
			tostring(og.unreliablebytes),
			tostring(og.reliablebytes),
			tostring(og.ackbytes),
			dbits(og.cleartime),
			dbits(og.time),
			tostring(ig.unreliablebytes),
			tostring(ig.reliablebytes),
			tostring(ig.ackbytes),
			dbits(ig.cleartime),
			dbits(ig.time),
		}, "\t")
	end
	local function packets(): { any }
		local l = {}
		local head = lhnet.lhnet_packetlist
		local p = head.next
		while p ~= head do
			table.insert(l, p)
			p = p.next
		end
		return l
	end
	local function unlink(p: any)
		p.next.prev = p.prev
		p.prev.next = p.next
	end
	local function append(p: any)
		local head = lhnet.lhnet_packetlist
		p.next = head
		p.prev = head.prev
		head.prev.next = p
		head.prev = p
	end
	local function setcvar(name: string, value: string)
		local c = cvar.Cvar_FindVar(name)
		assert(c, "cvar " .. name)
		c.string = { str = value }
		c.value = f32.round(libc.atof(value))
		c.integer = libc.toint(c.value)
	end
	local function sizebuf(data: string): any
		local m = common.SZ_New(math.max(#data, 1))
		buffer.writestring(m.data, 0, data)
		m.cursize = #data
		return m
	end
	local function clread(k: number)
		local s = clsock(k)
		while true do
			local len = netconn.NetConn_Read(s, readbuf, buffer.len(readbuf), peer)
			if len <= 0 then
				break
			end
			emit(string.format("RP\t%d\t%d\t%s", len, lhnet.LHNETADDRESS_GetPort(peer), bhex(readbuf, 0, len)))
		end
	end

	local actions = 0
	local function act(f: { string })
		local k = f[1]
		if k == "T" then
			prvm_edict.realtime = fromdbits(f[2])
		elseif k == "CV" then
			setcvar(f[2], unhex(f[3] or "-"))
		elseif k == "SRAND" then
			libc.srand(tonumber(f[2]) :: number)
		elseif k == "OPENSV" then
			local r = netconn.NetConn_OpenServerPort(nil, LOOP, tonumber(f[2]) :: number, 0)
			emit("R\t" .. (if r then "1" else "0"))
			local svs_, n = netconn.sockets()
			svsock = svs_[n]
		elseif k == "OPENCL" then
			netconn.NetConn_OpenClientPort(nil, LOOP, tonumber(f[2]) :: number)
			local _, _, _, n = netconn.sockets()
			emit("R\t" .. n)
		elseif k == "CONN" then
			local side, port = tonumber(f[2]) :: number, tonumber(f[3]) :: number
			local a = lhnet.LHNETADDRESS_New()
			lhnet.LHNETADDRESS_FromPort(a, LOOP, port)
			local c = netconn.NetConn_Open(if side == 0 then svsock else clsock(side - 1), a)
			local id = #conns + 1
			conns[id - 1 + 1] = c
			emit(string.format("CA\t%d\t%s", id - 1, c.address))
		elseif k == "CLSNETCON" then
			local id = tonumber(f[2]) :: number
			netconn.cls_netcon = if id < 0 then nil else conns[id + 1]
		elseif k == "Q" then
			common.SZ_Write(conns[tonumber(f[2]) :: number + 1].message, unhex(f[3]))
		elseif k == "CS" then
			emit("R\t" .. (if netconn.NetConn_CanSend(conns[tonumber(f[2]) :: number + 1]) then "1" else "0"))
		elseif k == "SEND" then
			local r = netconn.NetConn_SendUnreliableMessage(
				conns[tonumber(f[2]) :: number + 1],
				sizebuf(unhex(f[3])),
				common.PROTOCOL.DARKPLACES7,
				tonumber(f[4]) :: number,
				tonumber(f[5]) :: number,
				f[6] ~= "0"
			)
			emit("R\t" .. r)
		elseif k == "WIRE" then
			local l = packets()
			emit("W\t" .. #l)
			for i, p in l do
				emit(
					string.format(
						"PK\t%d\t%d\t%d\t%s",
						i - 1,
						p.sourceport,
						p.destinationport,
						bhex(p.data, 0, p.length)
					)
				)
			end
		elseif k == "DROP" then
			unlink(packets()[tonumber(f[2]) :: number + 1])
		elseif k == "DUP" then
			local p = packets()[tonumber(f[2]) :: number + 1]
			local data = buffer.create(p.length)
			buffer.copy(data, 0, p.data, 0, p.length)
			local q = table.clone(p)
			q.data = data
			q.prev = p
			q.next = p.next
			p.next.prev = q
			p.next = q
		elseif k == "MOVE" then
			local p = packets()[tonumber(f[2]) :: number + 1]
			unlink(p)
			append(p)
		elseif k == "RECV" then
			local c = conns[tonumber(f[2]) :: number + 1]
			local newtimeout = fromdbits(f[3])
			while true do
				local len = netconn.NetConn_Read(c.mysocket, readbuf, buffer.len(readbuf), peer)
				if len <= 0 then
					break
				end
				emit(string.format("RP\t%d\t%d\t%s", len, lhnet.LHNETADDRESS_GetPort(peer), bhex(readbuf, 0, len)))
				local r = netconn.NetConn_ReceivedMessage(c, readbuf, len, common.PROTOCOL.DARKPLACES7, newtimeout)
				emit("RM\t" .. r)
				if r == 2 then
					local iscl = c == netconn.cls_netcon
					local m = if iscl then netconn.cl_message else netconn.sv_message
					emit(
						string.format(
							"MSG\t%d\t%s\t%d\t%d",
							if iscl then 1 else 0,
							bhex(m.data, 0, m.cursize),
							m.readcount or 0,
							if m.badread then 1 else 0
						)
					)
				end
			end
		elseif k == "ST" then
			local id = tonumber(f[2]) :: number
			emit(state(id, conns[id + 1]))
		elseif k == "SV" then
			svs.maxclients = tonumber(f[2]) :: number
			svs.clients = {}
			sv.active = true
			sv.protocol = tonumber(f[3]) :: number
			sv.worldbasename = f[4]
			sv.name = f[5]
		elseif k == "PROG" then
			local prog: any = prvm_edict.NewProg("server")
			prog.globalofs_cache = { worldstatus = 28 }
			prog.fieldofs_cache = { clientstatus = 1 }
			prog.strings = unhex(f[2])
			prog.stringssize = #prog.strings
			prog.max_edicts = tonumber(f[3]) :: number
			prog.entityfields = 4
			prog.globals = buffer.create(64 * 4)
			prog.edictsfields = buffer.create(prog.max_edicts * 4 * 4)
			cvar.prvm_prog_list[0] = prog
		elseif k == "GSTR" then
			buffer.writei32(cvar.prvm_prog_list[0].globals, 28 * 4, tonumber(f[2]) :: number)
		elseif k == "EDSTR" then
			local e = tonumber(f[2]) :: number
			buffer.writei32(cvar.prvm_prog_list[0].edictsfields, (e * 4 + 1) * 4, tonumber(f[3]) :: number)
		elseif k == "CLI" then
			local c = sv_main.client(tonumber(f[2]) :: number)
			c.active = true
			c.netconnection = nil
			c.name.str = unhex(f[3])
			c.frags = tonumber(f[4]) :: number
			c.colors = tonumber(f[5]) :: number
			c.ping = f32.frombits(tonumber(f[6], 16) :: number)
		elseif k == "CLIX" then
			local c = sv_main.client(tonumber(f[2]) :: number)
			c.frags = tonumber(f[3]) :: number
			c.colors = tonumber(f[4]) :: number
			c.ping = f32.frombits(tonumber(f[5], 16) :: number)
		elseif k == "BEGUN" then
			sv_main.client(tonumber(f[2]) :: number).begun = f[3] ~= "0"
		elseif k == "SVPROTO" then
			sv.protocol = tonumber(f[2]) :: number
		elseif k == "PKT" then
			local data = unhex(f[3])
			netconn.NetConn_Write(clsock(tonumber(f[2]) :: number), buffer.fromstring(data), #data, svaddr)
		elseif k == "SVFRAME" then
			netconn.NetConn_ServerFrame()
		elseif k == "CLREAD" then
			clread(tonumber(f[2]) :: number)
		elseif k == "STC" then
			local slot = tonumber(f[2]) :: number
			local c = sv_main.client(slot)
			if c.netconnection then
				emit(state(slot, c.netconnection))
			else
				emit(string.format("S\t%d\t-", slot))
			end
		elseif k == "ATTACH" then
			local slot = tonumber(f[2]) :: number
			local a = lhnet.LHNETADDRESS_New()
			lhnet.LHNETADDRESS_FromString(a, f[3], 26000)
			local c = sv_main.client(slot)
			c.netconnection = netconn.NetConn_Open(svsock, a)
			c.active = true
			emit(string.format("CA\t%d\t%s", slot, c.netconnection.address))
		elseif k == "CLEARSLOT" then
			local c = sv_main.client(tonumber(f[2]) :: number)
			netconn.NetConn_Close(c.netconnection)
			c.netconnection = nil
			c.active = false
		elseif k == "HB" then
			netconn.NetConn_Heartbeat(tonumber(f[2]) :: number)
		elseif k == "NETSTATS" then
			netconn.Net_Stats_f()
		elseif k == "EXT" then
			emit(
				string.format(
					"X\t%d\t%d\t%s",
					netconn.sv_net_extresponse_count,
					netconn.sv_net_extresponse_last,
					hex(netconn.sv_net_extresponse[netconn.sv_net_extresponse_last])
				)
			)
		elseif k == "SVQ" then
			common.SZ_Write(sv_main.client(tonumber(f[2]) :: number).netconnection.message, unhex(f[3]))
		elseif k == "SVSEND" then
			local c = sv_main.client(tonumber(f[2]) :: number).netconnection
			local m = common.SZ_New(64)
			common.MSG_WriteByte(m, 1)
			emit("R\t" .. netconn.NetConn_SendUnreliableMessage(c, m, sv.protocol, 1000000, 0, false))
		end
	end

	local ok, err = pcall(function()
		for _, line in lines do
			local f = string.split(line, "\t")
			if ACTIONS[f[1]] then
				emit(line)
				actions += 1
				act(f)
			end
		end
	end)

	-- restore
	console.Con_Print = savedprint
	console.sink = savedsink
	netconn.hooks.SV_ConnectClient = nil
	netconn.hooks.SV_SendServerinfo = nil
	netconn.hooks.SV_ReadClientMessage = nil
	netconn.hooks.SV_DropClient = nil
	netconn.cls_netcon = nil
	netconn.reset_state()
	lhnet.LHNET_Shutdown()
	lhnet.LHNET_Init()
	lhnet.time = function(): number
		return os.time()
	end
	svs.clients, svs.maxclients = saved.clients, saved.maxclients
	cvar.prvm_prog_list[0] = saved.prog
	prvm_edict.realtime = saved.realtime
	server.host_client = saved.host_client
	server.Clear()
	fs.SetProvider(nil)

	t.ok(ctx, ok, "replay runs without an error: " .. tostring(err))
	-- compare
	local n = math.max(#lines, #out)
	local bad = 0
	local rows = 0
	for i = 1, n do
		rows += 1
		local want, got = lines[i], out[i]
		if want ~= got then
			bad += 1
			if bad <= 8 then
				t.ok(
					ctx,
					false,
					string.format(
						"row %d differs: want %s | got %s",
						i,
						string.sub(want or "(none)", 1, 240),
						string.sub(got or "(none)", 1, 240)
					)
				)
			end
		else
			ctx.checks += 1
		end
	end
	print(
		string.format(
			"  netconn vectors: %d rows (%d actions replayed), %d identical, %d differ",
			#lines,
			actions,
			rows - bad,
			bad
		)
	)
end
