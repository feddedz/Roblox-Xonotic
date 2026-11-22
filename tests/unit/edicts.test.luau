--!strict
-- engine/prvm_edict.luau edict allocation (prvm_edict.c PRVM_MEM_Alloc / ED_Alloc / ED_Free / ED_CanAlloc).
local t = require("../_lib/t")
local cvar = require("../../engine/cvar")
local prvm_edict = require("../../engine/prvm_edict")

return function(ctx: t.Ctx)
	cvar.reset() -- prvm_reuseedicts_* fall back to their registered defaults (2 s, 1)
	local prog: any = prvm_edict.NewProg("server")
	prog.entityfields = 4
	prog.max_edicts = 4
	prog.reserved_edicts = 2
	prog.limit_edicts = 600
	prvm_edict.realtime = 100
	prog.starttime = 100
	prvm_edict.PRVM_MEM_Alloc(prog)
	t.eq(ctx, prog.num_edicts, 3, "num_edicts = 1 + reserved")
	local a = prvm_edict.PRVM_ED_Alloc(prog)
	t.eq(ctx, a, 3, "first free slot after the reserved ones")
	local b = prvm_edict.PRVM_ED_Alloc(prog)
	t.eq(ctx, b, 4)
	t.ok(ctx, prog.max_edicts >= 5, "grew past max_edicts")
	buffer.writef32(prog.edictsfields, (a * prog.entityfields) * 4, 7)
	prvm_edict.PRVM_ED_Free(prog, a)
	t.ok(ctx, prog.ed_free[a], "freed")
	-- same frame: never reused (neverinsameframe), startup window (freed < starttime + 2): reusable next frame
	t.eq(ctx, prvm_edict.PRVM_ED_Alloc(prog), 5, "not reused in the same frame")
	prvm_edict.realtime = 100.2
	t.eq(ctx, prvm_edict.PRVM_ED_Alloc(prog), a, "reused during the startup window")
	t.eq(ctx, buffer.readf32(prog.edictsfields, (a * prog.entityfields) * 4), 0, "fields cleared")
	-- after startup: blocked for 1 s
	prvm_edict.realtime = 200
	prvm_edict.PRVM_ED_Free(prog, a)
	prvm_edict.realtime = 200.5
	t.ok(ctx, prvm_edict.PRVM_ED_Alloc(prog) ~= a, "blocked < 1 s after free")
	prvm_edict.realtime = 201.5
	t.eq(ctx, prvm_edict.PRVM_ED_Alloc(prog), a, "free again after 1 s")
	prvm_edict.PRVM_ED_Free(prog, 1)
	t.ok(ctx, not prog.ed_free[1], "reserved edicts are never freed")
	-- find / findfloat / findflags / findchain* on field slots (0: string, 1: float, 3: chain)
	local prvm_cmds = require("../../engine/prvm_cmds")
	prog.globals = buffer.create(4 * 64)
	prog.strings = "\0" -- offset 0 is string_null, as in a real progs.dat
	prog.stringssize = 1
	prog.argc = 3
	local function E(e: number, f: number): number
		return (e * prog.entityfields + f) * 4
	end
	local str = prvm_edict.PRVM_SetTempString(prog, "item")
	for e = 1, prog.num_edicts - 1 do
		if not prog.ed_free[e] then
			buffer.writei32(prog.edictsfields, E(e, 0), 0)
			buffer.writef32(prog.edictsfields, E(e, 1), 0)
		end
	end
	local live = {}
	for e = 1, prog.num_edicts - 1 do
		if not prog.ed_free[e] then
			table.insert(live, e)
		end
	end
	local x, y = live[2], live[3]
	buffer.writei32(prog.edictsfields, E(x, 0), str)
	buffer.writei32(prog.edictsfields, E(y, 0), str)
	buffer.writef32(prog.edictsfields, E(y, 1), 6)
	local function ret(): number
		return buffer.readi32(prog.globals, 4)
	end
	buffer.writei32(prog.globals, 16, 0)
	buffer.writei32(prog.globals, 28, 0)
	buffer.writei32(prog.globals, 40, prvm_edict.PRVM_SetTempString(prog, "item"))
	prvm_cmds.VM_find(prog)
	t.eq(ctx, ret(), x, "find first")
	buffer.writei32(prog.globals, 16, x)
	prvm_cmds.VM_find(prog)
	t.eq(ctx, ret(), y, "find next")
	buffer.writei32(prog.globals, 16, y)
	prvm_cmds.VM_find(prog)
	t.eq(ctx, ret(), 0, "find end -> world")
	buffer.writei32(prog.globals, 16, 0)
	buffer.writei32(prog.globals, 28, 1)
	buffer.writef32(prog.globals, 40, 2)
	prvm_cmds.VM_findflags(prog)
	t.eq(ctx, ret(), y, "findflags 6 & 2")
	buffer.writef32(prog.globals, 40, 6)
	prvm_cmds.VM_findfloat(prog)
	t.eq(ctx, ret(), y, "findfloat")
	buffer.writei32(prog.globals, 16, 0)
	buffer.writei32(prog.globals, 28, prvm_edict.PRVM_SetTempString(prog, "item"))
	buffer.writei32(prog.globals, 40, 3)
	prvm_cmds.VM_findchain(prog)
	t.eq(ctx, ret(), y, "chain head = last match")
	t.eq(ctx, buffer.readi32(prog.edictsfields, E(y, 3)), x, "chain link")
	t.eq(ctx, buffer.readi32(prog.edictsfields, E(x, 3)), 0, "chain end")
	prvm_edict.realtime = 0
end
