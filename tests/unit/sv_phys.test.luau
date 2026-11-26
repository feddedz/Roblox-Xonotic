--!strict
-- engine/sv_phys.luau line testing and linking (SV_TracePoint / SV_TraceLine / SV_TraceBox, SV_PointSuperContents,
-- SV_EntitiesInBox, SV_LinkEdict, SV_LinkEdict_TouchAreaGrid) against the C rules, on a synthetic server prog
-- (field / global offsets put straight into the FieldOfs / GlobalOfs caches) and box models built from
-- Collision_ClipTrace_Box / _Point. Not a differential test against the C build: there are no C vectors yet.
local t = require("../_lib/t")
local collision = require("../../engine/collision")
local console = require("../../engine/console")
local cvar = require("../../engine/cvar")
local f32 = require("../../engine/_port/f32")
local matrixlib = require("../../engine/matrixlib")
local prvm_edict = require("../../engine/prvm_edict")
local server = require("../../engine/server")
local sv_phys = require("../../engine/sv_phys")
local world = require("../../engine/world")
require("../../engine/model_brush") -- sets collision.Collision_ClipTrace_Box / _Point

local R = f32.round
local SOLID, BODY, CORPSE, WATER = 0x1, 0x20, 0x40, 0x8
local MOVE_NORMAL, MOVE_NOMONSTERS, MOVE_MISSILE, MOVE_WORLDONLY =
	sv_phys.MOVE_NORMAL, sv_phys.MOVE_NOMONSTERS, sv_phys.MOVE_MISSILE, sv_phys.MOVE_WORLDONLY

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
	console.sink = function(_line: string) end
	cvar.reset()
	collision.Collision_Init()

	-- server prog: one slot per float, three per vector
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
	prvm_edict.realtime = 10
	prvm_edict.PRVM_MEM_Alloc(prog)
	cvar.prvm_prog_list[0] = prog

	local function setF(e: number, f: string, v: number)
		buffer.writef32(prog.edictsfields, (e * prog.entityfields + prvm_edict.FieldOfs(prog, f)) * 4, v)
	end
	local function setI(e: number, f: string, v: number)
		buffer.writei32(prog.edictsfields, (e * prog.entityfields + prvm_edict.FieldOfs(prog, f)) * 4, v)
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

	-- the server: a floor slab as the world model, the area grid over +-4096
	local sv = server.sv
	sv.world = world.new()
	sv.models = {}
	sv.time = 12.345678901
	world.World_SetSize(sv.world, "maps/test.bsp", { -4096, -4096, -4096 }, { 4096, 4096, 4096 }, prog)
	sv.worldmodel = boxmodel({ -1024, -1024, -64 }, { 1024, 1024, 0 }, SOLID)
	sv.models[1] = sv.worldmodel -- modelindex 1
	local bmodel = boxmodel({ -32, -32, -32 }, { 32, 32, 32 }, bit32.bor(SOLID, WATER))
	local rr = R(math.sqrt(3 * 32 * 32))
	bmodel.rotatedmins, bmodel.rotatedmaxs = { -rr, -rr, -rr }, { rr, rr, rr }
	local yr = R(math.sqrt(2 * 32 * 32))
	bmodel.yawmins, bmodel.yawmaxs = { -yr, -yr, -32 }, { yr, yr, 32 }
	sv.models[2] = bmodel -- modelindex 2

	local function spawn(solid: number, origin: { number }, mins: { number }, maxs: { number }): number
		local e = prvm_edict.PRVM_ED_Alloc(prog)
		setF(e, "solid", solid)
		setV(e, "origin", origin)
		setV(e, "mins", mins)
		setV(e, "maxs", maxs)
		sv_phys.SV_LinkEdict(e)
		return e
	end
	local function unlink(e: number)
		world.World_UnlinkEdict(prog, e)
	end
	local function key(tr: collision.trace_t): string
		local p = tr.plane.normal
		return `{tr.fraction} {tr.endpos[1]} {tr.endpos[2]} {tr.endpos[3]} {p[1]} {p[2]} {p[3]} {tr.plane.dist} {tr.startsolid} {tr.allsolid} {tr.startsupercontents} {tr.hitsupercontents}`
	end

	-- 1. no entities: the world clip unchanged; ent is the world when anything was hit
	local seed = 77
	local function frand(lo: number, hi: number): number
		seed = (seed * 1103515245 + 12345) % 2147483648
		return R(lo + (hi - lo) * (seed % 65536) / 65536)
	end
	local bad = 0
	for i = 1, 60 do
		local s = { frand(-300, 300), frand(-300, 300), frand(-40, 200) }
		local e = { frand(-300, 300), frand(-300, 300), frand(-120, 200) }
		local mins, maxs = { -16, -16, -24 }, { 16, 16, 45 }
		local hit = bit32.bor(SOLID, BODY)
		local ext = if i % 3 == 0 then 0 else R(1 / 32)
		local ref = collision.newtrace()
		collision.Collision_ClipToWorld(ref, sv.worldmodel, s, mins, maxs, e, hit, 0, 0, ext)
		local got = sv_phys.SV_TraceBox(s, mins, maxs, e, MOVE_NORMAL, nil, hit, 0, 0, ext)
		local refl = collision.newtrace()
		collision.Collision_ClipLineToWorld(refl, sv.worldmodel, s, e, hit, 0, 0, ext, false)
		local gotl = sv_phys.SV_TraceLine(s, e, MOVE_NORMAL, nil, hit, 0, 0, ext)
		local refp = collision.newtrace()
		collision.Collision_ClipPointToWorld(refp, sv.worldmodel, s, hit, 0, 0)
		local gotp = sv_phys.SV_TracePoint(s, MOVE_NORMAL, nil, hit, 0, 0)
		local function wantent(tr: collision.trace_t): any
			return if tr.startsolid or tr.fraction < 1 then 0 else nil
		end
		if
			key(got) ~= key(ref)
			or key(gotl) ~= key(refl)
			or key(gotp) ~= key(refp)
			or got.ent ~= wantent(ref)
			or gotl.ent ~= wantent(refl)
			or gotp.ent ~= wantent(refp)
			or got.worldstartsolid ~= ref.startsolid
			or got.bmodelstartsolid ~= ref.startsolid
		then
			bad += 1
		end
	end
	t.eq(
		ctx,
		bad,
		0,
		"with no entities SV_TraceBox / Line / Point equal Collision_ClipToWorld / LineToWorld / PointToWorld"
	)

	-- 2. linking: absmin / absmax as C computes them, and found by SV_EntitiesInBox
	local o1 = { R(0.1), R(-0.3), R(100.7) }
	local e1 = spawn(sv_phys.SOLID_BBOX, o1, { -16, -16, -16 }, { 16, 16, 16 })
	local wantmin = { R(R(o1[1] + -16) - 1), R(R(o1[2] + -16) - 1), R(R(o1[3] + -16) - 1) }
	local wantmax = { R(R(o1[1] + 16) + 1), R(R(o1[2] + 16) + 1), R(R(o1[3] + 16) + 1) }
	t.eq(ctx, table.concat(V(e1, "absmin"), " "), table.concat(wantmin, " "), "bbox absmin = origin + mins - 1")
	t.eq(ctx, table.concat(V(e1, "absmax"), " "), table.concat(wantmax, " "), "bbox absmax = origin + maxs + 1")
	local list: { number } = {}
	local cnt = sv_phys.SV_EntitiesInBox({ -1, -1, 99 }, { 1, 1, 101 }, 32, list)
	t.ok(ctx, cnt == 1 and list[1] == e1, "the linked entity is found by SV_EntitiesInBox")
	t.eq(ctx, sv_phys.SV_EntitiesInBox({ 500, 500, 500 }, { 501, 501, 501 }, 32, list), 0, "and not elsewhere")
	t.eq(ctx, sv_phys.SV_EntitiesInBox({ -1, -1, 99 }, { 1, 1, 101 }, 0, list), 0, "maxedicts < 1 returns 0")
	cvar.Cvar_RegisterVariable(cvar.static(0, "sv_areadebug", "0", ""))
	cvar.Cvar_SetValue("sv_areadebug", 1)
	local dl: { number } = {}
	local dn = sv_phys.SV_EntitiesInBox({ -1, -1, 99 }, { 1, 1, 101 }, 32, dl)
	t.ok(ctx, dn == 1 and dl[1] == e1, "sv_areadebug 1 (absmin / absmax scan) finds the same entity")
	cvar.Cvar_SetValue("sv_areadebug", 0)

	-- FL_ITEM and sv_legacy_bbox_expand
	local item = prvm_edict.PRVM_ED_Alloc(prog)
	setF(item, "solid", sv_phys.SOLID_TRIGGER)
	setF(item, "flags", sv_phys.FL_ITEM)
	setV(item, "origin", { 300, 300, R(10.3) })
	setV(item, "mins", { -8, -8, 0 })
	setV(item, "maxs", { 8, 8, 16 })
	sv_phys.SV_LinkEdict(item)
	t.eq(
		ctx,
		table.concat(V(item, "absmin"), " ") .. " / " .. table.concat(V(item, "absmax"), " "),
		`{R(292 - 15)} {R(292 - 15)} {R(R(R(10.3) + 0) - 1)} / {R(308 + 15)} {R(308 + 15)} {R(R(R(10.3) + 16) + 1)}`,
		"FL_ITEM expands by 15 15 1"
	)
	cvar.Cvar_RegisterVariable(cvar.static(0, "sv_legacy_bbox_expand", "1", ""))
	cvar.Cvar_SetValue("sv_legacy_bbox_expand", 0)
	sv_phys.SV_LinkEdict(item)
	t.eq(
		ctx,
		table.concat(V(item, "absmin"), " ") .. " / " .. table.concat(V(item, "absmax"), " "),
		`292 292 {R(10.3)} / 308 308 {R(R(10.3) + 16)}`,
		"sv_legacy_bbox_expand 0: no expansion"
	)
	cvar.Cvar_SetValue("sv_legacy_bbox_expand", 1)
	sv_phys.SV_LinkEdict(item)

	-- SOLID_BSP: normal / yaw / rotated boxes of the model
	local bsp = prvm_edict.PRVM_ED_Alloc(prog)
	setF(bsp, "solid", sv_phys.SOLID_BSP)
	setF(bsp, "modelindex", 2)
	local bo = { -400, 0, R(64.25) }
	setV(bsp, "origin", bo)
	sv_phys.SV_LinkEdict(bsp)
	local function abs(e: number): string
		return table.concat(V(e, "absmin"), " ") .. " / " .. table.concat(V(e, "absmax"), " ")
	end
	local function boxstr(o: { number }, mn: { number }, mx: { number }): string
		local a, b = {}, {}
		for k = 1, 3 do
			a[k] = R(R(o[k] + mn[k]) - 1)
			b[k] = R(R(o[k] + mx[k]) + 1)
		end
		return table.concat(a, " ") .. " / " .. table.concat(b, " ")
	end
	t.eq(
		ctx,
		abs(bsp),
		boxstr(bo, bmodel.normalmins, bmodel.normalmaxs),
		"SOLID_BSP unrotated: normalmins / normalmaxs"
	)
	setV(bsp, "angles", { 0, 30, 0 })
	sv_phys.SV_LinkEdict(bsp)
	t.eq(ctx, abs(bsp), boxstr(bo, bmodel.yawmins, bmodel.yawmaxs), "SOLID_BSP yawed: yawmins / yawmaxs")
	setV(bsp, "angles", { 0, 0, 0 })
	setV(bsp, "avelocity", { 0, 90, 0 })
	sv_phys.SV_LinkEdict(bsp)
	t.eq(ctx, abs(bsp), boxstr(bo, bmodel.yawmins, bmodel.yawmaxs), "SOLID_BSP yaw avelocity: yawmins / yawmaxs")
	setV(bsp, "avelocity", { 0, 0, 0 })
	setV(bsp, "angles", { 0, 0, 20 })
	sv_phys.SV_LinkEdict(bsp)
	t.eq(ctx, abs(bsp), boxstr(bo, bmodel.rotatedmins, bmodel.rotatedmaxs), "SOLID_BSP rolled: rotatedmins / maxs")
	setV(bsp, "angles", { 15, 0, 0 })
	sv_phys.SV_LinkEdict(bsp)
	t.eq(ctx, abs(bsp), boxstr(bo, bmodel.rotatedmins, bmodel.rotatedmaxs), "SOLID_BSP pitched: rotatedmins / maxs")
	setV(bsp, "angles", { 0, 0, 0 })
	sv_phys.SV_LinkEdict(bsp)
	-- SOLID_BSP without a model: origin + mins / maxs
	local nomodel = spawn(sv_phys.SOLID_BSP, { 900, 900, 900 }, { -1, -2, -3 }, { 4, 5, 6 })
	t.eq(ctx, abs(nomodel), boxstr({ 900, 900, 900 }, { -1, -2, -3 }, { 4, 5, 6 }), "SOLID_BSP without model")
	unlink(nomodel)
	-- MOVETYPE_PHYSICS: the rotated box (RotateBBox)
	local phys = prvm_edict.PRVM_ED_Alloc(prog)
	setF(phys, "solid", sv_phys.SOLID_NOT)
	setF(phys, "movetype", sv_phys.MOVETYPE_PHYSICS)
	setV(phys, "origin", { 1000, 1000, 1000 })
	setV(phys, "mins", { -10, -20, -5 })
	setV(phys, "maxs", { 10, 20, 5 })
	setV(phys, "angles", { 0, 90, 0 })
	sv_phys.SV_LinkEdict(phys)
	do
		local m = matrixlib.new()
		matrixlib.Matrix4x4_CreateFromQuakeEntity(m, 0, 0, 0, 0, 90, 0, 1)
		local lo, hi = { math.huge, math.huge, math.huge }, { -math.huge, -math.huge, -math.huge }
		for _, x in { -10, 10 } do
			for _, y in { -20, 20 } do
				for _, z in { -5, 5 } do
					local u = { 0, 0, 0 }
					matrixlib.Matrix4x4_Transform(m, { x, y, z }, u)
					for k = 1, 3 do
						lo[k] = math.min(lo[k], u[k])
						hi[k] = math.max(hi[k], u[k])
					end
				end
			end
		end
		t.eq(ctx, abs(phys), boxstr({ 1000, 1000, 1000 }, lo, hi), "MOVETYPE_PHYSICS: box of the 8 rotated corners")
		local mn = V(phys, "absmin")
		t.ok(ctx, math.abs(mn[1] - 979) < 1e-3 and math.abs(mn[2] - 989) < 1e-3, "rotated 90: x / y extents swap")
	end
	unlink(phys)

	-- 3. a SOLID_BBOX entity in the path is hit and trace.ent is that edict
	local s, e = { -200, R(-0.3), R(100.7) }, { 200, R(-0.3), R(100.7) }
	local HIT = bit32.bor(SOLID, BODY, CORPSE)
	local tr = sv_phys.SV_TraceLine(s, e, MOVE_NORMAL, nil, HIT, 0, 0, 0)
	do
		local mtx, imtx = matrixlib.new(), matrixlib.new()
		matrixlib.Matrix4x4_CreateTranslate(mtx, o1[1], o1[2], o1[3])
		matrixlib.Matrix4x4_Invert_Simple(imtx, mtx)
		local ref = collision.newtrace()
		collision.Collision_ClipLineToGenericEntity(
			ref,
			nil,
			nil,
			nil,
			{ -16, -16, -16 },
			{ 16, 16, 16 },
			BODY,
			mtx,
			imtx,
			s,
			e,
			HIT,
			0,
			0,
			0,
			false
		)
		t.ok(ctx, tr.ent == e1 and tr.fraction < 1, "line hits the bbox entity, trace.ent = its edict")
		t.eq(ctx, key(tr), key(ref), "the hit equals Collision_ClipLineToGenericEntity against that box")
		t.eq(ctx, tr.hitsupercontents, BODY, "hitsupercontents is SUPERCONTENTS_BODY")
	end
	local tb = sv_phys.SV_TraceBox(s, { -4, -4, -4 }, { 4, 4, 4 }, e, MOVE_NORMAL, nil, HIT, 0, 0, 0)
	t.ok(ctx, tb.ent == e1 and tb.fraction < tr.fraction, "box hits it earlier than the line")
	local tp = sv_phys.SV_TracePoint(o1, MOVE_NORMAL, nil, HIT, 0, 0)
	t.ok(ctx, tp.ent == e1 and tp.startsolid, "point inside the entity: startsolid, ent = edict")
	t.ok(ctx, not tp.bmodelstartsolid, "bmodelstartsolid only for SOLID_BSP")

	-- 4. passedict, its owner and its owned entities are skipped
	local other = spawn(sv_phys.SOLID_NOT, { 2000, 2000, 2000 }, { 0, 0, 0 }, { 0, 0, 0 })
	t.eq(ctx, sv_phys.SV_TraceLine(s, e, MOVE_NORMAL, e1, HIT, 0, 0, 0).fraction, 1, "passedict itself is skipped")
	t.eq(ctx, sv_phys.SV_TraceLine(s, e, MOVE_NORMAL, other, HIT, 0, 0, 0).ent, e1, "an unrelated passedict is not")
	setI(other, "owner", e1)
	t.eq(ctx, sv_phys.SV_TraceLine(s, e, MOVE_NORMAL, other, HIT, 0, 0, 0).fraction, 1, "passedict's owner is skipped")
	setI(other, "owner", 0)
	setI(e1, "owner", other)
	t.eq(
		ctx,
		sv_phys.SV_TraceLine(s, e, MOVE_NORMAL, other, HIT, 0, 0, 0).fraction,
		1,
		"entities passedict owns are skipped"
	)
	t.eq(
		ctx,
		sv_phys.SV_TraceLine(s, e, MOVE_NORMAL, nil, HIT, 0, 0, 0).ent,
		e1,
		"without passedict the owned one is hit"
	)
	setI(e1, "owner", 0)
	t.eq(ctx, sv_phys.SV_TraceLine(s, e, MOVE_NORMAL, 0, HIT, 0, 0, 0).ent, e1, "passedict = world counts as NULL")

	-- 5. MOVE_* types
	t.eq(
		ctx,
		sv_phys.SV_TraceLine(s, e, MOVE_NOMONSTERS, nil, HIT, 0, 0, 0).fraction,
		1,
		"MOVE_NOMONSTERS ignores SOLID_BBOX"
	)
	t.eq(
		ctx,
		sv_phys.SV_TraceLine(s, e, MOVE_WORLDONLY, nil, HIT, 0, 0, 0).fraction,
		1,
		"MOVE_WORLDONLY ignores entities"
	)
	local bs, be = { -600, 0, R(64.25) }, { -200, 0, R(64.25) }
	local tn = sv_phys.SV_TraceLine(bs, be, MOVE_NOMONSTERS, nil, HIT, 0, 0, 0)
	t.ok(ctx, tn.ent == bsp and tn.fraction < 1, "MOVE_NOMONSTERS still hits SOLID_BSP")
	t.ok(ctx, math.abs(tn.endpos[1] - -432) < 0.1, "SOLID_BSP hit at the model's box face")
	t.eq(
		ctx,
		sv_phys.SV_TraceLine(bs, be, MOVE_WORLDONLY, nil, HIT, 0, 0, 0).fraction,
		1,
		"MOVE_WORLDONLY ignores SOLID_BSP"
	)
	local tbsp = sv_phys.SV_TracePoint(bo, MOVE_NORMAL, nil, HIT, 0, 0)
	t.ok(ctx, tbsp.startsolid and tbsp.bmodelstartsolid and tbsp.ent == bsp, "start in SOLID_BSP: bmodelstartsolid")
	-- rotated bmodel: traced in its own space
	setV(bsp, "angles", { 0, 45, 0 })
	sv_phys.SV_LinkEdict(bsp)
	local trot = sv_phys.SV_TraceLine(bs, be, MOVE_NORMAL, nil, HIT, 0, 0, 0)
	t.ok(
		ctx,
		trot.ent == bsp and math.abs(trot.endpos[1] - (-400 - 32 * math.sqrt(2))) < 0.1,
		"yawed SOLID_BSP hit at its corner"
	)
	setV(bsp, "angles", { 0, 0, 0 })
	sv_phys.SV_LinkEdict(bsp)
	-- MOVE_MISSILE: monsters get a box 15 units bigger
	local mon = spawn(sv_phys.SOLID_SLIDEBOX, { 0, 300, 100 }, { -16, -16, -16 }, { 16, 16, 16 })
	setF(mon, "flags", sv_phys.FL_MONSTER)
	local ms, me = { -200, 274, 100 }, { 200, 274, 100 } -- 10 units beside the monster's box
	t.eq(
		ctx,
		sv_phys.SV_TraceLine(ms, me, MOVE_NORMAL, nil, HIT, 0, 0, 0).fraction,
		1,
		"MOVE_NORMAL misses beside the monster"
	)
	local tm = sv_phys.SV_TraceLine(ms, me, MOVE_MISSILE, nil, HIT, 0, 0, 0)
	t.ok(ctx, tm.ent == mon and tm.fraction < 1, "MOVE_MISSILE hits the monster through the 15-unit extension")
	t.ok(
		ctx,
		sv_phys.SV_TracePoint({ 0, 274, 100 }, MOVE_MISSILE, nil, HIT, 0, 0).ent == mon,
		"MOVE_MISSILE point trace too"
	)
	t.ok(
		ctx,
		sv_phys.SV_TraceBox(ms, { -1, -1, -1 }, { 1, 1, 1 }, me, MOVE_MISSILE, nil, HIT, 0, 0, 0).ent == mon,
		"MOVE_MISSILE box trace too"
	)
	setF(mon, "flags", 0)
	t.eq(ctx, sv_phys.SV_TraceLine(ms, me, MOVE_MISSILE, nil, HIT, 0, 0, 0).fraction, 1, "not for non-monsters")
	unlink(mon)
	-- points against points are skipped when passedict is set (unless MOVE_MISSILE vs FL_MONSTER)
	local pt = spawn(sv_phys.SOLID_BBOX, { 0, -300, 100 }, { 0, 0, 0 }, { 0, 0, 0 })
	local ps, pe = { 0, -300, 50 }, { 0, -300, 150 }
	t.eq(ctx, sv_phys.SV_TraceLine(ps, pe, MOVE_NORMAL, other, HIT, 0, 0, 0).fraction, 1, "points vs points skipped")
	t.eq(
		ctx,
		sv_phys.SV_TraceLine(ps, pe, MOVE_MISSILE, other, HIT, 0, 0, 0).fraction,
		1,
		"also for MOVE_MISSILE vs non-monsters"
	)
	setF(pt, "flags", sv_phys.FL_MONSTER)
	local tpm = sv_phys.SV_TraceLine(ps, pe, MOVE_MISSILE, other, HIT, 0, 0, 0)
	t.ok(ctx, tpm.ent == pt, "MOVE_MISSILE against an FL_MONSTER point entity is not skipped")
	unlink(pt)
	-- solid < SOLID_BBOX never blocks; SOLID_CORPSE only for masks with SUPERCONTENTS_CORPSE
	setF(e1, "solid", sv_phys.SOLID_TRIGGER)
	t.eq(ctx, sv_phys.SV_TraceLine(s, e, MOVE_NORMAL, nil, HIT, 0, 0, 0).fraction, 1, "SOLID_TRIGGER does not block")
	setF(e1, "solid", sv_phys.SOLID_CORPSE)
	t.eq(
		ctx,
		sv_phys.SV_TraceLine(s, e, MOVE_NORMAL, nil, HIT, 0, 0, 0).hitsupercontents,
		CORPSE,
		"SOLID_CORPSE hits as CORPSE"
	)
	local player = spawn(sv_phys.SOLID_SLIDEBOX, { 3000, 3000, 3000 }, { -16, -16, -24 }, { 16, 16, 45 })
	local pmask = sv_phys.SV_GenericHitSuperContentsMask(player)
	t.eq(ctx, pmask, bit32.bor(SOLID, BODY, 0x100), "SOLID_SLIDEBOX mask: SOLID | BODY | PLAYERCLIP")
	t.eq(
		ctx,
		sv_phys.SV_TraceLine(s, e, MOVE_NORMAL, player, pmask, 0, 0, 0).fraction,
		1,
		"players pass through corpses"
	)
	setF(player, "flags", sv_phys.FL_MONSTER)
	t.eq(ctx, sv_phys.SV_GenericHitSuperContentsMask(player), bit32.bor(SOLID, BODY, 0x200), "monster: MONSTERCLIP")
	setF(player, "flags", 0)
	setF(player, "solid", sv_phys.SOLID_CORPSE)
	t.eq(ctx, sv_phys.SV_GenericHitSuperContentsMask(player), bit32.bor(SOLID, BODY), "SOLID_CORPSE mask")
	setF(player, "solid", sv_phys.SOLID_BBOX)
	t.eq(ctx, sv_phys.SV_GenericHitSuperContentsMask(player), HIT, "other solids: SOLID | BODY | CORPSE")
	setF(player, "dphitcontentsmask", 0x1234)
	t.eq(ctx, sv_phys.SV_GenericHitSuperContentsMask(player), 0x1234, "dphitcontentsmask wins")
	t.eq(ctx, sv_phys.SV_GenericHitSuperContentsMask(nil), HIT, "no passedict")
	unlink(player)
	setF(e1, "solid", sv_phys.SOLID_BBOX)

	-- 6. SV_PointSuperContents: world plus SOLID_BSP entities (sv_gameplayfix_swiminbmodels)
	t.eq(ctx, sv_phys.SV_PointSuperContents({ 10, 10, -10 }), SOLID, "inside the world slab")
	t.eq(ctx, sv_phys.SV_PointSuperContents({ 10, 10, 10 }), 0, "empty")
	t.eq(ctx, sv_phys.SV_PointSuperContents(bo), bit32.bor(SOLID, WATER), "inside the bmodel (swiminbmodels default 1)")
	t.eq(ctx, sv_phys.SV_PointSuperContents(o1), 0, "SOLID_BBOX entities do not count")
	cvar.Cvar_RegisterVariable(cvar.static(0, "sv_gameplayfix_swiminbmodels", "1", ""))
	cvar.Cvar_SetValue("sv_gameplayfix_swiminbmodels", 0)
	t.eq(ctx, sv_phys.SV_PointSuperContents(bo), 0, "sv_gameplayfix_swiminbmodels 0: world only")
	cvar.Cvar_SetValue("sv_gameplayfix_swiminbmodels", 1)

	-- 7. SV_LinkEdict_TouchAreaGrid: triggers' touch functions run with self / other set, then restored
	local calls = {}
	prog.ExecuteProgram = function(_p: any, fnum: number, _msg: string)
		table.insert(calls, {
			fnum = fnum,
			self = G("self"),
			other = G("other"),
			ent = G("trace_ent"),
			frac = GF("trace_fraction"),
			time = GF("time"),
		})
	end
	setF(item, "solid", sv_phys.SOLID_TRIGGER)
	setI(item, "touch", 7)
	sv_phys.SV_LinkEdict(item)
	local walker = spawn(sv_phys.SOLID_SLIDEBOX, { 300, 300, 30 }, { -16, -16, -24 }, { 16, 16, 45 })
	buffer.writei32(prog.globals, prog.globalofs_cache.self * 4, 55)
	buffer.writei32(prog.globals, prog.globalofs_cache.other * 4, 66)
	sv_phys.SV_LinkEdict_TouchAreaGrid(walker)
	t.eq(ctx, #calls, 1, "one trigger touched")
	local c = calls[1]
	t.ok(
		ctx,
		c and c.fnum == 7 and c.self == item and c.other == walker and c.ent == walker,
		"self = trigger, other = toucher"
	)
	t.ok(ctx, c and c.frac == 1 and c.time == R(sv.time), "trace_fraction 1, time = sv.time as float")
	t.eq(ctx, G("self") .. " " .. G("other"), "55 66", "self / other restored")
	setI(item, "touch", 0)
	sv_phys.SV_LinkEdict_TouchAreaGrid(walker)
	t.eq(ctx, #calls, 1, "no touch function: not called")
	setF(walker, "solid", sv_phys.SOLID_NOT)
	setI(item, "touch", 7)
	sv_phys.SV_LinkEdict_TouchAreaGrid(walker)
	t.eq(ctx, #calls, 1, "SOLID_NOT entities touch nothing")
	prog.ExecuteProgram = nil

	-- the world and free edicts are never linked
	sv_phys.SV_LinkEdict(0)
	prvm_edict.PRVM_ED_Free(prog, walker)
	unlink(walker)
	sv_phys.SV_LinkEdict(walker)
	t.eq(ctx, sv_phys.SV_EntitiesInBox({ 299, 299, 29 }, { 301, 301, 31 }, 32, list), 0, "free edict not relinked")

	sv.worldmodel = nil
	sv.models = {}
	sv.world = world.new()
	console.sink = oldsink
	cvar.reset()
end
