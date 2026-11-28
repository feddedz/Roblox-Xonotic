--!strict
-- SV_ReadClientMessage (engine/sv_user.luau, sv_user.c L800-974) on hand-built client messages and a small fake
-- server (synthetic prog: field / global offsets put straight into the FieldOfs / GlobalOfs caches; one network
-- client in slot 0). sv_phys.SV_Physics_ClientMove is replaced by a recorder (that runs SV_ApplyClientMove as
-- SV_ClientThink would) so the move execution order and frametimes can be checked.
-- Covered: clc_nop, clc_stringcmd (signon commands through the command table, trailing newline, the newline
-- exploit filter, case-insensitive prefixes, QC SV_ParseClientCommand with its tempstring restore, src_client
-- "player tried to"), clc_move in the DP7 layout (usercmd values, edict fields, move order with the 50 ms split,
-- old moves skipped, packet-loss tracking, the no-prediction path with impulse / button accumulation),
-- clc_ackframe (EntityFrame5_LostFrame / AckFrame), clc_disconnect, an unknown byte and a bad read (dropped).
-- Expectations derived from sv_user.c / common.c (no C reference vectors yet).
local t = require("../_lib/t")
local common = require("../../engine/common")
local console = require("../../engine/console")
local cvar = require("../../engine/cvar")
local fs = require("../../engine/fs")
local f32 = require("../../engine/_port/f32")
local host = require("../../engine/host")
local host_cmd = require("../../engine/host_cmd")
local protocol = require("../../engine/protocol")
local prvm_edict = require("../../engine/prvm_edict")
local server = require("../../engine/server")
local sv_main = require("../../engine/sv_main")
local sv_phys = require("../../engine/sv_phys")
local sv_user = require("../../engine/sv_user")

local R = f32.round
local P = common.PROTOCOL
local clc_nop, clc_disconnect, clc_move, clc_stringcmd, clc_ackframe = 1, 2, 3, 4, 50

return function(ctx: t.Ctx)
	local lines: { string } = {}
	local oldsink = console.sink
	console.sink = function(l: string)
		table.insert(lines, l)
	end
	local function said(pat: string): boolean
		for _, l in lines do
			if string.find(l, pat, 1, true) then
				return true
			end
		end
		return false
	end
	fs.SetProvider({
		files = {},
		load = function(_p: string): string?
			return nil
		end,
	})
	host.Host_Init_Dedicated({ maxclients = 2 })
	host_cmd.Host_InitClientCommands()
	server.Clear()
	local svs = host_cmd.svs :: any
	local oldclients, oldmax = svs.clients, svs.maxclients
	svs.clients = {}
	svs.maxclients = 2
	local oldrealtime = prvm_edict.realtime
	prvm_edict.realtime = 10

	local FIELDS = {
		{ "origin", 3 },
		{ "angles", 3 },
		{ "velocity", 3 },
		{ "view_ofs", 3 },
		{ "v_angle", 3 },
		{ "movement", 3 },
		{ "cursor_screen", 3 },
		{ "cursor_trace_start", 3 },
		{ "cursor_trace_endpos", 3 },
		{ "cursor_trace_ent", 1 },
		{ "flags", 1 },
		{ "movetype", 1 },
		{ "disableclientprediction", 1 },
		{ "idealpitch", 1 },
		{ "impulse", 1 },
		{ "ping", 1 },
		{ "ping_packetloss", 1 },
		{ "ping_movementloss", 1 },
		{ "button0", 1 },
		{ "button2", 1 },
		{ "button3", 1 },
		{ "buttonuse", 1 },
		{ "buttonchat", 1 },
		{ "cursor_active", 1 },
	}
	local GLOBALS = { { "self", 1 }, { "time", 1 }, { "frametime", 1 } }
	local prog: any = prvm_edict.NewProg("server")
	prog.fieldofs_cache, prog.globalofs_cache = {}, {}
	local n = 0
	for _, f in FIELDS do
		prog.fieldofs_cache[f[1]] = n
		n += f[2]
	end
	prog.entityfields = n
	n = 28
	for _, g in GLOBALS do
		prog.globalofs_cache[g[1]] = n
		n += g[2]
	end
	prog.numglobals = n
	prog.globals = buffer.create(n * 4)
	prog.max_edicts = 32
	prog.reserved_edicts = 0
	prog.limit_edicts = 512
	prog.strings = "\0"
	prog.stringssize = 1
	prvm_edict.PRVM_MEM_Alloc(prog)
	prog.num_edicts = 16
	prog.funcoffsets = { SV_ParseClientCommand = 0 }
	cvar.prvm_prog_list[0] = prog

	local function getF(e: number, f: string): number
		return buffer.readf32(prog.edictsfields, (e * prog.entityfields + prvm_edict.FieldOfs(prog, f)) * 4)
	end
	local function getI(e: number, f: string): number
		return buffer.readi32(prog.edictsfields, (e * prog.entityfields + prvm_edict.FieldOfs(prog, f)) * 4)
	end
	local function getV(e: number, f: string, i: number): number
		return buffer.readf32(prog.edictsfields, (e * prog.entityfields + prvm_edict.FieldOfs(prog, f) + i) * 4)
	end
	local function setF(e: number, f: string, v: number)
		buffer.writef32(prog.edictsfields, (e * prog.entityfields + prvm_edict.FieldOfs(prog, f)) * 4, v)
	end
	local function GF(g: string): number
		return buffer.readf32(prog.globals, prog.globalofs_cache[g] * 4)
	end
	local function setGF(g: string, v: number)
		buffer.writef32(prog.globals, prog.globalofs_cache[g] * 4, v)
	end

	local sv = server.sv :: any
	sv.protocol = P.DARKPLACES7
	sv.time = 5.0
	sv.frametime = 0.0125
	setGF("frametime", R(0.0125))
	cvar.Cvar_SetValue("sv_clmovement_enable", 1)
	cvar.Cvar_SetValue("sv_clmovement_minping", 0)
	cvar.Cvar_SetValue("sv_clmovement_inputtimeout", 0.2)

	local c: any
	local function newclient()
		c = sv_main.client(0)
		sv_main.ClearClient(c)
		c.active = true
		c.edict = 1
		c.name.str = "tester"
		c.netconnection = { message = common.SZ_New(65536), address = "test", cleartime = 0, timeout = 0 }
		c.netconnection.message.allowoverflow = true
		c.sendsignon = 2
		server.host_client = c
		buffer.fill(prog.edictsfields, prog.entityfields * 4, 0, prog.entityfields * 4)
		setF(1, "movetype", 3) -- MOVETYPE_WALK
	end
	newclient()

	-- the message: built with the MSG_ writers into sv_user.sv_message, then read
	-- (engine/netconn.luau may point sv_user.sv_message at its own sizebuf: fetched for every message)
	local msg = sv_user.sv_message
	local function begin()
		msg = sv_user.sv_message
		common.SZ_Clear(msg)
	end
	local function run()
		common.MSG_BeginReading(msg)
		server.host_client = c
		sv_user.SV_ReadClientMessage()
	end
	local function stringcmd(s: string)
		common.MSG_WriteByte(msg, clc_stringcmd)
		common.MSG_WriteString(msg, s)
	end

	-- the recorder of SV_Physics_ClientMove calls
	local calls: { { frametime: number, gframetime: number, sequence: number, ping: number } } = {}
	local physmod: any = sv_phys
	local savedphys = physmod.SV_Physics_ClientMove
	physmod.SV_Physics_ClientMove = function()
		local hc = server.host_client
		table.insert(calls, {
			frametime = sv.frametime,
			gframetime = GF("frametime"),
			sequence = hc.cmd.sequence,
			ping = hc.ping,
		})
		sv_user.SV_ApplyClientMove()
	end

	------------------------------------------------------------------------------------------------------------
	-- clc_nop, clc_stringcmd
	------------------------------------------------------------------------------------------------------------
	begin()
	common.MSG_WriteByte(msg, clc_nop)
	run()
	t.eq(ctx, c.active, true, "clc_nop: still connected")
	t.eq(ctx, c.sendsignon, 2, "clc_nop does not touch sendsignon")

	begin()
	stringcmd("prespawn")
	run()
	t.eq(ctx, c.prespawned, true, "prespawn stringcmd reaches Host_PreSpawn_f through the command table")
	t.eq(ctx, c.sendsignon, 0, "sendsignon 2 -> 0")
	local reliable = buffer.readstring(c.netconnection.message.data, 0, c.netconnection.message.cursize)
	t.eq(ctx, reliable, string.char(25, 2), "Host_PreSpawn_f wrote svc_signonnum 2 after the (empty) signon")

	table.clear(lines)
	begin()
	stringcmd("PreSpawn\n")
	run()
	t.ok(ctx, said("prespawn not valid -- already prespawned"), "trailing newline is cut, prefix is case-insensitive")

	table.clear(lines)
	begin()
	stringcmd("prespawn\nquit")
	run()
	t.ok(ctx, said("Received invalid stringcmd from tester"), "text after a newline: invalid stringcmd")
	t.ok(ctx, c.active, "an invalid stringcmd does not drop the client")

	table.clear(lines)
	begin()
	stringcmd("Begin")
	run()
	t.ok(ctx, said("Begin not valid -- not yet spawned"), "Begin (any case) runs Host_Begin_f")

	table.clear(lines)
	begin()
	stringcmd("spawnfoo 1")
	run()
	t.ok(
		ctx,
		said('player "tester" tried to spawnfoo 1'),
		"a 'spawn' prefix goes to Cmd_ExecuteString(src_client): unknown -> player tried to"
	)

	table.clear(lines)
	begin()
	stringcmd("quit")
	run()
	t.ok(ctx, said('player "tester" tried to quit'), "a console-only command from a client: player tried to")

	-- QC SV_ParseClientCommand
	local qcgot: { string } = {}
	local qcself, qctime = -1, -1
	prog.funcoffsets.SV_ParseClientCommand = 7
	prog.ExecuteProgram = function(p: any, fnum: number, _m: string)
		t.eq(ctx, fnum, 7, "SV_ParseClientCommand function number")
		table.insert(qcgot, prvm_edict.PRVM_GetString(p, buffer.readi32(p.globals, 4 * 4)))
		qcself = buffer.readi32(p.globals, p.globalofs_cache.self * 4)
		qctime = buffer.readf32(p.globals, p.globalofs_cache.time * 4)
		prvm_edict.PRVM_SetTempString(p, "garbage the QC made")
	end
	local tempsize = prog.tempstringsbuf.cursize
	begin()
	stringcmd("say hello\r\n")
	stringcmd("cmd ready")
	stringcmd("prespawn")
	run()
	t.eq(ctx, #qcgot, 2, "two commands went to QC, prespawn did not")
	t.eq(ctx, qcgot[1], "say hello", "QC gets the command without the line end")
	t.eq(ctx, qcgot[2], "cmd ready", "second command")
	t.eq(ctx, qcself, 1, "self = the client edict")
	t.eq(ctx, qctime, R(5.0), "time = sv.time")
	t.eq(ctx, prog.tempstringsbuf.cursize, tempsize, "tempstringsbuf.cursize restored")
	prog.funcoffsets.SV_ParseClientCommand = 0
	prog.ExecuteProgram = nil

	------------------------------------------------------------------------------------------------------------
	-- clc_move (DP7: sequence, time, 3 x angle16, 3 x coord16, long buttons, byte impulse, 30 bytes cursor)
	------------------------------------------------------------------------------------------------------------
	local function move(m: any)
		common.MSG_WriteByte(msg, clc_move)
		common.MSG_WriteLong(msg, m.sequence)
		common.MSG_WriteFloat(msg, m.time)
		for i = 1, 3 do
			common.MSG_WriteAngle16i(msg, (m.angles or { 0, 0, 0 })[i])
		end
		local mv = m.move or { 0, 0, 0 }
		common.MSG_WriteCoord16i(msg, mv[1])
		common.MSG_WriteCoord16i(msg, mv[2])
		common.MSG_WriteCoord16i(msg, mv[3])
		common.MSG_WriteLong(msg, m.buttons or 0)
		common.MSG_WriteByte(msg, m.impulse or 0)
		local cs = m.cursor_screen or { 0, 0 }
		common.MSG_WriteShort(msg, cs[1])
		common.MSG_WriteShort(msg, cs[2])
		local st, im = m.cursor_start or { 0, 0, 0 }, m.cursor_impact or { 0, 0, 0 }
		for i = 1, 3 do
			common.MSG_WriteFloat(msg, st[i])
		end
		for i = 1, 3 do
			common.MSG_WriteFloat(msg, im[i])
		end
		common.MSG_WriteShort(msg, m.cursor_ent or 0)
	end
	c.spawned = true
	c.begun = true
	prog.ed_free[3] = false
	prog.ed_free[4] = true

	-- one move of 0.1 s: split into two 0.05 s moves
	table.clear(calls)
	local t1 = R(4.9)
	begin()
	move({
		sequence = 10,
		time = t1,
		angles = { 10, 90, -45 },
		move = { 400, -200.4, 0 },
		buttons = 1 + 2 + 256 + 4096,
		impulse = 7,
		cursor_screen = { 16383, -32767 },
		cursor_start = { 1, 2, 3 },
		cursor_impact = { 4.5, 5, 6 },
		cursor_ent = 3,
	})
	run()
	local step = 360 / 65536
	t.eq(ctx, sv_user.sv_numreadmoves, 1, "one move read")
	local cm = c.cmd
	t.eq(ctx, cm.sequence, 10, "usercmd sequence")
	t.eq(ctx, cm.clienttime, t1, "usercmd clienttime = the float")
	t.eq(ctx, cm.receivetime, R(5.0), "usercmd receivetime = (float)sv.time")
	t.eq(ctx, cm.viewangles[1], R(1820 * step), "viewangles[0]: angle16 of 10")
	t.eq(ctx, cm.viewangles[2], 90, "viewangles[1]")
	t.eq(ctx, cm.viewangles[3], -45, "viewangles[2]")
	t.eq(ctx, cm.forwardmove, 400, "forwardmove")
	t.eq(ctx, cm.sidemove, -200, "sidemove (coord16i rounds)")
	t.eq(ctx, cm.buttons, 1 + 2 + 256 + 4096, "buttons (long)")
	t.eq(ctx, cm.cursor_screen[1], R(16383 * R(1 / 32767)), "cursor_screen[0] = short * (1.0f/32767.0f)")
	t.eq(ctx, cm.cursor_screen[2], R(-32767 * R(1 / 32767)), "cursor_screen[1]")
	t.eq(ctx, cm.cursor_screen[3], 0, "cursor_screen[2] stays 0")
	t.eq(ctx, cm.cursor_impact[1], 4.5, "cursor_impact[0]")
	t.eq(ctx, cm.cursor_entitynumber, 3, "cursor_entitynumber")
	t.eq(ctx, #calls, 2, "a 0.1 s move runs as two SV_Physics_ClientMove calls")
	t.eq(ctx, calls[1] and calls[1].frametime, R(R(0.1) * 0.5), "first half: frametime = moveframetime * 0.5f")
	t.eq(ctx, calls[1] and calls[1].gframetime, R(R(0.1) * 0.5), "QC frametime global set for the move")
	t.eq(ctx, calls[2] and calls[2].frametime, R(R(0.1) * 0.5), "second half")
	t.eq(ctx, calls[1] and calls[1].ping, R(R(5.0) - t1), "ping = receivetime - time while the move runs")
	t.eq(ctx, sv.frametime, 0.0125, "sv.frametime restored")
	t.eq(ctx, GF("frametime"), R(0.0125), "QC frametime restored")
	t.eq(ctx, c.movesequence, 10, "movesequence")
	t.eq(ctx, c.clmovement_inputtimeout, R(0.2), "clmovement_inputtimeout = sv_clmovement_inputtimeout")
	t.eq(ctx, c.ping, R(R(5.0) - t1), "ping = receivetime - clienttime after the moves")
	-- the edict fields (SV_ApplyClientMove)
	t.eq(ctx, getF(1, "button0"), 1, "button0")
	t.eq(ctx, getF(1, "button2"), 1, "button2")
	t.eq(ctx, getF(1, "buttonuse"), 1, "buttonuse (bit 8)")
	t.eq(ctx, getF(1, "button3"), 0, "button3")
	t.eq(ctx, getF(1, "impulse"), 7, "impulse")
	t.eq(ctx, getV(1, "v_angle", 1), 90, "v_angle")
	t.eq(ctx, getV(1, "movement", 0), 400, "movement x")
	t.eq(ctx, getV(1, "movement", 1), -200, "movement y")
	t.eq(ctx, getV(1, "cursor_trace_endpos", 0), 4.5, "cursor_trace_endpos")
	t.eq(ctx, getI(1, "cursor_trace_ent"), 3, "cursor_trace_ent")
	t.eq(ctx, getF(1, "ping"), R(R(R(5.0) - t1) * 1000), "ping field in ms")
	t.eq(ctx, c.cmd.impulse, 0, "impulse sent to QC once")
	t.eq(ctx, c.movement_highestsequence_seen, 10, "highest sequence seen")
	t.eq(ctx, c.movement_count[10], 1, "movement_count[10] = 1")

	-- three moves in one packet: the old one (10) is skipped, 11 and 12 run in order
	table.clear(calls)
	local t2, t3 = R(4.93), R(4.96)
	begin()
	move({ sequence = 10, time = t1, cursor_ent = 4 })
	move({ sequence = 11, time = t2, move = { 100, 0, 0 } })
	move({ sequence = 12, time = t3, move = { 200, 0, 0 } })
	run()
	t.eq(ctx, sv_user.sv_numreadmoves, 3, "three moves read")
	t.eq(ctx, sv_user.sv_readmoves[1].cursor_entitynumber, 0, "a free cursor entity reads as world")
	t.eq(ctx, #calls, 2, "two new moves executed")
	t.eq(ctx, calls[1] and calls[1].sequence, 11, "move 11 first")
	t.eq(ctx, calls[2] and calls[2].sequence, 12, "then move 12")
	t.eq(ctx, calls[1] and calls[1].frametime, R(t2 - t1), "moveframetime = time - previous cmd.time")
	t.eq(ctx, c.movement_count[10], 2, "repeated move 10 counted twice")
	t.eq(ctx, getV(1, "movement", 0), 200, "the last move's movement is applied")

	-- a gap in the sequence: 13..19 lost; a move without time progress (21) is lost too
	table.clear(calls)
	begin()
	move({ sequence = 20, time = R(4.99) })
	move({ sequence = 21, time = R(4.99) })
	run()
	t.eq(ctx, c.movement_count[13], -1, "move 13 lost")
	t.eq(ctx, c.movement_count[19], -1, "move 19 lost")
	t.eq(ctx, c.movement_count[20], 1, "move 20 seen")
	t.eq(ctx, c.movement_count[21], -1, "move 21 without time progress counted as lost")
	t.eq(ctx, #calls, 1, "only move 20 ran")
	t.eq(ctx, c.movesequence, 20, "movesequence stays 20")

	-- sequence 0 (prediction off): the moves are not run here, impulse / buttons accumulate until applied
	table.clear(calls)
	begin()
	move({ sequence = 0, time = R(5.0), impulse = 9, buttons = 1 })
	run()
	t.eq(ctx, #calls, 0, "sequence 0: no physics run from the message")
	t.eq(ctx, c.movesequence, 0, "movesequence 0")
	t.eq(ctx, c.clmovement_inputtimeout, 0, "inputtimeout 0: normal physics takes over")
	t.eq(ctx, c.movement_highestsequence_seen, 0, "highest sequence reset")
	t.eq(ctx, c.movement_count[20], nil, "movement_count cleared")
	t.eq(ctx, c.cmd.time, 5.0, "cmd.time = max(cmd.time, sv.time)")
	begin()
	move({ sequence = 0, time = R(5.0), impulse = 0, buttons = 4 })
	run()
	t.eq(ctx, c.cmd.impulse, 9, "impulse of the unapplied move kept")
	t.eq(ctx, c.cmd.buttons, 5, "buttons of the unapplied move OR'd in")
	sv_user.SV_ApplyClientMove()
	begin()
	move({ sequence = 0, time = R(5.0), impulse = 0, buttons = 0 })
	run()
	t.eq(ctx, c.cmd.impulse, 0, "after SV_ApplyClientMove nothing accumulates")
	t.eq(ctx, c.cmd.buttons, 0, "buttons not accumulated after apply")

	-- moves of a client that has not begun are read but not executed
	c.begun = false
	c.movesequence = 0
	table.clear(calls)
	begin()
	move({ sequence = 30, time = R(5.0) })
	run()
	t.eq(ctx, #calls, 0, "not begun: no move executed")
	t.eq(ctx, c.cmd.sequence, 0, "not begun: cmd unchanged")
	c.begun = true

	------------------------------------------------------------------------------------------------------------
	-- clc_ackframe
	------------------------------------------------------------------------------------------------------------
	do
		local d = protocol.EntityFrame5_AllocDatabase(nil)
		d.latestframenum = 5
		d.packetlog[1].packetnumber = 3
		d.packetlog[2].packetnumber = 4
		d.packetlog[3].packetnumber = 5
		d.packetlog[4].packetnumber = 7
		c.entitydatabase5 = d
		c.latestframenum = 2
		begin()
		common.MSG_WriteByte(msg, clc_ackframe)
		common.MSG_WriteLong(msg, 5)
		run()
		t.eq(ctx, d.packetlog[1].packetnumber, 0, "frame 3 lost (EntityFrame5_LostFrame)")
		t.eq(ctx, d.packetlog[2].packetnumber, 0, "frame 4 lost")
		t.eq(ctx, d.packetlog[3].packetnumber, 0, "frame 5 acked (EntityFrame5_AckFrame)")
		t.eq(ctx, d.packetlog[4].packetnumber, 7, "frame 7 kept")
		t.eq(ctx, c.latestframenum, 5, "latestframenum = 5")
		begin()
		common.MSG_WriteByte(msg, clc_ackframe)
		common.MSG_WriteLong(msg, 4)
		run()
		t.eq(ctx, c.latestframenum, 5, "an older ack is ignored")
		c.begun = false
		begin()
		common.MSG_WriteByte(msg, clc_ackframe)
		common.MSG_WriteLong(msg, 9)
		run()
		t.eq(ctx, c.latestframenum, 5, "acks before begin are ignored")
		c.begun = true
		c.entitydatabase5 = nil
	end

	------------------------------------------------------------------------------------------------------------
	-- disconnect, unknown byte, bad read (the client is dropped without its fake netconnection: the
	-- svc_disconnect / NetConn_Close part of SV_DropClient belongs to engine/netconn.luau)
	------------------------------------------------------------------------------------------------------------
	local function nonet()
		c.netconnection = nil
	end
	nonet()
	table.clear(lines)
	begin()
	common.MSG_WriteByte(msg, clc_disconnect)
	stringcmd("prespawn")
	run()
	t.eq(ctx, c.active, false, "clc_disconnect drops the client")
	t.ok(ctx, said('Client "tester" dropped'), "SV_DropClient ran")
	t.eq(ctx, c.prespawned, false, "nothing after clc_disconnect is read")

	newclient()
	nonet()
	table.clear(lines)
	begin()
	common.MSG_WriteByte(msg, clc_nop)
	common.MSG_WriteByte(msg, 99)
	run()
	t.ok(ctx, said("SV_ReadClientMessage: unknown command char 99 (at offset 0x2)"), "unknown byte reported")
	t.eq(ctx, c.active, false, "unknown byte drops the client")

	newclient()
	nonet()
	table.clear(lines)
	begin()
	common.MSG_WriteByte(msg, clc_ackframe)
	common.MSG_WriteShort(msg, 5) -- a long needs 4 bytes
	run()
	t.ok(ctx, said("SV_ReadClientMessage: badread at sv_user.c:956"), "badread after the short ackframe")
	t.ok(ctx, said("SV_ReadClientMessage: badread"), "then the loop's badread check")
	t.eq(ctx, c.active, false, "a bad read drops the client")

	newclient()
	nonet()
	begin()
	common.MSG_WriteByte(msg, clc_move)
	common.MSG_WriteLong(msg, 1)
	run()
	t.eq(ctx, c.active, false, "a truncated clc_move is a bad read: dropped")
	-- restore
	physmod.SV_Physics_ClientMove = savedphys
	sv_main.ClearClient(sv_main.client(0))
	svs.clients, svs.maxclients = oldclients, oldmax
	server.Clear()
	server.host_client = nil
	prvm_edict.realtime = oldrealtime
	common.SZ_Clear(msg)
	common.MSG_BeginReading(msg)
	fs.SetProvider(nil)
	console.sink = oldsink
end
