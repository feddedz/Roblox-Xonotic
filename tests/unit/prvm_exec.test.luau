--!strict
-- Reference interpreter (engine/prvm_exec.luau) against the C semantics of prvm_execprogram.h,
-- on hand-assembled programs (tests/_lib/qcasm.luau). Globals: 1-3 return, 4.. parms, 28+ free.
local t = require("../_lib/t")
local qcasm = require("../_lib/qcasm")
local prvm_edict = require("../../engine/prvm_edict")
local prvm_exec = require("../../engine/prvm_exec")
local f32 = require("../../engine/_port/f32")

local OP = prvm_edict.OP

local function load(spec: any): (prvm_edict.Prog, { [string]: number })
	local data, strs = qcasm.build(spec)
	local prog = prvm_edict.NewProg("test")
	prvm_edict.PRVM_Prog_Load(prog, "test.dat", data)
	return prog, strs
end
local function gf(p: prvm_edict.Prog, ofs: number): number
	return buffer.readf32(p.globals, ofs * 4)
end
local function gi(p: prvm_edict.Prog, ofs: number): number
	return buffer.readi32(p.globals, ofs * 4)
end
local function bits(x: number): number
	return f32.tobits(x)
end
local function main(stmts: { { number } }): { Func: any }
	return { { name = "main", first = 1, parm_start = 28, locals = 0 } } :: any
end

return function(ctx: t.Ctx)
	-- arithmetic rounding, division by zero, MUL_V product rounding
	do
		local p = load({
			statements = {
				{ OP.DONE },
				{ OP.ADD_F, 30, 31, 32 },
				{ OP.DIV_F, 33, 34, 35 },
				{ OP.DIV_F, 33, 36, 37 },
				{ OP.MUL_V, 40, 43, 46 },
				{ OP.MUL_FV, 31, 40, 47 },
				{ OP.DONE },
			},
			functions = main({}),
			numglobals = 64,
			globals = {
				[30] = 0.1,
				[31] = 0.2,
				[33] = 5,
				[34] = 0,
				[40] = 1e-3,
				[41] = 3.3,
				[42] = -7.1,
				[43] = 9.9,
				[44] = 0.37,
				[45] = 123.456,
			},
			globalsInt = { [36] = -2147483648 }, -- -0.0
		})
		prvm_exec.PRVM_ExecuteProgram(p, 1, "main")
		t.eq(ctx, bits(gf(p, 32)), bits(f32.round(f32.round(0.1) + f32.round(0.2))), "ADD_F rounds once like float")
		t.eq(ctx, gf(p, 35), 0, "DIV_F by 0 gives 0")
		t.eq(ctx, gf(p, 37), 0, "DIV_F by -0.0 gives 0")
		local a = { f32.round(1e-3), f32.round(3.3), f32.round(-7.1) }
		local b = { f32.round(9.9), f32.round(0.37), f32.round(123.456) }
		local want = f32.add(f32.add(f32.mul(a[1], b[1]), f32.mul(a[2], b[2])), f32.mul(a[3], b[3]))
		t.eq(ctx, bits(gf(p, 46)), bits(want), "MUL_V rounds each product and sum")
		t.eq(ctx, bits(gf(p, 49)), bits(f32.mul(f32.round(0.2), a[3])), "MUL_FV")
		t.eq(ctx, p.depth, 0, "stack unwound")
	end

	-- truthiness by bits, IF/IFNOT, bit ops on truncated floats
	do
		local p = load({
			statements = {
				{ OP.DONE },
				{ OP.IF, 50, 2 }, -- -0.0 is false: not taken
				{ OP.STORE_F, 52, 51 }, -- g51 = 1
				{ OP.IFNOT, 53, 2 }, -- NaN is true: not taken
				{ OP.STORE_F, 52, 54 }, -- g54 = 1
				{ OP.BITAND, 60, 61, 62 },
				{ OP.BITOR, 63, 64, 65 },
				{ OP.BITAND, 53, 66, 67 }, -- (int)NaN = INT_MIN
				{ OP.NOT_F, 50, 0, 68 },
				{ OP.AND, 52, 50, 69 },
				{ OP.DONE },
			},
			functions = main({}),
			numglobals = 80,
			globals = { [52] = 1, [60] = -1.5, [61] = 3, [63] = 6.9, [64] = 1, [66] = -1 },
			globalsInt = { [50] = -2147483648, [53] = 0x7FC00000 },
		})
		prvm_exec.PRVM_ExecuteProgram(p, 1, "main")
		t.eq(ctx, gf(p, 51), 1, "IF on -0.0 not taken")
		t.eq(ctx, gf(p, 54), 1, "IFNOT on NaN not taken")
		t.eq(ctx, gf(p, 62), 3, "BITAND truncates toward zero: (int)-1.5 & 3")
		t.eq(ctx, gf(p, 65), 7, "BITOR: (int)6.9 | 1")
		t.eq(ctx, gf(p, 67), -2147483648, "BITAND with NaN uses INT_MIN")
		t.eq(ctx, gf(p, 68), 1, "NOT_F of -0.0")
		t.eq(ctx, gf(p, 69), 0, "AND with -0.0")
	end

	-- strings
	do
		local data, strs = qcasm.build({
			statements = {
				{ OP.DONE },
				{ OP.NE_S, 30, 31, 32 },
				{ OP.EQ_S, 30, 33, 34 },
				{ OP.NOT_S, 35, 0, 36 },
				{ OP.NOT_S, 37, 0, 38 },
				{ OP.NOT_S, 30, 0, 39 },
				{ OP.DONE },
			},
			functions = main({}),
			numglobals = 48,
			strings = { "abc", "abd", "", "abc2" },
		})
		local p = prvm_edict.NewProg("test")
		prvm_edict.PRVM_Prog_Load(p, "t", data)
		buffer.writei32(p.globals, 30 * 4, strs["abc"])
		buffer.writei32(p.globals, 31 * 4, strs["abd"])
		buffer.writei32(p.globals, 33 * 4, strs["abc"])
		buffer.writei32(p.globals, 35 * 4, strs[""])
		buffer.writei32(p.globals, 37 * 4, 0)
		prvm_exec.PRVM_ExecuteProgram(p, 1, "main")
		t.eq(ctx, gf(p, 32), -1, "NE_S stores strcmp byte difference")
		t.eq(ctx, gf(p, 34), 1, "EQ_S compares contents")
		t.eq(ctx, gf(p, 36), 1, "NOT_S empty string")
		t.eq(ctx, gf(p, 38), 1, "NOT_S null string")
		t.eq(ctx, gf(p, 39), 0, "NOT_S non-empty")
		t.eq(ctx, prvm_edict.PRVM_GetString(p, strs["abc2"]), "abc2", "GetString")
	end

	-- recursion: locals live in globals and are saved/restored; builtins get argc and parms
	do
		local seen = {}
		local p = load({
			statements = {
				{ OP.DONE }, -- 0
				-- fact(n) @1: parm_start 70, locals 3
				{ OP.LE, 70, 80, 71 },
				{ OP.IFNOT, 71, 2 },
				{ OP.RETURN, 80 },
				{ OP.SUB_F, 70, 80, 4 },
				{ OP.CALL1, 81 },
				{ OP.MUL_F, 70, 1, 72 },
				{ OP.RETURN, 72 },
				{ OP.DONE }, -- 8
				-- main @9
				{ OP.STORE_F, 82, 4 },
				{ OP.CALL1, 81 },
				{ OP.STORE_F, 1, 83 },
				{ OP.STORE_F, 82, 4 },
				{ OP.CALL1, 84 }, -- builtin #7
				{ OP.STORE_F, 1, 85 },
				{ OP.DONE },
			},
			functions = {
				{ name = "fact", first = 1, parm_start = 70, locals = 3, parms = { 1 } },
				{ name = "main", first = 9, parm_start = 28, locals = 0 },
				{ name = "bi", first = -7, parm_start = 0, locals = 0 },
			},
			numglobals = 96,
			globals = { [80] = 1, [82] = 5, [70] = 42 },
			globalsInt = { [81] = 1, [84] = 3 },
		})
		p.numbuiltins = 16
		p.builtins[7] = function(prog: any)
			seen.argc = prog.argc
			buffer.writef32(prog.globals, 4, buffer.readf32(prog.globals, 16) * 2)
		end
		prvm_exec.PRVM_ExecuteProgram(p, 2, "main")
		t.eq(ctx, gf(p, 83), 120, "recursive factorial through CALL1/RETURN")
		t.eq(ctx, gf(p, 70), 42, "callee locals restored after return")
		t.eq(ctx, seen.argc, 1, "builtin sees argc")
		t.eq(ctx, gf(p, 85), 10, "builtin return value")
		t.eq(ctx, p.localstack_used, 0, "local stack balanced")
	end

	-- edict fields: ADDRESS/STOREP/LOAD and bounds errors
	do
		local spec = {
			statements = {
				{ OP.DONE },
				{ OP.ADDRESS, 100, 101, 102 },
				{ OP.STOREP_F, 103, 102 },
				{ OP.LOAD_F, 100, 101, 104 },
				{ OP.DONE },
			},
			functions = main({}),
			numglobals = 112,
			entityfields = 4,
			globals = { [103] = 7.5 },
			globalsInt = { [100] = 2, [101] = 1 },
		}
		local p = load(spec)
		prvm_edict.SetMaxEdicts(p, 8)
		prvm_exec.PRVM_ExecuteProgram(p, 1, "main")
		t.eq(ctx, gf(p, 104), 7.5, "STOREP + LOAD through ADDRESS")
		t.eq(ctx, buffer.readf32(p.edictsfields, (2 * 4 + 1) * 4), 7.5, "edict field layout edict*entityfields+field")
		local p2 = load(spec)
		prvm_edict.SetMaxEdicts(p2, 2)
		local ok, err = pcall(prvm_exec.PRVM_ExecuteProgram, p2, 1, "main")
		t.ok(
			ctx,
			not ok and string.find(tostring(err), "out of bounds edict number", 1, true) ~= nil,
			"ADDRESS edict bound"
		)
	end

	-- runaway loop counter: error exactly at 10,000,000 jumps
	do
		local p = load({
			statements = { { OP.DONE }, { OP.GOTO, 0 }, { OP.DONE } },
			functions = main({}),
			numglobals = 32,
		})
		local ok, err = pcall(prvm_exec.PRVM_ExecuteProgram, p, 1, "main")
		t.ok(
			ctx,
			not ok and string.find(tostring(err), "runaway loop counter hit limit of 10000000", 1, true) ~= nil,
			"runaway check"
		)
	end

	-- loader checks
	do
		local data = qcasm.build({ statements = { { OP.DONE } }, functions = main({}), numglobals = 30 })
		buffer.writei32(data, 0, 7)
		local ok, err = pcall(prvm_edict.PRVM_Prog_Load, prvm_edict.NewProg("x"), "x.dat", data)
		t.ok(
			ctx,
			not ok and string.find(tostring(err), "wrong version number (7 should be 6)", 1, true) ~= nil,
			"version check"
		)
	end
end
