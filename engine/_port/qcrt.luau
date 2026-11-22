--!strict
--!native
--[[
	Port support (not a DarkPlaces file): runtime for QuakeC compiled ahead of time by tools/qcaot/compile.py
	(task M2-AOT, docs/subsystems/qcvm.md). Every helper reproduces the corresponding path of the reference
	interpreter engine/prvm_exec.luau (= prvm_execprogram.h @xonotic-v0.8.6) exactly, including error text.
	Compiled functions live in prog.aot[fnum]; each runs after PRVM_EnterFunction and ends with
	qcrt.ret (OP_RETURN/OP_DONE semantics + PRVM_LeaveFunction).
	The per-ExecuteProgram jump counter (C local `jumpcount`) is prog.jc, saved/restored per invocation.
]]

local prvm_edict = require("../prvm_edict")
local prvm_exec = require("../prvm_exec")

local qcrt = {}

local readi32, writei32 = buffer.readi32, buffer.writei32
local EnterFunction, LeaveFunction = prvm_exec.PRVM_EnterFunction, prvm_exec.PRVM_LeaveFunction

qcrt.GetString = prvm_edict.PRVM_GetString
qcrt.strcmp = prvm_exec.strcmp
qcrt.istrue = prvm_exec.istrue
qcrt.ftoi = prvm_exec.ftoi

local function U(x: number): number
	return if x < 0 then x + 0x100000000 else x
end

function qcrt.tosigned(u: number): number
	return if u >= 0x80000000 then u - 0x100000000 else u
end

-- taken IF/IFNOT/GOTO: ++jumpcount == 10000000 && prvm_runawaycheck
function qcrt.jump(prog: any, st: number)
	local jc = prog.jc + 1
	prog.jc = jc
	if jc == prog.runaway_limit and prog.cvar_prvm_runawaycheck ~= 0 then
		prog.xstatement = st
		prog.error_cmd(
			string.format(
				"%s runaway loop counter hit limit of %d jumps\ntip: read above for list of most-executed functions",
				prog.name,
				jc
			)
		)
	end
end

function qcrt.divzero(prog: any, st: number)
	if prog.cvar_developer ~= 0 then
		prog.xstatement = st
		prog.warning(string.format("Attempted division by zero in %s\n", prog.name))
	end
end

-- OP_CALL0..8
function qcrt.call(prog: any, fn: number, argc: number, st: number)
	prog.xstatement = st
	prog.argc = argc
	if fn == 0 then
		prog.error_cmd(string.format("NULL function in %s", prog.name))
	end
	if fn == 0 or fn < 0 or fn >= prog.numfunctions then
		prog.error_cmd(string.format("%s CALL outside the program", prog.name))
		return
	end
	local enterfunc = prog.functions[fn + 1]
	enterfunc.callcount += 1
	if enterfunc.first_statement < 0 then
		local builtinnumber = -enterfunc.first_statement
		local bi = if builtinnumber < prog.numbuiltins then prog.builtins[builtinnumber] else nil
		if bi then
			bi(prog)
		else
			prog.error_cmd(
				string.format(
					"No such builtin #%d in %s; most likely cause: outdated engine build. Try updating!",
					builtinnumber,
					prog.name
				)
			)
		end
	else
		EnterFunction(prog, fn)
		qcrt.aotfn(prog, fn)(prog)
	end
end

-- OP_DONE / OP_RETURN
function qcrt.ret(prog: any, A: number, st: number)
	local G = prog.globals
	prog.xstatement = st
	writei32(G, 4, readi32(G, A))
	writei32(G, 8, readi32(G, A + 4))
	writei32(G, 12, readi32(G, A + 8))
	LeaveFunction(prog)
end

-- OP_LOAD_F / _FLD / _ENT / _S / _FNC
function qcrt.load1(prog: any, A: number, B: number, C: number, st: number)
	local G = prog.globals
	local ed, fld = readi32(G, A), readi32(G, B)
	if U(ed) >= prog.max_edicts then
		prog.xstatement = st
		prog.error_cmd(string.format("%s Progs attempted to read an out of bounds edict number", prog.name))
		return
	end
	if U(fld) >= prog.entityfields then
		prog.xstatement = st
		prog.error_cmd(string.format("%s attempted to read an invalid field in an edict (%d)", prog.name, fld))
		return
	end
	writei32(G, C, readi32(prog.edictsfields, (ed * prog.entityfields + fld) * 4))
end

-- OP_LOAD_V
function qcrt.loadv(prog: any, A: number, B: number, C: number, st: number)
	local G = prog.globals
	local ed, fld = readi32(G, A), readi32(G, B)
	if U(ed) >= prog.max_edicts then
		prog.xstatement = st
		prog.error_cmd(string.format("%s Progs attempted to read an out of bounds edict number", prog.name))
		return
	end
	if U(fld) > prog.entityfields - 3 then
		prog.xstatement = st
		prog.error_cmd(string.format("%s attempted to read an invalid field in an edict (%d)", prog.name, fld))
		return
	end
	local E = prog.edictsfields
	local p = (ed * prog.entityfields + fld) * 4
	writei32(G, C, readi32(E, p))
	writei32(G, C + 4, readi32(E, p + 4))
	writei32(G, C + 8, readi32(E, p + 8))
end

-- OP_ADDRESS
function qcrt.address(prog: any, A: number, B: number, C: number, st: number)
	local G = prog.globals
	local ed, fld = readi32(G, A), readi32(G, B)
	if U(ed) >= prog.max_edicts then
		prog.xstatement = st
		prog.error_cmd(string.format("%s Progs attempted to address an out of bounds edict number", prog.name))
		return
	end
	if U(fld) >= prog.entityfields then
		prog.xstatement = st
		prog.error_cmd(string.format("%s attempted to address an invalid field (%d) in an edict", prog.name, fld))
		return
	end
	writei32(G, C, ed * prog.entityfields + fld)
end

-- OP_STOREP_F / _ENT / _FLD / _S / _FNC
function qcrt.storep1(prog: any, A: number, B: number, st: number)
	local G = prog.globals
	local p = readi32(G, B)
	local ef, area = prog.entityfields, prog.entityfieldsarea
	if U(p) - ef >= area - ef or U(p) < ef then
		if U(p) >= area then
			prog.xstatement = st
			prog.error_cmd(string.format("%s attempted to write to an out of bounds edict (%d)", prog.name, p))
			return
		end
		if U(p) < ef and not prog.allowworldwrites then
			prog.xstatement = st
			prog.warning(string.format("assignment to world field %d in %s\n", p, prog.name))
		end
	end
	writei32(prog.edictsfields, p * 4, readi32(G, A))
end

-- OP_STOREP_V
function qcrt.storepv(prog: any, A: number, B: number, st: number)
	local G = prog.globals
	local p = readi32(G, B)
	local ef, area = prog.entityfields, prog.entityfieldsarea
	if U(p) - ef > area - ef - 3 or U(p) < ef then
		if U(p) > area - 3 then
			prog.xstatement = st
			prog.error_cmd(string.format("%s attempted to write to an out of bounds edict (%d)", prog.name, p))
			return
		end
		if U(p) < ef and not prog.allowworldwrites then
			prog.xstatement = st
			prog.warning(string.format("assignment to world field %d in %s\n", p, prog.name))
		end
	end
	local E = prog.edictsfields
	writei32(E, p * 4, readi32(G, A))
	writei32(E, p * 4 + 4, readi32(G, A + 4))
	writei32(E, p * 4 + 8, readi32(G, A + 8))
end

-- compiled function fnum; its chunk is required on first use (prog.aot_load, game/generated/<prog>/init.luau)
function qcrt.aotfn(prog: any, fnum: number): (any) -> ()
	local fn = prog.aot[fnum]
	if fn == nil and prog.aot_load then
		fn = prog.aot_load(fnum)
	end
	return fn
end

-- Equivalent of PRVM_ExecuteProgram for compiled programs (prvm_exec.c SVVM_ExecuteProgram L952-1054).
function qcrt.ExecuteProgram(prog: any, fnum: number, errormessage: string)
	if fnum == 0 or fnum >= prog.numfunctions or fnum < 0 then
		prog.error_cmd("SVVM_ExecuteProgram: " .. errormessage)
	end
	local func = prog.functions[fnum + 1]
	local restorevm_tempstringsbuf_cursize = prog.tempstringsbuf.cursize
	local savedjc = prog.jc or 0
	prog.jc = 0
	EnterFunction(prog, fnum)
	func.callcount += 1
	qcrt.aotfn(prog, fnum)(prog)
	prog.jc = savedjc
	prog.tempstringsbuf.cursize = restorevm_tempstringsbuf_cursize
end

return qcrt
