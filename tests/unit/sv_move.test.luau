--!strict
-- Monster movement (engine/sv_move.luau: SV_CheckBottom, SV_movestep, SV_StepDirection, SV_NewChaseDir,
-- SV_CloseEnough, VM_SV_MoveToGoal; engine/svvm_cmds.luau: walkmove #32, checkbottom #40, movetogoal #67)
-- against the C rules (sv_move.c / svvm_cmds.c @xonotic-v0.8.6), on a synthetic server prog, a floor slab
-- as the world and box models as SOLID_BSP entities, as in tests/unit/sv_world_builtins.test.luau.
-- Expected values are derived by hand from the C; exact positions are checked against an independent
-- SV_TraceBox with the arguments the C passes. Not a differential test against the C build.
local t = require("../_lib/t")
local collision = require("../../engine/collision")
local console = require("../../engine/console")
local cvar = require("../../engine/cvar")
local f32 = require("../../engine/_port/f32")
local libc = require("../../engine/_port/libc")
local mathlib = require("../../engine/mathlib")
local prvm_edict = require("../../engine/prvm_edict")
local server = require("../../engine/server")
local sv_phys = require("../../engine/sv_phys")
local sv_move = require("../../engine/sv_move")
local svvm_cmds = require("../../engine/svvm_cmds")
local world = require("../../engine/world")
require("../../engine/model_brush") -- sets collision.Collision_ClipTrace_Box / _Point

local R = f32.round
local SOLID, WATER = 0x1, 0x2
local B = svvm_cmds.PORTED
local OFS_RETURN, OFS_PARM0 = 1, 4
local FL_FLY, FL_SWIM, FL_ONGROUND, FL_PARTIALGROUND = 1, 2, 512, 1024

-- a model that is one axis-aligned box (in model space); `normal` overrides the hit plane normal
local function boxmodel(cmins: { number }, cmaxs: { number }, contents: number, normal: { number }?): any
	local m: any = {
		type = "mod_brushq3",
		name = "*box",
		numframes = 1,
		brush = {},
		normalmins = { cmins[1], cmins[2], cmins[3] },
		normalmaxs = { cmaxs[1], cmaxs[2], cmaxs[3] },
	}
	m.TraceBox = function(_m, _fb, _sk, tr, s, mins, maxs, e, hit, skip, skipmat)
		collision.Collision_ClipTrace_Box(tr, cmins, cmaxs, s, mins, maxs, e, hit, skip, skipmat, contents, 0, nil)
		if normal and tr.fraction < 1 then
			tr.plane.normal[1], tr.plane.normal[2], tr.plane.normal[3] = normal[1], normal[2], normal[3]
		end
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

return function(ctx: t.Ctx)
	local oldsink = console.sink
	local lines: { string } = {}
	console.sink = function(line: string)
		table.insert(lines, line)
	end
	cvar.reset()
	collision.Collision_Init()

	local FIELDS = {
		{ "owner", 1 },
		{ "solid", 1 },
		{ "flags", 1 },
		{ "mins", 3 },
		{ "maxs", 3 },
		{ "size", 3 },
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
		{ "chain", 1 },
		{ "groundentity", 1 },
		{ "nextthink", 1 },
		{ "enemy", 1 },
		{ "goalentity", 1 },
		{ "ideal_yaw", 1 },
		{ "yaw_speed", 1 },
	}
	local GLOBALS = {
		{ "self", 1 },
		{ "other", 1 },
		{ "time", 1 },
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
	prog.max_edicts = 400
	prog.reserved_edicts = 0
	prog.limit_edicts = 512
	prog.error_cmd = function(msg: string)
		error("error_cmd: " .. msg, 0)
	end
	prvm_edict.realtime = 10
	prvm_edict.PRVM_MEM_Alloc(prog)
	cvar.prvm_prog_list[0] = prog

	local function OF(f: string): number
		return prvm_edict.FieldOfs(prog, f)
	end
	local function F(e: number, f: string): number
		return buffer.readf32(prog.edictsfields, (e * prog.entityfields + OF(f)) * 4)
	end
	local function I(e: number, f: string): number
		return buffer.readi32(prog.edictsfields, (e * prog.entityfields + OF(f)) * 4)
	end
	local function setF(e: number, f: string, v: number)
		buffer.writef32(prog.edictsfields, (e * prog.entityfields + OF(f)) * 4, v)
	end
	local function setI(e: number, f: string, v: number)
		buffer.writei32(prog.edictsfields, (e * prog.entityfields + OF(f)) * 4, v)
	end
	local function V(e: number, f: string): { number }
		local o = (e * prog.entityfields + OF(f)) * 4
		local b = prog.edictsfields
		return { buffer.readf32(b, o), buffer.readf32(b, o + 4), buffer.readf32(b, o + 8) }
	end
	local function setV(e: number, f: string, v: { number })
		local o = (e * prog.entityfields + OF(f)) * 4
		buffer.writef32(prog.edictsfields, o, v[1])
		buffer.writef32(prog.edictsfields, o + 4, v[2])
		buffer.writef32(prog.edictsfields, o + 8, v[3])
	end
	local function vs(v: { number }): string
		return `{v[1]} {v[2]} {v[3]}`
	end
	local function vsR(v: { number }): string -- a double vector as the floats it is stored as
		return `{R(v[1])} {R(v[2])} {R(v[3])}`
	end
	local function near(a: { number }, b: { number }, eps: number): boolean
		return math.abs(a[1] - b[1]) < eps and math.abs(a[2] - b[2]) < eps and math.abs(a[3] - b[3]) < eps
	end
	local function setGI(g: string, v: number)
		buffer.writei32(prog.globals, prog.globalofs_cache[g] * 4, v)
	end
	local function GI(g: string): number
		return buffer.readi32(prog.globals, prog.globalofs_cache[g] * 4)
	end
	local function pF(i: number, v: number)
		buffer.writef32(prog.globals, (OFS_PARM0 + 3 * i) * 4, v)
	end
	local function pI(i: number, v: number)
		buffer.writei32(prog.globals, (OFS_PARM0 + 3 * i) * 4, v)
	end
	local function retF(): number
		return buffer.readf32(prog.globals, OFS_RETURN * 4)
	end
	local function setRet(v: number)
		buffer.writef32(prog.globals, OFS_RETURN * 4, v)
	end
	local function call(name: string, argc: number): (boolean, any)
		prog.argc = argc
		return pcall(B[name], prog)
	end
	local function lastline(): string
		return lines[#lines] or ""
	end
	local function setcvar(name: string, default: string, v: number)
		if not cvar.Cvar_FindVar(name) then
			cvar.Cvar_RegisterVariable(cvar.static(0, name, default, ""))
		end
		cvar.Cvar_SetValue(name, v)
	end

	-- the server: a floor slab (top z = 0, x / y in +-1024) as the world model, the area grid over +-4096
	local sv = server.sv
	sv.world = world.new()
	sv.models = {}
	sv.time = 3.5
	world.World_SetSize(sv.world, "maps/test.bsp", { -4096, -4096, -4096 }, { 4096, 4096, 4096 }, prog)
	sv.worldmodel = boxmodel({ -1024, -1024, -64 }, { 1024, 1024, 0 }, SOLID)
	sv.models[1] = sv.worldmodel

	local created: { number } = {}
	local function spawn(solid: number, origin: { number }, mins: { number }, maxs: { number }): number
		local e = prvm_edict.PRVM_ED_Alloc(prog)
		setF(e, "solid", solid)
		setV(e, "origin", origin)
		setV(e, "mins", mins)
		setV(e, "maxs", maxs)
		sv_phys.SV_LinkEdict(e)
		table.insert(created, e)
		return e
	end
	-- a SOLID_BSP entity at the origin whose model is the box cmins .. cmaxs (world coordinates)
	local function bsp(cmins: { number }, cmaxs: { number }, contents: number, normal: { number }?): number
		local idx = #sv.models + 1
		sv.models[idx] = boxmodel(cmins, cmaxs, contents, normal)
		local e = prvm_edict.PRVM_ED_Alloc(prog)
		setF(e, "solid", sv_phys.SOLID_BSP)
		setF(e, "modelindex", idx)
		-- mins / maxs as setmodel sets them (else line traces skip it: points against points)
		setV(e, "mins", cmins)
		setV(e, "maxs", cmaxs)
		sv_phys.SV_LinkEdict(e)
		table.insert(created, e)
		return e
	end
	-- removes everything spawned so far (so the scenes do not see each other)
	local function clear()
		for _, e in created do
			world.World_UnlinkEdict(prog, e)
			prvm_edict.PRVM_ED_Free(prog, e)
		end
		created = {}
		prvm_edict.realtime += 10 -- freed edicts may be reused
	end
	local MMIN, MMAX = { -16, -16, -24 }, { 16, 16, 40 }
	local function monster(origin: { number }, flags: number): number
		local e = spawn(sv_phys.SOLID_SLIDEBOX, origin, MMIN, MMAX)
		setF(e, "flags", bit32.bor(flags, sv_phys.FL_MONSTER))
		return e
	end
	local MON = sv_phys.FL_MONSTER
	local EXT = collision.cv.collision_extendmovelength.value
	-- the walking trace of SV_movestep (sv_move.c L171-175), stepheight 18
	local function steptrace(e: number, move: { number }): collision.trace_t
		local o = V(e, "origin")
		local neworg = { R(o[1] + move[1]), R(o[2] + move[2]), R(o[3] + move[3]) }
		neworg[3] = R(neworg[3] + 18)
		local end_ = { neworg[1], neworg[2], R(neworg[3] - 36) }
		return sv_phys.SV_TraceBox(neworg, MMIN, MMAX, end_, 0, e, sv_phys.SV_GenericHitSuperContentsMask(e), 0, 0, EXT)
	end
	-- the move of SV_StepDirection / walkmove for yaw, dist (float yaw*M_PI*2/360 in double, cos / sin double)
	local function yawmove(yaw: number, dist: number): { number }
		local y = R(yaw * math.pi * 2 / 360)
		return { R(math.cos(y) * dist), R(math.sin(y) * dist), 0 }
	end
	-- glibc rand(): a seed whose first three outputs satisfy pred
	local function findseed(pred: (r: { number }) -> boolean): number
		for s = 1, 100000 do
			libc.srand(s)
			local r = { libc.rand(), libc.rand(), libc.rand() }
			if pred(r) then
				return s
			end
		end
		error("no seed")
	end
	local function nthrand(seed: number, k: number): number
		libc.srand(seed)
		local r = 0
		for _ = 1, k do
			r = libc.rand()
		end
		return r
	end

	-- 1. SV_CheckBottom
	do
		local yes0, no0 = sv_move.c_yes, sv_move.c_no
		local m = monster({ -800, -800, R(24.5) }, FL_ONGROUND)
		t.eq(ctx, sv_move.SV_CheckBottom(m), true, "on the floor: all four corners solid")
		t.eq(ctx, `{sv_move.c_yes - yes0} {sv_move.c_no - no0}`, "1 0", "the easy way out (c_yes only)")
		setV(m, "origin", { 1016, -800, 25 })
		t.eq(ctx, sv_move.SV_CheckBottom(m), false, "a corner over the floor edge: false")
		t.eq(ctx, `{sv_move.c_yes - yes0} {sv_move.c_no - no0}`, "1 1", "the real check (c_no)")
		setV(m, "origin", { 1040, -800, 25 })
		t.eq(ctx, sv_move.SV_CheckBottom(m), false, "the midpoint over the void: false")
		setV(m, "origin", { -800, -800, 200 })
		t.eq(ctx, sv_move.SV_CheckBottom(m), false, "high in the air: false")
		-- a step 10 high under the +x half: off-step corners not solid -> real check, midpoint on the step
		bsp({ -600, -900, 0 }, { -500, -700, 10 }, SOLID)
		setV(m, "origin", { -590, -800, 35 }) -- bottom 11
		local yes1, no1 = sv_move.c_yes, sv_move.c_no
		t.eq(ctx, sv_move.SV_CheckBottom(m), true, "straddling a 10 step (<= sv_stepheight 18): true")
		t.eq(ctx, `{sv_move.c_yes - yes1} {sv_move.c_no - no1}`, "1 1", "through the real check")
		-- a step 20 high: mid (20) - corner (0) > 18
		bsp({ -600, -500, 0 }, { -500, -300, 20 }, SOLID)
		setV(m, "origin", { -590, -400, 45 }) -- bottom 21
		t.eq(ctx, sv_move.SV_CheckBottom(m), false, "straddling a 20 step (> 18): false")
		setcvar("sv_stepheight", "18", 24)
		t.eq(ctx, sv_move.SV_CheckBottom(m), true, "sv_stepheight 24: true")
		cvar.Cvar_SetValue("sv_stepheight", 18)
		-- the midpoint on the floor, two corners starting inside the step: mid - corner < 0 is fine
		setV(m, "origin", { -610, -400, 25 }) -- bottom 1: corners at x -626 (floor) / -594 (inside the step)
		t.eq(ctx, sv_move.SV_CheckBottom(m), true, "corners higher than the midpoint are fine")
		-- the builtin
		pI(0, m)
		setV(m, "origin", { -800, -800, R(24.5) })
		t.ok(ctx, (call("VM_SV_checkbottom", 1)), "checkbottom runs")
		t.eq(ctx, retF(), 1, "checkbottom on the floor: 1")
		setV(m, "origin", { 1016, -800, 25 })
		call("VM_SV_checkbottom", 1)
		t.eq(ctx, retF(), 0, "checkbottom over the edge: 0")
		t.ok(ctx, not (call("VM_SV_checkbottom", 2)), "checkbottom: parameter count checked")
		clear()
	end

	-- 2. SV_movestep, walking
	do
		-- flat floor
		local m = monster({ -900, 0, 25 }, bit32.bor(FL_ONGROUND, FL_PARTIALGROUND))
		setI(m, "groundentity", 77)
		local tr = steptrace(m, { 10, 0, 0 })
		t.ok(ctx, near(tr.endpos, { -890, 0, 24.03125 }, 1e-3), "hand value: lands at bottom + impact nudge")
		t.eq(ctx, sv_move.SV_movestep(m, { 10, 0, 0 }, true, false, false), true, "flat move: true")
		t.eq(ctx, vs(V(m, "origin")), vsR(tr.endpos), "origin = the push-down trace endpos (as float)")
		t.eq(ctx, I(m, "groundentity"), 0, "groundentity = trace.ent (world)")
		t.eq(ctx, F(m, "flags"), FL_ONGROUND + MON, "FL_PARTIALGROUND cleared after a good move")
		local o = V(m, "origin")
		t.eq(ctx, vs(V(m, "absmin")), `{R(R(o[1] - 16) - 1)} {R(R(o[2] - 16) - 1)} {R(R(o[3] - 24) - 1)}`, "relinked")
		-- relink false: origin moves, absmin stays
		local amin = V(m, "absmin")
		t.eq(ctx, sv_move.SV_movestep(m, { 10, 0, 0 }, false, false, false), true, "relink false: true")
		t.eq(ctx, vs(V(m, "absmin")), vs(amin), "relink false: not relinked")
		sv_phys.SV_LinkEdict(m)

		-- step up 16 (<= 18)
		local step = bsp({ -700, -50, 0 }, { -600, 50, 16 }, SOLID)
		setV(m, "origin", { -725, 0, 25 })
		sv_phys.SV_LinkEdict(m)
		tr = steptrace(m, { 10, 0, 0 })
		t.ok(ctx, near(tr.endpos, { -715, 0, 40.03125 }, 1e-3), "hand value: on the step top")
		t.eq(ctx, sv_move.SV_movestep(m, { 10, 0, 0 }, true, false, false), true, "step up 16: true")
		t.eq(ctx, vs(V(m, "origin")), vsR(tr.endpos), "step up: origin on the step")
		t.eq(ctx, I(m, "groundentity"), step, "step up: groundentity = the step entity")

		-- step down 16: off the step onto the floor
		setV(m, "origin", { -640, 0, R(40.03125) })
		sv_phys.SV_LinkEdict(m)
		tr = steptrace(m, { 70, 0, 0 })
		t.ok(ctx, near(tr.endpos, { -570, 0, 24.03125 }, 1e-3), "hand value: down on the floor")
		t.eq(ctx, sv_move.SV_movestep(m, { 70, 0, 0 }, true, false, false), true, "step down 16: true")
		t.eq(ctx, vs(V(m, "origin")), vsR(tr.endpos), "step down: origin on the floor")
		t.eq(ctx, I(m, "groundentity"), 0, "step down: groundentity world")
		clear()

		-- step too high (30): startsolid twice
		m = monster({ -725, 0, 25 }, FL_ONGROUND)
		bsp({ -700, -50, 0 }, { -600, 50, 30 }, SOLID)
		t.eq(ctx, sv_move.SV_movestep(m, { 10, 0, 0 }, true, false, false), false, "step 30: false")
		t.eq(ctx, vs(V(m, "origin")), "-725 0 25", "step 30: origin unchanged")
		clear()

		-- off the floor edge: walked off an edge
		m = monster({ 1000, 600, 25 }, FL_ONGROUND)
		t.eq(ctx, sv_move.SV_movestep(m, { 60, 0, 0 }, true, false, false), false, "walking off a ledge: false")
		t.eq(ctx, vs(V(m, "origin")), "1000 600 25", "ledge: origin unchanged")
		t.eq(ctx, F(m, "flags"), FL_ONGROUND + MON, "ledge: flags unchanged")
		-- with FL_PARTIALGROUND: go ahead and fall
		setF(m, "flags", FL_ONGROUND + FL_PARTIALGROUND + MON)
		t.eq(ctx, sv_move.SV_movestep(m, { 60, 0, 0 }, true, false, false), true, "FL_PARTIALGROUND off a ledge: true")
		t.eq(ctx, vs(V(m, "origin")), "1060 600 25", "origin += move")
		t.eq(ctx, F(m, "flags"), FL_PARTIALGROUND + MON, "FL_ONGROUND cleared")
		t.eq(ctx, V(m, "absmin")[1], R(R(1060 - 16) - 1), "relinked")

		-- dangling corner: the trace hits the floor, SV_CheckBottom fails
		setV(m, "origin", { 990, 700, 25 })
		setF(m, "flags", FL_ONGROUND + MON)
		sv_phys.SV_LinkEdict(m)
		t.eq(ctx, sv_move.SV_movestep(m, { 20, 0, 0 }, true, false, false), false, "dangling corner: false")
		t.eq(ctx, vs(V(m, "origin")), "990 700 25", "dangling corner: oldorg restored")
		setF(m, "flags", FL_ONGROUND + FL_PARTIALGROUND + MON)
		tr = steptrace(m, { 20, 0, 0 })
		t.eq(ctx, sv_move.SV_movestep(m, { 20, 0, 0 }, true, false, false), true, "FL_PARTIALGROUND dangling: true")
		t.eq(ctx, vs(V(m, "origin")), vsR(tr.endpos), "FL_PARTIALGROUND dangling: origin = trace endpos")
		t.eq(ctx, F(m, "flags"), FL_ONGROUND + FL_PARTIALGROUND + MON, "FL_PARTIALGROUND kept")
		clear()

		-- sv_gameplayfix_nostepmoveonsteepslopes: plane normal z 0.4 < 0.5
		bsp({ -900, 750, 0 }, { -800, 850, 5 }, SOLID, { 0.9165, 0, 0.4 })
		m = monster({ -850, 800, 30 }, FL_ONGROUND)
		tr = steptrace(m, { 1, 0, 0 })
		t.ok(
			ctx,
			tr.fraction < 1 and math.abs(tr.plane.normal[3] - 0.4) < 1e-6,
			"the slope model hits with normal z 0.4"
		)
		t.eq(ctx, sv_move.SV_movestep(m, { 1, 0, 0 }, true, false, false), true, "steep plane, gameplayfix 0: true")
		local o2 = V(m, "origin")
		setcvar("sv_gameplayfix_nostepmoveonsteepslopes", "0", 1)
		t.eq(ctx, sv_move.SV_movestep(m, { 1, 0, 0 }, true, false, false), false, "steep plane, gameplayfix 1: false")
		t.eq(ctx, vs(V(m, "origin")), vs(o2), "steep plane: oldorg restored")
		setF(m, "flags", FL_ONGROUND + FL_FLY + MON)
		t.eq(
			ctx,
			sv_move.SV_movestep(m, { 1, 0, 0 }, true, false, false),
			true,
			"flying monsters never reach the check"
		)
		cvar.Cvar_SetValue("sv_gameplayfix_nostepmoveonsteepslopes", 0)
		clear()

		-- relink touches triggers at the new position
		local calls = {}
		prog.ExecuteProgram = function(p: any, fnum: number, _msg: string)
			table.insert(calls, { fnum = fnum, self = GI("self"), other = GI("other") })
			p.xfunction = 42
		end
		m = monster({ -900, -300, 25 }, FL_ONGROUND)
		local trig = spawn(sv_phys.SOLID_TRIGGER, { -860, -300, 30 }, { -8, -8, -8 }, { 8, 8, 8 })
		setI(trig, "touch", 7)
		t.eq(ctx, sv_move.SV_movestep(m, { 10, 0, 0 }, false, false, false), true, "move without relink")
		t.eq(ctx, #calls, 0, "relink false: no touch")
		t.eq(ctx, sv_move.SV_movestep(m, { 10, 0, 0 }, true, false, true), true, "move with relink (settrace 1)")
		t.ok(ctx, #calls == 1 and calls[1].fnum == 7 and calls[1].self == trig and calls[1].other == m, "touch called")
		calls = {}

		-- 3. VM_SV_walkmove (#32)
		setV(m, "origin", { -900, -300, 25 })
		sv_phys.SV_LinkEdict(m)
		setGI("self", m)
		prog.xfunction = 5
		pF(0, 0)
		pF(1, 40)
		tr = steptrace(m, yawmove(0, 40))
		t.ok(ctx, (call("VM_SV_walkmove", 2)), "walkmove runs")
		t.eq(ctx, retF(), 1, "walkmove: 1")
		t.eq(ctx, vs(V(m, "origin")), vsR(tr.endpos), "walkmove: origin = the step trace")
		t.eq(ctx, #calls, 1, "walkmove relinks and touches")
		t.eq(ctx, prog.xfunction, 5, "walkmove: prog->xfunction restored after the touch changed it")
		t.eq(ctx, GI("self"), m, "walkmove: self restored")
		-- yaw 90: cos(float(pi/2)) is not 0
		local mv = yawmove(90, 10)
		t.ok(ctx, mv[1] ~= 0 and mv[2] == 10, "yaw 90: move x = R(cos(R(pi/2)) * 10) ~= 0")
		local before = V(m, "origin")
		tr = steptrace(m, mv)
		pF(0, 90)
		pF(1, 10)
		pF(2, 1)
		call("VM_SV_walkmove", 3)
		t.eq(ctx, retF(), 1, "walkmove with settrace: 1")
		t.eq(ctx, vs(V(m, "origin")), vsR(tr.endpos), "walkmove yaw 90")
		t.eq(ctx, V(m, "origin")[1], R(before[1] + mv[1]), "x: -860 + the cos residue, rounded to float")
		-- not on the ground / flying
		setF(m, "flags", MON)
		setRet(7)
		call("VM_SV_walkmove", 2)
		t.eq(ctx, retF(), 0, "not FL_ONGROUND / FLY / SWIM: 0")
		t.eq(ctx, vs(V(m, "origin")), vsR(tr.endpos), "not on ground: not moved")
		setF(m, "flags", FL_ONGROUND + MON)
		-- off a ledge
		setV(m, "origin", { 1000, 600, 25 })
		sv_phys.SV_LinkEdict(m)
		pF(0, 0)
		pF(1, 60)
		call("VM_SV_walkmove", 2)
		t.eq(ctx, retF(), 0, "walkmove off a ledge: 0")
		-- world / free self
		setGI("self", 0)
		setRet(7)
		call("VM_SV_walkmove", 2)
		t.eq(ctx, lastline(), "walkmove: can not modify world entity", "world: warning")
		t.eq(ctx, retF(), 0, "world: 0")
		local fr = prvm_edict.PRVM_ED_Alloc(prog)
		prvm_edict.PRVM_ED_Free(prog, fr)
		setGI("self", fr)
		call("VM_SV_walkmove", 2)
		t.eq(ctx, lastline(), "walkmove: can not modify free entity", "free: warning")
		t.ok(ctx, not (call("VM_SV_walkmove", 1)), "walkmove: parameter count checked (1)")
		t.ok(ctx, not (call("VM_SV_walkmove", 4)), "walkmove: parameter count checked (4)")
		prog.ExecuteProgram = nil
		clear()
	end

	-- 4. SV_movestep, FL_FLY / FL_SWIM
	do
		local m = monster({ 0, -600, 300 }, FL_FLY)
		local en = spawn(sv_phys.SOLID_BBOX, { 0, -900, 200 }, { -8, -8, -8 }, { 8, 8, 8 })
		setI(m, "enemy", en)
		local function fly(move: { number }, noenemy: boolean): (boolean, string)
			local ok = sv_move.SV_movestep(m, move, true, noenemy, false)
			return ok, vs(V(m, "origin"))
		end
		local ok, o = fly({ 10, 0, 0 }, false)
		t.eq(ctx, `{ok} {o}`, "true 10 -600 292", "enemy 100 below (dz > 40): 8 down")
		setV(m, "origin", { 0, -600, 300 })
		setV(en, "origin", { 0, -900, 265 })
		ok, o = fly({ 10, 0, 0 }, false)
		t.eq(ctx, `{ok} {o}`, "true 10 -600 300", "dz 35: level")
		setV(m, "origin", { 0, -600, 300 })
		setV(en, "origin", { 0, -900, 280 })
		ok, o = fly({ 10, 0, 0 }, false)
		t.eq(ctx, `{ok} {o}`, "true 10 -600 308", "dz 20 (< 30): 8 up")
		setV(m, "origin", { 0, -600, 300 })
		ok, o = fly({ 10, 0, 0 }, true)
		t.eq(ctx, `{ok} {o}`, "true 10 -600 300", "noenemy: no height adjustment")
		setV(m, "origin", { R(0.1), -600, R(300.7) })
		setV(en, "origin", { 0, -900, R(300.7) })
		ok, o = fly({ R(3.3), R(-1.1), R(0.2) }, false)
		t.eq(
			ctx,
			o,
			`{R(R(0.1) + R(3.3))} {R(-600 + R(-1.1))} {R(R(R(300.7) + R(0.2)) + 8)}`,
			"float sums (origin + move, + 8)"
		)
		t.eq(ctx, V(m, "absmin")[1], R(R(R(R(0.1) + R(3.3)) - 16) - 1), "relinked")
		-- a ceiling 4 above the head: the move 8 up is blocked, the level one is taken
		setV(m, "origin", { 0, -600, 300 })
		sv_phys.SV_LinkEdict(m)
		setV(en, "origin", { 0, -900, 290 }) -- dz 10: 8 up
		bsp({ -100, -700, 344 }, { 100, -500, 400 }, SOLID)
		ok, o = fly({ 10, 0, 0 }, false)
		t.eq(ctx, `{ok} {o}`, "true 10 -600 300", "blocked up: second try without vertical motion")
		-- a wall ahead: both tries blocked
		local wall = bsp({ 40, -700, 0 }, { 60, -500, 343 }, SOLID)
		ok, o = fly({ 30, 0, 0 }, false)
		t.eq(ctx, `{ok} {o}`, "false 10 -600 300", "blocked both ways: false, not moved")
		ok, o = fly({ 30, 0, 0 }, true)
		t.eq(ctx, `{ok} {o}`, "false 10 -600 300", "noenemy blocked: false (break after one try)")
		setI(m, "enemy", 0)
		ok, o = fly({ 30, 0, 0 }, false)
		t.eq(ctx, `{ok} {o}`, "false 10 -600 300", "enemy world blocked: false")
		world.World_UnlinkEdict(prog, wall)
		-- swimming: water bmodel (not solid for the monster mask)
		bsp({ 400, -700, 200 }, { 600, -500, 400 }, WATER)
		setF(m, "flags", FL_SWIM + MON)
		setV(m, "origin", { 500, -600, 300 })
		sv_phys.SV_LinkEdict(m)
		ok, o = fly({ 10, 0, 0 }, false)
		t.eq(ctx, `{ok} {o}`, "true 510 -600 300", "swim inside water: true")
		ok, o = fly({ 200, 0, 0 }, false)
		t.eq(ctx, `{ok} {o}`, "false 510 -600 300", "swim monster left water: false, not moved")
		setF(m, "flags", FL_FLY + MON)
		ok, o = fly({ 200, 0, 0 }, false)
		t.eq(ctx, `{ok} {o}`, "true 710 -600 300", "a flyer may leave the water")
		clear()
	end

	-- 5. SV_StepDirection (self = ent: VM_changeyaw turns self)
	do
		local m = monster({ -900, -900, R(24.03125) }, FL_ONGROUND)
		setGI("self", m)
		setF(m, "yaw_speed", 20)
		local tr = steptrace(m, yawmove(10, 10))
		t.eq(ctx, sv_move.SV_StepDirection(m, 10, 10), true, "yaw 10: true")
		t.eq(ctx, `{F(m, "ideal_yaw")} {V(m, "angles")[2]}`, "10 10", "ideal_yaw set, turned to it")
		t.eq(ctx, vs(V(m, "origin")), vsR(tr.endpos), "facing it: the step is taken")
		local o = V(m, "origin")
		-- yaw 270 at speed 20: turns 0 -> 340, delta 70 in (45, 315): the step is undone
		setV(m, "angles", { 0, 0, 0 })
		t.eq(ctx, sv_move.SV_StepDirection(m, 270, 10), true, "yaw 270: true (moved, then undone)")
		t.eq(ctx, `{F(m, "ideal_yaw")} {V(m, "angles")[2]}`, "270 340", "turned 20 the short way")
		t.eq(ctx, vs(V(m, "origin")), vs(o), "not turned far enough: origin restored")
		t.eq(ctx, V(m, "absmin")[1], R(R(o[1] - 16) - 1), "relinked")
		-- delta -70 (turning the other way) is not undone (only 45 < delta < 315)
		setV(m, "angles", { 0, 0, 0 })
		tr = steptrace(m, yawmove(90, 10))
		t.eq(ctx, sv_move.SV_StepDirection(m, 90, 10), true, "yaw 90 at speed 20: true")
		t.eq(ctx, V(m, "angles")[2], 20, "turned to 20")
		t.eq(ctx, vs(V(m, "origin")), vsR(tr.endpos), "delta -70: the step is kept (engine quirk)")
		-- blocked
		setV(m, "origin", { 1000, 600, 25 })
		setV(m, "angles", { 0, 0, 0 })
		t.eq(ctx, sv_move.SV_StepDirection(m, 0, 60), false, "off a ledge: false")
		t.eq(ctx, V(m, "absmin")[1], R(R(1000 - 16) - 1), "relinked anyway")
		clear()
	end

	-- 6. VM_SV_MoveToGoal (#67) / SV_NewChaseDir / SV_CloseEnough with glibc rand() fixed by srand
	do
		local m = monster({ -300, -300, R(24.03125) }, FL_ONGROUND)
		local goal = spawn(sv_phys.SOLID_BBOX, { -400, -400, 24 }, { -8, -8, -8 }, { 8, 8, 8 })
		setGI("self", m)
		setI(m, "goalentity", goal)
		setF(m, "yaw_speed", 360)
		local function mtg(dist: number): (boolean, any)
			pF(0, dist)
			return call("VM_SV_MoveToGoal", 1)
		end

		-- (rand() & 3) != 1: one SV_StepDirection along ideal_yaw, one rand() used
		local s = findseed(function(r)
			return bit32.band(r[1], 3) ~= 1
		end)
		setF(m, "ideal_yaw", 0)
		local tr = steptrace(m, yawmove(0, 10))
		libc.srand(s)
		t.ok(ctx, (mtg(10)), "movetogoal runs")
		t.eq(ctx, vs(V(m, "origin")), vsR(tr.endpos), "rand()&3 != 1: stepped along ideal_yaw 0")
		t.eq(ctx, F(m, "ideal_yaw"), 0, "ideal_yaw kept")
		t.eq(ctx, libc.rand(), nthrand(s, 2), "one rand() used")

		-- (rand() & 3) == 1: SV_NewChaseDir; goal at -x -y: direct route 215 (engine quirk, not 225)
		s = findseed(function(r)
			return bit32.band(r[1], 3) == 1
		end)
		setV(m, "origin", { -300, -300, R(24.03125) })
		sv_phys.SV_LinkEdict(m)
		setV(m, "angles", { 0, 0, 0 })
		tr = steptrace(m, yawmove(215, 10))
		libc.srand(s)
		mtg(10)
		t.eq(ctx, F(m, "ideal_yaw"), 215, "direct route -x -y: ideal_yaw 215")
		t.eq(ctx, V(m, "angles")[2], 215, "turned (yaw_speed 360)")
		t.eq(ctx, vs(V(m, "origin")), vsR(tr.endpos), "stepped toward 215")
		t.eq(ctx, libc.rand(), nthrand(s, 2), "the direct route uses no rand()")

		-- +x +y: 45
		setV(goal, "origin", { -200, -200, 24 })
		setV(m, "origin", { -300, -300, R(24.03125) })
		libc.srand(s)
		mtg(10)
		t.eq(ctx, F(m, "ideal_yaw"), 45, "direct route +x +y: 45")
		setV(goal, "origin", { -200, -400, 24 })
		setV(m, "origin", { -300, -300, R(24.03125) })
		libc.srand(s)
		mtg(10)
		t.eq(ctx, F(m, "ideal_yaw"), 315, "direct route +x -y: 315")

		-- only deltax: d[1] = 0; ideal_yaw 180 makes 0 the turnaround, so olddir 180 is taken
		setV(goal, "origin", { -200, -300, 24 })
		setV(m, "origin", { -300, -300, R(24.03125) })
		setF(m, "ideal_yaw", 180)
		setV(m, "angles", { 0, 180, 0 })
		libc.srand(s)
		mtg(10)
		t.eq(ctx, F(m, "ideal_yaw"), 180, "goal ahead but behind the turnaround: olddir")
		t.eq(ctx, libc.rand(), nthrand(s, 3), "rand() for the swap was used")
		clear()

		-- a bridge along x (y +-17, top 100, the floor 90 below): only 0 and 180 can be walked;
		-- goal on the monster: no direction to it; olddir 90 fails; the search order is rand() & 1
		bsp({ -200, -17, 90 }, { 200, 17, 100 }, SOLID)
		m = monster({ 0, 0, R(124.5) }, FL_ONGROUND)
		goal = spawn(sv_phys.SOLID_TRIGGER, { 0, 0, 124 }, { -8, -8, -8 }, { 8, 8, 8 }) -- (not in the way)
		setGI("self", m)
		setI(m, "goalentity", goal)
		setF(m, "yaw_speed", 360)
		for _, want in { 0, 180 } do
			s = findseed(function(r)
				return bit32.band(r[3], 1) == (if want == 0 then 1 else 0)
			end)
			setV(m, "origin", { 0, 0, R(124.5) })
			sv_phys.SV_LinkEdict(m)
			setF(m, "ideal_yaw", 90)
			setV(m, "angles", { 0, 90, 0 })
			local mv = yawmove(want, 20)
			tr = steptrace(m, mv)
			libc.srand(s)
			mtg(20)
			t.eq(ctx, F(m, "ideal_yaw"), want, `search {if want == 0 then "up from 0" else "down from 315"}`)
			t.eq(ctx, vs(V(m, "origin")), vsR(tr.endpos), `moved toward {want}`)
		end
		clear()

		-- on a 32x32 pillar (top 100, the floor 100 below), dist 40: no direction works;
		-- ideal_yaw = olddir = ANGLEMOD((int)(100 / 45) * 45) = 90, the bottom is fine
		bsp({ -16, -16, 0 }, { 16, 16, 100 }, SOLID)
		m = monster({ 0, 0, R(124.5) }, FL_ONGROUND)
		goal = spawn(sv_phys.SOLID_TRIGGER, { 500, 0, 124 }, { -8, -8, -8 }, { 8, 8, 8 })
		setGI("self", m)
		setI(m, "goalentity", goal)
		setF(m, "yaw_speed", 360)
		setF(m, "ideal_yaw", 100)
		libc.srand(s)
		mtg(40)
		t.eq(ctx, F(m, "ideal_yaw"), 90, "boxed in: ideal_yaw = olddir 90")
		t.eq(ctx, vs(V(m, "origin")), `0 0 {R(124.5)}`, "boxed in: not moved")
		t.eq(ctx, F(m, "flags"), FL_ONGROUND + MON, "bottom fine: no FL_PARTIALGROUND")
		-- negative ideal_yaw: (int) truncates toward 0, ANGLEMOD wraps: -100 -> (int)-2.2 = -2 -> -90 -> 270
		setF(m, "ideal_yaw", -100)
		libc.srand(s)
		mtg(40)
		t.eq(ctx, F(m, "ideal_yaw"), 270, "olddir of -100: 270")
		t.eq(ctx, R(mathlib.ANGLEMOD(-90)), 270, "(ANGLEMOD(-90) = 270)")
		-- in the air (the floor 100 below): SV_FixCheckBottom sets FL_PARTIALGROUND
		setV(m, "origin", { 0, 0, R(224.5) })
		sv_phys.SV_LinkEdict(m)
		libc.srand(s)
		mtg(40)
		t.eq(ctx, F(m, "flags"), FL_ONGROUND + FL_PARTIALGROUND + MON, "no valid bottom: FL_PARTIALGROUND")

		-- not on the ground: OFS_RETURN 0, nothing used
		setF(m, "flags", MON)
		setRet(7)
		libc.srand(s)
		mtg(40)
		t.eq(ctx, retF(), 0, "not on ground: returns 0")
		t.eq(ctx, libc.rand(), nthrand(s, 1), "not on ground: no rand()")
		setF(m, "flags", FL_ONGROUND + MON)

		-- SV_CloseEnough: the enemy set and the goal's area box within dist of ours: return at once
		setV(m, "origin", { 0, 0, R(124.5) })
		sv_phys.SV_LinkEdict(m)
		setV(goal, "origin", { 40, 0, 124 })
		sv_phys.SV_LinkEdict(goal)
		setI(m, "enemy", goal)
		setF(m, "ideal_yaw", 0)
		setRet(7)
		libc.srand(s)
		mtg(10)
		-- areamaxs x of m = 0 + 16 + 1, areamins x of goal = 40 - 8 - 1: 31 > 17 + 10 -> not close
		t.ok(ctx, libc.rand() ~= nthrand(s, 1), "31 > 17 + 10: not close, rand() used")
		t.eq(ctx, sv_move.SV_CloseEnough(m, goal, 10), false, "SV_CloseEnough dist 10: false")
		t.eq(ctx, sv_move.SV_CloseEnough(m, goal, 14), true, "SV_CloseEnough dist 14 (31 <= 31): true")
		setV(m, "origin", { 0, 0, R(124.5) })
		sv_phys.SV_LinkEdict(m)
		libc.srand(s)
		mtg(14)
		t.eq(ctx, libc.rand(), nthrand(s, 1), "close enough: no rand()")
		t.eq(ctx, retF(), 7, "close enough: OFS_RETURN untouched (C)")
		t.eq(ctx, vs(V(m, "origin")), `0 0 {R(124.5)}`, "close enough: not moved")
		t.ok(ctx, not (call("VM_SV_MoveToGoal", 2)), "movetogoal: parameter count checked")
		clear()
	end

	t.eq(ctx, svvm_cmds.PORTED.VM_SV_MoveToGoal ~= nil, true, "movetogoal registered")

	prog.ExecuteProgram = nil
	sv.worldmodel = nil
	sv.models = {}
	sv.world = world.new()
	cvar.prvm_prog_list[0] = nil
	console.sink = oldsink
	cvar.reset()
end
