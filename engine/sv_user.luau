--!strict
--[[
Copyright (C) 1996-1997 Id Software, Inc. (DarkPlaces sv_user.c; GPLv2 or later, see engine/prvm_exec.luau)
]]
--[[
	Port of sv_user.c @xonotic-v0.8.6 (server code for moving users). PARTIAL: SV_ClientThink and
	SV_ApplyClientMove.
	host_client is server.host_client (a client_t table, see engine/sv_main.luau); its cmd is the usercmd_t
	(a table whose missing fields are the zeroed C memory). A bot's cmd stays zeroed (receivetime 0), so
	SV_ApplyClientMove returns at once for it, as in C.
	NOT YET PORTED (logged once where reached): the engine movement of SV_ClientThink when the QuakeC has no
	SV_PlayerPhysics or sv_playerphysicsqc is 0 (DropPunchAngle, V_CalcRoll, SV_WaterJump, SV_WaterMove,
	SV_AirMove with SV_UserFriction / SV_Accelerate / SV_AirAccelerate; Xonotic always has SV_PlayerPhysics),
	SV_SetIdealPitch, SV_ReadClientMove, SV_ExecuteClientMoves, SV_ReadClientMessage and the rest (network
	clients, M6-NET).
]]
local cvar = require("./cvar")
local prvm_cmds = require("./prvm_cmds")
local prvm_edict = require("./prvm_edict")
local server = require("./server")

local sv_user = {}

local warned: { [string]: boolean } = {}
local function notPorted(what: string)
	if not warned[what] then
		warned[what] = true
		print("NOT YET PORTED: " .. what)
	end
end

local sv_phys_mod: any = nil

local NETGRAPH_PACKETS = 256 -- netconn.h L217
local NETGRAPH_LOSTPACKET = -1 -- netconn.h L218
local OFS_NULL = 0

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
	if not sv_phys_mod then
		sv_phys_mod = require("./sv_phys") -- sv_phys requires this module (kept: require() is slow in Lune)
	end
	local SV_CheckVelocity = sv_phys_mod.SV_CheckVelocity

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

-- port: sv_user.c SV_ApplyClientMove L708-769 @xonotic-v0.8.6
function sv_user.SV_ApplyClientMove()
	local prog: any = cvar.prvm_prog_list[0] -- SVVM_prog
	local host_client = server.host_client
	local move = host_client.cmd
	if not move then
		-- (a client_t table without cmd: the zeroed usercmd_t)
		move = {}
		host_client.cmd = move
	end
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

return sv_user
