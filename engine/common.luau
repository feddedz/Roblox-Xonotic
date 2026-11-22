--!strict
--[[
Copyright (C) 1996-1997 Id Software, Inc. (DarkPlaces common.c; GPLv2 or later, see engine/prvm_edict.luau)
]]
--[[
	Port of common.c @xonotic-v0.8.6. PARTIAL: COM_ParseToken_Console (used by cmd.c).
	A C `const char *` into a string is (s, i): byte index i (1-based); i > #s reads as the NUL terminator.
	Also InfoString_GetValue / InfoString_SetValue, CRC_Block / CRC_Block_CaseInsensitive (CRC-16/CCITT, crctable generated from its polynomial 0x1021).
	NOT YET PORTED: the rest of common.c (other tokenizers, sizebuf/MSG_*, COM_CheckParm, ...).
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

-- COM_ToLowerString / COM_ToUpperString share one body; upper selects the direction.
local function caseString(input: string, size_out: number, upper: boolean): string
	if size_out == 0 then
		return ""
	end
	local utf8lib = require("./utf8lib")
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

return common
