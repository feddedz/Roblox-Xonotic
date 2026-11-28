--!strict
-- The send side of sv_main.c with one network client: the stormkeep bot match of sv_botmatch.test.luau (4 bots,
-- compiled QuakeC, host.Host_Main_Frame), plus ONE fake client attached through SV_ConnectClient. netconn.c is
-- not ported, so the client's netconnection is a stub object and sv_main.netconn is a stub hook table that
-- records every datagram and "sends" the reliable message with it (as NetConn_SendUnreliableMessage does when
-- reliables are not suppressed). The client goes through serverinfo, then the signon client commands prespawn /
-- spawn / begin (host_cmd.CLIENTCOMMANDS: SV_ReadClientMessage is not ported, so the test runs them where the
-- client's clc_stringcmd would), then ~200 frames.
-- Checks: the serverinfo message (svc_print / svc_stufftext lines, svc_serverinfo with protocol 3504 = DP7,
-- maxclients, the precache lists, svc_cdtrack, svc_setview, svc_signonnum 1), one datagram per server frame within
-- 1400 bytes, svc_time + svc_clientdata at the start of every in-game datagram, the entity gathering counts, no
-- QC or engine error. NOT YET PORTED lines are printed by the engine the first time they are reached (run this
-- test alone to see all of them; the markers below say which phase reached them).
-- SEND_FRAMES overrides the frame count (default 200). Needs work/vfs-high and game/generated/progs; skips
-- without them.
local t = require("../_lib/t")
local lfs = require("@lune/fs")
local common = require("../../engine/common")
local console = require("../../engine/console")
local fs = require("../../engine/fs")
local host = require("../../engine/host")
local host_cmd = require("../../engine/host_cmd")
local cmd = require("../../engine/cmd")
local cvar = require("../../engine/cvar")
local sv_main = require("../../engine/sv_main")
local server = require("../../engine/server")
local qcrt = require("../../engine/_port/qcrt")
local f32 = require("../../engine/_port/f32")
local provider = require("../_lib/vfs_provider")

local NET_MAXMESSAGE = 65536
local svc_print, svc_stufftext, svc_serverinfo, svc_cdtrack, svc_setview, svc_signonnum = 8, 9, 11, 32, 5, 25
local svc_time, svc_clientdata, svc_nop = 7, 15, 1

-- a reader over a message string (0-based offsets)
local function reader(s: string)
	local r = { s = s, pos = 0, bad = false }
	function r.byte(): number
		local b = string.byte(r.s, r.pos + 1)
		r.pos += 1
		if b == nil then
			r.bad = true
			return -1
		end
		return b
	end
	function r.short(): number
		local lo, hi = r.byte(), r.byte()
		return lo + hi * 256
	end
	function r.long(): number
		if r.pos + 4 > #r.s then
			r.bad = true
			r.pos += 4
			return -1
		end
		local v = string.unpack("<i4", r.s, r.pos + 1)
		r.pos += 4
		return v
	end
	function r.float(): number
		if r.pos + 4 > #r.s then
			r.bad = true
			r.pos += 4
			return 0
		end
		local v = string.unpack("<f", r.s, r.pos + 1)
		r.pos += 4
		return v
	end
	function r.str(): string
		local e = string.find(r.s, "\0", r.pos + 1, true)
		if not e then
			r.bad = true
			r.pos = #r.s
			return ""
		end
		local v = string.sub(r.s, r.pos + 1, e - 1)
		r.pos = e
		return v
	end
	return r
end

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

	local function finish()
		sv_main.vm_setup_opts = nil
		sv_main.netconn = nil
		sv_main.lhnet = nil
		fs.SetProvider(nil)
		console.sink = function(l: string)
			print(l)
		end
	end

	print("  --- phase: map start (NOT YET PORTED lines below come from spawning the server) ---")
	local ok, err = pcall(function()
		cmd.Cbuf_AddText(
			"sv_random_seed 12345\nbot_join_empty 1\nbot_number 4\nskill 5\nminplayers 0\ng_dm 1\ntimelimit_override 0\nfraglimit_override 0\nmap stormkeep\n"
		)
		cmd.Cbuf_Execute()
	end)
	t.ok(ctx, ok, "map stormkeep starts without an error: " .. tostring(err))
	local sv = server.sv :: any
	local prog: any = cvar.prvm_prog_list[0]
	if not ok or not prog or not sv.active then
		finish()
		return
	end
	print(
		string.format(
			"  csqc: sv.csqc_progname %q, size %d, crc %d (SV_Prepare_CSQC)",
			sv.csqc_progname,
			sv.csqc_progsize,
			sv.csqc_progcrc
		)
	)
	t.ok(ctx, sv.csqc_progname == "csprogs.dat" and sv.csqc_progsize > 0, "SV_Prepare_CSQC loaded csprogs.dat")

	local ticrate = host.cv.sys_ticrate.value
	local frameerr: any = nil
	print("  --- phase: bot frames before the client connects ---")
	for _ = 1, 30 do
		local okf, e = pcall(host.Host_Main_Frame, ticrate)
		if not okf then
			frameerr = e
			break
		end
	end
	t.ok(ctx, frameerr == nil, "30 bot frames before the client connects: " .. tostring(frameerr))

	-- the stub netconnection and hooks
	local datagrams: { string } = {}
	local reliables: { string } = {}
	local conn: any = {
		message = common.SZ_New(NET_MAXMESSAGE),
		address = "fake:26000",
		peeraddress = { addresstype = 2 }, -- LHNETADDRESSTYPE_INET4
		cleartime = 0,
		timeout = 0,
		sendMessageLength = 0,
	}
	sv_main.netconn = {
		NetConn_CanSend = function(_c: any): boolean
			return true
		end,
		NetConn_SendUnreliableMessage = function(
			c: any,
			msg: any,
			_protocol: number,
			_rate: number,
			_burst: number,
			suppress: boolean
		): number
			table.insert(datagrams, buffer.readstring(msg.data, 0, msg.cursize))
			if not suppress and c.message.cursize > 0 then
				table.insert(reliables, buffer.readstring(c.message.data, 0, c.message.cursize))
				common.SZ_Clear(c.message)
			end
			return 0
		end,
	}
	sv_main.lhnet = {
		LHNETADDRESS_GetAddressType = function(a: any): number
			return a.addresstype
		end,
	}

	-- a free client slot (NetConn_ServerFrame would pick the first free one)
	local slot = -1
	for i = 0, svs.maxclients - 1 do
		local c = svs.clients[i]
		if not (c and c.active) then
			slot = i
			break
		end
	end
	t.ok(ctx, slot >= 0, "a free client slot")
	if slot < 0 then
		finish()
		return
	end
	print(string.format("  --- phase: SV_ConnectClient(%d, fake netconnection) ---", slot))
	local okc, errc = pcall(sv_main.SV_ConnectClient, slot, conn)
	t.ok(ctx, okc, "SV_ConnectClient with a netconnection: " .. tostring(errc))
	local c = svs.clients[slot]
	if not okc then
		finish()
		return
	end

	-- the serverinfo message (still in the reliable buffer)
	local serverinfo = buffer.readstring(conn.message.data, 0, conn.message.cursize)
	do
		local r = reader(serverinfo)
		local texts = {}
		local first = r.byte()
		t.eq(ctx, first, svc_print, "serverinfo message starts with svc_print")
		table.insert(texts, "print " .. string.format("%q", r.str()))
		local b = r.byte()
		while b == svc_stufftext do
			table.insert(texts, "stufftext " .. string.format("%q", r.str()))
			b = r.byte()
		end
		print("  serverinfo lines before svc_serverinfo: " .. table.concat(texts, ", "))
		t.eq(ctx, b, svc_serverinfo, "then svc_serverinfo")
		local proto = r.long()
		t.eq(ctx, proto, 3504, "protocol number 3504 (DP7)")
		t.eq(ctx, r.byte(), svs.maxclients, "maxclients")
		t.eq(ctx, r.byte(), 1, "GAME_DEATHMATCH")
		local worldmessage = r.str()
		local nmodels, nsounds = 0, 0
		local firstmodel = r.str()
		if firstmodel ~= "" then
			nmodels = 1
			while r.str() ~= "" do
				nmodels += 1
			end
		end
		while r.str() ~= "" do
			nsounds += 1
		end
		local wantm, wants = 0, 0
		while (sv.model_precache[wantm + 1] or "") ~= "" do
			wantm += 1
		end
		while (sv.sound_precache[wants + 1] or "") ~= "" do
			wants += 1
		end
		print(
			string.format(
				"  svc_serverinfo: protocol %d, world message %q, %d models (first %q), %d sounds",
				proto,
				worldmessage,
				nmodels,
				firstmodel,
				nsounds
			)
		)
		t.eq(ctx, firstmodel, sv.worldname, "first model is the world")
		t.eq(ctx, nmodels, wantm, "model precache list")
		t.eq(ctx, nsounds, wants, "sound precache list")
		t.eq(ctx, r.byte(), svc_cdtrack, "svc_cdtrack")
		r.byte()
		r.byte()
		t.eq(ctx, r.byte(), svc_setview, "svc_setview")
		t.eq(ctx, r.short(), slot + 1, "setview entity = client edict")
		t.eq(ctx, r.byte(), svc_signonnum, "svc_signonnum")
		t.eq(ctx, r.byte(), 1, "signon 1")
		t.eq(ctx, r.pos, #serverinfo, "serverinfo ends after the signon")
		t.ok(ctx, not r.bad, "serverinfo parses")
		t.ok(ctx, string.find(serverinfo, "csqc_progname csprogs.dat\n", 1, true) ~= nil, "csqc_progname stufftext")
	end
	t.eq(ctx, c.sendsignon, 1, "sendsignon 1 after serverinfo")

	local function frame(): boolean
		local okf, e = pcall(host.Host_Main_Frame, ticrate)
		if not okf then
			frameerr = e
		end
		return okf
	end
	local function clientcommand(name: string): (boolean, any)
		local save = server.host_client
		server.host_client = c
		local okk, e = pcall(host_cmd.CLIENTCOMMANDS[name])
		server.host_client = save
		return okk, e
	end

	print("  --- phase: signon (keepalive frame, prespawn, spawn, begin) ---")
	local d0 = #datagrams
	frame()
	t.eq(ctx, #datagrams, d0 + 1, "one datagram in the first frame after connecting")
	t.eq(ctx, datagrams[#datagrams], string.char(svc_nop), "the first datagram is a keepalive svc_nop")
	t.eq(ctx, reliables[1], serverinfo, "the serverinfo went out as the reliable message")
	t.eq(ctx, c.sendsignon, 2, "sendsignon 2 (keepalive phase)")

	local okp, ep = clientcommand("prespawn")
	t.ok(ctx, okp, "prespawn: " .. tostring(ep))
	t.eq(ctx, c.prespawned, true, "prespawned")
	t.eq(ctx, c.sendsignon, 0, "prespawn enables unlimited sends")
	frame()
	local okq, eq = clientcommand("spawn")
	t.ok(ctx, okq, "spawn (ClientConnect + PutClientInServer QC): " .. tostring(eq))
	t.eq(ctx, c.spawned, true, "spawned")
	frame()
	local okb, eb = clientcommand("begin")
	t.ok(ctx, okb, "begin: " .. tostring(eb))
	t.eq(ctx, c.begun, true, "begun")
	print(string.format(
		"  reliable messages sent during signon: %d (sizes %s)",
		#reliables,
		(function()
			local s = {}
			for _, m in reliables do
				table.insert(s, tostring(#m))
			end
			return table.concat(s, " ")
		end)()
	))

	-- in game
	print("  --- phase: in game frames ---")
	local frames = tonumber(require("@lune/process").env.SEND_FRAMES) or 200
	local framesrun, missing, oversize, badheader = 0, 0, 0, 0
	local maxlen, totallen = 0, 0
	local sumsend, sumstates, sumcsqc, sumvisible, sumtotal, sumpvs, sumtrace = 0, 0, 0, 0, 0, 0, 0
	local minsend, maxsend = math.huge, 0
	local t0 = os.clock()
	for f = 1, frames do
		local before = #datagrams
		if not frame() then
			break
		end
		framesrun = f
		if #datagrams ~= before + 1 then
			missing += 1
		end
		local d = datagrams[#datagrams] or ""
		maxlen = math.max(maxlen, #d)
		totallen += #d
		if #d > 1400 then
			oversize += 1
		end
		if string.byte(d, 1) ~= svc_time or string.byte(d, 6) ~= svc_clientdata then
			badheader += 1
		end
		local n = sv.numsendentities
		sumsend += n
		minsend = math.min(minsend, n)
		maxsend = math.max(maxsend, n)
		sumstates += sv_main.writeentities_counts.numsendstates
		sumcsqc += sv_main.writeentities_counts.numcsqcsendstates
		sumvisible += sv.writeentitiestoclient_stats_visibleentities
		sumtotal += sv.writeentitiestoclient_stats_totalentities
		sumpvs += sv.writeentitiestoclient_stats_culled_pvs
		sumtrace += sv.writeentitiestoclient_stats_culled_trace
	end
	local wall = os.clock() - t0
	t.ok(ctx, frameerr == nil, "frames run without a QC or engine error: " .. tostring(frameerr))
	t.eq(ctx, framesrun, frames, "frames run")
	local nf = math.max(framesrun, 1)
	print(
		string.format(
			"  %d in-game frames in %.2f s (%.2f ms/frame); datagrams: %d missing, max %d bytes, average %.1f bytes, %d over 1400, %d without svc_time + svc_clientdata",
			framesrun,
			wall,
			wall / nf * 1000,
			missing,
			maxlen,
			totallen / nf,
			oversize,
			badheader
		)
	)
	print(
		string.format(
			"  entity gathering per frame (average): sv.numsendentities %.1f (min %d, max %d), considered %.1f, visible %.1f, culled pvs %.1f / trace %.1f; to the encoders: %.1f entity states, %.1f csqc entities",
			sumsend / nf,
			if minsend == math.huge then 0 else minsend,
			maxsend,
			sumtotal / nf,
			sumvisible / nf,
			sumpvs / nf,
			sumtrace / nf,
			sumstates / nf,
			sumcsqc / nf
		)
	)
	print(
		string.format(
			"  last frame: numsendentities %d, total %d, visible %d, culled pvs %d, trace %d, states %d, csqc %d; num_edicts %d",
			sv.numsendentities,
			sv.writeentitiestoclient_stats_totalentities,
			sv.writeentitiestoclient_stats_visibleentities,
			sv.writeentitiestoclient_stats_culled_pvs,
			sv.writeentitiestoclient_stats_culled_trace,
			sv_main.writeentities_counts.numsendstates,
			sv_main.writeentities_counts.numcsqcsendstates,
			prog.num_edicts
		)
	)
	t.eq(ctx, missing, 0, "one datagram every in-game frame")
	t.eq(ctx, oversize, 0, "datagrams within 1400 bytes (DP5+ packet size limit)")
	t.eq(ctx, badheader, 0, "every in-game datagram starts with svc_time, then svc_clientdata")
	t.ok(ctx, sumsend > 0 and minsend > 0, "entities are gathered every frame")
	t.ok(ctx, sumvisible > 0, "some entities are visible to the client")
	t.ok(ctx, sumstates + sumcsqc > 0, "entity states / csqc entities reach the encoders")
	t.ok(ctx, c.active and c.begun, "the client is still connected")
	if #qcwarnings > 0 then
		print("  first QC warnings: " .. table.concat(qcwarnings, " | "))
	end

	-- leave no network client behind
	c.netconnection = nil
	c.active = false
	finish()
	local shown = 0
	for _, l in lines do
		if
			shown < 30
			and l ~= ""
			and string.sub(l, 1, 8) ~= "execing "
			and string.sub(l, 1, 26) ~= "Warning: Could not expand "
		then
			print("  console: " .. l)
			shown += 1
		end
	end
end
