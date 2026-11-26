--!strict
-- engine/sv_phys.luau movers (SV_CheckVelocity .. SV_Physics, SV_Trace_Toss) on a synthetic server prog (field /
-- global offsets put straight into the FieldOfs / GlobalOfs caches), a floor-slab world and box bmodels.
-- Expected values are derived from the C formulas with the same float rounding (traces the movers make are
-- recomputed with SV_TraceBox, which tests/unit/sv_phys.test.luau covers). Not a differential test against
-- the C build: there are no C vectors yet.
local t = require("../_lib/t")
local collision = require("../../engine/collision")
local console = require("../../engine/console")
local cvar = require("../../engine/cvar")
local f32 = require("../../engine/_port/f32")
local host_cmd = require("../../engine/host_cmd")
local mathlib = require("../../engine/mathlib")
local prvm_edict = require("../../engine/prvm_edict")
local server = require("../../engine/server")
local sv_phys = require("../../engine/sv_phys")
local world = require("../../engine/world")
require("../../engine/model_brush") -- sets collision.Collision_ClipTrace_Box / _Point

local R = f32.round
local SOLID = 0x1
local MOVE_NORMAL = sv_phys.MOVE_NORMAL
local FL_ONGROUND = sv_phys.FL_ONGROUND

-- a model that is one axis-aligned box (in model space)
local function boxmodel(cmins: { number }, cmaxs: { number }, contents: number): any
	local m: any = {
		type = "mod_brushq3",
		name = "*box",
		numframes = 1,
		brush = {},
		normalmins = { cmins[1], cmins[2], cmins[3] },
		normalmaxs = { cmaxs[1], cmaxs[2], cmaxs[3] },
	}
	local rr = R(math.sqrt(R(R(cmaxs[1] * cmaxs[1]) + R(cmaxs[2] * cmaxs[2])) + R(cmaxs[3] * cmaxs[3])))
	m.rotatedmins, m.rotatedmaxs = { -rr, -rr, -rr }, { rr, rr, rr }
	local yr = R(math.sqrt(R(R(cmaxs[1] * cmaxs[1]) + R(cmaxs[2] * cmaxs[2]))))
	m.yawmins, m.yawmaxs = { -yr, -yr, cmins[3] }, { yr, yr, cmaxs[3] }
	m.TraceBox = function(_m, _fb, _sk, tr, s, mins, maxs, e, hit, skip, skipmat)
		collision.Collision_ClipTrace_Box(tr, cmins, cmaxs, s, mins, maxs, e, hit, skip, skipmat, contents, 0, nil)
	end
	m.TraceLine = function(_m, _fb, _sk, tr, s, e, hit, skip, skipmat)
		local z = { 0, 0, 0 }
		collision.Collision_ClipTrace_Box(tr, cmins, cmaxs, s, z, z, e, hit, skip, skipmat, contents, 0, nil)
	end
	m.TracePoint = function(_m, _fb, _sk, tr, s, hit, skip, skipmat)
		collision.Collision_ClipTrace_Point(tr, cmins, cmaxs, s, hit, skip, skipmat, contents, 0, nil)
	end
	m.PointSuperContents = function(_m, _frame, p)
		if
			p[1] >= cmins[1]
			and p[1] <= cmaxs[1]
			and p[2] >= cmins[2]
			and p[2] <= cmaxs[2]
			and p[3] >= cmins[3]
			and p[3] <= cmaxs[3]
		then
			return contents
		end
		return 0
	end
	return m
end

local FIELDS = {
	{ "owner", 1 },
	{ "solid", 1 },
	{ "flags", 1 },
	{ "mins", 3 },
	{ "maxs", 3 },
	{ "origin", 3 },
	{ "angles", 3 },
	{ "modelindex", 1 },
	{ "dphitcontentsmask", 1 },
	{ "pflags", 1 },
	{ "movetype", 1 },
	{ "avelocity", 3 },
	{ "absmin", 3 },
	{ "absmax", 3 },
	{ "touch", 1 },
	{ "frame", 1 },
	{ "velocity", 3 },
	{ "nextthink", 1 },
	{ "think", 1 },
	{ "classname", 1 },
	{ "groundentity", 1 },
	{ "gravity", 1 },
	{ "ltime", 1 },
	{ "blocked", 1 },
	{ "bouncefactor", 1 },
	{ "bouncestop", 1 },
	{ "watertype", 1 },
	{ "waterlevel", 1 },
	{ "contentstransition", 1 },
	{ "view_ofs", 3 },
	{ "v_angle", 3 },
	{ "oldorigin", 3 },
	{ "aiment", 1 },
	{ "punchangle", 3 },
	{ "movetypesteplandevent", 1 },
	{ "fixangle", 1 },
}
local GLOBALS = {
	{ "self", 1 },
	{ "other", 1 },
	{ "time", 1 },
	{ "frametime", 1 },
	{ "force_retouch", 1 },
	{ "trace_allsolid", 1 },
	{ "trace_startsolid", 1 },
	{ "trace_fraction", 1 },
	{ "trace_inwater", 1 },
	{ "trace_inopen", 1 },
	{ "trace_endpos", 3 },
	{ "trace_plane_normal", 3 },
	{ "trace_plane_dist", 1 },
	{ "trace_ent", 1 },
	{ "trace_dpstartcontents", 1 },
	{ "trace_dphitcontents", 1 },
	{ "trace_dphitq3surfaceflags", 1 },
	{ "trace_dphittexturename", 1 },
}

return function(ctx: t.Ctx)
	local oldsink = console.sink
	console.sink = function(_line: string) end
	cvar.reset()
	collision.Collision_Init()
	local EXT = collision.cv.collision_extendmovelength.value

	local prog: any
	local sv = server.sv
	local calls: { any } = {}
	local handlers: { [number]: () -> () } = {}

	local function setF(e: number, f: string, v: number)
		buffer.writef32(prog.edictsfields, (e * prog.entityfields + prvm_edict.FieldOfs(prog, f)) * 4, v)
	end
	local function F(e: number, f: string): number
		return buffer.readf32(prog.edictsfields, (e * prog.entityfields + prvm_edict.FieldOfs(prog, f)) * 4)
	end
	local function setI(e: number, f: string, v: number)
		buffer.writei32(prog.edictsfields, (e * prog.entityfields + prvm_edict.FieldOfs(prog, f)) * 4, v)
	end
	local function I(e: number, f: string): number
		return buffer.readi32(prog.edictsfields, (e * prog.entityfields + prvm_edict.FieldOfs(prog, f)) * 4)
	end
	local function V(e: number, f: string): { number }
		local o = (e * prog.entityfields + prvm_edict.FieldOfs(prog, f)) * 4
		local b = prog.edictsfields
		return { buffer.readf32(b, o), buffer.readf32(b, o + 4), buffer.readf32(b, o + 8) }
	end
	local function setV(e: number, f: string, v: { number })
		local o = (e * prog.entityfields + prvm_edict.FieldOfs(prog, f)) * 4
		buffer.writef32(prog.edictsfields, o, v[1])
		buffer.writef32(prog.edictsfields, o + 4, v[2])
		buffer.writef32(prog.edictsfields, o + 8, v[3])
	end
	local function G(g: string): number
		return buffer.readi32(prog.globals, prog.globalofs_cache[g] * 4)
	end
	local function GF(g: string): number
		return buffer.readf32(prog.globals, prog.globalofs_cache[g] * 4)
	end
	local function setG(g: string, v: number)
		buffer.writei32(prog.globals, prog.globalofs_cache[g] * 4, v)
	end
	local function setGF(g: string, v: number)
		buffer.writef32(prog.globals, prog.globalofs_cache[g] * 4, v)
	end
	local function vs(v: { number }): string
		return `{v[1]} {v[2]} {v[3]}`
	end
	local function setcvar(name: string, default: string, value: number)
		if not cvar.Cvar_FindVar(name) then
			cvar.Cvar_RegisterVariable(cvar.static(0, name, default, ""))
		end
		cvar.Cvar_SetValue(name, value)
	end

	-- a fresh server prog and world: the floor slab z in [-64, 0] plus the given bmodels (modelindex 2, 3, ...)
	local function fresh(reserved: number?, models: { any }?)
		prog = prvm_edict.NewProg("server")
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
		prog.max_edicts = 64
		prog.reserved_edicts = reserved or 0
		prog.limit_edicts = 512
		prog.funcoffsets = { StartFrame = 101, EndFrame = 102, PlayerPreThink = 103, PlayerPostThink = 104 }
		prvm_edict.realtime = 10
		prvm_edict.PRVM_MEM_Alloc(prog)
		cvar.prvm_prog_list[0] = prog
		calls = {}
		handlers = {}
		prog.ExecuteProgram = function(_p: any, fnum: number, _msg: string)
			table.insert(calls, {
				fnum = fnum,
				self = G("self"),
				other = G("other"),
				time = GF("time"),
				frametime = GF("frametime"),
				ent = G("trace_ent"),
				normal = { GF("trace_plane_normal"), 0, 0 },
			})
			local h = handlers[fnum]
			if h then
				h()
			end
		end
		sv.world = world.new()
		sv.models = {}
		world.World_SetSize(sv.world, "maps/test.bsp", { -4096, -4096, -4096 }, { 4096, 4096, 4096 }, prog)
		sv.worldmodel = boxmodel({ -1024, -1024, -64 }, { 1024, 1024, 0 }, SOLID)
		sv.models[1] = sv.worldmodel
		for i, m in models or {} do
			sv.models[i + 1] = m
		end
		setF(0, "solid", sv_phys.SOLID_BSP)
		setF(0, "modelindex", 1)
	end
	local function spawn(solid: number, origin: { number }, mins: { number }, maxs: { number }): number
		local e = prvm_edict.PRVM_ED_Alloc(prog)
		setF(e, "solid", solid)
		setV(e, "origin", origin)
		setV(e, "mins", mins)
		setV(e, "maxs", maxs)
		sv_phys.SV_LinkEdict(e)
		return e
	end
	local function bsp(modelindex: number, origin: { number }): number
		local e = prvm_edict.PRVM_ED_Alloc(prog)
		setF(e, "solid", sv_phys.SOLID_BSP)
		setF(e, "modelindex", modelindex)
		setV(e, "origin", origin)
		sv_phys.SV_LinkEdict(e)
		return e
	end
	local function trace(e: number, s: { number }, push: { number }): collision.trace_t
		local en = { R(s[1] + push[1]), R(s[2] + push[2]), R(s[3] + push[3]) }
		return sv_phys.SV_TraceBox(
			s,
			V(e, "mins"),
			V(e, "maxs"),
			en,
			MOVE_NORMAL,
			e,
			sv_phys.SV_GenericHitSuperContentsMask(e),
			0,
			0,
			EXT
		)
	end
	local function Rv(v: { number }): { number }
		return { R(v[1]), R(v[2]), R(v[3]) }
	end
	local B16 = { { -16, -16, -16 }, { 16, 16, 16 } }
	local PMINS, PMAXS = { -16, -16, -24 }, { 16, 16, 45 }

	sv.time = 10
	sv.frametime = 0.05

	------------------------------------------------------------------------------------------------
	-- SV_CheckVelocity
	fresh()
	do
		local e = spawn(sv_phys.SOLID_BBOX, { 0, 0, 100 }, B16[1], B16[2])
		setV(e, "velocity", { 0 / 0, 5, 0 })
		setV(e, "origin", { 1, 0 / 0, 3 })
		sv_phys.SV_CheckVelocity(e)
		t.eq(ctx, vs(V(e, "velocity")), "0 5 0", "CheckVelocity: a NaN velocity component becomes 0")
		t.eq(ctx, vs(V(e, "origin")), "1 0 3", "CheckVelocity: a NaN origin component becomes 0")
		setV(e, "velocity", { R(1e-4), R(1e-4), 0 })
		sv_phys.SV_CheckVelocity(e)
		t.eq(ctx, vs(V(e, "velocity")), "0 0 0", "CheckVelocity: |v|^2 < 1e-7 is cleared")
		setV(e, "velocity", { 3000, 4000, 0 })
		sv_phys.SV_CheckVelocity(e)
		local w = R(2000 / math.sqrt(R(R(9e6) + R(16e6))))
		t.eq(ctx, vs(V(e, "velocity")), vs({ R(3000 * w), R(4000 * w), 0 }), "CheckVelocity: sv_maxvelocity 2000")
		setcvar("sv_maxvelocity", "2000", 100)
		setV(e, "velocity", { R(70.3), R(-80.1), R(10.7) })
		sv_phys.SV_CheckVelocity(e)
		local v0 = { R(70.3), R(-80.1), R(10.7) }
		local ws = mathlib.DotProduct(v0, v0)
		local w2 = R(100 / math.sqrt(ws))
		t.eq(ctx, vs(V(e, "velocity")), vs({ R(v0[1] * w2), R(v0[2] * w2), R(v0[3] * w2) }), "sv_maxvelocity 100")
		setV(e, "velocity", { 60, 80, 0 }) -- exactly 100: not scaled
		sv_phys.SV_CheckVelocity(e)
		t.eq(ctx, vs(V(e, "velocity")), "60 80 0", "speed equal to sv_maxvelocity is kept")
		cvar.Cvar_SetValue("sv_maxvelocity", 2000)
	end

	------------------------------------------------------------------------------------------------
	-- ClipVelocity
	do
		local out = { 0, 0, 0 }
		sv_phys.ClipVelocity({ 100, 0, -50 }, { 0, 0, 1 }, out, 1)
		t.eq(ctx, vs(out), "100 0 0", "ClipVelocity onto a floor")
		sv_phys.ClipVelocity({ R(0.05), 10, -10 }, { 0, 0, 1 }, out, R(1.5))
		t.eq(ctx, vs(out), "0 10 5", "ClipVelocity overbounce 1.5; |x| < STOP_EPSILON zeroed")
		sv_phys.ClipVelocity({ R(0.1), R(-0.1), R(0.0999) }, { 0, 0, 1 }, out, 1)
		t.eq(
			ctx,
			vs(out),
			`{R(0.1)} {R(-0.1)} 0`,
			"STOP_EPSILON is the double 0.1: the float 0.1 (slightly larger) is kept"
		)
		local n = { R(0.6), 0, R(0.8) }
		local inv = { R(123.4), R(5.5), R(-321.9) }
		sv_phys.ClipVelocity(inv, n, out, 1)
		local back = R(-mathlib.DotProduct(inv, n) * 1)
		t.eq(
			ctx,
			vs(out),
			vs({ R(inv[1] + R(back * n[1])), R(inv[2] + R(back * n[2])), R(inv[3] + R(back * n[3])) }),
			"ClipVelocity on a slope, float ops"
		)
		local same = { 0, 0, -500 }
		sv_phys.ClipVelocity(same, { 0, 0, 1 }, same, 2)
		t.eq(ctx, vs(same), "0 0 500", "ClipVelocity with in == out (overbounce 2)")
	end

	------------------------------------------------------------------------------------------------
	-- SV_Gravity
	fresh()
	do
		local e = spawn(sv_phys.SOLID_BBOX, { 0, 0, 100 }, B16[1], B16[2])
		sv.frametime = 1 / 72
		t.eq(ctx, sv_phys.SV_Gravity(e), R(R(1 * 800) * (1 / 72)), "SV_Gravity without .gravity: 1 * 800 * frametime")
		setF(e, "gravity", R(0.35))
		t.eq(ctx, sv_phys.SV_Gravity(e), R(R(R(0.35) * 800) * (1 / 72)), "SV_Gravity with .gravity 0.35")
		setcvar("sv_gravity", "800", 600)
		t.eq(ctx, sv_phys.SV_Gravity(e), R(R(R(0.35) * 600) * (1 / 72)), "SV_Gravity with sv_gravity 600")
		cvar.Cvar_SetValue("sv_gravity", 800)
		sv.frametime = 0.05
	end

	------------------------------------------------------------------------------------------------
	-- SV_FlyMove: floor
	fresh()
	do
		local e = spawn(sv_phys.SOLID_SLIDEBOX, { 0, 0, R(24.5) }, PMINS, PMAXS)
		setF(e, "movetype", sv_phys.MOVETYPE_WALK)
		setI(e, "groundentity", 33)
		setV(e, "velocity", { 100, 50, -200 })
		local tm = R(0.1)
		local o = V(e, "origin")
		local tr1 = trace(e, o, { R(100 * tm), R(50 * tm), R(-200 * tm) })
		local o1 = Rv(tr1.endpos)
		local tl = R(tm * (1 - tr1.fraction))
		local tr2 = trace(e, o1, { R(100 * tl), R(50 * tl), 0 })
		local blocked = sv_phys.SV_FlyMove(e, tm, false, nil, sv_phys.SV_GenericHitSuperContentsMask(e), 0, 0, 0)
		t.ok(ctx, tr1.fraction < 1 and tr1.plane.normal[3] == 1 and tr2.fraction == 1, "floor setup: hit, then slide")
		t.eq(ctx, blocked, 1, "FlyMove onto a floor: blocked 1")
		t.eq(ctx, vs(V(e, "velocity")), "100 50 0", "floor: velocity clipped")
		t.eq(ctx, vs(V(e, "origin")), vs(Rv(tr2.endpos)), "floor: origin after the slide")
		t.ok(ctx, bit32.band(F(e, "flags"), FL_ONGROUND) ~= 0, "floor: FL_ONGROUND set")
		t.eq(ctx, I(e, "groundentity"), 0, "floor: groundentity = world")
		t.eq(ctx, sv_phys.SV_FlyMove(e, 0, false, nil, 0, 0, 0, 0), 0, "time <= 0 returns 0")
	end

	-- gravity in SV_FlyMove: sv_gameplayfix_gravityunaffectedbyticrate halves it before and after the move
	do
		local e = spawn(sv_phys.SOLID_SLIDEBOX, { 300, 300, 500 }, PMINS, PMAXS)
		local tm = R(sv.frametime)
		local g = sv_phys.SV_Gravity(e)
		setV(e, "velocity", { 0, 0, 0 })
		sv_phys.SV_FlyMove(e, tm, true, nil, 0, 0, 0, 0)
		t.eq(ctx, vs(V(e, "velocity")), vs({ 0, 0, R(0 - g) }), "applygravity: vz -= gravity")
		t.eq(ctx, vs(V(e, "origin")), vs({ 300, 300, R(500 + R(R(0 - g) * tm)) }), "and moved by it")
		setcvar("sv_gameplayfix_gravityunaffectedbyticrate", "0", 1)
		setV(e, "velocity", { 0, 0, 0 })
		setV(e, "origin", { 300, 300, 500 })
		sv_phys.SV_FlyMove(e, tm, true, nil, 0, 0, 0, 0)
		local half = R(0 - R(g * 0.5))
		t.eq(ctx, vs(V(e, "velocity")), vs({ 0, 0, R(half - R(g * 0.5)) }), "gravityunaffectedbyticrate: two halves")
		t.eq(ctx, vs(V(e, "origin")), vs({ 300, 300, R(500 + R(half * tm)) }), "moved by the first half only")
		cvar.Cvar_SetValue("sv_gameplayfix_gravityunaffectedbyticrate", 0)
		setcvar("sv_gameplayfix_nogravityonground", "0", 1)
		setF(e, "flags", FL_ONGROUND)
		setV(e, "velocity", { 0, 0, 0 })
		sv_phys.SV_FlyMove(e, tm, true, nil, 0, 0, 0, 0)
		t.eq(ctx, vs(V(e, "velocity")), "0 0 0", "nogravityonground: no gravity while FL_ONGROUND")
		setF(e, "flags", 0)
		sv_phys.SV_FlyMove(e, tm, true, nil, 0, 0, 0, 0)
		t.eq(ctx, vs(V(e, "velocity")), vs({ 0, 0, R(0 - g) }), "nogravityonground: gravity when airborne")
		cvar.Cvar_SetValue("sv_gameplayfix_nogravityonground", 0)
	end

	-- SV_FlyMove: wall, corner, floor + wall, step
	local wallx = boxmodel({ -16, -512, -64 }, { 16, 512, 256 }, SOLID)
	local wally = boxmodel({ -512, -16, -64 }, { 512, 16, 256 }, SOLID)
	local step = boxmodel({ -64, -512, 0 }, { 64, 512, 16 }, SOLID)
	fresh(0, { wallx, wally, step })
	do
		bsp(2, { 80, 0, 0 }) -- x face at 64
		local e = spawn(sv_phys.SOLID_SLIDEBOX, { 0, 0, 25 }, PMINS, PMAXS)
		setV(e, "velocity", { 500, 0, 0 })
		local tm = R(0.1)
		local tr1 = trace(e, V(e, "origin"), { R(500 * tm), 0, 0 })
		local sn = { 9, 9, 9 }
		local blocked = sv_phys.SV_FlyMove(e, tm, false, sn, 0, 0, 0, 0)
		t.eq(ctx, blocked, 2, "FlyMove into a wall: blocked 2")
		t.eq(ctx, vs(sn), "-1 0 0", "wall: stepnormal = the wall normal")
		t.eq(ctx, vs(V(e, "velocity")), "0 0 0", "wall: head-on velocity stops")
		t.eq(ctx, vs(V(e, "origin")), vs(Rv(tr1.endpos)), "wall: origin at the trace endpos")
		t.ok(ctx, math.abs(V(e, "origin")[1] - 48) < 0.05, "wall: stopped at the face")
	end
	fresh(0, { wallx, wally, step })
	do
		bsp(2, { 80, 0, 0 })
		bsp(3, { 0, 80, 0 }) -- y face at 64
		local e = spawn(sv_phys.SOLID_SLIDEBOX, { 0, 0, 25 }, PMINS, PMAXS)
		setV(e, "velocity", { 1000, 800, 0 })
		local sn = { 9, 9, 9 }
		local blocked = sv_phys.SV_FlyMove(e, R(0.1), false, sn, 0, 0, 0, 0)
		local o = V(e, "origin")
		t.eq(ctx, blocked, 2, "FlyMove into a corner: blocked 2")
		t.eq(ctx, vs(V(e, "velocity")), "0 0 0", "corner: stopped")
		t.ok(ctx, math.abs(o[1] - 48) < 0.05 and math.abs(o[2] - 48) < 0.05, "corner: against both walls")
		t.eq(ctx, vs(sn), "0 -1 0", "corner: stepnormal of the last wall")
	end
	fresh(0, { wallx, wally, step })
	do
		bsp(2, { 80, 0, 0 })
		local e = spawn(sv_phys.SOLID_SLIDEBOX, { 0, 0, R(24.5) }, PMINS, PMAXS)
		setV(e, "velocity", { 1000, 0, -300 })
		local blocked = sv_phys.SV_FlyMove(e, R(0.1), false, nil, 0, 0, 0, 0)
		t.eq(ctx, blocked, 3, "FlyMove floor then wall: blocked 1 | 2")
		t.eq(ctx, vs(V(e, "velocity")), "0 0 0", "floor + wall: stopped")
		t.ok(ctx, bit32.band(F(e, "flags"), FL_ONGROUND) ~= 0, "floor + wall: on ground")
	end
	fresh(0, { wallx, wally, step })
	do
		bsp(4, { 128, 0, 0 }) -- step: x face at 64, top at z 16
		local e = spawn(sv_phys.SOLID_SLIDEBOX, { 0, 0, 24.03125 }, PMINS, PMAXS)
		setV(e, "velocity", { 500, 0, 0 })
		local tm = R(0.1)
		local blocked = sv_phys.SV_FlyMove(e, tm, false, nil, 0, 0, 0, 0)
		t.eq(ctx, blocked, 2, "FlyMove into a step without stepheight: blocked 2")
		t.ok(ctx, math.abs(V(e, "origin")[1] - 48) < 0.05, "no stepheight: stops at the step face")
		setV(e, "origin", { 0, 0, 24.03125 })
		sv_phys.SV_LinkEdict(e)
		setV(e, "velocity", { 500, 0, 0 })
		local o = V(e, "origin")
		local tr1 = trace(e, o, { R(500 * tm), 0, 0 })
		local s1 = Rv(tr1.endpos)
		local up = trace(e, s1, { 0, 0, 18 })
		local s2 = Rv(up.endpos)
		local fw = trace(e, s2, { R(500 * tm), 0, 0 })
		local s3 = Rv(fw.endpos)
		local dn = trace(e, s3, { 0, 0, R(s1[3] - s3[3]) })
		blocked = sv_phys.SV_FlyMove(e, tm, false, nil, 0, 0, 0, 18)
		t.eq(ctx, blocked, 0, "stepheight 18: the step is climbed, no blocked bits")
		t.eq(ctx, vs(V(e, "origin")), vs(Rv(dn.endpos)), "step: up, forward, down")
		t.ok(ctx, math.abs(V(e, "origin")[3] - 40.03125) < 0.05, "step: standing on the step top")
		t.eq(ctx, vs(V(e, "velocity")), "500 0 0", "step: velocity kept")
	end

	------------------------------------------------------------------------------------------------
	-- SV_PushEntity: touch calls (SV_Impact), relinking, triggers (dolink), setorigin in touch
	fresh()
	do
		local mover = spawn(sv_phys.SOLID_SLIDEBOX, { 0, 0, 100 }, B16[1], B16[2])
		local target = spawn(sv_phys.SOLID_BBOX, { 60, 0, 100 }, B16[1], B16[2])
		setI(mover, "touch", 11)
		setI(target, "touch", 12)
		setG("self", 55)
		setG("other", 66)
		local ok, tr = sv_phys.SV_PushEntity(mover, { 100, 0, 0 }, false)
		t.ok(ctx, ok and tr.ent == target and tr.fraction < 1, "PushEntity hits the box, returns true")
		t.eq(ctx, #calls, 2, "both touch functions run")
		local c1, c2 = calls[1], calls[2]
		t.ok(ctx, c1 and c1.fnum == 11 and c1.self == mover and c1.other == target, "e1 touch: self = mover")
		t.ok(ctx, c1 and c1.ent == target and c1.normal[1] == -1, "e1 touch: trace globals of the trace")
		t.ok(ctx, c2 and c2.fnum == 12 and c2.self == target and c2.other == mover, "e2 touch: self = target")
		t.ok(ctx, c2 and c2.ent == mover and c2.normal[1] == 1, "e2 touch: trace_ent = mover, normal negated")
		t.ok(ctx, c1 and c1.time == R(sv.time), "touch: time = sv.time")
		t.eq(ctx, G("self") .. " " .. G("other"), "55 66", "self / other restored")
		local o = V(mover, "origin")
		t.eq(ctx, vs(o), vs(Rv(tr.endpos)), "origin = endpos")
		t.eq(ctx, V(mover, "absmin")[1], R(R(o[1] - 16) - 1), "relinked: absmin")
		-- FL_ONGROUND on the same groundentity: no impact
		calls = {}
		setF(mover, "flags", FL_ONGROUND)
		setI(mover, "groundentity", target)
		sv_phys.SV_PushEntity(mover, { 10, 0, 0 }, false)
		t.eq(ctx, #calls, 0, "no impact with the entity it stands on")
		setF(mover, "flags", 0)
		-- setorigin inside the touch function: PushEntity returns false
		handlers[11] = function()
			local m = prog.ed_mark
			if m and m[mover] == -1 then
				m[mover] = -2
			end
		end
		calls = {}
		local ok2 = sv_phys.SV_PushEntity(mover, { 10, 0, 0 }, false)
		t.eq(ctx, ok2, false, "touch called setorigin: PushEntity returns false")
		t.eq(ctx, prog.ed_mark[mover], 0, "mark reset to 0")
		handlers[11] = nil
		-- dolink: triggers at the destination are touched
		local trig = spawn(sv_phys.SOLID_TRIGGER, { 0, 300, 100 }, B16[1], B16[2])
		setI(trig, "touch", 13)
		setV(mover, "origin", { 0, 200, 100 })
		sv_phys.SV_LinkEdict(mover)
		calls = {}
		sv_phys.SV_PushEntity(mover, { 0, 100, 0 }, true)
		t.ok(ctx, #calls == 1 and calls[1].fnum == 13 and calls[1].self == trig, "dolink: trigger touched")
		calls = {}
		setV(mover, "origin", { 0, 200, 100 })
		sv_phys.SV_LinkEdict(mover)
		sv_phys.SV_PushEntity(mover, { 0, 100, 0 }, false)
		t.eq(ctx, #calls, 0, "dolink false: triggers not touched")
	end

	------------------------------------------------------------------------------------------------
	-- SV_PushMove: a moving pusher carries its rider and pushes an entity in its way
	local pmodel = boxmodel({ -32, -32, -32 }, { 32, 32, 32 }, SOLID)
	local cwall = boxmodel({ -16, -64, -64 }, { 16, 64, 64 }, SOLID)
	local function pusherent(): number
		local p = bsp(2, { 0, 0, 100 })
		setF(p, "movetype", sv_phys.MOVETYPE_PUSH)
		setF(p, "ltime", 5)
		setI(p, "blocked", 21)
		return p
	end
	fresh(0, { pmodel, cwall })
	do
		local p = pusherent()
		local rider = spawn(sv_phys.SOLID_SLIDEBOX, { 0, 0, 148.03125 }, B16[1], B16[2])
		setF(rider, "movetype", sv_phys.MOVETYPE_WALK)
		setF(rider, "flags", FL_ONGROUND)
		setI(rider, "groundentity", p)
		local victim = spawn(sv_phys.SOLID_BBOX, { 50, 0, 100 }, B16[1], B16[2])
		setF(victim, "movetype", sv_phys.MOVETYPE_TOSS)
		local mt = R(0.1)
		setV(p, "velocity", { 100, 0, 0 })
		local move1 = R(100 * mt)
		sv_phys.SV_PushMove(p, mt)
		t.eq(ctx, vs(V(p, "origin")), vs({ R(0 + R(mt * 100)), 0, 100 }), "PushMove: pusher moved")
		t.eq(ctx, F(p, "ltime"), R(5 + mt), "PushMove: ltime advanced")
		t.eq(ctx, vs(V(rider, "origin")), vs({ R(0 + move1), 0, 148.03125 }), "PushMove: rider carried")
		t.eq(ctx, vs(V(victim, "origin")), vs({ R(50 + move1), 0, 100 }), "PushMove: entity in the way pushed")
		t.ok(ctx, bit32.band(F(rider, "flags"), FL_ONGROUND) ~= 0, "MOVETYPE_WALK rider keeps FL_ONGROUND")
		t.eq(ctx, F(p, "solid"), sv_phys.SOLID_BSP, "pusher solid restored")
		t.eq(ctx, #calls, 0, "no blocked call")
		t.ok(ctx, prog.ed_waterposition_forceupdate[victim] == true, "waterposition_forceupdate set on moved")
		-- no velocity: only ltime advances
		setV(p, "velocity", { 0, 0, 0 })
		sv_phys.SV_PushMove(p, mt)
		t.eq(ctx, F(p, "ltime"), R(R(5 + mt) + mt), "PushMove without velocity: ltime only")
	end
	-- crushing: the victim is pushed into a wall, the move is undone and blocked runs
	fresh(0, { pmodel, cwall })
	do
		local p = pusherent()
		local victim = spawn(sv_phys.SOLID_BBOX, { 50, 0, 100 }, B16[1], B16[2])
		setF(victim, "movetype", sv_phys.MOVETYPE_TOSS)
		local w = bsp(3, { 83, 0, 100 }) -- face at x 67: one unit of room
		setF(w, "movetype", sv_phys.MOVETYPE_NONE)
		setV(p, "velocity", { 100, 0, 0 })
		sv_phys.SV_PushMove(p, R(0.1))
		t.eq(ctx, vs(V(p, "origin")), "0 0 100", "crush: pusher origin restored")
		t.eq(ctx, F(p, "ltime"), 5, "crush: ltime restored")
		t.eq(ctx, vs(V(victim, "origin")), "50 0 100", "crush: victim moved back")
		local c = calls[1]
		t.ok(ctx, #calls == 1 and c.fnum == 21 and c.self == p and c.other == victim, "crush: blocked(self, other)")
		t.ok(ctx, c and c.time == R(sv.time), "crush: time = sv.time")
		-- SOLID_TRIGGER victims become corpses (mins / maxs cleared in x / y)
		calls = {}
		setF(victim, "solid", sv_phys.SOLID_TRIGGER)
		sv_phys.SV_LinkEdict(victim)
		sv_phys.SV_PushMove(p, R(0.1))
		t.eq(ctx, #calls, 0, "SOLID_TRIGGER victim: no blocked call")
	end
	-- rotation: the rider is turned around the pusher's origin
	fresh(0, { pmodel, cwall })
	do
		local p = pusherent()
		local rider = spawn(sv_phys.SOLID_SLIDEBOX, { 20, 0, 148.03125 }, B16[1], B16[2])
		setF(rider, "movetype", sv_phys.MOVETYPE_WALK)
		setF(rider, "flags", FL_ONGROUND)
		setI(rider, "groundentity", p)
		local mt = R(0.1)
		setV(p, "avelocity", { 0, 90, 0 })
		local ma = R(90 * mt)
		-- AngleVectorsFLU(-moveangle): forward / left / up, doubles stored as float
		local ang = -ma * (math.pi * 2 / 360)
		local sy, cy = math.sin(ang), math.cos(ang)
		local fwd, left, upv = { R(cy), R(sy), 0 }, { R(-sy), R(cy), 0 }, { 0, 0, 1 }
		local org = { 20, 0, 48.03125 } -- rider origin - pusher origin + pivot (0)
		local org2 = { mathlib.DotProduct(org, fwd), mathlib.DotProduct(org, left), mathlib.DotProduct(org, upv) }
		local move = { R(org2[1] - org[1]), R(org2[2] - org[2]), R(org2[3] - org[3]) }
		sv_phys.SV_PushMove(p, mt)
		t.eq(ctx, vs(V(p, "angles")), vs({ 0, R(0 + R(mt * 90)), 0 }), "rotating pusher: angles advanced")
		t.eq(
			ctx,
			vs(V(rider, "origin")),
			vs({ R(20 + move[1]), R(0 + move[2]), R(48.03125 + 100 + move[3]) }),
			"rotating pusher: rider moved along the arc"
		)
		t.eq(ctx, V(rider, "angles")[2], R(0 + 1 * ma), "rotating pusher: rider yaw += fraction * moveangle")
		local ro = V(rider, "origin")
		t.ok(ctx, math.abs(ro[1] - 20 * math.cos(math.rad(9))) < 1e-3, "x = 20 cos 9")
		t.ok(ctx, math.abs(ro[2] - 20 * math.sin(math.rad(9))) < 1e-3, "y = 20 sin 9")
		-- angles are wrapped into [0, 360)
		setV(p, "angles", { 0, 355, 0 })
		sv_phys.SV_PushMove(p, mt)
		local y = R(355 + R(mt * 90))
		t.eq(ctx, V(p, "angles")[2], R(y - 360.0 * math.floor(y * (1.0 / 360.0))), "pusher angles wrapped")
	end
	-- SV_Physics_Pusher: think when nextthink falls inside the move
	fresh(0, { pmodel, cwall })
	do
		local p = pusherent()
		setV(p, "velocity", { 100, 0, 0 })
		setI(p, "think", 22)
		setF(p, "nextthink", R(5.02))
		sv_phys.SV_Physics_Pusher(p)
		local mt = R(R(5.02) - 5)
		t.eq(ctx, F(p, "ltime"), R(5 + mt), "Physics_Pusher: moves only until nextthink")
		t.eq(ctx, vs(V(p, "origin")), vs({ R(0 + R(mt * 100)), 0, 100 }), "Physics_Pusher: partial move")
		t.ok(ctx, #calls == 1 and calls[1].fnum == 22 and calls[1].self == p, "Physics_Pusher: think called")
		t.eq(ctx, F(p, "nextthink"), 0, "Physics_Pusher: nextthink cleared")
	end

	------------------------------------------------------------------------------------------------
	-- SV_Physics_Toss
	fresh(0, { wallx })
	do
		local ft = sv.frametime
		local mt = R(ft)
		local e = spawn(sv_phys.SOLID_BBOX, { 0, 0, 500 }, B16[1], B16[2])
		setF(e, "movetype", sv_phys.MOVETYPE_TOSS)
		setV(e, "velocity", { 100, 0, 0 })
		setV(e, "avelocity", { 0, 30, 0 })
		local g = sv_phys.SV_Gravity(e)
		sv_phys.SV_Physics_Toss(e)
		local vz = R(0 - g)
		t.eq(ctx, vs(V(e, "velocity")), vs({ 100, 0, vz }), "TOSS: gravity")
		t.eq(ctx, vs(V(e, "angles")), vs({ 0, R(0 + ft * 30), 0 }), "TOSS: angles += frametime * avelocity")
		t.eq(ctx, vs(V(e, "origin")), vs({ R(0 + R(100 * mt)), 0, R(500 + R(vz * mt)) }), "TOSS: free flight")
		-- landing
		setV(e, "origin", { 0, 0, R(16.5) })
		setV(e, "velocity", { 0, 0, -100 })
		sv_phys.SV_LinkEdict(e)
		sv_phys.SV_Physics_Toss(e)
		t.ok(ctx, bit32.band(F(e, "flags"), FL_ONGROUND) ~= 0, "TOSS landing: FL_ONGROUND")
		t.eq(ctx, I(e, "groundentity"), 0, "TOSS landing: groundentity world")
		t.eq(ctx, vs(V(e, "velocity")) .. " / " .. vs(V(e, "avelocity")), "0 0 0 / 0 0 0", "TOSS landing: stopped")
		t.ok(ctx, prog.ed_suspendedinairflag[e] == true, "TOSS on a SOLID_BSP ground: suspendedinairflag")
		t.ok(ctx, math.abs(V(e, "origin")[3] - 16.03125) < 0.01, "TOSS landing: resting on the floor")
		-- onground: no move at all (groundentity is world)
		local before = vs(V(e, "origin"))
		sv_phys.SV_Physics_Toss(e)
		t.eq(ctx, vs(V(e, "origin")) .. " / " .. vs(V(e, "velocity")), before .. " / 0 0 0", "onground: no move")
		-- moving upward clears FL_ONGROUND
		setV(e, "velocity", { 0, 0, 100 })
		sv_phys.SV_Physics_Toss(e)
		t.ok(ctx, bit32.band(F(e, "flags"), FL_ONGROUND) == 0, "upward velocity clears FL_ONGROUND")
		t.eq(ctx, V(e, "velocity")[3], R(100 - g), "and it moves with gravity")
	end
	fresh(0, { wallx })
	do
		local mt = R(sv.frametime)
		local e = spawn(sv_phys.SOLID_BBOX, { 0, 0, R(16.5) }, B16[1], B16[2])
		setF(e, "movetype", sv_phys.MOVETYPE_BOUNCE)
		setV(e, "velocity", { 50, 0, -500 })
		local g = sv_phys.SV_Gravity(e)
		local vz = R(-500 - g)
		local tr1 = trace(e, V(e, "origin"), { R(50 * mt), 0, R(vz * mt) })
		local o1 = Rv(tr1.endpos)
		local mt2 = R(mt * (1 - math.min(1, tr1.fraction)))
		local back = R(-vz * R(1 + 0.5))
		local v2 = { 50, 0, R(vz + back) }
		local tr2 = trace(e, o1, { R(v2[1] * mt2), 0, R(v2[3] * mt2) })
		sv_phys.SV_Physics_Toss(e)
		t.eq(ctx, vs(V(e, "velocity")), vs(v2), "BOUNCE: ClipVelocity with 1 + bouncefactor 0.5")
		t.ok(ctx, bit32.band(F(e, "flags"), FL_ONGROUND) == 0, "BOUNCE fast: keeps bouncing")
		t.eq(ctx, vs(V(e, "origin")), vs(Rv(tr2.endpos)), "BOUNCE: slidemoveprojectiles finishes the move")
		-- slow: stops (d < sv_gravity * bouncestop * gravity)
		setV(e, "origin", { 0, 0, R(16.5) })
		setV(e, "velocity", { 0, 0, -30 })
		sv_phys.SV_LinkEdict(e)
		sv_phys.SV_Physics_Toss(e)
		t.ok(ctx, bit32.band(F(e, "flags"), FL_ONGROUND) ~= 0, "BOUNCE slow: comes to rest")
		t.eq(ctx, vs(V(e, "velocity")), "0 0 0", "BOUNCE slow: velocity cleared")
		-- bouncestop 0.9 makes the fast one stop too
		setF(e, "flags", 0)
		setF(e, "bouncestop", R(0.9))
		setV(e, "origin", { 0, 0, R(16.5) })
		setV(e, "velocity", { 0, 0, -500 })
		sv_phys.SV_LinkEdict(e)
		sv_phys.SV_Physics_Toss(e)
		t.ok(ctx, bit32.band(F(e, "flags"), FL_ONGROUND) ~= 0, "BOUNCE with bouncestop 0.9: 270 < 720, stops")
		-- BOUNCEMISSILE: no gravity, overbounce 2
		local m = spawn(sv_phys.SOLID_BBOX, { 300, 0, R(16.5) }, B16[1], B16[2])
		setF(m, "movetype", sv_phys.MOVETYPE_BOUNCEMISSILE)
		setV(m, "velocity", { 0, 0, -500 })
		sv_phys.SV_Physics_Toss(m)
		t.eq(ctx, vs(V(m, "velocity")), "0 0 500", "BOUNCEMISSILE: reflected, no gravity")
		t.ok(ctx, bit32.band(F(m, "flags"), FL_ONGROUND) == 0, "BOUNCEMISSILE: never onground")
		setcvar("sv_gameplayfix_slidemoveprojectiles", "1", 0)
		setV(m, "origin", { 300, 0, R(16.5) })
		setV(m, "velocity", { 0, 0, -500 })
		sv_phys.SV_LinkEdict(m)
		sv_phys.SV_Physics_Toss(m)
		t.ok(ctx, V(m, "origin")[3] < 16.1, "slidemoveprojectiles 0: the move ends at the bounce")
		cvar.Cvar_SetValue("sv_gameplayfix_slidemoveprojectiles", 1)
	end
	fresh(0, { wallx })
	do
		bsp(2, { 80, 0, 0 })
		local e = spawn(sv_phys.SOLID_BBOX, { 0, 0, 100 }, B16[1], B16[2])
		setF(e, "movetype", sv_phys.MOVETYPE_FLYMISSILE)
		setV(e, "velocity", { 1000, 0, 0 })
		sv_phys.SV_Physics_Toss(e)
		t.eq(ctx, vs(V(e, "velocity")), "0 0 0", "FLYMISSILE into a wall: ClipVelocity 1.0")
		t.ok(ctx, bit32.band(F(e, "flags"), FL_ONGROUND) == 0, "FLYMISSILE wall: not onground")
		t.ok(ctx, math.abs(V(e, "origin")[1] - 48) < 0.05, "FLYMISSILE wall: at the face")
		setV(e, "origin", { -300, 0, R(16.5) })
		setV(e, "velocity", { 0, 0, -1000 })
		sv_phys.SV_LinkEdict(e)
		sv_phys.SV_Physics_Toss(e)
		t.ok(ctx, bit32.band(F(e, "flags"), FL_ONGROUND) ~= 0, "FLYMISSILE onto the floor: onground")
		t.eq(ctx, vs(V(e, "velocity")), "0 0 0", "FLYMISSILE floor: stopped")
	end

	------------------------------------------------------------------------------------------------
	-- SV_Physics_Step
	fresh()
	do
		local e = spawn(sv_phys.SOLID_SLIDEBOX, { 0, 0, R(16.5) }, B16[1], B16[2])
		setF(e, "movetype", sv_phys.MOVETYPE_STEP)
		setV(e, "velocity", { 0, 0, -200 })
		setI(e, "movetypesteplandevent", 31)
		local parm: { number } = {}
		handlers[31] = function()
			parm = {
				buffer.readf32(prog.globals, 16),
				buffer.readf32(prog.globals, 20),
				buffer.readf32(prog.globals, 24),
			}
		end
		sv_phys.SV_Physics_Step(e)
		t.ok(ctx, bit32.band(F(e, "flags"), FL_ONGROUND) ~= 0, "STEP falling: lands")
		t.ok(ctx, #calls == 1 and calls[1].fnum == 31 and calls[1].self == e, "STEP: movetypesteplandevent called")
		t.eq(ctx, vs(parm), "0 0 -200", "STEP: PARM0 = velocity before the move")
		t.ok(ctx, prog.ed_waterposition_forceupdate[e] == true, "STEP: waterposition_forceupdate")
		-- slow fall: no land event
		calls = {}
		setF(e, "flags", 0)
		setV(e, "origin", { 0, 0, R(16.5) })
		setV(e, "velocity", { 0, 0, -50 })
		sv_phys.SV_LinkEdict(e)
		sv_phys.SV_Physics_Step(e)
		t.eq(ctx, #calls, 0, "STEP slow landing (vz >= sv_gravity * -0.1): no event")
		-- FL_FLY: does not fall
		setF(e, "flags", sv_phys.FL_FLY)
		setV(e, "origin", { 0, 0, 300 })
		setV(e, "velocity", { 0, 0, -50 })
		sv_phys.SV_Physics_Step(e)
		t.eq(ctx, vs(V(e, "origin")), "0 0 300", "STEP FL_FLY: no move")
		-- onground with upward velocity: flies off
		setF(e, "flags", FL_ONGROUND)
		setV(e, "velocity", { 0, 0, 100 })
		sv_phys.SV_Physics_Step(e)
		t.ok(ctx, bit32.band(F(e, "flags"), FL_ONGROUND) == 0 and V(e, "origin")[3] > 300, "STEP upward: freefall")
	end

	------------------------------------------------------------------------------------------------
	-- SV_RunThink
	fresh()
	do
		sv.time = 10
		sv.frametime = 0.05
		local e = spawn(sv_phys.SOLID_NOT, { 0, 0, 100 }, B16[1], B16[2])
		setI(e, "think", 41)
		setF(e, "nextthink", 0)
		t.ok(ctx, sv_phys.SV_RunThink(e) and #calls == 0, "nextthink 0: no think")
		setF(e, "nextthink", R(10.06))
		t.ok(ctx, sv_phys.SV_RunThink(e) and #calls == 0, "nextthink after the frame: no think")
		setF(e, "nextthink", R(10.02))
		t.ok(ctx, sv_phys.SV_RunThink(e), "think: returns true")
		local c = calls[1]
		t.ok(ctx, #calls == 1 and c.fnum == 41 and c.self == e and c.other == 0, "think: self = ent, other = world")
		t.eq(ctx, c and c.time, R(10.02), "think: time = max(sv.time, nextthink)")
		t.eq(ctx, F(e, "nextthink"), 0, "think: nextthink cleared")
		calls = {}
		setF(e, "nextthink", R(9.5))
		sv_phys.SV_RunThink(e)
		t.eq(ctx, calls[1] and calls[1].time, 10, "past nextthink: time = sv.time")
		-- multiple thinks per frame: think reschedules itself 0.01 later
		handlers[41] = function()
			setF(e, "nextthink", R(GF("time") + R(0.01)))
		end
		calls = {}
		setF(e, "nextthink", R(10.001))
		sv_phys.SV_RunThink(e)
		local want, nt = 0, R(10.001)
		while want < 128 do
			want += 1
			local tm = if 10 > nt then 10 else nt
			tm = R(tm)
			nt = R(tm + R(0.01))
			if nt <= tm or nt > 10 + 0.05 then
				break
			end
		end
		t.eq(ctx, #calls, want, "multiplethinksperframe 1: thinks until past the frame")
		t.ok(ctx, #calls >= 4, "several thinks")
		setcvar("sv_gameplayfix_multiplethinksperframe", "1", 0)
		calls = {}
		setF(e, "nextthink", R(10.001))
		sv_phys.SV_RunThink(e)
		t.eq(ctx, #calls, 1, "multiplethinksperframe 0: one think")
		cvar.Cvar_SetValue("sv_gameplayfix_multiplethinksperframe", 1)
		-- nextthink = time: no loop
		handlers[41] = function()
			setF(e, "nextthink", GF("time"))
		end
		calls = {}
		setF(e, "nextthink", R(10.01))
		sv_phys.SV_RunThink(e)
		t.eq(ctx, #calls, 1, "nextthink = time: one think")
		-- the think frees the entity
		handlers[41] = function()
			prvm_edict.PRVM_ED_Free(prog, e)
		end
		setF(e, "nextthink", R(10.01))
		t.eq(ctx, sv_phys.SV_RunThink(e), false, "think removed the entity: false")
	end

	------------------------------------------------------------------------------------------------
	-- SV_Physics_Follow
	fresh()
	do
		local a = spawn(sv_phys.SOLID_NOT, { R(10.5), -20, 30 }, B16[1], B16[2])
		local e = spawn(sv_phys.SOLID_NOT, { 0, 0, 0 }, B16[1], B16[2])
		setF(e, "movetype", sv_phys.MOVETYPE_FOLLOW)
		setI(e, "aiment", a)
		setV(e, "view_ofs", { 4, 5, R(6.25) })
		setV(e, "v_angle", { 1, 2, 3 })
		sv_phys.SV_Physics_Follow(e)
		t.eq(
			ctx,
			vs(V(e, "origin")),
			vs({ R(10.5 + 4), -15, R(30 + R(6.25)) }),
			"Follow, no rotation: origin + view_ofs"
		)
		t.eq(ctx, vs(V(e, "angles")), "1 2 3", "Follow: angles = aiment angles + v_angle")
		setV(a, "angles", { R(10), R(37.5), 0 })
		setV(e, "punchangle", { 0, R(7), 0 })
		sv_phys.SV_Physics_Follow(e)
		local vf, vr, vu = { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 }
		local vo, pa, ea, eo = { 4, 5, R(6.25) }, { 0, R(7), 0 }, { R(10), R(37.5), 0 }, { R(10.5), -20, 30 }
		mathlib.AngleVectors({ -pa[1], pa[2], pa[3] }, vf, vr, vu)
		local v = {}
		for k = 1, 3 do
			v[k] = R(R(R(vo[1] * vf[k]) + R(vo[2] * vr[k])) + R(vo[3] * vu[k]))
		end
		mathlib.AngleVectors({ -ea[1], ea[2], ea[3] }, vf, vr, vu)
		local want = {
			R(R(R(R(v[1] * vf[1]) + R(v[2] * vf[2])) + R(v[3] * vf[3])) + eo[1]),
			R(R(R(R(v[1] * vr[1]) + R(v[2] * vr[2])) + R(v[3] * vr[3])) + eo[2]),
			R(R(R(R(v[1] * vu[1]) + R(v[2] * vu[2])) + R(v[3] * vu[3])) + eo[3]),
		}
		t.eq(ctx, vs(V(e, "origin")), vs(want), "Follow, rotated: the AngleVectors transform")
		t.eq(ctx, vs(V(e, "angles")), vs({ R(R(10) + 1), R(R(37.5) + 2), 3 }), "Follow rotated: angles")
		t.eq(ctx, V(e, "absmin")[1], R(R(want[1] - 16) - 1), "Follow: relinked")
	end

	------------------------------------------------------------------------------------------------
	-- SV_Trace_Toss
	fresh()
	do
		local e = spawn(sv_phys.SOLID_BBOX, { 0, 0, 200 }, B16[1], B16[2])
		setV(e, "velocity", { 100, 0, 200 })
		setV(e, "avelocity", { 0, 45, 0 })
		setV(e, "angles", { 0, 10, 0 })
		local o, v = { 0, 0, 200 }, { 100, 0, 200 }
		local g = R(1 * (800 * 0.025))
		local want
		for _ = 0, 199 do
			v[3] = R(v[3] - g)
			local move = { R(v[1] * 0.05), R(v[2] * 0.05), R(v[3] * 0.05) }
			want = trace(e, o, move)
			o = Rv(want.endpos)
			v[3] = R(v[3] - g)
			if want.fraction < 1 then
				break
			end
		end
		local tr = sv_phys.SV_Trace_Toss(prog, e, nil)
		t.ok(ctx, tr.fraction < 1 and tr.plane.normal[3] == 1, "Trace_Toss: lands on the floor")
		t.eq(ctx, vs(tr.endpos), vs(want.endpos), "Trace_Toss: endpos of the 0.05 s steps")
		t.eq(ctx, vs(V(e, "origin")), "0 0 200", "Trace_Toss: origin restored")
		t.eq(ctx, vs(V(e, "velocity")), "100 0 200", "Trace_Toss: velocity restored")
		t.eq(ctx, vs(V(e, "angles")) .. " " .. vs(V(e, "avelocity")), "0 10 0 0 45 0", "angles / avelocity restored")
	end

	------------------------------------------------------------------------------------------------
	-- SV_WalkMove: stepping up a stair
	fresh(0, { step })
	do
		bsp(2, { 128, 0, 0 })
		local e = spawn(sv_phys.SOLID_SLIDEBOX, { 0, 0, 24.03125 }, PMINS, PMAXS)
		setF(e, "movetype", sv_phys.MOVETYPE_WALK)
		setF(e, "flags", FL_ONGROUND)
		setV(e, "velocity", { 1000, 0, 0 })
		sv_phys.SV_WalkMove(e)
		local o = V(e, "origin")
		t.ok(ctx, math.abs(o[3] - 40.03125) < 0.05, "WalkMove: stepped up onto the stair")
		t.ok(ctx, o[1] > 48.5, "WalkMove: moved past the stair face")
		t.eq(ctx, F(e, "watertype"), -1, "WalkMove: SV_CheckWater set CONTENTS_EMPTY")
		-- frametime 0: no move
		sv.frametime = 0
		local before = vs(V(e, "origin"))
		sv_phys.SV_WalkMove(e)
		t.eq(ctx, vs(V(e, "origin")), before, "WalkMove with frametime 0: no move")
		sv.frametime = 0.05
	end

	------------------------------------------------------------------------------------------------
	-- SV_Physics: one frame over clients and other entities
	local svs = host_cmd.svs :: any
	local oldmax, oldclients = svs.maxclients, svs.clients
	svs.maxclients = 2
	svs.clients = { [0] = { begun = true, edict = 1 }, [1] = { begun = false, edict = 2, cmd = { x = 1 } } }
	fresh(2)
	do
		sv.time = 20
		sv.frametime = 0.05
		setF(1, "solid", sv_phys.SOLID_SLIDEBOX)
		setV(1, "origin", { 500, 500, 100 })
		setV(1, "mins", B16[1])
		setV(1, "maxs", B16[2])
		local thinker = spawn(sv_phys.SOLID_NOT, { 0, 0, 100 }, B16[1], B16[2]) -- 3
		setI(thinker, "think", 51)
		setF(thinker, "nextthink", R(20.01))
		local toss = spawn(sv_phys.SOLID_BBOX, { 100, 0, 300 }, B16[1], B16[2]) -- 4
		setF(toss, "movetype", sv_phys.MOVETYPE_TOSS)
		prog.ed_move = { [3] = true, [4] = true }
		local newborn = spawn(sv_phys.SOLID_BBOX, { -100, 0, 300 }, B16[1], B16[2]) -- 5: spawned this frame
		setF(newborn, "movetype", sv_phys.MOVETYPE_TOSS)
		local dead = spawn(sv_phys.SOLID_NOT, { 0, 0, 0 }, B16[1], B16[2]) -- 6: freed long ago
		prvm_edict.PRVM_ED_Free(prog, dead)
		prvm_edict.realtime = 20
		setGF("force_retouch", 2)
		local numbefore = prog.num_edicts
		sv_phys.SV_Physics()
		local order = {}
		for _, c in calls do
			table.insert(order, `{c.fnum}:{c.self}`)
		end
		t.eq(
			ctx,
			table.concat(order, " "),
			"101:0 103:1 104:1 51:3 102:0",
			"SV_Physics: StartFrame, client pre/post think, entity think, EndFrame"
		)
		t.ok(ctx, calls[1].time == 20 and calls[1].frametime == R(0.05), "StartFrame: time and frametime")
		t.eq(ctx, sv.time, 20 + 0.05, "sv.time advanced by frametime (double)")
		t.eq(ctx, V(toss, "origin")[3] < 300, true, "TOSS entity moved")
		t.eq(ctx, vs(V(newborn, "origin")), "-100 0 300", "newly spawned entity not moved (delayprojectiles)")
		t.eq(ctx, prog.ed_move[newborn], true, "but marked to move next frame")
		t.eq(ctx, GF("force_retouch"), 1, "force_retouch decremented")
		t.eq(ctx, prog.num_edicts, numbefore - 1, "num_edicts drops the freed top edict")
		t.eq(ctx, next(svs.clients[1].cmd), nil, "client not begun: cmd zeroed")
		-- second frame: the newborn moves, StartFrame time is the advanced sv.time
		calls = {}
		sv_phys.SV_Physics()
		t.ok(ctx, V(newborn, "origin")[3] < 300, "second frame: the new entity moves")
		t.eq(ctx, calls[1].time, R(20 + 0.05), "second frame: StartFrame time")
		-- sv_freezenonclients: only clients run, time stands still
		setcvar("sv_freezenonclients", "0", 1)
		local z = V(toss, "origin")[3]
		local tnow = sv.time
		calls = {}
		sv_phys.SV_Physics()
		t.eq(ctx, V(toss, "origin")[3], z, "freezenonclients: entities frozen")
		t.eq(ctx, sv.time, tnow, "freezenonclients: time frozen")
		t.ok(ctx, #calls == 4 and calls[2].fnum == 103, "freezenonclients: clients still think")
		cvar.Cvar_SetValue("sv_freezenonclients", 0)
		-- SV_Physics_ClientMove: PlayerPreThink / PostThink with frametime 0
		calls = {}
		server.host_client = svs.clients[0]
		setF(1, "fixangle", 1)
		setV(1, "angles", { 1, 2, 3 })
		sv_phys.SV_Physics_ClientMove()
		t.ok(
			ctx,
			#calls == 2 and calls[1].fnum == 103 and calls[1].frametime == 0 and calls[2].fnum == 104,
			"ClientMove: pre / post think with frametime 0"
		)
		t.eq(ctx, GF("frametime"), R(sv.frametime), "ClientMove: frametime restored")
		t.ok(ctx, svs.clients[0].fixangle_angles_set and vs(svs.clients[0].fixangle_angles) == "1 2 3", "fixangle")
		t.eq(ctx, F(1, "fixangle"), 0, "fixangle cleared")
	end
	svs.maxclients, svs.clients = oldmax, oldclients
	server.host_client = nil

	sv.worldmodel = nil
	sv.models = {}
	sv.world = world.new()
	sv.time = 0
	sv.frametime = 0
	console.sink = oldsink
	cvar.reset()
end
