--!strict
-- The movers half of engine/sv_phys.luau (SV_TestEntityPosition .. SV_Physics, AngleVectorsFLU) against the
-- release's sv_phys.c compiled unchanged (tests/vectors/movers.tsv, tools/testgen/movers_vectors.sh). The vector
-- file carries the synthetic map of trace_vectors.c, the QuakeC field / global / function offsets, the server
-- models, the cvars, the client slots and every edict's field memory and private values; the test rebuilds that
-- server, makes every call the C program made and compares, after each call, its result, the QC function calls it
-- made (in order, with the globals the engine set) and the whole state: every edict field word, every global, the
-- private edict values (free, move, suspendedinairflag, waterposition_*, moved_from*, mark), the client values,
-- sv.time and prog->num_edicts. The QC functions get the effects movers_vectors.c mv_effect gives them.
-- After a call that differs the state is set to the C one, so later calls are compared from the same state.
local t = require("../_lib/t")
local bih = require("../../engine/bih")
local collision = require("../../engine/collision")
local console = require("../../engine/console")
local cvar = require("../../engine/cvar")
local f32 = require("../../engine/_port/f32")
local host_cmd = require("../../engine/host_cmd")
local model_brush = require("../../engine/model_brush")
local prvm_edict = require("../../engine/prvm_edict")
local server = require("../../engine/server")
local sv_phys = require("../../engine/sv_phys")
local world = require("../../engine/world")

local R = f32.round

return function(ctx: t.Ctx)
	local scratch = buffer.create(8)
	local function fb(hex: string): number
		return f32.frombits(tonumber(hex, 16) :: number)
	end
	local function db(hex: string): number
		buffer.writeu32(scratch, 4, tonumber(string.sub(hex, 1, 8), 16) :: number)
		buffer.writeu32(scratch, 0, tonumber(string.sub(hex, 9, 16), 16) :: number)
		return buffer.readf64(scratch, 0)
	end
	local function dh(v: number): string
		buffer.writef64(scratch, 0, v)
		return string.format("%08x%08x", buffer.readu32(scratch, 4), buffer.readu32(scratch, 0))
	end
	local function fh(v: number): string
		return string.format("%08x", f32.tobits(v))
	end
	local function num(s: string): number
		return tonumber(s) :: number
	end
	local function v3(c: { string }, i: number): { number }
		return { fb(c[i]), fb(c[i + 1]), fb(c[i + 2]) }
	end
	local function vh(v: { number }): string
		return fh(v[1]) .. "\t" .. fh(v[2]) .. "\t" .. fh(v[3])
	end
	local function floats(c: { string }, first: number): buffer
		local b = buffer.create((#c - first + 1) * 4)
		for i = first, #c do
			buffer.writeu32(b, (i - first) * 4, tonumber(c[i], 16) :: number)
		end
		return b
	end
	local function bstr(b: any): string
		return if b then "1" else "0"
	end

	cvar.reset()
	collision.Collision_Init()
	model_brush.Mod_BrushInit()

	local oldsink = console.sink
	console.sink = function(_line: string) end
	local oldrealtime = prvm_edict.realtime
	prvm_edict.realtime = 0 -- PRVM_ED_CanAlloc: a free edict can be reused (as the C stub has it)

	-- the synthetic map of trace_vectors.c (rebuilt as in tests/unit/sv_phys_ref.test.luau)
	local textures: { any } = {}
	local function tex(s: string): any
		return textures[num(s) + 1]
	end
	local brushes: { any } = {}
	local surfaces: { any } = {}
	local header: { string } = {}
	local planes: { collision.colplanef_t } = {}
	local cvert: { buffer }, rvert: { buffer }, lelem: { buffer } = {}, {}, {}
	local nodelines: { { string } }, leaflines: { { string } } = {}, {}
	local leafbrushes, leafsurfaces = buffer.create(0), buffer.create(0)
	local models: { any } = {}
	local shared: any = nil

	local function buildshared()
		local nsurf = #surfaces
		local sv, st = surfaces[1].num_vertices, surfaces[1].num_triangles
		local gcvert, grvert = buffer.create(nsurf * sv * 12), buffer.create(nsurf * sv * 12)
		local gcelem, grelem = buffer.create(nsurf * st * 12), buffer.create(nsurf * st * 12)
		for s = 0, nsurf - 1 do
			buffer.copy(gcvert, s * sv * 12, cvert[s + 1])
			buffer.copy(grvert, s * sv * 12, rvert[s + 1])
			for i = 0, st * 3 - 1 do
				local e = buffer.readi32(lelem[s + 1], i * 4) + s * sv
				buffer.writei32(gcelem, (s * st * 3 + i) * 4, e)
				buffer.writei32(grelem, (s * st * 3 + i) * 4, e)
			end
		end
		local nodes: { any }, leafs: { any } = {}, {}
		for i, c in nodelines do
			local plane = { normal = v3(c, 3), dist = fb(c[6]), type = num(c[7]), signbits = num(c[8]) }
			nodes[i] = {
				index = i - 1,
				plane = plane,
				mins = v3(c, 11),
				maxs = v3(c, 14),
				combinedsupercontents = 0,
				children = {},
			}
		end
		for i, c in leaflines do
			leafs[i] = {
				index = i - 1,
				plane = nil,
				clusterindex = num(c[3]),
				areaindex = 0,
				containscollisionsurfaces = c[4] ~= "0",
				numleafsurfaces = num(c[5]),
				firstleafsurface = num(c[6]),
				numleafbrushes = num(c[7]),
				firstleafbrush = num(c[8]),
				mins = v3(c, 9),
				maxs = v3(c, 12),
				combinedsupercontents = 0,
				children = {},
			}
		end
		for i, c in nodelines do
			for k = 1, 2 do
				local child = num(c[8 + k])
				nodes[i].children[k] = if child >= 0 then nodes[child + 1] else leafs[-child]
				nodes[i].children[k].parent = nodes[i]
			end
		end
		shared = { gcvert = gcvert, grvert = grvert, gcelem = gcelem, grelem = grelem, nodes = nodes, leafs = leafs }
	end
	local function buildmodel(c: { string })
		if not shared then
			buildshared()
		end
		local m = model_brush.newmodel("movers" .. c[2])
		m.data_textures = textures
		m.data_surfaces = surfaces
		m.num_surfaces = #surfaces
		m.brush.data_brushes = brushes
		m.brush.data_nodes = shared.nodes
		m.brush.data_leafs = shared.leafs
		m.brush.data_leafbrushes = leafbrushes
		m.brush.data_leafsurfaces = leafsurfaces
		m.brush.data_collisionvertex3f = shared.gcvert
		m.brush.data_collisionelement3i = shared.gcelem
		m.surfmesh = { data_vertex3f = shared.grvert, data_element3i = shared.grelem }
		-- the function pointers Mod_Q3BSP_Load sets
		m.TraceBox = model_brush.Mod_Q3BSP_TraceBox
		m.TraceBrush = model_brush.Mod_Q3BSP_TraceBrush
		m.TraceLine = model_brush.Mod_Q3BSP_TraceLine
		m.TracePoint = model_brush.Mod_Q3BSP_TracePoint
		m.PointSuperContents = model_brush.Mod_Q3BSP_PointSuperContents
		m.TraceLineAgainstSurfaces = model_brush.Mod_CollisionBIH_TraceLine
		m.brush.submodel = num(c[2])
		m.firstmodelbrush = num(c[3])
		m.nummodelbrushes = num(c[4])
		m.firstmodelsurface = num(c[5])
		m.nummodelsurfaces = num(c[6])
		m.collision_bih = bih.new()
		m.render_bih = bih.new()
		model_brush.Mod_MakeCollisionBIH(m, false, m.collision_bih)
		model_brush.Mod_MakeCollisionBIH(m, true, m.render_bih)
		t.eq(
			ctx,
			`{m.collision_bih.numnodes}\t{m.render_bih.numnodes}`,
			c[7] .. "\t" .. c[8],
			"model " .. c[2] .. ": BIH nodes"
		)
		models[num(c[2]) + 1] = m
	end

	-- the server
	local sv = server.sv
	local oldsv = {
		world = sv.world,
		models = sv.models,
		worldmodel = sv.worldmodel,
		time = sv.time,
		frametime = sv.frametime,
	}
	local oldprog = cvar.prvm_prog_list[0]
	local svs = host_cmd.svs :: any
	local oldsvs = { clients = svs.clients, maxclients = svs.maxclients }
	local oldhost = server.host_client
	sv.models = {}
	local fieldofs: { [string]: number }, globalofs: { [string]: number } = {}, {}
	local fieldname: { [number]: string } = {} -- slot -> "name[k]"
	local globalname: { [number]: string } = {}
	local nfields, nglobals, ned = 0, 0, 0
	local prog: any = nil
	local qcslots: { number } = {}
	local funcs: { [string]: number } = {}
	local texslot = -1 -- trace_dphittexturename: compared as zero / nonzero

	-- what the Luau calls did, for the current C call
	local qc: { string } = {}
	local qcidx = 0
	local mirrorF: buffer = buffer.create(0)
	local mirrorG: buffer = buffer.create(0)
	local privsnap: { string } = {}
	local privexp: { [number]: string } = {}
	local clsnap: { string } = {}
	local clexp: { [number]: string } = {}
	local label = ""
	local ret = ""
	local ncalls = 0
	local nfailed = 0

	local function word(b: buffer, slot: number): string
		return string.format("%08x", buffer.readu32(b, slot * 4))
	end
	local function gword(b: buffer, slot: number): string
		if slot == texslot then
			return if buffer.readu32(b, slot * 4) ~= 0 then "00000001" else "00000000"
		end
		return word(b, slot)
	end
	local function fieldwords(n: number, f: string, count: number): string
		local parts = {}
		for i = 0, count - 1 do
			table.insert(parts, word(prog.edictsfields, n * nfields + fieldofs[f] + i))
		end
		return table.concat(parts, "\t")
	end
	local function getf(n: number, f: string, k: number): number
		return buffer.readf32(prog.edictsfields, (n * nfields + fieldofs[f] + k) * 4)
	end
	local function setf(n: number, f: string, k: number, v: number)
		buffer.writef32(prog.edictsfields, (n * nfields + fieldofs[f] + k) * 4, v)
	end
	local function gi(g: string): number
		return buffer.readi32(prog.globals, globalofs[g] * 4)
	end
	local function gf(g: string): number
		return buffer.readf32(prog.globals, globalofs[g] * 4)
	end
	local function privtab(name: string): { [number]: any }
		local tb = prog[name]
		if not tb then
			tb = {}
			prog[name] = tb
		end
		return tb
	end
	local function pvec(name: string, n: number): { number }
		return privtab(name)[n] or { 0, 0, 0 }
	end
	-- free move suspendedinairflag waterposition_forceupdate mark waterposition_origin moved_from moved_fromangles,
	-- packed (fast to build and compare) and as the text of a P line
	local PRIVFMT = "<BBBBi4fffffffff"
	local function b01(x: any): number
		return if x then 1 else 0
	end
	local function privkey(n: number): string
		local a, b, c = pvec("ed_waterposition_origin", n), pvec("ed_moved_from", n), pvec("ed_moved_fromangles", n)
		return string.pack(
			PRIVFMT,
			b01(prog.ed_free[n]),
			b01(privtab("ed_move")[n]),
			b01(privtab("ed_suspendedinairflag")[n]),
			b01(privtab("ed_waterposition_forceupdate")[n]),
			privtab("ed_mark")[n] or 0,
			a[1],
			a[2],
			a[3],
			b[1],
			b[2],
			b[3],
			c[1],
			c[2],
			c[3]
		)
	end
	local function privtextkey(text: string): string
		local c = string.split(text, "\t")
		local v = {}
		for i = 6, 14 do
			v[i - 5] = fb(c[i])
		end
		return string.pack(
			PRIVFMT,
			num(c[1]),
			num(c[2]),
			num(c[3]),
			num(c[4]),
			num(c[5]),
			v[1],
			v[2],
			v[3],
			v[4],
			v[5],
			v[6],
			v[7],
			v[8],
			v[9]
		)
	end
	local function privkeytext(key: string): string
		local r = table.pack(string.unpack(PRIVFMT, key))
		local parts = {}
		for i = 1, 5 do
			parts[i] = tostring(r[i])
		end
		for i = 6, 14 do
			parts[i] = fh(r[i])
		end
		return table.concat(parts, "\t")
	end
	local function setpriv(n: number, c: { string }, first: number)
		prog.ed_free[n] = c[first] ~= "0"
		privtab("ed_move")[n] = c[first + 1] ~= "0"
		privtab("ed_suspendedinairflag")[n] = c[first + 2] ~= "0"
		privtab("ed_waterposition_forceupdate")[n] = c[first + 3] ~= "0"
		privtab("ed_mark")[n] = num(c[first + 4])
		privtab("ed_waterposition_origin")[n] = v3(c, first + 5)
		privtab("ed_moved_from")[n] = v3(c, first + 8)
		privtab("ed_moved_fromangles")[n] = v3(c, first + 11)
	end
	local function clstr(i: number): string
		local cl = svs.clients[i]
		if cl == nil then -- a zeroed client_t
			return "-1\t0\t0\t00000000\t00000000\t00000000\t00000000"
		end
		return table.concat({
			tostring(cl.edict),
			bstr(cl.begun),
			bstr(cl.fixangle_angles_set),
			fh(cl.clmovement_inputtimeout or 0),
			vh(cl.fixangle_angles or { 0, 0, 0 }),
		}, "\t")
	end
	local function setcl(i: number, c: { string }, first: number)
		svs.clients[i] = {
			edict = num(c[first]),
			begun = c[first + 1] ~= "0",
			fixangle_angles_set = c[first + 2] ~= "0",
			clmovement_inputtimeout = fb(c[first + 3]),
			fixangle_angles = v3(c, first + 4),
			cmd = {},
		}
	end

	-- the effect of a QC function by its number (movers_vectors.c mv_effect)
	local FN_PRE, FN_POST = 3, 4
	local DYN0, SENT = 21, 127 -- movers_vectors.c MV_DYN0, MV_SENT
	local function effect(fnum: number)
		local self, other, time = gi("self"), gi("other"), gf("time")
		if fnum == FN_PRE then
			setf(self, "velocity", 0, R(getf(self, "velocity", 0) + 5))
			return
		elseif fnum == FN_POST then
			setf(self, "fixangle", 0, 1)
			return
		elseif fnum < 10 then
			return
		end
		local e = fnum % 10
		if e == 0 then
			-- spawn(): the first free edict of the cases (MV_DYN0 .. MV_SENT - 1) is in use again, not moved yet
			for i = DYN0, SENT - 1 do
				if prog.ed_free[i] then
					prog.ed_free[i] = false
					privtab("ed_move")[i] = false
					break
				end
			end
		elseif e == 1 then
			setf(self, "nextthink", 0, R(time + R(0.05)))
		elseif e == 2 then
			setf(self, "nextthink", 0, time)
		elseif e == 3 then
			setf(self, "velocity", 2, R(getf(self, "velocity", 2) + 100))
		elseif e == 4 then
			if self > 2 and self < ned - 1 then
				prog.ed_free[self] = true
			end
		elseif e == 5 then
			if self > 0 then
				setf(self, "origin", 2, R(getf(self, "origin", 2) + 64))
				local marks = privtab("ed_mark")
				if (marks[self] or 0) == -1 then
					marks[self] = -2
				end
				sv_phys.SV_LinkEdict(self)
			end
		elseif e == 6 then
			setf(self, "nextthink", 0, R(time + R(0.01)))
		elseif e == 7 then
			for k = 0, 2 do
				setf(self, "velocity", k, -getf(self, "velocity", k))
			end
		elseif e == 8 then
			if other > 0 then
				setf(other, "velocity", 2, R(getf(other, "velocity", 2) + 50))
			end
		elseif e == 9 then
			if other > 2 and other < ned - 1 then
				prog.ed_free[other] = true
			end
		end
	end

	local function tracestr(tr: collision.trace_t): string
		return table.concat({
			bstr(tr.allsolid),
			bstr(tr.startsolid),
			bstr(tr.worldstartsolid),
			bstr(tr.bmodelstartsolid),
			dh(tr.fraction),
			dh(tr.endpos[1]),
			dh(tr.endpos[2]),
			dh(tr.endpos[3]),
			fh(tr.plane.normal[1]),
			fh(tr.plane.normal[2]),
			fh(tr.plane.normal[3]),
			fh(tr.plane.dist),
			tostring(if tr.ent == nil then -1 else tr.ent),
		}, "\t")
	end

	-- one call as the C line names it; returns the result string the E line has
	local function call(c: { string }): string
		local op = c[2]
		local n = if c[3] then tonumber(c[3]) or 0 else 0
		if op == "TEP" then
			return bstr(sv_phys.SV_TestEntityPosition(n, v3(c, 4)))
		elseif op == "CCT" then
			return bstr(sv_phys.SV_CheckContentsTransition(n, num(c[4])))
		elseif op == "CV" then
			sv_phys.SV_CheckVelocity(n)
		elseif op == "RT" then
			return bstr(sv_phys.SV_RunThink(n))
		elseif op == "IMP" then
			local tr = collision.newtrace()
			tr.allsolid = c[4] ~= "0"
			tr.startsolid = c[5] ~= "0"
			tr.inwater = c[6] ~= "0"
			tr.inopen = c[7] ~= "0"
			tr.fraction = db(c[8])
			tr.endpos = { db(c[9]), db(c[10]), db(c[11]) }
			tr.plane.normal = v3(c, 12)
			tr.plane.dist = fb(c[15])
			tr.ent = num(c[16])
			tr.startsupercontents = num(c[17])
			tr.hitsupercontents = num(c[18])
			tr.hitq3surfaceflags = num(c[19])
			tr.hittexture = if num(c[20]) < 0 then nil else textures[num(c[20]) + 1]
			sv_phys.SV_Impact(n, tr)
		elseif op == "FLY" then
			local sn = { 0, 0, 0 }
			local r =
				sv_phys.SV_FlyMove(n, fb(c[4]), c[5] ~= "0", if c[6] ~= "0" then sn else nil, num(c[7]), 0, 0, fb(c[8]))
			return `{r}\t{vh(sn)}`
		elseif op == "GRAV" then
			return fh(sv_phys.SV_Gravity(n))
		elseif op == "NPK" then
			return bstr(sv_phys.SV_NudgeOutOfSolid_PivotIsKnownGood(n, v3(c, 4)))
		elseif op == "PE" then
			local ok, tr = sv_phys.SV_PushEntity(n, v3(c, 4), c[7] ~= "0")
			return bstr(ok) .. "\t" .. tracestr(tr)
		elseif op == "UNO" then
			local off = { 0, 0, 0 }
			local r = sv_phys.SV_UnstickEntityReturnOffset(n, off)
			return `{r}\t{vh(off)}`
		elseif op == "UN" then
			return bstr(sv_phys.SV_UnstickEntity(n))
		elseif op == "CS" then
			sv_phys.SV_CheckStuck(n)
		elseif op == "CW" then
			return bstr(sv_phys.SV_CheckWater(n))
		elseif op == "WF" then
			sv_phys.SV_WallFriction(n, v3(c, 4))
		elseif op == "WM" then
			sv_phys.SV_WalkMove(n)
		elseif op == "FOL" then
			sv_phys.SV_Physics_Follow(n)
		elseif op == "CWT" then
			sv_phys.SV_CheckWaterTransition(n)
		elseif op == "TOSS" then
			sv_phys.SV_Physics_Toss(n)
		elseif op == "STEP" then
			sv_phys.SV_Physics_Step(n)
		elseif op == "PENT" then
			sv_phys.SV_Physics_Entity(n)
		elseif op == "CNT" then
			sv_phys.SV_Physics_ClientEntity_NoThink(n)
		elseif op == "CMOVE" then
			sv_phys.SV_Physics_ClientMove()
		elseif op == "CPRE" then
			sv_phys.SV_Physics_ClientEntity_PreThink(n)
		elseif op == "CPOST" then
			sv_phys.SV_Physics_ClientEntity_PostThink(n)
		elseif op == "CENT" then
			sv_phys.SV_Physics_ClientEntity(n)
		elseif op == "PM" then
			sv_phys.SV_PushMove(n, fb(c[4]))
		elseif op == "PP" then
			sv_phys.SV_Physics_Pusher(n)
		elseif op == "PHYS" then
			sv_phys.SV_Physics()
		elseif op == "CLIP" then
			local out = { 0, 0, 0 }
			sv_phys.ClipVelocity(v3(c, 3), v3(c, 6), out, fb(c[9]))
			return vh(out)
		elseif op == "AVF" then
			local mask = num(c[6])
			local fw, lf, up = { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 }
			sv_phys.AngleVectorsFLU(
				v3(c, 3),
				if bit32.band(mask, 1) ~= 0 then fw else nil,
				if bit32.band(mask, 2) ~= 0 then lf else nil,
				if bit32.band(mask, 4) ~= 0 then up else nil
			)
			return vh(fw) .. "\t" .. vh(lf) .. "\t" .. vh(up)
		else
			error("unknown call " .. op)
		end
		return "-"
	end

	-- compare the state after a call with the C one (snapshot + the C program's changes); set it to the C one
	local function finish(c: { string })
		ncalls += 1
		local bad = false
		local function fail(what: string, got: string, want: string)
			bad = true
			t.eq(ctx, got, want, `{label}: {what}`)
		end
		local want = table.concat(c, "\t", 2, #c - 2)
		if ret ~= want then
			fail("result", ret, want)
		end
		if qcidx ~= #qc then
			fail("number of QC calls", tostring(#qc), tostring(qcidx))
		end
		-- edict fields
		local fields = prog.edictsfields
		if buffer.tostring(fields) ~= buffer.tostring(mirrorF) then
			local diffs = {}
			local relink: { [number]: boolean } = {}
			for slot = 0, ned * nfields - 1 do
				if buffer.readu32(fields, slot * 4) ~= buffer.readu32(mirrorF, slot * 4) then
					local e = slot // nfields
					relink[e] = true
					if #diffs < 8 then
						table.insert(
							diffs,
							`ed {e} {fieldname[slot % nfields] or tostring(slot % nfields)} {word(fields, slot)} (C {word(
								mirrorF,
								slot
							)})`
						)
					end
				end
			end
			fail("fields", table.concat(diffs, "; "), "the C state")
			buffer.copy(fields, 0, mirrorF)
			for e in relink do
				if e > 0 and not prog.ed_free[e] then
					sv_phys.SV_LinkEdict(e)
				end
			end
			buffer.copy(fields, 0, mirrorF)
		end
		-- globals
		local gbad = {}
		for slot = 0, nglobals - 1 do
			if gword(prog.globals, slot) ~= gword(mirrorG, slot) then
				table.insert(
					gbad,
					`{globalname[slot] or tostring(slot)} {word(prog.globals, slot)} (C {word(mirrorG, slot)})`
				)
			end
		end
		if #gbad > 0 then
			fail("globals", table.concat(gbad, "; "), "the C globals")
			buffer.copy(prog.globals, 0, mirrorG)
		end
		-- private edict values
		local pbad = {}
		for e = 0, ned - 1 do
			local exp = privexp[e] or privsnap[e + 1]
			local got = privkey(e)
			if got ~= exp then
				local exptext = privkeytext(exp)
				if #pbad < 4 then
					table.insert(pbad, `ed {e} [{privkeytext(got)}] (C [{exptext}])`)
				end
				setpriv(e, string.split(exptext, "\t"), 1)
			end
		end
		if #pbad > 0 then
			fail(
				"private values (free move susp wfu mark wpo moved_from moved_fromangles)",
				table.concat(pbad, "; "),
				"C"
			)
		end
		for i = 0, 1 do
			local exp = clexp[i] or clsnap[i + 1]
			local got = clstr(i)
			if got ~= exp then
				fail(`client {i} (edict begun fixset timeout fixangles)`, got, exp)
				setcl(i, string.split(exp, "\t"), 1)
			end
		end
		if dh(sv.time) ~= c[#c - 1] then
			fail("sv.time", dh(sv.time), c[#c - 1])
			sv.time = db(c[#c - 1])
		end
		if tostring(prog.num_edicts) ~= c[#c] then
			fail("num_edicts", tostring(prog.num_edicts), c[#c])
			prog.num_edicts = num(c[#c])
		end
		if bad then
			nfailed += 1
		else
			t.ok(ctx, true)
		end
	end

	local lineno = 0
	local text = t.read("tests/vectors/movers.tsv")
	for line in string.gmatch(text, "[^\r\n]+") do
		lineno += 1
		local c = string.split(line, "\t")
		local kind = c[1]
		if kind == "QC" then
			qcidx += 1
			local want = { c[2] }
			for i = 3, #c do
				want[i - 1] = if qcslots[i - 2] == texslot and c[i] ~= "00000000" then "00000001" else c[i]
			end
			t.eq(ctx, qc[qcidx], table.concat(want, "\t"), `{label}: QC call {qcidx} (fnum, globals)`)
		elseif kind == "D" then
			local e = num(c[2])
			for i = 3, #c, 2 do
				buffer.writeu32(mirrorF, (e * nfields + num(c[i])) * 4, tonumber(c[i + 1], 16) :: number)
			end
		elseif kind == "GD" then
			for i = 2, #c, 2 do
				buffer.writeu32(mirrorG, num(c[i]) * 4, tonumber(c[i + 1], 16) :: number)
			end
		elseif kind == "P" and prog then
			privexp[num(c[2])] = privtextkey(table.concat(c, "\t", 3))
		elseif kind == "P" then -- a brush plane of the map (before the prog exists)
			local texture = tex(c[6])
			table.insert(
				planes,
				{ normal = v3(c, 2), dist = fb(c[5]), q3surfaceflags = texture.surfaceflags, texture = texture }
			)
		elseif kind == "CL" then
			clexp[num(c[2])] = table.concat(c, "\t", 3)
		elseif kind == "E" then
			finish(c)
		elseif kind == "C" then
			label = `line {lineno}: {string.sub(line, 1, 60)}`
			mirrorF = buffer.create(buffer.len(prog.edictsfields))
			buffer.copy(mirrorF, 0, prog.edictsfields)
			mirrorG = buffer.create(buffer.len(prog.globals))
			buffer.copy(mirrorG, 0, prog.globals)
			for e = 0, ned - 1 do
				privsnap[e + 1] = privkey(e)
			end
			clsnap[1], clsnap[2] = clstr(0), clstr(1)
			privexp, clexp = {}, {}
			qc, qcidx = {}, 0
			ret = call(c)
		elseif kind == "ED" then
			local n = num(c[2])
			prog.ed_free[n] = c[3] ~= "0"
			for i = 0, nfields - 1 do
				buffer.writeu32(prog.edictsfields, (n * nfields + i) * 4, tonumber(c[4 + i], 16) :: number)
			end
		elseif kind == "PS" then
			setpriv(num(c[2]), c, 3)
		elseif kind == "F" then
			prog.ed_free[num(c[2])] = c[3] ~= "0"
		elseif kind == "LINK" then
			sv_phys.SV_LinkEdict(num(c[2]))
		elseif kind == "LK" then
			local n = num(c[2])
			t.eq(
				ctx,
				fieldwords(n, "absmin", 3) .. "\t" .. fieldwords(n, "absmax", 3),
				table.concat(c, "\t", 3),
				`line {lineno}: SV_LinkEdict({n}) absmin / absmax`
			)
		elseif kind == "CLS" then
			setcl(num(c[2]), c, 3)
		elseif kind == "HC" then
			server.host_client = svs.clients[num(c[2])]
		elseif kind == "SFT" then
			sv.frametime = db(c[2])
		elseif kind == "GSET" then
			buffer.writeu32(prog.globals, num(c[2]) * 4, tonumber(c[3], 16) :: number)
		elseif kind == "NUMED" then
			prog.num_edicts = num(c[2])
		elseif kind == "FUNC" then
			funcs[c[2]] = num(c[3])
			if prog then
				prog.funcoffsets[c[2]] = num(c[3])
			end
		elseif kind == "SVS" then
			svs.maxclients = num(c[2])
			svs.clients = {}
		elseif kind == "TEX" then
			textures[num(c[2]) + 1] = {
				index = num(c[2]),
				name = "tex" .. c[2],
				supercontents = num(c[3]),
				surfaceflags = num(c[4]),
				currentmaterialflags = num(c[5]),
				basematerialflags = num(c[6]),
			}
		elseif kind == "B" then
			header = c
			planes = {}
		elseif kind == "BR" then
			local texture = tex(header[4])
			local b = collision.Collision_NewBrushFromPlanes(
				num(header[3]),
				planes,
				texture.supercontents,
				texture.surfaceflags,
				texture,
				header[5] ~= "0"
			)
			t.eq(ctx, if b then "1" else "0", c[2], "brush " .. header[2] .. " exists")
			brushes[num(header[2]) + 1] = { colbrushf = b, texture = texture, numbrushsides = 0, firstbrushside = 0 }
		elseif kind == "SF" then
			local s = num(c[2])
			surfaces[s + 1] = {
				index = s,
				texture = tex(c[3]),
				mins = v3(c, 7),
				maxs = v3(c, 10),
				num_vertices = num(c[5]),
				num_triangles = num(c[6]),
				num_firstvertex = s * num(c[5]),
				num_firsttriangle = s * num(c[6]),
				num_collisionvertices = num(c[5]),
				num_collisiontriangles = num(c[6]),
				num_firstcollisiontriangle = s * num(c[6]),
				deprecatedq3num_collisionbboxstride = num(c[4]),
				deprecatedq3collisionmarkframe = 0,
			}
		elseif kind == "SV" then
			cvert[#surfaces] = floats(c, 2)
			surfaces[#surfaces].deprecatedq3data_collisionvertex3f = cvert[#surfaces]
		elseif kind == "SE" then
			local b = buffer.create((#c - 1) * 4)
			for i = 2, #c do
				buffer.writei32(b, (i - 2) * 4, num(c[i]))
			end
			lelem[#surfaces] = b
			surfaces[#surfaces].deprecatedq3data_collisionelement3i = b
		elseif kind == "SR" then
			rvert[#surfaces] = floats(c, 2)
		elseif kind == "SB" then
			surfaces[#surfaces].deprecatedq3data_collisionbbox6f = if #c > 1 then floats(c, 2) else nil
		elseif kind == "ND" then
			table.insert(nodelines, c)
		elseif kind == "LF" then
			table.insert(leaflines, c)
		elseif kind == "LB" or kind == "LS" then
			local b = buffer.create((#c - 1) * 4)
			for i = 2, #c do
				buffer.writei32(b, (i - 2) * 4, num(c[i]))
			end
			if kind == "LB" then
				leafbrushes = b
			else
				leafsurfaces = b
			end
		elseif kind == "MODEL" then
			buildmodel(c)
		elseif kind == "CVAR" then
			if not cvar.Cvar_FindVar(c[2]) then
				cvar.Cvar_RegisterVariable(cvar.static(0, c[2], c[3], ""))
			end
			cvar.Cvar_SetValue(c[2], num(c[3]))
		elseif kind == "FIELD" then
			fieldofs[c[2]] = num(c[3])
		elseif kind == "NFIELDS" then
			nfields = num(c[2])
			for name, o in fieldofs do
				local width = if name == "mins"
						or name == "maxs"
						or name == "origin"
						or name == "angles"
						or name == "avelocity"
						or name == "absmin"
						or name == "absmax"
						or name == "velocity"
						or name == "oldorigin"
						or name == "view_ofs"
						or name == "v_angle"
						or name == "punchangle"
					then 3
					else 1
				for k = 0, width - 1 do
					fieldname[o + k] = if width == 3 then `{name}[{k}]` else name
				end
			end
		elseif kind == "GLOBAL" then
			globalofs[c[2]] = num(c[3])
		elseif kind == "NGLOBALS" then
			nglobals = num(c[2])
			for name, o in globalofs do
				local width = if name == "trace_endpos" or name == "trace_plane_normal" then 3 else 1
				for k = 0, width - 1 do
					globalname[o + k] = if width == 3 then `{name}[{k}]` else name
				end
			end
			texslot = globalofs.trace_dphittexturename
		elseif kind == "QCSLOTS" then
			for i = 2, #c do
				qcslots[i - 1] = num(c[i])
			end
		elseif kind == "NED" then
			ned = num(c[2])
			prog = prvm_edict.NewProg("server")
			prog.fieldofs_cache = fieldofs
			prog.globalofs_cache = globalofs
			prog.entityfields = nfields
			prog.numglobals = nglobals
			prog.globals = buffer.create(nglobals * 4)
			prog.max_edicts = ned
			prog.limit_edicts = ned
			prog.reserved_edicts = 0
			prog.num_edicts = ned
			prvm_edict.PRVM_MEM_Alloc(prog)
			t.eq(ctx, prog.num_edicts, ned, "num_edicts")
			prog.funcoffsets = table.clone(funcs) -- PRVM_serverfunction(name)
			-- a one-byte string table (""), so string 0 is "" and a temp string's number is never 0 (the C stub's
			-- PRVM_SetTempString returns 1: the test compares trace_dphittexturename only with zero)
			prog.strings = "\0"
			prog.stringssize = 1
			-- prog->ExecuteProgram: the call with the globals the C stub prints, then the scripted effect
			prog.ExecuteProgram = function(p: any, fnum: number, _msg: string)
				local parts = { tostring(fnum) }
				for i, slot in qcslots do
					parts[i + 1] = gword(p.globals, slot)
				end
				table.insert(qc, table.concat(parts, "\t"))
				effect(fnum)
			end
			cvar.prvm_prog_list[0] = prog
		elseif kind == "SMODEL" then
			local idx, src = num(c[2]), num(c[3])
			local m = models[src + 1]
			if c[4] == "alias" then
				m = table.clone(m)
				m.brush = table.clone(m.brush)
			end
			m.type = if c[4] == "alias" then "mod_alias" else "mod_brushq3"
			m.numframes = num(c[5])
			m.normalmins, m.normalmaxs = v3(c, 6), v3(c, 9)
			m.yawmins, m.yawmaxs = v3(c, 12), v3(c, 15)
			m.rotatedmins, m.rotatedmaxs = v3(c, 18), v3(c, 21)
			sv.models[idx] = m
			if idx == 1 then
				sv.worldmodel = m
			end
		elseif kind == "TIME" then
			sv.time = db(c[2])
		elseif kind == "WORLD" then
			sv.world = world.new()
			prog.ed_area = nil
			world.World_SetSize(sv.world, "maps/movers.bsp", v3(c, 2), v3(c, 5), prog)
		elseif kind == "G" then
			local w = sv.world
			local parts = {}
			for _, v in { w.areagrid_mins, w.areagrid_maxs, w.areagrid_size, w.areagrid_bias, w.areagrid_scale } do
				table.insert(parts, vh(v))
			end
			t.eq(ctx, table.concat(parts, "\t"), table.concat(c, "\t", 2), `line {lineno}: World_SetSize grid`)
		elseif kind == "END" then
			t.ok(ctx, true, "reached the end of the vector file")
			t.eq(ctx, nfailed, 0, `calls that differ from C (of {ncalls})`)
		elseif kind == "EDICTNUMERROR" then
			t.ok(ctx, false, `line {lineno}: the C program stopped: {line}`)
		end
	end
	console.sink = oldsink
	prvm_edict.realtime = oldrealtime
	sv.world, sv.models, sv.worldmodel, sv.time, sv.frametime =
		oldsv.world, oldsv.models, oldsv.worldmodel, oldsv.time, oldsv.frametime
	svs.clients, svs.maxclients = oldsvs.clients, oldsvs.maxclients
	server.host_client = oldhost
	cvar.prvm_prog_list[0] = oldprog
	cvar.reset()
end
