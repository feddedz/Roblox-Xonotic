--!strict
--[[
Copyright (C) 1996-1997 Id Software, Inc. (DarkPlaces common.c; GPLv2 or later, see engine/prvm_edict.luau)
]]
--[[
	Port of common.c @xonotic-v0.8.6. PARTIAL: COM_ParseToken_Console (used by cmd.c).
	A C `const char *` into a string is (s, i): byte index i (1-based); i > #s reads as the NUL terminator.
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

return common
