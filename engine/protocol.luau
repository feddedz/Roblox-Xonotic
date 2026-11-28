--!strict
--[[
	DarkPlaces protocol.c / protocol.h, GPLv2 or later (see engine/cvar.luau). protocol.c carries no
	copyright header of its own.
]]
--[[
	Port of protocol.c @xonotic-v0.8.6, the server side Xonotic uses (PROTOCOL_DARKPLACES7 + CSQC entities):
	the protocol table (L57-132), the CSQC entity frames (L274-620), the stats helpers (L622-698) and the
	DP5+ entity frames (L1997-2346, L2633-2697, L2758-3028). Everything is in C order.

	Representation:
	  * entity_state_t is a table with the C field names (protocol.EntityState_New() is the zeroed C memory,
	    protocol.defaultstate the baseline). Vectors / arrays are 1-based (netcenter, origin, angles, light,
	    colormod, glowmod, framegroupblend = 4 x { frame, lerp, start }); skeletonobject is
	    { model, relativetransforms } (model_alias.luau's skeleton: nil = NULL, relativetransforms[i + 1] =
	    matrix4x4_t of bone i). The integer fields hold the C type's value range (the producer truncates, as C
	    stores into unsigned short / unsigned char). `*dst = *src` is protocol.EntityState_Copy(dst, src)
	    (skeletonobject's two pointers are copied, as the C struct copy does).
	  * entityframe5_database_t is a table with the C field names. Its numeric [maxedicts] arrays are buffers
	    at the C element's byte offset: deltabits (u32 per entity, read as int), priorities (u8),
	    updateframenum (i32), visiblebits (u8 bit array); states is a table, C element i at [i + 1].
	    packetlog[i + 1] = { packetnumber, numstates, states = buffer of numstates x (u32 number, u32 bits),
	    statsdeltabits = buffer of 32 bytes }; prioritychaincounts is a buffer of 32 i32, prioritychains one
	    buffer of 32 x 1024 u16 (chain p, slot i at byte (p * 1024 + i) * 2).
	  * client_t is a table of host_cmd.svs.clients (0-based, see engine/sv_main.luau). The fields this file
	    reads that sv_main.luau does not create yet are created zeroed on first use (Mem_Alloc'd client_t
	    memory is zero), by protocol.CSQC_ClientFields / protocol.Stats_ClientFields:
	      csqcnumedicts, csqcentityframehistory_next, csqcentityframe_lastreset (numbers),
	      csqcentityscope (buffer, u8 x MAX_EDICTS), csqcentitysendflags (buffer, u32 x MAX_EDICTS),
	      csqcentityframehistory[i + 1] = { framenum, num, entno = buffer of 256 u16, sendflags = buffer
	      of 256 i32 } (NUM_CSQCENTITYDB_FRAMES = 256 entries),
	      stats[i] (0-based table of MAX_CL_STATS ints), statsdeltabits[i] (0-based table of 32 bytes),
	      like spawn_parms. entitydatabase5 is the database table (nil = NULL).
	  * sv.writeentitiestoclient_clientnumber / sv.writeentitiestoclient_cliententitynumber are read with a
	    default of 0 (server.h L156-157; sv_main.luau's SV_WriteEntitiesToClient sets them).
	  * an edict is its number (prog->edicts + n is n); PRVM_serveredictfunction(ed, SendEntity) is the i32
	    slot of the field; PRVM_G_* are the 4-byte slots of prog.globals; SVVM_prog is cvar.prvm_prog_list[0].
	NOT PORTED (client side, not in scope): EntityFrameQuake_ReadEntity, EntityFrameQuake_ISeeDeadEntities,
	EntityState_ReadExtendBits, EntityState_ReadFields, EntityFrame_CL_ReadFrame, EntityFrame4_CL_ReadFrame,
	EntityState5_ReadUpdate, EntityFrame5_CL_ReadFrame, QW_TranslateEffects, EntityStateQW_ReadPlayerUpdate,
	EntityStateQW_ReadEntityUpdate, EntityFrameQW_AllocDatabase, EntityFrameQW_FreeDatabase,
	EntityFrameQW_CL_ReadFrame.
	NOT YET PORTED (the pre-DP5 server writers, log when reached): EntityFrameQuake_WriteFrame,
	EntityState_DeltaBits, EntityState_WriteExtendBits, EntityState_WriteFields, EntityState_WriteUpdate, the
	EntityFrame_* (DP1-3) and EntityFrame4_* (DP4) database functions.
	There is no EntityFrame5_ResetDatabase in 0.8.6.
]]
local common = require("./common")
local console = require("./console")
local cvar = require("./cvar")
local f32 = require("./_port/f32")
local host_cmd = require("./host_cmd")
local libc = require("./_port/libc")
local matrixlib = require("./matrixlib")
local prvm_cmds = require("./prvm_cmds")
local prvm_edict = require("./prvm_edict")
local server = require("./server")

local protocol = {}

local R = f32.round
local toint = libc.toint
local band, bor, bnot, rshift, lshift = bit32.band, bit32.bor, bit32.bnot, bit32.rshift, bit32.lshift
local readu8, writeu8 = buffer.readu8, buffer.writeu8
local readu16, writeu16 = buffer.readu16, buffer.writeu16
local readi32, writei32 = buffer.readi32, buffer.writei32
local readu32, writeu32 = buffer.readu32, buffer.writeu32
local FieldOfs = prvm_edict.FieldOfs
local GlobalOfs = prvm_cmds.GlobalOfs
local Con_Printf, Con_DPrintf = console.Con_Printf, console.Con_DPrintf
local MSG_WriteByte, MSG_WriteShort, MSG_WriteLong = common.MSG_WriteByte, common.MSG_WriteShort, common.MSG_WriteLong
local MSG_WriteCoord13i, MSG_WriteCoord32f = common.MSG_WriteCoord13i, common.MSG_WriteCoord32f
local MSG_WriteAngle8i, MSG_WriteAngle16i = common.MSG_WriteAngle8i, common.MSG_WriteAngle16i
local P = common.PROTOCOL

local warned: { [string]: boolean } = {}
local function notPorted(what: string)
	if not warned[what] then
		warned[what] = true
		print("NOT YET PORTED: " .. what)
	end
end

-- sv_main.luau (SV_GetModelByIndex), resolved on first use: sv_main will require this module
local sv_main_mod: any = nil
local function SV_GetModelByIndex(modelindex: number): any
	if not sv_main_mod then
		sv_main_mod = (require :: any)("./sv_main")
	end
	return sv_main_mod.SV_GetModelByIndex(modelindex)
end

-- quakedef.h L139, L221, L233-241
local MAX_EDICTS = 32768
local MAX_CL_STATS = 256
local STAT_TOTALSECRETS, STAT_TOTALMONSTERS, STAT_SECRETS, STAT_MONSTERS = 11, 12, 13, 14
local STAT_VIEWHEIGHT, STAT_VIEWZOOM = 16, 21
protocol.MAX_EDICTS = MAX_EDICTS
protocol.MAX_CL_STATS = MAX_CL_STATS
-- server.h L173, L264
local NUM_CSQCENTITIES_PER_FRAME = 256
local NUM_CSQCENTITYDB_FRAMES = 256
protocol.NUM_CSQCENTITIES_PER_FRAME = NUM_CSQCENTITIES_PER_FRAME
protocol.NUM_CSQCENTITYDB_FRAMES = NUM_CSQCENTITYDB_FRAMES
-- protocol.h svc_* (L191, L244, L251-252), qw_svc_* (L849, L876)
local svc_updatestat, svc_updatestatubyte, svc_entities, svc_csqcentities = 3, 51, 57, 58
local qw_svc_updatestat, qw_svc_updatestatlong = 3, 38
protocol.svc_updatestat = svc_updatestat
protocol.svc_updatestatubyte = svc_updatestatubyte
protocol.svc_entities = svc_entities
protocol.svc_csqcentities = svc_csqcentities
-- pr_comp.h
local OFS_RETURN, OFS_PARM0, OFS_PARM1 = 1, 4, 7

-- protocol.h L82-84
protocol.PFLAGS_NOSHADOW = 1
protocol.PFLAGS_CORONA = 2
protocol.PFLAGS_FULLDYNAMIC = 128
-- protocol.h L87-125
protocol.U_MOREBITS = 0x00000001
protocol.U_ORIGIN1 = 0x00000002
protocol.U_ORIGIN2 = 0x00000004
protocol.U_ORIGIN3 = 0x00000008
protocol.U_ANGLE2 = 0x00000010
protocol.U_STEP = 0x00000020
protocol.U_FRAME = 0x00000040
protocol.U_SIGNAL = 0x00000080
protocol.U_ANGLE1 = 0x00000100
protocol.U_ANGLE3 = 0x00000200
protocol.U_MODEL = 0x00000400
protocol.U_COLORMAP = 0x00000800
protocol.U_SKIN = 0x00001000
protocol.U_EFFECTS = 0x00002000
protocol.U_LONGENTITY = 0x00004000
protocol.U_EXTEND1 = 0x00008000
protocol.U_DELTA = 0x00010000
protocol.U_ALPHA = 0x00020000
protocol.U_SCALE = 0x00040000
protocol.U_EFFECTS2 = 0x00080000
protocol.U_GLOWSIZE = 0x00100000
protocol.U_GLOWCOLOR = 0x00200000
protocol.U_COLORMOD = 0x00400000
protocol.U_EXTEND2 = 0x00800000
protocol.U_GLOWTRAIL = 0x01000000
protocol.U_VIEWMODEL = 0x02000000
protocol.U_FRAME2 = 0x04000000
protocol.U_MODEL2 = 0x08000000
protocol.U_EXTERIORMODEL = 0x10000000
protocol.U_UNUSED29 = 0x20000000
protocol.U_UNUSED30 = 0x40000000
protocol.U_EXTEND3 = 0x80000000
-- protocol.h L330-348
local RENDER_VIEWMODEL = 4
local RENDER_LOWPRECISION = 16
local RENDER_COMPLEXANIMATION = 128
protocol.RENDER_STEP = 1
protocol.RENDER_GLOWTRAIL = 2
protocol.RENDER_VIEWMODEL = RENDER_VIEWMODEL
protocol.RENDER_EXTERIORMODEL = 8
protocol.RENDER_LOWPRECISION = RENDER_LOWPRECISION
protocol.RENDER_COLORMAPPED = 32
protocol.RENDER_WORLDOBJECT = 64
protocol.RENDER_COMPLEXANIMATION = RENDER_COMPLEXANIMATION
protocol.RENDER_SHADOW = 65536
protocol.RENDER_LIGHT = 131072
protocol.RENDER_NOSELFSHADOW = 262144
protocol.RENDER_EQUALIZE = 524288
protocol.RENDER_NODEPTHTEST = 1048576
protocol.RENDER_ADDITIVE = 2097152
protocol.RENDER_DOUBLESIDED = 4194304
protocol.RENDER_CUSTOMIZEDMODELLIGHT = 4096
protocol.RENDER_DYNAMICMODELLIGHT = 8388608
protocol.MAX_FRAMEGROUPBLENDS = 4 -- protocol.h L350
-- entity_state_active_t (protocol.h L372-378)
local ACTIVE_NOT, ACTIVE_NETWORK, ACTIVE_SHARED = 0, 1, 2
protocol.ACTIVE_NOT = ACTIVE_NOT
protocol.ACTIVE_NETWORK = ACTIVE_NETWORK
protocol.ACTIVE_SHARED = ACTIVE_SHARED
-- protocol.h L683-768
local E5_FULLUPDATE = 0x00000001
local E5_ORIGIN = 0x00000002
local E5_ANGLES = 0x00000004
local E5_MODEL = 0x00000008
local E5_FRAME = 0x00000010
local E5_SKIN = 0x00000020
local E5_EFFECTS = 0x00000040
local E5_EXTEND1 = 0x00000080
local E5_FLAGS = 0x00000100
local E5_ALPHA = 0x00000200
local E5_SCALE = 0x00000400
local E5_ORIGIN32 = 0x00000800
local E5_ANGLES16 = 0x00001000
local E5_MODEL16 = 0x00002000
local E5_COLORMAP = 0x00004000
local E5_EXTEND2 = 0x00008000
local E5_ATTACHMENT = 0x00010000
local E5_LIGHT = 0x00020000
local E5_GLOW = 0x00040000
local E5_EFFECTS16 = 0x00080000
local E5_EFFECTS32 = 0x00100000
local E5_FRAME16 = 0x00200000
local E5_COLORMOD = 0x00400000
local E5_EXTEND3 = 0x00800000
local E5_GLOWMOD = 0x01000000
local E5_COMPLEXANIMATION = 0x02000000
local E5_TRAILEFFECTNUM = 0x04000000
protocol.E5_FULLUPDATE = E5_FULLUPDATE
protocol.E5_ORIGIN = E5_ORIGIN
protocol.E5_ANGLES = E5_ANGLES
protocol.E5_MODEL = E5_MODEL
protocol.E5_FRAME = E5_FRAME
protocol.E5_SKIN = E5_SKIN
protocol.E5_EFFECTS = E5_EFFECTS
protocol.E5_EXTEND1 = E5_EXTEND1
protocol.E5_FLAGS = E5_FLAGS
protocol.E5_ALPHA = E5_ALPHA
protocol.E5_SCALE = E5_SCALE
protocol.E5_ORIGIN32 = E5_ORIGIN32
protocol.E5_ANGLES16 = E5_ANGLES16
protocol.E5_MODEL16 = E5_MODEL16
protocol.E5_COLORMAP = E5_COLORMAP
protocol.E5_EXTEND2 = E5_EXTEND2
protocol.E5_ATTACHMENT = E5_ATTACHMENT
protocol.E5_LIGHT = E5_LIGHT
protocol.E5_GLOW = E5_GLOW
protocol.E5_EFFECTS16 = E5_EFFECTS16
protocol.E5_EFFECTS32 = E5_EFFECTS32
protocol.E5_FRAME16 = E5_FRAME16
protocol.E5_COLORMOD = E5_COLORMOD
protocol.E5_EXTEND3 = E5_EXTEND3
protocol.E5_GLOWMOD = E5_GLOWMOD
protocol.E5_COMPLEXANIMATION = E5_COMPLEXANIMATION
protocol.E5_TRAILEFFECTNUM = E5_TRAILEFFECTNUM
protocol.E5_UNUSED27 = 0x08000000
protocol.E5_UNUSED28 = 0x10000000
protocol.E5_UNUSED29 = 0x20000000
protocol.E5_UNUSED30 = 0x40000000
protocol.E5_EXTEND4 = 0x80000000
local ENTITYFRAME5_MAXPACKETLOGS = 64
local ENTITYFRAME5_MAXSTATES = 1024
local ENTITYFRAME5_PRIORITYLEVELS = 32
protocol.ENTITYFRAME5_MAXPACKETLOGS = ENTITYFRAME5_MAXPACKETLOGS
protocol.ENTITYFRAME5_MAXSTATES = ENTITYFRAME5_MAXSTATES
protocol.ENTITYFRAME5_PRIORITYLEVELS = ENTITYFRAME5_PRIORITYLEVELS
local STATSBYTES = (MAX_CL_STATS + 7) // 8 -- (MAX_CL_STATS+7)/8

-- CSQC entity scope values. Bitflags! (protocol.c L13-18)
local SCOPE_WANTREMOVE = 1 -- Set if a remove has been scheduled. Never set together with WANTUPDATE.
local SCOPE_WANTUPDATE = 2 -- Set if an update has been scheduled.
local SCOPE_WANTSEND = bor(SCOPE_WANTREMOVE, SCOPE_WANTUPDATE)
local SCOPE_EXISTED_ONCE = 4 -- Set if the entity once existed. All these get resent on a full loss.
local SCOPE_ASSUMED_EXISTING = 8 -- Set if the entity is currently assumed existing and therefore needs removes.
protocol.SCOPE_WANTREMOVE = SCOPE_WANTREMOVE
protocol.SCOPE_WANTUPDATE = SCOPE_WANTUPDATE
protocol.SCOPE_EXISTED_ONCE = SCOPE_EXISTED_ONCE
protocol.SCOPE_ASSUMED_EXISTING = SCOPE_ASSUMED_EXISTING

-- C `int` from a 32-bit pattern
local function s32(x: number): number
	return if x >= 0x80000000 then x - 0x100000000 else x
end

export type framegroupblend_t = { frame: number, lerp: number, start: number }
export type skeleton_t = { model: any, relativetransforms: any }
export type entity_state_t = {
	time: number,
	netcenter: { number },
	origin: { number },
	angles: { number },
	effects: number,
	customizeentityforclient: number,
	number: number,
	modelindex: number,
	frame: number,
	tagentity: number,
	specialvisibilityradius: number,
	viewmodelforclient: number,
	exteriormodelforclient: number,
	nodrawtoclient: number,
	drawonlytoclient: number,
	traileffectnum: number,
	light: { number },
	active: number,
	lightstyle: number,
	lightpflags: number,
	colormap: number,
	skin: number,
	alpha: number,
	scale: number,
	glowsize: number,
	glowcolor: number,
	flags: number,
	internaleffects: number,
	tagindex: number,
	colormod: { number },
	glowmod: { number },
	framegroupblend: { framegroupblend_t },
	skeletonobject: skeleton_t,
}

-- a zeroed entity_state_t (memset 0 / Mem_Alloc'd memory)
function protocol.EntityState_New(): entity_state_t
	return {
		time = 0,
		netcenter = { 0, 0, 0 },
		origin = { 0, 0, 0 },
		angles = { 0, 0, 0 },
		effects = 0,
		customizeentityforclient = 0,
		number = 0,
		modelindex = 0,
		frame = 0,
		tagentity = 0,
		specialvisibilityradius = 0,
		viewmodelforclient = 0,
		exteriormodelforclient = 0,
		nodrawtoclient = 0,
		drawonlytoclient = 0,
		traileffectnum = 0,
		light = { 0, 0, 0, 0 },
		active = 0,
		lightstyle = 0,
		lightpflags = 0,
		colormap = 0,
		skin = 0,
		alpha = 0,
		scale = 0,
		glowsize = 0,
		glowcolor = 0,
		flags = 0,
		internaleffects = 0,
		tagindex = 0,
		colormod = { 0, 0, 0 },
		glowmod = { 0, 0, 0 },
		framegroupblend = {
			{ frame = 0, lerp = 0, start = 0 },
			{ frame = 0, lerp = 0, start = 0 },
			{ frame = 0, lerp = 0, start = 0 },
			{ frame = 0, lerp = 0, start = 0 },
		},
		skeletonobject = { model = nil, relativetransforms = nil },
	}
end
local EntityState_New = protocol.EntityState_New

-- *dst = *src (entity_state_t struct assignment)
function protocol.EntityState_Copy(dst: entity_state_t, src: entity_state_t)
	dst.time = src.time
	local a, b = dst.netcenter, src.netcenter
	a[1], a[2], a[3] = b[1], b[2], b[3]
	a, b = dst.origin, src.origin
	a[1], a[2], a[3] = b[1], b[2], b[3]
	a, b = dst.angles, src.angles
	a[1], a[2], a[3] = b[1], b[2], b[3]
	dst.effects = src.effects
	dst.customizeentityforclient = src.customizeentityforclient
	dst.number = src.number
	dst.modelindex = src.modelindex
	dst.frame = src.frame
	dst.tagentity = src.tagentity
	dst.specialvisibilityradius = src.specialvisibilityradius
	dst.viewmodelforclient = src.viewmodelforclient
	dst.exteriormodelforclient = src.exteriormodelforclient
	dst.nodrawtoclient = src.nodrawtoclient
	dst.drawonlytoclient = src.drawonlytoclient
	dst.traileffectnum = src.traileffectnum
	a, b = dst.light, src.light
	a[1], a[2], a[3], a[4] = b[1], b[2], b[3], b[4]
	dst.active = src.active
	dst.lightstyle = src.lightstyle
	dst.lightpflags = src.lightpflags
	dst.colormap = src.colormap
	dst.skin = src.skin
	dst.alpha = src.alpha
	dst.scale = src.scale
	dst.glowsize = src.glowsize
	dst.glowcolor = src.glowcolor
	dst.flags = src.flags
	dst.internaleffects = src.internaleffects
	dst.tagindex = src.tagindex
	a, b = dst.colormod, src.colormod
	a[1], a[2], a[3] = b[1], b[2], b[3]
	a, b = dst.glowmod, src.glowmod
	a[1], a[2], a[3] = b[1], b[2], b[3]
	for i = 1, 4 do
		local x, y = dst.framegroupblend[i], src.framegroupblend[i]
		x.frame, x.lerp, x.start = y.frame, y.lerp, y.start
	end
	dst.skeletonobject.model = src.skeletonobject.model
	dst.skeletonobject.relativetransforms = src.skeletonobject.relativetransforms
end
local EntityState_Copy = protocol.EntityState_Copy

-- this is 88 bytes (must match entity_state_t in protocol.h)
-- protocol.c defaultstate L20-55
local defaultstate = EntityState_New()
defaultstate.active = ACTIVE_NOT
defaultstate.alpha = 255
defaultstate.scale = 16
defaultstate.glowcolor = 254
defaultstate.colormod = { 32, 32, 32 }
defaultstate.glowmod = { 32, 32, 32 }
protocol.defaultstate = defaultstate

-- LordHavoc: I own protocol ranges 96, 97, 3500-3599

-- protocol.c protocolversioninfo L59-82 (the terminating { 0, PROTOCOL_UNKNOWN, NULL } is the end of the table)
local protocolversioninfo: { { number: number, version: number, name: string } } = {
	{ number = 3504, version = P.DARKPLACES7, name = "DP7" },
	{ number = 3503, version = P.DARKPLACES6, name = "DP6" },
	{ number = 3502, version = P.DARKPLACES5, name = "DP5" },
	{ number = 3501, version = P.DARKPLACES4, name = "DP4" },
	{ number = 3500, version = P.DARKPLACES3, name = "DP3" },
	{ number = 97, version = P.DARKPLACES2, name = "DP2" },
	{ number = 96, version = P.DARKPLACES1, name = "DP1" },
	{ number = 15, version = P.QUAKEDP, name = "QUAKEDP" },
	{ number = 15, version = P.QUAKE, name = "QUAKE" },
	{ number = 28, version = P.QUAKEWORLD, name = "QW" },
	{ number = 250, version = P.NEHAHRAMOVIE, name = "NEHAHRAMOVIE" },
	{ number = 10000, version = P.NEHAHRABJP, name = "NEHAHRABJP" },
	{ number = 10001, version = P.NEHAHRABJP2, name = "NEHAHRABJP2" },
	{ number = 10002, version = P.NEHAHRABJP3, name = "NEHAHRABJP3" },
}
protocol.protocolversioninfo = protocolversioninfo

-- port: protocol.c Protocol_EnumForName L84-91 @xonotic-v0.8.6
function protocol.Protocol_EnumForName(s: string): number
	for i = 1, #protocolversioninfo do
		if libc.strcasecmp(s, protocolversioninfo[i].name) == 0 then
			return protocolversioninfo[i].version
		end
	end
	return P.UNKNOWN
end

-- port: protocol.c Protocol_NameForEnum L93-100 @xonotic-v0.8.6
function protocol.Protocol_NameForEnum(p: number): string
	for i = 1, #protocolversioninfo do
		if protocolversioninfo[i].version == p then
			return protocolversioninfo[i].name
		end
	end
	return "UNKNOWN"
end

-- port: protocol.c Protocol_EnumForNumber L102-109 @xonotic-v0.8.6
function protocol.Protocol_EnumForNumber(n: number): number
	for i = 1, #protocolversioninfo do
		if protocolversioninfo[i].number == n then
			return protocolversioninfo[i].version
		end
	end
	return P.UNKNOWN
end

-- port: protocol.c Protocol_NumberForEnum L111-118 @xonotic-v0.8.6
function protocol.Protocol_NumberForEnum(p: number): number
	for i = 1, #protocolversioninfo do
		if protocolversioninfo[i].version == p then
			return protocolversioninfo[i].number
		end
	end
	return 0
end

-- strlcat into a char[buffersize] holding `dst`
local function strlcat(dst: string, src: string, buffersize: number): string
	local room = buffersize - 1 - #dst
	if room <= 0 then
		return dst
	end
	return dst .. string.sub(src, 1, room)
end

-- port: protocol.c Protocol_Names L120-132 @xonotic-v0.8.6 (returns the text of buffer; nil when buffersize < 1,
-- where C leaves the buffer untouched)
-- engine quirk kept: the separator is only added from the third name on ("DP7DP6 DP5 ...")
function protocol.Protocol_Names(buffersize: number): string?
	local buf
	if buffersize < 1 then
		return nil
	end
	buf = ""
	for i = 0, #protocolversioninfo - 1 do
		if i > 1 then
			buf = strlcat(buf, " ", buffersize)
		end
		buf = strlcat(buf, protocolversioninfo[i + 1].name, buffersize)
	end
	return buf
end

-- the C stubs of the client side readers are not in this module (see the header)

-- PRVM_serveredictfunction(ed, SendEntity) (0 when the progs have no such field)
local function SendEntityOf(prog: any, ed: number): number
	local o = FieldOfs(prog, "SendEntity")
	if o < 0 then
		return 0
	end
	return readi32(prog.edictsfields, (ed * prog.entityfields + o) * 4)
end

-- developer_networkentities (cl_parse.c L174, registered by CL_Parse_Init; 0 until registered)
local developer_networkentities: any = nil
local function developer_networkentities_integer(): number
	if not developer_networkentities then
		developer_networkentities = cvar.Cvar_FindVar("developer_networkentities")
		if not developer_networkentities then
			return 0
		end
	end
	return developer_networkentities.integer
end

-- ENTITYSIZEPROFILING_END (protocol.c L6-11); start is entityprofiling_startsize (ENTITYSIZEPROFILING_START)
local function ENTITYSIZEPROFILING_END(msg: common.SizeBuf, start: number, num: number, flags: number)
	if developer_networkentities_integer() >= 2 then
		local prog: any = cvar.prvm_prog_list[0] -- SVVM_prog
		local o = FieldOfs(prog, "classname")
		local cn = if o >= 0 then readi32(prog.edictsfields, (num * prog.entityfields + o) * 4) else 0
		Con_Printf(
			"sent entity update of size %d for %d classname %s flags %d\n",
			msg.cursize - start,
			num,
			if cn ~= 0 then prvm_edict.PRVM_GetString(prog, cn) else "(no classname)",
			flags
		)
	end
end

-- the client_t fields of the CSQC entity database (see the header), created zeroed on first use
function protocol.CSQC_ClientFields(client: any)
	if client.csqcentityscope == nil then
		client.csqcnumedicts = client.csqcnumedicts or 0
		client.csqcentityscope = buffer.create(MAX_EDICTS)
		client.csqcentitysendflags = buffer.create(MAX_EDICTS * 4)
		local h = table.create(NUM_CSQCENTITYDB_FRAMES)
		for i = 1, NUM_CSQCENTITYDB_FRAMES do
			h[i] = {
				framenum = 0,
				num = 0,
				entno = buffer.create(NUM_CSQCENTITIES_PER_FRAME * 2),
				sendflags = buffer.create(NUM_CSQCENTITIES_PER_FRAME * 4),
			}
		end
		client.csqcentityframehistory = h
		client.csqcentityframehistory_next = client.csqcentityframehistory_next or 0
		client.csqcentityframe_lastreset = client.csqcentityframe_lastreset or 0
	end
end
local CSQC_ClientFields = protocol.CSQC_ClientFields

-- the client_t stats / statsdeltabits arrays (see the header), created zeroed on first use
function protocol.Stats_ClientFields(client: any)
	if client.stats == nil then
		local st = {}
		for i = 0, MAX_CL_STATS - 1 do
			st[i] = 0
		end
		client.stats = st
	end
	if client.statsdeltabits == nil then
		local sd = {}
		for i = 0, STATSBYTES - 1 do
			sd[i] = 0
		end
		client.statsdeltabits = sd
	end
end
local Stats_ClientFields = protocol.Stats_ClientFields

-- NOTE: this only works with DP5 protocol and upwards. For lower protocols
-- (including QUAKE), no packet loss handling for CSQC is done, which makes
-- CSQC basically useless.
-- Always use the DP5 protocol, or a higher one, when using CSQC entities.
-- port: protocol.c EntityFrameCSQC_LostAllFrames L278-297 @xonotic-v0.8.6
local function EntityFrameCSQC_LostAllFrames(client: any)
	local prog: any = cvar.prvm_prog_list[0] -- SVVM_prog
	-- mark ALL csqc entities as requiring a FULL resend!
	-- I know this is a bad workaround, but better than nothing.
	local i, n
	local ed
	CSQC_ClientFields(client)
	local scope, sendflags = client.csqcentityscope, client.csqcentitysendflags

	n = client.csqcnumedicts
	i = 0
	while i < n do
		if band(readu8(scope, i), SCOPE_EXISTED_ONCE) ~= 0 then
			ed = i
			writeu32(sendflags, i * 4, bor(readu32(sendflags, i * 4), 0xFFFFFF)) -- FULL RESEND. We can't clear SCOPE_ASSUMED_EXISTING yet as this would cancel removes on a rejected send attempt.
			if SendEntityOf(prog, ed) == 0 then -- If it was ever sent to that client as a CSQC entity...
				writeu8(scope, i, bor(readu8(scope, i), SCOPE_ASSUMED_EXISTING)) -- FORCE REMOVE.
			end
		end
		i += 1
	end
end
protocol.EntityFrameCSQC_LostAllFrames = EntityFrameCSQC_LostAllFrames

local recoversendflags = buffer.create(MAX_EDICTS * 4) -- static int recoversendflags[MAX_EDICTS]; // client only

-- port: protocol.c EntityFrameCSQC_LostFrame L298-405 @xonotic-v0.8.6
function protocol.EntityFrameCSQC_LostFrame(client: any, framenum: number)
	-- marks a frame as lost
	local i, j
	local valid
	local ringfirst, ringlast
	local d
	CSQC_ClientFields(client)
	local history = client.csqcentityframehistory

	if client.csqcentityframe_lastreset < 0 then
		return
	end
	if framenum < client.csqcentityframe_lastreset then
		return -- no action required, as we resent that data anyway
	end

	-- is our frame out of history?
	ringfirst = client.csqcentityframehistory_next -- oldest entry
	ringlast = (ringfirst + NUM_CSQCENTITYDB_FRAMES - 1) % NUM_CSQCENTITYDB_FRAMES -- most recently added entry

	valid = false

	j = 0
	while j < NUM_CSQCENTITYDB_FRAMES do
		d = history[(ringfirst + j) % NUM_CSQCENTITYDB_FRAMES + 1]
		if d.framenum < 0 then
			j += 1
			continue
		end
		if d.framenum == framenum then
			break
		elseif d.framenum < framenum then
			valid = true
		end
		j += 1
	end
	if j == NUM_CSQCENTITYDB_FRAMES then
		if valid then -- got beaten, i.e. there is a frame < framenum
			-- a non-csqc frame got lost... great
			return
		else
			-- a too old frame got lost... sorry, cannot handle this
			Con_DPrintf("CSQC entity DB: lost a frame too early to do any handling (resending ALL)...\n")
			Con_DPrintf("Lost frame = %d\n", framenum)
			Con_DPrintf("Entity DB = %d to %d\n", history[ringfirst + 1].framenum, history[ringlast + 1].framenum)
			EntityFrameCSQC_LostAllFrames(client)
			client.csqcentityframe_lastreset = -1
		end
		return
	end

	-- so j is the frame that got lost
	-- ringlast is the frame that we have to go to
	ringfirst = (ringfirst + j) % NUM_CSQCENTITYDB_FRAMES
	if ringlast < ringfirst then
		ringlast += NUM_CSQCENTITYDB_FRAMES
	end

	buffer.fill(recoversendflags, 0, 0)

	-- selene: allow(empty_if)
	for jj = ringfirst, ringlast do
		d = history[jj % NUM_CSQCENTITYDB_FRAMES + 1]
		if d.framenum < 0 then
			-- deleted frame
		elseif d.framenum < framenum then
			-- a frame in the past... should never happen
			Con_Printf("CSQC entity DB encountered a frame from the past when recovering from PL...?\n")
		elseif d.framenum == framenum then
			-- handling the actually lost frame now
			for ii = 0, d.num - 1 do
				local sf = readi32(d.sendflags, ii * 4)
				local ent = readu16(d.entno, ii * 2)
				if sf < 0 then -- remove
					writeu32(recoversendflags, ent * 4, 0xFFFFFFFF) -- |= -1: all bits, including sign
				elseif sf > 0 then
					writeu32(recoversendflags, ent * 4, bor(readu32(recoversendflags, ent * 4), sf))
				end
			end
		else
			-- handling the frames that followed it now
			for ii = 0, d.num - 1 do
				local sf = readi32(d.sendflags, ii * 4)
				local ent = readu16(d.entno, ii * 2)
				if sf < 0 then -- remove
					writeu32(recoversendflags, ent * 4, 0) -- no need to update, we got a more recent remove (and will fix it THEN)
					break -- no flags left to remove...
				elseif sf > 0 then
					writeu32(recoversendflags, ent * 4, band(readu32(recoversendflags, ent * 4), bnot(sf))) -- no need to update these bits, we already got them later
				end
			end
		end
	end

	local scope, sendflags = client.csqcentityscope, client.csqcentitysendflags
	i = 0
	while i < client.csqcnumedicts do
		local r = readi32(recoversendflags, i * 4)
		if r < 0 then
			writeu8(scope, i, bor(readu8(scope, i), SCOPE_ASSUMED_EXISTING)) -- FORCE REMOVE.
		else
			writeu32(sendflags, i * 4, bor(readu32(sendflags, i * 4), r))
		end
		i += 1
	end
end

-- port: protocol.c EntityFrameCSQC_AllocFrame L406-414 @xonotic-v0.8.6
local function EntityFrameCSQC_AllocFrame(client: any, framenum: number): number
	local ringfirst = client.csqcentityframehistory_next -- oldest entry
	client.csqcentityframehistory_next += 1
	client.csqcentityframehistory_next %= NUM_CSQCENTITYDB_FRAMES
	client.csqcentityframehistory[ringfirst + 1].framenum = framenum
	client.csqcentityframehistory[ringfirst + 1].num = 0
	return ringfirst
end
protocol.EntityFrameCSQC_AllocFrame = EntityFrameCSQC_AllocFrame

-- port: protocol.c EntityFrameCSQC_DeallocFrame L415-427 @xonotic-v0.8.6
local function EntityFrameCSQC_DeallocFrame(client: any, framenum: number)
	local ringfirst = client.csqcentityframehistory_next -- oldest entry
	local ringlast = (ringfirst + NUM_CSQCENTITYDB_FRAMES - 1) % NUM_CSQCENTITYDB_FRAMES -- most recently added entry
	if framenum == client.csqcentityframehistory[ringlast + 1].framenum then
		client.csqcentityframehistory[ringlast + 1].framenum = -1
		client.csqcentityframehistory[ringlast + 1].num = 0
		client.csqcentityframehistory_next = ringlast
	else
		Con_Printf("Trying to dealloc the wrong entity frame\n")
	end
end
protocol.EntityFrameCSQC_DeallocFrame = EntityFrameCSQC_DeallocFrame

--[515]: we use only one array per-client for SendEntity feature
-- TODO: add some handling for entity send priorities, to better deal with huge
-- amounts of csqc networked entities
-- port: protocol.c EntityFrameCSQC_WriteFrame L432-620 @xonotic-v0.8.6
-- numbers: the entity numbers (unsigned short), C element i at [i + 1]
function protocol.EntityFrameCSQC_WriteFrame(
	msg: common.SizeBuf,
	maxsize: number,
	numnumbers: number,
	numbers: { number },
	framenum: number
): boolean
	local prog: any = cvar.prvm_prog_list[0] -- SVVM_prog
	local sv = server.sv :: any
	local svs = host_cmd.svs :: any
	local num, number, iend, sendflags
	local sectionstarted = false
	local ed
	local client = svs.clients[sv.writeentitiestoclient_clientnumber or 0]
	CSQC_ClientFields(client)
	local dbframe = EntityFrameCSQC_AllocFrame(client, framenum)
	local db = client.csqcentityframehistory[dbframe + 1]
	local scope, csf = client.csqcentityscope, client.csqcentitysendflags
	local globals = prog.globals

	if client.csqcentityframe_lastreset < 0 then
		client.csqcentityframe_lastreset = framenum
	end

	maxsize -= 24 -- always fit in an empty svc_entities message (for packet loss detection!)

	-- make sure there is enough room to store the svc_csqcentities byte,
	-- the terminator (0x0000) and at least one entity update
	if msg.cursize + 32 >= maxsize then
		return false
	end

	if client.csqcnumedicts < prog.num_edicts then
		client.csqcnumedicts = prog.num_edicts
	end

	number = 1
	num = 0
	while num < numnumbers do
		iend = numbers[num + 1]
		while number < iend do
			writeu8(scope, number, band(readu8(scope, number), bnot(SCOPE_WANTSEND)))
			if band(readu8(scope, number), SCOPE_ASSUMED_EXISTING) ~= 0 then
				writeu8(scope, number, bor(readu8(scope, number), SCOPE_WANTREMOVE))
			end
			writeu32(csf, number * 4, 0xFFFFFF)
			number += 1
		end
		ed = number
		writeu8(scope, number, band(readu8(scope, number), bnot(SCOPE_WANTSEND)))
		if SendEntityOf(prog, ed) ~= 0 then
			writeu8(scope, number, bor(readu8(scope, number), SCOPE_WANTUPDATE))
		else
			if band(readu8(scope, number), SCOPE_ASSUMED_EXISTING) ~= 0 then
				writeu8(scope, number, bor(readu8(scope, number), SCOPE_WANTREMOVE))
			end
			writeu32(csf, number * 4, 0xFFFFFF)
		end
		number += 1
		num += 1
	end
	iend = client.csqcnumedicts
	while number < iend do
		writeu8(scope, number, band(readu8(scope, number), bnot(SCOPE_WANTSEND)))
		if band(readu8(scope, number), SCOPE_ASSUMED_EXISTING) ~= 0 then
			writeu8(scope, number, bor(readu8(scope, number), SCOPE_WANTREMOVE))
		end
		writeu32(csf, number * 4, 0xFFFFFF)
		number += 1
	end

	-- now try to emit the entity updates
	-- (FIXME: prioritize by distance?)
	iend = client.csqcnumedicts
	number = 1
	while number < iend do
		if band(readu8(scope, number), SCOPE_WANTSEND) == 0 then
			number += 1
			continue
		end
		if db.num >= NUM_CSQCENTITIES_PER_FRAME then
			break
		end
		ed = number
		if band(readu8(scope, number), SCOPE_WANTREMOVE) ~= 0 then -- Also implies ASSUMED_EXISTING.
			-- A removal. SendFlags have no power here.
			-- write a remove message
			-- first write the message identifier if needed
			if not sectionstarted then
				sectionstarted = true
				MSG_WriteByte(msg, svc_csqcentities)
			end
			-- write the remove message
			do
				local entityprofiling_startsize = msg.cursize
				MSG_WriteShort(msg, bor(band(number, 0xFFFF), 0x8000))
				writeu8(scope, number, band(readu8(scope, number), bnot(bor(SCOPE_WANTSEND, SCOPE_ASSUMED_EXISTING))))
				writeu32(csf, number * 4, 0xFFFFFF) -- resend completely if it becomes active again
				writeu16(db.entno, db.num * 2, number)
				writei32(db.sendflags, db.num * 4, -1)
				db.num += 1
				ENTITYSIZEPROFILING_END(msg, entityprofiling_startsize, number, 0)
			end
			if msg.cursize + 17 >= maxsize then
				break
			end
		else
			-- save the cursize value in case we overflow and have to rollback
			local oldcursize = msg.cursize

			-- An update.
			sendflags = readi32(csf, number * 4)
			-- Nothing to send? FINE.
			if sendflags == 0 then
				number += 1
				continue
			end
			-- If it's a new entity, always assume sendflags 0xFFFFFF.
			if band(readu8(scope, number), SCOPE_ASSUMED_EXISTING) == 0 then
				sendflags = 0xFFFFFF
			end

			-- write an update
			local sendentity = SendEntityOf(prog, ed)
			if sendentity ~= 0 then
				if not sectionstarted then
					MSG_WriteByte(msg, svc_csqcentities)
				end
				do
					local oldcursize2 = msg.cursize
					local entityprofiling_startsize = msg.cursize
					MSG_WriteShort(msg, number)
					msg.allowoverflow = true
					writei32(globals, OFS_PARM0 * 4, sv.writeentitiestoclient_cliententitynumber or 0)
					buffer.writef32(globals, OFS_PARM1 * 4, sendflags)
					writei32(globals, GlobalOfs(prog, "self") * 4, number)
					prvm_edict.ExecuteProgram(prog, sendentity, "Null SendEntity\n")
					msg.allowoverflow = false
					local ret = buffer.readf32(globals, OFS_RETURN * 4)
					if ret == 0 then
						-- Send rejected by CSQC. This means we want to remove it.
						-- CSQC requests we remove this one.
						if band(readu8(scope, number), SCOPE_ASSUMED_EXISTING) ~= 0 then
							msg.cursize = oldcursize2
							msg.overflowed = false
							MSG_WriteShort(msg, bor(band(number, 0xFFFF), 0x8000))
							writeu8(
								scope,
								number,
								band(readu8(scope, number), bnot(bor(SCOPE_WANTSEND, SCOPE_ASSUMED_EXISTING)))
							)
							writeu32(csf, number * 4, 0)
							writeu16(db.entno, db.num * 2, number)
							writei32(db.sendflags, db.num * 4, -1)
							db.num += 1
							-- and take note that we have begun the svc_csqcentities
							-- section of the packet
							sectionstarted = true
							ENTITYSIZEPROFILING_END(msg, entityprofiling_startsize, number, 0)
							if msg.cursize + 17 >= maxsize then
								break
							end
						else
							-- Nothing to do. Just don't do it again.
							msg.cursize = oldcursize
							msg.overflowed = false
							writeu8(scope, number, band(readu8(scope, number), bnot(SCOPE_WANTSEND)))
							writeu32(csf, number * 4, 0)
						end
						number += 1
						continue
					elseif ret ~= 0 and msg.cursize + 2 <= maxsize then
						-- an update has been successfully written
						writeu32(csf, number * 4, 0)
						writeu16(db.entno, db.num * 2, number)
						writei32(db.sendflags, db.num * 4, sendflags)
						db.num += 1
						writeu8(scope, number, band(readu8(scope, number), bnot(SCOPE_WANTSEND)))
						writeu8(
							scope,
							number,
							bor(readu8(scope, number), bor(SCOPE_EXISTED_ONCE, SCOPE_ASSUMED_EXISTING))
						)
						-- and take note that we have begun the svc_csqcentities
						-- section of the packet
						sectionstarted = true
						ENTITYSIZEPROFILING_END(msg, entityprofiling_startsize, number, sendflags)
						if msg.cursize + 17 >= maxsize then
							break
						end
						number += 1
						continue
					end
				end
			end
			-- self.SendEntity returned false (or does not exist) or the
			-- update was too big for this packet - rollback the buffer to its
			-- state before the writes occurred, we'll try again next frame
			msg.cursize = oldcursize
			msg.overflowed = false
		end
		number += 1
	end
	if sectionstarted then
		-- write index 0 to end the update (0 is never used by real entities)
		MSG_WriteShort(msg, 0)
	end

	if db.num == 0 then
		-- if no single ent got added, remove the frame from the DB again, to allow
		-- for a larger history
		EntityFrameCSQC_DeallocFrame(client, framenum)
	end

	return sectionstarted
end

-- port: protocol.c Protocol_UpdateClientStats L622-634 @xonotic-v0.8.6 (stats: C element i at [i])
function protocol.Protocol_UpdateClientStats(stats: { [number]: number })
	local host_client = server.host_client
	Stats_ClientFields(host_client)
	local hs, hd = host_client.stats, host_client.statsdeltabits
	-- update the stats array and set deltabits for any changed stats
	for i = 0, MAX_CL_STATS - 1 do
		if hs[i] ~= stats[i] then
			hd[rshift(i, 3)] = bor(hd[rshift(i, 3)], lshift(1, band(i, 7)))
			hs[i] = stats[i]
		end
	end
end

-- only a few stats are within the 32 stat limit of Quake, and most of them
-- are sent every frame in svc_clientdata messages, so we only send the
-- remaining ones here
-- protocol.c sendquakestats L639-653
local sendquakestats = {
	-- quake did not send these secrets/monsters stats in this way, but doing so
	-- allows a mod to increase STAT_TOTALMONSTERS during the game, and ensures
	-- that STAT_SECRETS and STAT_MONSTERS are always correct (even if a client
	-- didn't receive an svc_foundsecret or svc_killedmonster), which may be most
	-- valuable if randomly seeking around in a demo
	STAT_TOTALSECRETS, -- never changes during game
	STAT_TOTALMONSTERS, -- changes in some mods
	STAT_SECRETS, -- this makes svc_foundsecret unnecessary
	STAT_MONSTERS, -- this makes svc_killedmonster unnecessary
	STAT_VIEWHEIGHT, -- sent just for FTEQW clients
	STAT_VIEWZOOM, -- this rarely changes
	-1,
}

-- port: protocol.c Protocol_WriteStatsReliable L655-698 @xonotic-v0.8.6
function protocol.Protocol_WriteStatsReliable()
	local host_client = server.host_client
	local sv = server.sv
	local i, j
	if not host_client.netconnection then
		return
	end
	Stats_ClientFields(host_client)
	local hs, hd = host_client.stats, host_client.statsdeltabits
	local m = host_client.netconnection.message
	-- detect changes in stats and write reliable messages
	-- this only deals with 32 stats because the older protocols which use
	-- this function can only cope with 32 stats,
	-- they also do not support svc_updatestatubyte which was introduced in
	-- DP6 protocol (except for QW)
	j = 0
	while sendquakestats[j + 1] >= 0 do
		i = sendquakestats[j + 1]
		-- check if this bit is set
		if band(hd[rshift(i, 3)], lshift(1, band(i, 7))) ~= 0 then
			hd[rshift(i, 3)] -= lshift(1, band(i, 7))
			-- send the stat as a byte if possible
			if sv.protocol == P.QUAKEWORLD then
				if hs[i] >= 0 and hs[i] < 256 then
					MSG_WriteByte(m, qw_svc_updatestat)
					MSG_WriteByte(m, i)
					MSG_WriteByte(m, hs[i])
				else
					MSG_WriteByte(m, qw_svc_updatestatlong)
					MSG_WriteByte(m, i)
					MSG_WriteLong(m, hs[i])
				end
			else
				-- this could make use of svc_updatestatubyte in DP6 and later
				-- protocols but those protocols do not use this function
				MSG_WriteByte(m, svc_updatestat)
				MSG_WriteByte(m, i)
				MSG_WriteLong(m, hs[i])
			end
		end
		j += 1
	end
end

-- port: protocol.c EntityFrameQuake_WriteFrame L701-869 @xonotic-v0.8.6 (NOT YET PORTED: pre-DP5 protocols)
function protocol.EntityFrameQuake_WriteFrame(
	_msg: common.SizeBuf,
	_maxsize: number,
	_numstates: number,
	_states: any
): boolean
	notPorted("EntityFrameQuake_WriteFrame (protocol.c, QUAKE / NEHAHRA protocols)")
	return false
end

-- port: protocol.c EntityState_DeltaBits L871-935 @xonotic-v0.8.6 (NOT YET PORTED: DP1-4 protocols)
function protocol.EntityState_DeltaBits(_o: entity_state_t, _n: entity_state_t): number
	notPorted("EntityState_DeltaBits (protocol.c, DP1-4 protocols)")
	return 0
end

-- port: protocol.c EntityState_WriteExtendBits L937-950 @xonotic-v0.8.6 (NOT YET PORTED: DP1-4 protocols)
function protocol.EntityState_WriteExtendBits(_msg: common.SizeBuf, _bits: number)
	notPorted("EntityState_WriteExtendBits (protocol.c, DP1-4 protocols)")
end

-- port: protocol.c EntityState_WriteFields L952-1048 @xonotic-v0.8.6 (NOT YET PORTED: DP1-4 protocols)
function protocol.EntityState_WriteFields(_ent: entity_state_t, _msg: common.SizeBuf, _bits: number)
	notPorted("EntityState_WriteFields (protocol.c, DP1-4 protocols)")
end

-- port: protocol.c EntityState_WriteUpdate L1050-1078 @xonotic-v0.8.6 (NOT YET PORTED: DP1-4 protocols)
function protocol.EntityState_WriteUpdate(_ent: entity_state_t, _msg: common.SizeBuf, _delta: entity_state_t)
	notPorted("EntityState_WriteUpdate (protocol.c, DP1-4 protocols)")
end

-- port: protocol.c EntityFrame_AllocDatabase L1244-1247 @xonotic-v0.8.6 (NOT YET PORTED: DP1-3 protocols)
function protocol.EntityFrame_AllocDatabase(_mempool: any): any
	notPorted("EntityFrame_AllocDatabase (protocol.c, DP1-3 protocols)")
	return nil
end

-- port: protocol.c EntityFrame_FreeDatabase L1250-1253 @xonotic-v0.8.6 (NOT YET PORTED: DP1-3 protocols)
function protocol.EntityFrame_FreeDatabase(_d: any)
	notPorted("EntityFrame_FreeDatabase (protocol.c, DP1-3 protocols)")
end

-- port: protocol.c EntityFrame_ClearDatabase L1256-1259 @xonotic-v0.8.6 (NOT YET PORTED: DP1-3 protocols)
function protocol.EntityFrame_ClearDatabase(_d: any)
	notPorted("EntityFrame_ClearDatabase (protocol.c, DP1-3 protocols)")
end

-- port: protocol.c EntityFrame_AckFrame L1262-1274 @xonotic-v0.8.6 (NOT YET PORTED: DP1-3 protocols)
function protocol.EntityFrame_AckFrame(_d: any, _frame: number)
	notPorted("EntityFrame_AckFrame (protocol.c, DP1-3 protocols)")
end

-- port: protocol.c EntityFrame_Clear L1277-1286 @xonotic-v0.8.6 (NOT YET PORTED: DP1-3 protocols)
function protocol.EntityFrame_Clear(_f: any, _eye: { number }?, _framenum: number)
	notPorted("EntityFrame_Clear (protocol.c, DP1-3 protocols)")
end

-- port: protocol.c EntityFrame_FetchFrame L1289-1306 @xonotic-v0.8.6 (NOT YET PORTED: DP1-3 protocols)
function protocol.EntityFrame_FetchFrame(_d: any, _framenum: number, _f: any)
	notPorted("EntityFrame_FetchFrame (protocol.c, DP1-3 protocols)")
end

-- port: protocol.c EntityFrame_AddFrame_Server L1361-1410 @xonotic-v0.8.6 (NOT YET PORTED: DP1-3 protocols)
function protocol.EntityFrame_AddFrame_Server(
	_d: any,
	_eye: { number },
	_framenum: number,
	_numentities: number,
	_entitydata: any
)
	notPorted("EntityFrame_AddFrame_Server (protocol.c, DP1-3 protocols)")
end

-- port: protocol.c EntityFrame_WriteFrame L1413-1480 @xonotic-v0.8.6 (NOT YET PORTED: DP1-3 protocols)
function protocol.EntityFrame_WriteFrame(
	_msg: common.SizeBuf,
	_maxsize: number,
	_d: any,
	_numstates: number,
	_states: any,
	_viewentnum: number
): boolean
	notPorted("EntityFrame_WriteFrame (protocol.c, DP1-3 protocols)")
	return false
end

-- port: protocol.c EntityFrame_MostRecentlyRecievedFrameNum L1611-1617 @xonotic-v0.8.6 (NOT YET PORTED: DP1-3)
function protocol.EntityFrame_MostRecentlyRecievedFrameNum(_d: any): number
	notPorted("EntityFrame_MostRecentlyRecievedFrameNum (protocol.c, DP1-3 protocols)")
	return -1
end

-- port: protocol.c EntityFrame4_AllocDatabase L1664-1671 @xonotic-v0.8.6 (NOT YET PORTED: DP4 protocol)
function protocol.EntityFrame4_AllocDatabase(_pool: any): any
	notPorted("EntityFrame4_AllocDatabase (protocol.c, DP4 protocol)")
	return nil
end

-- port: protocol.c EntityFrame4_FreeDatabase L1673-1682 @xonotic-v0.8.6 (NOT YET PORTED: DP4 protocol)
function protocol.EntityFrame4_FreeDatabase(_d: any)
	notPorted("EntityFrame4_FreeDatabase (protocol.c, DP4 protocol)")
end

-- port: protocol.c EntityFrame4_ResetDatabase L1684-1692 @xonotic-v0.8.6 (NOT YET PORTED: DP4 protocol)
function protocol.EntityFrame4_ResetDatabase(_d: any)
	notPorted("EntityFrame4_ResetDatabase (protocol.c, DP4 protocol)")
end

-- port: protocol.c EntityFrame4_AckFrame L1694-1754 @xonotic-v0.8.6 (NOT YET PORTED: DP4 protocol)
function protocol.EntityFrame4_AckFrame(_d: any, _framenum: number, _servermode: boolean): number
	notPorted("EntityFrame4_AckFrame (protocol.c, DP4 protocol)")
	return 0
end

-- port: protocol.c EntityFrame4_WriteFrame L1889-1992 @xonotic-v0.8.6 (NOT YET PORTED: DP4 protocol)
function protocol.EntityFrame4_WriteFrame(
	_msg: common.SizeBuf,
	_maxsize: number,
	_d: any,
	_numstates: number,
	_states: any
): boolean
	notPorted("EntityFrame4_WriteFrame (protocol.c, DP4 protocol)")
	return false
end

-- a zeroed entityframe5_packetlog_t
local function NewPacketLog(): any
	return {
		packetnumber = 0,
		numstates = 0,
		states = buffer.create(ENTITYFRAME5_MAXSTATES * 8),
		statsdeltabits = buffer.create(STATSBYTES),
	}
end

-- port: protocol.c EntityFrame5_AllocDatabase L1997-2006 @xonotic-v0.8.6
function protocol.EntityFrame5_AllocDatabase(_pool: any): any
	local d: any
	-- Mem_Alloc'd: everything zero
	d = {
		latestframenum = 0,
		viewentnum = 0,
		packetlog = table.create(ENTITYFRAME5_MAXPACKETLOGS),
		maxedicts = 0,
		deltabits = buffer.create(0),
		priorities = buffer.create(0),
		updateframenum = buffer.create(0),
		states = {},
		visiblebits = buffer.create(0),
		prioritychaincounts = buffer.create(ENTITYFRAME5_PRIORITYLEVELS * 4),
		prioritychains = buffer.create(ENTITYFRAME5_PRIORITYLEVELS * ENTITYFRAME5_MAXSTATES * 2),
	}
	for i = 1, ENTITYFRAME5_MAXPACKETLOGS do
		d.packetlog[i] = NewPacketLog()
	end
	d.latestframenum = 0
	for i = 0, d.maxedicts - 1 do
		EntityState_Copy(d.states[i + 1], defaultstate)
	end
	return d
end

-- port: protocol.c EntityFrame5_FreeDatabase L2008-2015 @xonotic-v0.8.6 (the memory is garbage collected)
function protocol.EntityFrame5_FreeDatabase(_d: any)
	-- all the [maxedicts] memory is allocated at once, so there's only one
	-- thing to free
end

-- port: protocol.c EntityFrame5_ExpandEdicts L2017-2046 @xonotic-v0.8.6
local function EntityFrame5_ExpandEdicts(d: any, newmax: number)
	if d.maxedicts < newmax then
		local oldmaxedicts = d.maxedicts
		local olddeltabits = d.deltabits
		local oldpriorities = d.priorities
		local oldupdateframenum = d.updateframenum
		local oldstates = d.states
		local oldvisiblebits = d.visiblebits
		d.maxedicts = newmax
		-- Mem_Alloc'd: zero (the states too, not defaultstate)
		d.deltabits = buffer.create(d.maxedicts * 4)
		d.priorities = buffer.create(d.maxedicts)
		d.updateframenum = buffer.create(d.maxedicts * 4)
		d.states = table.create(d.maxedicts)
		d.visiblebits = buffer.create((d.maxedicts + 7) // 8)
		if oldmaxedicts ~= 0 then
			buffer.copy(d.deltabits, 0, olddeltabits, 0, oldmaxedicts * 4)
			buffer.copy(d.priorities, 0, oldpriorities, 0, oldmaxedicts)
			buffer.copy(d.updateframenum, 0, oldupdateframenum, 0, oldmaxedicts * 4)
			for i = 1, oldmaxedicts do
				d.states[i] = oldstates[i]
			end
			buffer.copy(d.visiblebits, 0, oldvisiblebits, 0, (oldmaxedicts + 7) // 8)
			-- the previous buffers were a single allocation, so just one free
		end
		for i = oldmaxedicts + 1, d.maxedicts do
			d.states[i] = EntityState_New()
		end
	end
end
protocol.EntityFrame5_ExpandEdicts = EntityFrame5_ExpandEdicts

-- port: protocol.c EntityState5_Priority L2048-2089 @xonotic-v0.8.6
local function EntityState5_Priority(d: any, stateindex: number): number
	local limit, priority
	local s: any = nil -- hush compiler warning by initializing this
	local svs = host_cmd.svs :: any
	-- if it is the player, update urgently
	if stateindex == d.viewentnum then
		return ENTITYFRAME5_PRIORITYLEVELS - 1
	end
	-- priority increases each frame no matter what happens
	priority = readu8(d.priorities, stateindex) + 1
	-- players get an extra priority boost
	if stateindex <= svs.maxclients then
		priority += 1
	end
	-- remove dead entities very quickly because they are just 2 bytes
	if d.states[stateindex + 1].active ~= ACTIVE_NETWORK then
		priority += 1
		return if priority >= 1
			then (if priority < ENTITYFRAME5_PRIORITYLEVELS - 1 then priority else ENTITYFRAME5_PRIORITYLEVELS - 1)
			else 1
	end
	-- certain changes are more noticable than others
	if
		band(readu32(d.deltabits, stateindex * 4), E5_FULLUPDATE + E5_ATTACHMENT + E5_MODEL + E5_FLAGS + E5_COLORMAP)
		~= 0
	then
		priority += 1
	end
	-- find the root entity this one is attached to, and judge relevance by it
	limit = 0
	while limit < 256 do
		s = d.states[stateindex + 1]
		if band(s.flags, RENDER_VIEWMODEL) ~= 0 then
			stateindex = d.viewentnum
		elseif s.tagentity ~= 0 then
			stateindex = s.tagentity
		else
			break
		end
		if d.maxedicts < stateindex then
			EntityFrame5_ExpandEdicts(d, band(stateindex + 256, bnot(255)))
		end
		limit += 1
	end
	if limit >= 256 then
		Con_DPrintf("Protocol: Runaway loop recursing tagentity links on entity %d\n", stateindex)
	end
	-- now that we have the parent entity we can make some decisions based on
	-- distance from the player
	local a, b = d.states[d.viewentnum + 1].netcenter, s.netcenter
	local dx, dy, dz = R(a[1] - b[1]), R(a[2] - b[2]), R(a[3] - b[3])
	if math.sqrt(R(R(R(dx * dx) + R(dy * dy)) + R(dz * dz))) < 1024.0 then
		priority += 1
	end
	return if priority >= 1
		then (if priority < ENTITYFRAME5_PRIORITYLEVELS - 1 then priority else ENTITYFRAME5_PRIORITYLEVELS - 1)
		else 1
end
protocol.EntityState5_Priority = EntityState5_Priority

-- port: protocol.c anim_reducetime L2091-2104 @xonotic-v0.8.6
local function anim_reducetime(t: number, frameduration: number, maxtime: number): number
	if t < 0 then -- clamp to non-negative
		return 0
	end
	if t <= maxtime then -- time can be represented normally
		return t
	end
	if frameduration == 0 then -- don't like dividing by zero
		return t
	end
	if maxtime <= 2 * frameduration then -- if two frames don't fit, we better not do this
		return t
	end
	t -= frameduration * math.ceil((t - maxtime) / frameduration)
	-- now maxtime - frameduration < t <= maxtime
	return t
end

-- see VM_SV_frameduration
-- port: protocol.c anim_frameduration L2107-2114 @xonotic-v0.8.6
local function anim_frameduration(model: any, framenum: number): number
	if not model or not model.animscenes or framenum < 0 or framenum >= model.numframes then
		return 0
	end
	local sc = model.animscenes[framenum + 1]
	if sc.framerate ~= 0 then
		return R(sc.framecount / sc.framerate)
	end
	return 0
end

-- (int)(anim_reducetime(sv.time - fgb.start, anim_frameduration(model, fgb.frame), 65.535) * 1000.0)
local function animtime(model: any, fgb: framegroupblend_t): number
	return toint(anim_reducetime(server.sv.time - fgb.start, anim_frameduration(model, fgb.frame), 65.535) * 1000.0)
end

local pose7s = buffer.create(14) -- short pose7s[7]

-- port: protocol.c EntityState5_WriteUpdate L2116-2346 @xonotic-v0.8.6
function protocol.EntityState5_WriteUpdate(number: number, s: entity_state_t, changedbits: number, msg: common.SizeBuf)
	local prog: any = cvar.prvm_prog_list[0] -- SVVM_prog
	local svs = host_cmd.svs :: any
	local bits = 0
	--dp_model_t *model;

	if s.active ~= ACTIVE_NETWORK then
		local entityprofiling_startsize = msg.cursize
		MSG_WriteShort(msg, bor(number, 0x8000))
		ENTITYSIZEPROFILING_END(msg, entityprofiling_startsize, s.number, 0)
	else
		if SendEntityOf(prog, s.number) ~= 0 then
			return
		end

		bits = changedbits % 4294967296
		local o = s.origin
		if
			band(bits, E5_ORIGIN) ~= 0
			and (
				band(s.flags, RENDER_LOWPRECISION) == 0
				or s.exteriormodelforclient ~= 0
				or s.tagentity ~= 0
				or s.viewmodelforclient ~= 0
				or (s.number >= 1 and s.number <= svs.maxclients)
				or o[1] <= -4096.0625
				or o[1] >= 4095.9375
				or o[2] <= -4096.0625
				or o[2] >= 4095.9375
				or o[3] <= -4096.0625
				or o[3] >= 4095.9375
			)
		then
			-- maybe also add: ((model = SV_GetModelByIndex(s->modelindex)) != NULL && model->name[0] == '*')
			bits = bor(bits, E5_ORIGIN32)
		end
		-- possible values:
		--   negative origin:
		--     (int)(f * 8 - 0.5) >= -32768
		--          (f * 8 - 0.5) >  -32769
		--           f            >  -4096.0625
		--   positive origin:
		--     (int)(f * 8 + 0.5) <=  32767
		--          (f * 8 + 0.5) <   32768
		--           f * 8 + 0.5) <   4095.9375
		if band(bits, E5_ANGLES) ~= 0 and band(s.flags, RENDER_LOWPRECISION) == 0 then
			bits = bor(bits, E5_ANGLES16)
		end
		if band(bits, E5_MODEL) ~= 0 and s.modelindex >= 256 then
			bits = bor(bits, E5_MODEL16)
		end
		if band(bits, E5_FRAME) ~= 0 and s.frame >= 256 then
			bits = bor(bits, E5_FRAME16)
		end
		if band(bits, E5_EFFECTS) ~= 0 then
			if band(s.effects, 0xFFFF0000) ~= 0 then
				bits = bor(bits, E5_EFFECTS32)
			elseif band(s.effects, 0xFFFFFF00) ~= 0 then
				bits = bor(bits, E5_EFFECTS16)
			end
		end
		if bits >= 256 then
			bits = bor(bits, E5_EXTEND1)
		end
		if bits >= 65536 then
			bits = bor(bits, E5_EXTEND2)
		end
		if bits >= 16777216 then
			bits = bor(bits, E5_EXTEND3)
		end
		do
			local entityprofiling_startsize = msg.cursize
			MSG_WriteShort(msg, number)
			MSG_WriteByte(msg, band(bits, 0xFF))
			if band(bits, E5_EXTEND1) ~= 0 then
				MSG_WriteByte(msg, band(rshift(bits, 8), 0xFF))
			end
			if band(bits, E5_EXTEND2) ~= 0 then
				MSG_WriteByte(msg, band(rshift(bits, 16), 0xFF))
			end
			if band(bits, E5_EXTEND3) ~= 0 then
				MSG_WriteByte(msg, band(rshift(bits, 24), 0xFF))
			end
			if band(bits, E5_FLAGS) ~= 0 then
				MSG_WriteByte(msg, s.flags)
			end
			if band(bits, E5_ORIGIN) ~= 0 then
				if band(bits, E5_ORIGIN32) ~= 0 then
					MSG_WriteCoord32f(msg, o[1])
					MSG_WriteCoord32f(msg, o[2])
					MSG_WriteCoord32f(msg, o[3])
				else
					MSG_WriteCoord13i(msg, o[1])
					MSG_WriteCoord13i(msg, o[2])
					MSG_WriteCoord13i(msg, o[3])
				end
			end
			if band(bits, E5_ANGLES) ~= 0 then
				if band(bits, E5_ANGLES16) ~= 0 then
					MSG_WriteAngle16i(msg, s.angles[1])
					MSG_WriteAngle16i(msg, s.angles[2])
					MSG_WriteAngle16i(msg, s.angles[3])
				else
					MSG_WriteAngle8i(msg, s.angles[1])
					MSG_WriteAngle8i(msg, s.angles[2])
					MSG_WriteAngle8i(msg, s.angles[3])
				end
			end
			if band(bits, E5_MODEL) ~= 0 then
				if band(bits, E5_MODEL16) ~= 0 then
					MSG_WriteShort(msg, s.modelindex)
				else
					MSG_WriteByte(msg, s.modelindex)
				end
			end
			if band(bits, E5_FRAME) ~= 0 then
				if band(bits, E5_FRAME16) ~= 0 then
					MSG_WriteShort(msg, s.frame)
				else
					MSG_WriteByte(msg, s.frame)
				end
			end
			if band(bits, E5_SKIN) ~= 0 then
				MSG_WriteByte(msg, s.skin)
			end
			if band(bits, E5_EFFECTS) ~= 0 then
				if band(bits, E5_EFFECTS32) ~= 0 then
					MSG_WriteLong(msg, s.effects)
				elseif band(bits, E5_EFFECTS16) ~= 0 then
					MSG_WriteShort(msg, s.effects)
				else
					MSG_WriteByte(msg, s.effects)
				end
			end
			if band(bits, E5_ALPHA) ~= 0 then
				MSG_WriteByte(msg, s.alpha)
			end
			if band(bits, E5_SCALE) ~= 0 then
				MSG_WriteByte(msg, s.scale)
			end
			if band(bits, E5_COLORMAP) ~= 0 then
				MSG_WriteByte(msg, s.colormap)
			end
			if band(bits, E5_ATTACHMENT) ~= 0 then
				MSG_WriteShort(msg, s.tagentity)
				MSG_WriteByte(msg, s.tagindex)
			end
			if band(bits, E5_LIGHT) ~= 0 then
				MSG_WriteShort(msg, s.light[1])
				MSG_WriteShort(msg, s.light[2])
				MSG_WriteShort(msg, s.light[3])
				MSG_WriteShort(msg, s.light[4])
				MSG_WriteByte(msg, s.lightstyle)
				MSG_WriteByte(msg, s.lightpflags)
			end
			if band(bits, E5_GLOW) ~= 0 then
				MSG_WriteByte(msg, s.glowsize)
				MSG_WriteByte(msg, s.glowcolor)
			end
			if band(bits, E5_COLORMOD) ~= 0 then
				MSG_WriteByte(msg, s.colormod[1])
				MSG_WriteByte(msg, s.colormod[2])
				MSG_WriteByte(msg, s.colormod[3])
			end
			if band(bits, E5_GLOWMOD) ~= 0 then
				MSG_WriteByte(msg, s.glowmod[1])
				MSG_WriteByte(msg, s.glowmod[2])
				MSG_WriteByte(msg, s.glowmod[3])
			end
			if band(bits, E5_COMPLEXANIMATION) ~= 0 then
				local sk = s.skeletonobject
				if sk.model and sk.relativetransforms then
					local numbones = sk.model.num_bones
					MSG_WriteByte(msg, 4)
					MSG_WriteShort(msg, s.modelindex)
					MSG_WriteByte(msg, numbones)
					for bonenum = 0, numbones - 1 do
						matrixlib.Matrix4x4_ToBonePose7s(sk.relativetransforms[bonenum + 1], 64, pose7s, 0)
						MSG_WriteShort(msg, buffer.readi16(pose7s, 0))
						MSG_WriteShort(msg, buffer.readi16(pose7s, 2))
						MSG_WriteShort(msg, buffer.readi16(pose7s, 4))
						MSG_WriteShort(msg, buffer.readi16(pose7s, 6))
						MSG_WriteShort(msg, buffer.readi16(pose7s, 8))
						MSG_WriteShort(msg, buffer.readi16(pose7s, 10))
						MSG_WriteShort(msg, buffer.readi16(pose7s, 12))
					end
				else
					local model = SV_GetModelByIndex(s.modelindex)
					local fgb = s.framegroupblend
					if fgb[4].lerp > 0 then
						MSG_WriteByte(msg, 3)
						MSG_WriteShort(msg, fgb[1].frame)
						MSG_WriteShort(msg, fgb[2].frame)
						MSG_WriteShort(msg, fgb[3].frame)
						MSG_WriteShort(msg, fgb[4].frame)
						MSG_WriteShort(msg, animtime(model, fgb[1]))
						MSG_WriteShort(msg, animtime(model, fgb[2]))
						MSG_WriteShort(msg, animtime(model, fgb[3]))
						MSG_WriteShort(msg, animtime(model, fgb[4]))
						MSG_WriteByte(msg, toint(R(fgb[1].lerp * 255.0)))
						MSG_WriteByte(msg, toint(R(fgb[2].lerp * 255.0)))
						MSG_WriteByte(msg, toint(R(fgb[3].lerp * 255.0)))
						MSG_WriteByte(msg, toint(R(fgb[4].lerp * 255.0)))
					elseif fgb[3].lerp > 0 then
						MSG_WriteByte(msg, 2)
						MSG_WriteShort(msg, fgb[1].frame)
						MSG_WriteShort(msg, fgb[2].frame)
						MSG_WriteShort(msg, fgb[3].frame)
						MSG_WriteShort(msg, animtime(model, fgb[1]))
						MSG_WriteShort(msg, animtime(model, fgb[2]))
						MSG_WriteShort(msg, animtime(model, fgb[3]))
						MSG_WriteByte(msg, toint(R(fgb[1].lerp * 255.0)))
						MSG_WriteByte(msg, toint(R(fgb[2].lerp * 255.0)))
						MSG_WriteByte(msg, toint(R(fgb[3].lerp * 255.0)))
					elseif fgb[2].lerp > 0 then
						MSG_WriteByte(msg, 1)
						MSG_WriteShort(msg, fgb[1].frame)
						MSG_WriteShort(msg, fgb[2].frame)
						MSG_WriteShort(msg, animtime(model, fgb[1]))
						MSG_WriteShort(msg, animtime(model, fgb[2]))
						MSG_WriteByte(msg, toint(R(fgb[1].lerp * 255.0)))
						MSG_WriteByte(msg, toint(R(fgb[2].lerp * 255.0)))
					else
						MSG_WriteByte(msg, 0)
						MSG_WriteShort(msg, fgb[1].frame)
						MSG_WriteShort(msg, animtime(model, fgb[1]))
					end
				end
			end
			if band(bits, E5_TRAILEFFECTNUM) ~= 0 then
				MSG_WriteShort(msg, s.traileffectnum)
			end
			ENTITYSIZEPROFILING_END(msg, entityprofiling_startsize, s.number, s32(bits))
		end
	end
end
local EntityState5_WriteUpdate = protocol.EntityState5_WriteUpdate

-- memcmp helpers: the bytes of a float / double / int (bit patterns, so -0 ~= 0 and equal NaNs compare equal)
local cmpbuf = buffer.create(16)
local function sameF32(a: number, b: number): boolean
	return f32.tobits(a) == f32.tobits(b)
end
local function sameF64(a: number, b: number): boolean
	buffer.writef64(cmpbuf, 0, a)
	buffer.writef64(cmpbuf, 8, b)
	return readu32(cmpbuf, 0) == readu32(cmpbuf, 8) and readu32(cmpbuf, 4) == readu32(cmpbuf, 12)
end
-- memcmp(a, b, n * sizeof(matrix4x4_t)) ~= 0 (float m[4][4])
local function matricesDiffer(a: any, b: any, n: number): boolean
	for i = 1, n do
		local ma, mb = a[i].m, b[i].m
		for r = 1, 4 do
			for c = 1, 4 do
				if not sameF32(ma[r][c], mb[r][c]) then
					return true
				end
			end
		end
	end
	return false
end
-- memcmp(o->framegroupblend, n->framegroupblend, sizeof(o->framegroupblend)) ~= 0
local function framegroupblendsDiffer(a: { framegroupblend_t }, b: { framegroupblend_t }): boolean
	for i = 1, 4 do
		local x, y = a[i], b[i]
		if x.frame ~= y.frame or not sameF32(x.lerp, y.lerp) or not sameF64(x.start, y.start) then
			return true
		end
	end
	return false
end

-- port: protocol.c EntityState5_DeltaBits L2633-2697 @xonotic-v0.8.6 (the COMPLEXANIMATION branches are separate in C)
-- selene: allow(if_same_then_else)
local function EntityState5_DeltaBits(o: entity_state_t, n: entity_state_t): number
	local bits = 0
	if n.active == ACTIVE_NETWORK then
		if o.active ~= ACTIVE_NETWORK then
			bits = bor(bits, E5_FULLUPDATE)
		end
		if not (o.origin[1] == n.origin[1] and o.origin[2] == n.origin[2] and o.origin[3] == n.origin[3]) then
			bits = bor(bits, E5_ORIGIN)
		end
		if not (o.angles[1] == n.angles[1] and o.angles[2] == n.angles[2] and o.angles[3] == n.angles[3]) then
			bits = bor(bits, E5_ANGLES)
		end
		if o.modelindex ~= n.modelindex then
			bits = bor(bits, E5_MODEL)
		end
		if o.frame ~= n.frame then
			bits = bor(bits, E5_FRAME)
		end
		if o.skin ~= n.skin then
			bits = bor(bits, E5_SKIN)
		end
		if o.effects ~= n.effects then
			bits = bor(bits, E5_EFFECTS)
		end
		if o.flags ~= n.flags then
			bits = bor(bits, E5_FLAGS)
		end
		if o.alpha ~= n.alpha then
			bits = bor(bits, E5_ALPHA)
		end
		if o.scale ~= n.scale then
			bits = bor(bits, E5_SCALE)
		end
		if o.colormap ~= n.colormap then
			bits = bor(bits, E5_COLORMAP)
		end
		if o.tagentity ~= n.tagentity or o.tagindex ~= n.tagindex then
			bits = bor(bits, E5_ATTACHMENT)
		end
		if
			o.light[1] ~= n.light[1]
			or o.light[2] ~= n.light[2]
			or o.light[3] ~= n.light[3]
			or o.light[4] ~= n.light[4]
			or o.lightstyle ~= n.lightstyle
			or o.lightpflags ~= n.lightpflags
		then
			bits = bor(bits, E5_LIGHT)
		end
		if o.glowsize ~= n.glowsize or o.glowcolor ~= n.glowcolor then
			bits = bor(bits, E5_GLOW)
		end
		if o.colormod[1] ~= n.colormod[1] or o.colormod[2] ~= n.colormod[2] or o.colormod[3] ~= n.colormod[3] then
			bits = bor(bits, E5_COLORMOD)
		end
		if o.glowmod[1] ~= n.glowmod[1] or o.glowmod[2] ~= n.glowmod[2] or o.glowmod[3] ~= n.glowmod[3] then
			bits = bor(bits, E5_GLOWMOD)
		end
		if band(n.flags, RENDER_COMPLEXANIMATION) ~= 0 then
			local osk, nsk = o.skeletonobject, n.skeletonobject
			local ohas = (osk.model ~= nil and osk.relativetransforms ~= nil)
			local nhas = (nsk.model ~= nil and nsk.relativetransforms ~= nil)
			if ohas ~= nhas then
				bits = bor(bits, E5_COMPLEXANIMATION)
			elseif ohas then
				if o.modelindex ~= n.modelindex then
					bits = bor(bits, E5_COMPLEXANIMATION)
				elseif osk.model.num_bones ~= nsk.model.num_bones then
					bits = bor(bits, E5_COMPLEXANIMATION)
				elseif matricesDiffer(osk.relativetransforms, nsk.relativetransforms, osk.model.num_bones) then
					bits = bor(bits, E5_COMPLEXANIMATION)
				end
			elseif framegroupblendsDiffer(o.framegroupblend, n.framegroupblend) then
				bits = bor(bits, E5_COMPLEXANIMATION)
			end
		end
		if o.traileffectnum ~= n.traileffectnum then
			bits = bor(bits, E5_TRAILEFFECTNUM)
		end
	else
		if o.active == ACTIVE_NETWORK then
			bits = bor(bits, E5_FULLUPDATE)
		end
	end
	return s32(bits)
end
protocol.EntityState5_DeltaBits = EntityState5_DeltaBits

-- port: protocol.c packetlog5cmp L2758-2763 @xonotic-v0.8.6
local function packetlog5cmp(a: any, b: any): number
	return a.packetnumber - b.packetnumber
end
protocol.packetlog5cmp = packetlog5cmp

local lf_statsdeltabits = buffer.create(STATSBYTES) -- static unsigned char statsdeltabits[(MAX_CL_STATS+7)/8];
local lf_deltabits = buffer.create(MAX_EDICTS * 4) -- static int deltabits[MAX_EDICTS];
local lf_packetlogs = table.create(ENTITYFRAME5_MAXPACKETLOGS) -- entityframe5_packetlog_t *packetlogs[...]

-- port: protocol.c EntityFrame5_LostFrame L2765-2824 @xonotic-v0.8.6
local function EntityFrame5_LostFrame(d: any, framenum: number)
	local bits
	local s
	local p
	local statsdeltabits = lf_statsdeltabits
	local deltabits = lf_deltabits
	local packetlogs = lf_packetlogs
	local host_client = server.host_client

	for i = 0, ENTITYFRAME5_MAXPACKETLOGS - 1 do
		packetlogs[i + 1] = d.packetlog[i + 1]
	end
	-- engine quirk kept: C calls qsort(packetlogs, sizeof(*packetlogs), ENTITYFRAME5_MAXPACKETLOGS, packetlog5cmp)
	-- with the count and element size swapped: it sorts 8 "elements" of 64 bytes (the pointer array itself) by
	-- the low 32 bits of the pointers, which are already in ascending order, so the array is left as it is and
	-- the logs are walked in index order, not by packet number. packetlog5cmp is never applied to the logs.

	buffer.fill(deltabits, 0, 0)
	buffer.fill(statsdeltabits, 0, 0)
	for i = 0, ENTITYFRAME5_MAXPACKETLOGS - 1 do
		p = packetlogs[i + 1]

		if p.packetnumber == 0 then
			continue
		end

		if p.packetnumber <= framenum then
			s = p.states
			for j = 0, p.numstates - 1 do
				local sn = readu32(s, j * 8)
				writeu32(deltabits, sn * 4, bor(readu32(deltabits, sn * 4), readu32(s, j * 8 + 4)))
			end

			for l = 0, STATSBYTES - 1 do
				writeu8(statsdeltabits, l, bor(readu8(statsdeltabits, l), readu8(p.statsdeltabits, l)))
			end

			p.packetnumber = 0
		else
			s = p.states
			for j = 0, p.numstates - 1 do
				local sn = readu32(s, j * 8)
				writeu32(deltabits, sn * 4, band(readu32(deltabits, sn * 4), bnot(readu32(s, j * 8 + 4))))
			end
			for l = 0, STATSBYTES - 1 do
				writeu8(statsdeltabits, l, band(readu8(statsdeltabits, l), bnot(readu8(p.statsdeltabits, l))))
			end
		end
	end

	for i = 0, d.maxedicts - 1 do
		bits = band(readu32(deltabits, i * 4), bnot(readu32(d.deltabits, i * 4)))
		if bits ~= 0 then
			writeu32(d.deltabits, i * 4, bor(readu32(d.deltabits, i * 4), bits))
			-- if it was a very important update, set priority higher
			local pr = readu8(d.priorities, i)
			if band(bits, E5_FULLUPDATE + E5_ATTACHMENT + E5_MODEL + E5_COLORMAP) ~= 0 then
				writeu8(d.priorities, i, if pr > 4 then pr else 4)
			else
				writeu8(d.priorities, i, if pr > 1 then pr else 1)
			end
		end
	end

	Stats_ClientFields(host_client)
	local hd = host_client.statsdeltabits
	for l = 0, STATSBYTES - 1 do
		hd[l] = bor(hd[l], readu8(statsdeltabits, l))
		-- no need to mask out the already-set bits here, as we do not
		-- do that priorities stuff
	end
end
protocol.EntityFrame5_LostFrame = EntityFrame5_LostFrame

-- port: protocol.c EntityFrame5_AckFrame L2826-2833 @xonotic-v0.8.6
function protocol.EntityFrame5_AckFrame(d: any, framenum: number)
	-- scan for packets made obsolete by this ack and delete them
	for i = 1, ENTITYFRAME5_MAXPACKETLOGS do
		if d.packetlog[i].packetnumber <= framenum then
			d.packetlog[i].packetnumber = 0
		end
	end
end

-- CHECKPVSBIT / SETPVSBIT / CLEARPVSBIT (model_brush.h L723-725) on a byte buffer, b >= 0
local function CHECKPVSBIT(pvs: buffer, b: number): boolean
	return band(readu8(pvs, rshift(b, 3)), lshift(1, band(b, 7))) ~= 0
end
local function SETPVSBIT(pvs: buffer, b: number)
	writeu8(pvs, rshift(b, 3), bor(readu8(pvs, rshift(b, 3)), lshift(1, band(b, 7))))
end
local function CLEARPVSBIT(pvs: buffer, b: number)
	writeu8(pvs, rshift(b, 3), band(readu8(pvs, rshift(b, 3)), bnot(lshift(1, band(b, 7)))))
end

local wf_data = buffer.create(128) -- unsigned char data[128];
local wf_buf: common.SizeBuf = { data = wf_data, maxsize = 0, cursize = 0, allowoverflow = false, overflowed = false }

-- port: protocol.c EntityFrame5_WriteFrame L2835-3028 @xonotic-v0.8.6
-- states: the entity_state_t pointers, C element i at [i + 1]
function protocol.EntityFrame5_WriteFrame(
	msg: common.SizeBuf,
	maxsize: number,
	d: any,
	numstates: number,
	states: { entity_state_t },
	viewentnum: number,
	movesequence: number,
	need_empty: boolean
): boolean
	local prog: any = cvar.prvm_prog_list[0] -- SVVM_prog
	local sv = server.sv
	local host_client = server.host_client
	local n
	local num, l, framenum, packetlognumber, priority
	local buf = wf_buf
	local packetlog: any

	if prog.max_edicts > d.maxedicts then
		EntityFrame5_ExpandEdicts(d, prog.max_edicts)
	end

	framenum = d.latestframenum + 1
	d.viewentnum = viewentnum

	-- if packet log is full, mark all frames as lost, this will cause
	-- it to send the lost data again
	packetlognumber = 0
	while packetlognumber < ENTITYFRAME5_MAXPACKETLOGS do
		if d.packetlog[packetlognumber + 1].packetnumber == 0 then
			break
		end
		packetlognumber += 1
	end
	if packetlognumber == ENTITYFRAME5_MAXPACKETLOGS then
		Con_DPrintf("EntityFrame5_WriteFrame: packetlog overflow for a client, resetting\n")
		EntityFrame5_LostFrame(d, framenum)
		packetlognumber = 0
	end

	-- prepare the buffer
	buf.cursize, buf.allowoverflow, buf.overflowed = 0, false, false
	buf.data = wf_data
	buf.maxsize = 128

	-- detect changes in states
	num = 1
	for i = 0, numstates - 1 do
		n = states[i + 1]
		-- mark gaps in entity numbering as removed entities
		while num < n.number do
			-- if the entity used to exist, clear it
			if CHECKPVSBIT(d.visiblebits, num) then
				CLEARPVSBIT(d.visiblebits, num)
				writeu32(d.deltabits, num * 4, E5_FULLUPDATE)
				local pr = readu8(d.priorities, num)
				writeu8(d.priorities, num, if pr > 8 then pr else 8) -- removal is cheap
				EntityState_Copy(d.states[num + 1], defaultstate)
				d.states[num + 1].number = num
			end
			num += 1
		end
		-- update the entity state data
		if not CHECKPVSBIT(d.visiblebits, num) then
			-- entity just spawned in, don't let it completely hog priority
			-- because of being ancient on the first frame
			writei32(d.updateframenum, num * 4, framenum)
			-- initial priority is a bit high to make projectiles send on the
			-- first frame, among other things
			local pr = readu8(d.priorities, num)
			writeu8(d.priorities, num, if pr > 4 then pr else 4)
		end
		SETPVSBIT(d.visiblebits, num)
		writeu32(
			d.deltabits,
			num * 4,
			bor(readu32(d.deltabits, num * 4), EntityState5_DeltaBits(d.states[num + 1], n) % 4294967296)
		)
		local pr = readu8(d.priorities, num)
		writeu8(d.priorities, num, if pr > 1 then pr else 1)
		EntityState_Copy(d.states[num + 1], n)
		d.states[num + 1].number = num
		-- advance to next entity so the next iteration doesn't immediately remove it
		num += 1
	end
	-- all remaining entities are dead
	while num < d.maxedicts do
		if CHECKPVSBIT(d.visiblebits, num) then
			CLEARPVSBIT(d.visiblebits, num)
			writeu32(d.deltabits, num * 4, E5_FULLUPDATE)
			local pr = readu8(d.priorities, num)
			writeu8(d.priorities, num, if pr > 8 then pr else 8) -- removal is cheap
			EntityState_Copy(d.states[num + 1], defaultstate)
			d.states[num + 1].number = num
		end
		num += 1
	end

	-- if there isn't at least enough room for an empty svc_entities,
	-- don't bother trying...
	if buf.cursize + 11 > buf.maxsize then
		return false
	end

	-- build lists of entities by priority level
	local chaincounts, chains = d.prioritychaincounts, d.prioritychains
	buffer.fill(chaincounts, 0, 0)
	l = 0
	num = 0
	while num < d.maxedicts do
		if readu8(d.priorities, num) ~= 0 then
			if readu32(d.deltabits, num * 4) ~= 0 then
				if readu8(d.priorities, num) < (ENTITYFRAME5_PRIORITYLEVELS - 1) then
					-- (the call first: it can reallocate d->priorities through EntityFrame5_ExpandEdicts)
					local pv = EntityState5_Priority(d, num)
					writeu8(d.priorities, num, pv)
				end
				l = num
				priority = readu8(d.priorities, num)
				local c = readi32(chaincounts, priority * 4)
				if c < ENTITYFRAME5_MAXSTATES then
					writeu16(chains, (priority * ENTITYFRAME5_MAXSTATES + c) * 2, num)
					writei32(chaincounts, priority * 4, c + 1)
				end
			else
				writeu8(d.priorities, num, 0)
			end
		end
		num += 1
	end

	packetlog = nil
	-- write stat updates
	local protocolv = sv.protocol
	if
		protocolv ~= P.QUAKE
		and protocolv ~= P.QUAKEDP
		and protocolv ~= P.NEHAHRAMOVIE
		and protocolv ~= P.NEHAHRABJP
		and protocolv ~= P.NEHAHRABJP2
		and protocolv ~= P.NEHAHRABJP3
		and protocolv ~= P.DARKPLACES1
		and protocolv ~= P.DARKPLACES2
		and protocolv ~= P.DARKPLACES3
		and protocolv ~= P.DARKPLACES4
		and protocolv ~= P.DARKPLACES5
	then
		Stats_ClientFields(host_client)
		local hs, hd = host_client.stats, host_client.statsdeltabits
		local i = 0
		while i < MAX_CL_STATS and msg.cursize + 6 + 11 <= maxsize do
			if band(hd[rshift(i, 3)], lshift(1, band(i, 7))) ~= 0 then
				hd[rshift(i, 3)] = band(hd[rshift(i, 3)], bnot(lshift(1, band(i, 7))))
				-- add packetlog entry now that we have something for it
				if not packetlog then
					packetlog = d.packetlog[packetlognumber + 1]
					packetlog.packetnumber = framenum
					packetlog.numstates = 0
					buffer.fill(packetlog.statsdeltabits, 0, 0)
				end
				writeu8(
					packetlog.statsdeltabits,
					rshift(i, 3),
					bor(readu8(packetlog.statsdeltabits, rshift(i, 3)), lshift(1, band(i, 7)))
				)
				if hs[i] >= 0 and hs[i] < 256 then
					MSG_WriteByte(msg, svc_updatestatubyte)
					MSG_WriteByte(msg, i)
					MSG_WriteByte(msg, hs[i])
					l = 1
				else
					MSG_WriteByte(msg, svc_updatestat)
					MSG_WriteByte(msg, i)
					MSG_WriteLong(msg, hs[i])
					l = 1
				end
			end
			i += 1
		end
	end

	-- only send empty svc_entities frame if needed
	if l == 0 and not need_empty then
		return false
	end

	-- add packetlog entry now that we have something for it
	if not packetlog then
		packetlog = d.packetlog[packetlognumber + 1]
		packetlog.packetnumber = framenum
		packetlog.numstates = 0
		buffer.fill(packetlog.statsdeltabits, 0, 0)
	end

	-- write state updates
	if developer_networkentities_integer() >= 10 then
		Con_Printf("send: svc_entities %d\n", framenum)
	end
	d.latestframenum = framenum
	MSG_WriteByte(msg, svc_entities)
	MSG_WriteLong(msg, framenum)
	if
		protocolv ~= P.QUAKE
		and protocolv ~= P.QUAKEDP
		and protocolv ~= P.NEHAHRAMOVIE
		and protocolv ~= P.DARKPLACES1
		and protocolv ~= P.DARKPLACES2
		and protocolv ~= P.DARKPLACES3
		and protocolv ~= P.DARKPLACES4
		and protocolv ~= P.DARKPLACES5
		and protocolv ~= P.DARKPLACES6
	then
		MSG_WriteLong(msg, movesequence)
	end
	local pls = packetlog.states
	priority = ENTITYFRAME5_PRIORITYLEVELS - 1
	while priority >= 0 and packetlog.numstates < ENTITYFRAME5_MAXSTATES do
		local i = 0
		while i < readi32(chaincounts, priority * 4) and packetlog.numstates < ENTITYFRAME5_MAXSTATES do
			num = readu16(chains, (priority * ENTITYFRAME5_MAXSTATES + i) * 2)
			n = d.states[num + 1]
			if band(readu32(d.deltabits, num * 4), E5_FULLUPDATE) ~= 0 then
				writeu32(d.deltabits, num * 4, bor(E5_FULLUPDATE, EntityState5_DeltaBits(defaultstate, n) % 4294967296))
			end
			buf.cursize = 0
			EntityState5_WriteUpdate(num, n, s32(readu32(d.deltabits, num * 4)), buf)
			-- if the entity won't fit, try the next one
			if msg.cursize + buf.cursize + 2 > maxsize then
				i += 1
				continue
			end
			-- write entity to the packet
			common.SZ_Write(msg, buffer.readstring(buf.data, 0, buf.cursize))
			-- mark age on entity for prioritization
			writei32(d.updateframenum, num * 4, framenum)
			-- log entity so deltabits can be restored later if lost
			writeu32(pls, packetlog.numstates * 8, num)
			writeu32(pls, packetlog.numstates * 8 + 4, readu32(d.deltabits, num * 4))
			packetlog.numstates += 1
			-- clear deltabits and priority so it won't be sent again
			writeu32(d.deltabits, num * 4, 0)
			writeu8(d.priorities, num, 0)
			i += 1
		end
		priority -= 1
	end
	MSG_WriteShort(msg, 0x8000)

	return true
end

return protocol
