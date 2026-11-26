--!strict
-- Server builtins on the world / trace code (engine/svvm_cmds.luau: setorigin, setsize, traceline, tracebox,
-- pointcontents, droptofloor, findradius, copyentity; engine/prvm_cmds.luau VM_SetTraceGlobals) and the
-- sv_main.c edict hooks (SVVM_free_edict, SVVM_begin / end_increase_edicts) against the C rules
-- (svvm_cmds.c / prvm_cmds.c / sv_main.c @xonotic-v0.8.6), on a synthetic server prog and box models as in
-- tests/unit/sv_phys.test.luau. Not a differential test against the C build: there are no C vectors yet.
local t = require("../_lib/t")
local collision = require("../../engine/collision")
local console = require("../../engine/console")
local cvar = require("../../engine/cvar")
local f32 = require("../../engine/_port/f32")
local prvm_cmds = require("../../engine/prvm_cmds")
local prvm_edict = require("../../engine/prvm_edict")
local server = require("../../engine/server")
local sv_phys = require("../../engine/sv_phys")
local sv_main = require("../../engine/sv_main")
local svvm_cmds = require("../../engine/svvm_cmds")
local world = require("../../engine/world")
require("../../engine/model_brush") -- sets collision.Collision_ClipTrace_Box / _Point

local R = f32.round
local SOLID, WATER, SLIME, LAVA, SKY, BODY, CORPSE = 0x1, 0x2, 0x4, 0x8, 0x10, 0x20, 0x40
local B = svvm_cmds.PORTED
local OFS_RETURN, OFS_PARM0 = 1, 4

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

return function(ctx: t.Ctx)
	local oldsink = console.sink
	local lines: { string } = {}
	console.sink = function(line: string)
		table.insert(lines, line)
	end
	cvar.reset()
	collision.Collision_Init()

	-- server prog: one slot per float, three per vector
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
		{ "mychain", 1 },
		{ "groundentity", 1 },
		{ "nextthink", 1 },
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
	prog.max_edicts = 64
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
	-- globals
	local function GO(g: string): number
		return prog.globalofs_cache[g]
	end
	local function GI(g: string): number
		return buffer.readi32(prog.globals, GO(g) * 4)
	end
	local function GF(g: string): number
		return buffer.readf32(prog.globals, GO(g) * 4)
	end
	local function GV(g: string): { number }
		local o = GO(g) * 4
		return {
			buffer.readf32(prog.globals, o),
			buffer.readf32(prog.globals, o + 4),
			buffer.readf32(prog.globals, o + 8),
		}
	end
	local function setGI(g: string, v: number)
		buffer.writei32(prog.globals, GO(g) * 4, v)
	end
	-- builtin parameters (OFS_PARM0 + 3 * i)
	local function pV(i: number, v: { number })
		local o = (OFS_PARM0 + 3 * i) * 4
		buffer.writef32(prog.globals, o, v[1])
		buffer.writef32(prog.globals, o + 4, v[2])
		buffer.writef32(prog.globals, o + 8, v[3])
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
	local function retI(): number
		return buffer.readi32(prog.globals, OFS_RETURN * 4)
	end
	local function call(name: string, argc: number): (boolean, any)
		prog.argc = argc
		return pcall(B[name], prog)
	end
	local function lastline(): string
		return lines[#lines] or ""
	end
	local function inbox(e: number, mins: { number }, maxs: { number }): boolean
		local list: { number } = {}
		local cnt = sv_phys.SV_EntitiesInBox(mins, maxs, 64, list)
		for k = 1, cnt do
			if list[k] == e then
				return true
			end
		end
		return false
	end

	-- the server: a floor slab as the world model, the area grid over +-4096
	local sv = server.sv
	sv.world = world.new()
	sv.models = {}
	sv.time = 3.5
	world.World_SetSize(sv.world, "maps/test.bsp", { -4096, -4096, -4096 }, { 4096, 4096, 4096 }, prog)
	sv.worldmodel = boxmodel({ -1024, -1024, -64 }, { 1024, 1024, 0 }, SOLID)
	sv.models[1] = sv.worldmodel
	sv.models[2] = boxmodel({ -32, -32, -32 }, { 32, 32, 32 }, bit32.bor(SOLID, WATER))
	sv.models[3] = boxmodel({ -32, -32, -32 }, { 32, 32, 32 }, WATER)
	sv.models[4] = boxmodel({ -32, -32, -32 }, { 32, 32, 32 }, SLIME)

	local function spawn(solid: number, origin: { number }, mins: { number }, maxs: { number }): number
		local e = prvm_edict.PRVM_ED_Alloc(prog)
		setF(e, "solid", solid)
		setV(e, "origin", origin)
		setV(e, "mins", mins)
		setV(e, "maxs", maxs)
		sv_phys.SV_LinkEdict(e)
		return e
	end

	-- 1. VM_SetTraceGlobals: every trace_t field into its global (prvm_cmds.c L5998-6013)
	do
		local tr = collision.newtrace()
		tr.allsolid, tr.startsolid, tr.inwater, tr.inopen = true, false, true, false
		tr.fraction = 0.1 -- double
		tr.endpos = { 1 / 3, -2 / 3, 1e10 + 0.5 }
		tr.plane.normal = { 0.6, 0, 0.8 }
		tr.plane.dist = 12.3456789
		tr.ent = nil
		tr.startsupercontents, tr.hitsupercontents, tr.hitq3surfaceflags = WATER, bit32.bor(SOLID, BODY), 0x40
		tr.hittexture = { name = "textures/common/caulk" }
		prvm_cmds.VM_SetTraceGlobals(prog, tr)
		t.eq(ctx, GF("trace_allsolid") .. " " .. GF("trace_startsolid"), "1 0", "allsolid / startsolid as 1 / 0")
		t.eq(ctx, GF("trace_inwater") .. " " .. GF("trace_inopen"), "1 0", "inwater / inopen as 1 / 0")
		t.eq(ctx, GF("trace_fraction"), R(0.1), "fraction (double) stored as float")
		t.eq(ctx, vs(GV("trace_endpos")), `{R(1 / 3)} {R(-2 / 3)} {R(1e10 + 0.5)}`, "endpos (double) stored as float")
		t.eq(ctx, vs(GV("trace_plane_normal")), `{R(0.6)} 0 {R(0.8)}`, "plane normal")
		t.eq(ctx, GF("trace_plane_dist"), R(12.3456789), "plane dist")
		t.eq(ctx, GI("trace_ent"), 0, "trace.ent NULL -> world")
		t.eq(ctx, GF("trace_dpstartcontents"), WATER, "dpstartcontents")
		t.eq(ctx, GF("trace_dphitcontents"), bit32.bor(SOLID, BODY), "dphitcontents")
		t.eq(ctx, GF("trace_dphitq3surfaceflags"), 0x40, "dphitq3surfaceflags")
		t.eq(
			ctx,
			prvm_edict.PRVM_GetString(prog, GI("trace_dphittexturename")),
			"textures/common/caulk",
			"dphittexturename: temp string of the texture name"
		)
		tr.hittexture = nil
		tr.ent = 5
		prvm_cmds.VM_SetTraceGlobals(prog, tr)
		t.eq(ctx, GI("trace_dphittexturename"), 0, "no texture: string 0")
		t.eq(ctx, GI("trace_ent"), 5, "trace.ent edict")
	end

	-- 2. setorigin (#2)
	local mins1, maxs1 = { -16, -16, -24 }, { 16, 16, 45 }
	local e1 = spawn(sv_phys.SOLID_SLIDEBOX, { 0, 0, 500 }, mins1, maxs1)
	do
		local o = { R(100.3), R(-7.7), R(200.1) }
		pI(0, e1)
		pV(1, o)
		prog.ed_mark = { [e1] = -1 }
		local ok = call("VM_SV_setorigin", 2)
		t.ok(ctx, ok, "setorigin runs")
		t.eq(ctx, vs(V(e1, "origin")), vs(o), "origin = parm1")
		local wmin = { R(R(o[1] - 16) - 1), R(R(o[2] - 16) - 1), R(R(o[3] - 24) - 1) }
		local wmax = { R(R(o[1] + 16) + 1), R(R(o[2] + 16) + 1), R(R(o[3] + 45) + 1) }
		t.eq(ctx, vs(V(e1, "absmin")), vs(wmin), "relinked: absmin")
		t.eq(ctx, vs(V(e1, "absmax")), vs(wmax), "relinked: absmax")
		t.ok(ctx, inbox(e1, { 99, -8, 199 }, { 101, -7, 201 }), "found in the area grid at the new origin")
		t.ok(ctx, not inbox(e1, { -1, -1, 499 }, { 1, 1, 501 }), "not at the old one")
		t.eq(ctx, prog.ed_mark[e1], -2, "mark WAIT_FOR_SETORIGIN -> SETORIGIN_CAUGHT")
		prog.ed_mark[e1] = 0
		call("VM_SV_setorigin", 2)
		t.eq(ctx, prog.ed_mark[e1], 0, "other marks unchanged")
		pI(0, 0)
		pV(1, { 1, 2, 3 })
		call("VM_SV_setorigin", 2)
		t.eq(ctx, lastline(), "setorigin: can not modify world entity", "world: warning")
		t.eq(ctx, vs(V(0, "origin")), "0 0 0", "world unchanged")
		t.ok(ctx, not (call("VM_SV_setorigin", 3)), "parameter count checked")
	end

	-- 3. setsize (#4) / SetMinMaxSize
	do
		local mn, mx = { R(-16.1), R(-0.3), R(-24.7) }, { R(16.2), R(0.1), R(45.9) }
		pI(0, e1)
		pV(1, mn)
		pV(2, mx)
		t.ok(ctx, (call("VM_SV_setsize", 3)), "setsize runs")
		t.eq(ctx, vs(V(e1, "mins")), vs(mn), "mins")
		t.eq(ctx, vs(V(e1, "maxs")), vs(mx), "maxs")
		t.eq(
			ctx,
			vs(V(e1, "size")),
			`{R(mx[1] - mn[1])} {R(mx[2] - mn[2])} {R(mx[3] - mn[3])}`,
			"size = max - min (float)"
		)
		local o = V(e1, "origin")
		t.eq(
			ctx,
			vs(V(e1, "absmin")),
			`{R(R(o[1] + mn[1]) - 1)} {R(R(o[2] + mn[2]) - 1)} {R(R(o[3] + mn[3]) - 1)}`,
			"relinked with the new size"
		)
		pV(1, { 0, 5, 0 })
		pV(2, { 1, 4, 1 })
		local ok, err = call("VM_SV_setsize", 3)
		t.ok(
			ctx,
			not ok and string.find(tostring(err), "SetMinMaxSize: backwards mins/maxs", 1, true) ~= nil,
			"backwards"
		)
		t.eq(ctx, vs(V(e1, "mins")), vs(mn), "backwards: unchanged")
		pI(0, 0)
		call("VM_SV_setsize", 3)
		t.eq(ctx, lastline(), "setsize: can not modify world entity", "world: warning")
		local fr = prvm_edict.PRVM_ED_Alloc(prog)
		prvm_edict.PRVM_ED_Free(prog, fr)
		pI(0, fr)
		call("VM_SV_setsize", 3)
		t.eq(ctx, lastline(), "setsize: can not modify free entity", "free: warning")
		pV(1, mins1)
		pV(2, maxs1)
		pI(0, e1)
		call("VM_SV_setsize", 3)
	end

	-- 4. traceline (#16) / tracebox (#90): the globals equal SV_TraceLine / SV_TraceBox with the builtin's
	-- mask and extend length
	local function checkglobals(tr: collision.trace_t, what: string)
		local p = tr.plane.normal
		t.eq(
			ctx,
			`{GF("trace_allsolid")} {GF("trace_startsolid")} {GF("trace_fraction")} {GF("trace_inwater")} {GF(
				"trace_inopen"
			)}`,
			`{if tr.allsolid then 1 else 0} {if tr.startsolid then 1 else 0} {R(tr.fraction)} {if tr.inwater
				then 1
				else 0} {if tr.inopen then 1 else 0}`,
			what .. ": solid / fraction / water / open"
		)
		t.eq(ctx, vs(GV("trace_endpos")), vs({ R(tr.endpos[1]), R(tr.endpos[2]), R(tr.endpos[3]) }), what .. ": endpos")
		t.eq(ctx, vs(GV("trace_plane_normal")), vs({ R(p[1]), R(p[2]), R(p[3]) }), what .. ": plane normal")
		t.eq(ctx, GF("trace_plane_dist"), R(tr.plane.dist), what .. ": plane dist")
		t.eq(ctx, GI("trace_ent"), tr.ent or 0, what .. ": trace_ent")
		t.eq(
			ctx,
			`{GF("trace_dpstartcontents")} {GF("trace_dphitcontents")} {GF("trace_dphitq3surfaceflags")} {GI(
				"trace_dphittexturename"
			)}`,
			`{tr.startsupercontents} {tr.hitsupercontents} {tr.hitq3surfaceflags} 0`,
			what .. ": contents / flags / texture"
		)
	end
	local target = spawn(sv_phys.SOLID_BBOX, { R(300.25), 0, 100 }, { -16, -16, -16 }, { 16, 16, 16 })
	local shooter = spawn(sv_phys.SOLID_SLIDEBOX, { 0, 0, 100 }, mins1, maxs1)
	local extline = collision.cv.collision_extendtracelinelength.value
	local extbox = collision.cv.collision_extendtraceboxlength.value
	t.eq(ctx, extline .. " " .. extbox, "1 1", "collision_extendtraceline / boxlength defaults")
	do
		local cases = {
			{ { 0, 0, 100 }, { 600, 0, 100 }, 0, shooter, "hits the bbox, ignoring the shooter" },
			{ { 0, 0, 100 }, { 600, 0, 100 }, 0, 0, "ignore = world: the shooter itself is hit (startsolid)" },
			{ { 0, R(0.3), 100 }, { R(50.7), R(-0.1), -100 }, 0, shooter, "hits the floor" },
			{ { 0, 0, 100 }, { 0, 600, 100 }, 0, shooter, "misses" },
			{ { 0, 0, 100 }, { 600, 0, 100 }, sv_phys.MOVE_NOMONSTERS, shooter, "MOVE_NOMONSTERS" },
			{ { 0, 0, 100 }, { 600, 0, 100 }, sv_phys.MOVE_WORLDONLY, shooter, "MOVE_WORLDONLY" },
			{ { 0, 0, 100 }, { 0, 0, 100 }, 0, shooter, "zero length (TracePoint)" },
		}
		for _, c in cases do
			pV(0, c[1])
			pV(1, c[2])
			pF(2, c[3])
			pI(3, c[4])
			t.ok(ctx, (call("VM_SV_traceline", 4)), "traceline runs: " .. c[5])
			local ref = sv_phys.SV_TraceLine(
				c[1],
				c[2],
				c[3],
				c[4],
				sv_phys.SV_GenericHitSuperContentsMask(c[4]),
				0,
				0,
				extline
			)
			checkglobals(ref, "traceline " .. c[5])
		end
		-- the hit itself
		pV(0, { 0, 0, 100 })
		pV(1, { 600, 0, 100 })
		pF(2, 0)
		pI(3, shooter)
		call("VM_SV_traceline", 4)
		t.ok(ctx, GI("trace_ent") == target and GF("trace_fraction") < 1, "trace_ent = the bbox entity")
		t.eq(ctx, vs(GV("trace_plane_normal")), "-1 0 0", "its face normal")
		pV(1, { 0, 600, 100 })
		call("VM_SV_traceline", 4)
		t.ok(ctx, GI("trace_ent") == 0 and GF("trace_fraction") == 1, "miss: trace_ent world, fraction 1")
		t.ok(ctx, (call("VM_SV_traceline", 8)), "up to 8 parameters")
		t.ok(ctx, not (call("VM_SV_traceline", 3)), "fewer than 4: error")
		pV(1, { 0, 0 / 0, 100 })
		local ok, err = call("VM_SV_traceline", 4)
		t.ok(ctx, not ok and string.find(tostring(err), "NAN errors detected in traceline", 1, true) ~= nil, "NaN")

		local bmin, bmax = { -8, -8, -8 }, { 8, 8, 8 }
		local bcases = {
			{ { 0, 0, 100 }, { 600, 0, 100 }, 0, shooter, "hits the bbox" },
			{ { 0, R(0.3), 100 }, { R(50.7), R(-0.1), -100 }, 0, shooter, "hits the floor" },
			{ { 0, 0, 4 }, { 0, 0, 50 }, 0, shooter, "starts in the floor" },
			{ { 0, 0, 100 }, { 0, 600, 100 }, 0, shooter, "misses" },
		}
		for _, c in bcases do
			pV(0, c[1])
			pV(1, bmin)
			pV(2, bmax)
			pV(3, c[2])
			pF(4, c[3])
			pI(5, c[4])
			t.ok(ctx, (call("VM_SV_tracebox", 6)), "tracebox runs: " .. c[5])
			local ref = sv_phys.SV_TraceBox(
				c[1],
				bmin,
				bmax,
				c[2],
				c[3],
				c[4],
				sv_phys.SV_GenericHitSuperContentsMask(c[4]),
				0,
				0,
				extbox
			)
			checkglobals(ref, "tracebox " .. c[5])
		end
		pV(0, { 0, 0, 4 })
		pV(3, { 0, 0, 50 })
		call("VM_SV_tracebox", 6)
		t.eq(ctx, GF("trace_startsolid") .. " " .. GI("trace_ent"), "1 0", "tracebox starting in the floor")
		t.ok(ctx, not (call("VM_SV_tracebox", 5)), "fewer than 6: error")
		pV(3, { 0 / 0, 0, 0 })
		ok, err = call("VM_SV_tracebox", 6)
		t.ok(ctx, not ok and string.find(tostring(err), "NAN errors detected in tracebox", 1, true) ~= nil, "NaN")
	end

	-- 5. pointcontents (#41): SV_PointSuperContents through Mod_Q1BSP_NativeContentsFromSuperContents
	do
		local N = svvm_cmds.Mod_Q1BSP_NativeContentsFromSuperContents
		t.eq(
			ctx,
			`{N(0)} {N(SOLID)} {N(BODY)} {N(WATER)} {N(SLIME)} {N(LAVA)} {N(SKY)} {N(CORPSE)}`,
			"-1 -2 -2 -3 -4 -5 -6 -1",
			"native contents of each supercontents bit"
		)
		t.eq(
			ctx,
			`{N(bit32.bor(SKY, LAVA))} {N(bit32.bor(LAVA, SLIME, WATER))} {N(bit32.bor(SLIME, WATER))} {N(
				bit32.bor(WATER, SOLID)
			)}`,
			"-6 -5 -4 -2",
			"priority: solid/body, sky, lava, slime, water"
		)
		local w = prvm_edict.PRVM_ED_Alloc(prog)
		setF(w, "solid", sv_phys.SOLID_BSP)
		setF(w, "modelindex", 3)
		setV(w, "origin", { -600, 0, 100 })
		sv_phys.SV_LinkEdict(w)
		local s = prvm_edict.PRVM_ED_Alloc(prog)
		setF(s, "solid", sv_phys.SOLID_BSP)
		setF(s, "modelindex", 4)
		setV(s, "origin", { -600, 300, 100 })
		sv_phys.SV_LinkEdict(s)
		local function pc(p: { number }): number
			pV(0, p)
			call("VM_SV_pointcontents", 1)
			return retF()
		end
		t.eq(ctx, pc({ 10, 10, -10 }), -2, "in the world slab: CONTENTS_SOLID")
		t.eq(ctx, pc({ 10, 10, 10 }), -1, "empty: CONTENTS_EMPTY")
		t.eq(ctx, pc({ -600, 0, 100 }), -3, "in the water bmodel: CONTENTS_WATER")
		t.eq(ctx, pc({ -600, 300, 100 }), -4, "in the slime bmodel: CONTENTS_SLIME")
		t.eq(ctx, pc({ 300, 0, 100 }), -1, "bbox entities do not count")
		t.ok(ctx, not (call("VM_SV_pointcontents", 2)), "parameter count checked")
		world.World_UnlinkEdict(prog, w)
		world.World_UnlinkEdict(prog, s)
	end

	-- 6. droptofloor (#34)
	cvar.Cvar_RegisterVariable(cvar.static(0, "sv_gameplayfix_droptofloorstartsolid", "1", ""))
	cvar.Cvar_RegisterVariable(cvar.static(0, "sv_gameplayfix_droptofloorstartsolid_nudgetocorrect", "1", ""))
	-- SV_NudgeOutOfSolid is not ported yet: test the paths without it
	cvar.Cvar_SetValue("sv_gameplayfix_droptofloorstartsolid_nudgetocorrect", 0)
	local extmove = collision.cv.collision_extendmovelength.value
	local function drop(e: number): number
		setGI("self", e)
		local ok = call("VM_SV_droptofloor", 0)
		t.ok(ctx, ok, "droptofloor runs")
		return retF()
	end
	world.World_UnlinkEdict(prog, e1)
	world.World_UnlinkEdict(prog, target)
	world.World_UnlinkEdict(prog, shooter)
	do
		-- falls onto the floor
		local d = spawn(sv_phys.SOLID_TRIGGER, { R(10.5), R(-3.25), R(80.3) }, mins1, maxs1)
		setF(d, "flags", 8)
		setI(d, "groundentity", 77)
		local o = V(d, "origin")
		local ref = sv_phys.SV_TraceBox(
			o,
			mins1,
			maxs1,
			{ o[1], o[2], R(o[3] - 256) },
			sv_phys.MOVE_NORMAL,
			d,
			sv_phys.SV_GenericHitSuperContentsMask(d),
			0,
			0,
			extmove
		)
		buffer.writef32(prog.globals, OFS_RETURN * 4, 5)
		t.eq(ctx, drop(d), 1, "lands: returns 1")
		t.eq(ctx, vs(V(d, "origin")), vs({ R(ref.endpos[1]), R(ref.endpos[2]), R(ref.endpos[3]) }), "origin = endpos")
		t.ok(ctx, math.abs(V(d, "origin")[3] - 24) < 0.1, "standing on the floor")
		t.eq(ctx, F(d, "flags"), 8 + 512, "FL_ONGROUND added, other flags kept")
		t.eq(ctx, I(d, "groundentity"), 0, "groundentity = world")
		t.ok(ctx, prog.ed_suspendedinairflag and prog.ed_suspendedinairflag[d] == true, "suspendedinairflag set")
		local no = V(d, "origin")
		t.eq(
			ctx,
			vs(V(d, "absmin")),
			vs({ R(R(no[1] - 16) - 1), R(R(no[2] - 16) - 1), R(R(no[3] - 24) - 1) }),
			"relinked"
		)

		-- standing on another entity
		local box = spawn(sv_phys.SOLID_BBOX, { 2000, 0, 50 }, { -32, -32, -32 }, { 32, 32, 32 })
		local d2 = spawn(sv_phys.SOLID_TRIGGER, { 2000, 0, 200 }, mins1, maxs1)
		t.eq(ctx, drop(d2), 1, "lands on the box")
		t.eq(ctx, I(d2, "groundentity"), box, "groundentity = the box")
		t.ok(ctx, math.abs(V(d2, "origin")[3] - (82 + 24)) < 0.1, "on top of the box")

		-- more than 256 units above anything: stays
		local d3 = spawn(sv_phys.SOLID_TRIGGER, { -2000, -2000, 400 }, mins1, maxs1)
		setI(d3, "groundentity", 77)
		t.eq(ctx, drop(d3), 0, "too high: returns 0")
		t.eq(ctx, vs(V(d3, "origin")), "-2000 -2000 400", "origin unchanged")
		t.eq(ctx, F(d3, "flags") .. " " .. I(d3, "groundentity"), "0 77", "flags / groundentity unchanged")

		-- start solid, sv_gameplayfix_droptofloorstartsolid 0 (Xonotic's xonotic-server.cfg): the plain branch,
		-- which moves only when the box trace is not allsolid and fraction < 1
		cvar.Cvar_SetValue("sv_gameplayfix_droptofloorstartsolid", 0)
		local d4a = spawn(sv_phys.SOLID_TRIGGER, { -500, 500, 10 }, mins1, maxs1)
		setI(d4a, "groundentity", 77)
		local o4 = V(d4a, "origin")
		local ref4 = sv_phys.SV_TraceBox(
			o4,
			mins1,
			maxs1,
			{ o4[1], o4[2], R(o4[3] - 256) },
			sv_phys.MOVE_NORMAL,
			d4a,
			sv_phys.SV_GenericHitSuperContentsMask(d4a),
			0,
			0,
			extmove
		)
		t.ok(ctx, ref4.startsolid, "the box starts in the floor")
		local moves = not ref4.allsolid and ref4.fraction < 1
		t.eq(ctx, drop(d4a), if moves then 1 else 0, "startsolid without the fix: plain branch result")
		t.eq(
			ctx,
			vs(V(d4a, "origin")) .. " " .. F(d4a, "flags"),
			if moves then vs({ R(ref4.endpos[1]), R(ref4.endpos[2]), R(ref4.endpos[3]) }) .. " 512" else "-500 500 10 0",
			"startsolid without the fix: origin / flags"
		)
		world.World_UnlinkEdict(prog, d4a)
		-- with the fix: the line from the bottom centre starts in the floor -> could not fix, but on ground
		cvar.Cvar_SetValue("sv_gameplayfix_droptofloorstartsolid", 1)
		local d4 = spawn(sv_phys.SOLID_TRIGGER, { -500, 500, 10 }, mins1, maxs1)
		setI(d4, "groundentity", 77)
		t.eq(ctx, drop(d4), 1, "startsolid, bottom centre in solid: returns 1")
		t.eq(ctx, vs(V(d4, "origin")), "-500 500 10", "origin unchanged")
		t.eq(ctx, F(d4, "flags") .. " " .. I(d4, "groundentity"), "512 0", "FL_ONGROUND, groundentity world")
		t.ok(ctx, not prog.ed_suspendedinairflag[d4], "no suspendedinairflag")

		-- with the fix: box stuck in a pillar beside it, bottom centre free -> moved down onto the floor
		local pillar = spawn(sv_phys.SOLID_BBOX, { 1040, 1000, 50 }, { -16, -16, -16 }, { 16, 16, 16 })
		local mn, mx = { -30, -20, -24 }, { 30, 40, 30 }
		local d5 = spawn(sv_phys.SOLID_TRIGGER, { 1000, 1000, 60 }, mn, mx)
		local o5 = V(d5, "origin")
		local end5 = { o5[1], o5[2], R(o5[3] - 256) }
		local boxtr =
			sv_phys.SV_TraceBox(o5, mn, mx, end5, 0, d5, sv_phys.SV_GenericHitSuperContentsMask(d5), 0, 0, extmove)
		-- (trace.ent stays the world: Collision_CombineTraces only takes the startsolid entity at fraction 1)
		t.ok(ctx, boxtr.startsolid and pillar ~= 0, "the box trace starts in the pillar")
		local offset = { R(0.5 * R(mn[1] + mx[1])), R(0.5 * R(mn[2] + mx[2])), mn[3] }
		local org = { R(o5[1] + offset[1]), R(o5[2] + offset[2]), R(o5[3] + offset[3]) }
		local ltr = sv_phys.SV_TraceLine(org, end5, 0, d5, sv_phys.SV_GenericHitSuperContentsMask(d5), 0, 0, extmove)
		local want = {
			R(ltr.endpos[1] - offset[1]),
			R(ltr.endpos[2] - offset[2]),
			R(ltr.endpos[3] - offset[3]),
		}
		t.eq(ctx, drop(d5), 1, "fixed badly placed entity: returns 1")
		t.eq(ctx, vs(V(d5, "origin")), vs(want), "origin = line endpos - offset (offset y = 10)")
		-- engine quirk: the line runs from origin + offset to the un-offset end, so it is slanted by offset
		-- and the entity moves sideways by fraction * -offset
		t.ok(ctx, math.abs(want[3] - 24) < 0.1 and want[1] == 1000, "on the floor, x unchanged")
		t.ok(
			ctx,
			want[2] < 1000 and math.abs(want[2] - (1000 - ltr.fraction * 10)) < 1e-3,
			"y moved by fraction * -offset (C quirk)"
		)
		t.eq(ctx, F(d5, "flags") .. " " .. I(d5, "groundentity"), "512 0", "FL_ONGROUND, groundentity world")
		t.ok(ctx, prog.ed_suspendedinairflag[d5] == true, "suspendedinairflag set")
		world.World_UnlinkEdict(prog, pillar)

		-- world / free
		setGI("self", 0)
		call("VM_SV_droptofloor", 0)
		t.eq(ctx, lastline(), "droptofloor: can not modify world entity", "world: warning")
		t.eq(ctx, retF(), 0, "world: returns 0")
		t.ok(ctx, (call("VM_SV_droptofloor", 2)), "2 parameters allowed")
		t.ok(ctx, not (call("VM_SV_droptofloor", 3)), "3: error")
		for _, e in { d, d2, d3, d4, d5, box } do
			world.World_UnlinkEdict(prog, e)
		end
	end

	-- 7. findradius (#22): chain in reverse SV_EntitiesInBox order through .chain (or the given field)
	do
		local c = { -3000, 3000, 100 }
		local a = spawn(sv_phys.SOLID_BBOX, { -3000 + 50, 3000, 100 }, { -8, -8, -8 }, { 8, 8, 8 })
		local b = spawn(sv_phys.SOLID_NOT, { -3000, 3000 - 60, 100 }, { -8, -8, -8 }, { 8, 8, 8 })
		local far = spawn(sv_phys.SOLID_BBOX, { -3000, 3000 + 105, 100 }, { -8, -8, -8 }, { 8, 8, 8 })
		-- big: centre 150 away, its box reaches to 30 from c
		local big = spawn(sv_phys.SOLID_BSP, { -3000 + 150, 3000, 100 }, { -120, -8, -8 }, { 120, 8, 8 })
		local out = spawn(sv_phys.SOLID_BBOX, { -3000, 3000 + 400, 100 }, { -8, -8, -8 }, { 8, 8, 8 })
		local function chainof(field: string): { number }
			local r = {}
			local e = retI()
			while e ~= 0 and #r < 20 do
				table.insert(r, e)
				e = I(e, field)
			end
			return r
		end
		local function boxorder(radius: number): { number }
			local r1 = R(radius + 1)
			local l: { number } = {}
			local cnt = sv_phys.SV_EntitiesInBox(
				{ R(c[1] - r1), R(c[2] - r1), R(c[3] - r1) },
				{ R(c[1] + r1), R(c[2] + r1), R(c[3] + r1) },
				64,
				l
			)
			local res = {}
			for k = 1, cnt do
				res[k] = l[k]
			end
			return res
		end
		local function expect(order: { number }, keep: { [number]: boolean }): string
			local r = {}
			for k = #order, 1, -1 do
				if keep[order[k]] then
					table.insert(r, order[k])
				end
			end
			return table.concat(r, " ")
		end
		pV(0, c)
		pF(1, 100)
		t.ok(ctx, (call("VM_SV_findradius", 2)), "findradius runs")
		local order = boxorder(100)
		t.eq(
			ctx,
			table.concat(chainof("chain"), " "),
			expect(order, { [a] = true, [b] = true, [far] = true, [big] = true }),
			"distance to box: a, b (SOLID_NOT), far (box 97 away) and the big box, reverse box order"
		)
		t.ok(ctx, #order >= 4, "the box query found them")
		t.eq(ctx, I(chainof("chain")[#chainof("chain")], "chain"), 0, "the chain ends in the world")
		cvar.Cvar_RegisterVariable(cvar.static(0, "sv_gameplayfix_blowupfallenzombies", "1", ""))
		cvar.Cvar_RegisterVariable(cvar.static(0, "sv_gameplayfix_findradiusdistancetobox", "1", ""))
		cvar.Cvar_SetValue("sv_gameplayfix_blowupfallenzombies", 0)
		call("VM_SV_findradius", 2)
		t.eq(
			ctx,
			table.concat(chainof("chain"), " "),
			expect(order, { [a] = true, [far] = true, [big] = true }),
			"blowupfallenzombies 0: SOLID_NOT skipped"
		)
		cvar.Cvar_SetValue("sv_gameplayfix_blowupfallenzombies", 1)
		cvar.Cvar_SetValue("sv_gameplayfix_findradiusdistancetobox", 0)
		call("VM_SV_findradius", 2)
		t.eq(
			ctx,
			table.concat(chainof("chain"), " "),
			expect(order, { [a] = true, [b] = true }),
			"findradiusdistancetobox 0: distance to the box centre, far and the big box are out"
		)
		cvar.Cvar_SetValue("sv_gameplayfix_findradiusdistancetobox", 1)
		-- the radius is strict (< radius2): far's box nearest point is 97 away
		pF(1, 97)
		call("VM_SV_findradius", 2)
		t.ok(ctx, not table.find(chainof("chain"), far), "97: boundary not included")
		pF(1, R(97.01))
		call("VM_SV_findradius", 2)
		t.ok(ctx, table.find(chainof("chain"), far) ~= nil, "97.01: included")
		-- the chain field parameter
		pF(1, 100)
		pI(2, OF("mychain"))
		setI(a, "chain", 1234)
		t.ok(ctx, (call("VM_SV_findradius", 3)), "findradius with a chain field")
		t.eq(
			ctx,
			table.concat(chainof("mychain"), " "),
			expect(order, { [a] = true, [b] = true, [far] = true, [big] = true }),
			"mychain"
		)
		t.eq(ctx, I(a, "chain"), 1234, ".chain untouched")
		pI(2, -1)
		local ok, err = call("VM_SV_findradius", 3)
		t.ok(
			ctx,
			not ok and string.find(tostring(err), "doesnt have the specified chain field", 1, true) ~= nil,
			"bad field"
		)
		pF(1, 10)
		call("VM_SV_findradius", 2)
		t.eq(ctx, retI(), 0, "nothing in range: world")
		t.ok(ctx, not (call("VM_SV_findradius", 1)), "parameter count checked")
		t.ok(ctx, out ~= 0)
		for _, e in { a, b, far, big, out } do
			world.World_UnlinkEdict(prog, e)
		end
	end

	-- 8. the wired stubs: copyentity relinks, SVVM_free_edict unlinks, begin / end_increase_edicts
	do
		local src = spawn(sv_phys.SOLID_BBOX, { -3500, -3500, 100 }, { -8, -8, -8 }, { 8, 8, 8 })
		local dst = prvm_edict.PRVM_ED_Alloc(prog)
		pI(0, src)
		pI(1, dst)
		t.ok(ctx, (call("VM_SV_copyentity", 2)), "copyentity runs")
		t.eq(ctx, vs(V(dst, "origin")), "-3500 -3500 100", "fields copied")
		t.ok(ctx, inbox(dst, { -3501, -3501, 99 }, { -3499, -3499, 101 }), "copyentity: the copy is linked")
		world.World_UnlinkEdict(prog, src)
		prog.free_edict = sv_main.SVVM_free_edict
		prvm_edict.PRVM_ED_Free(prog, dst)
		t.ok(ctx, not inbox(dst, { -3501, -3501, 99 }, { -3499, -3499, 101 }), "SVVM_free_edict unlinks")
		t.eq(
			ctx,
			F(dst, "solid") .. " " .. F(dst, "nextthink") .. " " .. vs(V(dst, "origin")),
			"0 -1 0 0 0",
			"and clears"
		)
		prog.free_edict = nil

		-- end_increase_edicts relinks edicts 1 .. num_edicts - 2 (C pointer quirk: ent = edict i - 1)
		local p1 = spawn(sv_phys.SOLID_BBOX, { 3500, -3500, 100 }, { -8, -8, -8 }, { 8, 8, 8 })
		local plast = spawn(sv_phys.SOLID_BBOX, { 3500, -3400, 100 }, { -8, -8, -8 }, { 8, 8, 8 })
		t.eq(ctx, plast, prog.num_edicts - 1, "plast is the last edict")
		sv_main.SVVM_begin_increase_edicts(prog)
		t.ok(ctx, not inbox(p1, { 3499, -3501, 99 }, { 3501, -3499, 101 }), "begin_increase_edicts unlinks all")
		sv_main.SVVM_end_increase_edicts(prog)
		t.ok(ctx, inbox(p1, { 3499, -3501, 99 }, { 3501, -3499, 101 }), "end_increase_edicts relinks")
		t.ok(ctx, not inbox(plast, { 3499, -3401, 99 }, { 3501, -3399, 101 }), "but not the last edict (C quirk)")
		sv_phys.SV_LinkEdict(plast)
		-- through PRVM_ED_Alloc: growing past max_edicts keeps the links
		prog.begin_increase_edicts = sv_main.SVVM_begin_increase_edicts
		prog.end_increase_edicts = sv_main.SVVM_end_increase_edicts
		local oldmax = prog.max_edicts
		while prog.max_edicts == oldmax do
			prvm_edict.PRVM_ED_Alloc(prog)
		end
		t.ok(ctx, prog.max_edicts > oldmax, "edicts increased")
		t.ok(ctx, inbox(p1, { 3499, -3501, 99 }, { 3501, -3499, 101 }), "linked edicts survive the increase")
		t.ok(ctx, inbox(plast, { 3499, -3401, 99 }, { 3501, -3399, 101 }), "plast too (not last any more)")
		prog.begin_increase_edicts, prog.end_increase_edicts = nil, nil
	end

	sv.worldmodel = nil
	sv.models = {}
	sv.world = world.new()
	cvar.prvm_prog_list[0] = nil
	console.sink = oldsink
	cvar.reset()
end
