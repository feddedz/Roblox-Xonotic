--!strict
-- engine/utf8lib.luau + string builtins of engine/prvm_cmds.luau (prvm_cmds.c / utf8lib.c @xonotic-v0.8.6).
local t = require("../_lib/t")
local cvar = require("../../engine/cvar")
local utf8lib = require("../../engine/utf8lib")
local prvm_edict = require("../../engine/prvm_edict")
local prvm_cmds = require("../../engine/prvm_cmds")

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
	cvar.reset()
end
