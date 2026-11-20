--!strict
--!native
--[[
Copyright (C) 1996-1997 Id Software, Inc.

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.
]]
--[[
	Port of prvm_exec.c (PARTIAL: EnterFunction, LeaveFunction, ExecuteProgram) and prvm_execprogram.h
	@xonotic-v0.8.6. This is the REFERENCE interpreter (task M2-INTERP): the AOT compiler's output is
	differential-tested against it. Profiling, coverage, tracing, watchpoints and breakpoints
	(PRVMSLOWINTERPRETER / PRVMTIMEPROFILING / prvm_coverage) do not change program results and are
	NOT YET PORTED (task M2-INTERP-DEBUG).
	Float semantics (D-004): operands are read from f32 buffer slots; each C float operation is one
	double operation followed by the f32 rounding of the buffer write (or an explicit f32 round when the
	C code keeps an intermediate float, e.g. OP_MUL_V's partial products).
]]

local prvm_edict = require("./prvm_edict")
local f32 = require("./_port/f32")

local prvm_exec = {}

type Prog = prvm_edict.Prog

local readi32, writei32 = buffer.readi32, buffer.writei32
local readf32, writef32 = buffer.readf32, buffer.writef32
local band, bor = bit32.band, bit32.bor
local fround = f32.round
local OP = prvm_edict.OP
local PRVM_GetString = prvm_edict.PRVM_GetString

local OFS_RETURN = 1
local OFS_PARM0 = 4
local PRVM_OP_STATE = 1

-- FLOAT_IS_TRUE_FOR_INT (quakedef.h L580): -0.0 (0x80000000) and 0 are false
local function istrue(i: number): boolean
	return band(i, 0x7FFFFFFF) ~= 0
end
prvm_exec.istrue = istrue

-- C (int)float on x86-64 (cvttss2si): truncate toward zero; NaN/out of range -> INT_MIN
local function ftoi(x: number): number
	if x ~= x or x >= 2147483648 or x < -2147483648 then
		return -2147483648
	end
	if x >= 0 then
		return math.floor(x)
	end
	return math.ceil(x)
end
prvm_exec.ftoi = ftoi

local function tosigned(u: number): number
	if u >= 0x80000000 then
		return u - 0x100000000
	end
	return u
end

-- strcmp as glibc x86-64 returns it: difference of the first differing bytes as unsigned chars
-- (OP_NE_S stores this int into a float). To be confirmed against REF-DP.
local function strcmp(a: string, b: string): number
	local n = math.min(#a, #b)
	for i = 1, n do
		local x, y = string.byte(a, i), string.byte(b, i)
		if x ~= y then
			return x - y
		end
	end
	if #a == #b then
		return 0
	end
	return if #a > #b then string.byte(a, n + 1) else -string.byte(b, n + 1)
end
prvm_exec.strcmp = strcmp

local function F(prog: Prog, fnum: number)
	return prog.functions[fnum + 1]
end

-- port: prvm_exec.c PRVM_EnterFunction L581-620 @xonotic-v0.8.6
-- Returns first_statement - 1 ("offset the s++").
function prvm_exec.PRVM_EnterFunction(prog: Prog, fnum: number): number
	local f = F(prog, fnum)
	if not f then
		prog.error_cmd(string.format("PRVM_EnterFunction: NULL function in %s", prog.name))
	end
	prog.stack_s[prog.depth + 1] = prog.xstatement
	prog.stack_f[prog.depth + 1] = prog.xfunction
	prog.depth += 1
	if prog.depth >= prvm_edict.PRVM_MAX_STACK_DEPTH then
		prog.error_cmd("stack overflow")
	end
	-- save off any locals that the new function steps on
	local c = f.locals
	if prog.localstack_used + c > prvm_edict.PRVM_LOCALSTACK_SIZE then
		prog.error_cmd(string.format("PRVM_ExecuteProgram: locals stack overflow in %s", prog.name))
	end
	local G, LS = prog.globals, prog.localstack
	for i = 0, c - 1 do
		writei32(LS, (prog.localstack_used + i) * 4, readi32(G, (f.parm_start + i) * 4))
	end
	prog.localstack_used += c
	-- copy parameters
	local o = f.parm_start
	for i = 0, f.numparms - 1 do
		for j = 0, f.parm_size[i + 1] - 1 do
			writei32(G, o * 4, readi32(G, (OFS_PARM0 + i * 3 + j) * 4))
			o += 1
		end
	end
	f.recursion += 1
	prog.xfunction = fnum
	return f.first_statement - 1
end

-- port: prvm_exec.c PRVM_LeaveFunction L627-672 @xonotic-v0.8.6 (profiling accumulation omitted)
-- Returns the statement index to continue from (stack[depth].s).
function prvm_exec.PRVM_LeaveFunction(prog: Prog): number
	if prog.depth <= 0 then
		prog.error_cmd(string.format("prog stack underflow in %s", prog.name))
	end
	if prog.xfunction < 0 then
		prog.error_cmd(string.format("PR_LeaveFunction: NULL function in %s", prog.name))
	end
	-- restore locals from the stack
	local f = F(prog, prog.xfunction)
	local c = f.locals
	prog.localstack_used -= c
	if prog.localstack_used < 0 then
		prog.error_cmd(string.format("PRVM_ExecuteProgram: locals stack underflow in %s", prog.name))
	end
	local G, LS = prog.globals, prog.localstack
	for i = 0, c - 1 do
		writei32(G, (f.parm_start + i) * 4, readi32(LS, (prog.localstack_used + i) * 4))
	end
	-- up stack
	prog.depth -= 1
	f.recursion -= 1
	prog.xfunction = prog.stack_f[prog.depth + 1]
	return prog.stack_s[prog.depth + 1]
end

-- port: prvm_exec.c SVVM_ExecuteProgram L952-1054 + prvm_execprogram.h L161-562 @xonotic-v0.8.6
-- (MVM_/CLVM_ExecuteProgram differ only in the final SV_FlushBroadcastMessages, done by the host.)
function prvm_exec.PRVM_ExecuteProgram(prog: Prog, fnum: number, errormessage: string)
	if fnum == 0 or fnum >= prog.numfunctions or fnum < 0 then
		prog.error_cmd("SVVM_ExecuteProgram: " .. errormessage)
	end
	local func = F(prog, fnum)
	-- after executing this function, delete all tempstrings it created
	local restorevm_tempstringsbuf_cursize = prog.tempstringsbuf.cursize
	-- we know we're done when pr_depth drops to this
	local exitdepth = prog.depth
	-- make a stack frame
	local st = prvm_exec.PRVM_EnterFunction(prog, fnum)
	local jumpcount = 0
	func.callcount += 1

	local G = prog.globals
	local S = prog.statements
	local cached_edictsfields = prog.edictsfields
	local cached_entityfields = prog.entityfields
	local cached_entityfields_3 = prog.entityfields - 3
	local cached_entityfieldsarea = prog.entityfieldsarea
	local cached_entityfieldsarea_entityfields = prog.entityfieldsarea - prog.entityfields
	local cached_entityfieldsarea_3 = prog.entityfieldsarea - 3
	local cached_entityfieldsarea_entityfields_3 = prog.entityfieldsarea - prog.entityfields - 3
	local cached_max_edicts = prog.max_edicts
	local cached_allowworldwrites = prog.allowworldwrites
	local cached_flag = prog.flag

	-- (prvm_uint_t)x for an int x
	local function U(x: number): number
		return if x < 0 then x + 0x100000000 else x
	end
	local function runaway()
		prog.xstatement = st
		prog.error_cmd(
			string.format(
				"%s runaway loop counter hit limit of %d jumps\ntip: read above for list of most-executed functions",
				prog.name,
				jumpcount
			)
		)
	end

	while true do
		st += 1
		local w = st * 20
		local op = readi32(S, w)
		local A = readi32(S, w + 4) * 4
		local B = readi32(S, w + 8) * 4
		local C = readi32(S, w + 12) * 4

		if op == OP.ADD_F then
			writef32(G, C, readf32(G, A) + readf32(G, B))
		elseif op == OP.ADD_V then
			writef32(G, C, readf32(G, A) + readf32(G, B))
			writef32(G, C + 4, readf32(G, A + 4) + readf32(G, B + 4))
			writef32(G, C + 8, readf32(G, A + 8) + readf32(G, B + 8))
		elseif op == OP.SUB_F then
			writef32(G, C, readf32(G, A) - readf32(G, B))
		elseif op == OP.SUB_V then
			writef32(G, C, readf32(G, A) - readf32(G, B))
			writef32(G, C + 4, readf32(G, A + 4) - readf32(G, B + 4))
			writef32(G, C + 8, readf32(G, A + 8) - readf32(G, B + 8))
		elseif op == OP.MUL_F then
			writef32(G, C, readf32(G, A) * readf32(G, B))
		elseif op == OP.MUL_V then
			-- a0*b0 + a1*b1 + a2*b2 in float: each product and each sum rounded, left to right
			local p0 = fround(readf32(G, A) * readf32(G, B))
			local p1 = fround(readf32(G, A + 4) * readf32(G, B + 4))
			local p2 = fround(readf32(G, A + 8) * readf32(G, B + 8))
			writef32(G, C, fround(p0 + p1) + p2)
		elseif op == OP.MUL_FV then
			local tempfloat = readf32(G, A)
			writef32(G, C, tempfloat * readf32(G, B))
			writef32(G, C + 4, tempfloat * readf32(G, B + 4))
			writef32(G, C + 8, tempfloat * readf32(G, B + 8))
		elseif op == OP.MUL_VF then
			local tempfloat = readf32(G, B)
			writef32(G, C, tempfloat * readf32(G, A))
			writef32(G, C + 4, tempfloat * readf32(G, A + 4))
			writef32(G, C + 8, tempfloat * readf32(G, A + 8))
		elseif op == OP.DIV_F then
			local b = readf32(G, B)
			if b ~= 0 then
				writef32(G, C, readf32(G, A) / b)
			else
				if prog.cvar_developer ~= 0 then
					prog.xstatement = st
					prog.warning(string.format("Attempted division by zero in %s\n", prog.name))
				end
				writef32(G, C, 0)
			end
		elseif op == OP.BITAND then
			writef32(G, C, tosigned(band(ftoi(readf32(G, A)), ftoi(readf32(G, B)))))
		elseif op == OP.BITOR then
			writef32(G, C, tosigned(bor(ftoi(readf32(G, A)), ftoi(readf32(G, B)))))
		elseif op == OP.GE then
			writef32(G, C, if readf32(G, A) >= readf32(G, B) then 1 else 0)
		elseif op == OP.LE then
			writef32(G, C, if readf32(G, A) <= readf32(G, B) then 1 else 0)
		elseif op == OP.GT then
			writef32(G, C, if readf32(G, A) > readf32(G, B) then 1 else 0)
		elseif op == OP.LT then
			writef32(G, C, if readf32(G, A) < readf32(G, B) then 1 else 0)
		elseif op == OP.AND then
			writef32(G, C, if istrue(readi32(G, A)) and istrue(readi32(G, B)) then 1 else 0)
		elseif op == OP.OR then
			writef32(G, C, if istrue(readi32(G, A)) or istrue(readi32(G, B)) then 1 else 0)
		elseif op == OP.NOT_F then
			writef32(G, C, if istrue(readi32(G, A)) then 0 else 1)
		elseif op == OP.NOT_V then
			writef32(G, C, if readf32(G, A) == 0 and readf32(G, A + 4) == 0 and readf32(G, A + 8) == 0 then 1 else 0)
		elseif op == OP.NOT_S then
			local s = readi32(G, A)
			writef32(G, C, if s == 0 or PRVM_GetString(prog, s) == "" then 1 else 0)
		elseif op == OP.NOT_FNC then
			writef32(G, C, if readi32(G, A) == 0 then 1 else 0)
		elseif op == OP.NOT_ENT then
			writef32(G, C, if readi32(G, A) == 0 then 1 else 0)
		elseif op == OP.EQ_F then
			writef32(G, C, if readf32(G, A) == readf32(G, B) then 1 else 0)
		elseif op == OP.EQ_V then
			writef32(
				G,
				C,
				if readf32(G, A) == readf32(G, B)
						and readf32(G, A + 4) == readf32(G, B + 4)
						and readf32(G, A + 8) == readf32(G, B + 8)
					then 1
					else 0
			)
		elseif op == OP.EQ_S then
			local r = strcmp(PRVM_GetString(prog, readi32(G, A)), PRVM_GetString(prog, readi32(G, B)))
			writef32(G, C, if r == 0 then 1 else 0)
		elseif op == OP.EQ_E or op == OP.EQ_FNC then
			writef32(G, C, if readi32(G, A) == readi32(G, B) then 1 else 0)
		elseif op == OP.NE_F then
			writef32(G, C, if readf32(G, A) ~= readf32(G, B) then 1 else 0)
		elseif op == OP.NE_V then
			writef32(
				G,
				C,
				if readf32(G, A) ~= readf32(G, B)
						or readf32(G, A + 4) ~= readf32(G, B + 4)
						or readf32(G, A + 8) ~= readf32(G, B + 8)
					then 1
					else 0
			)
		elseif op == OP.NE_S then
			writef32(G, C, strcmp(PRVM_GetString(prog, readi32(G, A)), PRVM_GetString(prog, readi32(G, B))))
		elseif op == OP.NE_E or op == OP.NE_FNC then
			writef32(G, C, if readi32(G, A) ~= readi32(G, B) then 1 else 0)
		elseif
			op == OP.STORE_F
			or op == OP.STORE_ENT
			or op == OP.STORE_FLD
			or op == OP.STORE_S
			or op == OP.STORE_FNC
		then
			writei32(G, B, readi32(G, A))
		elseif op == OP.STORE_V then
			writei32(G, B, readi32(G, A))
			writei32(G, B + 4, readi32(G, A + 4))
			writei32(G, B + 8, readi32(G, A + 8))
		elseif
			op == OP.STOREP_F
			or op == OP.STOREP_ENT
			or op == OP.STOREP_FLD
			or op == OP.STOREP_S
			or op == OP.STOREP_FNC
		then
			local p = readi32(G, B)
			if U(p) - cached_entityfields >= cached_entityfieldsarea_entityfields or U(p) < cached_entityfields then
				if U(p) >= cached_entityfieldsarea then
					prog.xstatement = st
					prog.error_cmd(string.format("%s attempted to write to an out of bounds edict (%d)", prog.name, p))
					return
				end
				if U(p) < cached_entityfields and not cached_allowworldwrites then
					prog.xstatement = st
					prog.warning(string.format("assignment to world field %d in %s\n", p, prog.name))
				end
			end
			writei32(cached_edictsfields, p * 4, readi32(G, A))
		elseif op == OP.STOREP_V then
			local p = readi32(G, B)
			if U(p) - cached_entityfields > cached_entityfieldsarea_entityfields_3 or U(p) < cached_entityfields then
				if U(p) > cached_entityfieldsarea_3 then
					prog.xstatement = st
					prog.error_cmd(string.format("%s attempted to write to an out of bounds edict (%d)", prog.name, p))
					return
				end
				if U(p) < cached_entityfields and not cached_allowworldwrites then
					prog.xstatement = st
					prog.warning(string.format("assignment to world field %d in %s\n", p, prog.name))
				end
			end
			writei32(cached_edictsfields, p * 4, readi32(G, A))
			writei32(cached_edictsfields, p * 4 + 4, readi32(G, A + 4))
			writei32(cached_edictsfields, p * 4 + 8, readi32(G, A + 8))
		elseif op == OP.ADDRESS then
			local ed, fld = readi32(G, A), readi32(G, B)
			if U(ed) >= cached_max_edicts then
				prog.xstatement = st
				prog.error_cmd(string.format("%s Progs attempted to address an out of bounds edict number", prog.name))
				return
			end
			if U(fld) >= cached_entityfields then
				prog.xstatement = st
				prog.error_cmd(
					string.format("%s attempted to address an invalid field (%d) in an edict", prog.name, fld)
				)
				return
			end
			writei32(G, C, ed * cached_entityfields + fld)
		elseif op == OP.LOAD_F or op == OP.LOAD_FLD or op == OP.LOAD_ENT or op == OP.LOAD_S or op == OP.LOAD_FNC then
			local ed, fld = readi32(G, A), readi32(G, B)
			if U(ed) >= cached_max_edicts then
				prog.xstatement = st
				prog.error_cmd(string.format("%s Progs attempted to read an out of bounds edict number", prog.name))
				return
			end
			if U(fld) >= cached_entityfields then
				prog.xstatement = st
				prog.error_cmd(string.format("%s attempted to read an invalid field in an edict (%d)", prog.name, fld))
				return
			end
			writei32(G, C, readi32(cached_edictsfields, (ed * cached_entityfields + fld) * 4))
		elseif op == OP.LOAD_V then
			local ed, fld = readi32(G, A), readi32(G, B)
			if U(ed) >= cached_max_edicts then
				prog.xstatement = st
				prog.error_cmd(string.format("%s Progs attempted to read an out of bounds edict number", prog.name))
				return
			end
			if U(fld) > cached_entityfields_3 then
				prog.xstatement = st
				prog.error_cmd(string.format("%s attempted to read an invalid field in an edict (%d)", prog.name, fld))
				return
			end
			local p = (ed * cached_entityfields + fld) * 4
			writei32(G, C, readi32(cached_edictsfields, p))
			writei32(G, C + 4, readi32(cached_edictsfields, p + 4))
			writei32(G, C + 8, readi32(cached_edictsfields, p + 8))
		elseif op == OP.IFNOT then
			if not istrue(readi32(G, A)) then
				st = readi32(S, w + 16) - 1 -- offset the st++
				jumpcount += 1
				if jumpcount == 10000000 and prog.cvar_prvm_runawaycheck ~= 0 then
					runaway()
				end
			end
		elseif op == OP.IF then
			if istrue(readi32(G, A)) then
				st = readi32(S, w + 16) - 1
				jumpcount += 1
				if jumpcount == 10000000 and prog.cvar_prvm_runawaycheck ~= 0 then
					runaway()
				end
			end
		elseif op == OP.GOTO then
			st = readi32(S, w + 16) - 1
			jumpcount += 1
			if jumpcount == 10000000 and prog.cvar_prvm_runawaycheck ~= 0 then
				runaway()
			end
		elseif op >= OP.CALL0 and op <= OP.CALL8 then
			prog.xstatement = st
			prog.argc = op - OP.CALL0
			local fn = readi32(G, A)
			if fn == 0 then
				prog.error_cmd(string.format("NULL function in %s", prog.name))
			end
			if fn == 0 or fn < 0 or fn >= prog.numfunctions then
				prog.error_cmd(string.format("%s CALL outside the program", prog.name))
				return
			end
			local enterfunc = F(prog, fn)
			enterfunc.callcount += 1
			if enterfunc.first_statement < 0 then
				-- negative first_statement values are built in functions
				local builtinnumber = -enterfunc.first_statement
				local bi = if builtinnumber < prog.numbuiltins then prog.builtins[builtinnumber] else nil
				if bi then
					bi(prog)
					-- builtins may cause ED_Alloc() to be called, update cached variables
					cached_edictsfields = prog.edictsfields
					cached_entityfields = prog.entityfields
					cached_entityfields_3 = prog.entityfields - 3
					cached_entityfieldsarea = prog.entityfieldsarea
					cached_entityfieldsarea_entityfields = prog.entityfieldsarea - prog.entityfields
					cached_entityfieldsarea_3 = prog.entityfieldsarea - 3
					cached_entityfieldsarea_entityfields_3 = prog.entityfieldsarea - prog.entityfields - 3
					cached_max_edicts = prog.max_edicts
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
				st = prvm_exec.PRVM_EnterFunction(prog, fn)
			end
		elseif op == OP.DONE or op == OP.RETURN then
			prog.xstatement = st
			writei32(G, OFS_RETURN * 4, readi32(G, A))
			writei32(G, (OFS_RETURN + 1) * 4, readi32(G, A + 4))
			writei32(G, (OFS_RETURN + 2) * 4, readi32(G, A + 8))
			st = prvm_exec.PRVM_LeaveFunction(prog)
			if prog.depth <= exitdepth then
				break -- all done
			end
		elseif op == OP.STATE then
			if band(cached_flag, PRVM_OP_STATE) ~= 0 then
				prog.error_cmd("NOT YET PORTED: OP_STATE (unused by Xonotic 0.8.6 progs)")
			else
				prog.xstatement = st
				prog.error_cmd(string.format("OP_STATE not supported by %s", prog.name))
			end
		else
			-- C: the computed-goto/switch has no default; an op outside the table is undefined behaviour.
			prog.error_cmd(string.format("unknown opcode %d at statement %d in %s", op, st, prog.name))
		end
	end
	-- cleanup: delete tempstrings created by this function
	prog.tempstringsbuf.cursize = restorevm_tempstringsbuf_cursize
end

return prvm_exec
