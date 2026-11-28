--!strict
-- The read side of a network client in a real match: the stormkeep bot match of sv_botmatch.test.luau (4 bots,
-- compiled QuakeC, host.Host_Main_Frame) plus ONE fake client attached through SV_ConnectClient whose input goes
-- through sv_user.SV_ReadClientMessage as real client messages: the signon stringcmds ("prespawn", the userinfo
-- commands a DarkPlaces client sends at signon 2, "spawn", "begin") and then one clc_move per frame in the DP7
-- layout (attack to join the game, walk forward, turn, jump), plus a clc_ackframe for every entity frame sent.
-- The messages are delivered where NetConn_ServerFrame would (before the server frame, host_client set, the
-- connection timeout refreshed as NetConn_ReceivedMessage does); the outgoing side uses the stub hooks of
-- sv_send_client.test.luau (sv_main.netconn / sv_main.lhnet).
-- Checks: signon flags, the player entity moves through the QC physics (SV_PlayerPhysics), custom stats
-- (VM_SV_UpdateCustomStats) reach the client's stats, PVS culling (Mod_Q1BSP_FatPVS / FindBoxClusters) removes
-- entities, no QC or engine error. Per-frame entity counts are printed like sv_send_client.test.luau does.
-- NOT YET PORTED lines are printed by the engine the first time they are reached (run this test alone to see
-- all of them). READ_FRAMES overrides the frame count (default 300). Needs work/vfs-high and
-- game/generated/progs; skips without them.
local t = require("../_lib/t")
local lfs = require("@lune/fs")
local common = require("../../engine/common")
local console = require("../../engine/console")
local fs = require("../../engine/fs")
local host = require("../../engine/host")
local host_cmd = require("../../engine/host_cmd")
local cmd = require("../../engine/cmd")
local cvar = require("../../engine/cvar")
local prvm_edict = require("../../engine/prvm_edict")
local sv_main = require("../../engine/sv_main")
local sv_user = require("../../engine/sv_user")
local server = require("../../engine/server")
local qcrt = require("../../engine/_port/qcrt")
local f32 = require("../../engine/_port/f32")
local provider = require("../_lib/vfs_provider")

local R = f32.round
local NET_MAXMESSAGE = 65536
local clc_move, clc_stringcmd, clc_ackframe = 3, 4, 50

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
	-- (the client functions of the Cmd_AddCommand_WithClientCommand commands; idempotent)
	host_cmd.Host_InitClientCommands()
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
	local savednetconn, savedlhnet = sv_main.netconn, sv_main.lhnet
	local function finish()
		sv_main.vm_setup_opts = nil
		sv_main.netconn = savednetconn
		sv_main.lhnet = savedlhnet
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
	local prog: any = cvar.prvm_prog_list[0]
	if not ok or not prog or not sv.active then
		finish()
		return
	end
	local wm = sv.worldmodel
	t.ok(ctx, wm and wm.brush.FatPVS ~= nil, "the Q3 BSP loader installs brush.FatPVS")
	t.ok(ctx, wm and wm.brush.FindBoxClusters ~= nil, "the Q3 BSP loader installs brush.FindBoxClusters")
	t.ok(ctx, prog.filecrc ~= 0, "prog->filecrc is the CRC of progs.dat")
	print(
		string.format(
			"  progs.dat filecrc %d, %d custom stats registered",
			prog.filecrc,
			server.vm_customstats_last + 1
		)
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
	-- (the match countdown freezes players: the client connects after it, when the bots move too)
	local preframes = tonumber(require("@lune/process").env.READ_PREFRAMES) or 600
	print(string.format("  --- phase: %d bot frames before the client connects ---", preframes))
	for _ = 1, preframes do
		if not frame() then
			break
		end
	end
	t.ok(ctx, frameerr == nil, "bot frames before the client connects: " .. tostring(frameerr))

	-- the stub netconnection and send hooks
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
	if not okc then
		finish()
		return
	end
	local c = svs.clients[slot]
	local ent = c.edict

	-- deliver one client message through SV_ReadClientMessage (as NetConn_ServerFrame -> NetConn_ReceivedMessage
	-- -> SV_ReadClientMessage would, before the server frame)
	local readerr: any = nil
	local function deliver(build: (msg: any) -> ())
		local msg = sv_user.sv_message
		common.SZ_Clear(msg)
		build(msg)
		common.MSG_BeginReading(msg)
		conn.timeout = prvm_edict.realtime
			+ (if c.begun then host.cv.net_messagetimeout.value else host.cv.net_connecttimeout.value)
		local save = server.host_client
		server.host_client = c
		local okr, e = pcall(sv_user.SV_ReadClientMessage)
		server.host_client = save
		if not okr and readerr == nil then
			readerr = e
		end
	end
	local function stringcmds(list: { string })
		deliver(function(msg: any)
			for _, s in list do
				common.MSG_WriteByte(msg, clc_stringcmd)
				common.MSG_WriteString(msg, s)
			end
		end)
	end

	print("  --- phase: signon through SV_ReadClientMessage (prespawn, userinfo, spawn, begin) ---")
	frame() -- the serverinfo goes out (keepalive phase)
	t.eq(ctx, c.sendsignon, 2, "sendsignon 2 (keepalive phase)")
	stringcmds({ "prespawn" })
	t.eq(ctx, c.prespawned, true, 'clc_stringcmd "prespawn" ran Host_PreSpawn_f')
	t.eq(ctx, c.sendsignon, 0, "prespawn enables unlimited sends")
	frame()
	-- CL_SignonReply (cl_parse.c) at signon 2: the userinfo, then "spawn"
	stringcmds({
		'name "Tester"',
		"color 4 4",
		"rate 20000",
		"rate_burstsize 1024",
		"playermodel models/player/erebus.iqm",
		"playerskin 0",
		"spawn",
	})
	t.eq(ctx, c.spawned, true, 'clc_stringcmd "spawn" ran Host_Spawn_f (ClientConnect + PutClientInServer)')
	frame()
	stringcmds({ "begin" })
	t.eq(ctx, c.begun, true, 'clc_stringcmd "begin" ran Host_Begin_f')
	t.eq(ctx, c.active, true, "still connected after signon")
	print(string.format("  reliable messages sent during signon: %d", #reliables))
	t.ok(ctx, readerr == nil, "signon messages read without an error: " .. tostring(readerr))

	local function EF(e: number, f: string): number
		local o = prvm_edict.FieldOfs(prog, f)
		return if o >= 0 then buffer.readf32(prog.edictsfields, (e * prog.entityfields + o) * 4) else 0
	end
	local function EV(e: number, f: string): { number }
		local o = prvm_edict.FieldOfs(prog, f)
		local b = (e * prog.entityfields + o) * 4
		return {
			buffer.readf32(prog.edictsfields, b),
			buffer.readf32(prog.edictsfields, b + 4),
			buffer.readf32(prog.edictsfields, b + 8),
		}
	end

	-- in game: one clc_move per frame (+ clc_ackframe of the last entity frame)
	print("  --- phase: in game frames with clc_move input ---")
	local frames = tonumber(require("@lune/process").env.READ_FRAMES) or 300
	local seq = 0
	local yaw = 0
	local framesrun = 0
	local moved, origin0, maxdist = 0, EV(ent, "origin"), 0
	local lastorigin = EV(ent, "origin")
	local sumsend, sumvisible, sumtotal, sumpvs, sumtrace, maxpvs = 0, 0, 0, 0, 0, 0
	local pvsframes = 0
	local lastframenum = 0
	local acks = 0
	local playerframes = 0
	local walked = 0
	local t0 = os.clock()
	for f = 1, frames do
		seq += 1
		-- attack for the first 20 frames (join the game), then walk forward, turn, jump every 40 frames
		local buttons = 0
		local forward = 0
		if f <= 20 then
			buttons = if f % 2 == 1 then 1 else 0
		else
			forward = 400
			yaw = (yaw + 2) % 360
			if f % 40 < 5 then
				buttons = 2
			end
		end
		deliver(function(msg: any)
			if lastframenum > 0 then
				common.MSG_WriteByte(msg, clc_ackframe)
				common.MSG_WriteLong(msg, lastframenum)
			end
			common.MSG_WriteByte(msg, clc_move)
			common.MSG_WriteLong(msg, seq)
			common.MSG_WriteFloat(msg, R(sv.time))
			common.MSG_WriteAngle16i(msg, 0)
			common.MSG_WriteAngle16i(msg, yaw)
			common.MSG_WriteAngle16i(msg, 0)
			common.MSG_WriteCoord16i(msg, forward)
			common.MSG_WriteCoord16i(msg, 0)
			common.MSG_WriteCoord16i(msg, 0)
			common.MSG_WriteLong(msg, buttons)
			common.MSG_WriteByte(msg, 0)
			common.MSG_WriteShort(msg, 0)
			common.MSG_WriteShort(msg, 0)
			for _ = 1, 6 do
				common.MSG_WriteFloat(msg, 0)
			end
			common.MSG_WriteShort(msg, 0)
		end)
		if lastframenum > 0 then
			acks += 1
		end
		if readerr ~= nil or not c.active then
			break
		end
		local before = #datagrams
		if not frame() then
			break
		end
		framesrun = f
		-- the entity frame this frame's datagram carried (EntityFrame5_WriteFrame's framenum), acked next frame
		if #datagrams > before and c.entitydatabase5 and c.entitydatabase5.latestframenum then
			lastframenum = c.entitydatabase5.latestframenum
		end
		local o = EV(ent, "origin")
		if f > 40 then -- (after joining: walking, turning, jumping)
			local sx, sy = o[1] - lastorigin[1], o[2] - lastorigin[2]
			walked += math.sqrt(sx * sx + sy * sy)
		end
		if o[1] ~= lastorigin[1] or o[2] ~= lastorigin[2] or o[3] ~= lastorigin[3] then
			moved += 1
		end
		local dx, dy, dz = o[1] - origin0[1], o[2] - origin0[2], o[3] - origin0[3]
		maxdist = math.max(maxdist, math.sqrt(dx * dx + dy * dy + dz * dz))
		lastorigin = o
		if EF(ent, "health") > 0 and EF(ent, "movetype") ~= 0 then -- alive and not MOVETYPE_NONE
			playerframes += 1
		end
		sumsend += sv.numsendentities
		sumvisible += sv.writeentitiestoclient_stats_visibleentities
		sumtotal += sv.writeentitiestoclient_stats_totalentities
		sumpvs += sv.writeentitiestoclient_stats_culled_pvs
		sumtrace += sv.writeentitiestoclient_stats_culled_trace
		maxpvs = math.max(maxpvs, sv.writeentitiestoclient_stats_culled_pvs)
		if sv.writeentitiestoclient_stats_culled_pvs > 0 then
			pvsframes += 1
		end
	end
	local wall = os.clock() - t0
	t.ok(ctx, frameerr == nil, "frames run without a QC or engine error: " .. tostring(frameerr))
	t.ok(ctx, readerr == nil, "client messages read without an error: " .. tostring(readerr))
	t.eq(ctx, framesrun, frames, "frames run")
	t.ok(ctx, c.active and c.begun, "the client is still connected")
	local nf = math.max(framesrun, 1)
	local o = EV(ent, "origin")
	print(
		string.format(
			"  %d frames in %.2f s (%.2f ms/frame); client: movesequence %d, ping %.1f ms, latestframenum %d (%d acks sent), movetype %d, health %g",
			framesrun,
			wall,
			wall / nf * 1000,
			c.movesequence,
			c.ping * 1000,
			c.latestframenum,
			acks,
			EF(ent, "movetype"),
			EF(ent, "health")
		)
	)
	print(
		string.format(
			"  movement: origin moved in %d of %d frames, %d frames alive and movable, %.1f units walked (horizontal path after frame 40), max distance from the start %.1f, start (%.1f %.1f %.1f) -> end (%.1f %.1f %.1f), v_angle yaw %.2f",
			moved,
			framesrun,
			playerframes,
			walked,
			maxdist,
			origin0[1],
			origin0[2],
			origin0[3],
			o[1],
			o[2],
			o[3],
			EV(ent, "v_angle")[2]
		)
	)
	print(
		string.format(
			"  entity gathering per frame (average): sv.numsendentities %.1f, considered %.1f, visible %.1f, culled pvs %.1f (max %d, in %d frames) / trace %.1f",
			sumsend / nf,
			sumtotal / nf,
			sumvisible / nf,
			sumpvs / nf,
			maxpvs,
			pvsframes,
			sumtrace / nf
		)
	)
	-- (Xonotic's MOVETYPE_QCPLAYER player gets no engine prediction: SV_ExecuteClientMoves takes the else branch,
	-- copies the newest move and leaves its execution to the server frame)
	t.eq(ctx, c.cmd.sequence, seq, "the last clc_move is the client's usercmd")
	t.ok(ctx, moved > 10, "the player entity moves through the QC physics")
	t.ok(ctx, walked > 256, "the player walks (forwardmove 400 for 260 frames)")
	do
		local q = common.SZ_New(2)
		common.MSG_WriteAngle16i(q, yaw)
		t.eq(ctx, EV(ent, "v_angle")[2], common.MSG_ReadAngle16i(q), "v_angle follows the clc_move angles")
	end
	t.ok(ctx, sumpvs > 0, "PVS culling removes some entities")
	t.ok(ctx, c.latestframenum > 0, "clc_ackframe acknowledged entity frames")

	-- custom stats: every registered stat of the client's stats
	local nonzero, registered = 0, 0
	local shown: { string } = {}
	for i = 0, server.vm_customstats_last do
		local cs = server.vm_customstats[i]
		if cs and cs.type ~= 0 then
			registered += 1
			local v = c.stats and c.stats[i + 32] or 0
			if v ~= 0 then
				nonzero += 1
				if #shown < 12 then
					table.insert(shown, string.format("%d(type %d)=%d", i + 32, cs.type, v))
				end
			end
		end
	end
	print(
		string.format("  custom stats: %d registered, %d non-zero: %s", registered, nonzero, table.concat(shown, " "))
	)
	t.ok(ctx, registered > 0, "the QuakeC registers custom stats (addstat)")
	t.ok(ctx, nonzero > 0, "custom stats are non-zero in the client's stats")
	if #qcwarnings > 0 then
		print("  first QC warnings: " .. table.concat(qcwarnings, " | "))
	end

	-- leave no network client behind
	c.netconnection = nil
	c.active = false
	finish()
	local n = 0
	for _, l in lines do
		if
			n < 40
			and l ~= ""
			and string.sub(l, 1, 8) ~= "execing "
			and string.sub(l, 1, 26) ~= "Warning: Could not expand "
		then
			print("  console: " .. l)
			n += 1
		end
	end
end
