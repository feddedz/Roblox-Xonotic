--!strict
--[[
Copyright (C) 1996-1997 Id Software, Inc. (DarkPlaces common.c; GPLv2 or later, see engine/prvm_edict.luau)
]]
--[[
	Port of common.c @xonotic-v0.8.6. PARTIAL: COM_ParseToken_Console (used by cmd.c).
	A C `const char *` into a string is (s, i): byte index i (1-based); i > #s reads as the NUL terminator.
	Also InfoString_GetValue / InfoString_SetValue, CRC_Block / CRC_Block_CaseInsensitive (CRC-16/CCITT, crctable generated from its polynomial 0x1021).
	Also the sizebuf writers (SZ_*, MSG_Write*) and readers (MSG_InitReadBuffer, MSG_BeginReading, MSG_Read*).
	NOT YET PORTED: the rest of common.c (other tokenizers, COM_CheckParm, ...).
]]
local common = {}

local MAX_INPUTLINE = 16384 -- quakedef.h

-- com_token (char[MAX_INPUTLINE])
common.com_token = ""

local function at(s: string, i: number): number
	return string.byte(s, i) or 0
end

-- ISWHITESPACE(ch): !(ch) || ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n'   (quakedef.h L569)
local function ISWHITESPACE(c: number): boolean
	return c == 0 or c == 32 or c == 9 or c == 13 or c == 10
end
common.ISWHITESPACE = ISWHITESPACE

-- port: common.c COM_ParseToken_Console L1341-1401 @xonotic-v0.8.6
-- Returns (ok, newpointer): newpointer nil == C *datapointer = NULL.
function common.COM_ParseToken_Console(s: string, data: number?): (boolean, number?)
	local len = 0
	local tok = buffer.create(MAX_INPUTLINE)
	common.com_token = ""
	if data == nil then
		return false, nil
	end
	local d = data :: number
	while true do -- skipwhite:
		while ISWHITESPACE(at(s, d)) do
			if at(s, d) == 0 then
				return false, nil -- end of file
			end
			d += 1
		end
		if at(s, d) == 47 and at(s, d + 1) == 47 then -- comment
			while at(s, d) ~= 0 and at(s, d) ~= 10 and at(s, d) ~= 13 do
				d += 1
			end
			continue -- goto skipwhite
		end
		break
	end
	if at(s, d) == 34 then -- quoted string
		d += 1
		while at(s, d) ~= 0 and at(s, d) ~= 34 do
			-- allow escaped " and \ case
			if at(s, d) == 92 and (at(s, d + 1) == 34 or at(s, d + 1) == 92) then
				d += 1
			end
			if len < MAX_INPUTLINE - 1 then
				buffer.writeu8(tok, len, at(s, d))
				len += 1
			end
			d += 1
		end
		if at(s, d) == 34 then
			d += 1
		end
	else -- regular word
		while not ISWHITESPACE(at(s, d)) do
			if len < MAX_INPUTLINE - 1 then
				buffer.writeu8(tok, len, at(s, d))
				len += 1
			end
			d += 1
		end
	end
	common.com_token = buffer.readstring(tok, 0, len)
	return true, d
end

-- data: common.c crctable L145-178 @xonotic-v0.8.6 (CRC-CCITT table, polynomial 0x1021)
local crctable = table.create(256, 0)
for i = 0, 255 do
	local c = bit32.lshift(i, 8)
	for _ = 1, 8 do
		c = if bit32.btest(c, 0x8000) then bit32.bxor(bit32.lshift(c, 1), 0x1021) else bit32.lshift(c, 1)
		c = bit32.band(c, 0xFFFF)
	end
	crctable[i + 1] = c
end
local CRC_INIT_VALUE, CRC_XOR_VALUE = 0xffff, 0x0000

-- port: common.c CRC_Block L181-187 @xonotic-v0.8.6
function common.CRC_Block(data: string): number
	local crc = CRC_INIT_VALUE
	for i = 1, #data do
		crc = bit32.band(
			bit32.bxor(bit32.lshift(crc, 8), crctable[bit32.bxor(bit32.rshift(crc, 8), string.byte(data, i)) + 1]),
			0xFFFF
		)
	end
	return bit32.bxor(crc, CRC_XOR_VALUE)
end

-- port: common.c CRC_Block_CaseInsensitive L189-195 @xonotic-v0.8.6 (tolower: C locale)
function common.CRC_Block_CaseInsensitive(data: string): number
	local console = require("./console")

	-- byte at 0-based position of a C string (NUL past the end)
	local function cb(buf: string, i: number): number
		return string.byte(buf, i + 1) or 0
	end
	local function keymatch(buf: string, pos: number, key: string): boolean
		-- !memcmp(buffer + pos, key, keylength)
		for k = 1, #key do
			if cb(buf, pos + k - 1) ~= string.byte(key, k) then
				return false
			end
		end
		return true
	end

	-- port: common.c InfoString_GetValue L2008-2056 @xonotic-v0.8.6 (returns the value or nil for NULL)
	function common.InfoString_GetValue(buffer: string, key: string?, valuelength: number): string?
		local k = key or ""
		local keylength = #k
		if valuelength < 1 then
			console.Con_Printf("InfoString_GetValue: no room in value\n")
			return nil
		end
		if string.find(k, "\\", 1, true) then
			console.Con_Printf(
				'InfoString_GetValue: key name "%s" contains \\ which is not possible in an infostring\n',
				k
			)
			return nil
		end
		if string.find(k, '"', 1, true) then
			console.Con_Printf(
				'InfoString_SetValue: key name "%s" contains " which is not allowed in an infostring\n',
				k
			)
			return nil
		end
		if k == "" then
			console.Con_Printf("InfoString_GetValue: can not look up a key with no name\n")
			return nil
		end
		local pos = 0
		while cb(buffer, pos) == 92 do
			if
				keymatch(buffer, pos + 1, k)
				and (cb(buffer, pos + 1 + keylength) == 0 or cb(buffer, pos + 1 + keylength) == 92)
			then
				pos += 1 + keylength -- Skip \key
				if cb(buffer, pos) == 92 then
					pos += 1 -- Skip \ before value.
				end
				local j = 0
				while cb(buffer, pos + j) ~= 0 and cb(buffer, pos + j) ~= 92 and j < valuelength - 1 do
					j += 1
				end
				return string.sub(buffer, pos + 1, pos + j)
			end
			if cb(buffer, pos) == 92 then
				pos += 1
			end
			pos += 1
			while cb(buffer, pos) ~= 0 and cb(buffer, pos) ~= 92 do
				pos += 1
			end
			if cb(buffer, pos) == 92 then
				pos += 1
			end
			pos += 1
			while cb(buffer, pos) ~= 0 and cb(buffer, pos) ~= 92 do
				pos += 1
			end
		end
		return nil -- the key was not found
	end

	-- port: common.c InfoString_SetValue L2058-2118 @xonotic-v0.8.6 (returns the new buffer contents)
	function common.InfoString_SetValue(buffer: string, bufferlength: number, key: string?, value: string?): string
		local k, v = key or "", value or ""
		local keylength = #k
		if string.find(k, "\\", 1, true) or string.find(v, "\\", 1, true) then
			console.Con_Printf(
				'InfoString_SetValue: "%s" "%s" contains \\ which is not possible to store in an infostring\n',
				k,
				v
			)
			return buffer
		end
		if string.find(k, '"', 1, true) or string.find(v, '"', 1, true) then
			console.Con_Printf(
				'InfoString_SetValue: "%s" "%s" contains " which is not allowed in an infostring\n',
				k,
				v
			)
			return buffer
		end
		if k == "" then
			console.Con_Printf("InfoString_SetValue: can not set a key with no name\n")
			return buffer
		end
		local pos = 0
		while cb(buffer, pos) == 92 do
			if
				keymatch(buffer, pos + 1, k)
				and (cb(buffer, pos + 1 + keylength) == 0 or cb(buffer, pos + 1 + keylength) == 92)
			then
				break
			end
			if cb(buffer, pos) == 92 then
				pos += 1
			end
			while cb(buffer, pos) ~= 0 and cb(buffer, pos) ~= 92 do
				pos += 1
			end
			if cb(buffer, pos) == 92 then
				pos += 1
			end
			while cb(buffer, pos) ~= 0 and cb(buffer, pos) ~= 92 do
				pos += 1
			end
		end
		-- if we found the key, find the end of it because we will be replacing it
		local pos2 = pos
		if cb(buffer, pos) == 92 then
			pos2 += 1 + keylength
			if cb(buffer, pos2) == 92 then
				pos2 += 1
			end
			while cb(buffer, pos2) ~= 0 and cb(buffer, pos2) ~= 92 do
				pos2 += 1
			end
		end
		local rest = string.sub(buffer, pos2 + 1)
		if bufferlength <= pos + 1 + #k + 1 + #v + #rest then
			console.Con_Printf('InfoString_SetValue: no room for "%s" "%s" in infostring\n', k, v)
			return buffer
		end
		local head = string.sub(buffer, 1, pos)
		if v ~= "" then
			local new = "\\" .. k .. "\\" .. v .. string.sub(rest, 1, 16383)
			return head .. string.sub(new, 1, bufferlength - pos - 1)
		end
		return head .. string.sub(rest, 1, bufferlength - pos - 1) -- just remove the key from the text
	end

	return common.CRC_Block((string.gsub(data, "%u", string.lower)))
end

local console = require("./console")

-- byte at 0-based position of a C string (NUL past the end)
local function cb(buf: string, i: number): number
	return string.byte(buf, i + 1) or 0
end
local function keymatch(buf: string, pos: number, key: string): boolean
	-- !memcmp(buffer + pos, key, keylength)
	for k = 1, #key do
		if cb(buf, pos + k - 1) ~= string.byte(key, k) then
			return false
		end
	end
	return true
end

-- port: common.c InfoString_GetValue L2008-2056 @xonotic-v0.8.6 (returns the value or nil for NULL)
function common.InfoString_GetValue(buffer: string, key: string?, valuelength: number): string?
	local k = key or ""
	local keylength = #k
	if valuelength < 1 then
		console.Con_Printf("InfoString_GetValue: no room in value\n")
		return nil
	end
	if string.find(k, "\\", 1, true) then
		console.Con_Printf('InfoString_GetValue: key name "%s" contains \\ which is not possible in an infostring\n', k)
		return nil
	end
	if string.find(k, '"', 1, true) then
		console.Con_Printf('InfoString_SetValue: key name "%s" contains " which is not allowed in an infostring\n', k)
		return nil
	end
	if k == "" then
		console.Con_Printf("InfoString_GetValue: can not look up a key with no name\n")
		return nil
	end
	local pos = 0
	while cb(buffer, pos) == 92 do
		if
			keymatch(buffer, pos + 1, k)
			and (cb(buffer, pos + 1 + keylength) == 0 or cb(buffer, pos + 1 + keylength) == 92)
		then
			pos += 1 + keylength -- Skip \key
			if cb(buffer, pos) == 92 then
				pos += 1 -- Skip \ before value.
			end
			local j = 0
			while cb(buffer, pos + j) ~= 0 and cb(buffer, pos + j) ~= 92 and j < valuelength - 1 do
				j += 1
			end
			return string.sub(buffer, pos + 1, pos + j)
		end
		if cb(buffer, pos) == 92 then
			pos += 1
		end
		pos += 1
		while cb(buffer, pos) ~= 0 and cb(buffer, pos) ~= 92 do
			pos += 1
		end
		if cb(buffer, pos) == 92 then
			pos += 1
		end
		pos += 1
		while cb(buffer, pos) ~= 0 and cb(buffer, pos) ~= 92 do
			pos += 1
		end
	end
	return nil -- the key was not found
end

-- port: common.c InfoString_SetValue L2058-2118 @xonotic-v0.8.6 (returns the new buffer contents)
function common.InfoString_SetValue(buffer: string, bufferlength: number, key: string?, value: string?): string
	local k, v = key or "", value or ""
	local keylength = #k
	if string.find(k, "\\", 1, true) or string.find(v, "\\", 1, true) then
		console.Con_Printf(
			'InfoString_SetValue: "%s" "%s" contains \\ which is not possible to store in an infostring\n',
			k,
			v
		)
		return buffer
	end
	if string.find(k, '"', 1, true) or string.find(v, '"', 1, true) then
		console.Con_Printf('InfoString_SetValue: "%s" "%s" contains " which is not allowed in an infostring\n', k, v)
		return buffer
	end
	if k == "" then
		console.Con_Printf("InfoString_SetValue: can not set a key with no name\n")
		return buffer
	end
	local pos = 0
	while cb(buffer, pos) == 92 do
		if
			keymatch(buffer, pos + 1, k)
			and (cb(buffer, pos + 1 + keylength) == 0 or cb(buffer, pos + 1 + keylength) == 92)
		then
			break
		end
		if cb(buffer, pos) == 92 then
			pos += 1
		end
		while cb(buffer, pos) ~= 0 and cb(buffer, pos) ~= 92 do
			pos += 1
		end
		if cb(buffer, pos) == 92 then
			pos += 1
		end
		while cb(buffer, pos) ~= 0 and cb(buffer, pos) ~= 92 do
			pos += 1
		end
	end
	-- if we found the key, find the end of it because we will be replacing it
	local pos2 = pos
	if cb(buffer, pos) == 92 then
		pos2 += 1 + keylength
		if cb(buffer, pos2) == 92 then
			pos2 += 1
		end
		while cb(buffer, pos2) ~= 0 and cb(buffer, pos2) ~= 92 do
			pos2 += 1
		end
	end
	local rest = string.sub(buffer, pos2 + 1)
	if bufferlength <= pos + 1 + #k + 1 + #v + #rest then
		console.Con_Printf('InfoString_SetValue: no room for "%s" "%s" in infostring\n', k, v)
		return buffer
	end
	local head = string.sub(buffer, 1, pos)
	if v ~= "" then
		local new = "\\" .. k .. "\\" .. v .. string.sub(rest, 1, 16383)
		return head .. string.sub(new, 1, bufferlength - pos - 1)
	end
	return head .. string.sub(rest, 1, bufferlength - pos - 1) -- just remove the key from the text
end

local utf8lib_mod: any = nil

-- COM_ToLowerString / COM_ToUpperString share one body; upper selects the direction.
local function caseString(input: string, size_out: number, upper: boolean): string
	if size_out == 0 then
		return ""
	end
	-- (required on first use and kept: a require() call resolves the path every time in Lune, about 0.5 ms)
	if not utf8lib_mod then
		utf8lib_mod = require("./utf8lib")
	end
	local utf8lib = utf8lib_mod
	local out = {}
	local i = 1
	if utf8lib.enabled() then
		while (string.byte(input, i) or 0) ~= 0 and size_out > 1 do
			local ch
			ch, i = utf8lib.u8_getchar_utf8_enabled(input, i)
			ch = if upper then utf8lib.u8_toupper(ch) else utf8lib.u8_tolower(ch)
			local n, bytes = utf8lib.u8_fromchar(ch, size_out)
			if n <= 0 then
				break
			end
			table.insert(out, bytes)
			size_out -= n
		end
		return table.concat(out)
	end
	local lo, hi, d = if upper then 97 else 65, if upper then 122 else 90, if upper then -32 else 32
	while (string.byte(input, i) or 0) ~= 0 and size_out > 1 do
		local c = string.byte(input, i)
		table.insert(out, string.char(if c >= lo and c <= hi then c + d else c))
		i += 1
		size_out -= 1
	end
	return table.concat(out)
end

-- port: common.c COM_ToLowerString L1717-1748 @xonotic-v0.8.6 (returns the out string)
function common.COM_ToLowerString(input: string, size_out: number): string
	return caseString(input, size_out, false)
end

-- port: common.c COM_ToUpperString L1750-1781 @xonotic-v0.8.6 (returns the out string)
function common.COM_ToUpperString(input: string, size_out: number): string
	return caseString(input, size_out, true)
end

-- port: common.c COM_StringDecolorize L1945-2006 @xonotic-v0.8.6 (returns ok, out)
function common.COM_StringDecolorize(
	input: string,
	size_in: number,
	size_out: number,
	escape_carets: boolean
): (boolean, string)
	local out = {}
	if size_out < 1 then
		return false, ""
	end
	local function isx(c: number): boolean
		return (c >= 48 and c <= 57) or (c >= 97 and c <= 102) or (c >= 65 and c <= 70)
	end
	local e = if size_in ~= 0 then size_in + 1 else -1 -- 1-based index of end (NULL: never)
	local i = 1
	local function at(k: number): number
		if k == e then
			return 0
		end
		return string.byte(input, k) or 0
	end
	local full = false
	local function APPEND(ch: number): boolean
		size_out -= 1
		if size_out ~= 0 then
			table.insert(out, string.char(ch))
			return true
		end
		full = true
		return false
	end
	while true do
		local c = at(i)
		if c == 0 then
			return true, table.concat(out)
		elseif c == 94 then -- STRING_COLOR_TAG
			i += 1
			local d = at(i)
			if d == 120 then -- STRING_COLOR_RGB_TAG_CHAR
				if
					i + 1 ~= e
					and isx(at(i + 1))
					and i + 2 ~= e
					and isx(at(i + 2))
					and i + 3 ~= e
					and isx(at(i + 3))
				then
					i += 3
				else
					if not APPEND(94) then
						break
					end
					if escape_carets and not APPEND(94) then
						break
					end
					if not APPEND(120) then
						break
					end
				end
			elseif d == 0 then -- ends with unfinished color code!
				if not APPEND(94) then
					break
				end
				-- finish the code by appending another caret when escaping
				if escape_carets and not APPEND(94) then
					break
				end
				return true, table.concat(out)
			elseif d == 94 then -- escaped ^
				if not APPEND(94) then
					break
				end
				-- append a ^ twice when escaping
				if escape_carets and not APPEND(94) then
					break
				end
			elseif d < 48 or d > 57 then -- not a color code (0-9: color code, dropped)
				if not APPEND(94) then
					break
				end
				if not APPEND(d) then
					break
				end
			end
		else
			if not APPEND(c) then
				break
			end
		end
		i += 1
	end
	local _ = full
	return false, table.concat(out)
end

-- port: common.c COM_ParseToken_VM_Tokenize L1227-1332 @xonotic-v0.8.6 (data: 1-based index, nil = NULL)
function common.COM_ParseToken_VM_Tokenize(s: string, data: number?, returnnewline: boolean): (boolean, number?)
	local MAXLEN = 16384 - 1 -- sizeof(com_token) - 1
	common.com_token = ""
	if not data then
		return false, nil
	end
	local d = data :: number
	local out = {}
	local function put(c: number)
		if #out < MAXLEN then
			table.insert(out, string.char(c))
		end
	end
	local function isnl(c: number): boolean
		return c == 10 or c == 13
	end
	local function issep(c: number): boolean
		return c == 123 or c == 125 or c == 41 or c == 40 or c == 93 or c == 91 or c == 58 or c == 44 or c == 59
	end
	while true do -- skipwhite:
		while ISWHITESPACE(at(s, d)) and (not isnl(at(s, d)) or not returnnewline) do
			if at(s, d) == 0 then
				-- end of file
				return false, nil
			end
			d += 1
		end
		-- handle Windows line ending
		if at(s, d) == 13 and at(s, d + 1) == 10 then
			d += 1
		end
		if at(s, d) == 47 and at(s, d + 1) == 47 then
			-- comment
			while at(s, d) ~= 0 and not isnl(at(s, d)) do
				d += 1
			end
			continue
		elseif at(s, d) == 47 and at(s, d + 1) == 42 then
			-- comment
			d += 1
			while at(s, d) ~= 0 and (at(s, d) ~= 42 or at(s, d + 1) ~= 47) do
				d += 1
			end
			if at(s, d) ~= 0 then
				d += 1
			end
			if at(s, d) ~= 0 then
				d += 1
			end
			continue
		end
		break
	end
	local c0 = at(s, d)
	if c0 == 34 or c0 == 39 then
		-- quoted string
		local quote = c0
		d += 1
		while at(s, d) ~= 0 and at(s, d) ~= quote do
			local c = at(s, d)
			if c == 92 then
				d += 1
				c = at(s, d)
				if c == 110 then
					c = 10
				elseif c == 116 then
					c = 9
				end
			end
			put(c)
			d += 1
		end
		common.com_token = table.concat(out)
		if at(s, d) == quote then
			d += 1
		end
		return true, d
	elseif c0 == 13 then
		-- translate Mac line ending to UNIX
		common.com_token = "\n"
		return true, d + 1
	elseif c0 == 10 or issep(c0) then
		-- single character
		common.com_token = string.char(c0)
		return true, d + 1
	end
	-- regular word
	while not ISWHITESPACE(at(s, d)) and not issep(at(s, d)) do
		put(at(s, d))
		d += 1
	end
	common.com_token = table.concat(out)
	return true, d
end

-- port: common.c COM_ParseToken_QuakeC L1113-1218 @xonotic-v0.8.6 (data: 1-based index, nil = NULL)
-- (the C body is the same, character for character, as COM_ParseToken_VM_Tokenize L1227-1332)
function common.COM_ParseToken_QuakeC(s: string, data: number?, returnnewline: boolean): (boolean, number?)
	return common.COM_ParseToken_VM_Tokenize(s, data, returnnewline)
end

-- port: common.c COM_ParseToken_Simple L1000-1104 @xonotic-v0.8.6 (data: 1-based index, nil = NULL)
function common.COM_ParseToken_Simple(
	s: string,
	data: number?,
	returnnewline: boolean,
	parsebackslash: boolean,
	parsecomments: boolean
): (boolean, number?)
	local MAXLEN = 16384 - 1 -- sizeof(com_token) - 1
	common.com_token = ""
	if not data then
		return false, nil
	end
	local d = data :: number
	local out = {}
	local function put(c: number)
		if #out < MAXLEN then
			table.insert(out, string.char(c))
		end
	end
	local function isnl(c: number): boolean
		return c == 10 or c == 13
	end
	while true do -- skipwhite:
		while ISWHITESPACE(at(s, d)) and (not isnl(at(s, d)) or not returnnewline) do
			if at(s, d) == 0 then
				return false, nil -- end of file
			end
			d += 1
		end
		-- handle Windows line ending
		if at(s, d) == 13 and at(s, d + 1) == 10 then
			d += 1
		end
		if parsecomments and at(s, d) == 47 and at(s, d + 1) == 47 then
			while at(s, d) ~= 0 and not isnl(at(s, d)) do
				d += 1
			end
			continue
		elseif parsecomments and at(s, d) == 47 and at(s, d + 1) == 42 then
			d += 1
			while at(s, d) ~= 0 and (at(s, d) ~= 42 or at(s, d + 1) ~= 47) do
				d += 1
			end
			if at(s, d) ~= 0 then
				d += 1
			end
			if at(s, d) ~= 0 then
				d += 1
			end
			continue
		end
		break
	end
	local c0 = at(s, d)
	if c0 == 34 then
		-- quoted string
		d += 1
		while at(s, d) ~= 0 and at(s, d) ~= 34 do
			local c = at(s, d)
			if c == 92 and parsebackslash then
				d += 1
				c = at(s, d)
				if c == 110 then
					c = 10
				elseif c == 116 then
					c = 9
				elseif c == 0 then
					break -- C reads past the terminator here; stop at the end of the data instead
				end
			end
			put(c)
			d += 1
		end
		common.com_token = table.concat(out)
		if at(s, d) == 34 then
			d += 1
		end
		return true, d
	elseif c0 == 13 or c0 == 10 then
		-- \r: translate Mac line ending to UNIX; \n: single character
		common.com_token = "\n"
		return true, d + 1
	end
	-- regular word
	while not ISWHITESPACE(at(s, d)) do
		put(at(s, d))
		d += 1
	end
	common.com_token = table.concat(out)
	return true, d
end

-- protocolversion_t (common.h L125-143)
common.PROTOCOL = {
	UNKNOWN = 0,
	DARKPLACES7 = 1,
	DARKPLACES6 = 2,
	DARKPLACES5 = 3,
	DARKPLACES4 = 4,
	DARKPLACES3 = 5,
	DARKPLACES2 = 6,
	DARKPLACES1 = 7,
	QUAKEDP = 8,
	NEHAHRAMOVIE = 9,
	QUAKE = 10,
	QUAKEWORLD = 11,
	NEHAHRABJP = 12,
	NEHAHRABJP2 = 13,
	NEHAHRABJP3 = 14,
}
local P = common.PROTOCOL

-- sizebuf_t (common.h): data is a buffer of maxsize bytes. readcount / badread (common.h L49-50) are the read
-- state of the MSG_Read* functions; nil is the zeroed C memory (0 / false) of a sizebuf that was only written.
export type SizeBuf = {
	data: buffer,
	maxsize: number,
	cursize: number,
	allowoverflow: boolean,
	overflowed: boolean,
	readcount: number?,
	badread: boolean?,
}
function common.SZ_New(maxsize: number): SizeBuf
	return { data = buffer.create(maxsize), maxsize = maxsize, cursize = 0, allowoverflow = false, overflowed = false }
end

-- port: common.c SZ_Clear L582-585 @xonotic-v0.8.6
function common.SZ_Clear(buf: SizeBuf)
	buf.cursize = 0
end

-- port: common.c SZ_GetSpace L587-608 @xonotic-v0.8.6 (returns the byte offset; Host_Error raises)
function common.SZ_GetSpace(buf: SizeBuf, length: number): number
	if buf.cursize + length > buf.maxsize then
		if not buf.allowoverflow then
			error("SZ_GetSpace: overflow without allowoverflow set", 0)
		end
		if length > buf.maxsize then
			error(string.format("SZ_GetSpace: %i is > full buffer size", length), 0)
		end
		buf.overflowed = true
		local console = require("./console")
		console.Con_Print("SZ_GetSpace: overflow\n")
		common.SZ_Clear(buf)
	end
	local o = buf.cursize
	buf.cursize += length
	return o
end

-- port: common.c SZ_Write L610-613 @xonotic-v0.8.6
function common.SZ_Write(buf: SizeBuf, data: string)
	buffer.writestring(buf.data, common.SZ_GetSpace(buf, #data), data)
end

-- port: common.c MSG_WriteChar L270-276 @xonotic-v0.8.6
function common.MSG_WriteChar(sb: SizeBuf, c: number)
	buffer.writeu8(sb.data, common.SZ_GetSpace(sb, 1), c % 256)
end
-- port: common.c MSG_WriteByte L278-284 @xonotic-v0.8.6
common.MSG_WriteByte = common.MSG_WriteChar

-- port: common.c MSG_WriteShort L286-293 @xonotic-v0.8.6
function common.MSG_WriteShort(sb: SizeBuf, c: number)
	buffer.writeu16(sb.data, common.SZ_GetSpace(sb, 2), c % 65536)
end

-- port: common.c MSG_WriteLong L295-304 @xonotic-v0.8.6
function common.MSG_WriteLong(sb: SizeBuf, c: number)
	buffer.writeu32(sb.data, common.SZ_GetSpace(sb, 4), c % 4294967296)
end

-- port: common.c MSG_WriteFloat L306-319 @xonotic-v0.8.6
function common.MSG_WriteFloat(sb: SizeBuf, f: number)
	buffer.writef32(sb.data, common.SZ_GetSpace(sb, 4), f)
end

-- port: common.c MSG_WriteString L321-327 @xonotic-v0.8.6
function common.MSG_WriteString(sb: SizeBuf, s: string?)
	local str = if s then string.match(s, "^[^%z]*") :: string else ""
	if str == "" then
		common.MSG_WriteChar(sb, 0)
	else
		common.SZ_Write(sb, str .. "\0")
	end
end

-- port: common.c MSG_WriteUnterminatedString L329-333 @xonotic-v0.8.6
function common.MSG_WriteUnterminatedString(sb: SizeBuf, s: string?)
	local str = if s then string.match(s, "^[^%z]*") :: string else ""
	if str ~= "" then
		common.SZ_Write(sb, str)
	end
end

-- (int)(double) truncation, x86 out-of-range -> INT_MIN
local function cint(x: number): number
	if x ~= x or x >= 2147483648 or x <= -2147483649 then
		return -2147483648
	end
	return if x < 0 then math.ceil(x) else math.floor(x)
end

-- port: common.c MSG_WriteCoord13i L335-341 @xonotic-v0.8.6
function common.MSG_WriteCoord13i(sb: SizeBuf, f: number)
	common.MSG_WriteShort(sb, if f >= 0 then cint(f * 8.0 + 0.5) else cint(f * 8.0 - 0.5))
end
-- port: common.c MSG_WriteCoord16i L343-349 @xonotic-v0.8.6
function common.MSG_WriteCoord16i(sb: SizeBuf, f: number)
	common.MSG_WriteShort(sb, if f >= 0 then cint(f + 0.5) else cint(f - 0.5))
end
-- port: common.c MSG_WriteCoord32f L351-354 @xonotic-v0.8.6
common.MSG_WriteCoord32f = common.MSG_WriteFloat

-- port: common.c MSG_WriteCoord L356-366 @xonotic-v0.8.6 (DARKPLACES1 and the default branch are the same in C)
-- selene: allow(if_same_then_else)
function common.MSG_WriteCoord(sb: SizeBuf, f: number, protocol: number)
	if
		protocol == P.QUAKE
		or protocol == P.QUAKEDP
		or protocol == P.NEHAHRAMOVIE
		or protocol == P.NEHAHRABJP
		or protocol == P.NEHAHRABJP2
		or protocol == P.NEHAHRABJP3
		or protocol == P.QUAKEWORLD
	then
		common.MSG_WriteCoord13i(sb, f)
	elseif protocol == P.DARKPLACES1 then
		common.MSG_WriteCoord32f(sb, f)
	elseif protocol == P.DARKPLACES2 or protocol == P.DARKPLACES3 or protocol == P.DARKPLACES4 then
		common.MSG_WriteCoord16i(sb, f)
	else
		common.MSG_WriteCoord32f(sb, f)
	end
end

-- port: common.c MSG_WriteVector L368-373 @xonotic-v0.8.6
function common.MSG_WriteVector(sb: SizeBuf, v: { number }, protocol: number)
	common.MSG_WriteCoord(sb, v[1], protocol)
	common.MSG_WriteCoord(sb, v[2], protocol)
	common.MSG_WriteCoord(sb, v[3], protocol)
end

-- port: common.c MSG_WriteAngle8i L376-382 @xonotic-v0.8.6
function common.MSG_WriteAngle8i(sb: SizeBuf, f: number)
	local v = if f >= 0 then cint(f * (256.0 / 360.0) + 0.5) else cint(f * (256.0 / 360.0) - 0.5)
	common.MSG_WriteByte(sb, bit32.band(v, 255))
end
-- port: common.c MSG_WriteAngle16i L384-390 @xonotic-v0.8.6
function common.MSG_WriteAngle16i(sb: SizeBuf, f: number)
	local v = if f >= 0 then cint(f * (65536.0 / 360.0) + 0.5) else cint(f * (65536.0 / 360.0) - 0.5)
	common.MSG_WriteShort(sb, bit32.band(v, 65535))
end
-- port: common.c MSG_WriteAngle32f L392-395 @xonotic-v0.8.6
common.MSG_WriteAngle32f = common.MSG_WriteFloat

-- port: common.c MSG_WriteAngle L397-403 @xonotic-v0.8.6
function common.MSG_WriteAngle(sb: SizeBuf, f: number, protocol: number)
	if
		protocol == P.QUAKE
		or protocol == P.QUAKEDP
		or protocol == P.NEHAHRAMOVIE
		or protocol == P.NEHAHRABJP
		or protocol == P.NEHAHRABJP2
		or protocol == P.NEHAHRABJP3
		or protocol == P.DARKPLACES1
		or protocol == P.DARKPLACES2
		or protocol == P.DARKPLACES3
		or protocol == P.DARKPLACES4
		or protocol == P.QUAKEWORLD
	then
		common.MSG_WriteAngle8i(sb, f)
	else
		common.MSG_WriteAngle16i(sb, f)
	end
end

--[[
	reading functions (common.c L405-577, common.h L178-182). sb.readcount nil = 0, sb.badread nil = false.
	The int results are C ints (sign as in C); the float results are float values (f32-rounded doubles).
]]
local fround = require("./_port/f32").round
local readu8 = buffer.readu8

-- port: common.c MSG_InitReadBuffer L409-415 @xonotic-v0.8.6
function common.MSG_InitReadBuffer(buf: SizeBuf, data: buffer, size: number)
	-- memset(buf, 0, sizeof(*buf))
	buf.allowoverflow = false
	buf.overflowed = false
	buf.data = data
	buf.cursize = size
	buf.maxsize = buf.cursize
	common.MSG_BeginReading(buf)
end

-- port: common.c MSG_BeginReading L417-421 @xonotic-v0.8.6
function common.MSG_BeginReading(sb: SizeBuf)
	sb.readcount = 0
	sb.badread = false
end

-- port: common.c MSG_ReadLittleShort L423-432 @xonotic-v0.8.6
function common.MSG_ReadLittleShort(sb: SizeBuf): number
	local rc = sb.readcount or 0
	if rc + 2 > sb.cursize then
		sb.badread = true
		return -1
	end
	rc += 2
	sb.readcount = rc
	-- (short)(data[rc-2] | (data[rc-1]<<8))
	return buffer.readi16(sb.data, rc - 2)
end

-- port: common.c MSG_ReadBigShort L434-443 @xonotic-v0.8.6
function common.MSG_ReadBigShort(sb: SizeBuf): number
	local rc = sb.readcount or 0
	if rc + 2 > sb.cursize then
		sb.badread = true
		return -1
	end
	rc += 2
	sb.readcount = rc
	local v = readu8(sb.data, rc - 2) * 256 + readu8(sb.data, rc - 1)
	return if v >= 0x8000 then v - 0x10000 else v -- (short)
end

-- port: common.c MSG_ReadLittleLong L445-454 @xonotic-v0.8.6
function common.MSG_ReadLittleLong(sb: SizeBuf): number
	local rc = sb.readcount or 0
	if rc + 4 > sb.cursize then
		sb.badread = true
		return -1
	end
	rc += 4
	sb.readcount = rc
	return buffer.readi32(sb.data, rc - 4)
end

-- port: common.c MSG_ReadBigLong L456-465 @xonotic-v0.8.6
function common.MSG_ReadBigLong(sb: SizeBuf): number
	local rc = sb.readcount or 0
	if rc + 4 > sb.cursize then
		sb.badread = true
		return -1
	end
	rc += 4
	sb.readcount = rc
	local d = sb.data
	-- (data<<24) + ... in int: the top byte's shift wraps into the sign bit (x86)
	local u = readu8(d, rc - 4) * 16777216 + readu8(d, rc - 3) * 65536 + readu8(d, rc - 2) * 256 + readu8(d, rc - 1)
	return if u >= 0x80000000 then u - 0x100000000 else u
end

-- port: common.c MSG_ReadLittleFloat L467-482 @xonotic-v0.8.6
function common.MSG_ReadLittleFloat(sb: SizeBuf): number
	local rc = sb.readcount or 0
	if rc + 4 > sb.cursize then
		sb.badread = true
		return -1
	end
	rc += 4
	sb.readcount = rc
	-- dat.l = the 4 bytes little endian; return dat.f
	return buffer.readf32(sb.data, rc - 4)
end

local bigfloat_tmp = buffer.create(4)
-- port: common.c MSG_ReadBigFloat L484-499 @xonotic-v0.8.6
function common.MSG_ReadBigFloat(sb: SizeBuf): number
	local rc = sb.readcount or 0
	if rc + 4 > sb.cursize then
		sb.badread = true
		return -1
	end
	rc += 4
	sb.readcount = rc
	local d = sb.data
	buffer.writeu8(bigfloat_tmp, 0, readu8(d, rc - 1))
	buffer.writeu8(bigfloat_tmp, 1, readu8(d, rc - 2))
	buffer.writeu8(bigfloat_tmp, 2, readu8(d, rc - 3))
	buffer.writeu8(bigfloat_tmp, 3, readu8(d, rc - 4))
	return buffer.readf32(bigfloat_tmp, 0)
end

-- port: common.h MSG_ReadChar L178 @xonotic-v0.8.6 (macro)
function common.MSG_ReadChar(sb: SizeBuf): number
	local rc = sb.readcount or 0
	if rc >= sb.cursize then
		sb.badread = true
		return -1
	end
	sb.readcount = rc + 1
	return buffer.readi8(sb.data, rc) -- (signed char)
end

-- port: common.h MSG_ReadByte L179 @xonotic-v0.8.6 (macro)
function common.MSG_ReadByte(sb: SizeBuf): number
	local rc = sb.readcount or 0
	if rc >= sb.cursize then
		sb.badread = true
		return -1
	end
	sb.readcount = rc + 1
	return readu8(sb.data, rc) -- (unsigned char)
end

-- common.h L180-182: MSG_ReadShort / MSG_ReadLong / MSG_ReadFloat are the little-endian readers
common.MSG_ReadShort = common.MSG_ReadLittleShort
common.MSG_ReadLong = common.MSG_ReadLittleLong
common.MSG_ReadFloat = common.MSG_ReadLittleFloat

-- port: common.c MSG_ReadString L501-511 @xonotic-v0.8.6
-- (returns the string: the C static buffer `string` of maxstring bytes holds at most maxstring - 1 characters;
-- the rest of the message string is still consumed)
function common.MSG_ReadString(sb: SizeBuf, maxstring: number): string
	local rc = sb.readcount or 0
	local start = rc
	local d, cursize = sb.data, sb.cursize
	local l -- characters read (c > 0)
	-- while ((c = MSG_ReadByte(sb)) > 0)
	while true do
		if rc >= cursize then
			sb.badread = true -- MSG_ReadByte returned -1
			l = rc - start
			break
		end
		local c = readu8(d, rc)
		rc += 1
		if c == 0 then
			l = rc - 1 - start
			break
		end
	end
	sb.readcount = rc
	-- if (l < maxstring - 1) string[l++] = c;
	if l > maxstring - 1 then
		l = maxstring - 1
	end
	return buffer.readstring(d, start, l)
end

-- port: common.c MSG_ReadBytes L513-519 @xonotic-v0.8.6 (out: a buffer written from offset 0)
function common.MSG_ReadBytes(sb: SizeBuf, numbytes: number, out: buffer): number
	local l = 0
	while l < numbytes do
		local c = common.MSG_ReadByte(sb)
		if c == -1 then
			break
		end
		buffer.writeu8(out, l, c)
		l += 1
	end
	return l
end

-- port: common.c MSG_ReadCoord13i L521-524 @xonotic-v0.8.6
function common.MSG_ReadCoord13i(sb: SizeBuf): number
	return fround(common.MSG_ReadLittleShort(sb) * (1.0 / 8.0))
end

-- (signed short) of an int
local function sshort(v: number): number
	v = bit32.band(v, 0xFFFF)
	return if v >= 0x8000 then v - 0x10000 else v
end

-- port: common.c MSG_ReadCoord16i L526-529 @xonotic-v0.8.6
function common.MSG_ReadCoord16i(sb: SizeBuf): number
	return sshort(common.MSG_ReadLittleShort(sb))
end

-- port: common.c MSG_ReadCoord32f L531-534 @xonotic-v0.8.6
function common.MSG_ReadCoord32f(sb: SizeBuf): number
	return common.MSG_ReadLittleFloat(sb)
end

-- port: common.c MSG_ReadCoord L536-546 @xonotic-v0.8.6 (DARKPLACES1 and the default branch are the same in C)
-- selene: allow(if_same_then_else)
function common.MSG_ReadCoord(sb: SizeBuf, protocol: number): number
	if
		protocol == P.QUAKE
		or protocol == P.QUAKEDP
		or protocol == P.NEHAHRAMOVIE
		or protocol == P.NEHAHRABJP
		or protocol == P.NEHAHRABJP2
		or protocol == P.NEHAHRABJP3
		or protocol == P.QUAKEWORLD
	then
		return common.MSG_ReadCoord13i(sb)
	elseif protocol == P.DARKPLACES1 then
		return common.MSG_ReadCoord32f(sb)
	elseif protocol == P.DARKPLACES2 or protocol == P.DARKPLACES3 or protocol == P.DARKPLACES4 then
		return common.MSG_ReadCoord16i(sb)
	else
		return common.MSG_ReadCoord32f(sb)
	end
end

-- port: common.c MSG_ReadVector L548-553 @xonotic-v0.8.6
function common.MSG_ReadVector(sb: SizeBuf, v: { number }, protocol: number)
	v[1] = common.MSG_ReadCoord(sb, protocol)
	v[2] = common.MSG_ReadCoord(sb, protocol)
	v[3] = common.MSG_ReadCoord(sb, protocol)
end

-- port: common.c MSG_ReadAngle8i L556-559 @xonotic-v0.8.6
function common.MSG_ReadAngle8i(sb: SizeBuf): number
	local b = bit32.band(common.MSG_ReadByte(sb), 0xFF)
	local sc = if b >= 0x80 then b - 0x100 else b -- (signed char)
	return fround(sc * (360.0 / 256.0))
end

-- port: common.c MSG_ReadAngle16i L561-564 @xonotic-v0.8.6
function common.MSG_ReadAngle16i(sb: SizeBuf): number
	return fround(sshort(common.MSG_ReadLittleShort(sb)) * (360.0 / 65536.0))
end

-- port: common.c MSG_ReadAngle32f L566-569 @xonotic-v0.8.6
function common.MSG_ReadAngle32f(sb: SizeBuf): number
	return common.MSG_ReadLittleFloat(sb)
end

-- port: common.c MSG_ReadAngle L571-577 @xonotic-v0.8.6
function common.MSG_ReadAngle(sb: SizeBuf, protocol: number): number
	if
		protocol == P.QUAKE
		or protocol == P.QUAKEDP
		or protocol == P.NEHAHRAMOVIE
		or protocol == P.NEHAHRABJP
		or protocol == P.NEHAHRABJP2
		or protocol == P.NEHAHRABJP3
		or protocol == P.DARKPLACES1
		or protocol == P.DARKPLACES2
		or protocol == P.DARKPLACES3
		or protocol == P.DARKPLACES4
		or protocol == P.QUAKEWORLD
	then
		return common.MSG_ReadAngle8i(sb)
	else
		return common.MSG_ReadAngle16i(sb)
	end
end

return common
