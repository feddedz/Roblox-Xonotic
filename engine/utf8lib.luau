--!strict
--[[
	DarkPlaces utf8lib.c (Blub\0, GPLv2 or later, see engine/cvar.luau).
]]
--[[
	Port of utf8lib.c @xonotic-v0.8.6. PARTIAL: utf8_enable lookup, utf8_lengths, utf8_range, u8_analyze,
	u8_strlen, u8_bytelen, u8_byteofs, u8_getchar_utf8_enabled, u8_getchar_noendptr, u8_quake2utf8map.
	A C `const char *` is (s, i): string + 1-based byte index; bytes past the end read as NUL.
	u8_fromchar, u8_toupper, u8_tolower.
	NOT YET PORTED: the rest (u8_encodech, u8_strpad, ...), added with the builtins that need them.
]]
local cvar = require("./cvar")
local u8_case = require("./_port/u8_case")

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

-- port: utf8lib.c u8_fromchar L636-698 @xonotic-v0.8.6
-- Returns n, bytes: n as in C (bytes written, <= 0 if the buffer is too small), bytes = what was written
-- before the terminating NUL (only meaningful when n > 0).
function utf8lib.u8_fromchar(w: number, maxlen: number): (number, string)
	if maxlen < 1 then
		return 0, ""
	end
	if w == 0 then
		return 0, ""
	end
	local on = enabled()
	if w >= 0xE000 and not on then
		w -= 0xE000
	end
	if w < 0x80 or not on then
		if maxlen < 2 then
			return -1, ""
		end
		return 1, string.char(w % 256) -- (char)w
	end
	if w < 0x800 then
		if maxlen < 3 then
			return -1, ""
		end
		return 2, string.char(bit32.bor(0xC0, bit32.rshift(w, 6)), bit32.bor(0x80, bit32.band(w, 0x3F)))
	end
	if w < 0x10000 then
		if maxlen < 4 then
			return -1, ""
		end
		return 3,
			string.char(
				bit32.bor(0xE0, bit32.rshift(w, 12)),
				bit32.bor(0x80, bit32.band(bit32.rshift(w, 6), 0x3F)),
				bit32.bor(0x80, bit32.band(w, 0x3F))
			)
	end
	-- RFC 3629
	if w <= 0x10FFFF then
		if maxlen < 5 then
			return -1, ""
		end
		return 4,
			string.char(
				bit32.bor(0xF0, bit32.rshift(w, 18)),
				bit32.bor(0x80, bit32.band(bit32.rshift(w, 12), 0x3F)),
				bit32.bor(0x80, bit32.band(bit32.rshift(w, 6), 0x3F)),
				bit32.bor(0x80, bit32.band(w, 0x3F))
			)
	end
	return 0, ""
end

-- port: utf8lib.c u8_toupper L957-2009 @xonotic-v0.8.6 (table in engine/_port/u8_case.luau)
function utf8lib.u8_toupper(ch: number): number
	return u8_case.u8_toupper[ch] or ch
end

-- port: utf8lib.c u8_tolower L2011-3055 @xonotic-v0.8.6 (table in engine/_port/u8_case.luau)
function utf8lib.u8_tolower(ch: number): number
	return u8_case.u8_tolower[ch] or ch
end

-- port: utf8lib.c u8_encodech L705-715 @xonotic-v0.8.6 (returns the bytes, or nil)
function utf8lib.u8_encodech(ch: number): string?
	local n, bytes = utf8lib.u8_fromchar(ch, 16)
	if n > 0 then
		return bytes
	end
	return nil
end

-- port: utf8lib.c colorcode_skipwidth L229-250 @xonotic-v0.8.6
local function ishex(c: number): boolean
	return (c >= 48 and c <= 57) or (c >= 97 and c <= 102) or (c >= 65 and c <= 70)
end
local function colorcode_skipwidth(s: string, p: number): number
	if at(s, p) == 94 then -- STRING_COLOR_TAG '^'
		local c1 = at(s, p + 1)
		if c1 <= 57 and c1 >= 48 then -- ^[0-9] found
			return 2
		elseif c1 == 120 and ishex(at(s, p + 2)) and ishex(at(s, p + 3)) and ishex(at(s, p + 4)) then
			return 5
		elseif c1 == 94 then
			return 1 -- special case, do NOT call colorcode_skipwidth for next char
		end
	end
	return 0
end

local SIZE = 2 ^ 64
local function size_t(n: number): number
	return if n < 0 then n + SIZE else n
end

-- port: utf8lib.c u8_strnlen_colorcodes L300-341 @xonotic-v0.8.6
local function u8_strnlen_colorcodes(s: string, n: number): number
	local p = 1
	local len = 0
	while at(s, p) ~= 0 and n ~= 0 do
		local w = colorcode_skipwidth(s, p)
		n = size_t(n - w)
		p += w
		if w > 1 then -- == 1 means single caret
			continue
		end
		local c = at(s, p)
		-- ascii char, skip u8_analyze
		if c < 0x80 or not enabled() then
			len += 1
			p += 1
			n = size_t(n - 1)
			continue
		end
		-- invalid, skip u8_analyze
		if c < 0xC2 then
			p += 1
			n = size_t(n - 1)
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

-- port: utf8lib.c u8_bytelen_colorcodes L387-425 @xonotic-v0.8.6
local function u8_bytelen_colorcodes(s: string, n: number): number
	local p = 1
	local len = 0
	while at(s, p) ~= 0 and n ~= 0 do
		local w = colorcode_skipwidth(s, p)
		len += w
		p += w
		if w > 1 then -- == 1 means single caret
			continue
		end
		local c = at(s, p)
		if c < 0x80 or not enabled() then
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

-- "%*s%.*s%*s" with lpad, "", prec, in, rpad, "" (prec in bytes)
local function pad3(lpad: number, prec: number, s: string, rpad: number): string
	return string.rep(" ", lpad) .. string.sub(s, 1, prec) .. string.rep(" ", rpad)
end

-- port: utf8lib.c u8_strpad L889-905 @xonotic-v0.8.6 (returns the full formatted string; the caller
-- applies dpsnprintf's outsize truncation)
function utf8lib.u8_strpad(s: string, leftalign: boolean, minwidth: number, maxwidth: number): string
	s = string.match(s, "^[^%z]*") :: string
	if not enabled() then
		-- "%*.*s", leftalign ? -(int)minwidth : (int)minwidth, (int)maxwidth
		local body = if maxwidth >= 0 then string.sub(s, 1, maxwidth) else s
		local w = minwidth - #body
		if w <= 0 then
			return body
		end
		return if leftalign then body .. string.rep(" ", w) else string.rep(" ", w) .. body
	end
	local l = utf8lib.u8_bytelen(s, 1, maxwidth)
	local actual_width = utf8lib.u8_strnlen(s, 1, l)
	local pad = if actual_width >= minwidth then 0 else minwidth - actual_width
	return pad3(if leftalign then 0 else pad, l, s, if leftalign then pad else 0)
end

-- port: utf8lib.c u8_strpad_colorcodes L907-916 @xonotic-v0.8.6 (see u8_strpad)
function utf8lib.u8_strpad_colorcodes(s: string, leftalign: boolean, minwidth: number, maxwidth: number): string
	s = string.match(s, "^[^%z]*") :: string
	local l = u8_bytelen_colorcodes(s, maxwidth)
	local actual_width = u8_strnlen_colorcodes(s, l)
	local pad = if actual_width >= minwidth then 0 else minwidth - actual_width
	return pad3(if leftalign then 0 else pad, l, s, if leftalign then pad else 0)
end

local function isxdigit(c: number): boolean
	return (c >= 48 and c <= 57) or (c >= 97 and c <= 102) or (c >= 65 and c <= 70)
end

-- port: common.c COM_StringLengthNoColors L1871-1923 @xonotic-v0.8.6 (returns len, valid)
function utf8lib.COM_StringLengthNoColors(s: string, size_s: number): (number, boolean)
	local e = if size_s ~= 0 then size_s + 1 else -1
	local function c(k: number): number
		return if k == e then 0 else at(s, k)
	end
	local p, len = 1, 0
	while true do
		local ch = c(p)
		if ch == 0 then
			return len, true
		elseif ch == 94 then -- STRING_COLOR_TAG
			p += 1
			local d = c(p)
			if d == 120 then -- STRING_COLOR_RGB_TAG_CHAR
				if
					p + 1 ~= e
					and isxdigit(c(p + 1))
					and p + 2 ~= e
					and isxdigit(c(p + 2))
					and p + 3 ~= e
					and isxdigit(c(p + 3))
				then
					p += 3
				else
					len += 2
				end
			elseif d == 0 then -- ends with unfinished color code!
				return len + 1, false
			elseif d == 94 then -- escaped ^
				len += 1
			elseif d < 48 or d > 57 then -- not a color code (0-9: color code)
				len += 2
			end
		else
			len += 1
		end
		p += 1
	end
end

-- port: utf8lib.c u8_COM_StringLengthNoColors L784-878 @xonotic-v0.8.6 (returns len, valid)
function utf8lib.u8_COM_StringLengthNoColors(s: string, size_s: number): (number, boolean)
	if not enabled() then
		return utf8lib.COM_StringLengthNoColors(s, size_s)
	end
	local e = if size_s ~= 0 then size_s + 1 else -1
	local function c(k: number): number
		return if k == e then 0 else at(s, k)
	end
	local p, len = 1, 0
	while true do
		local ch = c(p)
		if ch == 0 then
			return len, true
		elseif ch == 94 then
			p += 1
			local d = c(p)
			if d == 120 then
				if
					p + 1 ~= e
					and isxdigit(c(p + 1))
					and p + 2 ~= e
					and isxdigit(c(p + 2))
					and p + 3 ~= e
					and isxdigit(c(p + 3))
				then
					p += 3
				else
					len += 2
				end
			elseif d == 0 then
				return len + 1, false
			elseif d == 94 then
				len += 1
			elseif d < 48 or d > 57 then
				len += 2
			end
			p += 1
			continue
		end
		-- ascii char, skip u8_analyze
		if ch < 0x80 then
			len += 1
			p += 1
			continue
		end
		-- invalid, skip u8_analyze
		if ch < 0xC2 then
			p += 1
			continue
		end
		local ok, st, ln = u8_analyze(s, p, U8_ANALYZE_INFINITY)
		if not ok then
			-- we CAN end up here, if an invalid char is between this one and the end of the string
			return len, true
		end
		if e ~= -1 and p + st + ln > e then
			-- string length exceeded by new character
			return len, true
		end
		-- valid character, skip after it
		p += st + ln
		len += 1
	end
end

return utf8lib
