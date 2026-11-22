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

return common
