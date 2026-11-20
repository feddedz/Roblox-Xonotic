--!strict
-- CI-runnable AOT check: hand-assembled programs (tests/_lib/qcasm.luau) are compiled with
-- tools/qcaot/compile.py and must leave exactly the same state as the reference interpreter.
-- (Real-program coverage: tests/integration/qcaot_diff.test.luau.)
local t = require("../_lib/t")
local fs = require("@lune/fs")
local process = require("@lune/process")
local qcasm = require("../_lib/qcasm")
local prvm_edict = require("../../engine/prvm_edict")
local prvm_exec = require("../../engine/prvm_exec")
local qcrt = require("../../engine/_port/qcrt")

local OP = prvm_edict.OP

local PROGRAMS: { [string]: any } = {
	arith = {
		statements = {
			{ OP.DONE },
			{ OP.ADD_F, 30, 31, 32 },
			{ OP.DIV_F, 33, 34, 35 },
			{ OP.MUL_V, 40, 43, 46 },
			{ OP.MUL_FV, 31, 40, 47 },
			{ OP.SUB_V, 40, 43, 50 },
			{ OP.BITAND, 60, 61, 62 },
			{ OP.BITOR, 63, 64, 65 },
			{ OP.NE_V, 40, 43, 66 },
			{ OP.NOT_V, 70, 0, 67 },
			{ OP.DONE },
		},
		functions = { { name = "main", first = 1, parm_start = 28, locals = 0 } },
		numglobals = 80,
		globals = {
			[30] = 0.1,
			[31] = 0.2,
			[33] = 5,
			[40] = 1e-3,
			[41] = 3.3,
			[42] = -7.1,
			[43] = 9.9,
			[44] = 0.37,
			[45] = 123.456,
			[60] = -1.5,
			[61] = 3,
			[63] = 6.9,
			[64] = 1,
		},
	},
	control = {
		statements = {
			{ OP.DONE }, -- 0
			{ OP.LE, 70, 80, 71 }, -- fact @1
			{ OP.IFNOT, 71, 2 },
			{ OP.RETURN, 80 },
			{ OP.SUB_F, 70, 80, 4 },
			{ OP.CALL1, 81 },
			{ OP.MUL_F, 70, 1, 72 },
			{ OP.RETURN, 72 },
			{ OP.DONE }, -- 8
			{ OP.STORE_F, 82, 4 }, -- main @9
			{ OP.CALL1, 81 },
			{ OP.STORE_F, 1, 83 },
			{ OP.STORE_F, 82, 4 },
			{ OP.CALL1, 84 },
			{ OP.STORE_F, 1, 85 },
			{ OP.IF, 86, 2 }, -- -0.0: not taken
			{ OP.STORE_F, 80, 87 },
			{ OP.LT, 88, 82, 89 }, -- loop: g88 += 1 while g88 < 5
			{ OP.IFNOT, 89, 3 },
			{ OP.ADD_F, 88, 80, 88 },
			{ OP.GOTO, -3 },
			{ OP.DONE },
		},
		functions = {
			{ name = "fact", first = 1, parm_start = 70, locals = 3, parms = { 1 } },
			{ name = "main", first = 9, parm_start = 28, locals = 0 },
			{ name = "bi", first = -7, parm_start = 0, locals = 0 },
		},
		numglobals = 96,
		globals = { [80] = 1, [82] = 5, [70] = 42 },
		globalsInt = { [81] = 1, [84] = 3, [86] = -2147483648 },
		entry = 2,
	},
	fields = {
		statements = {
			{ OP.DONE },
			{ OP.ADDRESS, 100, 101, 102 },
			{ OP.STOREP_F, 103, 102 },
			{ OP.LOAD_F, 100, 101, 104 },
			{ OP.ADDRESS, 100, 105, 106 },
			{ OP.STOREP_V, 40, 106 },
			{ OP.LOAD_V, 100, 105, 107 },
			{ OP.LOAD_F, 108, 101, 110 }, -- out of bounds edict: same error in both
			{ OP.DONE },
		},
		functions = { { name = "main", first = 1, parm_start = 28, locals = 0 } },
		numglobals = 112,
		entityfields = 8,
		globals = { [103] = 7.5, [40] = 1, [41] = 2, [42] = 3 },
		globalsInt = { [100] = 2, [101] = 1, [105] = 4, [108] = 99 },
	},
	runaway = {
		statements = { { OP.DONE }, { OP.GOTO, 0 }, { OP.DONE } },
		functions = { { name = "main", first = 1, parm_start = 28, locals = 0 } },
		numglobals = 32,
	},
}

local function prep(data: buffer): any
	local p: any = prvm_edict.NewProg("synth")
	p.warning = function(_m: string) end
	prvm_edict.PRVM_Prog_Load(p, "synth.dat", data)
	prvm_edict.SetMaxEdicts(p, 8)
	p.runaway_limit = 1000
	p.numbuiltins = 16
	p.builtins[7] = function(prog: any)
		buffer.writef32(prog.globals, 4, buffer.readf32(prog.globals, 16) * 2 + prog.argc)
	end
	return p
end

return function(ctx: t.Ctx)
	fs.writeDir("work/test-tmp")
	for name, spec in PROGRAMS do
		local data = qcasm.build(spec)
		local dat = "work/test-tmp/" .. name .. ".dat"
		fs.writeFile(dat, buffer.tostring(data))
		local out = "game/generated/_test_" .. name
		local r = process.exec("python3", { "tools/qcaot/compile.py", dat, out })
		t.ok(ctx, r.ok, name .. ": compile.py failed: " .. r.stderr)
		if not r.ok then
			continue
		end
		local pI, pA = prep(data), prep(data)
		local gen = (require :: any)("../../game/generated/_test_" .. name)
		gen.install(pA)
		local entry = spec.entry or 1
		local okI, errI = pcall(prvm_exec.PRVM_ExecuteProgram, pI, entry, "synth")
		local okA, errA = pcall(qcrt.ExecuteProgram, pA, entry, "synth")
		t.eq(ctx, okA, okI, name .. ": same success")
		t.eq(ctx, tostring(errA), tostring(errI), name .. ": same error")
		t.ok(ctx, buffer.tostring(pA.globals) == buffer.tostring(pI.globals), name .. ": same globals")
		t.ok(ctx, buffer.tostring(pA.edictsfields) == buffer.tostring(pI.edictsfields), name .. ": same edict fields")
		fs.removeDir(out)
	end
end
