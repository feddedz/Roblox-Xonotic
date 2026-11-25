--!strict
-- engine/utf8lib.luau + string builtins of engine/prvm_cmds.luau (prvm_cmds.c / utf8lib.c @xonotic-v0.8.6).
local t = require("../_lib/t")
local cvar = require("../../engine/cvar")
local utf8lib = require("../../engine/utf8lib")
local prvm_edict = require("../../engine/prvm_edict")
local prvm_cmds = require("../../engine/prvm_cmds")
local common = require("../../engine/common")
local f32 = require("../../engine/_port/f32")

return function(ctx: t.Ctx)
	cvar.reset()
	local u8 = cvar.static(cvar.CVAR_SAVE, "utf8_enable", "0", "")
	cvar.Cvar_RegisterVariable(u8)
	-- utf8_enable 0: bytes
	t.eq(ctx, utf8lib.u8_strlen("héllo"), 6, "strlen bytes when utf8 off")
	cvar.Cvar_SetQuick(u8, "1")
	t.eq(ctx, utf8lib.u8_strlen("héllo"), 5, "strlen chars when utf8 on")
	t.eq(ctx, utf8lib.u8_strlen("a\128b"), 2, "invalid byte skipped")
	t.eq(ctx, utf8lib.u8_bytelen("héllo", 1, 2), 3, "bytelen 2 chars")
	t.eq(ctx, (utf8lib.u8_byteofs("héllo", 2)), 3, "byteofs of 3rd char")
	t.eq(ctx, (utf8lib.u8_byteofs("ab", 5)), -1, "byteofs past end")
	t.eq(ctx, (utf8lib.u8_getchar_utf8_enabled("é", 1)), 0xE9, "decode")
	t.eq(ctx, utf8lib.u8_quake2utf8map(1), 0xE001)

	-- builtins on a bare prog
	local prog: any = prvm_edict.NewProg("server")
	prog.globals = buffer.create(4 * 64)
	prog.stringssize = 0
	local function setstr(i: number, s: string)
		buffer.writei32(prog.globals, (4 + 3 * i) * 4, prvm_edict.PRVM_SetTempString(prog, s))
	end
	local function setf(i: number, f: number)
		buffer.writef32(prog.globals, (4 + 3 * i) * 4, f)
	end
	local function rets(): string
		return prvm_edict.PRVM_GetString(prog, buffer.readi32(prog.globals, 4))
	end
	local function retf(): number
		return buffer.readf32(prog.globals, 4)
	end
	prog.argc = 3
	setstr(0, "foo")
	setstr(1, "bar")
	setstr(2, "baz")
	prvm_cmds.VM_strcat(prog)
	t.eq(ctx, rets(), "foobarbaz")
	prog.argc = 1
	setf(0, 3)
	prvm_cmds.VM_ftos(prog)
	t.eq(ctx, rets(), "3")
	setf(0, 0.5)
	prvm_cmds.VM_ftos(prog)
	t.eq(ctx, rets(), "0.500000")
	setf(0, 3e9)
	prvm_cmds.VM_ftos(prog)
	t.eq(ctx, rets(), "3000000000.000000", "(int) overflow takes the %f branch")
	setstr(0, " 2.5xyz")
	prvm_cmds.VM_stof(prog)
	t.eq(ctx, retf(), 2.5)
	setstr(0, "héllo")
	prvm_cmds.VM_strlen(prog)
	t.eq(ctx, retf(), 5)
	prog.argc = 3
	setstr(0, "héllo")
	setf(1, 1)
	setf(2, 2)
	prvm_cmds.VM_substring(prog)
	t.eq(ctx, rets(), "él")
	setf(1, -3)
	setf(2, -1)
	prvm_cmds.VM_substring(prog)
	t.eq(ctx, rets(), "llo", "negative start/length (FTE_STRINGS)")
	prog.argc = 1
	setstr(0, "zoned")
	prvm_cmds.VM_strzone(prog)
	local z = buffer.readi32(prog.globals, 4)
	t.eq(ctx, prvm_edict.PRVM_GetString(prog, z), "zoned")
	buffer.writei32(prog.globals, 16, z)
	prvm_cmds.VM_strunzone(prog)
	t.ok(ctx, not pcall(prvm_cmds.VM_strunzone, prog), "double free errors")
	prog.argc = 2
	setstr(0, "héllo")
	setf(1, 1)
	prvm_cmds.VM_str2chr(prog)
	t.eq(ctx, retf(), 0xE9)
	setstr(0, "abc")
	setstr(1, "abd")
	prvm_cmds.VM_strncmp(prog)
	t.eq(ctx, retf(), -1)
	prog.argc = 3
	setf(2, 2)
	prvm_cmds.VM_strncmp(prog)
	t.eq(ctx, retf(), 0)
	prog.argc = 1
	setf(0, -1.5)
	prvm_cmds.VM_floor(prog)
	t.eq(ctx, retf(), -2)
	-- string buffers
	prog.argc = 0
	prvm_cmds.VM_buf_create(prog)
	local b0 = retf()
	prvm_cmds.VM_buf_create(prog)
	t.eq(ctx, retf(), b0 + 1, "second buffer gets the next index")
	prog.argc = 3
	setf(0, b0)
	setf(1, 4)
	setstr(2, "four")
	prvm_cmds.VM_bufstr_set(prog)
	prog.argc = 1
	prvm_cmds.VM_buf_getsize(prog)
	t.eq(ctx, retf(), 5, "num_strings = highest index + 1")
	prog.argc = 2
	setf(1, 4)
	prvm_cmds.VM_bufstr_get(prog)
	t.eq(ctx, rets(), "four")
	setf(1, 2)
	prvm_cmds.VM_bufstr_get(prog)
	t.eq(ctx, buffer.readi32(prog.globals, 4), 0, "unset slot -> null string")
	prog.argc = 2
	setstr(1, "utf8")
	prvm_cmds.VM_buf_cvarlist(prog)
	prog.argc = 1
	prvm_cmds.VM_buf_getsize(prog)
	t.eq(ctx, retf(), 1, "cvarlist matched utf8_enable")
	prvm_cmds.VM_buf_del(prog)
	prvm_cmds.VM_buf_getsize(prog)
	t.eq(ctx, retf(), -1, "deleted buffer is invalid")
	prog.argc = 3
	setf(0, 1)
	setf(1, 5)
	setf(2, 3)
	prvm_cmds.VM_bound(prog)
	t.eq(ctx, retf(), 3, "bound(min, num, max)")
	setf(0, 5)
	setf(1, 1)
	prvm_cmds.VM_bound(prog)
	t.eq(ctx, retf(), 5, "below min -> min (mathlib.h macro order)")
	t.eq(ctx, common.CRC_Block("123456789"), 0x29B1, "CRC-16/CCITT check value")
	prog.argc = 3
	setstr(0, "ab")
	setstr(1, "X")
	setstr(2, "abcabc")
	prvm_cmds.VM_strreplace(prog)
	t.eq(ctx, rets(), "XcXc")
	prog.argc = 2
	setstr(0, "héllo world")
	setstr(1, "wor")
	prvm_cmds.VM_strstrofs(prog)
	t.eq(ctx, retf(), 6, "char offset (utf8)")
	prog.argc = 1
	setstr(0, "a b/é")
	prvm_cmds.VM_uri_escape(prog)
	t.eq(ctx, rets(), "a%20b%2F%C3%A9")
	setstr(0, "a%20b%2F%C3%A9%00x")
	prvm_cmds.VM_uri_unescape(prog)
	t.eq(ctx, rets(), "a b/éx", "%00 is not unescaped... and dropped")
	prog.argc = 3
	setf(0, 4)
	setf(1, -2)
	setf(2, 9)
	prvm_cmds.VM_max(prog)
	t.eq(ctx, retf(), 9)
	prvm_cmds.VM_min(prog)
	t.eq(ctx, retf(), -2)
	prog.argc = 1
	buffer.writef32(prog.globals, 16, 3)
	buffer.writef32(prog.globals, 20, 4)
	buffer.writef32(prog.globals, 24, 0)
	prvm_cmds.VM_vlen(prog)
	t.eq(ctx, retf(), 5, "vlen")
	setf(0, -2.5)
	prvm_cmds.VM_rint(prog)
	t.eq(ctx, retf(), -3, "rint rounds half away from zero")
	prog.argc = 2
	setstr(0, "ABC")
	setstr(1, "abd")
	prvm_cmds.VM_strncasecmp(prog)
	t.eq(ctx, retf(), -1)
	-- tokenizers
	prog.argc = 1
	setstr(0, ' set  "a b" c')
	prvm_cmds.VM_tokenize_console(prog)
	t.eq(ctx, retf(), 3, "tokenize_console count")
	setf(0, 1)
	prvm_cmds.VM_argv(prog)
	t.eq(ctx, rets(), "a b", "quoted token")
	prvm_cmds.VM_argv_start_index(prog)
	t.eq(ctx, retf(), 6)
	setf(0, -1)
	prvm_cmds.VM_argv(prog)
	t.eq(ctx, rets(), "c", "negative index from the end")
	prog.argc = 3
	setstr(0, "a,b;;c")
	setstr(1, ",")
	setstr(2, ";")
	prvm_cmds.VM_tokenizebyseparator(prog)
	t.eq(ctx, retf(), 4, "a | b | (empty) | c")
	prog.argc = 1
	setf(0, 2)
	prvm_cmds.VM_argv(prog)
	t.eq(ctx, rets(), "")
	setf(0, 3)
	prvm_cmds.VM_argv(prog)
	t.eq(ctx, rets(), "c")
	-- info strings
	t.eq(ctx, common.InfoString_GetValue("\\a\\1\\bb\\22", "bb", 100), "22")
	t.eq(ctx, common.InfoString_GetValue("\\a\\1", "x", 100), nil)
	t.eq(ctx, common.InfoString_SetValue("\\a\\1\\b\\2", 100, "a", "9"), "\\a\\9\\b\\2", "replace keeps order")
	t.eq(ctx, common.InfoString_SetValue("\\a\\1\\b\\2", 100, "a", ""), "\\b\\2", "empty value removes the key")
	t.eq(ctx, common.InfoString_SetValue("", 100, "c", "3"), "\\c\\3")
	-- case conversion (utf8_enable 1: Unicode tables of utf8lib.c; 0: ASCII only)
	prog.argc = 1
	setstr(0, "Héllo Wörld ÿ")
	prvm_cmds.VM_strtoupper(prog)
	t.eq(ctx, rets(), "HÉLLO WÖRLD Ÿ", "u8_toupper")
	prvm_cmds.VM_strtolower(prog)
	setstr(0, "ÀÉ ΣΩ ABC")
	prvm_cmds.VM_strtolower(prog)
	t.eq(ctx, rets(), "àé σω abc", "u8_tolower")
	setstr(0, "a\128b")
	prvm_cmds.VM_strtoupper(prog)
	t.eq(ctx, rets(), "AB", "invalid byte skipped by u8_getchar")
	t.eq(ctx, common.COM_ToUpperString("abcdef", 4), "ABC", "size_out caps")
	t.eq(ctx, common.COM_ToUpperString("aéb", 3), "A", "multibyte char that does not fit stops")
	t.eq(ctx, utf8lib.u8_fromchar(0x1F600, 8), 4)
	cvar.Cvar_SetQuick(u8, "0")
	setstr(0, "Héllo")
	prvm_cmds.VM_strtoupper(prog)
	t.eq(ctx, rets(), "HéLLO", "utf8 off: ASCII only")
	cvar.Cvar_SetQuick(u8, "1")
	-- search_*
	local fs = require("../../engine/fs")
	fs.SetProvider({
		files = { "maps/b.bsp", "maps/a.bsp", "maps/a.mapinfo" },
		load = function(_: string): string?
			return nil
		end,
	} :: any)
	prog.name = "server"
	prog.argc = 3
	setstr(0, "maps/*.bsp")
	setf(1, 1)
	setf(2, 1)
	prvm_cmds.VM_search_begin(prog)
	t.eq(ctx, retf(), 0, "first handle")
	local h = retf()
	setstr(0, "nothing*")
	prvm_cmds.VM_search_begin(prog)
	t.eq(ctx, retf(), -1, "no match -> -1")
	prog.argc = 1
	setf(0, h)
	prvm_cmds.VM_search_getsize(prog)
	t.eq(ctx, retf(), 2)
	prog.argc = 2
	setf(1, 0)
	prvm_cmds.VM_search_getfilename(prog)
	t.eq(ctx, rets(), "maps/a.bsp", "sorted")
	prog.argc = 1
	prvm_cmds.VM_search_end(prog)
	buffer.writef32(prog.globals, 4, 123)
	prvm_cmds.VM_search_getsize(prog)
	t.eq(ctx, retf(), 123, "closed handle: warning, return untouched")
	-- digest_hex (RFC 1320 / FIPS 180-2 vectors)
	local mdfour = require("../../engine/mdfour")
	local function hex(x: string): string
		return (string.gsub(x, ".", function(c: string): string
			return string.format("%02x", string.byte(c))
		end))
	end
	t.eq(ctx, hex(mdfour.mdfour("")), "31d6cfe0d16ae931b73c59d7e0c089c0")
	t.eq(ctx, hex(mdfour.mdfour("abc")), "a448017aaf21d8525fc10ae87aa6729d")
	t.eq(ctx, hex(mdfour.mdfour(string.rep("1234567890", 8))), "e33b4ddc9c38f2199c3e7b164fcc0536")
	prog.argc = 2
	setstr(0, "MD4")
	setstr(1, "message digest")
	prvm_cmds.VM_digest_hex(prog)
	t.eq(ctx, rets(), "d9130a8164549fe818874806e1c7014b")
	setstr(0, "SHA256")
	setstr(1, "abc")
	prvm_cmds.VM_digest_hex(prog)
	t.eq(ctx, rets(), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
	setstr(1, string.rep("a", 1000))
	prvm_cmds.VM_digest_hex(prog)
	t.eq(ctx, rets(), "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
	setstr(0, "MD5")
	prvm_cmds.VM_digest_hex(prog)
	t.eq(ctx, buffer.readi32(prog.globals, 4), 0, "unknown digest -> string_null")
	-- fopen / fgets / fputs / fclose
	fs.realfiles = {}
	prog.argc = 2
	setstr(0, "x.txt")
	setf(1, 2) -- FILE_WRITE
	prvm_cmds.VM_fopen(prog)
	local wh = retf()
	t.eq(ctx, wh, 0)
	setf(0, wh)
	setstr(1, "line1\r\nline2\rline3\n")
	prvm_cmds.VM_fputs(prog)
	prog.argc = 1
	prvm_cmds.VM_fclose(prog)
	t.eq(ctx, fs.realfiles["data/x.txt"], "line1\r\nline2\rline3\n", "written under data/")
	prog.argc = 2
	setstr(0, "x.txt")
	setf(1, 0)
	prvm_cmds.VM_fopen(prog)
	local rh = retf()
	prog.argc = 1
	setf(0, rh)
	local got = {}
	for _ = 1, 4 do
		prvm_cmds.VM_fgets(prog)
		table.insert(got, if buffer.readi32(prog.globals, 4) == 0 then "<null>" else rets())
	end
	t.eq(ctx, table.concat(got, "|"), "line1|line2|line3|<null>", "CR, CRLF, LF; EOF -> string_null")
	prvm_cmds.VM_fclose(prog)
	prog.argc = 2
	setstr(0, "missing.txt")
	setf(1, 0)
	prvm_cmds.VM_fopen(prog)
	t.eq(ctx, retf(), -1)
	setf(1, 7)
	prvm_cmds.VM_fopen(prog)
	t.eq(ctx, retf(), -3, "bad mode")
	setstr(0, "maps/a.mapinfo")
	setf(1, 0)
	prvm_cmds.VM_fopen(prog)
	t.eq(ctx, retf(), -1, "provider load returns nil here")
	fs.realfiles = {}
	-- checkextension / random / whichpack
	prog.extensionstring = require("../../engine/_port/extensions").sv
	prog.argc = 1
	setstr(0, "dp_qc_strftime")
	prvm_cmds.VM_checkextension(prog)
	t.eq(ctx, retf(), 1, "case-insensitive")
	setstr(0, "DP_QC_STR")
	prvm_cmds.VM_checkextension(prog)
	t.eq(ctx, retf(), 0, "whole words only")
	local libc = require("../../engine/_port/libc")
	libc.srand(0)
	prog.argc = 0
	prvm_cmds.VM_random(prog)
	t.eq(ctx, retf(), f32.round((1804289383 + 0.5) / 2147483648), "lhrandom on glibc rand")
	prog.argc = 1
	fs.realfiles["data/w.txt"] = "x"
	setstr(0, "data/w.txt")
	buffer.writei32(prog.globals, 4, 0)
	prvm_cmds.VM_whichpack(prog)
	t.eq(ctx, buffer.readi32(prog.globals, 4) ~= 0 and rets() == "", true, "written file: found, not in a pack")
	fs.realfiles = {}
	setstr(0, "maps/zzz.bsp")
	prvm_cmds.VM_whichpack(prog)
	t.eq(ctx, buffer.readi32(prog.globals, 4), 0, "not found -> string_null")
	-- sprintf (utf8_enable 1)
	local function sp(fmt: string, ...: any): string
		local args = { ... }
		prog.argc = 1 + #args
		setstr(0, fmt)
		for k, a in args do
			if type(a) == "string" then
				setstr(k, a)
			elseif type(a) == "table" then
				for q = 0, 2 do
					buffer.writef32(prog.globals, (4 + 3 * k + q) * 4, a[q + 1])
				end
			else
				setf(k, a)
			end
		end
		prvm_cmds.VM_sprintf(prog)
		return rets()
	end
	t.eq(ctx, sp("%d|%5.2f|%s|%-4s|", 3.7, 3.14159, "ab", "x"), "3| 3.14|ab|x   |")
	t.eq(ctx, sp("%i", 1), "1065353216", "%i reads the argument's int bits")
	t.eq(ctx, sp("%x|%X", -1, 255), "ffffffffffffffff|FF")
	t.eq(ctx, sp("%v", { 1, 2.5, -3 }), "1 2.5 -3")
	t.eq(ctx, sp("%3$s %1$s", "a", "b", "c"), "c a", "positional")
	t.eq(ctx, sp("[%*d]", 4, 7), "[   7]", "width from argument")
	t.eq(ctx, sp("[%*d]", -4, 7), "[7   ]", "negative width: left")
	t.eq(ctx, sp("[%5s]", "^1ab"), "[   ^1ab]", "color codes do not count")
	t.eq(ctx, sp("[%+5s]", "^1ab"), "[ ^1ab]", "+ flag: color codes count")
	t.eq(ctx, sp("[%-3s]", "é"), "[é  ]", "width in characters")
	t.eq(ctx, sp("%c%c", 65, 233), "Aé")
	t.eq(ctx, sp("100%% %.3s", "abcdef"), "100% abc")
	t.eq(ctx, sp("a%qb", 1), "a", "invalid directive stops")
	t.eq(ctx, sp("%05.1f|%+d|% d", -2.25, 5, 5), "-02.2|+5| 5")
	t.eq(ctx, sp("%s|%d", "only"), "only|0", "missing argument -> 0")
	t.eq(ctx, sp("%e", 1e10), "1.000000e+10")
	-- strdecolorize (escape_carets)
	prog.argc = 1
	setstr(0, "^1red ^x0F0green ^^caret ^q ^xZZ end^")
	prvm_cmds.VM_strdecolorize(prog)
	t.eq(ctx, rets(), "red green ^^caret ^q ^^xZZ end^^")
	t.eq(ctx, select(2, common.COM_StringDecolorize("^1abc", 0, 3, false)), "ab", "out of room")
	-- math / vector builtins
	local function vecret(): string
		return string.format(
			"%g %g %g",
			buffer.readf32(prog.globals, 4),
			buffer.readf32(prog.globals, 8),
			buffer.readf32(prog.globals, 12)
		)
	end
	prog.argc = 2
	setf(0, 1)
	setf(1, 4)
	prvm_cmds.VM_bitshift(prog)
	t.eq(ctx, retf(), 16)
	setf(0, -12)
	setf(1, -2)
	prvm_cmds.VM_bitshift(prog)
	t.eq(ctx, retf(), 3, "fabs of the int first")
	setf(0, 1)
	setf(1, 33)
	prvm_cmds.VM_bitshift(prog)
	t.eq(ctx, retf(), 2, "x86 shift count & 31")
	prog.argc = 1
	setstr(0, "'1 -2.5 3e2'")
	prvm_cmds.VM_stov(prog)
	t.eq(ctx, vecret(), "1 -2.5 300")
	setstr(0, "4 x 5")
	prvm_cmds.VM_stov(prog)
	t.eq(ctx, vecret(), "4 0 0", "stops at a non-number")
	for k = 0, 2 do
		buffer.writef32(prog.globals, (4 + k) * 4, ({ 1, -22.25, 333 })[k + 1])
	end
	prvm_cmds.VM_vtos(prog)
	t.eq(ctx, rets(), "'  1.0 -22.2 333.0'")
	for k = 0, 2 do
		buffer.writef32(prog.globals, (4 + k) * 4, ({ 0, -5, 0 })[k + 1])
	end
	prvm_cmds.VM_vectoyaw(prog)
	t.eq(ctx, retf(), 270)
	prvm_cmds.VM_normalize(prog)
	t.eq(ctx, vecret(), "0 -1 0")
	setstr(0, "^1ab^^c^x123d^")
	prvm_cmds.VM_strlennocol(prog)
	t.eq(ctx, retf(), 6, "a b ^ c d + unfinished ^")
	setstr(0, "é^2é")
	prvm_cmds.VM_strlennocol(prog)
	t.eq(ctx, retf(), 2)
	prog.argc = 3
	setf(0, 72)
	setf(1, 0xE9)
	setf(2, 0x263A)
	prvm_cmds.VM_chr2str(prog)
	t.eq(ctx, rets(), "Hé☺")
	prog.argc = 2
	setf(0, 1)
	setf(1, -1)
	prvm_cmds.VM_atan2(prog)
	t.eq(ctx, retf(), f32.round(math.atan2(1, -1)))
	-- string buffers: add / sort / implode / find / free / copy; matchpattern
	prog.argc = 0
	prvm_cmds.VM_buf_create(prog)
	local bh = retf()
	local function add(str: string, order: number)
		prog.argc = 3
		setf(0, bh)
		setstr(1, str)
		setf(2, order)
		prvm_cmds.VM_bufstr_add(prog)
	end
	add("pear", 1)
	add("apple", 1)
	add("", 1)
	add("fig", 1)
	t.eq(ctx, retf(), 3, "appended at index 3")
	local function implode(sep: string): string
		prog.argc = 2
		setf(0, bh)
		setstr(1, sep)
		prvm_cmds.VM_buf_implode(prog)
		return rets()
	end
	t.eq(ctx, implode(","), ",pear,apple,,fig", "separator before every string, the first too")
	prog.argc = 3
	setf(0, bh)
	setf(1, 0)
	setf(2, 0)
	prvm_cmds.VM_buf_sort(prog)
	t.eq(ctx, implode("|"), "|apple|fig|pear|", "ascending, empty last")
	local function find(pat: string, rule: number): number
		prog.argc = 3
		setf(0, bh)
		setstr(1, pat)
		setf(2, rule)
		prvm_cmds.VM_bufstr_find(prog)
		return retf()
	end
	t.eq(ctx, find("fig", 0), 1, "whole")
	t.eq(ctx, find("*ple", 0), 0, "right")
	t.eq(ctx, find("p?ar", 0), 2, "pattern")
	t.eq(ctx, find("pe", 2), 2, "left (explicit rule)")
	t.eq(ctx, find("zz", 0), -1)
	prog.argc = 2
	setf(0, bh)
	setf(1, 1)
	prvm_cmds.VM_bufstr_free(prog)
	add("kiwi", 0)
	t.eq(ctx, retf(), 1, "order 0 fills the first hole")
	prog.argc = 2
	setf(0, bh)
	setf(1, bh + 1)
	prvm_cmds.VM_buf_copy(prog)
	t.eq(ctx, implode("|"), "", "buf_copy empties the source (C reads PARM0 as destination)")
	local function mp(str: string, pat: string, rule: number, ofs: number?): number
		prog.argc = if ofs then 4 else 3
		setstr(0, str)
		setstr(1, pat)
		setf(2, rule)
		if ofs then
			setf(3, ofs)
		end
		prvm_cmds.VM_matchpattern(prog)
		return retf()
	end
	t.eq(ctx, mp("hello world", "hello*", 0), 1, "x* -> pattern rule")
	t.eq(ctx, mp("hello world", "*world", 0), 1)
	t.eq(ctx, mp("hello world", "world", 0, 6), 1, "offset")
	t.eq(ctx, mp("hello", "ell", 4), 1, "middle")
	-- tokenize (VM parser: quotes, separators, comments)
	prog.argc = 1
	setstr(0, "a 'b c' {x:y} // gone")
	prvm_cmds.VM_tokenize(prog)
	t.eq(ctx, retf(), 7, "a, b c, {, x, :, y, }")
	setf(0, 1)
	prvm_cmds.VM_argv(prog)
	t.eq(ctx, rets(), "b c")
	-- strpad / strconv / strireplace
	prog.argc = 2
	setf(0, 5)
	setstr(1, "ab")
	prvm_cmds.VM_strpad(prog)
	t.eq(ctx, rets(), "ab   ", "> 0 = right padding")
	setf(0, -5)
	prvm_cmds.VM_strpad(prog)
	t.eq(ctx, rets(), "   ab", "< 0 = left padding")
	prog.argc = 4
	setf(0, 2)
	setf(1, 0)
	setf(2, 0)
	setstr(3, "abc1!")
	prvm_cmds.VM_strconv(prog)
	t.eq(ctx, rets(), "ABC1!", "upper")
	setf(0, 0)
	setf(1, 2)
	setf(2, 2)
	setstr(3, "a1")
	prvm_cmds.VM_strconv(prog)
	t.eq(ctx, rets(), string.char(97 + 128, 49 + 128), "red alpha / red numbers")
	prog.argc = 3
	setstr(0, "WORLD")
	setstr(1, "there")
	setstr(2, "hello world, World")
	prvm_cmds.VM_strireplace(prog)
	t.eq(ctx, rets(), "hello there, there")
	-- buf_writefile -> buf_loadfile round trip
	fs.realfiles = {}
	prog.argc = 0
	prvm_cmds.VM_buf_create(prog)
	local wb = retf()
	for _, line in { "one", "two" } do
		prog.argc = 3
		setf(0, wb)
		setstr(1, line)
		setf(2, 1)
		prvm_cmds.VM_bufstr_add(prog)
	end
	prog.argc = 2
	setstr(0, "lines.txt")
	setf(1, 2)
	prvm_cmds.VM_fopen(prog)
	local fh = retf()
	setf(0, fh)
	setf(1, wb)
	prvm_cmds.VM_buf_writefile(prog)
	prog.argc = 1
	prvm_cmds.VM_fclose(prog)
	t.eq(ctx, fs.realfiles["data/lines.txt"], "one\ntwo\n")
	prog.argc = 0
	prvm_cmds.VM_buf_create(prog)
	local rb = retf()
	prog.argc = 2
	setstr(0, "lines.txt")
	setf(1, rb)
	prvm_cmds.VM_buf_loadfile(prog)
	t.eq(ctx, retf(), 1)
	setf(0, rb)
	setstr(1, ",")
	prvm_cmds.VM_buf_implode(prog)
	t.eq(ctx, rets(), ",one,two")
	fs.realfiles = {}
	fs.SetProvider(nil)
	cvar.reset()
end
