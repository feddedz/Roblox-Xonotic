--!strict
--[[
Copyright (C) 1996-1997 Id Software, Inc. (DarkPlaces sv_user.c; GPLv2 or later, see engine/prvm_exec.luau)
]]
--[[
	Port of sv_user.c @xonotic-v0.8.6 (server code for moving users): SV_SetIdealPitch, SV_ClientThink,
	SV_ReadClientMove, SV_ExecuteClientMoves, SV_ApplyClientMove, SV_FrameLost, SV_FrameAck and
	SV_ReadClientMessage.
	host_client is server.host_client (a client_t table, see engine/sv_main.luau); its cmd is the usercmd_t
	(a table whose missing fields are the zeroed C memory). A bot's cmd stays zeroed (receivetime 0), so
	SV_ApplyClientMove returns at once for it, as in C.
	The incoming message is netconn.c's global `sizebuf_t sv_message`: here sv_user.sv_message (a sizebuf of
	NET_MAXMESSAGE bytes, read with the common.c MSG_Read* functions). The network code (engine/netconn.luau) fills
	it (or replaces the field with its own sizebuf: SV_ReadClientMessage reads sv_user.sv_message at each call),
	sets server.host_client, then calls SV_ReadClientMessage, as NetConn_ServerFrame does.
	sv_numreadmoves / sv_readmoves (sv_user.c L447-448) are sv_user.sv_numreadmoves / sv_user.sv_readmoves (C
	element i at [i + 1]).
	NOT YET PORTED (logged once where reached): the engine movement of SV_ClientThink when the QuakeC has no
	SV_PlayerPhysics or sv_playerphysicsqc is 0 (DropPunchAngle, V_CalcRoll, SV_WaterJump, SV_WaterMove,
	SV_AirMove with SV_UserFriction / SV_Accelerate / SV_AirAccelerate; Xonotic always has SV_PlayerPhysics),
	SV_WriteDemoMessage (sv_demo.c, sv_autodemo_perclient >= 2), Com_HexDumpToConsole (developer dumps), the
	download part of clc_ackdownloaddata (downloads are not ported).
]]
local common = require("./common")
local console = require("./console")
local cvar = require("./cvar")
local libc = require("./_port/libc")
local libm = require("./_port/libm")
local prvm_cmds = require("./prvm_cmds")
local prvm_edict = require("./prvm_edict")
local server = require("./server")
local cmd = require("./cmd")
local R = require("./_port/f32").round

local sv_user = {}

local warned: { [string]: boolean } = {}
local function notPorted(what: string)
	if not warned[what] then
		warned[what] = true
		print("NOT YET PORTED: " .. what)
	end
end

local sv_phys_mod: any = nil

-- modules that require this one's users (sv_phys -> sv_user, host -> sv_main), required on first use and kept
-- (a require() call resolves the path every time in Lune)
local function SVPHYS(): any
	if not sv_phys_mod then
		sv_phys_mod = require("./sv_phys")
	end
	return sv_phys_mod
end
local host_mod: any = nil
local function HOST(): any
	if not host_mod then
		host_mod = require("./host")
	end
	return host_mod
end
local protocol_mod: any = nil
local function PROTOCOL(): any
	if not protocol_mod then
		protocol_mod = require("./protocol")
	end
	return protocol_mod
end

-- a cvar_t of the C file by its C variable name (host.cv, registered by host.Host_Init_Dedicated)
local function CV(var: string): any
	local c = HOST().cv[var]
	if not c then
		error("sv_user: cvar " .. var .. " is not registered (run host.Host_Init_Dedicated first)", 0)
	end
	return c
end
-- developer_networkentities (cl_parse.c, registered by CL_Parse_Init; a dedicated server has the static 0)
local function developer_networkentities_integer(): number
	local c = cvar.Cvar_FindVar("developer_networkentities")
	return if c then c.integer else 0
end

local NETGRAPH_PACKETS = 256 -- netconn.h L217
local NETGRAPH_LOSTPACKET = -1 -- netconn.h L218
local OFS_NULL = 0
local OFS_PARM0 = 4 -- pr_comp.h
local NET_MAXMESSAGE = 65536 -- quakedef.h L137
local MAX_INPUTLINE = 16384 -- quakedef.h L128 (sizeof(sv_readstring), netconn.c L75)
local CL_MAX_USERCMDS = 128 -- quakedef.h L149
local MOVE_NOMONSTERS = 1 -- world.h
local SUPERCONTENTS_SOLID = 1 -- bspfile.h
local FL_ONGROUND = 512 -- server.h
local MOVETYPE_WALK = 3 -- server.h
local ON_EPSILON = 0.1 -- quakedef.h L214
local M_PI = 3.14159265358979323846 -- mathlib.h
-- protocol.h L261-269
local clc_nop, clc_disconnect, clc_move, clc_stringcmd = 1, 2, 3, 4
local clc_ackframe, clc_ackdownloaddata = 50, 51

-- netconn.c L71-75: sizebuf_t sv_message (data = sv_message_buf[NET_MAXMESSAGE], NetConn_Init L3946-3947)
sv_user.sv_message = common.SZ_New(NET_MAXMESSAGE)

local function EF(prog: any, ed: number, f: string): number -- PRVM_serveredictfloat(ed, f) (0 if missing)
	local o = prvm_edict.FieldOfs(prog, f)
	if o < 0 then
		return 0
	end
	return buffer.readf32(prog.edictsfields, (ed * prog.entityfields + o) * 4)
end
local function EV(prog: any, ed: number, f: string, i: number): number -- PRVM_serveredictvector(ed, f)[i]
	local o = prvm_edict.FieldOfs(prog, f)
	if o < 0 then
		return 0
	end
	return buffer.readf32(prog.edictsfields, (ed * prog.entityfields + o + i) * 4)
end
local function SET_EF(prog: any, ed: number, f: string, v: number) -- PRVM_serveredictfloat(ed, f) = v
	local o = prvm_edict.FieldOfs(prog, f)
	if o >= 0 then
		buffer.writef32(prog.edictsfields, (ed * prog.entityfields + o) * 4, v)
	end
end
local function SET_EI(prog: any, ed: number, f: string, v: number) -- PRVM_serveredictedict(ed, f) = v
	local o = prvm_edict.FieldOfs(prog, f)
	if o >= 0 then
		buffer.writei32(prog.edictsfields, (ed * prog.entityfields + o) * 4, v)
	end
end
local function SET_EV(prog: any, ed: number, f: string, x: number, y: number, z: number)
	local o = prvm_edict.FieldOfs(prog, f)
	if o >= 0 then
		local a = (ed * prog.entityfields + o) * 4
		buffer.writef32(prog.edictsfields, a, x)
		buffer.writef32(prog.edictsfields, a + 4, y)
		buffer.writef32(prog.edictsfields, a + 8, z)
	end
end
local function GF(prog: any, g: string): number -- PRVM_serverglobalfloat (0 if the global is missing)
	local o = prvm_cmds.GlobalOfs(prog, g)
	if o < 0 then
		return 0
	end
	return buffer.readf32(prog.globals, o * 4)
end
local function SET_GF(prog: any, g: string, v: number)
	local o = prvm_cmds.GlobalOfs(prog, g)
	if o >= 0 then
		buffer.writef32(prog.globals, o * 4, v)
	end
end
local function SET_GI(prog: any, g: string, v: number)
	local o = prvm_cmds.GlobalOfs(prog, g)
	if o >= 0 then
		buffer.writei32(prog.globals, o * 4, v)
	end
end
-- PRVM_serverfunction(name): the cache engine/sv_phys.luau and engine/sv_main.luau use (prog.funcoffsets)
local function serverfunction(prog: any, name: string): number
	local fo = prog.funcoffsets
	if not fo then
		fo = {}
		prog.funcoffsets = fo
	end
	local f = fo[name]
	if f == nil then
		local _, fnum = prvm_edict.PRVM_ED_FindFunction(prog, name)
		f = fnum or 0
		fo[name] = f
	end
	return f
end
-- an unsigned / signed 32-bit int stored in an int
local function toint32(u: number): number
	u = u % 4294967296
	return if u >= 0x80000000 then u - 0x100000000 else u
end
-- (signed char) of an int
local function schar(v: number): number
	v = v % 256
	return if v >= 128 then v - 256 else v
end

-- a zeroed usercmd_t (client.h L654-686)
local function newusercmd(): any
	return {
		viewangles = { 0, 0, 0 },
		forwardmove = 0,
		sidemove = 0,
		upmove = 0,
		cursor_screen = { 0, 0, 0 },
		cursor_start = { 0, 0, 0 },
		cursor_end = { 0, 0, 0 },
		cursor_impact = { 0, 0, 0 },
		cursor_normal = { 0, 0, 0 },
		cursor_fraction = 0,
		cursor_entitynumber = 0,
		time = 0,
		receivetime = 0,
		clienttime = 0,
		msec = 0,
		buttons = 0,
		impulse = 0,
		sequence = 0,
		applied = false,
		predicted = false,
		frametime = 0,
		canjump = false,
		jump = false,
		crouch = false,
	}
end
sv_user.newusercmd = newusercmd
-- *dst = *src for usercmd_t tables (the vectors are copied; fields missing in src are zero in C)
local function copyusercmd(dst: any, src: any)
	table.clear(dst)
	for k, v in src do
		if type(v) == "table" then
			dst[k] = table.clone(v)
		else
			dst[k] = v
		end
	end
end
-- host_client->cmd (created zeroed on first use)
local function clientcmd(c: any): any
	local m = c.cmd
	if not m then
		m = {}
		c.cmd = m
	end
	return m
end

--[[
===============
SV_SetIdealPitch
===============
]]
-- port: sv_user.c SV_SetIdealPitch L35-99 @xonotic-v0.8.6
function sv_user.SV_SetIdealPitch()
	local prog: any = cvar.prvm_prog_list[0] -- SVVM_prog
	local host_client = server.host_client
	local ed = host_client.edict
	local angleval, sinval, cosval, step, dir
	local tr
	local top, bottom = { 0, 0, 0 }, { 0, 0, 0 }
	local z = table.create(6, 0) -- float z[MAX_FORWARD]
	local MAX_FORWARD = 6
	local i, steps
	local SV_TraceLine = SVPHYS().SV_TraceLine

	if bit32.band(libc.toint(EF(prog, ed, "flags")), FL_ONGROUND) == 0 then
		return
	end

	angleval = R(EV(prog, ed, "angles", 1) * M_PI * 2 / 360) -- [YAW] (double arithmetic, stored as float)
	sinval = R(libm.sin(angleval))
	cosval = R(libm.cos(angleval))

	i = 0
	while i < MAX_FORWARD do
		top[1] = R(EV(prog, ed, "origin", 0) + R(R(cosval * (i + 3)) * 12))
		top[2] = R(EV(prog, ed, "origin", 1) + R(R(sinval * (i + 3)) * 12))
		top[3] = R(EV(prog, ed, "origin", 2) + EV(prog, ed, "view_ofs", 2))

		bottom[1] = top[1]
		bottom[2] = top[2]
		bottom[3] = R(top[3] - 160)

		tr = SV_TraceLine(
			top,
			bottom,
			MOVE_NOMONSTERS,
			ed,
			SUPERCONTENTS_SOLID,
			0,
			0,
			CV("collision_extendmovelength").value
		)
		-- if looking at a wall, leave ideal the way is was
		if tr.startsolid then
			return
		end

		-- near a dropoff
		if tr.fraction == 1 then
			return
		end

		-- (trace_t.fraction is double)
		z[i + 1] = R(top[3] + tr.fraction * R(bottom[3] - top[3]))
		i += 1
	end

	dir = 0
	steps = 0
	for j = 1, i - 1 do
		step = R(z[j + 1] - z[j])
		if step > -ON_EPSILON and step < ON_EPSILON then
			continue
		end

		-- mixed changes
		if dir ~= 0 and (R(step - dir) > ON_EPSILON or R(step - dir) < -ON_EPSILON) then
			return
		end

		steps += 1
		dir = step
	end

	if dir == 0 then
		SET_EF(prog, ed, "idealpitch", 0)
		return
	end

	if steps < 2 then
		return
	end
	SET_EF(prog, ed, "idealpitch", R(-dir * CV("sv_idealpitchscale").value))
end

--[[
===================
SV_ClientThink

the move fields specify an intended velocity in pix/sec
the angle fields specify an exact angular motion in degrees
===================
]]
-- port: sv_user.c SV_ClientThink L367-440 @xonotic-v0.8.6
function sv_user.SV_ClientThink()
	local prog: any = cvar.prvm_prog_list[0] -- SVVM_prog
	local sv = server.sv
	local host_client = server.host_client
	local SV_CheckVelocity = SVPHYS().SV_CheckVelocity

	--Con_Printf("clientthink for %ims\n", (int) (sv.frametime * 1000));

	sv_user.SV_ApplyClientMove()
	-- make sure the velocity is sane (not a NaN)
	SV_CheckVelocity(host_client.edict)

	-- LordHavoc: QuakeC replacement for SV_ClientThink (player movement)
	local qc = cvar.Cvar_FindVar("sv_playerphysicsqc")
	if serverfunction(prog, "SV_PlayerPhysics") ~= 0 and qc and qc.integer ~= 0 then
		buffer.writef32(prog.globals, prvm_cmds.GlobalOfs(prog, "time") * 4, sv.time)
		buffer.writei32(prog.globals, prvm_cmds.GlobalOfs(prog, "self") * 4, host_client.edict)
		prvm_edict.ExecuteProgram(
			prog,
			serverfunction(prog, "SV_PlayerPhysics"),
			"QC function SV_PlayerPhysics is missing"
		)
		SV_CheckVelocity(host_client.edict)
		return
	end

	notPorted(
		"SV_ClientThink engine movement without QC SV_PlayerPhysics (sv_user.c L388-439: DropPunchAngle, V_CalcRoll, SV_WaterJump, SV_WaterMove, SV_AirMove)"
	)
end

--[[
===================
SV_ReadClientMove
===================
]]
sv_user.sv_numreadmoves = 0
sv_user.sv_readmoves = table.create(CL_MAX_USERCMDS) :: { any } -- usercmd_t sv_readmoves[CL_MAX_USERCMDS]

local function badreadat(line: number)
	console.Con_Printf("SV_ReadClientMessage: badread at %s:%i\n", "sv_user.c", line)
end

-- the protocols in the `sv.protocol != ...` lists of SV_ReadClientMove
local function quakeproto(p: number): boolean -- QUAKE, QUAKEDP, NEHAHRAMOVIE, NEHAHRABJP, NEHAHRABJP2, NEHAHRABJP3
	local P = common.PROTOCOL
	return p == P.QUAKE
		or p == P.QUAKEDP
		or p == P.NEHAHRAMOVIE
		or p == P.NEHAHRABJP
		or p == P.NEHAHRABJP2
		or p == P.NEHAHRABJP3
end
local function upto(p: number, last: number): boolean -- quakeproto or DARKPLACES1 .. last
	local P = common.PROTOCOL
	if quakeproto(p) or p == P.DARKPLACES1 then
		return true
	end
	-- (DARKPLACES1 = 7 down to DARKPLACES7 = 1 in protocolversion_t)
	return p >= last and p <= P.DARKPLACES2
end

-- port: sv_user.c SV_ReadClientMove L449-578 @xonotic-v0.8.6 (DARKPLACES1 and the default angle branch are the same in C)
-- selene: allow(if_same_then_else)
local function SV_ReadClientMove()
	local prog: any = cvar.prvm_prog_list[0] -- SVVM_prog
	local sv = server.sv
	local host_client = server.host_client
	local sv_message = sv_user.sv_message
	local P = common.PROTOCOL
	local protocol = sv.protocol
	local move = newusercmd() -- usercmd_t newmove; memset(move, 0, sizeof(*move));

	if sv_message.badread then
		badreadat(458)
	end

	-- read ping time
	if not upto(protocol, P.DARKPLACES6) then
		move.sequence = common.MSG_ReadLong(sv_message) % 4294967296 -- (unsigned int)
	end
	move.clienttime = common.MSG_ReadFloat(sv_message)
	move.time = move.clienttime
	if sv_message.badread then
		badreadat(464)
	end
	move.receivetime = R(sv.time) -- (float)sv.time

	-- limit reported time to current time
	-- (incase the client is trying to cheat)
	local limit = move.receivetime + sv.frametime
	move.time = if move.time < limit then move.time else limit

	-- read current angles
	for i = 1, 3 do
		if quakeproto(protocol) then
			move.viewangles[i] = common.MSG_ReadAngle8i(sv_message)
		elseif protocol == P.DARKPLACES1 then
			move.viewangles[i] = common.MSG_ReadAngle16i(sv_message)
		elseif protocol == P.DARKPLACES2 or protocol == P.DARKPLACES3 then
			move.viewangles[i] = common.MSG_ReadAngle32f(sv_message)
		else
			move.viewangles[i] = common.MSG_ReadAngle16i(sv_message)
		end
	end
	if sv_message.badread then
		badreadat(486)
	end

	-- read movement
	move.forwardmove = common.MSG_ReadCoord16i(sv_message)
	move.sidemove = common.MSG_ReadCoord16i(sv_message)
	move.upmove = common.MSG_ReadCoord16i(sv_message)
	if sv_message.badread then
		badreadat(492)
	end

	-- read buttons
	-- be sure to bitwise OR them into the move->buttons because we want to
	-- accumulate button presses from multiple packets per actual move
	if upto(protocol, P.DARKPLACES5) then
		move.buttons = common.MSG_ReadByte(sv_message)
	else
		move.buttons = common.MSG_ReadLong(sv_message)
	end
	if sv_message.badread then
		badreadat(501)
	end

	-- read impulse
	move.impulse = common.MSG_ReadByte(sv_message)
	if sv_message.badread then
		badreadat(505)
	end

	-- PRYDON_CLIENTCURSOR
	if not upto(protocol, P.DARKPLACES5) then
		-- 30 bytes
		local f = R(1.0 / 32767.0) -- 1.0f / 32767.0f
		move.cursor_screen[1] = R(common.MSG_ReadShort(sv_message) * f)
		move.cursor_screen[2] = R(common.MSG_ReadShort(sv_message) * f)
		move.cursor_start[1] = common.MSG_ReadFloat(sv_message)
		move.cursor_start[2] = common.MSG_ReadFloat(sv_message)
		move.cursor_start[3] = common.MSG_ReadFloat(sv_message)
		move.cursor_impact[1] = common.MSG_ReadFloat(sv_message)
		move.cursor_impact[2] = common.MSG_ReadFloat(sv_message)
		move.cursor_impact[3] = common.MSG_ReadFloat(sv_message)
		move.cursor_entitynumber = bit32.band(common.MSG_ReadShort(sv_message), 0xFFFF) -- (unsigned short)
		if move.cursor_entitynumber >= prog.max_edicts then
			console.Con_DPrintf("SV_ReadClientMessage: client send bad cursor_entitynumber\n")
			move.cursor_entitynumber = 0
		end
		-- as requested by FrikaC, cursor_trace_ent is reset to world if the
		-- entity is free at time of receipt
		if prog.ed_free and prog.ed_free[move.cursor_entitynumber] then
			move.cursor_entitynumber = 0
		end
		if sv_message.badread then
			badreadat(529)
		end
	end

	-- if the previous move has not been applied yet, we need to accumulate
	-- the impulse/buttons from it
	local hcmd = clientcmd(host_client)
	if not hcmd.applied then
		if move.impulse == 0 then
			move.impulse = hcmd.impulse or 0
		end
		move.buttons = toint32(bit32.bor(move.buttons, hcmd.buttons or 0))
	end

	-- now store this move for later execution
	-- (we have to buffer the moves because of old ones being repeated)
	if sv_user.sv_numreadmoves < CL_MAX_USERCMDS then
		sv_user.sv_numreadmoves += 1
		sv_user.sv_readmoves[sv_user.sv_numreadmoves] = move -- (a new table: *move copied into the slot)
	end

	-- movement packet loss tracking
	local mc = host_client.movement_count
	if not mc then
		mc = {}
		host_client.movement_count = mc
	end
	if move.sequence ~= 0 then
		local highest = host_client.movement_highestsequence_seen or 0
		if move.sequence > highest then
			if highest ~= 0 then
				-- mark moves in between as lost
				local delta = (move.sequence - highest - 1) % 4294967296 -- unsigned int
				if delta < NETGRAPH_PACKETS then
					for u = 0, delta - 1 do
						mc[((highest + 1 + u) % 4294967296) % NETGRAPH_PACKETS] = -1
					end
				else
					for k = 0, NETGRAPH_PACKETS - 1 do -- memset(movement_count, -1, ...)
						mc[k] = -1
					end
				end
			end
			-- mark THIS move as seen for the first time
			mc[move.sequence % NETGRAPH_PACKETS] = 1
			-- update highest sequence seen
			host_client.movement_highestsequence_seen = move.sequence
		else
			local k = move.sequence % NETGRAPH_PACKETS
			if (mc[k] or 0) >= 0 then
				mc[k] = schar((mc[k] or 0) + 1) -- ++ of a signed char
			end
		end
	else
		host_client.movement_highestsequence_seen = 0
		table.clear(mc) -- memset(movement_count, 0, ...) (nil = 0)
	end
end
sv_user.SV_ReadClientMove = SV_ReadClientMove

-- port: sv_user.c SV_ExecuteClientMoves L580-706 @xonotic-v0.8.6
local function SV_ExecuteClientMoves()
	local prog: any = cvar.prvm_prog_list[0] -- SVVM_prog
	local sv = server.sv
	local host_client = server.host_client
	local realtime = prvm_edict.realtime
	local readmoves = sv_user.sv_readmoves
	local numreadmoves = sv_user.sv_numreadmoves
	local moveframetime
	local oldframetime
	local oldframetime2
	if numreadmoves < 1 then
		return
	end
	-- only start accepting input once the player is spawned
	if not host_client.begun then
		return
	end
	local ed = host_client.edict
	local last = readmoves[numreadmoves]
	-- disable clientside movement prediction in some cases
	local lag = last.receivetime - last.time
	if math.ceil((if lag > 0 then lag else 0) * 1000.0) < CV("sv_clmovement_minping").integer then
		host_client.clmovement_disabletimeout = realtime + CV("sv_clmovement_minping_disabletime").value / 1000.0
	end
	-- several conditions govern whether clientside movement prediction is allowed
	local inputtimeout = CV("sv_clmovement_inputtimeout")
	if
		last.sequence ~= 0
		and CV("sv_clmovement_enable").integer ~= 0
		and inputtimeout.value > 0
		and (host_client.clmovement_disabletimeout or 0) <= realtime
		and (
			EF(prog, ed, "disableclientprediction") == -1
			or (EF(prog, ed, "movetype") == MOVETYPE_WALK and EF(prog, ed, "disableclientprediction") == 0)
		)
	then
		-- process the moves in order and ignore old ones
		-- but always trust the latest move
		-- (this deals with bogus initial move sequences after level change,
		--  where the client will eventually catch up with the level change
		--  and reset its move sequence)
		for moveindex = 0, numreadmoves - 1 do
			local move = readmoves[moveindex + 1]
			local hcmd = clientcmd(host_client)
			if (host_client.movesequence or 0) < move.sequence or moveindex == numreadmoves - 1 then
				-- this is a new move
				-- prevent slowhack/speedhack combos: bound(sv.time - 1, move->time, sv.time)
				local lo, hi = sv.time - 1, sv.time
				local mt = move.time
				move.time = if mt >= lo then (if mt < hi then mt else hi) else lo
				-- prevent backstepping of time: max(move->time, host_client->cmd.time)
				local ct = hcmd.time or 0
				move.time = if move.time > ct then move.time else ct
				-- bound(0, move->time - host_client->cmd.time, min(0.1, sv_clmovement_inputtimeout.value))
				local mx = if 0.1 < inputtimeout.value then 0.1 else inputtimeout.value
				local num = move.time - ct
				moveframetime = R(if num >= 0 then (if num < mx then num else mx) else 0)

				-- discard (treat like lost) moves with too low distance from
				-- the previous one to prevent hacks using float inaccuracy
				-- clients will see this as packet loss in the netgraph
				-- this should also apply if a move cannot get
				-- executed because it came too late and
				-- already was performed serverside
				if moveframetime < 0.0005 then
					-- count the move as LOST if we don't
					-- execute it but it has higher
					-- sequence count
					if (host_client.movesequence or 0) ~= 0 then
						if move.sequence > host_client.movesequence then
							local mc = host_client.movement_count
							if not mc then
								mc = {}
								host_client.movement_count = mc
							end
							mc[move.sequence % NETGRAPH_PACKETS] = -1
						end
					end
					continue
				end

				--Con_Printf("movesequence = %i (%i lost), moveframetime = %f\n", ...);
				copyusercmd(hcmd, move)
				host_client.movesequence = move.sequence

				-- if using prediction, we need to perform moves when packets are
				-- received, even if multiple occur in one frame
				-- (they can't go beyond the current time so there is no cheat issue
				--  with this approach, and if they don't send input for a while they
				--  start moving anyway, so the longest 'lagaport' possible is
				--  determined by the sv_clmovement_inputtimeout cvar)
				if moveframetime <= 0 then
					continue
				end
				oldframetime = GF(prog, "frametime")
				oldframetime2 = sv.frametime
				-- update ping time for qc to see while executing this move
				host_client.ping = R(hcmd.receivetime - hcmd.time)
				-- the server and qc frametime values must be changed temporarily
				sv.frametime = moveframetime
				SET_GF(prog, "frametime", sv.frametime)
				-- if move is more than 50ms, split it into two moves (this matches QWSV behavior and the client prediction)
				if sv.frametime > 0.05 then
					sv.frametime = R(moveframetime * 0.5)
					SET_GF(prog, "frametime", sv.frametime)
					SVPHYS().SV_Physics_ClientMove()
				end
				SVPHYS().SV_Physics_ClientMove()
				sv.frametime = oldframetime2
				SET_GF(prog, "frametime", oldframetime)
				host_client.clmovement_inputtimeout = inputtimeout.value
			end
		end
	else
		-- try to gather button bits from old moves, but only if their time is
		-- advancing (ones with the same timestamp can't be trusted)
		local hcmd = clientcmd(host_client)
		for moveindex = 0, numreadmoves - 2 do
			local move = readmoves[moveindex + 1]
			if (hcmd.time or 0) < move.time then
				last.buttons = toint32(bit32.bor(last.buttons, move.buttons))
				if move.impulse ~= 0 then
					last.impulse = move.impulse
				end
			end
		end
		-- now copy the new move
		copyusercmd(hcmd, last)
		hcmd.time = if hcmd.time > sv.time then hcmd.time else sv.time
		-- physics will run up to sv.time, so allow no predicted moves
		-- before that otherwise, there is a speedhack by turning
		-- prediction on and off repeatedly on client side because the
		-- engine would run BOTH client and server physics for the same
		-- time
		host_client.movesequence = 0
		-- make sure that normal physics takes over immediately
		host_client.clmovement_inputtimeout = 0
	end

	-- calculate average ping time
	local hcmd = clientcmd(host_client)
	host_client.ping = R((hcmd.receivetime or 0) - (hcmd.clienttime or 0))
	-- (#ifdef NUM_PING_TIMES: not defined, server.h L183)
end
sv_user.SV_ExecuteClientMoves = SV_ExecuteClientMoves

-- port: sv_user.c SV_ApplyClientMove L708-769 @xonotic-v0.8.6
function sv_user.SV_ApplyClientMove()
	local prog: any = cvar.prvm_prog_list[0] -- SVVM_prog
	local host_client = server.host_client
	local move = clientcmd(host_client) -- (a client_t table without cmd: the zeroed usercmd_t)
	local movementloss, packetloss
	local ed = host_client.edict

	if (move.receivetime or 0) == 0 then
		return
	end

	-- note: a move can be applied multiple times if the client packets are
	-- not coming as often as the physics is executed, and the move must be
	-- applied before running qc each time because the id1 qc had a bug where
	-- it clears self.button2 in PlayerJump, causing pogostick behavior if
	-- moves are not applied every time before calling qc
	move.applied = true

	local buttons = move.buttons or 0
	local function bit(n: number): number -- (move->buttons >> n) & 1
		return bit32.band(bit32.rshift(buttons, n), 1)
	end

	-- set the edict fields
	SET_EF(prog, ed, "button0", bit32.band(buttons, 1))
	SET_EF(prog, ed, "button2", bit32.rshift(bit32.band(buttons, 2), 1))
	if (move.impulse or 0) ~= 0 then
		SET_EF(prog, ed, "impulse", move.impulse)
	end
	-- only send the impulse to qc once
	move.impulse = 0

	movementloss = 0
	packetloss = 0
	if host_client.netconnection then
		local netgraph = host_client.netconnection.incoming_netgraph or {}
		for j = 0, NETGRAPH_PACKETS - 1 do
			local g = netgraph[j]
			if g and g.unreliablebytes == NETGRAPH_LOSTPACKET then
				packetloss += 1
			end
		end
		local mc = host_client.movement_count or {}
		for j = 0, NETGRAPH_PACKETS - 1 do
			if (mc[j] or 0) < 0 then
				movementloss += 1
			end
		end
	end

	local va = move.viewangles or { 0, 0, 0 }
	SET_EV(prog, ed, "v_angle", va[1], va[2], va[3])
	SET_EF(prog, ed, "button3", bit(2))
	SET_EF(prog, ed, "button4", bit(3))
	SET_EF(prog, ed, "button5", bit(4))
	SET_EF(prog, ed, "button6", bit(5))
	SET_EF(prog, ed, "button7", bit(6))
	SET_EF(prog, ed, "button8", bit(7))
	SET_EF(prog, ed, "button9", bit(11))
	SET_EF(prog, ed, "button10", bit(12))
	SET_EF(prog, ed, "button11", bit(13))
	SET_EF(prog, ed, "button12", bit(14))
	SET_EF(prog, ed, "button13", bit(15))
	SET_EF(prog, ed, "button14", bit(16))
	SET_EF(prog, ed, "button15", bit(17))
	SET_EF(prog, ed, "button16", bit(18))
	SET_EF(prog, ed, "buttonuse", bit(8))
	SET_EF(prog, ed, "buttonchat", bit(9))
	SET_EF(prog, ed, "cursor_active", bit(10))
	SET_EV(prog, ed, "movement", move.forwardmove or 0, move.sidemove or 0, move.upmove or 0)
	local cs, cst, ci =
		move.cursor_screen or { 0, 0, 0 }, move.cursor_start or { 0, 0, 0 }, move.cursor_impact or { 0, 0, 0 }
	SET_EV(prog, ed, "cursor_screen", cs[1], cs[2], cs[3])
	SET_EV(prog, ed, "cursor_trace_start", cst[1], cst[2], cst[3])
	SET_EV(prog, ed, "cursor_trace_endpos", ci[1], ci[2], ci[3])
	SET_EI(prog, ed, "cursor_trace_ent", move.cursor_entitynumber or OFS_NULL) -- PRVM_EDICT_TO_PROG(PRVM_EDICT_NUM(n))
	SET_EF(prog, ed, "ping", host_client.ping * 1000.0)
	SET_EF(prog, ed, "ping_packetloss", packetloss / NETGRAPH_PACKETS) -- (float division)
	SET_EF(prog, ed, "ping_movementloss", movementloss / NETGRAPH_PACKETS)
end

-- port: sv_user.c SV_FrameLost L771-783 @xonotic-v0.8.6
local function SV_FrameLost(framenum: number): boolean
	local host_client = server.host_client
	if host_client.entitydatabase5 then
		if framenum <= host_client.entitydatabase5.latestframenum then
			PROTOCOL().EntityFrame5_LostFrame(host_client.entitydatabase5, framenum)
			PROTOCOL().EntityFrameCSQC_LostFrame(host_client, framenum)
			return true
		end
	end
	return false
end
sv_user.SV_FrameLost = SV_FrameLost

-- port: sv_user.c SV_FrameAck L785-793 @xonotic-v0.8.6
local function SV_FrameAck(framenum: number)
	local host_client = server.host_client
	if host_client.entitydatabase then
		PROTOCOL().EntityFrame_AckFrame(host_client.entitydatabase, framenum)
	elseif host_client.entitydatabase4 then
		PROTOCOL().EntityFrame4_AckFrame(host_client.entitydatabase4, framenum, true)
	elseif host_client.entitydatabase5 then
		PROTOCOL().EntityFrame5_AckFrame(host_client.entitydatabase5, framenum)
	end
end
sv_user.SV_FrameAck = SV_FrameAck

--[[
===================
SV_ReadClientMessage
===================
]]
-- port: sv_user.c SV_ReadClientMessage L800-974 @xonotic-v0.8.6
-- (the C switch: clc_nop is an empty case, two cases run the same Cmd_ExecuteString, start is read and unused
-- while downloads are not ported)
-- selene: allow(if_same_then_else, empty_if, unused_variable)
function sv_user.SV_ReadClientMessage()
	local prog: any = cvar.prvm_prog_list[0] -- SVVM_prog
	local sv = server.sv
	local host_client
	local sv_message = sv_user.sv_message
	local SV_DropClient = HOST().SV_DropClient
	local netcmd, num, start
	local s

	if CV("sv_autodemo_perclient").integer >= 2 then
		notPorted("SV_WriteDemoMessage (sv_demo.c) in SV_ReadClientMessage")
	end

	--MSG_BeginReading ();
	sv_user.sv_numreadmoves = 0

	while true do
		host_client = server.host_client -- (the C global, read at each use)
		if not host_client.active then
			-- a command caused an error
			SV_DropClient(false)
			return
		end

		if sv_message.badread then
			console.Con_Print("SV_ReadClientMessage: badread\n")
			SV_DropClient(false)
			return
		end

		netcmd = common.MSG_ReadByte(sv_message)
		if netcmd == -1 then
			-- end of message
			-- apply the moves that were read this frame
			SV_ExecuteClientMoves()
			break
		end

		if netcmd == clc_nop then
			-- (nothing)
		elseif netcmd == clc_stringcmd then
			-- allow reliable messages now as the client is done with initial loading
			if host_client.sendsignon == 2 then
				host_client.sendsignon = 0
			end
			s = common.MSG_ReadString(sv_message, MAX_INPUTLINE) -- sv_readstring
			local q: number? = nil
			local invalid = false
			for p = 1, #s do
				local ch = string.byte(s, p)
				if ch == 10 or ch == 13 then
					if not q then
						q = p
					end
				elseif q then
					invalid = true -- newline seen, THEN something else -> possible exploit
					break
				end
			end
			if not invalid then
				if q then
					s = string.sub(s, 1, q - 1) -- *q = 0
				end
				local lower = libc.lowerascii(string.sub(s, 1, 8))
				if
					string.sub(lower, 1, 5) == "spawn"
					or string.sub(lower, 1, 5) == "begin"
					or string.sub(lower, 1, 8) == "prespawn"
				then
					cmd.Cmd_ExecuteString(s, cmd.src_client, true)
				elseif serverfunction(prog, "SV_ParseClientCommand") ~= 0 then
					local restorevm_tempstringsbuf_cursize
					restorevm_tempstringsbuf_cursize = prog.tempstringsbuf.cursize
					buffer.writei32(prog.globals, OFS_PARM0 * 4, prvm_edict.PRVM_SetTempString(prog, s))
					SET_GF(prog, "time", sv.time)
					SET_GI(prog, "self", host_client.edict)
					prvm_edict.ExecuteProgram(
						prog,
						serverfunction(prog, "SV_ParseClientCommand"),
						"QC function SV_ParseClientCommand is missing"
					)
					prog.tempstringsbuf.cursize = restorevm_tempstringsbuf_cursize
				else
					cmd.Cmd_ExecuteString(s, cmd.src_client, true)
				end
			else
				-- clc_stringcmd_invalid:
				console.Con_Printf("Received invalid stringcmd from %s\n", host_client.name.str)
				if CV("developer").integer > 0 then
					notPorted("Com_HexDumpToConsole (common.c) of an invalid stringcmd in SV_ReadClientMessage")
				end
			end
		elseif netcmd == clc_disconnect then
			SV_DropClient(false) -- client wants to disconnect
			return
		elseif netcmd == clc_move then
			SV_ReadClientMove()
		elseif netcmd == clc_ackdownloaddata then
			start = common.MSG_ReadLong(sv_message)
			num = common.MSG_ReadShort(sv_message)
			if host_client.download_file and host_client.download_started then
				-- (start / num: the block position the client acknowledges)
				notPorted(
					"clc_ackdownloaddata of a running download (sv_user.c L906-949: FS_FileSize, FS_Seek, FS_Read, CRC_Block, cl_downloadfinished) in SV_ReadClientMessage"
				)
			end
		elseif netcmd == clc_ackframe then
			if sv_message.badread then
				badreadat(954)
			end
			num = common.MSG_ReadLong(sv_message)
			if sv_message.badread then
				badreadat(956)
			end
			if developer_networkentities_integer() >= 10 then
				console.Con_Printf("recv clc_ackframe %i\n", num)
			end
			-- if the client hasn't progressed through signons yet,
			-- ignore any clc_ackframes we get (they're probably from the
			-- previous level)
			if host_client.begun and host_client.latestframenum < num then
				local i = host_client.latestframenum + 1
				while i < num do
					if not SV_FrameLost(i) then
						break
					end
					i += 1
				end
				SV_FrameAck(num)
				host_client.latestframenum = num
			end
		else
			console.Con_Printf(
				"SV_ReadClientMessage: unknown command char %i (at offset 0x%x)\n",
				netcmd,
				sv_message.readcount or 0
			)
			if CV("developer_networking").integer ~= 0 then
				notPorted("Com_HexDumpToConsole (common.c) of an unknown client message in SV_ReadClientMessage")
			end
			SV_DropClient(false)
			return
		end
	end
end

return sv_user
