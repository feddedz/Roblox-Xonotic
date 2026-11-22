--!strict
--[[
	DarkPlaces prvm_cmds.c (common QuakeC builtins), GPLv2 or later (see engine/cvar.luau).
]]
--[[
	Port of prvm_cmds.c @xonotic-v0.8.6. PARTIAL: the cvar builtins and their helpers. Builtins are
	registered by C name in svvm_cmds.PORTED (server); csqc/menu tables later.
	Globals: OFS_RETURN = 1, OFS_PARM0 = 4, parameter i at 4 + 3*i (pr_comp.h), 4-byte slots.
	NOT YET PORTED: everything else in prvm_cmds.c (stubs in engine/svvm_cmds.luau log it).
]]
local cvar = require("./cvar")
local cmd = require("./cmd")
local console = require("./console")
local libc = require("./_port/libc")
local prvm_edict = require("./prvm_edict")
local utf8lib = require("./utf8lib")
local filematch = require("./filematch")
local common = require("./common")
local f32 = require("./_port/f32")
local fs = require("./fs")
local mdfour = require("./mdfour")
local sha256 = require("./_port/sha256")
local mathlib = require("./mathlib")
local host_cmd = require("./host_cmd")

local prvm_cmds = {}

local OFS_RETURN, OFS_PARM0 = 1, 4
local VM_STRINGTEMP_LENGTH = 16384 -- prvm_cmds.h: MAX_INPUTLINE

local function G_STRING(prog: any, ofs: number): string
	return prvm_edict.PRVM_GetString(prog, buffer.readi32(prog.globals, ofs * 4))
end
local function SET_G_FLOAT(prog: any, ofs: number, v: number)
	buffer.writef32(prog.globals, ofs * 4, v)
end
local function SET_G_INT(prog: any, ofs: number, v: number)
	buffer.writei32(prog.globals, ofs * 4, v)
end

local function G_FLOAT(prog: any, ofs: number): number
	return buffer.readf32(prog.globals, ofs * 4)
end

-- VM_SAFEPARMCOUNT (prvm_cmds.h L207)
local function SAFEPARMCOUNT(prog: any, p: number, f: string)
	if prog.argc ~= p then
		prog.error_cmd(string.format("%s wrong parameter count %i (%d expected ) !", f, prog.argc, p))
	end
end

-- VM_SAFEPARMCOUNTRANGE (prvm_cmds.h L206)
local function SAFEPARMCOUNTRANGE(prog: any, p1: number, p2: number, f: string)
	if prog.argc < p1 or prog.argc > p2 then
		prog.error_cmd(string.format("%s wrong parameter count %i (%d to %d expected ) !", f, prog.argc, p1, p2))
	end
end

-- port: prvm_cmds.c VM_Warning L25-44 @xonotic-v0.8.6 (prvm_backtraceforwarnings state dump not ported)
function prvm_cmds.VM_Warning(_prog: any, fmt: string, ...: any)
	console.Con_Print(libc.snprintf(16384, fmt, ...))
end

-- port: prvm_cmds.c VM_CheckEmptyString L55-59 @xonotic-v0.8.6
function prvm_cmds.VM_CheckEmptyString(prog: any, s: string)
	local c = string.byte(s, 1) or 0
	if c == 0 or c == 32 or c == 9 or c == 13 or c == 10 then
		prog.error_cmd(string.format("%s: Bad string", prog.name))
	end
end

-- port: prvm_cmds.c VM_VarString L239-253 @xonotic-v0.8.6
function prvm_cmds.VM_VarString(prog: any, first: number, outlength: number): string
	local parts = {}
	local room = outlength - 1
	local i = first
	while i < prog.argc and room > 0 do
		local s = libc.cstr(G_STRING(prog, OFS_PARM0 + i * 3))
		if #s > room then
			s = string.sub(s, 1, room)
		end
		table.insert(parts, s)
		room -= #s
		i += 1
	end
	return table.concat(parts)
end

-- port: prvm_cmds.c PRVM_Cvar_ReadOk L623-628 @xonotic-v0.8.6
local function PRVM_Cvar_ReadOk(s: string): boolean
	local c = cvar.Cvar_FindVar(s)
	return c ~= nil and bit32.band(c.flags, cvar.CVAR_PRIVATE) == 0
end

-- port: prvm_cmds.c VM_cvar L637-644 @xonotic-v0.8.6
function prvm_cmds.VM_cvar(prog: any)
	SAFEPARMCOUNTRANGE(prog, 1, 8, "VM_cvar")
	local s = prvm_cmds.VM_VarString(prog, 0, VM_STRINGTEMP_LENGTH)
	prvm_cmds.VM_CheckEmptyString(prog, s)
	SET_G_FLOAT(prog, OFS_RETURN, if PRVM_Cvar_ReadOk(s) then cvar.Cvar_VariableValue(s) else 0)
end

-- port: prvm_cmds.c VM_cvar_type L659-690 @xonotic-v0.8.6
function prvm_cmds.VM_cvar_type(prog: any)
	SAFEPARMCOUNTRANGE(prog, 1, 8, "VM_cvar")
	local s = prvm_cmds.VM_VarString(prog, 0, VM_STRINGTEMP_LENGTH)
	prvm_cmds.VM_CheckEmptyString(prog, s)
	local c = cvar.Cvar_FindVar(s)
	if not c then
		SET_G_FLOAT(prog, OFS_RETURN, 0)
		return -- CVAR_TYPE_NONE
	end
	local ret = 1 -- CVAR_EXISTS
	if bit32.band(c.flags, cvar.CVAR_SAVE) ~= 0 then
		ret = bit32.bor(ret, 2) -- CVAR_TYPE_SAVED
	end
	if bit32.band(c.flags, cvar.CVAR_PRIVATE) ~= 0 then
		ret = bit32.bor(ret, 4) -- CVAR_TYPE_PRIVATE
	end
	if bit32.band(c.flags, cvar.CVAR_ALLOCATED) == 0 then
		ret = bit32.bor(ret, 8) -- CVAR_TYPE_ENGINE
	end
	if c.description ~= cvar.cvar_dummy_description then
		ret = bit32.bor(ret, 16) -- CVAR_TYPE_HASDESCRIPTION
	end
	if bit32.band(c.flags, cvar.CVAR_READONLY) ~= 0 then
		ret = bit32.bor(ret, 32) -- CVAR_TYPE_READONLY
	end
	SET_G_FLOAT(prog, OFS_RETURN, ret)
end

-- port: prvm_cmds.c VM_cvar_string L699-706 @xonotic-v0.8.6
function prvm_cmds.VM_cvar_string(prog: any)
	SAFEPARMCOUNTRANGE(prog, 1, 8, "VM_cvar_string")
	local s = prvm_cmds.VM_VarString(prog, 0, VM_STRINGTEMP_LENGTH)
	prvm_cmds.VM_CheckEmptyString(prog, s)
	SET_G_INT(
		prog,
		OFS_RETURN,
		prvm_edict.PRVM_SetTempString(prog, if PRVM_Cvar_ReadOk(s) then cvar.Cvar_VariableString(s).str else "")
	)
end

-- port: prvm_cmds.c VM_cvar_defstring L716-723 @xonotic-v0.8.6
function prvm_cmds.VM_cvar_defstring(prog: any)
	SAFEPARMCOUNTRANGE(prog, 1, 8, "VM_cvar_defstring")
	local s = prvm_cmds.VM_VarString(prog, 0, VM_STRINGTEMP_LENGTH)
	prvm_cmds.VM_CheckEmptyString(prog, s)
	SET_G_INT(prog, OFS_RETURN, prvm_edict.PRVM_SetTempString(prog, cvar.Cvar_VariableDefString(s).str))
end

-- port: prvm_cmds.c VM_cvar_description L732-739 @xonotic-v0.8.6
function prvm_cmds.VM_cvar_description(prog: any)
	SAFEPARMCOUNTRANGE(prog, 1, 8, "VM_cvar_description")
	local s = prvm_cmds.VM_VarString(prog, 0, VM_STRINGTEMP_LENGTH)
	prvm_cmds.VM_CheckEmptyString(prog, s)
	SET_G_INT(prog, OFS_RETURN, prvm_edict.PRVM_SetTempString(prog, cvar.Cvar_VariableDescription(s).str))
end

-- port: prvm_cmds.c VM_cvar_set L747-756 @xonotic-v0.8.6
function prvm_cmds.VM_cvar_set(prog: any)
	SAFEPARMCOUNTRANGE(prog, 2, 8, "VM_cvar_set")
	local s = prvm_cmds.VM_VarString(prog, 1, VM_STRINGTEMP_LENGTH)
	local name = G_STRING(prog, OFS_PARM0)
	prvm_cmds.VM_CheckEmptyString(prog, name)
	cvar.Cvar_Set(name, s)
end

-- port: prvm_cmds.c VM_registercvar L1642-1671 @xonotic-v0.8.6
function prvm_cmds.VM_registercvar(prog: any)
	SAFEPARMCOUNTRANGE(prog, 2, 3, "VM_registercvar")
	local name = G_STRING(prog, OFS_PARM0)
	local value = G_STRING(prog, OFS_PARM0 + 3)
	local flags = if prog.argc >= 3 then libc.toint(buffer.readf32(prog.globals, (OFS_PARM0 + 6) * 4)) else 0
	SET_G_FLOAT(prog, OFS_RETURN, 0)
	if flags > cvar.CVAR_MAXFLAGSVAL then
		return
	end
	-- first check to see if it has already been defined
	if cvar.Cvar_FindVar(name) then
		return
	end
	-- check for overlap with a command
	if cmd.Cmd_Exists(name) then
		prvm_cmds.VM_Warning(prog, "VM_registercvar: %s is a command\n", name)
		return
	end
	cvar.Cvar_Get(name, value, flags, nil)
	SET_G_FLOAT(prog, OFS_RETURN, 1) -- success
end

-- port: prvm_cmds.c VM_print L373-379 @xonotic-v0.8.6
function prvm_cmds.VM_print(prog: any)
	console.Con_Print(prvm_cmds.VM_VarString(prog, 0, VM_STRINGTEMP_LENGTH))
end

-- port: prvm_cmds.c VM_ftos L785-799 @xonotic-v0.8.6
function prvm_cmds.VM_ftos(prog: any)
	SAFEPARMCOUNT(prog, 1, "VM_ftos")
	local v = G_FLOAT(prog, OFS_PARM0)
	local s
	if f32.round(libc.toint(v)) == v then
		s = string.format("%.0f", v)
	else
		s = string.format("%f", v)
	end
	SET_G_INT(prog, OFS_RETURN, prvm_edict.PRVM_SetTempString(prog, libc.snprintf(128, "%s", s)))
end

-- port: prvm_cmds.c VM_stof L862-868 @xonotic-v0.8.6
function prvm_cmds.VM_stof(prog: any)
	SAFEPARMCOUNTRANGE(prog, 1, 8, "VM_stof")
	SET_G_FLOAT(prog, OFS_RETURN, libc.atof(prvm_cmds.VM_VarString(prog, 0, VM_STRINGTEMP_LENGTH)))
end

-- port: prvm_cmds.c VM_floor L1433-1438 @xonotic-v0.8.6
function prvm_cmds.VM_floor(prog: any)
	SAFEPARMCOUNT(prog, 1, "VM_floor")
	SET_G_FLOAT(prog, OFS_RETURN, math.floor(G_FLOAT(prog, OFS_PARM0)))
end

-- port: prvm_cmds.c VM_pow L1750-1754 @xonotic-v0.8.6
function prvm_cmds.VM_pow(prog: any)
	SAFEPARMCOUNT(prog, 2, "VM_pow")
	SET_G_FLOAT(prog, OFS_RETURN, G_FLOAT(prog, OFS_PARM0) ^ G_FLOAT(prog, OFS_PARM0 + 3))
end

-- port: prvm_cmds.c VM_strlen L2170-2176 @xonotic-v0.8.6
function prvm_cmds.VM_strlen(prog: any)
	SAFEPARMCOUNT(prog, 1, "VM_strlen")
	SET_G_FLOAT(prog, OFS_RETURN, utf8lib.u8_strlen(G_STRING(prog, OFS_PARM0)))
end

-- port: prvm_cmds.c VM_strcat L2279-2286 @xonotic-v0.8.6
function prvm_cmds.VM_strcat(prog: any)
	SAFEPARMCOUNTRANGE(prog, 1, 8, "VM_strcat")
	SET_G_INT(
		prog,
		OFS_RETURN,
		prvm_edict.PRVM_SetTempString(prog, prvm_cmds.VM_VarString(prog, 0, VM_STRINGTEMP_LENGTH))
	)
end

-- port: prvm_cmds.c VM_substring L2297-2359 @xonotic-v0.8.6
function prvm_cmds.VM_substring(prog: any)
	SAFEPARMCOUNT(prog, 3, "VM_substring")
	local s = libc.cstr(G_STRING(prog, OFS_PARM0))
	local start = libc.toint(G_FLOAT(prog, OFS_PARM0 + 3))
	local length = libc.toint(G_FLOAT(prog, OFS_PARM0 + 6))
	local u_slength = 0
	if start < 0 then -- FTE_STRINGS feature
		u_slength = utf8lib.u8_strlen(s)
		start += u_slength
		start = math.clamp(start, 0, u_slength)
	end
	if length < 0 then -- FTE_STRINGS feature
		if u_slength == 0 then -- it's not calculated when it's not needed above
			u_slength = utf8lib.u8_strlen(s)
		end
		length += u_slength - start + 1
	end
	local u_start = utf8lib.u8_byteofs(s, start)
	if u_start < 0 then
		SET_G_INT(prog, OFS_RETURN, prvm_edict.PRVM_SetTempString(prog, ""))
		return
	end
	local u_length = utf8lib.u8_bytelen(s, 1 + u_start, length)
	if u_length >= VM_STRINGTEMP_LENGTH - 1 then
		u_length = VM_STRINGTEMP_LENGTH - 1
	end
	SET_G_INT(prog, OFS_RETURN, prvm_edict.PRVM_SetTempString(prog, string.sub(s, 1 + u_start, u_start + u_length)))
end

-- port: prvm_cmds.c VM_strzone L2521-2533 @xonotic-v0.8.6
function prvm_cmds.VM_strzone(prog: any)
	SAFEPARMCOUNT(prog, 1, "VM_strzone")
	local s = prvm_cmds.VM_VarString(prog, 0, VM_STRINGTEMP_LENGTH)
	SET_G_INT(prog, OFS_RETURN, prvm_edict.PRVM_AllocString(prog, #s + 1, s))
end

-- port: prvm_cmds.c VM_strunzone L2543-2547 @xonotic-v0.8.6
function prvm_cmds.VM_strunzone(prog: any)
	SAFEPARMCOUNT(prog, 1, "VM_strunzone")
	prvm_edict.PRVM_FreeString(prog, buffer.readi32(prog.globals, OFS_PARM0 * 4))
end

-- port: prvm_cmds.c VM_str2chr L5671-5690 @xonotic-v0.8.6
function prvm_cmds.VM_str2chr(prog: any)
	SAFEPARMCOUNT(prog, 2, "VM_str2chr")
	local s = libc.cstr(G_STRING(prog, OFS_PARM0))
	local index = utf8lib.u8_bytelen(s, 1, libc.toint(G_FLOAT(prog, OFS_PARM0 + 3)))
	index = libc.toint(index) -- (int) of the size_t result
	local uindex = if index < 0 then index + 4294967296 else index -- (unsigned)
	if uindex < #s then
		local ch
		if utf8lib.enabled() then
			ch = (utf8lib.u8_getchar_utf8_enabled(s, 1 + index))
		else
			ch = string.byte(s, 1 + index)
		end
		SET_G_FLOAT(prog, OFS_RETURN, ch)
	else
		SET_G_FLOAT(prog, OFS_RETURN, 0)
	end
end

-- strcmp / strncmp result as glibc returns it: difference of the first differing bytes (unsigned)
local function cmpbytes(a: string, b: string, n: number): number
	local i = 1
	while i <= n do
		local x, y = string.byte(a, i) or 0, string.byte(b, i) or 0
		if x ~= y then
			return x - y
		end
		if x == 0 then
			return 0
		end
		i += 1
	end
	return 0
end

-- port: prvm_cmds.c VM_strncmp L5898-5912 @xonotic-v0.8.6
function prvm_cmds.VM_strncmp(prog: any)
	SAFEPARMCOUNTRANGE(prog, 2, 3, "VM_strncmp")
	local s1 = libc.cstr(G_STRING(prog, OFS_PARM0))
	local s2 = libc.cstr(G_STRING(prog, OFS_PARM0 + 3))
	if prog.argc > 2 then
		local n = G_FLOAT(prog, OFS_PARM0 + 6)
		n = if n < 0 then math.huge else math.floor(n) -- (size_t) of a float
		SET_G_FLOAT(prog, OFS_RETURN, cmpbytes(s1, s2, n))
	else
		SET_G_FLOAT(prog, OFS_RETURN, cmpbytes(s1, s2, math.huge))
	end
end

local function RETURN_EDICT(prog: any, e: number)
	buffer.writei32(prog.globals, OFS_RETURN * 4, e)
end

-- port: prvm_cmds.c VM_spawn L969-976 @xonotic-v0.8.6 (builtinsprofile counters: profiling only)
function prvm_cmds.VM_spawn(prog: any)
	SAFEPARMCOUNT(prog, 0, "VM_spawn")
	RETURN_EDICT(prog, prvm_edict.PRVM_ED_Alloc(prog))
end

-- port: prvm_cmds.c VM_remove L986-1006 @xonotic-v0.8.6
function prvm_cmds.VM_remove(prog: any)
	SAFEPARMCOUNT(prog, 1, "VM_remove")
	local e = buffer.readi32(prog.globals, OFS_PARM0 * 4)
	local dev = cvar.Cvar_FindVar("developer")
	if e <= prog.reserved_edicts then
		if dev and dev.integer > 0 then
			prvm_cmds.VM_Warning(prog, "VM_remove: tried to remove the null entity or a reserved entity!\n")
		end
	elseif prog.ed_free[e] then
		if dev and dev.integer > 0 then
			prvm_cmds.VM_Warning(prog, "VM_remove: tried to remove an already freed entity!\n")
		end
	else
		prvm_edict.PRVM_ED_Free(prog, e)
	end
end

-- port: prvm_cmds.c VM_nextent L1462-1486 @xonotic-v0.8.6
function prvm_cmds.VM_nextent(prog: any)
	SAFEPARMCOUNT(prog, 1, "VM_nextent")
	local i = buffer.readi32(prog.globals, OFS_PARM0 * 4)
	while true do
		i += 1
		if i == prog.num_edicts then
			RETURN_EDICT(prog, 0)
			return
		end
		if not prog.ed_free[i] then
			RETURN_EDICT(prog, i)
			return
		end
	end
end

-- port: prvm_cmds.c VM_ftoe L890-900 @xonotic-v0.8.6
function prvm_cmds.VM_ftoe(prog: any)
	SAFEPARMCOUNT(prog, 1, "VM_ftoe")
	local ent = libc.toint(G_FLOAT(prog, OFS_PARM0))
	if ent < 0 or ent >= prog.max_edicts or prog.ed_free[ent] then
		ent = 0 -- return world instead of a free or invalid entity
	end
	SET_G_INT(prog, OFS_RETURN, ent)
end

-- port: prvm_cmds.c VM_etof L909-913 @xonotic-v0.8.6
function prvm_cmds.VM_etof(prog: any)
	SAFEPARMCOUNT(prog, 1, "VM_etof")
	SET_G_FLOAT(prog, OFS_RETURN, buffer.readi32(prog.globals, OFS_PARM0 * 4))
end

-- port: prvm_cmds.c VM_bound L1735-1739 @xonotic-v0.8.6 (mathlib.h bound macro)
function prvm_cmds.VM_bound(prog: any)
	SAFEPARMCOUNT(prog, 3, "VM_bound")
	local mn, num, mx = G_FLOAT(prog, OFS_PARM0), G_FLOAT(prog, OFS_PARM0 + 3), G_FLOAT(prog, OFS_PARM0 + 6)
	SET_G_FLOAT(prog, OFS_RETURN, if num >= mn then (if num < mx then num else mx) else mn)
end

--[[ String buffers (prvm_stringbuffer_t in prog->stringbuffersarray). Mem_ExpandableArray hands out the
lowest free record index, which is the buffer number QC sees; a record is
{ strings = { [0..] = string|nil }, num_strings, max_strings, flags }. ]]
local STRINGBUFFER_QCFLAGS = 1 -- progsvm.h L517

local function buffers(prog: any): { [number]: any }
	prog.stringbuffersarray = prog.stringbuffersarray or {}
	return prog.stringbuffersarray
end
-- Mem_ExpandableArray_RecordAtIndex: nil for negative / unallocated indices
local function RecordAtIndex(prog: any, i: number): any
	if i < 0 then
		return nil
	end
	return buffers(prog)[i]
end

-- port: prvm_cmds.c BufStr_Expand L4593-4607 @xonotic-v0.8.6
local function BufStr_Expand(sb: any, strindex: number)
	if sb.max_strings <= strindex then
		sb.max_strings = math.max(sb.max_strings * 2, 128)
		while sb.max_strings <= strindex do
			sb.max_strings *= 2
		end
	end
end

-- port: prvm_cmds.c BufStr_Shrink L4609-4623 @xonotic-v0.8.6
local function BufStr_Shrink(sb: any)
	while sb.num_strings > 0 and sb.strings[sb.num_strings - 1] == nil do
		sb.num_strings -= 1
	end
	if sb.num_strings == 0 then
		sb.max_strings = 0
		sb.strings = {}
	end
end

-- port: prvm_cmds.c BufStr_Set L4680-4702 @xonotic-v0.8.6
local function BufStr_Set(sb: any, strindex: number, str: string?)
	if not sb or strindex < 0 then
		return
	end
	BufStr_Expand(sb, strindex)
	sb.num_strings = math.max(sb.num_strings, strindex + 1)
	sb.strings[strindex] = if str then libc.cstr(str :: string) else nil
	BufStr_Shrink(sb)
end
prvm_cmds.BufStr_Set = BufStr_Set

-- port: prvm_cmds.c VM_buf_create L4742-4762 @xonotic-v0.8.6
function prvm_cmds.VM_buf_create(prog: any)
	SAFEPARMCOUNTRANGE(prog, 0, 2, "VM_buf_create")
	if prog.argc >= 1 and G_STRING(prog, OFS_PARM0) ~= "string" then
		SET_G_FLOAT(prog, OFS_RETURN, -1)
		return
	end
	local arr = buffers(prog)
	local i = 0
	while arr[i] ~= nil do
		i += 1
	end
	local sb = { strings = {}, num_strings = 0, max_strings = 0, flags = 0 }
	arr[i] = sb
	if prog.argc >= 2 then
		sb.flags = bit32.band(libc.toint(G_FLOAT(prog, OFS_PARM0 + 3)), STRINGBUFFER_QCFLAGS)
	end
	SET_G_FLOAT(prog, OFS_RETURN, i)
end

-- port: prvm_cmds.c VM_buf_del L4773-4785 @xonotic-v0.8.6 (BufStr_Del L4704-4719)
function prvm_cmds.VM_buf_del(prog: any)
	SAFEPARMCOUNT(prog, 1, "VM_buf_del")
	local n = libc.toint(G_FLOAT(prog, OFS_PARM0))
	if RecordAtIndex(prog, n) then
		buffers(prog)[n] = nil
	else
		prvm_cmds.VM_Warning(prog, "VM_buf_del: invalid buffer %i used in %s\n", n, prog.name)
	end
end

-- port: prvm_cmds.c VM_buf_getsize L4794-4808 @xonotic-v0.8.6
function prvm_cmds.VM_buf_getsize(prog: any)
	SAFEPARMCOUNT(prog, 1, "VM_buf_getsize")
	local n = libc.toint(G_FLOAT(prog, OFS_PARM0))
	local sb = RecordAtIndex(prog, n)
	if not sb then
		SET_G_FLOAT(prog, OFS_RETURN, -1)
		prvm_cmds.VM_Warning(prog, "VM_buf_getsize: invalid buffer %i used in %s\n", n, prog.name)
	else
		SET_G_FLOAT(prog, OFS_RETURN, sb.num_strings)
	end
end

-- port: prvm_cmds.c VM_bufstr_get L4947-4968 @xonotic-v0.8.6
function prvm_cmds.VM_bufstr_get(prog: any)
	SAFEPARMCOUNT(prog, 2, "VM_bufstr_get")
	SET_G_INT(prog, OFS_RETURN, 0) -- OFS_NULL
	local n = libc.toint(G_FLOAT(prog, OFS_PARM0))
	local sb = RecordAtIndex(prog, n)
	if not sb then
		prvm_cmds.VM_Warning(prog, "VM_bufstr_get: invalid buffer %i used in %s\n", n, prog.name)
		return
	end
	local strindex = libc.toint(G_FLOAT(prog, OFS_PARM0 + 3))
	if strindex < 0 then
		return
	end
	if strindex < sb.num_strings and sb.strings[strindex] then
		SET_G_INT(prog, OFS_RETURN, prvm_edict.PRVM_SetTempString(prog, sb.strings[strindex]))
	end
end

-- port: prvm_cmds.c VM_bufstr_set L4977-5000 @xonotic-v0.8.6
function prvm_cmds.VM_bufstr_set(prog: any)
	SAFEPARMCOUNT(prog, 3, "VM_bufstr_set")
	local n = libc.toint(G_FLOAT(prog, OFS_PARM0))
	local sb = RecordAtIndex(prog, n)
	if not sb then
		prvm_cmds.VM_Warning(prog, "VM_bufstr_set: invalid buffer %i used in %s\n", n, prog.name)
		return
	end
	local strindex = libc.toint(G_FLOAT(prog, OFS_PARM0 + 3))
	if strindex < 0 or strindex >= 1000000 then -- huge number of strings
		prvm_cmds.VM_Warning(prog, "VM_bufstr_set: invalid string index %i used in %s\n", strindex, prog.name)
		return
	end
	BufStr_Set(sb, strindex, G_STRING(prog, OFS_PARM0 + 6))
end

-- port: prvm_cmds.c VM_buf_cvarlist L5434-5508 @xonotic-v0.8.6
function prvm_cmds.VM_buf_cvarlist(prog: any)
	SAFEPARMCOUNTRANGE(prog, 2, 3, "VM_buf_cvarlist")
	local n = libc.toint(G_FLOAT(prog, OFS_PARM0))
	local sb = RecordAtIndex(prog, n)
	if not sb then
		prvm_cmds.VM_Warning(prog, "VM_bufstr_free: invalid buffer %i used in %s\n", n, prog.name)
		return
	end
	local partial = libc.cstr(G_STRING(prog, OFS_PARM0 + 3))
	local len = #partial
	local antipartial = if prog.argc == 3 then libc.cstr(G_STRING(prog, OFS_PARM0 + 6)) else nil
	local antilen = if antipartial then #(antipartial :: string) else 0
	local ispattern = string.find(partial, "[%*%?]") ~= nil
	local antiispattern = antipartial ~= nil and string.find(antipartial :: string, "[%*%?]") ~= nil
	local list = {}
	local count = 0
	local v = cvar.cvar_vars
	while v do
		local skip = false
		if len > 0 then
			if ispattern then
				skip = not filematch.matchpattern_with_separator(v.name, partial, false, "", false)
			else
				skip = string.sub(v.name, 1, len) ~= partial
			end
		end
		if not skip and antilen > 0 then
			if antiispattern then
				skip = filematch.matchpattern_with_separator(v.name, antipartial :: string, false, "", false)
			else
				skip = string.sub(v.name, 1, antilen) == antipartial
			end
		end
		if not skip then
			list[count] = v.name -- 0-based like the C array
			count += 1
		end
		v = v.next
	end
	sb.strings = list
	sb.max_strings, sb.num_strings = count, count
end

-- port: prvm_cmds.c VM_localcmd L615-621 @xonotic-v0.8.6
function prvm_cmds.VM_localcmd(prog: any)
	SAFEPARMCOUNTRANGE(prog, 1, 8, "VM_localcmd")
	cmd.Cbuf_AddText(prvm_cmds.VM_VarString(prog, 0, VM_STRINGTEMP_LENGTH))
end

-- port: prvm_cmds.c VM_min L1683-1698 @xonotic-v0.8.6
function prvm_cmds.VM_min(prog: any)
	SAFEPARMCOUNTRANGE(prog, 2, 8, "VM_min")
	if prog.argc >= 3 then
		local f = G_FLOAT(prog, OFS_PARM0)
		for i = 1, prog.argc - 1 do
			local x = G_FLOAT(prog, OFS_PARM0 + i * 3)
			if f > x then
				f = x
			end
		end
		SET_G_FLOAT(prog, OFS_RETURN, f)
	else
		local a, b = G_FLOAT(prog, OFS_PARM0), G_FLOAT(prog, OFS_PARM0 + 3)
		SET_G_FLOAT(prog, OFS_RETURN, if a < b then a else b)
	end
end

-- port: prvm_cmds.c VM_max L1709-1724 @xonotic-v0.8.6
function prvm_cmds.VM_max(prog: any)
	SAFEPARMCOUNTRANGE(prog, 2, 8, "VM_max")
	if prog.argc >= 3 then
		local f = G_FLOAT(prog, OFS_PARM0)
		for i = 1, prog.argc - 1 do
			local x = G_FLOAT(prog, OFS_PARM0 + i * 3)
			if f < x then
				f = x
			end
		end
		SET_G_FLOAT(prog, OFS_RETURN, f)
	else
		local a, b = G_FLOAT(prog, OFS_PARM0), G_FLOAT(prog, OFS_PARM0 + 3)
		SET_G_FLOAT(prog, OFS_RETURN, if a > b then a else b)
	end
end

-- port: prvm_cmds.c VM_strreplace L2369-2426 @xonotic-v0.8.6
function prvm_cmds.VM_strreplace(prog: any)
	SAFEPARMCOUNT(prog, 3, "VM_strreplace")
	local search = libc.cstr(G_STRING(prog, OFS_PARM0))
	local replace = libc.cstr(G_STRING(prog, OFS_PARM0 + 3))
	local subject = libc.cstr(G_STRING(prog, OFS_PARM0 + 6))
	local sl, rl, subl = #search, #replace, #subject
	local out = {}
	local si = 0
	local cap = VM_STRINGTEMP_LENGTH - 1
	local function put(ch: string)
		if si < cap then
			table.insert(out, ch)
			si += 1
		end
	end
	local i = 0
	while i <= subl - sl do
		local j = 0
		while j < sl and string.byte(subject, i + j + 1) == string.byte(search, j + 1) do
			j += 1
		end
		if j == sl then
			for k = 1, rl do
				if si >= cap then
					break
				end
				put(string.sub(replace, k, k))
			end
			if sl > 0 then
				i += sl - 1
			else
				put(string.sub(subject, i + 1, i + 1))
			end
		else
			put(string.sub(subject, i + 1, i + 1))
		end
		i += 1
	end
	while i < subl do
		put(string.sub(subject, i + 1, i + 1))
		i += 1
	end
	SET_G_INT(prog, OFS_RETURN, prvm_edict.PRVM_SetTempString(prog, table.concat(out)))
end

-- port: prvm_cmds.c VM_strstrofs L5647-5668 @xonotic-v0.8.6
function prvm_cmds.VM_strstrofs(prog: any)
	SAFEPARMCOUNTRANGE(prog, 2, 3, "VM_strstrofs")
	local instr = libc.cstr(G_STRING(prog, OFS_PARM0))
	local match = libc.cstr(G_STRING(prog, OFS_PARM0 + 3))
	local firstofs = if prog.argc > 2 then libc.toint(G_FLOAT(prog, OFS_PARM0 + 6)) else 0
	firstofs = libc.toint(utf8lib.u8_bytelen(instr, 1, firstofs))
	if firstofs ~= 0 and (firstofs < 0 or firstofs > #instr) then
		SET_G_FLOAT(prog, OFS_RETURN, -1)
		return
	end
	local at = string.find(instr, match, firstofs + 1, true)
	if not at then
		SET_G_FLOAT(prog, OFS_RETURN, -1)
	else
		SET_G_FLOAT(prog, OFS_RETURN, utf8lib.u8_strnlen(instr, 1, at - 1))
	end
end

-- port: prvm_cmds.c VM_crc16 L5933-5941 @xonotic-v0.8.6
function prvm_cmds.VM_crc16(prog: any)
	SAFEPARMCOUNTRANGE(prog, 2, 8, "VM_crc16")
	local insensitive = G_FLOAT(prog, OFS_PARM0)
	local s = prvm_cmds.VM_VarString(prog, 1, VM_STRINGTEMP_LENGTH)
	SET_G_FLOAT(prog, OFS_RETURN, if insensitive ~= 0 then common.CRC_Block_CaseInsensitive(s) else common.CRC_Block(s))
end

-- port: prvm_cmds.c VM_uri_escape L6054-6083 @xonotic-v0.8.6
function prvm_cmds.VM_uri_escape(prog: any)
	SAFEPARMCOUNTRANGE(prog, 1, 8, "VM_uri_escape")
	local src = prvm_cmds.VM_VarString(prog, 0, VM_STRINGTEMP_LENGTH)
	local hex = "0123456789ABCDEF"
	local out = {}
	local q = 0
	for k = 1, #src do
		if q >= VM_STRINGTEMP_LENGTH - 3 then
			break
		end
		local c = string.sub(src, k, k)
		if string.find(c, "^[A-Za-z0-9%-_%.!~'()]$") then
			table.insert(out, c)
			q += 1
		else
			local b = string.byte(c)
			table.insert(
				out,
				"%" .. string.sub(hex, b // 16 + 1, b // 16 + 1) .. string.sub(hex, b % 16 + 1, b % 16 + 1)
			)
			q += 3
		end
	end
	SET_G_INT(prog, OFS_RETURN, prvm_edict.PRVM_SetTempString(prog, table.concat(out)))
end

-- port: prvm_cmds.c VM_uri_unescape L6087-6130 @xonotic-v0.8.6
function prvm_cmds.VM_uri_unescape(prog: any)
	SAFEPARMCOUNTRANGE(prog, 1, 8, "VM_uri_unescape")
	local src = prvm_cmds.VM_VarString(prog, 0, VM_STRINGTEMP_LENGTH)
	local function hexv(c: number?): number?
		if not c then
			return nil
		elseif c >= 48 and c <= 57 then
			return c - 48
		elseif c >= 97 and c <= 102 then
			return c - 87
		elseif c >= 65 and c <= 70 then
			return c - 55
		end
		return nil
	end
	local out = {}
	local p = 1
	while p <= #src do
		if string.byte(src, p) == 37 then -- '%'
			local hi, lo = hexv(string.byte(src, p + 1)), hexv(string.byte(src, p + 2))
			if hi and lo then
				if hi ~= 0 or lo ~= 0 then -- don't unescape NUL bytes
					table.insert(out, string.char(hi * 16 + lo))
				end
				p += 3
				continue
			end
		end
		table.insert(out, string.sub(src, p, p))
		p += 1
	end
	SET_G_INT(prog, OFS_RETURN, prvm_edict.PRVM_SetTempString(prog, table.concat(out)))
end

-- port: prvm_cmds.c VM_vlen L492-496 @xonotic-v0.8.6 (VectorLength: float DotProduct, sqrt in double)
function prvm_cmds.VM_vlen(prog: any)
	SAFEPARMCOUNT(prog, 1, "VM_vlen")
	local x, y, z = G_FLOAT(prog, OFS_PARM0), G_FLOAT(prog, OFS_PARM0 + 1), G_FLOAT(prog, OFS_PARM0 + 2)
	local d = f32.add(f32.add(f32.mul(x, x), f32.mul(y, y)), f32.mul(z, z))
	SET_G_FLOAT(prog, OFS_RETURN, math.sqrt(d))
end

-- port: prvm_cmds.c VM_rint L1414-1424 @xonotic-v0.8.6
function prvm_cmds.VM_rint(prog: any)
	SAFEPARMCOUNT(prog, 1, "VM_rint")
	local f = G_FLOAT(prog, OFS_PARM0)
	if f > 0 then
		SET_G_FLOAT(prog, OFS_RETURN, math.floor(f + 0.5))
	else
		SET_G_FLOAT(prog, OFS_RETURN, math.ceil(f - 0.5))
	end
end

-- port: prvm_cmds.c VM_numentityfields L2021-2024 @xonotic-v0.8.6
function prvm_cmds.VM_numentityfields(prog: any)
	SET_G_FLOAT(prog, OFS_RETURN, #prog.fielddefs)
end

-- glibc strcasecmp/strncasecmp result: difference of the first differing tolower()ed bytes
local function casecmp(a: string, b: string, n: number): number
	local i = 1
	while i <= n do
		local x, y = string.byte(a, i) or 0, string.byte(b, i) or 0
		if x >= 65 and x <= 90 then
			x += 32
		end
		if y >= 65 and y <= 90 then
			y += 32
		end
		if x ~= y then
			return x - y
		end
		if x == 0 then
			return 0
		end
		i += 1
	end
	return 0
end

-- port: prvm_cmds.c VM_strncasecmp L5916-5930 @xonotic-v0.8.6
function prvm_cmds.VM_strncasecmp(prog: any)
	SAFEPARMCOUNTRANGE(prog, 2, 3, "VM_strncasecmp")
	local s1 = libc.cstr(G_STRING(prog, OFS_PARM0))
	local s2 = libc.cstr(G_STRING(prog, OFS_PARM0 + 3))
	if prog.argc > 2 then
		local n = G_FLOAT(prog, OFS_PARM0 + 6)
		n = if n < 0 then math.huge else math.floor(n)
		SET_G_FLOAT(prog, OFS_RETURN, casecmp(s1, s2, n))
	else
		SET_G_FLOAT(prog, OFS_RETURN, casecmp(s1, s2, math.huge))
	end
end

-- Tokenizer state shared by tokenize* / argv* (prvm_cmds.c L2586-2593: static, shared by all VMs)
local MAXTOKENS = VM_STRINGTEMP_LENGTH // 2
local num_tokens = 0
local tokens: { [number]: number } = {}
local tokens_startpos: { [number]: number } = {}
local tokens_endpos: { [number]: number } = {}

-- strlcpy(tokenize_string, s, sizeof(tokenize_string))
local function tokenize_copy(s: string): string
	s = libc.cstr(s)
	if #s > VM_STRINGTEMP_LENGTH - 1 then
		s = string.sub(s, 1, VM_STRINGTEMP_LENGTH - 1)
	end
	return s
end

-- port: prvm_cmds.c VM_tokenize_console L2625-2653 @xonotic-v0.8.6
function prvm_cmds.VM_tokenize_console(prog: any)
	SAFEPARMCOUNT(prog, 1, "VM_tokenize")
	local str = tokenize_copy(G_STRING(prog, OFS_PARM0))
	local p: number? = 1
	num_tokens = 0
	while true do
		if num_tokens >= MAXTOKENS then
			break
		end
		local q = p :: number
		while (string.byte(str, q) or 0) ~= 0 and common.ISWHITESPACE(string.byte(str, q) or 0) do
			q += 1
		end
		tokens_startpos[num_tokens] = q - 1
		local ok
		ok, p = common.COM_ParseToken_Console(str, q)
		if not ok then
			break
		end
		tokens_endpos[num_tokens] = (p :: number) - 1
		tokens[num_tokens] = prvm_edict.PRVM_SetTempString(prog, common.com_token)
		num_tokens += 1
	end
	SET_G_FLOAT(prog, OFS_RETURN, num_tokens)
end

-- port: prvm_cmds.c VM_tokenizebyseparator L2669-2731 @xonotic-v0.8.6
function prvm_cmds.VM_tokenizebyseparator(prog: any)
	SAFEPARMCOUNTRANGE(prog, 2, 8, "VM_tokenizebyseparator")
	local str = tokenize_copy(G_STRING(prog, OFS_PARM0))
	local separators = {}
	for j = 1, prog.argc - 1 do
		local sep = libc.cstr(G_STRING(prog, OFS_PARM0 + j * 3))
		if sep ~= "" then
			table.insert(separators, sep)
		end
	end
	num_tokens = 0
	local tokentextlen = 0 -- j: bytes used in tokentext[MAX_INPUTLINE]
	local p = 1
	local n = #str
	while num_tokens < MAXTOKENS do
		tokens_startpos[num_tokens] = p - 1
		local p0 = p
		local tok = {}
		while p <= n do
			local hit = nil
			for _, sep in separators do
				if string.sub(str, p, p + #sep - 1) == sep then
					hit = sep
					break
				end
			end
			if hit then
				p += #hit
				break
			end
			if tokentextlen < VM_STRINGTEMP_LENGTH - 1 then
				table.insert(tok, string.sub(str, p, p))
				tokentextlen += 1
			end
			p += 1
			p0 = p
		end
		tokens_endpos[num_tokens] = p0 - 1
		if tokentextlen >= VM_STRINGTEMP_LENGTH then
			break
		end
		tokentextlen += 1
		tokens[num_tokens] = prvm_edict.PRVM_SetTempString(prog, table.concat(tok))
		num_tokens += 1
		if p > n then
			break
		end
	end
	SET_G_FLOAT(prog, OFS_RETURN, num_tokens)
end

local function tokenindex(prog: any): number?
	SAFEPARMCOUNT(prog, 1, "VM_argv")
	local t = libc.toint(G_FLOAT(prog, OFS_PARM0))
	if t < 0 then
		t += num_tokens
	end
	if t >= 0 and t < num_tokens then
		return t
	end
	return nil
end

-- port: prvm_cmds.c VM_argv L2735-2750 @xonotic-v0.8.6
function prvm_cmds.VM_argv(prog: any)
	local t = tokenindex(prog)
	SET_G_INT(prog, OFS_RETURN, if t then tokens[t] else 0)
end

-- port: prvm_cmds.c VM_argv_start_index L2753-2768 @xonotic-v0.8.6
function prvm_cmds.VM_argv_start_index(prog: any)
	local t = tokenindex(prog)
	SET_G_FLOAT(prog, OFS_RETURN, if t then tokens_startpos[t] else -1)
end

-- port: prvm_cmds.c VM_argv_end_index L2771-2786 @xonotic-v0.8.6
function prvm_cmds.VM_argv_end_index(prog: any)
	local t = tokenindex(prog)
	SET_G_FLOAT(prog, OFS_RETURN, if t then tokens_endpos[t] else -1)
end

-- port: prvm_cmds.c VM_infoadd L5861-5877 @xonotic-v0.8.6
function prvm_cmds.VM_infoadd(prog: any)
	SAFEPARMCOUNTRANGE(prog, 2, 8, "VM_infoadd")
	local info = G_STRING(prog, OFS_PARM0)
	local key = G_STRING(prog, OFS_PARM0 + 3)
	local value = prvm_cmds.VM_VarString(prog, 2, VM_STRINGTEMP_LENGTH)
	local temp = tokenize_copy(info) -- strlcpy(temp, info, VM_STRINGTEMP_LENGTH)
	temp = common.InfoString_SetValue(temp, VM_STRINGTEMP_LENGTH, key, value)
	SET_G_INT(prog, OFS_RETURN, prvm_edict.PRVM_SetTempString(prog, temp))
end

-- port: prvm_cmds.c VM_infoget L5881-5894 @xonotic-v0.8.6
function prvm_cmds.VM_infoget(prog: any)
	SAFEPARMCOUNT(prog, 2, "VM_infoget")
	local info = libc.cstr(G_STRING(prog, OFS_PARM0))
	local key = libc.cstr(G_STRING(prog, OFS_PARM0 + 3))
	local value = common.InfoString_GetValue(info, key, VM_STRINGTEMP_LENGTH) or ""
	SET_G_INT(prog, OFS_RETURN, prvm_edict.PRVM_SetTempString(prog, value))
end

-- C name -> builtin, for the vm_*_builtins tables
-- port: prvm_cmds.c VM_strtolower L2233-2245 @xonotic-v0.8.6
function prvm_cmds.VM_strtolower(prog: any)
	SAFEPARMCOUNT(prog, 1, "VM_strtolower")
	local s = G_STRING(prog, OFS_PARM0)
	SET_G_INT(prog, OFS_RETURN, prvm_edict.PRVM_SetTempString(prog, common.COM_ToLowerString(s, VM_STRINGTEMP_LENGTH)))
end

-- port: prvm_cmds.c VM_strtoupper L2255-2267 @xonotic-v0.8.6
function prvm_cmds.VM_strtoupper(prog: any)
	SAFEPARMCOUNT(prog, 1, "VM_strtoupper")
	local s = G_STRING(prog, OFS_PARM0)
	SET_G_INT(prog, OFS_RETURN, prvm_edict.PRVM_SetTempString(prog, common.COM_ToUpperString(s, VM_STRINGTEMP_LENGTH)))
end

local PRVM_MAX_OPENSEARCHES = 128 -- progsvm.h L272 (not DP_SMALLMEMORY)

local function opensearches(prog: any): { [number]: { string } }
	prog.opensearches = prog.opensearches or {}
	return prog.opensearches
end

-- port: prvm_cmds.c VM_search_begin L3088-3121 @xonotic-v0.8.6 (PRVM_AllocationOrigin: leak report not ported)
function prvm_cmds.VM_search_begin(prog: any)
	SAFEPARMCOUNT(prog, 3, "VM_search_begin")
	local pattern = G_STRING(prog, OFS_PARM0)
	prvm_cmds.VM_CheckEmptyString(prog, pattern)
	local caseinsens = libc.toint(G_FLOAT(prog, OFS_PARM0 + 3))
	local quiet = libc.toint(G_FLOAT(prog, OFS_PARM0 + 6))
	local os_ = opensearches(prog)
	local handle = 0
	while handle < PRVM_MAX_OPENSEARCHES do
		if not os_[handle] then
			break
		end
		handle += 1
	end
	if handle >= PRVM_MAX_OPENSEARCHES then
		SET_G_FLOAT(prog, OFS_RETURN, -2)
		prvm_cmds.VM_Warning(
			prog,
			"VM_search_begin: %s ran out of search handles (%i)\n",
			prog.name,
			PRVM_MAX_OPENSEARCHES
		)
		return
	end
	local r = fs.FS_Search(libc.cstr(pattern), caseinsens ~= 0, quiet ~= 0)
	os_[handle] = r :: any
	if not r then
		SET_G_FLOAT(prog, OFS_RETURN, -1)
	else
		SET_G_FLOAT(prog, OFS_RETURN, handle)
	end
end

-- shared handle checks of VM_search_end / getsize / getfilename
local function searchHandle(prog: any, fname: string): { string }?
	local handle = libc.toint(G_FLOAT(prog, OFS_PARM0))
	if handle < 0 or handle >= PRVM_MAX_OPENSEARCHES then
		prvm_cmds.VM_Warning(prog, "%s: invalid handle %i used in %s\n", fname, handle, prog.name)
		return nil
	end
	local r = opensearches(prog)[handle]
	if r == nil then
		prvm_cmds.VM_Warning(prog, "%s: no such handle %i in %s\n", fname, handle, prog.name)
		return nil
	end
	return r
end

-- port: prvm_cmds.c VM_search_end L3130-3152 @xonotic-v0.8.6
function prvm_cmds.VM_search_end(prog: any)
	SAFEPARMCOUNT(prog, 1, "VM_search_end")
	if searchHandle(prog, "VM_search_end") then
		opensearches(prog)[libc.toint(G_FLOAT(prog, OFS_PARM0))] = nil
	end
end

-- port: prvm_cmds.c VM_search_getsize L3161-3180 @xonotic-v0.8.6
function prvm_cmds.VM_search_getsize(prog: any)
	SAFEPARMCOUNT(prog, 1, "VM_M_search_getsize")
	local r = searchHandle(prog, "VM_search_getsize")
	if r then
		SET_G_FLOAT(prog, OFS_RETURN, #r)
	end
end

-- port: prvm_cmds.c VM_search_getfilename L3189-3214 @xonotic-v0.8.6
function prvm_cmds.VM_search_getfilename(prog: any)
	SAFEPARMCOUNT(prog, 2, "VM_search_getfilename")
	local r = searchHandle(prog, "VM_search_getfilename")
	if not r then
		return
	end
	local filenum = libc.toint(G_FLOAT(prog, OFS_PARM0 + 3))
	if filenum < 0 or filenum >= #r then
		prvm_cmds.VM_Warning(prog, "VM_search_getfilename: invalid filenum %i in %s\n", filenum, prog.name)
		return
	end
	SET_G_INT(prog, OFS_RETURN, prvm_edict.PRVM_SetTempString(prog, r[filenum + 1]))
end

-- port: prvm_cmds.c VM_digest_hex L5944-5990 @xonotic-v0.8.6 (Crypto_Available: the release ships d0_blind_id)
function prvm_cmds.VM_digest_hex(prog: any)
	SAFEPARMCOUNTRANGE(prog, 2, 8, "VM_digest_hex")
	local digest = libc.cstr(G_STRING(prog, OFS_PARM0))
	local s = prvm_cmds.VM_VarString(prog, 1, VM_STRINGTEMP_LENGTH)
	local out: string? = nil
	if digest == "MD4" then
		out = mdfour.mdfour(s)
	elseif digest == "SHA256" then
		out = sha256(s)
	end
	-- no warning needed on mismatch - we return string_null to QC
	if out then
		local hex = string.gsub(out, ".", function(c: string): string
			return string.format("%02x", string.byte(c))
		end)
		SET_G_INT(prog, OFS_RETURN, prvm_edict.PRVM_SetTempString(prog, hex))
	else
		SET_G_INT(prog, OFS_RETURN, 0)
	end
end

local PRVM_MAX_OPENFILES = 256 -- progsvm.h L271 (not DP_SMALLMEMORY)

local function openfiles(prog: any): { [number]: any }
	prog.openfiles = prog.openfiles or {}
	return prog.openfiles
end

local function developer_extra(): boolean
	local v = cvar.Cvar_FindVar("developer_extra")
	return v ~= nil and v.integer ~= 0
end

-- port: prvm_cmds.c VM_fopen L1805-1859 @xonotic-v0.8.6 (PRVM_AllocationOrigin: leak report not ported)
function prvm_cmds.VM_fopen(prog: any)
	SAFEPARMCOUNT(prog, 2, "VM_fopen")
	local of = openfiles(prog)
	local filenum = 0
	while filenum < PRVM_MAX_OPENFILES do
		if of[filenum] == nil then
			break
		end
		filenum += 1
	end
	if filenum >= PRVM_MAX_OPENFILES then
		SET_G_FLOAT(prog, OFS_RETURN, -2)
		prvm_cmds.VM_Warning(prog, "VM_fopen: %s ran out of file handles (%i)\n", prog.name, PRVM_MAX_OPENFILES)
		return
	end
	local filename = libc.cstr(G_STRING(prog, OFS_PARM0))
	local mode = libc.toint(G_FLOAT(prog, OFS_PARM0 + 3))
	local modestring
	if mode == 0 then -- FILE_READ
		modestring = "rb"
		of[filenum] = fs.FS_OpenVirtualFile(string.sub("data/" .. filename, 1, 1023), false)
		if of[filenum] == nil then
			of[filenum] = fs.FS_OpenVirtualFile(string.sub(filename, 1, 1023), false)
		end
	elseif mode == 1 then -- FILE_APPEND
		modestring = "a"
		of[filenum] = fs.FS_OpenRealFile(string.sub("data/" .. filename, 1, 1023), modestring, false)
	elseif mode == 2 then -- FILE_WRITE
		modestring = "w"
		of[filenum] = fs.FS_OpenRealFile(string.sub("data/" .. filename, 1, 1023), modestring, false)
	else
		SET_G_FLOAT(prog, OFS_RETURN, -3)
		prvm_cmds.VM_Warning(
			prog,
			"VM_fopen: %s: no such mode %i (valid: 0 = read, 1 = append, 2 = write)\n",
			prog.name,
			mode
		)
		return
	end
	if of[filenum] == nil then
		SET_G_FLOAT(prog, OFS_RETURN, -1)
		if developer_extra() then
			prvm_cmds.VM_Warning(prog, "VM_fopen: %s: %s mode %s failed\n", prog.name, filename, modestring)
		end
	else
		SET_G_FLOAT(prog, OFS_RETURN, filenum)
		if developer_extra() then
			console.Con_DPrint(
				string.format("VM_fopen: %s: %s mode %s opened as #%i\n", prog.name, filename, modestring, filenum)
			)
		end
	end
end

-- handle checks shared by VM_fclose / VM_fgets / VM_fputs
local function fileHandle(prog: any, fname: string): (any, number)
	local filenum = libc.toint(G_FLOAT(prog, OFS_PARM0))
	if filenum < 0 or filenum >= PRVM_MAX_OPENFILES then
		prvm_cmds.VM_Warning(prog, "%s: invalid file handle %i used in %s\n", fname, filenum, prog.name)
		return nil, filenum
	end
	local f = openfiles(prog)[filenum]
	if f == nil then
		prvm_cmds.VM_Warning(
			prog,
			"%s: no such file handle %i (or file has been closed) in %s\n",
			fname,
			filenum,
			prog.name
		)
	end
	return f, filenum
end

-- port: prvm_cmds.c VM_fclose L1869-1892 @xonotic-v0.8.6
function prvm_cmds.VM_fclose(prog: any)
	SAFEPARMCOUNT(prog, 1, "VM_fclose")
	local f, filenum = fileHandle(prog, "VM_fclose")
	if not f then
		return
	end
	fs.FS_Close(f)
	openfiles(prog)[filenum] = nil
	if developer_extra() then
		console.Con_DPrint(string.format("VM_fclose: %s: #%i closed\n", prog.name, filenum))
	end
end

-- port: prvm_cmds.c VM_fgets L1902-1945 @xonotic-v0.8.6
function prvm_cmds.VM_fgets(prog: any)
	SAFEPARMCOUNT(prog, 1, "VM_fgets")
	-- set the return value regardless of any possible errors
	SET_G_INT(prog, OFS_RETURN, 0) -- OFS_NULL
	local f = fileHandle(prog, "VM_fgets")
	if not f then
		return
	end
	local out = {}
	local c
	while true do
		c = fs.FS_Getc(f)
		if c == 13 or c == 10 or c < 0 then
			break
		end
		if #out < VM_STRINGTEMP_LENGTH - 1 then
			table.insert(out, string.char(c))
		end
	end
	local str = table.concat(out)
	-- remove \n following \r
	if c == 13 then
		c = fs.FS_Getc(f)
		if c ~= 10 then
			fs.FS_UnGetc(f, c % 256) -- (unsigned char)c: EOF becomes 255, as in C
		end
	end
	if developer_extra() then
		console.Con_DPrint(string.format("fgets: %s: %s\n", prog.name, libc.cstr(str)))
	end
	if c >= 0 or #out > 0 then
		SET_G_INT(prog, OFS_RETURN, prvm_edict.PRVM_SetTempString(prog, str))
	end
end

-- port: prvm_cmds.c VM_fputs L1955-1979 @xonotic-v0.8.6
function prvm_cmds.VM_fputs(prog: any)
	SAFEPARMCOUNT(prog, 2, "VM_fputs")
	local f = fileHandle(prog, "VM_fputs")
	if not f then
		return
	end
	local str = prvm_cmds.VM_VarString(prog, 1, VM_STRINGTEMP_LENGTH)
	if #str > 0 then
		fs.FS_Write(f, str)
	end
	if developer_extra() then
		console.Con_DPrint(string.format("fputs: %s: %s\n", prog.name, str))
	end
end

-- port: prvm_cmds.c checkextension L266-309 @xonotic-v0.8.6 (no USEODE in the release's server; Crypto_Available
-- true: the release ships d0_blind_id)
local function checkextension(prog: any, name: string): boolean
	local ext = prog.extensionstring or ""
	local len = #name
	for word in string.gmatch(ext, "[^ ]+") do
		if #word == len and libc.strcasecmp(word, name) == 0 then
			return true
		end
	end
	return false
end
prvm_cmds.checkextension = checkextension

-- port: prvm_cmds.c VM_checkextension L311-316 @xonotic-v0.8.6
function prvm_cmds.VM_checkextension(prog: any)
	SAFEPARMCOUNT(prog, 1, "VM_checkextension")
	SET_G_FLOAT(prog, OFS_RETURN, if checkextension(prog, libc.cstr(G_STRING(prog, OFS_PARM0))) then 1 else 0)
end

-- port: mathlib.h lhrandom L65 @xonotic-v0.8.6 (double arithmetic, glibc rand)
function prvm_cmds.lhrandom(min: number, max: number): number
	return ((libc.rand() + 0.5) / (libc.RAND_MAX + 1)) * (max - min) + min
end

-- port: prvm_cmds.c VM_random L559-564 @xonotic-v0.8.6
function prvm_cmds.VM_random(prog: any)
	SAFEPARMCOUNT(prog, 0, "VM_random")
	SET_G_FLOAT(prog, OFS_RETURN, prvm_cmds.lhrandom(0, 1))
end

-- port: prvm_cmds.c VM_strftime L922-959 @xonotic-v0.8.6
function prvm_cmds.VM_strftime(prog: any)
	SAFEPARMCOUNTRANGE(prog, 2, 8, "VM_strftime")
	local fmt = prvm_cmds.VM_VarString(prog, 1, VM_STRINGTEMP_LENGTH)
	local t = os.time()
	local tm = if G_FLOAT(prog, OFS_PARM0) ~= 0 then libc.localtime(t) else libc.gmtime(t)
	SET_G_INT(prog, OFS_RETURN, prvm_edict.PRVM_SetTempString(prog, libc.strftime(fmt, tm, VM_STRINGTEMP_LENGTH)))
end

-- port: prvm_cmds.c VM_entityfieldname L2035-2049 @xonotic-v0.8.6
function prvm_cmds.VM_entityfieldname(prog: any)
	local i = libc.toint(G_FLOAT(prog, OFS_PARM0))
	if i < 0 or i >= #prog.fielddefs then
		prvm_cmds.VM_Warning(prog, "VM_entityfieldname: %s: field index out of bounds\n", prog.name)
		SET_G_INT(prog, OFS_RETURN, prvm_edict.PRVM_SetTempString(prog, ""))
		return
	end
	SET_G_INT(prog, OFS_RETURN, prog.fielddefs[i + 1].s_name) -- presuming that s_name points to a string already
end

-- port: prvm_cmds.c VM_whichpack L6134-6143 @xonotic-v0.8.6
function prvm_cmds.VM_whichpack(prog: any)
	SAFEPARMCOUNT(prog, 1, "VM_whichpack")
	local pack = fs.FS_WhichPack(libc.cstr(G_STRING(prog, OFS_PARM0)))
	SET_G_INT(prog, OFS_RETURN, if pack then prvm_edict.PRVM_SetTempString(prog, pack) else 0)
end

-- port: prvm_cmds.c VM_sprintf L6506-6827 @xonotic-v0.8.6
-- outbuf is a byte buffer with C pointer o; dpsnprintf returns -1 on truncation and o moves back by one,
-- as in C. INT_LOSSLESS_FORMAT_SIZE "j": integers are intmax_t (64-bit).
local MAX_INPUTLINE = 16384
local PRINTF_ALTERNATE, PRINTF_ZEROPAD, PRINTF_LEFT, PRINTF_SPACEPOSITIVE, PRINTF_SIGNPOSITIVE = 1, 2, 4, 8, 16
function prvm_cmds.VM_sprintf(prog: any)
	local s = libc.cstr(G_STRING(prog, OFS_PARM0))
	local outbuf = buffer.create(MAX_INPUTLINE)
	local o, e = 0, MAX_INPUTLINE
	local argpos = 1
	local function ch(i: number): number
		return string.byte(s, i) or 0
	end
	local function isdig(c: number): boolean
		return c >= 48 and c <= 57
	end
	-- dpsnprintf(o, end - o, ...) of an already formatted string
	local function dp(str: string): number
		local room = e - o
		if #str >= room then
			buffer.writestring(outbuf, o, str, room - 1)
			buffer.writeu8(outbuf, o + room - 1, 0)
			return -1
		end
		buffer.writestring(outbuf, o, str)
		if o + #str < e then
			buffer.writeu8(outbuf, o + #str, 0)
		end
		return #str
	end
	local function inargs(a: number): boolean
		return a >= 1 and a < prog.argc
	end
	local function GETARG_FLOAT(a: number): number
		return if inargs(a) then G_FLOAT(prog, OFS_PARM0 + 3 * a) else 0
	end
	local function GETARG_INT(a: number): number
		return if inargs(a) then buffer.readi32(prog.globals, (OFS_PARM0 + 3 * a) * 4) else 0
	end
	local function GETARG_VEC(a: number, k: number, isfloat: boolean): number
		if not inargs(a) then
			return 0
		end
		local off = (OFS_PARM0 + 3 * a + k) * 4
		return if isfloat then buffer.readf32(prog.globals, off) else buffer.readi32(prog.globals, off)
	end
	local function GETARG_STRING(a: number): string
		return if inargs(a) then libc.cstr(G_STRING(prog, OFS_PARM0 + 3 * a)) else ""
	end
	-- strtol(s, &err, 10) on a digit run, cast to int
	local function strtol_int(i: number): (number, number)
		local _, j = libc.strtol10(s, i)
		return libc.atoi(string.sub(s, i, j - 1)), j
	end
	local function invalid(s0: number)
		prvm_cmds.VM_Warning(prog, "VM_sprintf: invalid directive in %s: %s\n", prog.name, string.sub(s, s0))
	end

	local i = 1
	while true do
		local s0 = i
		local c = ch(i)
		if c == 0 then
			break -- finished
		end
		local verbatim = c ~= 37
		if c == 37 then
			i += 1
			if ch(i) == 37 then
				verbatim = true
			end
		end
		if verbatim then
			if o < e - 1 then
				buffer.writeu8(outbuf, o, ch(i))
				o += 1
			end
			i += 1
			continue
		end
		-- complete directive format: %3$*1$.*2$ld
		local width, precision, thisarg, flags, isfloat = -1, -1, -1, 0, -1
		local stop = false
		-- is number following?
		if isdig(ch(i)) then
			local err
			width, err = strtol_int(i)
			if ch(err) == 36 then -- '$'
				thisarg = width
				width = -1
				i = err + 1
			else
				if ch(i) == 48 then
					flags = bit32.bor(flags, PRINTF_ZEROPAD)
					if width == 0 then
						width = -1 -- it was just a flag
					end
				end
				i = err
			end
		end
		if width < 0 then
			while true do
				local f = ch(i)
				if f == 35 then
					flags = bit32.bor(flags, PRINTF_ALTERNATE)
				elseif f == 48 then
					flags = bit32.bor(flags, PRINTF_ZEROPAD)
				elseif f == 45 then
					flags = bit32.bor(flags, PRINTF_LEFT)
				elseif f == 32 then
					flags = bit32.bor(flags, PRINTF_SPACEPOSITIVE)
				elseif f == 43 then
					flags = bit32.bor(flags, PRINTF_SIGNPOSITIVE)
				else
					break -- noflags
				end
				i += 1
			end
			if ch(i) == 42 then -- '*'
				i += 1
				if isdig(ch(i)) then
					local err
					width, err = strtol_int(i)
					if ch(err) ~= 36 then
						invalid(s0)
						break
					end
					i = err + 1
				else
					width = argpos
					argpos += 1
				end
				width = libc.toint(GETARG_FLOAT(width))
				if width < 0 then
					flags = bit32.bor(flags, PRINTF_LEFT)
					width = if width == -2147483648 then width else -width
				end
			elseif isdig(ch(i)) then
				local err
				width, err = strtol_int(i)
				i = err
				if width < 0 then
					flags = bit32.bor(flags, PRINTF_LEFT)
					width = if width == -2147483648 then width else -width
				end
			end
			-- otherwise width stays -1
		end
		if ch(i) == 46 then -- '.'
			i += 1
			if ch(i) == 42 then
				i += 1
				if isdig(ch(i)) then
					local err
					precision, err = strtol_int(i)
					if ch(err) ~= 36 then
						invalid(s0)
						break
					end
					i = err + 1
				else
					precision = argpos
					argpos += 1
				end
				precision = libc.toint(GETARG_FLOAT(precision))
			elseif isdig(ch(i)) then
				local err
				precision, err = strtol_int(i)
				i = err
			else
				invalid(s0)
				break
			end
		end
		while true do
			local l = ch(i)
			if l == 104 then -- h
				isfloat = 1
			elseif l == 108 or l == 76 then -- l L
				isfloat = 0
			elseif l ~= 106 and l ~= 122 and l ~= 116 then -- j z t: no effect
				break -- nolength
			end
			i += 1
		end
		-- now s points to the final directive char and is no longer changed
		local d = string.char(ch(i))
		if isfloat < 0 then
			isfloat = if d == "i" then 0 else 1
		end
		local fl = isfloat == 1
		if thisarg < 0 then
			thisarg = argpos
			argpos += 1
		end
		if o < e - 1 then
			local fs_ = ""
			if d ~= "s" and d ~= "c" and bit32.band(flags, PRINTF_ALTERNATE) ~= 0 then
				fs_ ..= "#"
			end
			if bit32.band(flags, PRINTF_ZEROPAD) ~= 0 then
				fs_ ..= "0"
			end
			if bit32.band(flags, PRINTF_LEFT) ~= 0 then
				fs_ ..= "-"
			end
			if bit32.band(flags, PRINTF_SPACEPOSITIVE) ~= 0 then
				fs_ ..= " "
			end
			if bit32.band(flags, PRINTF_SIGNPOSITIVE) ~= 0 then
				fs_ ..= "+"
			end
			if width < 0 then -- not set
				width = 0
			end
			-- "%*d" with a negative int width means left-aligned |width| (INT_MIN: C's own UB, treated so too)
			local w, ff = width, fs_
			if w < 0 then
				w = -w
				if not string.find(ff, "-", 1, true) then
					ff ..= "-"
				end
			end
			local p = if precision >= 0 then precision else -1
			if d == "d" or d == "i" then
				o += dp(
					libc.format1(ff, w, p, "d", if fl then libc.toint64(GETARG_FLOAT(thisarg)) else GETARG_INT(thisarg))
				)
			elseif d == "o" or d == "u" or d == "x" or d == "X" then
				local v = if fl then libc.touint64bits(GETARG_FLOAT(thisarg)) else GETARG_INT(thisarg)
				o += dp(libc.format1(ff, w, p, d, v))
			elseif d == "e" or d == "E" or d == "f" or d == "F" or d == "g" or d == "G" then
				o += dp(libc.format1(ff, w, p, d, if fl then GETARG_FLOAT(thisarg) else GETARG_INT(thisarg)))
			elseif d == "v" or d == "V" then
				local g = if d == "v" then "g" else "G"
				local parts = {}
				for k = 0, 2 do
					parts[k + 1] = libc.format1(ff, w, p, g, GETARG_VEC(thisarg, k, fl))
				end
				o += dp(table.concat(parts, " "))
			elseif d == "c" then
				local u = (if fl then libc.toint64(GETARG_FLOAT(thisarg)) else GETARG_INT(thisarg)) % 4294967296
				if bit32.band(flags, PRINTF_ALTERNATE) ~= 0 then
					o += dp(libc.format1(ff, w, -1, "c", u % 256))
				else
					local buf = utf8lib.u8_encodech(if u >= 2147483648 then u - 4294967296 else u) or ""
					if precision < 0 then -- not set
						precision = e - o - 1
					end
					o += dp(utf8lib.u8_strpad(buf, bit32.band(flags, PRINTF_LEFT) ~= 0, width, precision))
				end
			elseif d == "s" then
				if bit32.band(flags, PRINTF_ALTERNATE) ~= 0 then
					o += dp(libc.format1(ff, w, p, "s", GETARG_STRING(thisarg)))
				else
					if precision < 0 then -- not set
						precision = e - o - 1
					end
					local left = bit32.band(flags, PRINTF_LEFT) ~= 0
					if bit32.band(flags, PRINTF_SIGNPOSITIVE) ~= 0 then
						o += dp(utf8lib.u8_strpad(GETARG_STRING(thisarg), left, width, precision))
					else
						o += dp(utf8lib.u8_strpad_colorcodes(GETARG_STRING(thisarg), left, width, precision))
					end
				end
			else
				invalid(s0)
				stop = true
			end
		end
		if stop then
			break
		end
		i += 1
	end
	-- finished:
	buffer.writeu8(outbuf, o, 0)
	SET_G_INT(prog, OFS_RETURN, prvm_edict.PRVM_SetTempString(prog, libc.cstr(buffer.readstring(outbuf, 0, o + 1))))
end

-- port: prvm_cmds.c VM_strdecolorize L2187-2197 @xonotic-v0.8.6
function prvm_cmds.VM_strdecolorize(prog: any)
	SAFEPARMCOUNT(prog, 1, "VM_strdecolorize")
	local _, out = common.COM_StringDecolorize(G_STRING(prog, OFS_PARM0), 0, VM_STRINGTEMP_LENGTH, true)
	SET_G_INT(prog, OFS_RETURN, prvm_edict.PRVM_SetTempString(prog, out))
end

-- vectors and fields
local R = f32.round
local M_PI = 3.14159265358979323846
local function G_VECTOR(prog: any, ofs: number): { number }
	local g = prog.globals
	return { buffer.readf32(g, ofs * 4), buffer.readf32(g, ofs * 4 + 4), buffer.readf32(g, ofs * 4 + 8) }
end
local function SET_G_VECTOR(prog: any, ofs: number, v: { number })
	local g = prog.globals
	buffer.writef32(g, ofs * 4, v[1])
	buffer.writef32(g, ofs * 4 + 4, v[2])
	buffer.writef32(g, ofs * 4 + 8, v[3])
end
-- PRVM_gameglobal* by name (PRVM_FindOffsets: globaloffsets)
local function GlobalOfs(prog: any, name: string): number
	prog.globalofs_cache = prog.globalofs_cache or {}
	local o = prog.globalofs_cache[name]
	if o == nil then
		local d = prvm_edict.PRVM_ED_FindGlobal(prog, name)
		o = if d then (d :: any).ofs else -1
		prog.globalofs_cache[name] = o
	end
	return o
end
local function E_OFS(prog: any, ed: number, f: number): number
	return (ed * prog.entityfields + f) * 4
end
local function E_FLOAT(prog: any, ed: number, f: number): number
	return buffer.readf32(prog.edictsfields, E_OFS(prog, ed, f))
end
local function SET_E_FLOAT(prog: any, ed: number, f: number, v: number)
	buffer.writef32(prog.edictsfields, E_OFS(prog, ed, f), v)
end
local function E_INT(prog: any, ed: number, f: number): number
	return buffer.readi32(prog.edictsfields, E_OFS(prog, ed, f))
end
local function SET_E_INT(prog: any, ed: number, f: number, v: number)
	buffer.writei32(prog.edictsfields, E_OFS(prog, ed, f), v)
end
local function G_EDICTNUM(prog: any, ofs: number): number
	return buffer.readi32(prog.globals, ofs * 4)
end
local function setGameVectors(prog: any, forward: { number }, right: { number }, up: { number })
	SET_G_VECTOR(prog, GlobalOfs(prog, "v_forward"), forward)
	SET_G_VECTOR(prog, GlobalOfs(prog, "v_right"), right)
	SET_G_VECTOR(prog, GlobalOfs(prog, "v_up"), up)
end

-- port: prvm_cmds.c VM_makevectors L4318-4327 @xonotic-v0.8.6
function prvm_cmds.VM_makevectors(prog: any)
	SAFEPARMCOUNT(prog, 1, "VM_makevectors")
	local f, r, u = {}, {}, {}
	mathlib.AngleVectors(G_VECTOR(prog, OFS_PARM0), f, r, u)
	setGameVectors(prog, f, r, u)
end

-- port: prvm_cmds.c VM_vectorvectors L4337-4346 @xonotic-v0.8.6
function prvm_cmds.VM_vectorvectors(prog: any)
	SAFEPARMCOUNT(prog, 1, "VM_vectorvectors")
	local f, r, u = {}, {}, {}
	mathlib.VectorNormalize2(G_VECTOR(prog, OFS_PARM0), f)
	mathlib.VectorVectors(f, r, u)
	setGameVectors(prog, f, r, u)
end

-- port: prvm_cmds.c VM_normalize L463-483 @xonotic-v0.8.6
function prvm_cmds.VM_normalize(prog: any)
	SAFEPARMCOUNT(prog, 1, "VM_normalize")
	local v = G_VECTOR(prog, OFS_PARM0)
	local f = mathlib.DotProduct(v, v)
	local nv = { 0, 0, 0 }
	if f ~= 0 then
		f = 1.0 / math.sqrt(f)
		nv = { R(v[1] * f), R(v[2] * f), R(v[3] * f) }
	end
	SET_G_VECTOR(prog, OFS_RETURN, nv)
end

-- port: prvm_cmds.c VM_vectoyaw L505-524 @xonotic-v0.8.6
function prvm_cmds.VM_vectoyaw(prog: any)
	SAFEPARMCOUNT(prog, 1, "VM_vectoyaw")
	local v = G_VECTOR(prog, OFS_PARM0)
	local yaw = 0
	if not (v[2] == 0 and v[1] == 0) then
		yaw = libc.toint(math.atan2(v[2], v[1]) * 180 / M_PI)
		if yaw < 0 then
			yaw += 360
		end
	end
	SET_G_FLOAT(prog, OFS_RETURN, yaw)
end

-- port: prvm_cmds.c VM_vectoangles L534-548 @xonotic-v0.8.6
function prvm_cmds.VM_vectoangles(prog: any)
	SAFEPARMCOUNTRANGE(prog, 1, 2, "VM_vectoangles")
	local result = {}
	if prog.argc >= 2 then
		mathlib.AnglesFromVectors(result, G_VECTOR(prog, OFS_PARM0), G_VECTOR(prog, OFS_PARM0 + 3), true)
	else
		mathlib.AnglesFromVectors(result, G_VECTOR(prog, OFS_PARM0), nil, true)
	end
	SET_G_VECTOR(prog, OFS_RETURN, result)
end

-- one-argument math builtins: PRVM_G_FLOAT(OFS_RETURN) = fn(PRVM_G_FLOAT(OFS_PARM0)) in double
local function math1(name: string, fn: (number) -> number): (any) -> ()
	return function(prog: any)
		SAFEPARMCOUNT(prog, 1, name)
		SET_G_FLOAT(prog, OFS_RETURN, fn(G_FLOAT(prog, OFS_PARM0)))
	end
end
-- port: prvm_cmds.c VM_ceil L1447-1452 @xonotic-v0.8.6
prvm_cmds.VM_ceil = math1("VM_ceil", math.ceil)
-- port: prvm_cmds.c VM_fabs L809-817 @xonotic-v0.8.6
prvm_cmds.VM_fabs = math1("VM_fabs", math.abs)
-- port: prvm_cmds.c VM_sin L1524-1528 @xonotic-v0.8.6
prvm_cmds.VM_sin = math1("VM_sin", math.sin)
-- port: prvm_cmds.c VM_cos L1536-1540 @xonotic-v0.8.6
prvm_cmds.VM_cos = math1("VM_cos", math.cos)
-- port: prvm_cmds.c VM_sqrt L1549-1553 @xonotic-v0.8.6
prvm_cmds.VM_sqrt = math1("VM_sqrt", math.sqrt)
-- port: prvm_cmds.c VM_asin L1562-1566 @xonotic-v0.8.6
prvm_cmds.VM_asin = math1("VM_asin", math.asin)
-- port: prvm_cmds.c VM_acos L1574-1578 @xonotic-v0.8.6
prvm_cmds.VM_acos = math1("VM_acos", math.acos)
-- port: prvm_cmds.c VM_atan L1586-1590 @xonotic-v0.8.6
prvm_cmds.VM_atan = math1("VM_atan", math.atan)
-- port: prvm_cmds.c VM_tan L1610-1614 @xonotic-v0.8.6
prvm_cmds.VM_tan = math1("VM_tan", math.tan)
-- port: prvm_cmds.c VM_log L1756-1760 @xonotic-v0.8.6
prvm_cmds.VM_log = math1("VM_log", math.log)

-- port: prvm_cmds.c VM_atan2 L1598-1602 @xonotic-v0.8.6
function prvm_cmds.VM_atan2(prog: any)
	SAFEPARMCOUNT(prog, 2, "VM_atan2")
	SET_G_FLOAT(prog, OFS_RETURN, math.atan2(G_FLOAT(prog, OFS_PARM0), G_FLOAT(prog, OFS_PARM0 + 3)))
end

-- port: prvm_cmds.c VM_randomvec L1625-1631 @xonotic-v0.8.6 (VectorRandom, mathlib.h L133)
function prvm_cmds.VM_randomvec(prog: any)
	SAFEPARMCOUNT(prog, 0, "VM_randomvec")
	local v = { 0, 0, 0 }
	repeat
		v[1] = R(prvm_cmds.lhrandom(-1, 1))
		v[2] = R(prvm_cmds.lhrandom(-1, 1))
		v[3] = R(prvm_cmds.lhrandom(-1, 1))
	until not (mathlib.DotProduct(v, v) > 1)
	SET_G_VECTOR(prog, OFS_RETURN, v)
end

-- port: prvm_cmds.c VM_bitshift L4372-4386 @xonotic-v0.8.6 (x86 masks the shift count to 5 bits)
function prvm_cmds.VM_bitshift(prog: any)
	SAFEPARMCOUNT(prog, 2, "VM_bitshift")
	local n1 = libc.toint(math.abs(R(libc.toint(G_FLOAT(prog, OFS_PARM0)))))
	local n2 = libc.toint(G_FLOAT(prog, OFS_PARM0 + 3))
	local r
	if n1 == 0 then
		r = n1
	elseif n2 < 0 then
		r = bit32.arshift(n1, -n2 % 32)
		r = if r >= 2147483648 then r - 4294967296 else r
	else
		r = bit32.lshift(n1, n2 % 32)
		r = if r >= 2147483648 then r - 4294967296 else r
	end
	SET_G_FLOAT(prog, OFS_RETURN, r)
end

-- VM_changeyaw / VM_changepitch body (float arithmetic)
local function changeangle(prog: any, ent: number, idx: number, idealf: string, speedf: string, who: string)
	if ent == 0 then
		prvm_cmds.VM_Warning(prog, "%s: can not modify world entity\n", who)
		return
	end
	if prog.ed_free[ent] then
		prvm_cmds.VM_Warning(prog, "%s: can not modify free entity\n", who)
		return
	end
	local ang = prvm_edict.FieldOfs(prog, "angles") + idx
	local current = R(mathlib.ANGLEMOD(E_FLOAT(prog, ent, ang)))
	local ideal = E_FLOAT(prog, ent, prvm_edict.FieldOfs(prog, idealf))
	local speed = E_FLOAT(prog, ent, prvm_edict.FieldOfs(prog, speedf))
	if current == ideal then
		return
	end
	local move = R(ideal - current)
	if ideal > current then
		if move >= 180 then
			move = R(move - 360)
		end
	else
		if move <= -180 then
			move = R(move + 360)
		end
	end
	if move > 0 then
		if move > speed then
			move = speed
		end
	else
		if move < -speed then
			move = -speed
		end
	end
	current = R(current + move)
	SET_E_FLOAT(prog, ent, ang, R(mathlib.ANGLEMOD(current)))
end

-- port: prvm_cmds.c VM_changeyaw L5522-5573 @xonotic-v0.8.6
function prvm_cmds.VM_changeyaw(prog: any)
	-- this is called (VERY HACKISHLY) by VM_SV_MoveToGoal, so it can not use any parameters
	local self = buffer.readi32(prog.globals, GlobalOfs(prog, "self") * 4)
	changeangle(prog, self, 1, "ideal_yaw", "yaw_speed", "changeyaw")
end

-- port: prvm_cmds.c VM_changepitch L5580-5629 @xonotic-v0.8.6
function prvm_cmds.VM_changepitch(prog: any)
	SAFEPARMCOUNT(prog, 1, "VM_changepitch")
	changeangle(prog, G_EDICTNUM(prog, OFS_PARM0), 0, "idealpitch", "pitch_speed", "changepitch")
end

-- port: prvm_cmds.c VM_vtos L827-835 @xonotic-v0.8.6
function prvm_cmds.VM_vtos(prog: any)
	SAFEPARMCOUNT(prog, 1, "VM_vtos")
	local v = G_VECTOR(prog, OFS_PARM0)
	local str = libc.snprintf(512, "'%5.1f %5.1f %5.1f'", v[1], v[2], v[3])
	SET_G_INT(prog, OFS_RETURN, prvm_edict.PRVM_SetTempString(prog, str))
end

-- port: prvm_cmds.c VM_etos L845-853 @xonotic-v0.8.6
function prvm_cmds.VM_etos(prog: any)
	SAFEPARMCOUNT(prog, 1, "VM_etos")
	SET_G_INT(
		prog,
		OFS_RETURN,
		prvm_edict.PRVM_SetTempString(prog, string.format("entity %i", G_EDICTNUM(prog, OFS_PARM0)))
	)
end

-- port: mathlib.c Math_atov L863-882 @xonotic-v0.8.6 (out: prvm_vec3_t, float)
local function Math_atov(str: string, out: { number }): number
	out[1], out[2], out[3] = 0, 0, 0
	local p = 1
	local function c(): number
		return string.byte(str, p) or 0
	end
	if c() == 39 then
		p += 1
	end
	local i = 0
	while i < 3 do
		while c() == 32 or c() == 9 do
			p += 1
		end
		out[i + 1] = R(libc.atof(string.sub(str, p)))
		local ch = c()
		if out[i + 1] == 0 and ch ~= 45 and ch ~= 43 and (ch < 48 or ch > 57) then
			break -- not a number
		end
		while c() ~= 0 and c() ~= 32 and c() ~= 9 and c() ~= 39 do
			p += 1
		end
		if c() == 39 then
			break
		end
		i += 1
	end
	return i
end
prvm_cmds.Math_atov = Math_atov

-- port: prvm_cmds.c VM_stov L2503-2511 @xonotic-v0.8.6
function prvm_cmds.VM_stov(prog: any)
	SAFEPARMCOUNT(prog, 1, "VM_stov")
	local v = {}
	Math_atov(prvm_cmds.VM_VarString(prog, 0, VM_STRINGTEMP_LENGTH), v)
	SET_G_VECTOR(prog, OFS_RETURN, v)
end

-- port: prvm_cmds.c VM_chr2str L5693-5712 @xonotic-v0.8.6
function prvm_cmds.VM_chr2str(prog: any)
	SAFEPARMCOUNTRANGE(prog, 0, 8, "VM_chr2str")
	local parts = {}
	local len = 0
	local i = 0
	while i < prog.argc and len < 36 do
		local n, bytes = utf8lib.u8_fromchar(libc.toint(G_FLOAT(prog, OFS_PARM0 + i * 3)), 36)
		if n > 0 then
			table.insert(parts, bytes)
		end
		len += n
		i += 1
	end
	SET_G_INT(prog, OFS_RETURN, prvm_edict.PRVM_SetTempString(prog, table.concat(parts)))
end

-- port: prvm_cmds.c VM_strlennocol L2209-2222 @xonotic-v0.8.6
function prvm_cmds.VM_strlennocol(prog: any)
	SAFEPARMCOUNT(prog, 1, "VM_strlennocol")
	local n = utf8lib.u8_COM_StringLengthNoColors(libc.cstr(G_STRING(prog, OFS_PARM0)), 0)
	SET_G_FLOAT(prog, OFS_RETURN, n)
end

-- port: prvm_cmds.c VM_isserver L2795-2800 @xonotic-v0.8.6
function prvm_cmds.VM_isserver(prog: any)
	SAFEPARMCOUNT(prog, 0, "VM_serverstate")
	SET_G_FLOAT(prog, OFS_RETURN, if host_cmd.sv_active then 1 else 0)
end

-- port: prvm_cmds.c VM_wasfreed L5992-5996 @xonotic-v0.8.6
function prvm_cmds.VM_wasfreed(prog: any)
	SAFEPARMCOUNT(prog, 1, "VM_wasfreed")
	SET_G_FLOAT(prog, OFS_RETURN, if prog.ed_free[G_EDICTNUM(prog, OFS_PARM0)] then 1 else 0)
end

-- port: prvm_cmds.c VM_dprint L765-775 @xonotic-v0.8.6
function prvm_cmds.VM_dprint(prog: any)
	SAFEPARMCOUNTRANGE(prog, 1, 8, "VM_dprint")
	console.Con_DPrint(prvm_cmds.VM_VarString(prog, 0, VM_STRINGTEMP_LENGTH))
end

local function E_STRING(prog: any, ed: number, f: number): string
	local t = E_INT(prog, ed, f)
	if t == 0 then
		return "" -- if (!t) t = "";
	end
	return libc.cstr(prvm_edict.PRVM_GetString(prog, t))
end

-- port: prvm_cmds.c VM_find L1016-1050 @xonotic-v0.8.6 (builtinsprofile: profiler counter, not ported)
function prvm_cmds.VM_find(prog: any)
	SAFEPARMCOUNT(prog, 3, "VM_find")
	local e = G_EDICTNUM(prog, OFS_PARM0)
	local f = buffer.readi32(prog.globals, (OFS_PARM0 + 3) * 4)
	local str = libc.cstr(G_STRING(prog, OFS_PARM0 + 6))
	e += 1
	while e < prog.num_edicts do
		if not prog.ed_free[e] and E_STRING(prog, e, f) == str then
			RETURN_EDICT(prog, e)
			return
		end
		e += 1
	end
	RETURN_EDICT(prog, 0)
end

-- port: prvm_cmds.c VM_findfloat L1061-1088 @xonotic-v0.8.6
function prvm_cmds.VM_findfloat(prog: any)
	SAFEPARMCOUNT(prog, 3, "VM_findfloat")
	local e = G_EDICTNUM(prog, OFS_PARM0)
	local f = buffer.readi32(prog.globals, (OFS_PARM0 + 3) * 4)
	local v = G_FLOAT(prog, OFS_PARM0 + 6)
	e += 1
	while e < prog.num_edicts do
		if not prog.ed_free[e] and E_FLOAT(prog, e, f) == v then
			RETURN_EDICT(prog, e)
			return
		end
		e += 1
	end
	RETURN_EDICT(prog, 0)
end

-- (prvm_int_t)float
local function toi(x: number): number
	return libc.toint(x)
end

-- port: prvm_cmds.c VM_findflags L1200-1230 @xonotic-v0.8.6
function prvm_cmds.VM_findflags(prog: any)
	SAFEPARMCOUNT(prog, 3, "VM_findflags")
	local e = G_EDICTNUM(prog, OFS_PARM0)
	local f = buffer.readi32(prog.globals, (OFS_PARM0 + 3) * 4)
	local v = toi(G_FLOAT(prog, OFS_PARM0 + 6))
	e += 1
	while e < prog.num_edicts do
		if not prog.ed_free[e] then
			local x = E_FLOAT(prog, e, f)
			if x ~= 0 and bit32.band(toi(x), v) ~= 0 then
				RETURN_EDICT(prog, e)
				return
			end
		end
		e += 1
	end
	RETURN_EDICT(prog, 0)
end

local function chainfield(prog: any, name: string): number
	local cf = if prog.argc == 3
		then buffer.readi32(prog.globals, (OFS_PARM0 + 6) * 4)
		else prvm_edict.FieldOfs(prog, "chain")
	if cf < 0 then
		prog.error_cmd(string.format("%s: %s doesnt have the specified chain field !", name, prog.name))
	end
	return cf
end

-- shared loop of VM_findchain / VM_findchainfloat / VM_findchainflags
local function findchain(prog: any, cf: number, match: (number) -> boolean)
	local chain = 0
	for i = 1, prog.num_edicts - 1 do
		if not prog.ed_free[i] and match(i) then
			SET_E_INT(prog, i, cf, chain)
			chain = i
		end
	end
	RETURN_EDICT(prog, chain)
end

-- port: prvm_cmds.c VM_findchain L1099-1142 @xonotic-v0.8.6
function prvm_cmds.VM_findchain(prog: any)
	SAFEPARMCOUNTRANGE(prog, 2, 3, "VM_findchain")
	local cf = chainfield(prog, "VM_findchain")
	local f = buffer.readi32(prog.globals, OFS_PARM0 * 4)
	local str = libc.cstr(G_STRING(prog, OFS_PARM0 + 3))
	findchain(prog, cf, function(i: number): boolean
		return E_STRING(prog, i, f) == str
	end)
end

-- port: prvm_cmds.c VM_findchainfloat L1154-1190 @xonotic-v0.8.6
function prvm_cmds.VM_findchainfloat(prog: any)
	SAFEPARMCOUNTRANGE(prog, 2, 3, "VM_findchainfloat")
	local cf = chainfield(prog, "VM_findchain")
	local f = buffer.readi32(prog.globals, OFS_PARM0 * 4)
	local v = G_FLOAT(prog, OFS_PARM0 + 3)
	findchain(prog, cf, function(i: number): boolean
		return E_FLOAT(prog, i, f) == v
	end)
end

-- port: prvm_cmds.c VM_findchainflags L1240-1278 @xonotic-v0.8.6
function prvm_cmds.VM_findchainflags(prog: any)
	SAFEPARMCOUNTRANGE(prog, 2, 3, "VM_findchainflags")
	local cf = chainfield(prog, "VM_findchain")
	local f = buffer.readi32(prog.globals, OFS_PARM0 * 4)
	local v = toi(G_FLOAT(prog, OFS_PARM0 + 3))
	findchain(prog, cf, function(i: number): boolean
		local x = E_FLOAT(prog, i, f)
		return x ~= 0 and bit32.band(toi(x), v) ~= 0
	end)
end

-- port: prvm_cmds.c VM_buf_copy L4817-4861 @xonotic-v0.8.6
-- The C fetches the destination with PARM0 (the source), so dst == src: the strings are freed, the record
-- is assigned to itself, a new zeroed strings array is allocated and the copy loop reads it (all NULL).
-- Net effect, reproduced here: the source keeps num_strings/max_strings but loses every string.
function prvm_cmds.VM_buf_copy(prog: any)
	SAFEPARMCOUNT(prog, 2, "VM_buf_copy")
	local n0 = libc.toint(G_FLOAT(prog, OFS_PARM0))
	local src = RecordAtIndex(prog, n0)
	if not src then
		prvm_cmds.VM_Warning(prog, "VM_buf_copy: invalid source buffer %i used in %s\n", n0, prog.name)
		return
	end
	local i = libc.toint(G_FLOAT(prog, OFS_PARM0 + 3))
	if i == n0 then
		prvm_cmds.VM_Warning(prog, "VM_buf_copy: source == destination (%i) in %s\n", i, prog.name)
		return
	end
	src.strings = {}
end

-- glibc msort (stdlib/msort.c msort_with_tmp): top-down merge sort, n1 = n / 2, the left element wins
-- when cmp <= 0. The comparators below are not consistent for NULL/empty strings, so the algorithm matters.
local function msort(a: { any }, lo: number, n: number, cmp: (any, any) -> number)
	if n <= 1 then
		return
	end
	local n1 = n // 2
	local n2 = n - n1
	msort(a, lo, n1, cmp)
	msort(a, lo + n1, n2, cmp)
	local tmp = table.create(n)
	local i, j = lo, lo + n1
	local ie, je = lo + n1, lo + n
	while i < ie and j < je do
		if cmp(a[i], a[j]) <= 0 then
			table.insert(tmp, a[i])
			i += 1
		else
			table.insert(tmp, a[j])
			j += 1
		end
	end
	while i < ie do
		table.insert(tmp, a[i])
		i += 1
	end
	-- the rest of the right half is already in place
	for k, v in tmp do
		a[lo + k - 1] = v
	end
end

-- port: prvm_cmds.c VM_buf_sort L4871-4897 @xonotic-v0.8.6 (BufStr_SortStringsUP/DOWN L4625-4643)
function prvm_cmds.VM_buf_sort(prog: any)
	SAFEPARMCOUNT(prog, 3, "VM_buf_sort")
	local n = libc.toint(G_FLOAT(prog, OFS_PARM0))
	local sb = RecordAtIndex(prog, n)
	if not sb then
		prvm_cmds.VM_Warning(prog, "VM_buf_sort: invalid buffer %i used in %s\n", n, prog.name)
		return
	end
	if sb.num_strings <= 0 then
		prvm_cmds.VM_Warning(prog, "VM_buf_sort: tried to sort empty buffer %i in %s\n", n, prog.name)
		return
	end
	local sortlength = libc.toint(G_FLOAT(prog, OFS_PARM0 + 3))
	if sortlength <= 0 then
		sortlength = 0x7FFFFFFF
	end
	local function strncmp(a: string, b: string): number
		return libc.strcmp(string.sub(a, 1, sortlength), string.sub(b, 1, sortlength))
	end
	local up = G_FLOAT(prog, OFS_PARM0 + 6) == 0
	local cmp = function(a: string?, b: string?): number
		if not a or a == "" then
			return 1
		end
		if not b or b == "" then
			return -1
		end
		return if up then strncmp(a, b) else strncmp(b, a)
	end
	local arr: { any } = table.create(sb.num_strings)
	for k = 0, sb.num_strings - 1 do
		arr[k] = sb.strings[k] or false
	end
	local wrapped = function(a: any, b: any): number
		return cmp(if a == false then nil else a, if b == false then nil else b)
	end
	msort(arr, 0, sb.num_strings, wrapped)
	for k = 0, sb.num_strings - 1 do
		sb.strings[k] = if arr[k] == false then nil else arr[k]
	end
	BufStr_Shrink(sb)
end

-- port: prvm_cmds.c VM_buf_implode L4906-4938 @xonotic-v0.8.6 (the separator is strlcat'ed before every
-- string, the first included; l does not count it for i == 0)
function prvm_cmds.VM_buf_implode(prog: any)
	SAFEPARMCOUNT(prog, 2, "VM_buf_implode")
	local n = libc.toint(G_FLOAT(prog, OFS_PARM0))
	local sb = RecordAtIndex(prog, n)
	SET_G_INT(prog, OFS_RETURN, 0) -- OFS_NULL
	if not sb then
		prvm_cmds.VM_Warning(prog, "VM_buf_implode: invalid buffer %i used in %s\n", n, prog.name)
		return
	end
	if sb.num_strings == 0 then
		return
	end
	local sep = libc.cstr(G_STRING(prog, OFS_PARM0 + 3))
	local k = ""
	local l = 0
	local cap = VM_STRINGTEMP_LENGTH - 1
	for i = 0, sb.num_strings - 1 do
		local str = sb.strings[i]
		if str then
			l += (if i > 0 then #sep else 0) + #str
			if l >= cap then
				break
			end
			k = string.sub(k .. sep, 1, cap) -- strlcat(k, sep, sizeof(k))
			k = string.sub(k .. str, 1, cap)
		end
	end
	SET_G_INT(prog, OFS_RETURN, prvm_edict.PRVM_SetTempString(prog, k))
end

-- port: prvm_cmds.c VM_bufstr_add L5010-5048 @xonotic-v0.8.6
function prvm_cmds.VM_bufstr_add(prog: any)
	SAFEPARMCOUNT(prog, 3, "VM_bufstr_add")
	local n = libc.toint(G_FLOAT(prog, OFS_PARM0))
	local sb = RecordAtIndex(prog, n)
	SET_G_FLOAT(prog, OFS_RETURN, -1)
	if not sb then
		prvm_cmds.VM_Warning(prog, "VM_bufstr_add: invalid buffer %i used in %s\n", n, prog.name)
		return
	end
	if buffer.readi32(prog.globals, (OFS_PARM0 + 3) * 4) == 0 then -- NULL string
		prvm_cmds.VM_Warning(prog, "VM_bufstr_add: can not add an empty string to buffer %i in %s\n", n, prog.name)
		return
	end
	local str = libc.cstr(G_STRING(prog, OFS_PARM0 + 3))
	local order = libc.toint(G_FLOAT(prog, OFS_PARM0 + 6))
	local strindex
	if order ~= 0 then
		strindex = sb.num_strings
	else
		strindex = 0
		while strindex < sb.num_strings do
			if sb.strings[strindex] == nil then
				break
			end
			strindex += 1
		end
	end
	BufStr_Expand(sb, strindex)
	sb.num_strings = math.max(sb.num_strings, strindex + 1)
	sb.strings[strindex] = str
	SET_G_FLOAT(prog, OFS_RETURN, strindex)
end

-- port: prvm_cmds.c VM_bufstr_free L5057-5084 @xonotic-v0.8.6
function prvm_cmds.VM_bufstr_free(prog: any)
	SAFEPARMCOUNT(prog, 2, "VM_bufstr_free")
	local n = libc.toint(G_FLOAT(prog, OFS_PARM0))
	local sb = RecordAtIndex(prog, n)
	if not sb then
		prvm_cmds.VM_Warning(prog, "VM_bufstr_free: invalid buffer %i used in %s\n", n, prog.name)
		return
	end
	local i = libc.toint(G_FLOAT(prog, OFS_PARM0 + 3))
	if i < 0 then
		prvm_cmds.VM_Warning(prog, "VM_bufstr_free: invalid string index %i used in %s\n", i, prog.name)
		return
	end
	if i < sb.num_strings then
		sb.strings[i] = nil
	end
	BufStr_Shrink(sb)
end

local MATCH_WHOLE, MATCH_LEFT, MATCH_RIGHT, MATCH_MIDDLE, MATCH_PATTERN = 1, 2, 3, 4, 5

-- port: prvm_cmds.c detect_match_rule L5257-5309 @xonotic-v0.8.6 (ppos - pattern == patternlength never
-- holds, so "*x*" and "x*" are MATCH_PATTERN, as in C)
local function detect_match_rule(pattern: string): (string, number)
	local patternlength = #pattern
	local ppos = string.find(pattern, "*", 1, true)
	local qpos = string.find(pattern, "?", 1, true)
	-- has ? - pattern
	if qpos then
		return pattern, MATCH_PATTERN
	end
	-- has * - left, mid, right or pattern
	if ppos then
		-- starts with * - may be right/mid or pattern
		if ppos - 1 == 0 then
			ppos = string.find(pattern, "*", 2, true)
			-- *something
			if not ppos then
				return string.sub(pattern, 2), MATCH_RIGHT
			end
			-- *something*
			if ppos - 1 == patternlength then
				return string.sub(pattern, 2, ppos - 1), MATCH_MIDDLE
			end
			-- *som*thing
			return pattern, MATCH_PATTERN
		end
		-- end with * - left
		if ppos - 1 == patternlength then
			return string.sub(pattern, 1, ppos - 1), MATCH_LEFT
		end
		-- som*thing
		return pattern, MATCH_PATTERN
	end
	-- have no wildcards - whole string
	return pattern, MATCH_WHOLE
end

-- port: prvm_cmds.c match_rule L5312-5329 @xonotic-v0.8.6
local function match_rule(
	str: string,
	max_string: number,
	pattern: string,
	patternlength: number,
	rule: number
): boolean
	if rule == 1 then
		return string.sub(str, 1, max_string) == string.sub(pattern, 1, max_string)
	end
	if rule == 2 then
		return string.sub(str, 1, patternlength) == string.sub(pattern, 1, patternlength)
	end
	if rule == 3 then
		local mid = string.find(str, pattern, 1, true)
		return mid ~= nil and mid + patternlength - 1 == #str
	end
	if rule == 4 then
		return string.find(str, pattern, 1, true) ~= nil
	end
	-- pattern
	return filematch.matchpattern_with_separator(str, pattern, false, "", false)
end

-- port: prvm_cmds.c VM_bufstr_find L5339-5386 @xonotic-v0.8.6
function prvm_cmds.VM_bufstr_find(prog: any)
	SAFEPARMCOUNTRANGE(prog, 3, 5, "VM_bufstr_find")
	SET_G_FLOAT(prog, OFS_RETURN, -1)
	local n = libc.toint(G_FLOAT(prog, OFS_PARM0))
	local sb = RecordAtIndex(prog, n)
	if not sb then
		prvm_cmds.VM_Warning(prog, "VM_bufstr_find: invalid buffer %i used in %s\n", n, prog.name)
		return
	end
	local matchrule = libc.toint(G_FLOAT(prog, OFS_PARM0 + 6))
	local match
	if matchrule ~= 0 then
		match = libc.cstr(G_STRING(prog, OFS_PARM0 + 3))
	else
		match, matchrule =
			detect_match_rule(string.sub(libc.cstr(G_STRING(prog, OFS_PARM0 + 3)), 1, VM_STRINGTEMP_LENGTH - 1))
	end
	local matchlen = #match
	local i = if prog.argc > 3 then libc.toint(G_FLOAT(prog, OFS_PARM0 + 9)) else 0
	local step = if prog.argc > 4 then libc.toint(G_FLOAT(prog, OFS_PARM0 + 12)) else 1
	while i < sb.num_strings do
		local str = sb.strings[i]
		if str and match_rule(str, VM_STRINGTEMP_LENGTH, match, matchlen, matchrule) then
			SET_G_FLOAT(prog, OFS_RETURN, i)
			break
		end
		i += step
	end
end

-- port: prvm_cmds.c VM_matchpattern L5394-5426 @xonotic-v0.8.6
function prvm_cmds.VM_matchpattern(prog: any)
	SAFEPARMCOUNTRANGE(prog, 2, 4, "VM_matchpattern")
	local str = libc.cstr(G_STRING(prog, OFS_PARM0))
	local matchrule = libc.toint(G_FLOAT(prog, OFS_PARM0 + 6))
	local match
	if matchrule ~= 0 then
		match = libc.cstr(G_STRING(prog, OFS_PARM0 + 3))
	else
		match, matchrule =
			detect_match_rule(string.sub(libc.cstr(G_STRING(prog, OFS_PARM0 + 3)), 1, VM_STRINGTEMP_LENGTH - 1))
	end
	local l = #match
	if prog.argc > 3 then
		-- s += max(0, min((unsigned int)PARM3, strlen(s) - 1)) in size_t
		local u = libc.toint64(G_FLOAT(prog, OFS_PARM0 + 9)) % 4294967296
		local lim = if #str == 0 then 2 ^ 64 - 1 else #str - 1
		local off = math.min(u, lim)
		str = string.sub(str, off + 1)
	end
	SET_G_FLOAT(prog, OFS_RETURN, if match_rule(str, VM_STRINGTEMP_LENGTH, match, l, matchrule) then 1 else 0)
end

prvm_cmds.BUILTINS = {
	VM_cvar = prvm_cmds.VM_cvar,
	VM_cvar_type = prvm_cmds.VM_cvar_type,
	VM_cvar_string = prvm_cmds.VM_cvar_string,
	VM_cvar_defstring = prvm_cmds.VM_cvar_defstring,
	VM_cvar_description = prvm_cmds.VM_cvar_description,
	VM_cvar_set = prvm_cmds.VM_cvar_set,
	VM_registercvar = prvm_cmds.VM_registercvar,
	VM_print = prvm_cmds.VM_print,
	VM_ftos = prvm_cmds.VM_ftos,
	VM_stof = prvm_cmds.VM_stof,
	VM_floor = prvm_cmds.VM_floor,
	VM_pow = prvm_cmds.VM_pow,
	VM_strlen = prvm_cmds.VM_strlen,
	VM_strcat = prvm_cmds.VM_strcat,
	VM_substring = prvm_cmds.VM_substring,
	VM_strzone = prvm_cmds.VM_strzone,
	VM_strunzone = prvm_cmds.VM_strunzone,
	VM_str2chr = prvm_cmds.VM_str2chr,
	VM_strncmp = prvm_cmds.VM_strncmp,
	VM_spawn = prvm_cmds.VM_spawn,
	VM_remove = prvm_cmds.VM_remove,
	VM_nextent = prvm_cmds.VM_nextent,
	VM_ftoe = prvm_cmds.VM_ftoe,
	VM_etof = prvm_cmds.VM_etof,
	VM_bound = prvm_cmds.VM_bound,
	VM_localcmd = prvm_cmds.VM_localcmd,
	VM_vlen = prvm_cmds.VM_vlen,
	VM_tokenize_console = prvm_cmds.VM_tokenize_console,
	VM_tokenizebyseparator = prvm_cmds.VM_tokenizebyseparator,
	VM_argv = prvm_cmds.VM_argv,
	VM_infoadd = prvm_cmds.VM_infoadd,
	VM_infoget = prvm_cmds.VM_infoget,
	VM_argv_start_index = prvm_cmds.VM_argv_start_index,
	VM_argv_end_index = prvm_cmds.VM_argv_end_index,
	VM_rint = prvm_cmds.VM_rint,
	VM_numentityfields = prvm_cmds.VM_numentityfields,
	VM_strncasecmp = prvm_cmds.VM_strncasecmp,
	VM_min = prvm_cmds.VM_min,
	VM_max = prvm_cmds.VM_max,
	VM_strreplace = prvm_cmds.VM_strreplace,
	VM_strstrofs = prvm_cmds.VM_strstrofs,
	VM_crc16 = prvm_cmds.VM_crc16,
	VM_uri_escape = prvm_cmds.VM_uri_escape,
	VM_uri_unescape = prvm_cmds.VM_uri_unescape,
	VM_buf_create = prvm_cmds.VM_buf_create,
	VM_buf_del = prvm_cmds.VM_buf_del,
	VM_buf_getsize = prvm_cmds.VM_buf_getsize,
	VM_bufstr_get = prvm_cmds.VM_bufstr_get,
	VM_bufstr_set = prvm_cmds.VM_bufstr_set,
	VM_buf_cvarlist = prvm_cmds.VM_buf_cvarlist,
	VM_strtolower = prvm_cmds.VM_strtolower,
	VM_buf_copy = prvm_cmds.VM_buf_copy,
	VM_buf_sort = prvm_cmds.VM_buf_sort,
	VM_buf_implode = prvm_cmds.VM_buf_implode,
	VM_bufstr_add = prvm_cmds.VM_bufstr_add,
	VM_bufstr_free = prvm_cmds.VM_bufstr_free,
	VM_bufstr_find = prvm_cmds.VM_bufstr_find,
	VM_matchpattern = prvm_cmds.VM_matchpattern,
	VM_makevectors = prvm_cmds.VM_makevectors,
	VM_vectorvectors = prvm_cmds.VM_vectorvectors,
	VM_normalize = prvm_cmds.VM_normalize,
	VM_vectoyaw = prvm_cmds.VM_vectoyaw,
	VM_vectoangles = prvm_cmds.VM_vectoangles,
	VM_ceil = prvm_cmds.VM_ceil,
	VM_fabs = prvm_cmds.VM_fabs,
	VM_sin = prvm_cmds.VM_sin,
	VM_cos = prvm_cmds.VM_cos,
	VM_sqrt = prvm_cmds.VM_sqrt,
	VM_asin = prvm_cmds.VM_asin,
	VM_acos = prvm_cmds.VM_acos,
	VM_atan = prvm_cmds.VM_atan,
	VM_tan = prvm_cmds.VM_tan,
	VM_log = prvm_cmds.VM_log,
	VM_atan2 = prvm_cmds.VM_atan2,
	VM_randomvec = prvm_cmds.VM_randomvec,
	VM_bitshift = prvm_cmds.VM_bitshift,
	VM_changeyaw = prvm_cmds.VM_changeyaw,
	VM_changepitch = prvm_cmds.VM_changepitch,
	VM_vtos = prvm_cmds.VM_vtos,
	VM_etos = prvm_cmds.VM_etos,
	VM_stov = prvm_cmds.VM_stov,
	VM_chr2str = prvm_cmds.VM_chr2str,
	VM_strlennocol = prvm_cmds.VM_strlennocol,
	VM_isserver = prvm_cmds.VM_isserver,
	VM_wasfreed = prvm_cmds.VM_wasfreed,
	VM_dprint = prvm_cmds.VM_dprint,
	VM_find = prvm_cmds.VM_find,
	VM_findfloat = prvm_cmds.VM_findfloat,
	VM_findflags = prvm_cmds.VM_findflags,
	VM_findchain = prvm_cmds.VM_findchain,
	VM_findchainfloat = prvm_cmds.VM_findchainfloat,
	VM_findchainflags = prvm_cmds.VM_findchainflags,
	VM_strdecolorize = prvm_cmds.VM_strdecolorize,
	VM_sprintf = prvm_cmds.VM_sprintf,
	VM_checkextension = prvm_cmds.VM_checkextension,
	VM_random = prvm_cmds.VM_random,
	VM_strftime = prvm_cmds.VM_strftime,
	VM_entityfieldname = prvm_cmds.VM_entityfieldname,
	VM_whichpack = prvm_cmds.VM_whichpack,
	VM_fopen = prvm_cmds.VM_fopen,
	VM_fclose = prvm_cmds.VM_fclose,
	VM_fgets = prvm_cmds.VM_fgets,
	VM_fputs = prvm_cmds.VM_fputs,
	VM_digest_hex = prvm_cmds.VM_digest_hex,
	VM_strtoupper = prvm_cmds.VM_strtoupper,
	VM_search_begin = prvm_cmds.VM_search_begin,
	VM_search_end = prvm_cmds.VM_search_end,
	VM_search_getsize = prvm_cmds.VM_search_getsize,
	VM_search_getfilename = prvm_cmds.VM_search_getfilename,
} :: { [string]: (prog: any) -> () }

return prvm_cmds
