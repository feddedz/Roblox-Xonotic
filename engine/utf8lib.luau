--!strict
--[[
	DarkPlaces utf8lib.c (Blub\0, GPLv2 or later, see engine/cvar.luau).
]]
--[[
	Port of utf8lib.c @xonotic-v0.8.6. PARTIAL: utf8_enable lookup, utf8_lengths, utf8_range, u8_analyze,
	u8_strlen, u8_bytelen, u8_byteofs, u8_getchar_utf8_enabled, u8_getchar_noendptr, u8_quake2utf8map.
	A C `const char *` is (s, i): string + 1-based byte index; bytes past the end read as NUL.
	NOT YET PORTED: the rest (u8_fromchar, u8_encodech, u8_strpad, ...), added with the builtins that need them.
]]
local cvar = require("./cvar")

local utf8lib = {}

local function at(s: string, i: number): number
	return string.byte(s, i) or 0
end

-- utf8_enable.integer (registered by u8_Init; 0 when not registered, like the static default "0")
local function enabled(): boolean
	local v = cvar.Cvar_FindVar("utf8_enable")
	return v ~= nil and v.integer ~= 0
end
utf8lib.enabled = enabled

-- data: utf8lib.c utf8_lengths L26-46 @xonotic-v0.8.6 (0 = invalid)
local utf8_lengths = table.create(256, 0)
for b = 0, 255 do
	local n = 0
	if b < 0x80 then
		n = 1
	elseif b >= 0xC2 and b <= 0xDF then
		n = 2
	elseif b >= 0xE0 and b <= 0xEF then
		n = 3
	elseif b >= 0xF0 and b <= 0xF4 then
		n = 4
	end
	utf8_lengths[b + 1] = n
end
-- data: utf8lib.c utf8_range L48-54 @xonotic-v0.8.6
local utf8_range = { [0] = 1, [1] = 1, [2] = 0x80, [3] = 0x800, [4] = 0x10000 }

local U8_ANALYZE_INFINITY = 7

-- port: utf8lib.c u8_analyze L62-188 @xonotic-v0.8.6 (the #if 0 block is not compiled)
-- Returns ok, start, len, ch (start/len are byte counts relative to p).
local function u8_analyze(s: string, p: number, maxlen: number): (boolean, number, number, number)
	local i = 0
	while true do -- findchar:
		local bits = 0
		while i < maxlen and at(s, p + i) ~= 0 do
			bits = utf8_lengths[at(s, p + i) + 1]
			if bits ~= 0 then
				break
			end
			i += 1
		end
		if i >= maxlen or at(s, p + i) == 0 then
			return false, i, 0, 0
		end
		if bits == 1 then -- ascii
			return true, i, 1, at(s, p + i)
		end
		local ch = bit32.band(at(s, p + i), bit32.rshift(0xFF, bits))
		local bad = false
		for j = 1, bits - 1 do
			local c = at(s, p + i + j)
			if bit32.band(c, 0xC0) ~= 0x80 then
				i += j
				bad = true
				break
			end
			ch = bit32.bor(bit32.lshift(ch, 6), bit32.band(c, 0x3F))
		end
		if not bad then
			if ch < utf8_range[bits] or ch >= 0x10FFFF then
				i += bits
			else
				return true, i, bits, ch
			end
		end
	end
end
utf8lib.u8_analyze = u8_analyze

-- port: utf8lib.c u8_strlen L194-227 @xonotic-v0.8.6
function utf8lib.u8_strlen(s: string, p0: number?): number
	local p = p0 or 1
	if not enabled() then
		local e = p
		while at(s, e) ~= 0 do
			e += 1
		end
		return e - p
	end
	local len = 0
	while at(s, p) ~= 0 do
		local c = at(s, p)
		if c < 0x80 then -- ascii char, skip u8_analyze
			len += 1
			p += 1
			continue
		end
		if c < 0xC2 then -- invalid, skip u8_analyze
			p += 1
			continue
		end
		local ok, st, ln = u8_analyze(s, p, U8_ANALYZE_INFINITY)
		if not ok then
			break
		end
		p += st + ln
		len += 1
	end
	return len
end

-- port: utf8lib.c u8_bytelen L348-385 @xonotic-v0.8.6 (n: size_t; callers pass (int) casts, negative = huge)
function utf8lib.u8_bytelen(s: string, p0: number, n: number): number
	if n < 0 then
		n += 2 ^ 64 -- (size_t) of a negative int
	end
	local p = p0
	if not enabled() then
		local e = p
		while at(s, e) ~= 0 do
			e += 1
		end
		local len = e - p
		return if len < n then len else n
	end
	local len = 0
	while at(s, p) ~= 0 and n > 0 do
		local c = at(s, p)
		if c < 0x80 then
			len += 1
			p += 1
			n -= 1
			continue
		end
		if c < 0xC2 then
			p += 1
			len += 1
			continue
		end
		local ok, st, ln = u8_analyze(s, p, U8_ANALYZE_INFINITY)
		if not ok then
			break
		end
		n -= 1
		p += st + ln
		len += st + ln
	end
	return len
end

-- port: utf8lib.c u8_strnlen L257-298 @xonotic-v0.8.6
function utf8lib.u8_strnlen(s: string, p0: number, n: number): number
	local p = p0
	if not enabled() then
		local e = p
		while at(s, e) ~= 0 do
			e += 1
		end
		local len = e - p
		return if len < n then len else n
	end
	local len = 0
	while at(s, p) ~= 0 and n > 0 do
		local c = at(s, p)
		if c < 0x80 then
			len += 1
			p += 1
			n -= 1
			continue
		end
		if c < 0xC2 then
			p += 1
			n -= 1
			continue
		end
		local ok, st, ln = u8_analyze(s, p, n)
		if not ok then
			break
		end
		-- valid character, see if it's still inside the range specified by n:
		if n < st + ln then
			return len
		end
		len += 1
		n -= st + ln
		p += st + ln
	end
	return len
end

-- port: utf8lib.c u8_byteofs L433-462 @xonotic-v0.8.6 (returns ofs, len; ofs -1 = not found)
function utf8lib.u8_byteofs(s: string, i: number): (number, number)
	if i < 0 then
		i += 2 ^ 64 -- size_t
	end
	if not enabled() then
		local e = 1
		while at(s, e) ~= 0 do
			e += 1
		end
		if e - 1 < i then
			return -1, 0
		end
		return i, 1
	end
	local ofs, st, ln = 0, 0, 0
	repeat
		ofs += ln
		local ok
		ok, st, ln = u8_analyze(s, 1 + ofs, U8_ANALYZE_INFINITY)
		if not ok then
			return -1, 0
		end
		ofs += st
		i -= 1
	until not (i + 1 > 0)
	return ofs, ln
end

-- data: utf8lib.c u8_quake2utf8map L576-593 @xonotic-v0.8.6 (0-31 and 128-255 -> 0xE000 + n, rest -> n)
local function quake2utf8(b: number): number
	if b < 32 or b >= 128 then
		return 0xE000 + b
	end
	return b
end
utf8lib.u8_quake2utf8map = quake2utf8

-- port: utf8lib.c u8_getchar_utf8_enabled L600-610 @xonotic-v0.8.6 (returns ch, end index)
function utf8lib.u8_getchar_utf8_enabled(s: string, p: number): (number, number)
	local ok, st, ln, ch = u8_analyze(s, p, U8_ANALYZE_INFINITY)
	if not ok then
		ch = 0
	end
	return ch, p + st + ln
end

-- utf8lib.h u8_getchar_noendptr L58
function utf8lib.u8_getchar_noendptr(s: string, p: number): number
	if enabled() then
		return (utf8lib.u8_getchar_utf8_enabled(s, p))
	end
	return quake2utf8(at(s, p))
end

return utf8lib
