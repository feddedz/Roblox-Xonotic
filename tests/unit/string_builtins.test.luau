--!strict
-- engine/utf8lib.luau + string builtins of engine/prvm_cmds.luau (prvm_cmds.c / utf8lib.c @xonotic-v0.8.6).
local t = require("../_lib/t")
local cvar = require("../../engine/cvar")
local utf8lib = require("../../engine/utf8lib")
local prvm_edict = require("../../engine/prvm_edict")
local prvm_cmds = require("../../engine/prvm_cmds")
local common = require("../../engine/common")

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
	fs.SetProvider(nil)
	cvar.reset()
end
