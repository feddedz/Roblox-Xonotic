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
	Port of cvar.c @xonotic-v0.8.6 -- dynamic variable tracking.

	Representation:
	  * cvar_t = Luau table with the C field names. `string`, `defstring` and `description` are C string
	    references `{ str = "..." }`: table identity = pointer identity (PRVM_SetEngineString dedupes by
	    pointer). Cvar_SetQuick_Internal keeps the same reference when the new value has the same length
	    (C reuses the buffer: memcpy) and makes a new one otherwise (Z_Free + Z_Malloc), so QC engine
	    strings alias exactly as in C.
	  * `value`/`vector` are float32 (rounded), `integer` is the C (int) cast of the float (x86-64).
	  * cvar_hashtable (CRC_Block % CVAR_HASHSIZE chains, CVAR_HASHSIZE 65536) is a name -> cvar map:
	    the chains only accelerate an exact strcmp lookup, so results are identical.
	  * `cvar.prvm_prog_list[0..2]` (server, client, menu) is set by PRVM_Prog_Load for autocvars.
	NOT YET PORTED (logged when reached): CL_SetInfo userinfo updates (client), SV_BroadcastPrintf of
	CVAR_NOTIFY changes (needs sv), NetConn_UpdateFavorites (menu). Cvar_CompleteBuildList and
	Cvar_FillAll_f (debug build only) are not ported: console completion is client UI (M7).
]]
local console = require("./console")
local f32 = require("./_port/f32")
local libc = require("./_port/libc")

local cvar = {}

local Con_Printf, Con_Print, Con_DPrintf, Con_DPrint =
	console.Con_Printf, console.Con_Print, console.Con_DPrintf, console.Con_DPrint

-- cvar.h flags
cvar.CVAR_SAVE = 1
cvar.CVAR_NOTIFY = 2
cvar.CVAR_READONLY = 4
cvar.CVAR_SERVERINFO = 8
cvar.CVAR_USERINFO = 16
cvar.CVAR_PRIVATE = 32
cvar.CVAR_NQUSERINFOHACK = 64
cvar.CVAR_NORESETTODEFAULTS = 128
cvar.CVAR_MAXFLAGSVAL = 255
cvar.CVAR_DEFAULTSET = bit32.lshift(1, 30)
cvar.CVAR_ALLOCATED = bit32.lshift(1, 31)
local CVAR_NOTIFY, CVAR_READONLY, CVAR_USERINFO, CVAR_PRIVATE, CVAR_NQUSERINFOHACK =
	cvar.CVAR_NOTIFY, cvar.CVAR_READONLY, cvar.CVAR_USERINFO, cvar.CVAR_PRIVATE, cvar.CVAR_NQUSERINFOHACK
local CVAR_NORESETTODEFAULTS, CVAR_SAVE, CVAR_MAXFLAGSVAL =
	cvar.CVAR_NORESETTODEFAULTS, cvar.CVAR_SAVE, cvar.CVAR_MAXFLAGSVAL
local CVAR_DEFAULTSET, CVAR_ALLOCATED = cvar.CVAR_DEFAULTSET, cvar.CVAR_ALLOCATED

local PRVM_PROG_MAX = 3 -- progsvm.h
local MAX_INPUTLINE = 16384 -- quakedef.h
local DEF_SAVEGLOBAL = 32768 -- pr_comp.h (1 << 15)
local ev_string, ev_float, ev_vector = 1, 2, 3

export type CStr = { str: string }
export type Cvar = {
	flags: number,
	name: string,
	string: CStr,
	description: CStr,
	integer: number,
	value: number,
	vector: { number },
	defstring: CStr,
	initstate: boolean,
	initflags: number,
	initstring: CStr?,
	initdescription: CStr?,
	initinteger: number,
	initvalue: number,
	initvector: { number },
	initdefstring: CStr?,
	globaldefindex: { [number]: number }, -- [0..2]
	globaldefindex_stringno: { [number]: number },
	next: Cvar?,
}

local function band(a: number, b: number): number
	return bit32.band(a, b)
end
local function bor(a: number, b: number): number
	return bit32.bor(a, b)
end
local function bnot(a: number): number
	return bit32.bnot(a)
end

local function newstr(s: string): CStr
	return { str = s }
end

-- const char *cvar_dummy_description = "custom cvar";   (ALWAYS the same pointer)
cvar.cvar_dummy_description = newstr("custom cvar")
local cvar_dummy_description = cvar.cvar_dummy_description
-- const char *cvar_null_string = "";
cvar.cvar_null_string = newstr("")
local cvar_null_string = cvar.cvar_null_string

cvar.cvar_vars = nil :: Cvar? -- alphabetical list
local cvar_hashtable: { [string]: Cvar } = {}

-- prvm_prog_list[i] for autocvars: set by PRVM_Prog_Load (prog.loaded, globaldefs, globals buffer)
cvar.prvm_prog_list = {} :: { [number]: any }

-- hooks to modules that are not ported yet or would create require cycles
cvar.Cmd_Exists = function(_name: string): boolean
	return false
end
cvar.sv_active = function(): boolean
	return false
end
cvar.cls_state_dedicated = true -- the Roblox server runs like a dedicated server (cls.state == ca_dedicated)

console.getcvar = function(name: string)
	return cvar_hashtable[name]
end

local function developer_extra(): boolean
	local v = cvar_hashtable["developer_extra"]
	return v ~= nil and v.integer ~= 0
end

local function setvalue(var: Cvar)
	var.value = f32.round(libc.atof(var.string.str))
	var.integer = libc.toint(var.value)
end

-- port: cvar.c Cvar_FindVar L35-47 @xonotic-v0.8.6
function cvar.Cvar_FindVar(var_name: string): Cvar?
	return cvar_hashtable[libc.cstr(var_name)]
end
local Cvar_FindVar = cvar.Cvar_FindVar

-- port: cvar.c Cvar_FindVarAfter L49-71 @xonotic-v0.8.6
function cvar.Cvar_FindVarAfter(prev_var_name: string, neededflags: number): Cvar?
	local var: Cvar?
	if prev_var_name ~= "" then
		var = Cvar_FindVar(prev_var_name)
		if not var then
			return nil
		end
		var = (var :: Cvar).next
	else
		var = cvar.cvar_vars
	end
	-- search for the next cvar matching the needed flags
	while var do
		if band(var.flags, neededflags) ~= 0 or neededflags == 0 then
			break
		end
		var = var.next
	end
	return var
end

-- port: cvar.c Cvar_FindVarLink L73-101 @xonotic-v0.8.6
-- Returns var and the previous var in the alphabetical list (prev_alpha). The hash-chain links are
-- implicit in the map. (C indexes cvar_hashtable with the unreduced CRC here; harmless because
-- CVAR_HASHSIZE is 65536 = the CRC range.)
local function Cvar_FindVarLink(var_name: string): (Cvar?, Cvar?)
	local var = cvar_hashtable[var_name]
	if not var then
		return nil, nil
	end
	if var == cvar.cvar_vars then
		return var, nil
	end
	local prev = cvar.cvar_vars :: Cvar
	while prev.next ~= var do
		prev = prev.next :: Cvar
	end
	return var, prev
end

-- port: cvar.c Cvar_VariableValueOr L108-116 @xonotic-v0.8.6 (returns the C float)
function cvar.Cvar_VariableValueOr(var_name: string, def: number): number
	local var = Cvar_FindVar(var_name)
	if not var then
		return def
	end
	return f32.round(libc.atof(var.string.str))
end

-- port: cvar.c Cvar_VariableValue L118-121 @xonotic-v0.8.6
function cvar.Cvar_VariableValue(var_name: string): number
	return cvar.Cvar_VariableValueOr(var_name, 0)
end

-- port: cvar.c Cvar_VariableStringOr L128-136 @xonotic-v0.8.6 (returns the C string reference)
function cvar.Cvar_VariableStringOr(var_name: string, def: CStr): CStr
	local var = Cvar_FindVar(var_name)
	if not var then
		return def
	end
	return var.string
end

-- port: cvar.c Cvar_VariableString L138-141 @xonotic-v0.8.6
function cvar.Cvar_VariableString(var_name: string): CStr
	return cvar.Cvar_VariableStringOr(var_name, cvar_null_string)
end

-- port: cvar.c Cvar_VariableDefString L148-156 @xonotic-v0.8.6
function cvar.Cvar_VariableDefString(var_name: string): CStr
	local var = Cvar_FindVar(var_name)
	if not var then
		return cvar_null_string
	end
	return var.defstring
end

-- port: cvar.c Cvar_VariableDescription L163-171 @xonotic-v0.8.6
function cvar.Cvar_VariableDescription(var_name: string): CStr
	local var = Cvar_FindVar(var_name)
	if not var then
		return cvar_null_string
	end
	return var.description
end

-- port: cvar.c Cvar_CompleteVariable L179-195 @xonotic-v0.8.6
function cvar.Cvar_CompleteVariable(partial: string): string?
	local len = #partial
	if len == 0 then
		return nil
	end
	local lp = libc.lowerascii(partial)
	local v = cvar.cvar_vars
	while v do
		if libc.lowerascii(string.sub(v.name, 1, len)) == lp then
			return v.name
		end
		v = v.next
	end
	return nil
end

-- port: cvar.c Cvar_CompleteCountPossible L206-224 @xonotic-v0.8.6
function cvar.Cvar_CompleteCountPossible(partial: string): number
	local len = #partial
	if len == 0 then
		return 0
	end
	local h = 0
	local lp = libc.lowerascii(partial)
	local v = cvar.cvar_vars
	while v do
		if libc.lowerascii(string.sub(v.name, 1, len)) == lp then
			h += 1
		end
		v = v.next
	end
	return h
end

-- port: cvar.c Cvar_CompleteCvarPrint L255-263 @xonotic-v0.8.6
function cvar.Cvar_CompleteCvarPrint(partial: string)
	local len = #partial
	local lp = libc.lowerascii(partial)
	local v = cvar.cvar_vars
	while v do
		if libc.lowerascii(string.sub(v.name, 1, len)) == lp then
			Con_Printf('^3%s^7 is "%s" ["%s"] %s\n', v.name, v.string.str, v.defstring.str, v.description.str)
		end
		v = v.next
	end
end

-- port: cvar.c Cvar_IsAutoCvar L266-277 @xonotic-v0.8.6
local function Cvar_IsAutoCvar(var: Cvar): boolean
	for i = 0, PRVM_PROG_MAX - 1 do
		local prog = cvar.prvm_prog_list[i]
		if prog and prog.loaded and var.globaldefindex[i] >= 0 then
			return true
		end
	end
	return false
end

-- port: cvar.c Cvar_UpdateAutoCvar L280-322 @xonotic-v0.8.6
local function Cvar_UpdateAutoCvar(var: Cvar)
	for i = 0, PRVM_PROG_MAX - 1 do
		local prog = cvar.prvm_prog_list[i]
		if prog and prog.loaded and var.globaldefindex[i] >= 0 then
			-- MUST BE SYNCED WITH prvm_edict.c PRVM_LoadProgs
			local def = prog.globaldefs[var.globaldefindex[i] + 1]
			local t = band(def.type, bnot(DEF_SAVEGLOBAL))
			if t == ev_float then
				buffer.writef32(prog.globals, def.ofs * 4, var.value)
			elseif t == ev_vector then
				local s = var.string.str
				local p = 1
				local v = { 0, 0, 0 }
				local function at(k: number): number
					return string.byte(s, k) or 0
				end
				local function ws(c: number): boolean
					return c == 0 or c == 32 or c == 9 or c == 13 or c == 10
				end
				for j = 1, 3 do
					while at(p) ~= 0 and ws(at(p)) do
						p += 1
					end
					if at(p) == 0 then
						break
					end
					v[j] = f32.round(libc.atof(string.sub(s, p)))
					while not ws(at(p)) do
						p += 1
					end
					if at(p) == 0 then
						break
					end
				end
				for j = 1, 3 do
					buffer.writef32(prog.globals, (def.ofs + j - 1) * 4, v[j])
				end
			elseif t == ev_string then
				prog.ChangeEngineString(prog, var.globaldefindex_stringno[i], var.string)
				buffer.writei32(prog.globals, def.ofs * 4, var.globaldefindex_stringno[i])
			end
		end
	end
end
cvar.Cvar_UpdateAutoCvar = Cvar_UpdateAutoCvar

-- port: cvar.c Cvar_UpdateAllAutoCvars L325-330 @xonotic-v0.8.6
function cvar.Cvar_UpdateAllAutoCvars()
	local v = cvar.cvar_vars
	while v do
		Cvar_UpdateAutoCvar(v)
		v = v.next
	end
end

local warnedNotPorted: { [string]: boolean } = {}
local function notPorted(what: string)
	if not warnedNotPorted[what] then
		warnedNotPorted[what] = true
		print("NOT YET PORTED: " .. what)
	end
end

-- port: cvar.c Cvar_SetQuick_Internal L338-421 @xonotic-v0.8.6
local function Cvar_SetQuick_Internal(var: Cvar, value: string)
	value = libc.cstr(value)
	local changed = var.string.str ~= value
	-- LordHavoc: don't reallocate when there is no change
	if not changed then
		return
	end
	-- LordHavoc: don't reallocate when the buffer is the same size
	if #var.string.str ~= #value then
		var.string = newstr(value) -- Z_Free + Z_Malloc: a new pointer
	else
		var.string.str = value -- memcpy into the same buffer
	end
	setvalue(var)
	if band(var.flags, CVAR_NOTIFY) ~= 0 and changed and cvar.sv_active() then
		local d = Cvar_FindVar("sv_disablenotify")
		if not (d and d.integer ~= 0) then
			notPorted('SV_BroadcastPrintf("\\"%s\\" changed to \\"%s\\"\\n") (sv_send.c)')
		end
	end
	if band(var.flags, CVAR_USERINFO) ~= 0 and not cvar.cls_state_dedicated then
		notPorted("CL_SetInfo (cl_main.c) for CVAR_USERINFO")
	elseif band(var.flags, CVAR_NQUSERINFOHACK) ~= 0 and not cvar.cls_state_dedicated then
		if var.name == "rcon_secure" then
			-- whenever rcon_secure is changed to 0, clear rcon_password
			if var.integer <= 0 then
				cvar.Cvar_Set("rcon_password", "")
			end
		else
			notPorted("CL_SetInfo (cl_main.c) for CVAR_NQUSERINFOHACK " .. var.name)
		end
	end
	Cvar_UpdateAutoCvar(var)
end

-- port: cvar.c Cvar_SetQuick L423-435 @xonotic-v0.8.6
function cvar.Cvar_SetQuick(var: Cvar?, value: string)
	if var == nil then
		Con_Print("Cvar_SetQuick: var == NULL\n")
		return
	end
	local v = var :: Cvar
	if developer_extra() then
		Con_DPrintf(
			'Cvar_SetQuick({"%s", "%s", %i, "%s"}, "%s");\n',
			v.name,
			v.string.str,
			v.flags,
			v.defstring.str,
			value
		)
	end
	Cvar_SetQuick_Internal(v, value)
end

-- port: cvar.c Cvar_Set L437-447 @xonotic-v0.8.6
function cvar.Cvar_Set(var_name: string, value: string)
	local var = Cvar_FindVar(var_name)
	if var == nil then
		Con_Printf("Cvar_Set: variable %s not found\n", var_name)
		return
	end
	cvar.Cvar_SetQuick(var, value)
end

-- (float)((int)value) == value ? "%i" : "%f"   (value is a C float)
local function formatvalue(value: number): string
	value = f32.round(value)
	local i = libc.toint(value)
	local s
	if f32.round(i) == value then
		s = string.format("%d", i)
	else
		s = string.format("%f", value)
	end
	return libc.snprintf(MAX_INPUTLINE, "%s", s)
end
cvar.formatvalue = formatvalue

-- port: cvar.c Cvar_SetValueQuick L454-463 @xonotic-v0.8.6
function cvar.Cvar_SetValueQuick(var: Cvar?, value: number)
	cvar.Cvar_SetQuick(var, formatvalue(value))
end

-- port: cvar.c Cvar_SetValue L465-474 @xonotic-v0.8.6
function cvar.Cvar_SetValue(var_name: string, value: number)
	cvar.Cvar_Set(var_name, formatvalue(value))
end

local function linkAlpha(var: Cvar)
	-- link the variable in alphanumerical order
	local current: Cvar? = nil
	local nxt = cvar.cvar_vars
	while nxt and libc.strcmp(nxt.name, var.name) < 0 do
		current = nxt
		nxt = nxt.next
	end
	if current then
		current.next = var
	else
		cvar.cvar_vars = var
	end
	var.next = nxt
end

-- Builds a static cvar_t like `cvar_t x = {flags, "name", "string", "description"};`
function cvar.static(flags: number, name: string, string: string, description: string?): Cvar
	return {
		flags = flags,
		name = name,
		string = newstr(string),
		description = if description then newstr(description) else nil :: any,
		integer = 0,
		value = 0,
		vector = { 0, 0, 0 },
		defstring = nil :: any,
		initstate = false,
		initflags = 0,
		initinteger = 0,
		initvalue = 0,
		initvector = { 0, 0, 0 },
		globaldefindex = { [0] = -1, [1] = -1, [2] = -1 },
		globaldefindex_stringno = { [0] = 0, [1] = 0, [2] = 0 },
		next = nil,
	}
end

-- port: cvar.c Cvar_RegisterVariable L483-576 @xonotic-v0.8.6
function cvar.Cvar_RegisterVariable(variable: Cvar)
	if developer_extra() then
		Con_DPrintf('Cvar_RegisterVariable({"%s", "%s", %i});\n', variable.name, variable.string.str, variable.flags)
	end
	-- first check to see if it has already been defined
	local c = Cvar_FindVar(variable.name)
	if c then
		if band(c.flags, CVAR_ALLOCATED) ~= 0 then
			if developer_extra() then
				Con_DPrintf('...  replacing existing allocated cvar {"%s", "%s", %i}\n', c.name, c.string.str, c.flags)
			end
			-- fixed variables replace allocated ones
			variable.flags = bor(variable.flags, band(c.flags, bnot(CVAR_ALLOCATED)))
			variable.string = c.string -- cvar->string is now owned by variable instead
			variable.defstring = c.defstring
			setvalue(variable)
			-- Preserve autocvar status.
			for i = 0, PRVM_PROG_MAX - 1 do
				variable.globaldefindex[i] = c.globaldefindex[i]
				variable.globaldefindex_stringno[i] = c.globaldefindex_stringno[i]
			end
			-- replace cvar with this one...
			variable.next = c.next
			if cvar.cvar_vars == c then
				cvar.cvar_vars = variable
			else
				local current = cvar.cvar_vars :: Cvar
				while current.next ~= c do
					current = current.next :: Cvar
				end
				current.next = variable
			end
			-- (C keeps the old struct on its hash chain behind the new head? No: the old struct is
			-- freed while still linked in cvar_hashtable -- a dangling pointer in DarkPlaces. The note
			-- above says this path is unused: all cvars are registered before config parsing.)
			cvar_hashtable[variable.name] = variable
		else
			Con_DPrintf("Can't register variable %s, already defined\n", variable.name)
		end
		return
	end
	-- check for overlap with a command
	if cvar.Cmd_Exists(variable.name) then
		Con_Printf("Cvar_RegisterVariable: %s is a command\n", variable.name)
		return
	end
	-- copy the value off, because future sets will Z_Free it
	local oldstr = variable.string.str
	variable.string = newstr(oldstr)
	variable.defstring = newstr(oldstr)
	setvalue(variable)
	-- Mark it as not an autocvar.
	for i = 0, PRVM_PROG_MAX - 1 do
		variable.globaldefindex[i] = -1
	end
	linkAlpha(variable)
	-- link to head of list in this hash table index
	cvar_hashtable[variable.name] = variable
end

-- port: cvar.c Cvar_Get L585-663 @xonotic-v0.8.6
function cvar.Cvar_Get(name: string, value: string, flags: number, newdescription: string?): Cvar?
	name, value = libc.cstr(name), libc.cstr(value)
	if developer_extra() then
		Con_DPrintf('Cvar_Get("%s", "%s", %i);\n', name, value, flags)
	end
	-- first check to see if it has already been defined
	local c = Cvar_FindVar(name)
	if c then
		c.flags = bor(c.flags, flags)
		Cvar_SetQuick_Internal(c, value)
		if newdescription and band(c.flags, CVAR_ALLOCATED) ~= 0 then
			if newdescription ~= "" then
				c.description = newstr(newdescription)
			else
				c.description = cvar_dummy_description
			end
		end
		return c
	end
	-- check for pure evil
	if name == "" then
		Con_Printf("Cvar_Get: invalid variable name\n")
		return nil
	end
	-- check for overlap with a command
	if cvar.Cmd_Exists(name) then
		Con_Printf("Cvar_Get: %s is a command\n", name)
		return nil
	end
	-- allocate a new cvar, cvar name, and cvar string
	local v = cvar.static(bor(flags, CVAR_ALLOCATED), name, value, nil)
	v.defstring = newstr(value)
	setvalue(v)
	if newdescription and newdescription ~= "" then
		v.description = newstr(newdescription)
	else
		v.description = cvar_dummy_description -- actually checked by VM_cvar_type
	end
	linkAlpha(v)
	cvar_hashtable[v.name] = v
	return v
end

-- port: cvar.c Cvar_Command L673-701 @xonotic-v0.8.6 (Cmd_Argc/Cmd_Argv passed in by cmd.luau)
function cvar.Cvar_Command(argc: number, argv: (number) -> string): boolean
	-- check variables
	local v = Cvar_FindVar(argv(0))
	if not v then
		return false
	end
	-- perform a variable print or set
	if argc == 1 then
		Con_Printf(
			'"%s" is "%s" ["%s"]\n',
			v.name,
			if band(v.flags, CVAR_PRIVATE) ~= 0 then "********" else v.string.str,
			v.defstring.str
		)
		return true
	end
	if developer_extra() then
		Con_DPrint("Cvar_Command: ")
	end
	if band(v.flags, CVAR_READONLY) ~= 0 then
		Con_Printf("%s is read-only\n", v.name)
		return true
	end
	cvar.Cvar_Set(v.name, argv(1))
	if developer_extra() then
		Con_DPrint("\n")
	end
	return true
end

-- port: cvar.c Cvar_UnlockDefaults L704-710 @xonotic-v0.8.6
function cvar.Cvar_UnlockDefaults()
	local v = cvar.cvar_vars
	while v do
		v.flags = band(v.flags, bnot(CVAR_DEFAULTSET))
		v = v.next
	end
end

-- port: cvar.c Cvar_LockDefaults_f L713-731 @xonotic-v0.8.6
function cvar.Cvar_LockDefaults_f()
	local v = cvar.cvar_vars
	while v do
		if band(v.flags, CVAR_DEFAULTSET) == 0 then
			v.flags = bor(v.flags, CVAR_DEFAULTSET)
			v.defstring = newstr(v.string.str)
		end
		v = v.next
	end
end

-- port: cvar.c Cvar_SaveInitState L733-746 @xonotic-v0.8.6
function cvar.Cvar_SaveInitState()
	local c = cvar.cvar_vars
	while c do
		c.initstate = true
		c.initflags = c.flags
		c.initdefstring = newstr(c.defstring.str)
		c.initstring = newstr(c.string.str)
		c.initvalue = c.value
		c.initinteger = c.integer
		c.initvector = { c.vector[1], c.vector[2], c.vector[3] }
		c = c.next
	end
end

-- port: cvar.c Cvar_RestoreInitState L748-823 @xonotic-v0.8.6
function cvar.Cvar_RestoreInitState()
	local prev: Cvar? = nil -- cp = &prev->next (or &cvar_vars)
	local c = cvar.cvar_vars
	while c do
		if c.initstate then
			-- restore this cvar, it existed at init
			local ids = if c.initdefstring then (c.initdefstring :: CStr).str else ""
			local is = if c.initstring then (c.initstring :: CStr).str else ""
			if
				band(bit32.bxor(c.flags, c.initflags), CVAR_MAXFLAGSVAL) ~= 0
				or c.defstring.str ~= ids
				or c.string.str ~= is
			then
				Con_DPrintf('Cvar_RestoreInitState: Restoring cvar "%s"\n', c.name)
				c.defstring = newstr(ids)
				c.string = newstr(is)
			end
			c.flags = c.initflags
			c.value = c.initvalue
			c.integer = c.initinteger
			c.vector = { c.initvector[1], c.initvector[2], c.initvector[3] }
			prev = c
			c = c.next
		else
			if band(c.flags, CVAR_ALLOCATED) == 0 then
				Con_DPrintf(
					'Cvar_RestoreInitState: Unable to destroy cvar "%s", it was registered after init!\n',
					c.name
				)
				-- In this case, at least reset it to the default.
				if band(c.flags, CVAR_NORESETTODEFAULTS) == 0 then
					cvar.Cvar_SetQuick(c, c.defstring.str)
				end
				prev = c
				c = c.next
				continue
			end
			if Cvar_IsAutoCvar(c) then
				Con_DPrintf(
					'Cvar_RestoreInitState: Unable to destroy cvar "%s", it is an autocvar used by running progs!\n',
					c.name
				)
				if band(c.flags, CVAR_NORESETTODEFAULTS) == 0 then
					cvar.Cvar_SetQuick(c, c.defstring.str)
				end
				prev = c
				c = c.next
				continue
			end
			-- remove this cvar, it did not exist at init
			Con_DPrintf('Cvar_RestoreInitState: Destroying cvar "%s"\n', c.name)
			cvar_hashtable[c.name] = nil
			local nxt = c.next
			if prev then
				prev.next = nxt
			else
				cvar.cvar_vars = nxt
			end
			c = nxt
		end
	end
end

-- port: cvar.c Cvar_ResetToDefaults_All_f L825-832 @xonotic-v0.8.6
function cvar.Cvar_ResetToDefaults_All_f()
	local v = cvar.cvar_vars
	while v do
		if band(v.flags, CVAR_NORESETTODEFAULTS) == 0 then
			cvar.Cvar_SetQuick(v, v.defstring.str)
		end
		v = v.next
	end
end

-- port: cvar.c Cvar_ResetToDefaults_NoSaveOnly_f L835-842 @xonotic-v0.8.6
function cvar.Cvar_ResetToDefaults_NoSaveOnly_f()
	local v = cvar.cvar_vars
	while v do
		if band(v.flags, bor(CVAR_NORESETTODEFAULTS, CVAR_SAVE)) == 0 then
			cvar.Cvar_SetQuick(v, v.defstring.str)
		end
		v = v.next
	end
end

-- port: cvar.c Cvar_ResetToDefaults_SaveOnly_f L845-852 @xonotic-v0.8.6
function cvar.Cvar_ResetToDefaults_SaveOnly_f()
	local v = cvar.cvar_vars
	while v do
		if band(v.flags, bor(CVAR_NORESETTODEFAULTS, CVAR_SAVE)) == CVAR_SAVE then
			cvar.Cvar_SetQuick(v, v.defstring.str)
		end
		v = v.next
	end
end

-- port: cvar.c Cvar_WriteVariables L863-876 @xonotic-v0.8.6 (returns the text FS_Printf would write)
function cvar.Cvar_WriteVariables(quote: (string, string) -> string): string
	local out = {}
	local v = cvar.cvar_vars
	while v do
		if
			band(v.flags, CVAR_SAVE) ~= 0
			and (
				v.string.str ~= v.defstring.str
				or (band(v.flags, CVAR_ALLOCATED) ~= 0 and band(v.flags, CVAR_DEFAULTSET) == 0)
			)
		then
			table.insert(
				out,
				string.format(
					'%s"%s" "%s"\n',
					if band(v.flags, CVAR_ALLOCATED) ~= 0 then "seta " else "",
					quote(v.name, '"\\$'),
					quote(v.string.str, '"\\$')
				)
			)
		end
		v = v.next
	end
	return table.concat(out)
end

-- port: cvar.c Cvar_List_f L886-926 @xonotic-v0.8.6
function cvar.Cvar_List_f(argc: number, argv: (number) -> string, matchpattern_with_separator: any)
	local partial: string? = nil
	local len = 0
	local ispattern = false
	if argc > 1 then
		partial = argv(1)
		len = #(partial :: string)
		ispattern = string.find(partial :: string, "*", 1, true) ~= nil
			or string.find(partial :: string, "?", 1, true) ~= nil
	end
	local count = 0
	local v = cvar.cvar_vars
	while v do
		local skip = false
		if len > 0 then
			if ispattern then
				skip = not matchpattern_with_separator(v.name, partial, false, "", false)
			else
				skip = string.sub(v.name, 1, len) ~= partial
			end
		end
		if not skip then
			Con_Printf(
				'%s is "%s" ["%s"] %s\n',
				v.name,
				if band(v.flags, CVAR_PRIVATE) ~= 0 then "********" else v.string.str,
				v.defstring.str,
				v.description.str
			)
			count += 1
		end
		v = v.next
	end
	if len > 0 then
		if ispattern then
			Con_Printf('%i cvar%s matching "%s"\n', count, if count > 1 then "s" else "", partial :: string)
		else
			Con_Printf('%i cvar%s beginning with "%s"\n', count, if count > 1 then "s" else "", partial :: string)
		end
	else
		Con_Printf("%i cvar(s)\n", count)
	end
end

-- port: cvar.c Cvar_Set_f L929-953 @xonotic-v0.8.6
function cvar.Cvar_Set_f(argc: number, argv: (number) -> string)
	if argc < 3 then
		Con_Printf("Set: wrong number of parameters, usage: set <variablename> <value> [<description>]\n")
		return
	end
	local c = Cvar_FindVar(argv(1))
	if c and band(c.flags, CVAR_READONLY) ~= 0 then
		Con_Printf("Set: %s is read-only\n", c.name)
		return
	end
	if developer_extra() then
		Con_DPrint("Set: ")
	end
	cvar.Cvar_Get(argv(1), argv(2), 0, if argc > 3 then argv(3) else nil)
end

-- port: cvar.c Cvar_SetA_f L955-979 @xonotic-v0.8.6
function cvar.Cvar_SetA_f(argc: number, argv: (number) -> string)
	if argc < 3 then
		Con_Printf("SetA: wrong number of parameters, usage: seta <variablename> <value> [<description>]\n")
		return
	end
	local c = Cvar_FindVar(argv(1))
	if c and band(c.flags, CVAR_READONLY) ~= 0 then
		Con_Printf("SetA: %s is read-only\n", c.name)
		return
	end
	if developer_extra() then
		Con_DPrint("SetA: ")
	end
	cvar.Cvar_Get(argv(1), argv(2), CVAR_SAVE, if argc > 3 then argv(3) else nil)
end

-- port: cvar.c Cvar_Del_f L981-1033 @xonotic-v0.8.6
function cvar.Cvar_Del_f(argc: number, argv: (number) -> string)
	if argc < 2 then
		Con_Printf("Del: wrong number of parameters, useage: unset <variablename1> [<variablename2> ...]\n")
		return
	end
	for i = 1, argc - 1 do
		local c, prev = Cvar_FindVarLink(argv(i))
		if not c then
			Con_Printf("Del: %s is not defined\n", argv(i))
			continue
		end
		local v = c :: Cvar
		if band(v.flags, CVAR_READONLY) ~= 0 then
			Con_Printf("Del: %s is read-only\n", v.name)
			continue
		end
		if band(v.flags, CVAR_ALLOCATED) == 0 then
			Con_Printf("Del: %s is static and cannot be deleted\n", v.name)
			continue
		end
		if v == cvar.cvar_vars then
			cvar.cvar_vars = v.next
		else
			(prev :: Cvar).next = v.next
		end
		cvar_hashtable[v.name] = nil
	end
end

-- Test support: forget every cvar (a fresh engine).
function cvar.reset()
	cvar.cvar_vars = nil
	table.clear(cvar_hashtable)
	cvar.prvm_prog_list = {}
end

return cvar
