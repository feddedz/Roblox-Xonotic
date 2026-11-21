--!strict
-- M2-RUNNER progress test: real progs.dat through SV_VM_Setup (engine/sv_main.luau), layout checks, and a
-- first run of the world spawn function on interpreter and AOT with all builtins stubbed. Both must agree
-- exactly; the printout shows which builtins worldspawn needs first. Needs game data (skips in CI).
local t = require("../_lib/t")
local fs = require("@lune/fs")
local sv_main = require("../../engine/sv_main")
local prvm_edict = require("../../engine/prvm_edict")
local prvm_exec = require("../../engine/prvm_exec")
local prvm_offsets = require("../../engine/prvm_offsets")
local qcrt = require("../../engine/_port/qcrt")
local f32 = require("../../engine/_port/f32")
local cvar = require("../../engine/cvar")
local cmd = require("../../engine/cmd")

return function(ctx: t.Ctx)
	local dat, gen = "work/vfs-high/progs.dat", "game/generated/progs/init.luau"
	if not (fs.isFile(dat) and fs.isFile(gen)) then
		t.skip(ctx, "needs work/vfs-high/progs.dat and tools/build.sh output")
		return
	end
	local data = buffer.fromstring(fs.readFile(dat))
	local logs: { { string } } = { {}, {} }
	local progs = {}
	for k = 1, 2 do
		progs[k] = sv_main.SV_VM_Setup(data, {
			onStub = function(n: number, cname: string, _p: any)
				table.insert(logs[k], string.format("#%d %s", n, cname))
			end,
		})
		progs[k].warning = function(_m: string) end
	end
	local pI, pA = progs[1], progs[2];
	(require :: any)("../../game/generated/progs").install(pA, { qcrt = qcrt, f32 = f32 })

	-- layout: required fields/globals appended unconditionally (prvm_edict.c L2049-2083)
	local reqF, reqG = 0, 0
	for _, d in prvm_offsets.server_fields do
		reqF += if d.type == 3 then 3 else 1
	end
	for _, d in prvm_offsets.server_globals do
		reqG += if d.type == 3 then 3 else 1
	end
	t.eq(ctx, pI.entityfields, pI.progs_entityfields + reqF, "entityfields = file + required fields")
	t.eq(ctx, pI.numglobals, pI.progs_numglobals + reqG, "numglobals = file + required globals")
	t.eq(ctx, pI.numbuiltins, 644, "vm_sv_numbuiltins")

	-- every builtin number progs.dat references exists in vm_sv_builtins[]
	local missing = {}
	for fnum = 0, pI.numfunctions - 1 do
		local f = pI.functions[fnum + 1]
		if f.first_statement < 0 then
			local n = -f.first_statement
			if not (n < pI.numbuiltins and pI.builtins[n]) then
				table.insert(missing, string.format("#%d %s", n, prvm_edict.PRVM_GetString(pI, f.s_name)))
			end
		end
	end
	-- Verified 2026-11-20: these are NULL in vm_sv_builtins[] @xonotic-v0.8.6 although progs.dat declares them,
	-- so calling one is "No such builtin" in real DarkPlaces too (the QC checks extensions first). Pinned so a
	-- change is noticed; the port must keep them NULL.
	table.sort(missing)
	t.eq(
		ctx,
		table.concat(missing, ", "),
		"#352 registercommand, #566 findbox, #566 findbox_tofield, #608 parseentitydata",
		"builtins declared by progs.dat that are NULL in the engine"
	)

	-- world spawn function, self = world
	local _, fnum = prvm_edict.PRVM_ED_FindFunction(pI, "spawnfunc_worldspawn")
	t.ok(ctx, fnum ~= nil, "spawnfunc_worldspawn exists")
	local selfdef = prvm_edict.PRVM_ED_FindGlobal(pI, "self")
	t.ok(ctx, selfdef ~= nil, "global self exists")
	if fnum == nil or selfdef == nil then
		return
	end
	for _, p in progs do
		buffer.writei32(p.globals, selfdef.ofs * 4, 0)
	end
	-- each run starts from the same (empty: no configs) cvar state; ported cvar builtins change it
	local function fresh(p: any)
		cvar.reset()
		cmd.reset()
		prvm_edict.PRVM_Prog_Load_AutoCvars(p)
		p.loaded = true
		cvar.prvm_prog_list[0] = p
	end
	local g0 = buffer.tostring(pI.globals)
	fresh(pI)
	local okI, errI = pcall(prvm_exec.PRVM_ExecuteProgram, pI, fnum, "worldspawn")
	buffer.copy(pA.globals, 0, buffer.fromstring(g0))
	fresh(pA)
	local okA, errA = pcall(qcrt.ExecuteProgram, pA, fnum, "worldspawn")
	t.eq(ctx, okA, okI, "worldspawn: same outcome")
	t.eq(ctx, tostring(errA), tostring(errI), "worldspawn: same error")
	t.ok(ctx, buffer.tostring(pA.globals) == buffer.tostring(pI.globals), "worldspawn: same globals")
	t.eq(ctx, table.concat(logs[2], "|"), table.concat(logs[1], "|"), "worldspawn: same builtin sequence")
	local seen, order = {}, {}
	for _, l in logs[1] do
		if not seen[l] then
			seen[l] = true
			table.insert(order, l)
		end
	end
	print(
		string.format(
			"  worldspawn (all builtins stubbed): ok=%s, %d builtin calls, %d distinct; result: %s",
			tostring(okI),
			#logs[1],
			#order,
			if okI then "completed" else tostring(errI)
		)
	)
	print("  first distinct builtins: " .. table.concat(order, ", ", 1, math.min(#order, 24)))
end
