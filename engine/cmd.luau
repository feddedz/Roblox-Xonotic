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
	Port of cmd.c @xonotic-v0.8.6 -- Quake script command processing module.

	Representation: the command buffer `cmd_text` is a Luau string (cursize = #cmd_text). Byte reads past
	cursize, which C performs on stale buffer bytes in two places of Cbuf_Execute, read as NUL here.
	cmd_functions / cmd_alias are kept as strcmp-sorted arrays (C: alphabetical linked lists); lookups
	use strcasecmp and return the first match in list order, like the C loops.
	Commands get their arguments through cmd.Cmd_Argc / cmd.Cmd_Argv like C.
	NOT YET PORTED (log when reached): Cmd_ForwardToServer / Cmd_ForwardStringToServer (client),
	CL_VM_ConsoleCommand (csqc), SCR_CenterPrint (cprint),
	thread mutexes (single-threaded), command completion (client UI).
]]
local common = require("./common")
local console = require("./console")
local cvar = require("./cvar")
local filematch = require("./filematch")
local fs = require("./fs")
local libc = require("./_port/libc")

local cmd = {}

local Con_Printf, Con_Print, Con_DPrintf = console.Con_Printf, console.Con_Print, console.Con_DPrintf

-- quakedef.h
local MAX_INPUTLINE = 16384
local MAX_ALIAS_NAME = 32
local CMDBUFSIZE = 655360
local MAX_ARGS = 80
local CMD_TOKENIZELENGTH = MAX_INPUTLINE + MAX_ARGS
local CONFIGFILENAME = "config.cfg"
cmd.STARTCONFIGFILENAME = "quake.rc"

-- cmd.h cmd_source_t
cmd.src_client = 0
cmd.src_command = 1

local ISWHITESPACE = common.ISWHITESPACE

local function at(s: string, i: number): number
	return string.byte(s, i) or 0
end

local warned: { [string]: boolean } = {}
local function notPorted(what: string)
	if not warned[what] then
		warned[what] = true
		print("NOT YET PORTED: " .. what)
	end
end

type Alias = { name: string, value: string, initstate: boolean, initialvalue: string? }
type Command = {
	name: string,
	description: string,
	consolefunction: (() -> ())?,
	clientfunction: (() -> ())?,
	csqcfunc: boolean,
	initstate: boolean,
}

local cmd_alias: { Alias } = {}
local cmd_functions: { Command } = {}
local cmd_wait = false
local cmd_tokenizebufferpos = 0

-- engine state this module reads (set by host / tests)
cmd.com_argv = {} :: { string } -- com_argv[0..argc-1] as a 1-based array (com_argv[1] = program name)
cmd.gamemode = "GAME_XONOTIC"
cmd.host_framecount = 0
cmd.realtime = 0
cmd.host_stuffcmdsrun = false
cmd.cls_state_connected = false

-- COM_CheckParm (common.c L1413-1428): position of parm in com_argv, or 0
local function COM_CheckParm(parm: string): number
	for i = 2, #cmd.com_argv do
		if cmd.com_argv[i] == parm then
			return i - 1
		end
	end
	return 0
end

--=============================================================================

-- port: cmd.c Cmd_Wait_f L54-57 @xonotic-v0.8.6
local function Cmd_Wait_f()
	cmd_wait = true
end

type Deferred = { value: string, delay: number }
local cmd_deferred_list: { Deferred } = {}

-- port: cmd.c Cmd_Defer_f L75-123 @xonotic-v0.8.6
local function Cmd_Defer_f()
	local argc = cmd.Cmd_Argc()
	if argc == 1 then
		if #cmd_deferred_list == 0 then
			Con_Printf("No commands are pending.\n")
		end
		for _, d in cmd_deferred_list do
			Con_Printf("-> In %9.2f: %s\n", d.delay, d.value)
		end
	elseif argc == 2 and libc.strcasecmp("clear", cmd.Cmd_Argv(1)) == 0 then
		table.clear(cmd_deferred_list)
	elseif argc == 3 then
		table.insert(cmd_deferred_list, { value = cmd.Cmd_Argv(2), delay = libc.atof(cmd.Cmd_Argv(1)) })
	else
		Con_Printf("usage: defer <seconds> <command>\n       defer clear\n")
		return
	end
end

-- port: cmd.c Cmd_Centerprint_f L132-166 @xonotic-v0.8.6 (SCR_CenterPrint not ported)
local function Cmd_Centerprint_f()
	if cmd.Cmd_Argc() >= 2 then
		notPorted("SCR_CenterPrint (cprint)")
	end
end

--[[
=============================================================================

						COMMAND BUFFER

=============================================================================
]]
local cmd_text = ""

-- port: cmd.c Cbuf_AddText L187-199 @xonotic-v0.8.6
function cmd.Cbuf_AddText(text: string)
	text = libc.cstr(text)
	if #cmd_text + #text >= CMDBUFSIZE then
		Con_Print("Cbuf_AddText: overflow\n")
	else
		cmd_text ..= text
	end
end

-- port: cmd.c Cbuf_InsertText L211-226 @xonotic-v0.8.6
function cmd.Cbuf_InsertText(text: string)
	text = libc.cstr(text)
	if #cmd_text + #text >= CMDBUFSIZE then
		Con_Print("Cbuf_InsertText: overflow\n")
	else
		cmd_text = text .. cmd_text
	end
end

local oldrealtime = 0
-- port: cmd.c Cbuf_Execute_Deferred L233-268 @xonotic-v0.8.6
local function Cbuf_Execute_Deferred()
	local realtime = cmd.realtime
	if realtime - oldrealtime < 0 or realtime - oldrealtime > 1800 then
		oldrealtime = realtime
	end
	local eat = realtime - oldrealtime
	if eat < (1.0 / 120.0) then
		return
	end
	oldrealtime = realtime
	local i = 1
	while i <= #cmd_deferred_list do
		local d = cmd_deferred_list[i]
		d.delay -= eat
		if d.delay <= 0 then
			cmd.Cbuf_AddText(d.value)
			cmd.Cbuf_AddText(";\n")
			table.remove(cmd_deferred_list, i)
			continue
		end
		i += 1
	end
end

local Cmd_PreprocessString: (string, number, Alias?) -> string?

-- port: cmd.c Cbuf_Execute L276-375 @xonotic-v0.8.6
function cmd.Cbuf_Execute()
	-- LordHavoc: making sure the tokenizebuffer doesn't get filled up by repeated crashes
	cmd_tokenizebufferpos = 0
	while #cmd_text > 0 do
		-- find a \n or ; line break
		local text = cmd_text
		local cursize = #text
		local quotes = false
		local comment: number? = nil -- 0-based offset of the comment start
		local i = 0 -- 0-based like C
		while i < cursize do
			local c = at(text, i + 1)
			if not comment then
				if c == 34 then
					quotes = not quotes
				end
				if quotes then
					-- make sure i doesn't get > cursize which causes a negative size in memmove
					if i < cursize - 1 and (c == 92 and (at(text, i + 2) == 34 or at(text, i + 2) == 92)) then
						i += 1
					end
				else
					if c == 47 and at(text, i + 2) == 47 and (i == 0 or ISWHITESPACE(at(text, i))) then
						comment = i
					end
					if c == 59 then
						break -- don't break if inside a quoted string or comment
					end
				end
			end
			c = at(text, i + 1)
			if c == 13 or c == 10 then
				break
			end
			i += 1
		end
		local line: string
		-- better than CRASHING on overlong input lines that may SOMEHOW enter the buffer
		if i >= MAX_INPUTLINE then
			Con_Printf("Warning: console input buffer had an overlong line. Ignored.\n")
			line = ""
		else
			line = libc.cstr(string.sub(text, 1, if comment then comment else i))
		end
		-- delete the text from the command buffer and move remaining commands down
		if i == cursize then
			cmd_text = ""
		else
			cmd_text = string.sub(text, i + 2)
		end
		-- execute the command line
		local f = 1
		while at(line, f) ~= 0 and ISWHITESPACE(at(line, f)) do
			f += 1
		end
		local function startsWord(w: string): boolean
			return string.sub(line, f, f + #w - 1) == w and ISWHITESPACE(at(line, f + #w))
		end
		if not startsWord("alias") and not startsWord("bind") and not startsWord("in_bind") then
			local preprocessed = Cmd_PreprocessString(line, MAX_INPUTLINE, nil)
			if preprocessed then
				cmd.Cmd_ExecuteString(preprocessed, cmd.src_command, false)
			end
		else
			cmd.Cmd_ExecuteString(line, cmd.src_command, false)
		end
		if cmd_wait then
			-- skip out while text still remains in buffer, leaving it for next frame
			cmd_wait = false
			break
		end
	end
end

-- port: cmd.c Cbuf_Frame L377-386 @xonotic-v0.8.6
function cmd.Cbuf_Frame()
	Cbuf_Execute_Deferred()
	if #cmd_text > 0 then
		cmd.Cbuf_Execute()
	end
end

--[[
==============================================================================

						SCRIPT COMMANDS

==============================================================================
]]

-- port: cmd.c Cmd_StuffCmds_f L407-458 @xonotic-v0.8.6
local function Cmd_StuffCmds_f()
	if cmd.Cmd_Argc() ~= 1 then
		Con_Print("stuffcmds : execute command line parameters\n")
		return
	end
	-- no reason to run the commandline arguments twice
	if cmd.host_stuffcmdsrun then
		return
	end
	cmd.host_stuffcmdsrun = true
	local argv = cmd.com_argv
	local build = {}
	local l = 0
	local maxb = MAX_INPUTLINE
	local function isdigitb(b: number): boolean
		return b >= 48 and b <= 57
	end
	local i = 1
	while i <= #argv do
		local a = argv[i]
		if string.byte(a, 1) == 43 and not isdigitb(at(a, 2)) and l + #a - 1 <= maxb - 1 then
			for j = 2, #a do
				table.insert(build, string.sub(a, j, j))
			end
			l += #a - 1
			i += 1
			while i <= #argv do
				local b = argv[i]
				local b1 = string.byte(b, 1)
				if (b1 == 43 or b1 == 45) and not isdigitb(at(b, 2)) then
					break
				end
				if l + #b + 4 > maxb - 1 then
					break
				end
				local q = string.find(b, " ", 1, true) ~= nil
				table.insert(build, if q then ' "' .. b .. '"' else " " .. b)
				l += #b + 1 + (if q then 2 else 0)
				i += 1
			end
			table.insert(build, "\n")
			l += 1
			i -= 1
		end
		i += 1
	end
	cmd.Cbuf_InsertText(table.concat(build))
end

local GAMEPLAYFIX_DEFAULT = "\n"
	.. "sv_gameplayfix_blowupfallenzombies 1\n"
	.. "sv_gameplayfix_findradiusdistancetobox 1\n"
	.. "sv_gameplayfix_grenadebouncedownslopes 1\n"
	.. "sv_gameplayfix_slidemoveprojectiles 1\n"
	.. "sv_gameplayfix_upwardvelocityclearsongroundflag 1\n"
	.. "sv_gameplayfix_setmodelrealbox 1\n"
	.. "sv_gameplayfix_droptofloorstartsolid 1\n"
	.. "sv_gameplayfix_droptofloorstartsolid_nudgetocorrect 1\n"
	.. "sv_gameplayfix_noairborncorpse 1\n"
	.. "sv_gameplayfix_noairborncorpse_allowsuspendeditems 1\n"
	.. "sv_gameplayfix_easierwaterjump 1\n"
	.. "sv_gameplayfix_delayprojectiles 1\n"
	.. "sv_gameplayfix_multiplethinksperframe 1\n"
	.. "sv_gameplayfix_fixedcheckwatertransition 1\n"
	.. "sv_gameplayfix_q1bsptracelinereportstexture 1\n"
	.. "sv_gameplayfix_swiminbmodels 1\n"
	.. "sv_gameplayfix_downtracesupportsongroundflag 1\n"
	.. "sys_ticrate 0.01388889\n"

-- port: cmd.c Cmd_Exec L460-699 @xonotic-v0.8.6 (only the `default:` gamemode branch, which is
-- GAME_XONOTIC's; the Quake/Nehahra/Hipnotic/Rogue/Tenebrae/Nexuiz/SteelStorm branches are other games)
local function Cmd_Exec(filename: string)
	local isdefaultcfg = filename == "default.cfg" or (#filename >= 12 and string.sub(filename, -12) == "/default.cfg")
	if filename == "config.cfg" then
		filename = CONFIGFILENAME
		if COM_CheckParm("-noconfig") ~= 0 then
			return -- don't execute config.cfg
		end
	end
	local f = fs.FS_LoadFile(filename, false)
	if not f then
		Con_Printf("couldn't exec %s\n", filename)
		return
	end
	Con_Printf("execing %s\n", filename)
	-- if executing default.cfg for the first time, lock the cvar defaults
	if isdefaultcfg then
		cmd.Cbuf_InsertText("\ncvar_lockdefaults\n")
	end
	-- insert newline after the text to make sure the last line is terminated
	cmd.Cbuf_InsertText("\n")
	cmd.Cbuf_InsertText(f)
	if isdefaultcfg then
		if cmd.gamemode ~= "GAME_XONOTIC" then
			notPorted("Cmd_Exec default.cfg prelude for " .. cmd.gamemode)
		end
		cmd.Cbuf_InsertText(GAMEPLAYFIX_DEFAULT)
	end
end

-- port: cmd.c Cmd_Exec_f L706-728 @xonotic-v0.8.6
local function Cmd_Exec_f()
	if cmd.Cmd_Argc() ~= 2 then
		Con_Print("exec <filename> : execute a script file\n")
		return
	end
	local s = fs.FS_Search(cmd.Cmd_Argv(1), true, true)
	if not s or #s == 0 then
		Con_Printf("couldn't exec %s\n", cmd.Cmd_Argv(1))
		return
	end
	for _, name in s :: { string } do
		Cmd_Exec(name)
	end
end

-- port: cmd.c Cmd_Echo_f L738-745 @xonotic-v0.8.6
local function Cmd_Echo_f()
	for i = 1, cmd.Cmd_Argc() - 1 do
		Con_Printf("%s ", cmd.Cmd_Argv(i))
	end
	Con_Print("\n")
end

-- port: cmd.c Cmd_Toggle_f L756-825 @xonotic-v0.8.6
local function Cmd_Toggle_f()
	local nNumArgs = cmd.Cmd_Argc()
	if nNumArgs == 1 then
		Con_Print(
			"Toggle Console Variable - Usage\n  toggle <variable> - toggles between 0 and 1\n  toggle <variable> <value> - toggles between 0 and <value>\n  toggle <variable> [string 1] [string 2]...[string n] - cycles through all strings\n"
		)
		return
	end
	local cv = cvar.Cvar_FindVar(cmd.Cmd_Argv(1))
	if cv ~= nil then
		local c = cv :: cvar.Cvar
		if nNumArgs == 2 then
			if c.integer ~= 0 then
				cvar.Cvar_SetValueQuick(c, 0)
			else
				cvar.Cvar_SetValueQuick(c, 1)
			end
		elseif nNumArgs == 3 then
			-- selene: allow(if_same_then_else)
			if c.integer == libc.atoi(cmd.Cmd_Argv(2)) then
				cvar.Cvar_SetValueQuick(c, 0)
			elseif c.integer == 0 then
				cvar.Cvar_SetQuick(c, cmd.Cmd_Argv(2))
			else
				cvar.Cvar_SetValueQuick(c, 0)
			end
		else
			local bFound = false
			local nCnt = 2
			while nCnt < nNumArgs do
				if c.string.str == cmd.Cmd_Argv(nCnt) then
					if nCnt + 1 == nNumArgs then
						cvar.Cvar_SetQuick(c, cmd.Cmd_Argv(2))
					else
						cvar.Cvar_SetQuick(c, cmd.Cmd_Argv(nCnt + 1))
					end
					nCnt = nNumArgs
					bFound = true
				end
				nCnt += 1
			end
			if not bFound then
				cvar.Cvar_SetQuick(c, cmd.Cmd_Argv(2))
			end
		end
	else
		Con_Printf("ERROR : CVar '%s' not found\n", cmd.Cmd_Argv(1))
	end
end

local aliasIndex: { [string]: Alias } = {} -- lowercase name -> first alias in list order

local function rebuildAliasIndex()
	table.clear(aliasIndex)
	for _, a in cmd_alias do
		local k = libc.lowerascii(a.name)
		if not aliasIndex[k] then
			aliasIndex[k] = a
		end
	end
end

-- port: cmd.c Cmd_Alias_f L834-901 @xonotic-v0.8.6
local function Cmd_Alias_f()
	if cmd.Cmd_Argc() == 1 then
		Con_Print("Current alias commands:\n")
		for _, a in cmd_alias do
			Con_Printf("%s : %s", a.name, a.value)
		end
		return
	end
	local s = cmd.Cmd_Argv(1)
	if #s >= MAX_ALIAS_NAME then
		Con_Print("Alias name is too long\n")
		return
	end
	-- if the alias already exists, reuse it
	local a: Alias? = nil
	for _, x in cmd_alias do
		if x.name == s then
			a = x
			break
		end
	end
	if not a then
		local na: Alias = { name = s, value = "", initstate = false }
		-- insert it at the right alphanumeric position
		local pos = #cmd_alias + 1
		for k, cur in cmd_alias do
			if not (libc.strcmp(cur.name, na.name) < 0) then
				pos = k
				break
			end
		end
		table.insert(cmd_alias, pos, na)
		rebuildAliasIndex()
		a = na
	end
	-- copy the rest of the command line (strlcat into char cmd[MAX_INPUTLINE])
	local c = cmd.Cmd_Argc()
	local parts = {}
	for i = 2, c - 1 do
		if i ~= 2 then
			table.insert(parts, " ")
		end
		table.insert(parts, cmd.Cmd_Argv(i))
	end
	table.insert(parts, "\n")
	local value = table.concat(parts)
	if #value > MAX_INPUTLINE - 1 then
		value = string.sub(value, 1, MAX_INPUTLINE - 1)
	end
	if #value + 1 >= 2 then
		value = string.sub(value, 1, #value - 1) .. "\n" -- make sure a newline is appended even if too long
	end
	(a :: Alias).value = value
end

-- port: cmd.c Cmd_UnAlias_f L910-944 @xonotic-v0.8.6
local function Cmd_UnAlias_f()
	if cmd.Cmd_Argc() == 1 then
		Con_Print("unalias: Usage: unalias alias1 [alias2 ...]\n")
		return
	end
	for i = 1, cmd.Cmd_Argc() - 1 do
		local s = cmd.Cmd_Argv(i)
		local found = false
		local k = 1
		while k <= #cmd_alias do
			local a = cmd_alias[k]
			if a.name == s then
				if a.initstate then -- we can not remove init aliases
					k += 1
					continue
				end
				table.remove(cmd_alias, k)
				rebuildAliasIndex()
				found = true
				break
			end
			k += 1
		end
		if not found then
			Con_Printf("unalias: %s alias not found\n", s)
		end
	end
end

--[[
=============================================================================

					COMMAND EXECUTION

=============================================================================
]]

local cmd_argc = 0
local cmd_argv: { string } = {} -- [0..argc-1] stored at index +1
local cmd_args: string? = nil
cmd.cmd_source = cmd.src_command

-- port: cmd.c Cmd_GetDirectCvarValue L974-1039 @xonotic-v0.8.6
local function Cmd_GetDirectCvarValue(varname: string?, alias: Alias?): (string?, boolean)
	local is_multiple = false
	if not varname or varname == "" then
		return nil, is_multiple
	end
	local vn = varname :: string
	if alias then
		if vn == "*" then
			return cmd.Cmd_Args() or "", true
		elseif vn == "#" then
			return string.format("%d", cmd.Cmd_Argc()), false
		elseif string.sub(vn, -1) == "-" then
			local argno, endp = libc.strtol10(vn)
			if endp == #vn then
				-- whole string is a number, apart from the -
				local args = cmd.Cmd_Args()
				local p: number? = if args then 1 else nil
				local s = args or ""
				while argno > 1 do
					local ok
					ok, p = common.COM_ParseToken_Console(s, p)
					if not ok then
						break
					end
					argno -= 1
				end
				if p then
					local q = p :: number
					-- kill pre-argument whitespace
					while at(s, q) ~= 0 and ISWHITESPACE(at(s, q)) do
						q += 1
					end
					return libc.cstr(string.sub(s, q)), true
				end
			end
		else
			local argno, endp = libc.strtol10(vn)
			if endp == #vn + 1 then
				-- whole string is a number
				if argno >= 0 and argno < cmd.Cmd_Argc() then
					return cmd.Cmd_Argv(argno), false
				end
			end
		end
	end
	local c = cvar.Cvar_FindVar(vn)
	if c and bit32.band(c.flags, cvar.CVAR_PRIVATE) == 0 then
		return c.string.str, false
	end
	return nil, false
end

-- port: cmd.c Cmd_QuoteString L1041-1098 @xonotic-v0.8.6 -> (ok, out)
function cmd.Cmd_QuoteString(outlen: number, s: string, quoteset: string, putquotes: boolean): (boolean, string)
	local quote_quot = string.find(quoteset, '"', 1, true) ~= nil
	local quote_backslash = string.find(quoteset, "\\", 1, true) ~= nil
	local quote_dollar = string.find(quoteset, "$", 1, true) ~= nil
	local out = {}
	if putquotes then
		if outlen <= 2 then
			return false, ""
		end
		table.insert(out, '"')
		outlen -= 2
	end
	local ok = true
	s = libc.cstr(s)
	for k = 1, #s do
		local ch = string.sub(s, k, k)
		if ch == '"' and quote_quot then
			if outlen <= 2 then
				ok = false
				break
			end
			table.insert(out, '\\"')
			outlen -= 2
		elseif ch == "\\" and quote_backslash then
			if outlen <= 2 then
				ok = false
				break
			end
			table.insert(out, "\\\\")
			outlen -= 2
		elseif ch == "$" and quote_dollar then
			if outlen <= 2 then
				ok = false
				break
			end
			table.insert(out, "$$")
			outlen -= 2
		else
			if outlen <= 1 then
				ok = false
				break
			end
			table.insert(out, ch)
			outlen -= 1
		end
	end
	if putquotes then
		table.insert(out, '"')
	end
	return ok, table.concat(out)
end

-- port: cmd.c Cmd_GetCvarValue L1100-1209 @xonotic-v0.8.6
-- `var` is the text from the byte after '$' to the end of the line; varlen bytes of it are the name.
local function Cmd_GetCvarValue(var: string, varlen: number, alias: Alias?): string?
	if varlen >= MAX_INPUTLINE then
		varlen = MAX_INPUTLINE - 1
	end
	local varname = libc.cstr(string.sub(var, 1, varlen))
	local varfunc: string? = nil
	local sp = string.find(varname, " ", 1, true)
	if sp then
		varfunc = string.sub(varname, sp + 1)
		varname = string.sub(varname, 1, sp - 1)
	end
	if at(var, 1) == 0 then
		-- empty cvar name?
		if alias then
			Con_Printf("Warning: Could not expand $ in alias %s\n", alias.name)
		else
			Con_Printf("Warning: Could not expand $\n")
		end
		return "$"
	end
	local required, optional = false, false
	if varfunc then
		local vf = varfunc :: string
		-- ? means optional
		if string.find(vf, "?", 1, true) then
			optional = true
			vf = string.gsub(vf, "%?", "")
		end
		-- ! means required
		if string.find(vf, "!", 1, true) then
			required = true
			vf = string.gsub(vf, "!", "")
		end
		-- kill spaces
		vf = string.gsub(vf, " ", "")
		-- if no function is left, NULL it
		varfunc = if vf == "" then nil else vf
	end
	local varstr: string?
	if string.sub(varname, 1, 1) == "$" then
		local inner = Cmd_GetDirectCvarValue(string.sub(varname, 2), alias)
		varstr = Cmd_GetDirectCvarValue(inner, alias)
	else
		local is_multiple
		-- Exception: $* and $n- don't use the quoted form by default
		varstr, is_multiple = Cmd_GetDirectCvarValue(varname, alias)
		if is_multiple and not varfunc then
			varfunc = "asis"
		end
	end
	if not varstr then
		if required then
			if alias then
				Con_Printf("Error: Could not expand $%s in alias %s\n", varname, alias.name)
			else
				Con_Printf("Error: Could not expand $%s\n", varname)
			end
			return nil
		elseif optional then
			return ""
		else
			if alias then
				Con_Printf("Warning: Could not expand $%s in alias %s\n", varname, alias.name)
			else
				Con_Printf("Warning: Could not expand $%s\n", varname)
			end
			return libc.snprintf(MAX_INPUTLINE, "$%s", varname)
		end
	end
	if not varfunc or varfunc == "q" then -- note: quoted form is default, use "asis" to override!
		local _, q = cmd.Cmd_QuoteString(MAX_INPUTLINE, varstr :: string, '"\\', false)
		return q
	elseif varfunc == "asis" then
		return varstr
	else
		Con_Printf("Unknown variable function %s\n", varfunc :: string)
	end
	return varstr
end

local VARCHARS = "#*0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_-"
local varcharset: { [number]: boolean } = {}
for k = 1, #VARCHARS do
	varcharset[string.byte(VARCHARS, k)] = true
end

-- port: cmd.c Cmd_PreprocessString L1216-1336 @xonotic-v0.8.6
-- Returns the output text, or nil where C returns false. maxoutlen as in C (buffer size incl. NUL).
Cmd_PreprocessString = function(intext: string, maxoutlen: number, alias: Alias?): string?
	if maxoutlen == 0 then
		return nil
	end
	maxoutlen -= 1 -- because of \0
	intext = libc.cstr(intext)
	local out = buffer.create(maxoutlen + 1)
	local outlen = 0
	local i = 1
	while at(intext, i) ~= 0 and outlen < maxoutlen do
		if at(intext, i) == 36 then -- '$'
			i += 1
			local val: string?
			local eat: number
			if at(intext, i) == 36 then
				val = "$"
				eat = 1
			elseif at(intext, i) == 123 then -- '{'
				-- varlen = strcspn(in + 1, "}")
				local j = i + 1
				while at(intext, j) ~= 0 and at(intext, j) ~= 125 do
					j += 1
				end
				local varlen = j - (i + 1)
				if at(intext, i + varlen + 1) == 125 then
					val = Cmd_GetCvarValue(string.sub(intext, i + 1), varlen, alias)
					if not val then
						return nil
					end
					eat = varlen + 2
				else
					-- ran out of data?
					val = nil
					eat = varlen + 1
				end
			else
				local j = i
				while varcharset[at(intext, j)] do
					j += 1
				end
				local varlen = j - i
				val = Cmd_GetCvarValue(string.sub(intext, i), varlen, alias)
				if not val then
					return nil
				end
				eat = varlen
			end
			if val then
				-- insert the cvar value
				local v = val :: string
				local k = 1
				while k <= #v and string.byte(v, k) ~= 0 and outlen < maxoutlen do
					buffer.writeu8(out, outlen, string.byte(v, k))
					outlen += 1
					k += 1
				end
				i += eat
			else
				-- copy the unexpanded text
				buffer.writeu8(out, outlen, 36)
				outlen += 1
				while eat > 0 and outlen < maxoutlen do
					buffer.writeu8(out, outlen, at(intext, i))
					outlen += 1
					i += 1
					eat -= 1
				end
			end
		else
			buffer.writeu8(out, outlen, at(intext, i))
			outlen += 1
			i += 1
		end
	end
	return libc.cstr(buffer.readstring(out, 0, outlen))
end

-- port: cmd.c Cmd_ExecuteAlias L1345-1360 @xonotic-v0.8.6
local function Cmd_ExecuteAlias(alias: Alias)
	local buf = Cmd_PreprocessString(alias.value, MAX_INPUTLINE - 2, alias)
	if not buf then
		return
	end
	-- insert at start of command buffer, so that aliases execute in order
	-- Note: Cbuf_PreprocessString will be called on this string AGAIN! So no second expansion: quote $.
	local _, buffer2 = cmd.Cmd_QuoteString(MAX_INPUTLINE, buf :: string, "$", false)
	cmd.Cbuf_InsertText(buffer2)
end

-- port: cmd.c Cmd_List_f L1371-1410 @xonotic-v0.8.6
local function Cmd_List_f()
	local partial: string? = nil
	local len = 0
	local ispattern = false
	if cmd.Cmd_Argc() > 1 then
		partial = cmd.Cmd_Argv(1)
		len = #(partial :: string)
		ispattern = string.find(partial :: string, "*", 1, true) ~= nil
			or string.find(partial :: string, "?", 1, true) ~= nil
	end
	local count = 0
	for _, c in cmd_functions do
		if len > 0 then
			if ispattern then
				if not filematch.matchpattern_with_separator(c.name, partial :: string, false, "", false) then
					continue
				end
			elseif string.sub(c.name, 1, len) ~= partial then
				continue
			end
		end
		Con_Printf("%s : %s\n", c.name, c.description)
		count += 1
	end
	if len > 0 then
		if ispattern then
			Con_Printf('%i Command%s matching "%s"\n\n', count, if count > 1 then "s" else "", partial :: string)
		else
			Con_Printf('%i Command%s beginning with "%s"\n\n', count, if count > 1 then "s" else "", partial :: string)
		end
	else
		Con_Printf("%i Command%s\n\n", count, if count > 1 then "s" else "")
	end
end

local function Cmd_Apropos_f()
	notPorted("apropos (cmd.c Cmd_Apropos_f, console UI)")
end

local function Cmd_ForwardToServer()
	notPorted("Cmd_ForwardToServer (cmd.c, client)")
end

-- port: cmd.c Cmd_Init L1468-1478 @xonotic-v0.8.6
function cmd.Cmd_Init()
	cmd_text = ""
end

local function argcArgv(): (number, (number) -> string)
	return cmd.Cmd_Argc(), cmd.Cmd_Argv
end

-- port: cmd.c Cmd_Init_Commands L1480-1516 @xonotic-v0.8.6
function cmd.Cmd_Init_Commands()
	local AddCommand = cmd.Cmd_AddCommand
	AddCommand("stuffcmds", Cmd_StuffCmds_f, "execute commandline parameters (must be present in quake.rc script)")
	AddCommand("exec", Cmd_Exec_f, "execute a script file")
	AddCommand("echo", Cmd_Echo_f, "print a message to the console (useful in scripts)")
	AddCommand(
		"alias",
		Cmd_Alias_f,
		"create a script function (parameters are passed in as $X (being X a number), $* for all parameters, $X- for all parameters starting from $X). Without arguments show the list of all alias"
	)
	AddCommand("unalias", Cmd_UnAlias_f, "remove an alias")
	AddCommand("cmd", Cmd_ForwardToServer, "send a console commandline to the server (used by some mods)")
	AddCommand("wait", Cmd_Wait_f, "make script execution wait for next rendered frame")
	AddCommand("set", function()
		cvar.Cvar_Set_f(argcArgv())
	end, "create or change the value of a console variable")
	AddCommand("seta", function()
		cvar.Cvar_SetA_f(argcArgv())
	end, "create or change the value of a console variable that will be saved to config.cfg")
	AddCommand("unset", function()
		cvar.Cvar_Del_f(argcArgv())
	end, "delete a cvar (does not work for static ones like _cl_name, or read-only ones)")
	AddCommand(
		"cmdlist",
		Cmd_List_f,
		"lists all console commands beginning with the specified prefix or matching the specified wildcard pattern"
	)
	AddCommand("cvarlist", function()
		local argc, argv = argcArgv()
		cvar.Cvar_List_f(argc, argv, filematch.matchpattern_with_separator)
	end, "lists all console variables beginning with the specified prefix or matching the specified wildcard pattern")
	AddCommand(
		"apropos",
		Cmd_Apropos_f,
		"lists all console variables/commands/aliases containing the specified string in the name or description"
	)
	AddCommand(
		"cvar_lockdefaults",
		cvar.Cvar_LockDefaults_f,
		"stores the current values of all cvars into their default values, only used once during startup after parsing default.cfg"
	)
	AddCommand(
		"cvar_resettodefaults_all",
		cvar.Cvar_ResetToDefaults_All_f,
		"sets all cvars to their locked default values"
	)
	AddCommand(
		"cvar_resettodefaults_nosaveonly",
		cvar.Cvar_ResetToDefaults_NoSaveOnly_f,
		"sets all non-saved cvars to their locked default values (variables that will not be saved to config.cfg)"
	)
	AddCommand(
		"cvar_resettodefaults_saveonly",
		cvar.Cvar_ResetToDefaults_SaveOnly_f,
		"sets all saved cvars to their locked default values (variables that will be saved to config.cfg)"
	)
	AddCommand("cprint", Cmd_Centerprint_f, "print something at the screen center")
	AddCommand("defer", Cmd_Defer_f, "execute a command in the future")
	AddCommand("toggle", Cmd_Toggle_f, "toggles a console variable's values (use for more info)")
end

-- port: cmd.c Cmd_Argc L1541-1544 @xonotic-v0.8.6
function cmd.Cmd_Argc(): number
	return cmd_argc
end

-- port: cmd.c Cmd_Argv L1551-1556 @xonotic-v0.8.6
function cmd.Cmd_Argv(arg: number): string
	if arg >= cmd_argc then
		return ""
	end
	return cmd_argv[arg + 1]
end

-- port: cmd.c Cmd_Args L1563-1566 @xonotic-v0.8.6
function cmd.Cmd_Args(): string?
	return cmd_args
end

-- port: cmd.c Cmd_TokenizeString L1577-1626 @xonotic-v0.8.6
local function Cmd_TokenizeString(text: string)
	text = libc.cstr(text)
	cmd_argc = 0
	cmd_args = nil
	local p: number? = 1
	while true do
		local q = p :: number
		-- skip whitespace up to a /n
		while at(text, q) ~= 0 and ISWHITESPACE(at(text, q)) and at(text, q) ~= 13 and at(text, q) ~= 10 do
			q += 1
		end
		if at(text, q) == 10 or at(text, q) == 13 then
			-- a newline separates commands in the buffer
			break
		end
		if at(text, q) == 0 then
			return
		end
		if cmd_argc == 1 then
			cmd_args = string.sub(text, q)
		end
		local ok
		ok, p = common.COM_ParseToken_Console(text, q)
		if not ok then
			return
		end
		if cmd_argc < MAX_ARGS then
			local l = #common.com_token + 1
			if cmd_tokenizebufferpos + l > CMD_TOKENIZELENGTH then
				Con_Printf(
					"Cmd_TokenizeString: ran out of %i character buffer space for command arguements\n",
					CMD_TOKENIZELENGTH
				)
				break
			end
			cmd_argv[cmd_argc + 1] = common.com_token
			cmd_tokenizebufferpos += l
			cmd_argc += 1
		end
	end
end

local cmdIndex: { [string]: Command } = {} -- lowercase name -> first command in list order

-- port: cmd.c Cmd_AddCommand_WithClientCommand L1634-1682 @xonotic-v0.8.6
function cmd.Cmd_AddCommand_WithClientCommand(
	cmd_name: string,
	consolefunction: (() -> ())?,
	clientfunction: (() -> ())?,
	description: string
)
	-- fail if the command is a variable name
	if cvar.Cvar_FindVar(cmd_name) then
		Con_Printf("Cmd_AddCommand: %s already defined as a var\n", cmd_name)
		return
	end
	-- fail if the command already exists
	for _, c in cmd_functions do
		if c.name == cmd_name then
			if consolefunction or clientfunction then
				Con_Printf("Cmd_AddCommand: %s already defined\n", cmd_name)
				return
			else --[515]: csqc
				c.csqcfunc = true
				return
			end
		end
	end
	local c: Command = {
		name = cmd_name,
		consolefunction = consolefunction,
		clientfunction = clientfunction,
		description = description,
		csqcfunc = consolefunction == nil and clientfunction == nil,
		initstate = false,
	}
	-- insert it at the right alphanumeric position
	local pos = #cmd_functions + 1
	for k, cur in cmd_functions do
		if not (libc.strcmp(cur.name, c.name) < 0) then
			pos = k
			break
		end
	end
	table.insert(cmd_functions, pos, c)
	table.clear(cmdIndex)
	for _, x in cmd_functions do
		local k = libc.lowerascii(x.name)
		if not cmdIndex[k] then
			cmdIndex[k] = x
		end
	end
end

-- port: cmd.c Cmd_AddCommand L1684-1687 @xonotic-v0.8.6
function cmd.Cmd_AddCommand(cmd_name: string, fn: (() -> ())?, description: string)
	cmd.Cmd_AddCommand_WithClientCommand(cmd_name, fn, nil, description)
end

-- port: cmd.c Cmd_Exists L1694-1703 @xonotic-v0.8.6
function cmd.Cmd_Exists(cmd_name: string): boolean
	for _, c in cmd_functions do
		if c.name == cmd_name then
			return true
		end
	end
	return false
end
cvar.Cmd_Exists = cmd.Cmd_Exists

local server_mod: any = nil
-- port: cmd.c Cmd_ExecuteString L1909-1994 @xonotic-v0.8.6
function cmd.Cmd_ExecuteString(text: string, src: number, _lockmutex: boolean)
	local oldpos = cmd_tokenizebufferpos
	cmd.cmd_source = src
	local found = false
	Cmd_TokenizeString(text)
	repeat -- (goto done == break)
		-- execute the command line
		if cmd.Cmd_Argc() == 0 then
			break -- no tokens
		end
		-- check functions
		local c = cmdIndex[libc.lowerascii(cmd_argv[1])]
		local handled = false
		if c then
			if c.csqcfunc then
				notPorted("CL_VM_ConsoleCommand (csqc console commands)")
			end
			if src == cmd.src_command then
				if c.consolefunction then
					(c.consolefunction :: () -> ())()
				elseif c.clientfunction then
					if cmd.cls_state_connected then
						Cmd_ForwardToServer()
					else
						Con_Printf('Can not send command "%s", not connected.\n', cmd.Cmd_Argv(0))
					end
				else
					Con_Printf('Command "%s" can not be executed\n', cmd.Cmd_Argv(0))
				end
				found = true
			elseif src == cmd.src_client then
				if c.clientfunction then
					(c.clientfunction :: () -> ())()
					handled = true
				end
			end
		end
		if handled then
			break
		end
		-- command_found:
		-- if it's a client command and no command was found, say so.
		if cmd.cmd_source == cmd.src_client then
			-- (host_client: engine/server.luau, which requires this module's users: required on first use and kept)
			if not server_mod then
				server_mod = require("./server")
			end
			Con_Printf('player "%s" tried to %s\n', server_mod.host_client.name.str, text)
			break
		end
		-- check alias
		local a = aliasIndex[libc.lowerascii(cmd_argv[1])]
		if a then
			Cmd_ExecuteAlias(a)
			break
		end
		if found then -- if the command was hooked and found, all is good
			break
		end
		-- check cvars
		if not cvar.Cvar_Command(cmd.Cmd_Argc(), cmd.Cmd_Argv) and cmd.host_framecount > 0 then
			Con_Printf('Unknown command "%s"\n', cmd.Cmd_Argv(0))
		end
	until true
	-- done:
	cmd_tokenizebufferpos = oldpos
end

-- port: cmd.c Cmd_CheckParm L2161-2176 @xonotic-v0.8.6
function cmd.Cmd_CheckParm(parm: string?): number
	if not parm then
		Con_Printf("Cmd_CheckParm: NULL")
		return 0
	end
	for i = 1, cmd.Cmd_Argc() - 1 do
		if libc.strcasecmp(parm :: string, cmd.Cmd_Argv(i)) == 0 then
			return i
		end
	end
	return 0
end

-- port: cmd.c Cmd_SaveInitState L2180-2192 @xonotic-v0.8.6
function cmd.Cmd_SaveInitState()
	for _, f in cmd_functions do
		f.initstate = true
	end
	for _, a in cmd_alias do
		a.initstate = true
		a.initialvalue = a.value
	end
	cvar.Cvar_SaveInitState()
end

-- port: cmd.c Cmd_RestoreInitState L2194-2235 @xonotic-v0.8.6
function cmd.Cmd_RestoreInitState()
	local k = 1
	while k <= #cmd_functions do
		local f = cmd_functions[k]
		if f.initstate then
			k += 1
		else
			Con_DPrintf("Cmd_RestoreInitState: Destroying command %s\n", f.name)
			table.remove(cmd_functions, k)
		end
	end
	table.clear(cmdIndex)
	for _, x in cmd_functions do
		local key = libc.lowerascii(x.name)
		if not cmdIndex[key] then
			cmdIndex[key] = x
		end
	end
	k = 1
	while k <= #cmd_alias do
		local a = cmd_alias[k]
		if a.initstate then
			if a.value ~= (a.initialvalue or "") then
				Con_DPrintf("Cmd_RestoreInitState: Restoring alias %s\n", a.name)
				a.value = a.initialvalue or ""
			end
			k += 1
		else
			Con_DPrintf("Cmd_RestoreInitState: Destroying alias %s\n", a.name)
			table.remove(cmd_alias, k)
		end
	end
	rebuildAliasIndex()
	cvar.Cvar_RestoreInitState()
end

-- Introspection for tests / the cvar loader
function cmd.aliases(): { Alias }
	return cmd_alias
end
function cmd.commands(): { Command }
	return cmd_functions
end
function cmd.pending(): string
	return cmd_text
end

-- Test support: a fresh command system.
function cmd.reset()
	cmd_text = ""
	table.clear(cmd_alias)
	table.clear(cmd_functions)
	table.clear(cmdIndex)
	table.clear(aliasIndex)
	table.clear(cmd_deferred_list)
	cmd_tokenizebufferpos = 0
	cmd_argc = 0
	cmd.host_stuffcmdsrun = false
	cmd.host_framecount = 0
end

return cmd
