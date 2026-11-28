--!strict
-- The send side of engine/sv_main.luau (sv_main.c): SV_WriteClientdataToMessage and SV_SendServerinfo byte
-- layouts, SV_PrepareEntityForSending's entity_state_t, SV_CanSeeBox / SV_MarkWriteEntityStateToClient culling
-- decisions and SV_SendClientDatagram's keepalive / signon handling, on a synthetic server prog (field / global
-- offsets put straight into the FieldOfs / GlobalOfs caches) and a fake world model with one wall at x = 0.
-- The expectations are read from the C (sv_main.c, protocol.h, common.c); no C reference vectors yet.
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

local R = f32.round
local P = common.PROTOCOL

-- expected-message builders (little endian, as the MSG_ writers)
local function u8(v: number): string
	return string.char(v % 256)
end
local function i16(v: number): string
	return string.pack("<I2", v % 65536)
end
local function i32(v: number): string
	return string.pack("<I4", v % 4294967296)
end
local function fl(v: number): string
	return string.pack("<f", v)
end
local function str(s: string): string
	return s .. "\0"
end
-- MSG_WriteAngle16i (common.c L384-390)
local function a16(f: number): string
	local x = f * (65536.0 / 360.0)
	local v = if f >= 0 then math.floor(x + 0.5) else math.ceil(x - 0.5)
	return i16(bit32.band(v, 65535))
end

local function msgstring(m: any): string
	return buffer.readstring(m.data, 0, m.cursize)
end
-- byte compare with the first differing offset in the failure message
local function bytes(ctx: t.Ctx, got: string, want: string, what: string)
	if got == want then
		t.ok(ctx, true, what)
		return
	end
	local n = math.min(#got, #want)
	local at = n + 1
	for i = 1, n do
		if string.byte(got, i) ~= string.byte(want, i) then
			at = i
			break
		end
	end
	local function hex(s: string): string
		return (
			string.gsub(string.sub(s, math.max(1, at - 4), at + 12), ".", function(c)
				return string.format("%02x ", string.byte(c))
			end)
		)
	end
	t.ok(
		ctx,
		false,
		string.format(
			"%s: differs at byte %d (got %d bytes, want %d): got %s| want %s",
			what,
			at - 1,
			#got,
			#want,
			hex(got),
			hex(want)
		)
	)
end

return function(ctx: t.Ctx)
	local oldsink = console.sink
	console.sink = function(_l: string) end
	fs.SetProvider({
		files = {},
		load = function(_p: string): string?
			return nil
		end,
	})
	host.Host_Init_Dedicated({ maxclients = 2 })
	server.Clear()
	local svs = host_cmd.svs :: any
	local oldclients, oldmax = svs.clients, svs.maxclients
	svs.clients = {}
	svs.maxclients = 2
	local oldrealtime = prvm_edict.realtime
	prvm_edict.realtime = 10

	-- server prog: one slot per float, three per vector
	local FIELDS = {
		{ "origin", 3 },
		{ "angles", 3 },
		{ "mins", 3 },
		{ "maxs", 3 },
		{ "velocity", 3 },
		{ "punchangle", 3 },
		{ "punchvector", 3 },
		{ "view_ofs", 3 },
		{ "color", 3 },
		{ "colormod", 3 },
		{ "glowmod", 3 },
		{ "modelindex", 1 },
		{ "model", 1 },
		{ "effects", 1 },
		{ "flags", 1 },
		{ "waterlevel", 1 },
		{ "idealpitch", 1 },
		{ "fixangle", 1 },
		{ "dmg_take", 1 },
		{ "dmg_save", 1 },
		{ "dmg_inflictor", 1 },
		{ "items", 1 },
		{ "items2", 1 },
		{ "weaponmodel", 1 },
		{ "viewzoom", 1 },
		{ "gravity", 1 },
		{ "weaponframe", 1 },
		{ "armorvalue", 1 },
		{ "health", 1 },
		{ "currentammo", 1 },
		{ "ammo_shells", 1 },
		{ "ammo_nails", 1 },
		{ "ammo_rockets", 1 },
		{ "ammo_cells", 1 },
		{ "weapon", 1 },
		{ "message", 1 },
		{ "sounds", 1 },
		{ "glow_size", 1 },
		{ "alpha", 1 },
		{ "scale", 1 },
		{ "skin", 1 },
		{ "frame", 1 },
		{ "colormap", 1 },
		{ "fullbright", 1 },
		{ "nodrawtoclient", 1 },
		{ "drawonlytoclient", 1 },
		{ "viewmodelforclient", 1 },
		{ "tag_entity", 1 },
		{ "SendEntity", 1 },
		{ "SendFlags", 1 },
		{ "Version", 1 },
		{ "solid", 1 },
	}
	local GLOBALS = { { "self", 1 }, { "other", 1 }, { "time", 1 }, { "serverflags", 1 }, { "total_secrets", 1 } }
	local prog: any = prvm_edict.NewProg("server")
	prog.fieldofs_cache, prog.globalofs_cache = {}, {}
	local n = 0
	for _, f in FIELDS do
		prog.fieldofs_cache[f[1]] = n
		n += f[2]
	end
	prog.entityfields = n
	n = 28 -- after OFS_RETURN / parms
	for _, g in GLOBALS do
		prog.globalofs_cache[g[1]] = n
		n += g[2]
	end
	prog.numglobals = n
	prog.globals = buffer.create(n * 4)
	prog.max_edicts = 32
	prog.reserved_edicts = 0
	prog.limit_edicts = 512
	-- string table: 0 "", 1 "Tiny Map", 10 "progs/thing.md3"
	prog.strings = "\0Tiny Map\0progs/thing.md3\0"
	prog.stringssize = #prog.strings
	local S_MAP, S_THING = 1, 10
	prvm_edict.PRVM_MEM_Alloc(prog)
	prog.num_edicts = 16
	cvar.prvm_prog_list[0] = prog

	local function setF(e: number, f: string, v: number)
		buffer.writef32(prog.edictsfields, (e * prog.entityfields + prvm_edict.FieldOfs(prog, f)) * 4, v)
	end
	local function setI(e: number, f: string, v: number)
		buffer.writei32(prog.edictsfields, (e * prog.entityfields + prvm_edict.FieldOfs(prog, f)) * 4, v)
	end
	local function setV(e: number, f: string, x: number, y: number, z: number)
		local o = (e * prog.entityfields + prvm_edict.FieldOfs(prog, f)) * 4
		buffer.writef32(prog.edictsfields, o, x)
		buffer.writef32(prog.edictsfields, o + 4, y)
		buffer.writef32(prog.edictsfields, o + 8, z)
	end
	local function getF(e: number, f: string): number
		return buffer.readf32(prog.edictsfields, (e * prog.entityfields + prvm_edict.FieldOfs(prog, f)) * 4)
	end
	local function setGF(g: string, v: number)
		buffer.writef32(prog.globals, prog.globalofs_cache[g] * 4, v)
	end
	local function clearEdict(e: number)
		buffer.fill(prog.edictsfields, e * prog.entityfields * 4, 0, prog.entityfields * 4)
	end

	local sv = server.sv :: any
	sv.protocol = P.DARKPLACES7
	sv.time = 5.25
	sv.models = {}
	sv.model_precache = { [0] = "", [1] = "maps/tiny.bsp", [2] = "*1" }
	sv.sound_precache = { [0] = "", [1] = "misc/x.wav" }

	------------------------------------------------------------------------------------------------------------
	-- SV_WriteClientdataToMessage, DP7
	------------------------------------------------------------------------------------------------------------
	do
		local c = sv_main.client(0)
		c.active = true
		c.edict = 1
		server.host_client = c
		local ent = 1
		clearEdict(ent)
		setF(ent, "flags", 512) -- FL_ONGROUND
		setV(ent, "velocity", 100, -50, 0)
		setV(ent, "punchangle", 0, 2.5, 0)
		setV(ent, "punchvector", 0, 0, 1)
		setV(ent, "angles", 10, 20, 30)
		setF(ent, "fixangle", 1)
		setF(ent, "dmg_take", 5)
		setF(ent, "dmg_save", 3)
		setI(ent, "dmg_inflictor", 2)
		setF(ent, "health", 100)
		setF(ent, "items", 1)
		setF(ent, "items2", 2)
		setGF("serverflags", 1)
		setV(ent, "view_ofs", 0, 0, 35.5)
		clearEdict(2)
		setV(2, "origin", 8, 16, 32)
		setV(2, "mins", -16, -16, -24)
		setV(2, "maxs", 16, 16, 32)

		local msg = common.SZ_New(1400)
		local stats: { [number]: number } = {}
		sv_main.SV_WriteClientdataToMessage(c, ent, msg, stats)

		-- bits: SU_ONGROUND | SU_PUNCH2 | SU_PUNCHVEC3 | SU_VELOCITY1 | SU_VELOCITY2, >= 65536 so | SU_EXTEND1
		local bits = 1024 + 8 + 262144 + 32 + 64 + 32768
		local want = u8(19)
			.. u8(3)
			.. u8(5)
			.. fl(8)
			.. fl(16)
			.. fl(36) -- origin + 0.5 * (mins + maxs)
			.. u8(10)
			.. a16(10)
			.. a16(20)
			.. a16(30) -- svc_setangle (DP7: 16 bit angles)
			.. u8(15)
			.. i16(bits)
			.. u8(bit32.rshift(bits, 16))
			.. fl(100) -- velocity[0] (DP7: 32 bit floats)
			.. a16(2.5) -- punchangle[1]
			.. fl(-50) -- velocity[1]
			.. fl(1) -- punchvector[2]
		bytes(ctx, msgstring(msg), want, "SV_WriteClientdataToMessage DP7: damage, setangle, clientdata")
		t.eq(ctx, getF(ent, "dmg_take"), 0, "dmg_take cleared")
		t.eq(ctx, getF(ent, "dmg_save"), 0, "dmg_save cleared")
		t.eq(ctx, getF(ent, "fixangle"), 0, "fixangle cleared")
		t.eq(ctx, c.fixangle_angles_set, false, "fixangle_angles_set cleared after sending")
		-- stats is a 0-based table of ints; statsf entries hold the bits of the float
		local scratch = buffer.create(4)
		local function statsf(i: number): number
			buffer.writei32(scratch, 0, stats[i])
			return buffer.readf32(scratch, 0)
		end
		t.eq(ctx, stats[0], 100, "stats[STAT_HEALTH]")
		t.eq(ctx, stats[16], 35, "stats[STAT_VIEWHEIGHT] = (int)view_ofs[2]")
		t.eq(ctx, stats[15], 1 + bit32.lshift(2, 23) + bit32.lshift(1, 28), "stats[STAT_ITEMS]")
		t.eq(ctx, stats[21], 255, "stats[STAT_VIEWZOOM] = 255 for viewzoom 0")
		t.ok(
			ctx,
			stats[225] < 0 and bit32.band(stats[225], 0x80000000) ~= 0,
			"stats[STAT_MOVEFLAGS] has MOVEFLAG_VALID (int)"
		)
		t.eq(ctx, statsf(240), R(host.cv.sys_ticrate.value), "statsf[STAT_MOVEVARS_TICRATE] = sys_ticrate")
		t.eq(ctx, statsf(249), 1, "statsf[STAT_MOVEVARS_ENTGRAVITY] = 1 for gravity 0")
		t.eq(ctx, statsf(242), R(host.cv.sv_gravity.value), "statsf[STAT_MOVEVARS_GRAVITY]")
		t.eq(ctx, stats[1], 0, "stats[1] stays 0")

		-- DP5: the old-protocol block (items, armor, weapon, the short ammo counts, viewzoom)
		sv.protocol = P.DARKPLACES5
		clearEdict(ent)
		setV(ent, "view_ofs", 0, 0, 22) -- DEFAULT_VIEWHEIGHT: no SU_VIEWHEIGHT
		setF(ent, "armorvalue", 50)
		setF(ent, "health", 100)
		setF(ent, "currentammo", 7)
		setF(ent, "ammo_shells", 1)
		setF(ent, "ammo_nails", 2)
		setF(ent, "ammo_rockets", 3)
		setF(ent, "ammo_cells", 4)
		setF(ent, "weapon", 8)
		setF(ent, "viewzoom", 0.5) -- (int)(0.5 * 255) = 127
		setGF("serverflags", 0)
		common.SZ_Clear(msg)
		sv_main.SV_WriteClientdataToMessage(c, ent, msg, stats)
		bits = 512 + 8192 + 16384 + 524288 + 32768 -- ITEMS | ARMOR | WEAPON | VIEWZOOM | EXTEND1
		want = u8(15)
			.. i16(bits)
			.. u8(bit32.rshift(bits, 16))
			.. i32(0) -- items
			.. i16(50) -- armor
			.. i16(0) -- weapon (weaponmodelindex)
			.. i16(100)
			.. i16(7)
			.. i16(1)
			.. i16(2)
			.. i16(3)
			.. i16(4)
			.. i16(8)
			.. i16(127)
		bytes(ctx, msgstring(msg), want, "SV_WriteClientdataToMessage DP5: clientdata with items / ammo / viewzoom")
		sv.protocol = P.DARKPLACES7
	end

	------------------------------------------------------------------------------------------------------------
	-- SV_SendServerinfo
	------------------------------------------------------------------------------------------------------------
	do
		local c = sv_main.client(1)
		c.active = true
		c.netconnection = { message = common.SZ_New(65536), address = "test", cleartime = 0, timeout = 0 }
		c.netconnection.message.allowoverflow = true
		prog.filecrc = 1234
		setI(0, "message", S_MAP)
		setF(0, "sounds", 3)
		cvar.Cvar_SetValue("deathmatch", 1)
		cvar.Cvar_SetValue("coop", 0)
		local savehost = server.host_client
		sv_main.SV_SendServerinfo(c)
		t.eq(ctx, server.host_client, savehost, "host_client restored around Curl_SendRequirements")
		local tail = u8(11)
			.. i32(3504) -- Protocol_NumberForEnum(PROTOCOL_DARKPLACES7)
			.. u8(2) -- svs.maxclients
			.. u8(1) -- GAME_DEATHMATCH
			.. str("Tiny Map")
			.. str("maps/tiny.bsp")
			.. str("*1")
			.. u8(0)
			.. str("misc/x.wav")
			.. u8(0)
			.. u8(32)
			.. u8(3)
			.. u8(3) -- svc_cdtrack, (int)sounds twice
			.. u8(5)
			.. i16(2) -- svc_setview clientcamera = edict 2
			.. u8(25)
			.. u8(1) -- svc_signonnum 1
		local head = u8(8) .. str("\nServer: Xonotic build - (progs 1234 crc)\n")
		local download = u8(9) .. str("cl_serverextension_download 2\n") .. u8(9) .. str("") -- + Curl_SendRequirements
		bytes(ctx, msgstring(c.netconnection.message), head .. download .. tail, "SV_SendServerinfo without csqc")
		t.eq(ctx, c.edict, 2, "client edict = slot + 1")
		t.eq(ctx, c.clientcamera, 2, "clientcamera = client edict")
		t.eq(ctx, c.sendsignon, 1, "sendsignon 1")
		t.eq(ctx, c.prespawned or c.spawned or c.begun, false, "prespawned / spawned / begun cleared")
		t.eq(ctx, buffer.readu32(c.csqcentitysendflags, 5 * 4), 0xFFFFFF, "csqcentitysendflags reset to 0xFFFFFF")
		t.eq(ctx, buffer.readu8(c.csqcentityscope, 5), 0, "csqcentityscope reset to 0")
		t.eq(ctx, c.stats[0], 0, "client stats cleared")
		t.eq(ctx, c.csqcentityframehistory[1].framenum, -1, "csqcentityframehistory[0].framenum = -1")
		t.eq(
			ctx,
			c.netconnection.timeout,
			10 + host.cv.net_connecttimeout.value,
			"timeout = realtime + net_connecttimeout"
		)

		-- with csqc progs: the three csqc stufftexts and the SV_InitCmd line come right after the print
		sv.csqc_progname = "csprogs.dat"
		sv.csqc_progsize = 1000
		sv.csqc_progcrc = 4321
		sv_main.SV_SendServerinfo(c)
		local csqc = u8(9)
			.. str("csqc_progname csprogs.dat\n")
			.. u8(9)
			.. str("csqc_progsize 1000\n")
			.. u8(9)
			.. str("csqc_progcrc 4321\n")
			.. u8(9)
			.. str("\n") -- SV_InitCmd is "" (PRVM_GetString never returns NULL)
		bytes(ctx, msgstring(c.netconnection.message), head .. csqc .. download .. tail, "SV_SendServerinfo with csqc")
		sv.csqc_progname = ""
	end

	------------------------------------------------------------------------------------------------------------
	-- SV_PrepareEntityForSending
	------------------------------------------------------------------------------------------------------------
	local thing = {
		type = "mod_alias",
		name = "progs/thing.md3",
		effects = 0,
		normalmins = { -16, -16, -16 },
		normalmaxs = { 16, 16, 16 },
		yawmins = { -20, -20, -16 },
		yawmaxs = { 20, 20, 16 },
		rotatedmins = { -24, -24, -24 },
		rotatedmaxs = { 24, 24, 24 },
	}
	sv.models[2] = thing
	local function thingAt(e: number, x: number, y: number, z: number)
		clearEdict(e)
		prog.ed_free[e] = false
		setV(e, "origin", x, y, z)
		setF(e, "modelindex", 2)
		setI(e, "model", S_THING)
	end
	do
		local cs = protocol.EntityState_New()
		thingAt(5, 100, 0, 0)
		setF(5, "alpha", 0.5)
		setF(5, "scale", 2)
		setV(5, "colormod", 1, 0.5, 0)
		setF(5, "skin", 257)
		setF(5, "frame", 300.7)
		setF(5, "colormap", 1025)
		setF(5, "fullbright", 1)
		setF(5, "glow_size", 40)
		t.ok(ctx, sv_main.SV_PrepareEntityForSending(5, cs, 5), "entity with a model is prepared")
		t.eq(ctx, cs.active, 1, "active = ACTIVE_NETWORK")
		t.eq(ctx, cs.number, 5, "number")
		t.eq(ctx, cs.modelindex, 2, "modelindex")
		t.eq(ctx, cs.alpha, 127, "alpha = (int)(0.5 * 255)")
		t.eq(ctx, cs.scale, 32, "scale = 2 * 16")
		t.eq(ctx, cs.colormod[1], 32, "colormod[0]")
		t.eq(ctx, cs.colormod[2], 16, "colormod[1]")
		t.eq(ctx, cs.colormod[3], 0, "colormod[2]")
		t.eq(ctx, cs.glowmod[1], 32, "glowmod stays defaultstate 32")
		t.eq(ctx, cs.skin, 1, "skin: (unsigned char) of 257")
		t.eq(ctx, cs.frame, 300, "frame: (unsigned short) of 300.7")
		t.eq(ctx, cs.colormap, 1, "colormap: (unsigned char) of 1025")
		t.eq(ctx, bit32.band(cs.flags, 32), 32, "RENDER_COLORMAPPED for colormap >= 1024")
		t.eq(ctx, bit32.band(cs.effects, 512), 512, "EF_FULLBRIGHT from .fullbright")
		t.eq(ctx, cs.glowsize, 10, "glowsize = glow_size / 4")
		t.eq(ctx, cs.specialvisibilityradius, 40, "specialvisibilityradius = glowsize * 4")
		t.eq(ctx, cs.glowcolor, 254, "glowcolor default 254")
		-- cull box: normal box scaled by 2, then widened by specialvisibilityradius 40
		local mins, maxs = sv_main.edcull(prog, 5)
		t.eq(ctx, mins[1], 60, "cullmins x = min(100 - 32, 100 - 40)")
		t.eq(ctx, maxs[1], 140, "cullmaxs x = max(100 + 32, 100 + 40)")
		t.eq(ctx, mins[3], -40, "cullmins z")
		t.eq(ctx, cs.netcenter[1], 100, "netcenter x")

		-- yaw: the yaw box
		thingAt(6, 0, 0, 0)
		setV(6, "angles", 0, 45, 0)
		sv_main.SV_PrepareEntityForSending(6, cs, 6)
		mins = sv_main.edcull(prog, 6)
		t.eq(ctx, mins[1], -20, "yawed entity uses yawmins")
		setV(6, "angles", 10, 45, 0)
		sv_main.SV_PrepareEntityForSending(6, cs, 6)
		mins = sv_main.edcull(prog, 6)
		t.eq(ctx, mins[1], -24, "pitched entity uses rotatedmins")

		-- early outs
		clearEdict(7)
		setV(7, "origin", 0 / 0, 0, 0)
		setF(7, "modelindex", 2)
		setI(7, "model", S_THING)
		t.eq(ctx, sv_main.SV_PrepareEntityForSending(7, cs, 7), false, "NaN origin is not sent")
		clearEdict(7)
		t.eq(ctx, sv_main.SV_PrepareEntityForSending(7, cs, 7), false, "no model, no effects, not a client: not sent")
		t.eq(
			ctx,
			sv_main.SV_PrepareEntityForSending(7, cs, 2),
			true,
			"an empty client entity (number <= maxclients) is sent"
		)
		setF(7, "modelindex", 2) -- model string 0: modelindex 0
		t.eq(ctx, sv_main.SV_PrepareEntityForSending(7, cs, 7), false, "modelindex without a model string is 0")

		-- csqc entity: SendFlags move into every client's csqcentitysendflags, legacy Version quirk
		thingAt(8, 0, 0, 0)
		setI(8, "SendEntity", 7)
		setF(8, "SendFlags", 5)
		-- csqcentitysendflags: buffer of u32 (protocol.luau's representation; client 0 gets it on first use)
		local function csf(ci: number): number
			local b = sv_main.client(ci).csqcentitysendflags
			return if b then buffer.readu32(b, 8 * 4) else 0
		end
		local function csfclear(ci: number)
			local b = sv_main.client(ci).csqcentitysendflags
			if b then
				buffer.writeu32(b, 8 * 4, 0)
			end
		end
		csfclear(0)
		csfclear(1)
		sv_main.SV_PrepareEntityForSending(8, cs, 8)
		t.eq(ctx, cs.active, 2, "SendEntity: active = ACTIVE_SHARED")
		t.eq(ctx, getF(8, "SendFlags"), 0, "SendFlags cleared")
		t.eq(ctx, csf(0), 5, "client 0 csqcentitysendflags |= SendFlags")
		t.eq(ctx, csf(1), 5, "client 1 csqcentitysendflags |= SendFlags")
		setF(8, "Version", 300)
		sv_main.SV_PrepareEntityForSending(8, cs, 8)
		t.eq(ctx, sv.csqcentityversion[8], 44, "csqcentityversion is an unsigned char (300 -> 44)")
		csfclear(0)
		sv_main.SV_PrepareEntityForSending(8, cs, 8)
		t.eq(
			ctx,
			csf(0),
			0xFFFFFF,
			"Version over 255 never matches the stored byte: full resend every frame (engine quirk)"
		)
	end

	------------------------------------------------------------------------------------------------------------
	-- SV_CanSeeBox / SV_MarkWriteEntityStateToClient on a map with one wall at x = 0
	------------------------------------------------------------------------------------------------------------
	do
		sv.worldmodel = {
			name = "maps/tiny.bsp",
			brush = {
				-- a line of sight is blocked when it crosses x = 0
				TraceLineOfSight = function(_m: any, s: { number }, e: { number }, _amins: any, _amaxs: any): boolean
					return (s[1] < 0) == (e[1] < 0)
				end,
			},
		}
		cvar.Cvar_SetValue("sv_cullentities_trace_entityocclusion", 0)
		cvar.Cvar_SetValue("sv_cullentities_trace", 1)
		cvar.Cvar_SetValue("sv_cullentities_trace_samples", 4)
		cvar.Cvar_SetValue("sv_cullentities_trace_samples_players", 4)
		cvar.Cvar_SetValue("sv_cullentities_trace_delay", 1)
		cvar.Cvar_SetValue("sv_cullentities_trace_delay_players", 1)
		cvar.Cvar_SetValue("sv_cullentities_nevercullbmodels", 0)
		local eye = { -100, 0, 0 }
		t.eq(
			ctx,
			sv_main.SV_CanSeeBox(4, 1, 0.1, eye, { 84, -16, -16 }, { 116, 16, 16 }),
			false,
			"CanSeeBox through the wall: false"
		)
		t.eq(
			ctx,
			sv_main.SV_CanSeeBox(4, 1, 0.1, eye, { -66, -16, -16 }, { -34, 16, 16 }),
			true,
			"CanSeeBox same side: true"
		)
		t.eq(
			ctx,
			sv_main.SV_CanSeeBox(0, 1, 0.1, eye, { -66, -16, -16 }, { -34, 16, 16 }),
			false,
			"CanSeeBox with 0 traces: false"
		)

		-- the client (entity 1) looks from x = -100; entities prepared, then marked
		thingAt(1, -100, 0, 0)
		thingAt(3, 100, 0, 0) -- behind the wall
		thingAt(4, -50, 0, 0) -- same side
		thingAt(9, 100, 0, 0) -- behind the wall, nodrawtoclient = 1 (rejected before any trace)
		setI(9, "nodrawtoclient", 1)
		thingAt(10, -50, 0, 0) -- EF_NODRAW
		setF(10, "effects", 16)
		thingAt(11, 100, 0, 0) -- behind the wall, viewmodel of the client: no visibility check
		setI(11, "viewmodelforclient", 1)
		thingAt(12, 100, 0, 0) -- behind the wall, tagged to entity 4 (visible)
		setI(12, "tag_entity", 4)
		thingAt(13, -50, 0, 0) -- same side, tagged to entity 3 (culled)
		setI(13, "tag_entity", 3)
		thingAt(14, -50, 0, 0) -- same side, drawonlytoclient another client
		setI(14, "drawonlytoclient", 2)
		thingAt(2, 100, 0, 0) -- the other player, behind the wall
		prog.num_edicts = 15
		prog.ed_free[7], prog.ed_free[5], prog.ed_free[6], prog.ed_free[8] = true, true, true, true
		sv.writeentitiestoclient_cliententitynumber = 1
		sv_main.SV_PrepareEntitiesForSending()
		t.eq(ctx, sv.numsendentities, 10, "SV_PrepareEntitiesForSending: 10 entities (1-4, 9-14)")

		local function markframe(): { [number]: boolean }
			sv.writeentitiestoclient_clientnumber = 0
			sv.writeentitiestoclient_numeyes = 1
			sv.writeentitiestoclient_eyes[1][1], sv.writeentitiestoclient_eyes[1][2], sv.writeentitiestoclient_eyes[1][3] =
				eye[1], eye[2], eye[3]
			sv.writeentitiestoclient_pvsbytes = 0
			sv.writeentitiestoclient_stats_culled_trace = 0
			sv.writeentitiestoclient_stats_visibleentities = 0
			sv.writeentitiestoclient_stats_totalentities = 0
			sv.sententitiesmark += 1
			for i = 1, sv.numsendentities do
				sv_main.SV_MarkWriteEntityStateToClient(sv.sendentities[i])
			end
			local marked = {}
			for e = 1, 14 do
				marked[e] = sv.sententities[e] == sv.sententitiesmark
			end
			return marked
		end
		local m = markframe()
		t.eq(ctx, m[1], true, "the client's own entity is never rejected")
		t.eq(ctx, m[2], false, "other player behind the wall: culled by trace")
		t.eq(ctx, m[3], false, "entity behind the wall: culled by trace")
		t.eq(ctx, m[4], true, "entity on the same side: sent")
		t.eq(ctx, m[9], false, "nodrawtoclient = client: not sent")
		t.eq(ctx, m[10], false, "EF_NODRAW: not sent")
		t.eq(ctx, m[11], true, "viewmodelforclient = client: sent without a visibility check")
		t.eq(ctx, m[12], true, "tagged to a visible parent: sent")
		t.eq(ctx, m[13], false, "tagged to a culled parent: not sent")
		t.eq(ctx, m[14], false, "drawonlytoclient another client: not sent")
		t.eq(ctx, sv.writeentitiestoclient_stats_culled_trace, 2, "culled_trace counts entities 2 and 3")
		t.eq(ctx, sv.writeentitiestoclient_stats_visibleentities, 4, "visibleentities")
		t.eq(ctx, sv.writeentitiestoclient_stats_totalentities, 10, "totalentities (each considered once)")
		local vt = sv_main.client(0).visibletime
		t.eq(ctx, vt[4], R(10 + 1), "visibletime of a seen entity = (float)(realtime + delay)")

		-- the seen entity moves behind the wall: kept for sv_cullentities_trace_delay, then culled
		setV(4, "origin", 100, 0, 0)
		sv_main.SV_PrepareEntitiesForSending()
		prvm_edict.realtime = 10.5
		m = markframe()
		t.eq(ctx, m[4], true, "hidden for less than the trace delay: still sent")
		prvm_edict.realtime = 12
		m = markframe()
		t.eq(ctx, m[4], false, "hidden longer than the trace delay: culled")
		t.eq(ctx, m[12], false, "its tagged child goes with it")
		prvm_edict.realtime = 10
	end

	------------------------------------------------------------------------------------------------------------
	-- SV_SendClientDatagram (through SV_SendClientMessages): keepalive phase of a connecting client
	------------------------------------------------------------------------------------------------------------
	do
		local sent: { { msg: string, suppress: boolean } } = {}
		sv_main.netconn = {
			NetConn_CanSend = function(_conn: any): boolean
				return true
			end,
			NetConn_SendUnreliableMessage = function(
				_conn: any,
				m: any,
				_protocol: number,
				_rate: number,
				_burst: number,
				suppress: boolean
			): number
				table.insert(sent, { msg = buffer.readstring(m.data, 0, m.cursize), suppress = suppress })
				return 0
			end,
		}
		sv_main.lhnet = {
			LHNETADDRESS_GetAddressType = function(_a: any): number
				return 2 -- LHNETADDRESSTYPE_INET4
			end,
		}
		local c = sv_main.client(1)
		c.begun = false
		c.rate = 20000
		c.keepalivetime = 0
		c.sendsignon = 1
		common.SZ_Clear(c.netconnection.message) -- (the reliable message went out)
		sv_main.client(0).active = false
		prvm_edict.realtime = 10
		sv_main.SV_SendClientMessages()
		t.eq(ctx, #sent, 1, "one datagram for the connected client")
		t.eq(ctx, sent[1] and sent[1].msg, u8(1), "keepalive datagram is svc_nop")
		t.eq(ctx, sent[1] and sent[1].suppress, false, "reliables not suppressed while sendsignon was 1")
		t.eq(ctx, c.keepalivetime, 15, "keepalivetime = realtime + 5")
		t.eq(ctx, c.sendsignon, 2, "sendsignon 1 -> 2 once the reliable message is empty")
		prvm_edict.realtime = 11
		sv_main.SV_SendClientMessages()
		t.eq(ctx, sent[2] and sent[2].msg, "", "no keepalive before keepalivetime: empty datagram")
		t.eq(ctx, sent[2] and sent[2].suppress, true, "sendsignon 2 suppresses reliables")
		sv_main.netconn = nil
		sv_main.lhnet = nil
	end

	-- restore
	sv_main.client(1).netconnection = nil
	svs.clients, svs.maxclients = oldclients, oldmax
	server.Clear()
	server.host_client = nil
	prvm_edict.realtime = oldrealtime
	fs.SetProvider(nil)
	console.sink = oldsink
end
