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
