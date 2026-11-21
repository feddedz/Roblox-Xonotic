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
	prvm_edict.realtime = 0
end
