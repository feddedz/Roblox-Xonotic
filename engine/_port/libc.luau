--!strict
--[[
	Port support (not a DarkPlaces source file): the C library functions DarkPlaces calls, with glibc
	semantics in the "C" locale. Strings are Luau strings of bytes; a C string ends at the first NUL.

	atof/strtod: longest valid prefix, leading isspace() skipped, optional sign, decimal with exponent,
	hexadecimal (0x, optional '.', optional p exponent), "inf"/"infinity", "nan"/"nan(chars)", case
	insensitive; nothing valid -> 0. Decimal conversion is delegated to Luau's tonumber on the exact
	matched digits (correctly rounded, like glibc). Hex mantissas longer than 13 hex digits are rounded
	once more than glibc would (never seen in Xonotic data; see tests/unit/libc.test.luau).
]]
local libc = {}

local function isspace(c: number): boolean
	return c == 32 or (c >= 9 and c <= 13)
end
local function isdigit(c: number): boolean
	return c >= 48 and c <= 57
end
local function hexval(c: number): number?
	if c >= 48 and c <= 57 then
		return c - 48
	elseif c >= 97 and c <= 102 then
		return c - 87
	elseif c >= 65 and c <= 70 then
		return c - 55
	end
	return nil
end

-- C string view: everything up to the first NUL.
function libc.cstr(s: string): string
	local z = string.find(s, "\0", 1, true)
	return if z then string.sub(s, 1, z - 1) else s
end

-- strtod(s, &end): returns value and the 1-based index of the first unparsed byte (end pointer).
-- port of glibc strtod behaviour (C locale)
function libc.strtod(s: string, init: number?): (number, number)
	local i = init or 1
	local n = #s
	local start = i
	while i <= n and isspace(string.byte(s, i)) do
		i += 1
	end
	local sign = 1
	local c = string.byte(s, i)
	if c == 43 or c == 45 then -- + -
		if c == 45 then
			sign = -1
		end
		i += 1
	end
	local rest = string.lower(string.sub(s, i, i + 7))
	if string.sub(rest, 1, 8) == "infinity" then
		return sign * math.huge, i + 8
	elseif string.sub(rest, 1, 3) == "inf" then
		return sign * math.huge, i + 3
	elseif string.sub(rest, 1, 3) == "nan" then
		local j = i + 3
		if string.byte(s, j) == 40 then -- nan(n-char-sequence)
			local k = j + 1
			while k <= n do
				local b = string.byte(s, k)
				if b == 41 then
					j = k + 1
					break
				elseif not (isdigit(b) or (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or b == 95) then
					break
				end
				k += 1
			end
		end
		return sign * (0 / 0), j
	end
	-- hexadecimal
	if string.byte(s, i) == 48 and (string.byte(s, i + 1) == 120 or string.byte(s, i + 1) == 88) then
		local j = i + 2
		local mant, exp, any = 0, 0, false
		while j <= n and hexval(string.byte(s, j)) do
			mant = mant * 16 + (hexval(string.byte(s, j)) :: number)
			any = true
			j += 1
		end
		if string.byte(s, j) == 46 then
			local k = j + 1
			while k <= n and hexval(string.byte(s, k)) do
				mant = mant * 16 + (hexval(string.byte(s, k)) :: number)
				exp -= 4
				any = true
				k += 1
			end
			if any then
				j = k
			end
		end
		if any then
			local pc = string.byte(s, j)
			if pc == 112 or pc == 80 then -- p P
				local k = j + 1
				local esign = 1
				local ec = string.byte(s, k)
				if ec == 43 or ec == 45 then
					esign = if ec == 45 then -1 else 1
					k += 1
				end
				if k <= n and isdigit(string.byte(s, k)) then
					local e = 0
					while k <= n and isdigit(string.byte(s, k)) do
						e = math.min(e * 10 + string.byte(s, k) - 48, 100000)
						k += 1
					end
					exp += esign * e
					j = k
				end
			end
			return sign * mant * 2 ^ exp, j
		end
		-- "0x" without hex digits: only the "0" is parsed
		return sign * 0, i + 1
	end
	-- decimal
	local j = i
	local digits = false
	while j <= n and isdigit(string.byte(s, j)) do
		j += 1
		digits = true
	end
	if string.byte(s, j) == 46 then
		local k = j + 1
		local frac = false
		while k <= n and isdigit(string.byte(s, k)) do
			k += 1
			frac = true
		end
		if digits or frac then
			j = k
			digits = true
		end
	end
	if not digits then
		return 0, start -- no conversion: end pointer = s
	end
	local ec = string.byte(s, j)
	if ec == 101 or ec == 69 then -- e E
		local k = j + 1
		local sc = string.byte(s, k)
		if sc == 43 or sc == 45 then
			k += 1
		end
		if k <= n and isdigit(string.byte(s, k)) then
			while k <= n and isdigit(string.byte(s, k)) do
				k += 1
			end
			j = k
		end
	end
	local v = tonumber(string.sub(s, i, j - 1)) :: number
	return sign * v, j
end

-- atof(s) == strtod(s, NULL), on the C string (stops at NUL)
function libc.atof(s: string): number
	return (libc.strtod(libc.cstr(s)))
end

local INT_MIN, INT_MAX = -2147483648, 2147483647
local LONG_MIN, LONG_MAX = -9223372036854775808, 9223372036854775807

-- strtol(s, &end, 10): value (clamped to long like glibc) and end index. Base 10 only (all DP uses).
function libc.strtol10(s: string, init: number?): (number, number)
	local i = init or 1
	local n = #s
	local start = i
	while i <= n and isspace(string.byte(s, i)) do
		i += 1
	end
	local neg = false
	local c = string.byte(s, i)
	if c == 43 or c == 45 then
		neg = c == 45
		i += 1
	end
	local j = i
	local v = 0
	while j <= n and isdigit(string.byte(s, j)) do
		v = v * 10 + string.byte(s, j) - 48
		j += 1
	end
	if j == i then
		return 0, start
	end
	v = if neg then -v else v
	if v > LONG_MAX then
		v = LONG_MAX
	elseif v < LONG_MIN then
		v = LONG_MIN
	end
	return v, j
end

-- atoi(s) == (int)strtol(s, NULL, 10): glibc clamps to LONG_MIN/LONG_MAX, then the cast keeps the low
-- 32 bits (two's complement). The low bits are tracked exactly (doubles lose them above 2^53).
function libc.atoi(s: string): number
	s = libc.cstr(s)
	local v, e = libc.strtol10(s)
	if v >= INT_MIN and v <= INT_MAX then
		return v
	end
	if v >= LONG_MAX then
		return -1 -- low 32 bits of 0x7fffffffffffffff
	elseif v <= LONG_MIN then
		return 0 -- low 32 bits of 0x8000000000000000
	end
	-- recompute the magnitude modulo 2^32 from the digits
	local i = 1
	while isspace(string.byte(s, i) or 0) do
		i += 1
	end
	local neg = string.byte(s, i) == 45
	if string.byte(s, i) == 43 or neg then
		i += 1
	end
	local lo = 0
	for k = i, e - 1 do
		lo = (lo * 10 + string.byte(s, k) - 48) % 4294967296
	end
	if neg then
		lo = (4294967296 - lo) % 4294967296
	end
	return if lo >= 2147483648 then lo - 4294967296 else lo
end

-- C (int) cast of a float/double on x86-64 (cvttss2si/cvttsd2si): truncation toward zero; NaN and
-- out-of-range values give INT_MIN (0x80000000, "integer indefinite").
function libc.toint(x: number): number
	if x ~= x or x >= 2147483648 or x <= -2147483649 then
		return INT_MIN
	end
	local t = if x < 0 then math.ceil(x) else math.floor(x)
	return t + 0 -- normalise -0 to 0
end

-- strcmp/strcasecmp sign (C locale, unsigned bytes), on C strings.
function libc.strcmp(a: string, b: string): number
	a, b = libc.cstr(a), libc.cstr(b)
	if a == b then
		return 0
	end
	return if a < b then -1 else 1 -- Luau compares strings bytewise (unsigned)
end

local function lowerascii(s: string): string
	return (string.gsub(s, "%u", string.lower))
end
libc.lowerascii = lowerascii

function libc.strcasecmp(a: string, b: string): number
	return libc.strcmp(lowerascii(libc.cstr(a)), lowerascii(libc.cstr(b)))
end

-- strncmp(a, b, n) == 0 ?
function libc.strneq(a: string, b: string, n: number): boolean
	return string.sub(libc.cstr(a), 1, n) == string.sub(libc.cstr(b), 1, n)
end

-- dpsnprintf(buf, size, fmt, ...): C formatting, truncated to size - 1 bytes.
function libc.snprintf(size: number, fmt: string, ...: any): string
	local s = string.format(fmt, ...)
	if #s > size - 1 then
		s = string.sub(s, 1, size - 1)
	end
	return s
end

return libc
