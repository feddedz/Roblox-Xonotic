--!strict
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
	Port of prvm_edict.c @xonotic-v0.8.6 (PARTIAL: program loading + string lookup).
	Storage layout (PRVM_64 off, D-004, docs/subsystems/qcvm.md): globals and edict fields are 4-byte
	slots in buffers (globals: ofs*4; edictsfields: (edict*entityfields + field)*4), statements are
	5 x i32 per statement (op, operand0, operand1, operand2, jumpabsolute) at index*20.
	NOT YET PORTED: the rest of PRVM_Prog_Load after the statement loop (required functions check,
	field/global offset lookup, PRVM_Init_Exec, ...), edict allocation, string allocation functions.
]]

local prvm_edict = {}

export type Function = {
	first_statement: number,
	parm_start: number,
	locals: number,
	s_name: number,
	s_file: number,
	numparms: number,
	parm_size: { number }, -- [1..8]
	recursion: number,
	callcount: number,
}

export type Prog = {
	name: string,
	-- loaded program
	progs_version: number,
	progs_crc: number,
	progs_numstatements: number,
	progs_numglobals: number,
	progs_numfunctions: number,
	progs_entityfields: number,
	numstatements: number,
	numglobals: number,
	numfunctions: number,
	entityfields: number,
	statements: buffer,
	functions: { Function }, -- index fnum + 1
	globaldefs: { { type: number, ofs: number, s_name: number } },
	fielddefs: { { type: number, ofs: number, s_name: number } },
	globals: buffer,
	strings: string,
	stringssize: number,
	-- edicts
	max_edicts: number,
	entityfieldsarea: number,
	edictsfields: buffer,
	-- strings created at runtime
	tempstringsbuf: { data: buffer, cursize: number, maxsize: number },
	-- engine strings: a C `const char *` is represented by a unique reference { str = "..." } (pointer identity)
	knownstrings: { [number]: { str: string } | false }, -- index num + 1
	numknownstrings: number,
	maxknownstrings: number,
	firstfreeknownstring: number,
	-- execution state (prvm_exec.c)
	depth: number,
	stack_s: { number }, -- prvm_stack_t.s, index depth + 1
	stack_f: { number }, -- prvm_stack_t.f (function index or -1 for NULL), index depth + 1
	localstack: buffer,
	localstack_used: number,
	xfunction: number, -- function index, -1 = NULL
	xstatement: number,
	argc: number,
	trace: number,
	flag: number,
	allowworldwrites: boolean,
	builtins: { [number]: (prog: any) -> () },
	numbuiltins: number,
	-- engine hooks (host decides what they do)
	error_cmd: (msg: string) -> (),
	warning: (msg: string) -> (),
	cvar_developer: number,
	cvar_prvm_runawaycheck: number,
	-- AOT (engine/_port/qcrt.luau): compiled functions by fnum, and the per-ExecuteProgram jump counter
	aot: { [number]: (prog: any) -> () },
	jc: number,
	-- 10000000 in C (prvm_execprogram.h `++jumpcount == 10000000`); only tests lower it
	runaway_limit: number,
}

export type RequiredDef = { type: number, name: string }

local ev_vector = 3
local DEF_SAVEGLOBAL = 0x8000
local PROG_VERSION = 6
local PRVM_MAX_STACK_DEPTH = 1024 -- progsvm.h L268 (non-DP_SMALLMEMORY)
local PRVM_LOCALSTACK_SIZE = 16384 -- progsvm.h L269
prvm_edict.PRVM_MAX_STACK_DEPTH = PRVM_MAX_STACK_DEPTH
prvm_edict.PRVM_LOCALSTACK_SIZE = PRVM_LOCALSTACK_SIZE
local PRVM_KNOWNSTRINGBASE = 0x40000000 -- prvm_edict.c L2958

-- opcode numbers (pr_comp.h opcode_e)
local OP = {}
for i, n in
	{
		"DONE",
		"MUL_F",
		"MUL_V",
		"MUL_FV",
		"MUL_VF",
		"DIV_F",
		"ADD_F",
		"ADD_V",
		"SUB_F",
		"SUB_V",
		"EQ_F",
		"EQ_V",
		"EQ_S",
		"EQ_E",
		"EQ_FNC",
		"NE_F",
		"NE_V",
		"NE_S",
		"NE_E",
		"NE_FNC",
		"LE",
		"GE",
		"LT",
		"GT",
		"LOAD_F",
		"LOAD_V",
		"LOAD_S",
		"LOAD_ENT",
		"LOAD_FLD",
		"LOAD_FNC",
		"ADDRESS",
		"STORE_F",
		"STORE_V",
		"STORE_S",
		"STORE_ENT",
		"STORE_FLD",
		"STORE_FNC",
		"STOREP_F",
		"STOREP_V",
		"STOREP_S",
		"STOREP_ENT",
		"STOREP_FLD",
		"STOREP_FNC",
		"RETURN",
		"NOT_F",
		"NOT_V",
		"NOT_S",
		"NOT_ENT",
		"NOT_FNC",
		"IF",
		"IFNOT",
		"CALL0",
		"CALL1",
		"CALL2",
		"CALL3",
		"CALL4",
		"CALL5",
		"CALL6",
		"CALL7",
		"CALL8",
		"STATE",
		"GOTO",
		"AND",
		"OR",
		"BITAND",
		"BITOR",
	}
do
	OP[n] = i - 1
end
prvm_edict.OP = OP

-- operand groups of PRVM_Prog_Load's statement switch (prvm_edict.c L2125-2253)
local GROUP_GGG, GROUP_GNG, GROUP_GG, GROUP_G = {}, {}, {}, {}
for _, n in
	{
		"ADD_F",
		"ADD_V",
		"SUB_F",
		"SUB_V",
		"MUL_F",
		"MUL_V",
		"MUL_FV",
		"MUL_VF",
		"DIV_F",
		"BITAND",
		"BITOR",
		"GE",
		"LE",
		"GT",
		"LT",
		"AND",
		"OR",
		"EQ_F",
		"EQ_V",
		"EQ_S",
		"EQ_E",
		"EQ_FNC",
		"NE_F",
		"NE_V",
		"NE_S",
		"NE_E",
		"NE_FNC",
		"ADDRESS",
		"LOAD_F",
		"LOAD_FLD",
		"LOAD_ENT",
		"LOAD_S",
		"LOAD_FNC",
		"LOAD_V",
	}
do
	GROUP_GGG[OP[n]] = true
end
for _, n in { "NOT_F", "NOT_V", "NOT_S", "NOT_FNC", "NOT_ENT" } do
	GROUP_GNG[OP[n]] = true
end
for _, n in
	{
		"STOREP_F",
		"STOREP_ENT",
		"STOREP_FLD",
		"STOREP_S",
		"STOREP_FNC",
		"STORE_F",
		"STORE_ENT",
		"STORE_FLD",
		"STORE_S",
		"STORE_FNC",
		"STATE",
		"STOREP_V",
		"STORE_V",
	}
do
	GROUP_GG[OP[n]] = true
end
for _, n in { "CALL0", "CALL1", "CALL2", "CALL3", "CALL4", "CALL5", "CALL6", "CALL7", "CALL8", "DONE", "RETURN" } do
	GROUP_G[OP[n]] = true
end

local function defaultError(msg: string)
	error(msg, 0)
end

local function defaultWarning(msg: string)
	print("VM_Warning: " .. msg)
end

-- A zeroed prvm_prog_t (the fields the VM port uses so far).
function prvm_edict.NewProg(name: string): Prog
	return {
		name = name,
		progs_version = 0,
		progs_crc = 0,
		progs_numstatements = 0,
		progs_numglobals = 0,
		progs_numfunctions = 0,
		progs_entityfields = 0,
		numstatements = 0,
		numglobals = 0,
		numfunctions = 0,
		entityfields = 0,
		statements = buffer.create(0),
		functions = {},
		globaldefs = {},
		fielddefs = {},
		globals = buffer.create(0),
		strings = "",
		stringssize = 0,
		max_edicts = 0,
		entityfieldsarea = 0,
		edictsfields = buffer.create(0),
		tempstringsbuf = { data = buffer.create(65536), cursize = 0, maxsize = 65536 },
		knownstrings = {},
		numknownstrings = 0,
		maxknownstrings = 0,
		firstfreeknownstring = 0,
		depth = 0,
		stack_s = {},
		stack_f = {},
		localstack = buffer.create(PRVM_LOCALSTACK_SIZE * 4),
		localstack_used = 0,
		xfunction = -1,
		xstatement = 0,
		argc = 0,
		trace = 0,
		flag = 0,
		allowworldwrites = false,
		builtins = {},
		numbuiltins = 0,
		error_cmd = defaultError,
		warning = defaultWarning,
		cvar_developer = 0,
		cvar_prvm_runawaycheck = 1,
		aot = {},
		jc = 0,
		runaway_limit = 10000000,
	}
end

-- Edict field storage for max_edicts edicts (host calls this; the C version grows it in PRVM_MEM_*).
function prvm_edict.SetMaxEdicts(prog: Prog, max_edicts: number)
	local old = prog.edictsfields
	prog.max_edicts = max_edicts
	prog.entityfieldsarea = prog.entityfields * max_edicts
	local new = buffer.create(prog.entityfieldsarea * 4)
	buffer.copy(new, 0, old, 0, math.min(buffer.len(old), buffer.len(new)))
	prog.edictsfields = new
end

-- port: prvm_edict.c PRVM_Prog_Load L1916-2468 @xonotic-v0.8.6 (PARTIAL: header .. last-statement check, L1983-2276)
function prvm_edict.PRVM_Prog_Load(
	prog: Prog,
	filename: string,
	data: buffer,
	required_fields: { RequiredDef }?,
	required_globals: { RequiredDef }?
)
	local filesize = buffer.len(data)
	local function L(ofs: number): number
		return buffer.readi32(data, ofs)
	end
	prog.numknownstrings = 0
	prog.maxknownstrings = 0
	prog.firstfreeknownstring = 0
	prog.knownstrings = {}
	-- dprograms_t header
	prog.progs_version = L(0)
	prog.progs_crc = L(4)
	if prog.progs_version ~= PROG_VERSION then
		prog.error_cmd(
			string.format(
				"%s: %s has wrong version number (%d should be %d)",
				prog.name,
				filename,
				prog.progs_version,
				PROG_VERSION
			)
		)
	end
	local ofs_statements, numstatements = L(8), L(12)
	local ofs_globaldefs, numglobaldefs = L(16), L(20)
	local ofs_fielddefs, numfielddefs = L(24), L(28)
	local ofs_functions, numfunctions = L(32), L(36)
	local ofs_strings, numstrings = L(40), L(44)
	local ofs_globals, numglobals = L(48), L(52)
	prog.progs_numstatements = numstatements
	prog.progs_numglobals = numglobals
	prog.progs_numfunctions = numfunctions
	prog.progs_entityfields = L(56)
	if ofs_strings + numstrings > filesize then
		prog.error_cmd(string.format("%s: %s strings go past end of file", prog.name, filename))
	end
	prog.strings = buffer.readstring(data, ofs_strings, numstrings)
	prog.stringssize = numstrings
	prog.numstatements = numstatements
	prog.numfunctions = numfunctions
	prog.numglobals = numglobals
	prog.entityfields = prog.progs_entityfields

	-- functions (dfunction_t, 36 bytes)
	prog.functions = table.create(numfunctions)
	for i = 0, numfunctions - 1 do
		local o = ofs_functions + i * 36
		local ps = {}
		for j = 0, 7 do
			ps[j + 1] = buffer.readu8(data, o + 28 + j)
		end
		local f: Function = {
			first_statement = L(o),
			parm_start = L(o + 4),
			locals = L(o + 8),
			s_name = L(o + 16),
			s_file = L(o + 20),
			numparms = L(o + 24),
			parm_size = ps,
			recursion = 0,
			callcount = 0,
		}
		if f.first_statement >= numstatements then
			prog.error_cmd(
				string.format("PRVM_LoadProgs: out of bounds function statement (function %d) in %s", i, prog.name)
			)
		end
		prog.functions[i + 1] = f
	end

	-- globaldefs + required globals (appended after the file's globals)
	prog.globaldefs = {}
	for i = 0, numglobaldefs - 1 do
		local o = ofs_globaldefs + i * 8
		prog.globaldefs[i + 1] =
			{ type = buffer.readu16(data, o), ofs = buffer.readu16(data, o + 2), s_name = L(o + 4) }
	end
	local appendedGlobalNames: { string } = {}
	for _, rg in required_globals or {} do
		table.insert(
			prog.globaldefs,
			{ type = rg.type, ofs = prog.numglobals, s_name = prvm_edict.PRVM_SetEngineString(prog, { str = rg.name }) }
		)
		table.insert(appendedGlobalNames, rg.name)
		prog.numglobals += if rg.type == ev_vector then 3 else 1
	end

	-- fielddefs + required fields
	prog.fielddefs = {}
	for i = 0, numfielddefs - 1 do
		local o = ofs_fielddefs + i * 8
		local t = buffer.readu16(data, o)
		if bit32.band(t, DEF_SAVEGLOBAL) ~= 0 then
			prog.error_cmd(string.format("PRVM_LoadProgs: prog->fielddefs[i].type & DEF_SAVEGLOBAL in %s", prog.name))
		end
		prog.fielddefs[i + 1] = { type = t, ofs = buffer.readu16(data, o + 2), s_name = L(o + 4) }
	end
	for _, rf in required_fields or {} do
		table.insert(prog.fielddefs, {
			type = rf.type,
			ofs = prog.entityfields,
			s_name = prvm_edict.PRVM_SetEngineString(prog, { str = rf.name }),
		})
		prog.entityfields += if rf.type == ev_vector then 3 else 1
	end

	-- (prvm_edict.c L2004-2005: the known-string table starts empty for each load)
	-- copy globals: with PRVM_64 off both branches of the int/float heuristic store the same 32 bits
	prog.globals = buffer.create(prog.numglobals * 4)
	buffer.copy(prog.globals, 0, data, ofs_globals, numglobals * 4)

	-- statements: copy, remap (identity), bounds check
	local st = buffer.create(numstatements * 20)
	prog.statements = st
	local OP_IF, OP_IFNOT, OP_GOTO = OP.IF, OP.IFNOT, OP.GOTO
	for i = 0, numstatements - 1 do
		local o = ofs_statements + i * 8
		local op = buffer.readu16(data, o)
		local a = buffer.readu16(data, o + 2)
		local b = buffer.readu16(data, o + 4)
		local c = buffer.readu16(data, o + 6)
		local w = i * 20
		local o0, o1, o2, jump = -1, -1, -1, -1
		local known = true
		if op == OP_IF or op == OP_IFNOT then
			if b >= 0x8000 then
				b -= 0x10000
			end
			if a >= numglobals or b + i < 0 or b + i >= numstatements then
				prog.error_cmd(
					string.format("PRVM_LoadProgs: out of bounds IF/IFNOT (statement %d) in %s", i, prog.name)
				)
			end
			o0, jump = a, i + b
		elseif op == OP_GOTO then
			if a >= 0x8000 then
				a -= 0x10000
			end
			if a + i < 0 or a + i >= numstatements then
				prog.error_cmd(string.format("PRVM_LoadProgs: out of bounds GOTO (statement %d) in %s", i, prog.name))
			end
			jump = i + a
		elseif GROUP_GGG[op] then
			if a >= numglobals or b >= numglobals or c >= numglobals then
				prog.error_cmd(string.format("PRVM_LoadProgs: out of bounds global index (statement %d)", i))
			end
			o0, o1, o2 = a, b, c
		elseif GROUP_GNG[op] then
			if a >= numglobals or c >= numglobals then
				prog.error_cmd(
					string.format("PRVM_LoadProgs: out of bounds global index (statement %d) in %s", i, prog.name)
				)
			end
			o0, o2 = a, c
		elseif GROUP_GG[op] then
			if a >= numglobals or b >= numglobals then
				prog.error_cmd(
					string.format("PRVM_LoadProgs: out of bounds global index (statement %d) in %s", i, prog.name)
				)
			end
			o0, o1 = a, b
		elseif GROUP_G[op] then
			if a >= numglobals then
				prog.error_cmd(
					string.format("PRVM_LoadProgs: out of bounds global index (statement %d) in %s", i, prog.name)
				)
			end
			o0 = a
		else
			-- C: Con_DPrintf("unknown opcode"), the mstatement_t stays zeroed (op 0 = OP_DONE, operands 0)
			print(string.format("PRVM_LoadProgs: unknown opcode %d at statement %d in %s", op, i, prog.name))
			known = false
		end
		if known then
			buffer.writei32(st, w, op)
			buffer.writei32(st, w + 4, o0)
			buffer.writei32(st, w + 8, o1)
			buffer.writei32(st, w + 12, o2)
			buffer.writei32(st, w + 16, jump)
		end
	end
	if numstatements < 1 then
		prog.error_cmd(string.format("PRVM_LoadProgs: empty program in %s", prog.name))
	else
		local lastop = buffer.readi32(st, (numstatements - 1) * 20)
		if lastop ~= OP.RETURN and lastop ~= OP.GOTO and lastop ~= OP.DONE then
			prog.error_cmd(
				string.format(
					"PRVM_LoadProgs: program may fall off the edge (does not end with RETURN, GOTO or DONE) in %s",
					prog.name
				)
			)
		end
	end
	prvm_edict.SetMaxEdicts(prog, math.max(prog.max_edicts, 1))
	return appendedGlobalNames
end

-- port: prvm_edict.c PRVM_GetString L2960-3010 @xonotic-v0.8.6
function prvm_edict.PRVM_GetString(prog: Prog, num: number): string
	if num < 0 then
		-- invalid
		prog.warning(string.format("PRVM_GetString: Invalid string offset (%d < 0)\n", num))
		return ""
	elseif num < prog.stringssize then
		-- constant string from progs.dat
		local e = string.find(prog.strings, "\0", num + 1, true)
		return string.sub(prog.strings, num + 1, (e or (prog.stringssize + 1)) - 1)
	elseif num <= prog.stringssize + prog.tempstringsbuf.maxsize then
		-- tempstring returned by engine to QC (becomes invalid after returning to engine)
		num -= prog.stringssize
		if num < prog.tempstringsbuf.cursize then
			local d = prog.tempstringsbuf.data
			local e = num
			while e < prog.tempstringsbuf.cursize and buffer.readu8(d, e) ~= 0 do
				e += 1
			end
			return buffer.readstring(d, num, e - num)
		else
			prog.warning(
				string.format(
					"PRVM_GetString: Invalid temp-string offset (%d >= %d prog->tempstringsbuf.cursize)\n",
					num,
					prog.tempstringsbuf.cursize
				)
			)
			return ""
		end
	elseif bit32.band(num, PRVM_KNOWNSTRINGBASE) ~= 0 then
		-- allocated string
		num -= PRVM_KNOWNSTRINGBASE
		if num >= 0 and num < prog.numknownstrings then
			local s = prog.knownstrings[num + 1]
			if not s then
				prog.warning(string.format("PRVM_GetString: Invalid zone-string offset (%d has been freed)\n", num))
				return ""
			end
			return s.str
		else
			prog.warning(
				string.format("PRVM_GetString: Invalid zone-string offset (%d >= %d)\n", num, prog.numknownstrings)
			)
			return ""
		end
	else
		-- invalid string offset
		prog.warning(
			string.format(
				"PRVM_GetString: Invalid constant-string offset (%d >= %d prog->stringssize)\n",
				num,
				prog.stringssize
			)
		)
		return ""
	end
end

-- port: prvm_edict.c PRVM_SetEngineString L3023-3072 @xonotic-v0.8.6
-- `s` is the engine string reference ({ str = ... }); identity of the table = identity of the C pointer.
-- Tempstring-area pointers (s >= tempstringsbuf.data) are represented by { tempofs = n } references.
function prvm_edict.PRVM_SetEngineString(prog: Prog, s: any): number
	if s == nil then
		return 0
	end
	if s.tempofs ~= nil then
		-- if it's in the tempstrings area, use a reserved range
		return prog.stringssize + s.tempofs
	end
	-- see if it's a known string address
	for i = 0, prog.numknownstrings - 1 do
		if prog.knownstrings[i + 1] == s then
			return PRVM_KNOWNSTRINGBASE + i
		end
	end
	-- new unknown engine string
	local i = prog.firstfreeknownstring
	while i < prog.numknownstrings do
		if not prog.knownstrings[i + 1] then
			break
		end
		i += 1
	end
	if i >= prog.numknownstrings then
		if i >= prog.maxknownstrings then
			prog.maxknownstrings += 128
		end
		prog.numknownstrings += 1
	end
	prog.firstfreeknownstring = i + 1
	prog.knownstrings[i + 1] = s
	return PRVM_KNOWNSTRINGBASE + i
end

-- port: prvm_edict.c PRVM_ED_FindField L360-372 @xonotic-v0.8.6 (returns the 1-based def index or nil)
function prvm_edict.PRVM_ED_FindField(prog: Prog, name: string)
	for i, def in prog.fielddefs do
		if prvm_edict.PRVM_GetString(prog, def.s_name) == name then
			return def, i
		end
	end
	return nil
end

-- port: prvm_edict.c PRVM_ED_FindGlobal L379-391 @xonotic-v0.8.6
function prvm_edict.PRVM_ED_FindGlobal(prog: Prog, name: string)
	for i, def in prog.globaldefs do
		if prvm_edict.PRVM_GetString(prog, def.s_name) == name then
			return def, i
		end
	end
	return nil
end

-- port: prvm_edict.c PRVM_ED_FindFunction L399-411 @xonotic-v0.8.6 (returns function record and fnum)
function prvm_edict.PRVM_ED_FindFunction(prog: Prog, name: string)
	for i = 0, prog.numfunctions - 1 do
		local func = prog.functions[i + 1]
		if prvm_edict.PRVM_GetString(prog, func.s_name) == name then
			return func, i
		end
	end
	return nil
end

return prvm_edict
