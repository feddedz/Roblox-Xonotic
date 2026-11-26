--!strict
-- engine/sv_move.luau (all of sv_move.c), the world builtins of engine/svvm_cmds.luau (setorigin, setsize,
-- traceline, tracebox, tracetoss, findradius, walkmove, droptofloor, checkbottom, pointcontents, copyentity),
-- VM_SetTraceGlobals / VM_changeyaw of engine/prvm_cmds.luau and the SVVM_* edict hooks of engine/sv_main.luau
-- against the release's C compiled unchanged (tests/vectors/svmove.tsv, tools/testgen/svmove_vectors.sh). The
-- vector file carries the synthetic map of trace_vectors.c, the server of svphys_vectors.c, the QuakeC field /
-- global offsets and every state change the generator makes; the test rebuilds that server, makes every call
-- the C program made and compares everything the call changed: the edicts' fields and private data (free,
-- suspendedinairflag, mark, areamins / areamaxs), the globals, the QC touch calls, prog->error_cmd messages,
-- return values and the c_yes / c_no counters. The libm cos / sin lines of the file (CS) are checked by
-- tests/unit/sv_move_libm_ref.test.luau.
local t = require("../_lib/t")
local bih = require("../../engine/bih")
local collision = require("../../engine/collision")
local console = require("../../engine/console")
local cvar = require("../../engine/cvar")
local f32 = require("../../engine/_port/f32")
local libc = require("../../engine/_port/libc")
local model_brush = require("../../engine/model_brush")
local prvm_edict = require("../../engine/prvm_edict")
local server = require("../../engine/server")
local sv_main = require("../../engine/sv_main")
local sv_move = require("../../engine/sv_move")
local sv_phys = require("../../engine/sv_phys")
local svvm_cmds = require("../../engine/svvm_cmds")
local world = require("../../engine/world")

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
	local function fbits(v: number): number
		buffer.writef32(scratch, 0, v)
		return buffer.readu32(scratch, 0)
	end
	local function num(s: string): number
		return tonumber(s) :: number
	end
	local function v3(c: { string }, i: number): { number }
		return { fb(c[i]), fb(c[i + 1]), fb(c[i + 2]) }
	end
	local function floats(c: { string }, first: number): buffer
		local b = buffer.create((#c - first + 1) * 4)
		for i = first, #c do
			buffer.writeu32(b, (i - first) * 4, tonumber(c[i], 16) :: number)
		end
		return b
	end
	local function bstr(b: boolean): string
		return if b then "1" else "0"
	end

	cvar.reset()
	collision.Collision_Init()
	model_brush.Mod_BrushInit()

	local oldsink = console.sink
	console.sink = function(_line: string) end -- VM_Warning, Con_DPrintf, Collision_ValidateBrush

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
		local m = model_brush.newmodel("svmove" .. c[2])
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
	local oldsv = { world = sv.world, models = sv.models, worldmodel = sv.worldmodel, time = sv.time }
	local oldprog = cvar.prvm_prog_list[0]
	sv.models = {}
	local fieldofs: { [string]: number }, globalofs: { [string]: number } = {}, {}
	local nfields, nglobals, ned = 0, 0, 0
	local prog: any = nil
	local gtex = -1 -- the global slot of trace_dphittexturename

	-- what the current call produced, compared in order with the C lines after the command
	local produced: { string } = {}
	local pidx = 0
	local label = ""
	local mismatches: { [string]: number } = {}
	local function check(got: string?, want: string, what: string)
		if got ~= want then
			local kind = string.match(label, "^line %d+: (.*)$") or label
			mismatches[kind] = (mismatches[kind] or 0) + 1
		end
		t.eq(ctx, got, want, `{label}: {what}`)
	end

	-- an edict's state words: 0 free, 1 suspendedinairflag, 2 mark, 3-5 areamins, 6-8 areamaxs, 9.. fields
	local function privwords(n: number): { number }
		local area = world.edictarea(prog, n)
		local mark = (prog.ed_mark and prog.ed_mark[n]) or 0
		return {
			if prog.ed_free[n] then 1 else 0,
			if prog.ed_suspendedinairflag and prog.ed_suspendedinairflag[n] then 1 else 0,
			mark % 4294967296,
			fbits(area.areamins[1]),
			fbits(area.areamins[2]),
			fbits(area.areamins[3]),
			fbits(area.areamaxs[1]),
			fbits(area.areamaxs[2]),
			fbits(area.areamaxs[3]),
		}
	end
	local function setword(n: number, i: number, w: number)
		if i == 0 then
			prog.ed_free[n] = w ~= 0
		elseif i == 1 then
			prog.ed_suspendedinairflag[n] = w ~= 0
		elseif i == 2 then
			prog.ed_mark[n] = if w >= 0x80000000 then w - 0x100000000 else w
		elseif i >= 9 then
			buffer.writeu32(prog.edictsfields, (n * nfields + i - 9) * 4, w)
		else
			error("the generator never sets the area of an edict")
		end
	end
	local prefields: buffer = buffer.create(0)
	local prepriv: { { number } } = {}
	local preglobals: buffer = buffer.create(0)
	local cy0, cn0 = 0, 0
	local function snapshot()
		prefields = buffer.create(buffer.len(prog.edictsfields))
		buffer.copy(prefields, 0, prog.edictsfields)
		preglobals = buffer.create(buffer.len(prog.globals))
		buffer.copy(preglobals, 0, prog.globals)
		for n = 0, ned - 1 do
			prepriv[n] = privwords(n)
		end
		cy0, cn0 = sv_move.c_yes, sv_move.c_no
	end
	local function results()
		local rowlen = nfields * 4
		for n = 0, ned - 1 do
			local p = privwords(n)
			local pp = prepriv[n]
			local samepriv = true
			for i = 1, 9 do
				if p[i] ~= pp[i] then
					samepriv = false
				end
			end
			local off = n * rowlen
			if
				not samepriv
				or buffer.readstring(prefields, off, rowlen) ~= buffer.readstring(prog.edictsfields, off, rowlen)
			then
				local parts = { "D", tostring(n) }
				for i = 1, 9 do
					if p[i] ~= pp[i] then
						table.insert(parts, string.format("%d:%08x", i - 1, p[i]))
					end
				end
				for i = 0, nfields - 1 do
					local a = buffer.readu32(prefields, off + i * 4)
					local b = buffer.readu32(prog.edictsfields, off + i * 4)
					if a ~= b then
						table.insert(parts, string.format("%d:%08x", 9 + i, b))
					end
				end
				table.insert(produced, table.concat(parts, "\t"))
			end
		end
		local gl = { "GL" }
		for i = 0, nglobals - 1 do
			local g = buffer.readu32(prog.globals, i * 4)
			if i == gtex then
				if g ~= 0 then
					table.insert(gl, `{i}:s:{prvm_edict.PRVM_GetString(prog, g)}`)
				else
					table.insert(gl, string.format("%d:%08x", i, g))
				end
			elseif g ~= buffer.readu32(preglobals, i * 4) then
				table.insert(gl, string.format("%d:%08x", i, g))
			end
		end
		table.insert(produced, table.concat(gl, "\t"))
		table.insert(produced, `CY\t{sv_move.c_yes - cy0}\t{sv_move.c_no - cn0}`)
	end
	local function escape(s: string): string
		return (string.gsub(string.gsub(s, "\n", "\\n"), "\t", "\\t"))
	end
	-- runs one call: fn returns the RV text or nil
	local function run(fn: () -> string?)
		if pidx < #produced then
			check(produced[pidx + 1], "(nothing)", "line the C program did not print")
		end
		produced, pidx = {}, 0
		snapshot()
		local ok, err = pcall(fn)
		if ok then
			if err ~= nil then
				table.insert(produced, "RV\t" .. err)
			end
		elseif type(err) == "table" and err.smv_error then
			table.insert(produced, "ERR\t" .. escape(err.smv_error))
		else
			table.insert(produced, "LUAERROR\t" .. tostring(err))
		end
		results()
	end

	local B = svvm_cmds.PORTED
	local builtins: { [string]: (any) -> () } = {
		setorigin = B.VM_SV_setorigin,
		setsize = B.VM_SV_setsize,
		traceline = B.VM_SV_traceline,
		tracebox = B.VM_SV_tracebox,
		tracetoss = B.VM_SV_tracetoss,
		findradius = B.VM_SV_findradius,
		walkmove = B.VM_SV_walkmove,
		droptofloor = B.VM_SV_droptofloor,
		checkbottom = B.VM_SV_checkbottom,
		pointcontents = B.VM_SV_pointcontents,
		copyentity = B.VM_SV_copyentity,
		movetogoal = sv_move.VM_SV_MoveToGoal,
	}

	local lineno = 0
	for line in string.gmatch(t.read("tests/vectors/svmove.tsv"), "[^\r\n]+") do
		lineno += 1
		local c = string.split(line, "\t")
		local kind = c[1]
		if kind == "TEX" then
			textures[num(c[2]) + 1] = {
				index = num(c[2]),
				name = "tex" .. c[2],
				supercontents = num(c[3]),
				surfaceflags = num(c[4]),
				currentmaterialflags = num(c[5]),
				basematerialflags = num(c[6]),
			}
		elseif kind == "B" and tonumber(c[2]) == nil then
			-- a builtin call: B name argc
			label = `line {lineno}: B {c[2]}`
			local fn = builtins[c[2]]
			local argc = num(c[3])
			run(function(): string?
				prog.argc = argc
				fn(prog)
				return nil
			end)
		elseif kind == "B" then
			header = c
			planes = {}
		elseif kind == "P" then
			local texture = tex(c[6])
			table.insert(
				planes,
				{ normal = v3(c, 2), dist = fb(c[5]), q3surfaceflags = texture.surfaceflags, texture = texture }
			)
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
			-- the cvars are registered with the value the C program gives them (their defaults first)
			if not cvar.Cvar_FindVar(c[2]) then
				cvar.Cvar_RegisterVariable(cvar.static(0, c[2], c[3], ""))
			end
			cvar.Cvar_SetValue(c[2], num(c[3]))
		elseif kind == "FIELD" then
			fieldofs[c[2]] = num(c[3])
		elseif kind == "NFIELDS" then
			nfields = num(c[2])
		elseif kind == "GLOBAL" then
			globalofs[c[2]] = num(c[3])
		elseif kind == "NGLOBALS" then
			nglobals = num(c[2])
			gtex = globalofs.trace_dphittexturename
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
			prog.ed_mark = {}
			prog.ed_suspendedinairflag = {}
			prog.xfunction = 1
			-- a progs string table starts with the empty string, so no tempstring is at offset 0 (= no string)
			prog.strings = "\0"
			prog.stringssize = 1
			t.eq(ctx, prog.num_edicts, ned, "num_edicts")
			prog.error_cmd = function(msg: string)
				error({ smv_error = msg }, 0)
			end
			-- prog->ExecuteProgram: the touch call with every global, as the C stub prints it
			prog.ExecuteProgram = function(p: any, fnum: number, _msg: string)
				local parts = { "TOUCH", tostring(fnum) }
				for i = 0, nglobals - 1 do
					table.insert(parts, string.format("%08x", buffer.readu32(p.globals, i * 4)))
				end
				table.insert(produced, table.concat(parts, "\t"))
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
			world.World_SetSize(sv.world, "maps/svphys.bsp", v3(c, 2), v3(c, 5), prog)
		elseif kind == "E" then
			local n = num(c[2])
			for i = 3, #c do
				local slot, w = string.match(c[i], "^(%d+):(%x+)$")
				setword(n, num(slot :: string), tonumber(w, 16) :: number)
			end
		elseif kind == "GS" then
			for i = 2, #c do
				local slot, w = string.match(c[i], "^(%d+):(%x+)$")
				buffer.writeu32(prog.globals, num(slot :: string) * 4, tonumber(w, 16) :: number)
			end
		elseif kind == "S" then
			libc.srand(num(c[2]))
		elseif kind == "LINK" then
			label = `line {lineno}: LINK {c[2]}`
			sv_phys.SV_LinkEdict(num(c[2]))
		elseif kind == "LK" then
			local n = num(c[2])
			local parts = {}
			for _, f in { "absmin", "absmax" } do
				for i = 0, 2 do
					table.insert(
						parts,
						string.format("%08x", buffer.readu32(prog.edictsfields, (n * nfields + fieldofs[f] + i) * 4))
					)
				end
			end
			local p = privwords(n)
			for i = 4, 9 do
				table.insert(parts, string.format("%08x", p[i]))
			end
			check(
				table.concat(parts, "\t"),
				table.concat(c, "\t", 3),
				"SV_LinkEdict absmin / absmax / areamins / areamaxs"
			)
		elseif kind == "CB" then
			label = `line {lineno}: CB SV_CheckBottom`
			run(function(): string?
				return bstr(sv_move.SV_CheckBottom(num(c[2])))
			end)
		elseif kind == "MS" then
			label = `line {lineno}: MS SV_movestep`
			run(function(): string?
				return bstr(sv_move.SV_movestep(num(c[2]), v3(c, 3), c[6] ~= "0", c[7] ~= "0", c[8] ~= "0"))
			end)
		elseif kind == "SD" then
			label = `line {lineno}: SD SV_StepDirection`
			run(function(): string?
				return bstr(sv_move.SV_StepDirection(num(c[2]), fb(c[3]), fb(c[4])))
			end)
		elseif kind == "NC" then
			label = `line {lineno}: NC SV_NewChaseDir`
			run(function(): string?
				sv_move.SV_NewChaseDir(num(c[2]), num(c[3]), fb(c[4]))
				return nil
			end)
		elseif kind == "CE" then
			label = `line {lineno}: CE SV_CloseEnough`
			run(function(): string?
				return bstr(sv_move.SV_CloseEnough(num(c[2]), num(c[3]), fb(c[4])))
			end)
		elseif kind == "HB" then
			label = `line {lineno}: HB SVVM_begin_increase_edicts`
			run(function(): string?
				sv_main.SVVM_begin_increase_edicts(prog)
				return nil
			end)
		elseif kind == "HE" then
			label = `line {lineno}: HE SVVM_end_increase_edicts`
			run(function(): string?
				sv_main.SVVM_end_increase_edicts(prog)
				return nil
			end)
		elseif kind == "HF" then
			label = `line {lineno}: HF SVVM_free_edict`
			run(function(): string?
				sv_main.SVVM_free_edict(prog, num(c[2]))
				return nil
			end)
		elseif kind == "TOUCH" or kind == "ERR" or kind == "RV" or kind == "D" or kind == "GL" or kind == "CY" then
			pidx += 1
			check(produced[pidx], line, kind)
		elseif kind == "END" then
			if pidx < #produced then
				check(produced[pidx + 1], "(nothing)", "line the C program did not print")
			end
			t.ok(ctx, true, "reached the end of the vector file")
		end
		-- CS lines (glibc cos / sin of the yaws): tests/unit/sv_move_libm_ref.test.luau
	end
	local bad = {}
	for k, v in mismatches do
		table.insert(bad, `{k}={v}`)
	end
	if #bad > 0 then
		table.sort(bad)
		print(`sv_move_ref mismatches by call: {table.concat(bad, " ")}`)
	end
	console.sink = oldsink
	sv.world, sv.models, sv.worldmodel, sv.time = oldsv.world, oldsv.models, oldsv.worldmodel, oldsv.time
	cvar.prvm_prog_list[0] = oldprog
	cvar.reset()
end
