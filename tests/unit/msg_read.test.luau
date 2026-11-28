--!strict
-- The common.c message readers (engine/common.luau MSG_Read*) against the writers: round trips for edge values,
-- sign extension, coordinate / angle quantisation, NaN bits, high-byte strings, MSG_ReadString's maxstring
-- truncation, and reads past the end (badread set, -1 returned, as the C functions and macros do).
-- Expectations derived from common.c L405-577 / common.h L178-182 (no C reference vectors yet).
local t = require("../_lib/t")
local common = require("../../engine/common")
local f32 = require("../../engine/_port/f32")

local R = f32.round
local P = common.PROTOCOL

local function fbits(v: number): number
	local b = buffer.create(4)
	buffer.writef32(b, 0, v)
	return buffer.readu32(b, 0)
end
local function frombits(u: number): number
	local b = buffer.create(4)
	buffer.writeu32(b, 0, u)
	return buffer.readf32(b, 0)
end
local function reader(sb: common.SizeBuf): common.SizeBuf
	common.MSG_BeginReading(sb)
	return sb
end

return function(ctx: t.Ctx)
	-- bytes / chars
	do
		local sb = common.SZ_New(64)
		for _, v in { 0, 1, 127, 128, 255, -1, -128, 256 + 5 } do
			common.MSG_WriteByte(sb, v)
		end
		reader(sb)
		t.eq(ctx, sb.readcount, 0, "MSG_BeginReading: readcount 0")
		t.eq(ctx, sb.badread, false, "MSG_BeginReading: badread false")
		local want = { 0, 1, 127, 128, 255, 255, 128, 5 }
		for i, w in want do
			t.eq(ctx, common.MSG_ReadByte(sb), w, "MSG_ReadByte " .. i)
		end
		t.eq(ctx, common.MSG_ReadByte(sb), -1, "MSG_ReadByte past the end: -1")
		t.eq(ctx, sb.badread, true, "MSG_ReadByte past the end: badread")
		t.eq(ctx, sb.readcount, 8, "readcount not advanced past the end")
		reader(sb)
		local wantc = { 0, 1, 127, -128, -1, -1, -128, 5 }
		for i, w in wantc do
			t.eq(ctx, common.MSG_ReadChar(sb), w, "MSG_ReadChar (signed char) " .. i)
		end
		t.eq(ctx, common.MSG_ReadChar(sb), -1, "MSG_ReadChar past the end")
		t.eq(ctx, sb.badread, true, "MSG_ReadChar past the end: badread")
	end

	-- a sizebuf the writers made without MSG_BeginReading (readcount / badread nil = 0 / false)
	do
		local sb = common.SZ_New(4)
		common.MSG_WriteShort(sb, -2)
		t.eq(ctx, common.MSG_ReadShort(sb), -2, "reading a fresh written sizebuf starts at 0")
	end

	-- shorts
	do
		local sb = common.SZ_New(64)
		local vals = { 0, 1, -1, 32767, -32768, 32768, 65535, -12345 }
		local want = { 0, 1, -1, 32767, -32768, -32768, -1, -12345 }
		for _, v in vals do
			common.MSG_WriteShort(sb, v)
		end
		reader(sb)
		for i, w in want do
			t.eq(ctx, common.MSG_ReadShort(sb), w, "MSG_ReadShort (short) " .. i)
		end
		t.eq(ctx, common.MSG_ReadShort(sb), -1, "MSG_ReadShort past the end: -1")
		t.ok(ctx, sb.badread, "MSG_ReadShort past the end: badread")
		-- one byte left: still a bad read (readcount+2 > cursize) and readcount unchanged
		local sb1 = common.SZ_New(3)
		common.MSG_WriteShort(sb1, 7)
		common.MSG_WriteByte(sb1, 9)
		reader(sb1)
		common.MSG_ReadShort(sb1)
		t.eq(ctx, common.MSG_ReadShort(sb1), -1, "MSG_ReadShort with one byte left: -1")
		t.eq(ctx, sb1.readcount, 2, "readcount unchanged by a bad short")
		t.eq(ctx, common.MSG_ReadByte(sb1), 9, "the byte is still there")
		-- big endian
		local sb2 = common.SZ_New(8)
		common.MSG_WriteByte(sb2, 0x80)
		common.MSG_WriteByte(sb2, 0x01)
		common.MSG_WriteByte(sb2, 0x12)
		common.MSG_WriteByte(sb2, 0x34)
		reader(sb2)
		t.eq(ctx, common.MSG_ReadBigShort(sb2), -32767, "MSG_ReadBigShort 0x8001")
		t.eq(ctx, common.MSG_ReadBigShort(sb2), 0x1234, "MSG_ReadBigShort 0x1234")
		t.eq(ctx, common.MSG_ReadBigShort(sb2), -1, "MSG_ReadBigShort past the end")
	end

	-- longs
	do
		local sb = common.SZ_New(64)
		local vals = { 0, 1, -1, 2147483647, -2147483648, 0x80000000, 0xFFFFFFFF, 123456789 }
		local want = { 0, 1, -1, 2147483647, -2147483648, -2147483648, -1, 123456789 }
		for _, v in vals do
			common.MSG_WriteLong(sb, v)
		end
		reader(sb)
		for i, w in want do
			t.eq(ctx, common.MSG_ReadLong(sb), w, "MSG_ReadLong (int) " .. i)
		end
		t.eq(ctx, common.MSG_ReadLong(sb), -1, "MSG_ReadLong past the end")
		local sb2 = common.SZ_New(8)
		for _, b in { 0xFF, 0x00, 0x00, 0x01, 0x12, 0x34, 0x56, 0x78 } do
			common.MSG_WriteByte(sb2, b)
		end
		reader(sb2)
		t.eq(ctx, common.MSG_ReadBigLong(sb2), -16777215, "MSG_ReadBigLong 0xFF000001 (sign bit wraps)")
		t.eq(ctx, common.MSG_ReadBigLong(sb2), 0x12345678, "MSG_ReadBigLong 0x12345678")
		t.eq(ctx, common.MSG_ReadBigLong(sb2), -1, "MSG_ReadBigLong past the end")
	end

	-- floats, NaN bits
	do
		local sb = common.SZ_New(64)
		local qnan = 0x7FC12345
		local vals = { 0, -0.0, 1.5, R(0.1), 3.4028234663852886e38, math.huge, -math.huge, frombits(qnan) }
		for _, v in vals do
			common.MSG_WriteFloat(sb, v)
		end
		reader(sb)
		for i, v in vals do
			local got = common.MSG_ReadFloat(sb)
			t.eq(ctx, fbits(got), fbits(v), "MSG_ReadFloat bits " .. i)
		end
		t.eq(ctx, common.MSG_ReadFloat(sb), -1, "MSG_ReadFloat past the end: -1")
		t.ok(ctx, sb.badread, "MSG_ReadFloat past the end: badread")
		-- big-endian float
		local sb2 = common.SZ_New(8)
		local u = fbits(-2.75)
		for k = 3, 0, -1 do
			common.MSG_WriteByte(sb2, bit32.band(bit32.rshift(u, k * 8), 0xFF))
		end
		reader(sb2)
		t.eq(ctx, common.MSG_ReadBigFloat(sb2), -2.75, "MSG_ReadBigFloat")
		t.eq(ctx, common.MSG_ReadBigFloat(sb2), -1, "MSG_ReadBigFloat past the end")
	end

	-- strings
	do
		local sb = common.SZ_New(256)
		local hi = "caf\233 \255\128^1x"
		common.MSG_WriteString(sb, hi)
		common.MSG_WriteString(sb, "")
		common.MSG_WriteString(sb, "abcdefgh")
		common.MSG_WriteString(sb, "after")
		common.MSG_WriteUnterminatedString(sb, "tail")
		reader(sb)
		t.eq(ctx, common.MSG_ReadString(sb, 16384), hi, "MSG_ReadString high bytes")
		t.eq(ctx, common.MSG_ReadString(sb, 16384), "", "MSG_ReadString empty")
		t.eq(ctx, common.MSG_ReadString(sb, 5), "abcd", "MSG_ReadString keeps maxstring - 1 characters")
		t.eq(ctx, common.MSG_ReadString(sb, 16384), "after", "... and consumed the rest of that string")
		t.eq(ctx, sb.badread, false, "no badread so far")
		t.eq(ctx, common.MSG_ReadString(sb, 16384), "tail", "unterminated string at the end is returned")
		t.eq(ctx, sb.badread, true, "unterminated string at the end sets badread")
		t.eq(ctx, common.MSG_ReadString(sb, 16384), "", "reading a string past the end: empty")
	end

	-- bytes
	do
		local sb = common.SZ_New(8)
		common.SZ_Write(sb, "\1\2\3")
		reader(sb)
		local out = buffer.create(8)
		t.eq(ctx, common.MSG_ReadBytes(sb, 2, out), 2, "MSG_ReadBytes 2")
		t.eq(ctx, buffer.readstring(out, 0, 2), "\1\2", "MSG_ReadBytes data")
		t.eq(ctx, common.MSG_ReadBytes(sb, 5, out), 1, "MSG_ReadBytes stops at the end")
		t.eq(ctx, buffer.readu8(out, 0), 3, "MSG_ReadBytes last byte")
		t.ok(ctx, sb.badread, "MSG_ReadBytes past the end: badread")
	end

	-- coords
	do
		local sb = common.SZ_New(256)
		local cs = { 0, 4096, -4096, 4095.875, -4095.875, 0.0625, -0.0625, 100.3 }
		for _, c in cs do
			common.MSG_WriteCoord13i(sb, c)
		end
		reader(sb)
		local want13 = { 0, -4096, -4096, 4095.875, -4095.875, 0.125, -0.125, 100.25 }
		-- 4096 * 8 = 32768 wraps to -32768 as a short: -4096 (engine limit of the old protocols)
		for i, w in want13 do
			t.eq(ctx, common.MSG_ReadCoord13i(sb), w, "MSG_ReadCoord13i " .. i)
		end
		t.eq(ctx, common.MSG_ReadCoord13i(sb), -0.125, "MSG_ReadCoord13i past the end: -1 * (1.0/8.0)")

		common.SZ_Clear(sb)
		local c16 = { 0, 4096, -4096, 32767, -32768, 0.5, -0.5, 1.49 }
		for _, c in c16 do
			common.MSG_WriteCoord16i(sb, c)
		end
		reader(sb)
		local want16 = { 0, 4096, -4096, 32767, -32768, 1, -1, 1 }
		for i, w in want16 do
			t.eq(ctx, common.MSG_ReadCoord16i(sb), w, "MSG_ReadCoord16i " .. i)
		end
		t.eq(ctx, common.MSG_ReadCoord16i(sb), -1, "MSG_ReadCoord16i past the end: -1")

		common.SZ_Clear(sb)
		local v = { R(1234.5678), -4096, 4096 }
		common.MSG_WriteVector(sb, v, P.DARKPLACES7)
		common.MSG_WriteVector(sb, v, P.QUAKE)
		common.MSG_WriteVector(sb, v, P.DARKPLACES4)
		common.MSG_WriteVector(sb, v, P.DARKPLACES1)
		reader(sb)
		local out = { 0, 0, 0 }
		common.MSG_ReadVector(sb, out, P.DARKPLACES7)
		t.eq(ctx, out[1], v[1], "MSG_ReadVector DP7: 32 bit float")
		t.eq(ctx, out[3], 4096, "MSG_ReadVector DP7: 4096")
		common.MSG_ReadVector(sb, out, P.QUAKE)
		t.eq(ctx, out[1], 1234.625, "MSG_ReadVector QUAKE: 13.3 fixed point")
		t.eq(ctx, out[2], -4096, "MSG_ReadVector QUAKE: -4096")
		common.MSG_ReadVector(sb, out, P.DARKPLACES4)
		t.eq(ctx, out[1], 1235, "MSG_ReadVector DP4: 16 bit integer")
		common.MSG_ReadVector(sb, out, P.DARKPLACES1)
		t.eq(ctx, out[1], v[1], "MSG_ReadVector DP1: 32 bit float")
		t.eq(ctx, sb.readcount, sb.cursize, "all coordinates consumed")
	end

	-- angles
	do
		local sb = common.SZ_New(256)
		local a8 = { 0, 90, 180, -90, 359, 360, -180, 1.40625 }
		for _, a in a8 do
			common.MSG_WriteAngle8i(sb, a)
		end
		reader(sb)
		-- (signed char) * (360/256): 180 -> -128 -> -180, 359 -> 255 -> -1 -> -1.40625, 360 wraps to 0
		local want8 = { 0, 90, -180, -90, -1.40625, 0, -180, 1.40625 }
		for i, w in want8 do
			t.eq(ctx, common.MSG_ReadAngle8i(sb), w, "MSG_ReadAngle8i " .. i)
		end
		t.eq(ctx, common.MSG_ReadAngle8i(sb), -1.40625, "MSG_ReadAngle8i past the end: (signed char)-1")

		common.SZ_Clear(sb)
		local a16 = { 0, 90, 180, -90, 359.99, 360, 720.5, -0.01 }
		for _, a in a16 do
			common.MSG_WriteAngle16i(sb, a)
		end
		reader(sb)
		local step = 360.0 / 65536.0
		local want16 = { 0, 90, -180, -90, R(-2 * step), 0, R(91 * step), R(-2 * step) }
		for i, w in want16 do
			t.eq(ctx, common.MSG_ReadAngle16i(sb), w, "MSG_ReadAngle16i " .. i)
		end

		common.SZ_Clear(sb)
		common.MSG_WriteAngle(sb, 45, P.DARKPLACES7)
		common.MSG_WriteAngle(sb, 45, P.DARKPLACES4)
		common.MSG_WriteAngle32f(sb, R(12.34))
		reader(sb)
		t.eq(ctx, common.MSG_ReadAngle(sb, P.DARKPLACES7), 45, "MSG_ReadAngle DP7: 16 bit")
		t.eq(ctx, sb.readcount, 2, "DP7 angle is 2 bytes")
		t.eq(ctx, common.MSG_ReadAngle(sb, P.DARKPLACES4), 45, "MSG_ReadAngle DP4: 8 bit")
		t.eq(ctx, sb.readcount, 3, "DP4 angle is 1 byte")
		t.eq(ctx, common.MSG_ReadAngle32f(sb), R(12.34), "MSG_ReadAngle32f")
	end

	-- MSG_InitReadBuffer
	do
		local data = buffer.create(3)
		buffer.writeu8(data, 0, 4)
		buffer.writeu16(data, 1, 0xFFFE)
		local sb: any = {}
		common.MSG_InitReadBuffer(sb, data, 3)
		t.eq(ctx, sb.cursize, 3, "MSG_InitReadBuffer cursize")
		t.eq(ctx, sb.maxsize, 3, "MSG_InitReadBuffer maxsize")
		t.eq(ctx, common.MSG_ReadByte(sb), 4, "MSG_InitReadBuffer data")
		t.eq(ctx, common.MSG_ReadShort(sb), -2, "MSG_InitReadBuffer short")
		t.eq(ctx, common.MSG_ReadByte(sb), -1, "end of the read buffer")
	end
end
