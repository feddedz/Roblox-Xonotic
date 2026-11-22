--!strict
-- M2-RUNNER: PRVM_ED_LoadFromFile on a stock map's entity lump (Q3 BSP lump 0), after the real config chain.
-- The first entity (worldspawn) loads into edict 0, every other entity is allocated and its spawn function
-- runs with the compiled QuakeC (world builtins are still stubs). Xonotic only queues them there (its
-- SV_OnEntityPreSpawnFunction sets __spawnfunc_expecting, lib/_all.inc); the first StartFrame runs the world
-- constructor (the real worldspawn), whose end spawns the queue (__spawnfunc_spawn_all). Needs game data.
local t = require("../_lib/t")
local lfs = require("@lune/fs")
local console = require("../../engine/console")
local fs = require("../../engine/fs")
local host = require("../../engine/host")
local sv_main = require("../../engine/sv_main")
local prvm_edict = require("../../engine/prvm_edict")
local qcrt = require("../../engine/_port/qcrt")
local f32 = require("../../engine/_port/f32")
local provider = require("../_lib/vfs_provider")

-- entity lump of a Q3 (IBSP 46) map: header "IBSP", version, then 17 lumps of (offset, length); lump 0
local function entities(path: string): string
	local b = buffer.fromstring(lfs.readFile(path))
	assert(buffer.readstring(b, 0, 4) == "IBSP", "not a Q3 bsp")
	local ofs, len = buffer.readi32(b, 8), buffer.readi32(b, 12)
	return buffer.readstring(b, ofs, len)
end

return function(ctx: t.Ctx)
	local dat, gen, map =
		"work/vfs-high/progs.dat", "game/generated/progs/init.luau", "work/vfs-high/maps/stormkeep.bsp"
	local p = provider("high")
	if not (p and lfs.isFile(dat) and lfs.isFile(gen) and lfs.isFile(map)) then
		t.skip(ctx, "needs work/vfs-high and tools/build.sh output")
		return
	end
	console.sink = function(_l: string) end
	fs.SetProvider(p)
	host.Host_Init_Dedicated()
	local stubs: { [string]: number } = {}
	local prog = sv_main.SV_VM_Setup(buffer.fromstring(lfs.readFile(dat)), {
		onStub = function(_n: number, cname: string, _p: any)
			stubs[cname] = (stubs[cname] or 0) + 1
		end,
	})
	prog.warning = function(_m: string) end
	(require :: any)("../../game/generated/progs").install(prog, { qcrt = qcrt, f32 = f32 })
	local ents = entities(map)
	local nbraces = select(2, string.gsub(ents, "\n{", ""))
	local ok, err = pcall(prvm_edict.PRVM_ED_LoadFromFile, prog, ents)
	local queued = prog.num_edicts
	-- first server frame: StartFrame with self = world (sv_phys.c SV_Physics; frame loop is M4)
	local _, sf = prvm_edict.PRVM_ED_FindFunction(prog, "StartFrame")
	buffer.writei32(prog.globals, (prvm_edict.PRVM_ED_FindGlobal(prog, "self") :: any).ofs * 4, 0)
	local ok2, err2 = pcall(prvm_edict.ExecuteProgram, prog, sf :: number, "StartFrame")
	fs.SetProvider(nil)
	console.sink = function(l: string)
		print(l)
	end
	local live = 0
	for e = 1, prog.num_edicts - 1 do
		if not prog.ed_free[e] then
			live += 1
		end
	end
	local names = {}
	for k, v in stubs do
		table.insert(names, string.format("%s x%d", k, v))
	end
	table.sort(names)
	print(
		string.format(
			"  stormkeep: %d entity blocks, load %s (%d edicts queued); first StartFrame %s, num_edicts %d, %d live; stubs: %s",
			nbraces + 1,
			if ok then "completed" else "stopped: " .. tostring(err),
			queued,
			if ok2 then "completed" else "stopped: " .. tostring(err2),
			prog.num_edicts,
			live,
			table.concat(names, ", ")
		)
	)
	t.ok(ctx, ok, "PRVM_ED_LoadFromFile completes: " .. tostring(err))
	t.ok(ctx, queued > 50, "entities were allocated")
	-- the first StartFrame stops in the warpzone setup today (needs getsurfacetexture / brush models, M3)
	t.ok(ctx, prog.num_edicts > queued, "StartFrame spawned the queued map entities")
	local cn = prvm_edict.FieldOfs(prog, "classname")
	t.eq(
		ctx,
		prvm_edict.PRVM_GetString(prog, buffer.readi32(prog.edictsfields, cn * 4)),
		"worldspawn",
		"edict 0 is worldspawn"
	)
	-- putentityfieldstring / getentityfieldstring / entityfieldtype on a live entity
	local prvm_cmds = require("../../engine/prvm_cmds")
	local function fieldindex(name: string): number
		local _, i = prvm_edict.PRVM_ED_FindField(prog, name)
		return (i :: number) - 1
	end
	local live1 = 1
	while prog.ed_free[live1] do
		live1 += 1
	end
	local function put(field: string, value: string): number
		prog.argc = 3
		buffer.writef32(prog.globals, 16, fieldindex(field))
		buffer.writei32(prog.globals, 28, live1)
		buffer.writei32(prog.globals, 40, prvm_edict.PRVM_SetTempString(prog, value))
		prvm_cmds.VM_putentityfieldstring(prog)
		return buffer.readf32(prog.globals, 4)
	end
	local function get(field: string): string
		prog.argc = 2
		buffer.writef32(prog.globals, 16, fieldindex(field))
		buffer.writei32(prog.globals, 28, live1)
		prvm_cmds.VM_getentityfieldstring(prog)
		return prvm_edict.PRVM_GetString(prog, buffer.readi32(prog.globals, 4))
	end
	t.eq(ctx, put("origin", " 1 -2.5 300"), 1)
	t.eq(ctx, get("origin"), "1 -2.5 300", "vector round trip (%.9g)")
	t.eq(ctx, put("netname", 'a"b\nc'), 1)
	t.eq(ctx, get("netname"), 'a\\"b\\nc', "UglyValueString escapes quote and newline")
	prog.argc = 1
	buffer.writef32(prog.globals, 16, fieldindex("origin"))
	prvm_cmds.VM_entityfieldtype(prog)
	t.eq(ctx, buffer.readf32(prog.globals, 4), 3, "ev_vector")
end
