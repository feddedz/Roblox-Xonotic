--!strict
--[[
Copyright (C) 1996-1997 Id Software, Inc. (DarkPlaces common.c; GPLv2 or later, see engine/prvm_edict.luau)
]]
--[[
	Port of common.c @xonotic-v0.8.6. PARTIAL: COM_ParseToken_Console (used by cmd.c).
	A C `const char *` into a string is (s, i): byte index i (1-based); i > #s reads as the NUL terminator.
	Also CRC_Block / CRC_Block_CaseInsensitive (CRC-16/CCITT, crctable generated from its polynomial 0x1021).
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
	return common.CRC_Block((string.gsub(data, "%u", string.lower)))
end

return common
