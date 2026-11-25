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

-- glibc srand/rand (stdlib/random_r.c TYPE_3: x**31 + x**3 + 1, 31 words of state, 310 discarded outputs).
-- DarkPlaces calls srand(time) at startup (host.c L1177-1179) and rand() through lhrandom; sv_random_seed
-- makes the sequence reproducible, so it must be glibc's. Vectors: tests/vectors/rand.tsv (real glibc).
libc.RAND_MAX = 2147483647
local rstate = table.create(31, 0)
local rf, rr = 4, 1 -- 1-based fptr / rptr into rstate (SEP_3 = 3)

local function rand_step(): number
	local v = (rstate[rf] + rstate[rr]) % 4294967296
	rstate[rf] = v
	rf = if rf == 31 then 1 else rf + 1
	rr = if rr == 31 then 1 else rr + 1
	return v // 2 -- (uint32 >> 1) & 0x7fffffff
end

function libc.srand(seed: number)
	seed = seed % 4294967296
	if seed == 0 then
		seed = 1
	end
	-- state words are int32_t: the seed is stored as-is (bits), the LCG runs on its signed value
	local word = if seed >= 2147483648 then seed - 4294967296 else seed
	rstate[1] = seed
	for i = 2, 31 do
		-- word = 16807 * word % 2147483647 without overflow (Schrage), C truncating division
		local hi = if word >= 0 then word // 127773 else -(-word // 127773)
		local lo = word - hi * 127773
		word = 16807 * lo - 2836 * hi
		if word < 0 then
			word += 2147483647
		end
		rstate[i] = word % 4294967296
	end
	rf, rr = 4, 1
	for _ = 1, 310 do
		rand_step()
	end
end

function libc.rand(): number
	return rand_step()
end
libc.srand(1) -- C: the state before any srand() call is srand(1)

-- glibc strftime in the "C" locale (time/strftime_l.c). tm fields as struct tm: year (full year),
-- mon (1-12), mday, hour, min, sec, wday (0 = Sunday), yday (0-based), zone, gmtoff (s), t (time_t).
-- Returns the result, or "" when it does not fit in maxsize (C returns 0).
-- NOT YET PORTED: flags (_ - 0 ^ #), field widths and the E/O modifiers (logged; Xonotic uses none).
export type Tm = {
	year: number,
	mon: number,
	mday: number,
	hour: number,
	min: number,
	sec: number,
	wday: number,
	yday: number,
	zone: string,
	gmtoff: number,
	t: number,
}
local WDAY = { "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" }
local MON = {
	"January",
	"February",
	"March",
	"April",
	"May",
	"June",
	"July",
	"August",
	"September",
	"October",
	"November",
	"December",
}

local function iso_week(tm: Tm): (number, number)
	-- ISO 8601 week number and week-based year (glibc iso_week_days)
	local function iso_week_days(yday: number, wday: number): number
		local big_enough_multiple_of_7 = (-366 // 7 + 2) * 7
		return yday - (yday - wday + 4 + big_enough_multiple_of_7) % 7 + 3
	end
	local function leap(y: number): boolean
		return y % 4 == 0 and (y % 100 ~= 0 or y % 400 == 0)
	end
	local year = tm.year
	local days = iso_week_days(tm.yday, tm.wday)
	if days < 0 then
		year -= 1
		days = iso_week_days(tm.yday + (if leap(year) then 366 else 365), tm.wday)
	else
		local d = iso_week_days(tm.yday - (if leap(year) then 366 else 365), tm.wday)
		if d >= 0 then
			year += 1
			days = d
		end
	end
	return days // 7 + 1, year
end

local function strftime_conv(c: string, tm: Tm): string?
	local h12 = tm.hour % 12
	if h12 == 0 then
		h12 = 12
	end
	if c == "a" then
		return string.sub(WDAY[tm.wday + 1], 1, 3)
	elseif c == "A" then
		return WDAY[tm.wday + 1]
	elseif c == "b" or c == "h" then
		return string.sub(MON[tm.mon], 1, 3)
	elseif c == "B" then
		return MON[tm.mon]
	elseif c == "c" then
		return libc.strftime("%a %b %e %H:%M:%S %Y", tm, 1024)
	elseif c == "C" then
		return string.format("%02d", tm.year // 100)
	elseif c == "d" then
		return string.format("%02d", tm.mday)
	elseif c == "D" then
		return libc.strftime("%m/%d/%y", tm, 1024)
	elseif c == "e" then
		return string.format("%2d", tm.mday)
	elseif c == "F" then
		return libc.strftime("%Y-%m-%d", tm, 1024)
	elseif c == "g" then
		local _, y = iso_week(tm)
		return string.format("%02d", y % 100)
	elseif c == "G" then
		local _, y = iso_week(tm)
		return tostring(y)
	elseif c == "H" then
		return string.format("%02d", tm.hour)
	elseif c == "I" then
		return string.format("%02d", h12)
	elseif c == "j" then
		return string.format("%03d", tm.yday + 1)
	elseif c == "k" then
		return string.format("%2d", tm.hour)
	elseif c == "l" then
		return string.format("%2d", h12)
	elseif c == "m" then
		return string.format("%02d", tm.mon)
	elseif c == "M" then
		return string.format("%02d", tm.min)
	elseif c == "n" then
		return "\n"
	elseif c == "p" then
		return if tm.hour >= 12 then "PM" else "AM"
	elseif c == "P" then
		return if tm.hour >= 12 then "pm" else "am"
	elseif c == "r" then
		return libc.strftime("%I:%M:%S %p", tm, 1024)
	elseif c == "R" then
		return libc.strftime("%H:%M", tm, 1024)
	elseif c == "s" then
		return string.format("%d", tm.t)
	elseif c == "S" then
		return string.format("%02d", tm.sec)
	elseif c == "t" then
		return "\t"
	elseif c == "T" then
		return libc.strftime("%H:%M:%S", tm, 1024)
	elseif c == "u" then
		return tostring((tm.wday + 6) % 7 + 1)
	elseif c == "U" then
		return string.format("%02d", (tm.yday - tm.wday + 7) // 7)
	elseif c == "V" then
		local w = iso_week(tm)
		return string.format("%02d", w)
	elseif c == "w" then
		return tostring(tm.wday)
	elseif c == "W" then
		return string.format("%02d", (tm.yday - (tm.wday - 1 + 7) % 7 + 7) // 7)
	elseif c == "x" then
		return libc.strftime("%m/%d/%y", tm, 1024)
	elseif c == "X" then
		return libc.strftime("%H:%M:%S", tm, 1024)
	elseif c == "y" then
		return string.format("%02d", tm.year % 100)
	elseif c == "Y" then
		return tostring(tm.year)
	elseif c == "z" then
		local off = tm.gmtoff
		local sign = if off < 0 then "-" else "+"
		off = math.abs(off) // 60
		return string.format("%s%02d%02d", sign, off // 60, off % 60)
	elseif c == "Z" then
		return tm.zone
	elseif c == "%" then
		return "%"
	end
	return nil
end

function libc.strftime(fmt: string, tm: Tm, maxsize: number): string
	local out = {}
	local i, n = 1, #fmt
	while i <= n do
		local ch = string.sub(fmt, i, i)
		if ch ~= "%" then
			table.insert(out, ch)
			i += 1
			continue
		end
		local c = string.sub(fmt, i + 1, i + 1)
		local r = if c ~= "" then strftime_conv(c, tm) else nil
		if r then
			table.insert(out, r)
			i += 2
		else
			if c ~= "" then
				print("NOT YET PORTED: strftime conversion %" .. c)
			end
			-- glibc copies an unknown conversion through unchanged
			table.insert(out, "%" .. c)
			i += 2
		end
	end
	local res = table.concat(out)
	if #res >= maxsize then
		return ""
	end
	return res
end

-- gmtime / localtime from os.date("!*t") / os.date("*t") (both exist on Roblox and Lune, G-048).
local function totm(d: any, t: number, zone: string, gmtoff: number): Tm
	return {
		year = d.year,
		mon = d.month,
		mday = d.day,
		hour = d.hour,
		min = d.min,
		sec = d.sec,
		wday = d.wday - 1,
		yday = d.yday - 1,
		zone = zone,
		gmtoff = gmtoff,
		t = t,
	}
end

function libc.gmtime(t: number): Tm
	return totm(os.date("!*t", t), t, "GMT", 0)
end

-- tm_zone: the host's zone name is not available; "UTC" when the offset is 0 (glibc's name for TZ unset
-- or UTC), else the numeric offset as glibc prints for zones without an abbreviation.
function libc.localtime(t: number): Tm
	local u: any = os.date("!*t", t)
	u.isdst = false
	local gmtoff = t - os.time(u)
	local zone = "UTC"
	if gmtoff ~= 0 then
		local o = math.abs(gmtoff) // 60
		zone = string.format("%s%02d%02d", if gmtoff < 0 then "-" else "+", o // 60, o % 60)
	end
	return totm(os.date("*t", t), t, zone, gmtoff)
end

-- (intmax_t)(double) on x86-64 (cvttsd2si): truncation; NaN / out of range -> INT64_MIN.
function libc.toint64(x: number): number
	if x ~= x or x >= 2 ^ 63 or x < -(2 ^ 63) then
		return -(2 ^ 63)
	end
	local t = if x < 0 then math.ceil(x) else math.floor(x)
	return t + 0
end

-- (uintmax_t)(double) as gcc emits it on x86-64, returned as the int64 with the same bits:
-- x < 2^63: cvttsd2si(x); else cvttsd2si(x - 2^63) ^ 2^63 (>= 2^64 gives 0).
function libc.touint64bits(x: number): number
	if x ~= x or x < 2 ^ 63 then
		return libc.toint64(x)
	end
	local r = libc.toint64(x - 2 ^ 63)
	if r == -(2 ^ 63) then
		return 0
	end
	return r - 2 ^ 63 -- bits r ^ 0x8000000000000000 as int64 (r >= 0 here)
end

-- One C printf conversion, as glibc prints it: flags (subset of "#0- +"), width (>= 0), precision
-- (-1 = none), conv, value (d i o u x X: an int64 value as a number, bits for unsigned conversions;
-- e E f F g G: a double; c: a byte; s: a string). Luau string.format is C's for these (it calls
-- snprintf) but refuses widths/precisions over 99; those are padded here.
function libc.format1(flags: string, width: number, prec: number, conv: string, value: any): string
	local bigw = width > 99
	local bigp = prec > 99
	if bigp and (conv == "e" or conv == "E" or conv == "f" or conv == "F" or conv == "g" or conv == "G") then
		print("NOT YET PORTED: printf precision > 99 for %" .. conv)
		prec = 99
		bigp = false
	end
	if
		(conv == "e" or conv == "E" or conv == "f" or conv == "F" or conv == "g" or conv == "G")
		and (value ~= value or value == math.huge or value == -math.huge)
	then
		-- Non-finite double, done here and not by snprintf: C runtimes differ (Windows' prints "i.nf" for
		-- "%#.0e" of infinity), and the server (Linux) and clients must print the same. glibc: "inf" / "nan",
		-- upper case for E F G, sign from the sign bit or the + / space flag, padded with spaces only;
		-- '#', '0' and the precision have no effect.
		local word = if value ~= value then "nan" else "inf"
		if conv == "E" or conv == "F" or conv == "G" then
			word = string.upper(word)
		end
		local bits = buffer.create(8)
		buffer.writef64(bits, 0, value)
		local sign = if buffer.readu8(bits, 7) >= 128
			then "-"
			elseif string.find(flags, "+", 1, true) then "+"
			elseif string.find(flags, " ", 1, true) then " "
			else ""
		local text = sign .. word
		if #text < width then
			text = if string.find(flags, "-", 1, true)
				then text .. string.rep(" ", width - #text)
				else string.rep(" ", width - #text) .. text
		end
		return text
	end
	local spec = "%" .. flags
	if not bigw and width > 0 then
		spec ..= tostring(width)
	end
	local body: string
	if bigp then
		-- integer / string precision > 99
		if conv == "s" then
			body = string.sub(value, 1, prec)
		else
			local digits = string.format("%" .. (if string.find(flags, "#", 1, true) then "#" else "") .. conv, value)
			local sign = ""
			local c1 = string.sub(digits, 1, 1)
			if c1 == "-" then
				sign, digits = "-", string.sub(digits, 2)
			elseif (conv == "d" or conv == "i") and string.find(flags, "+", 1, true) then
				sign = "+"
			elseif (conv == "d" or conv == "i") and string.find(flags, " ", 1, true) then
				sign = " "
			end
			local prefix = ""
			if string.sub(digits, 1, 2) == "0x" or string.sub(digits, 1, 2) == "0X" then
				prefix, digits = string.sub(digits, 1, 2), string.sub(digits, 3)
			end
			if #digits < prec then
				digits = string.rep("0", prec - #digits) .. digits
			end
			body = sign .. prefix .. digits
		end
		if not bigw and #body < width then
			body = if string.find(flags, "-", 1, true)
				then body .. string.rep(" ", width - #body)
				else string.rep(" ", width - #body) .. body
		end
	else
		if prec >= 0 then
			spec ..= "." .. tostring(prec)
		end
		body = string.format(spec .. conv, value)
	end
	if bigw and #body < width then
		local pad = width - #body
		if string.find(flags, "-", 1, true) then
			body ..= string.rep(" ", pad)
		elseif
			string.find(flags, "0", 1, true)
			and conv ~= "s"
			and conv ~= "c"
			and not (prec >= 0 and string.find("diouxX", conv, 1, true))
			and not string.find(body, "[inIN][naNA]")
		then
			-- zero padding goes after the sign and the 0x prefix
			local lead = string.match(body, "^[-+ ]?0[xX]") or string.match(body, "^[-+ ]?") or ""
			body = lead .. string.rep("0", pad) .. string.sub(body, #lead + 1)
		else
			body = string.rep(" ", pad) .. body
		end
	end
	return body
end

return libc
