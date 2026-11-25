--!strict
--[[
	mdfour.c

	An implementation of MD4 designed for use in the samba SMB
	authentication protocol

	Copyright (C) 1997-1998  Andrew Tridgell

	This program is free software; you can redistribute it and/or
	modify it under the terms of the GNU General Public License
	as published by the Free Software Foundation; either version 2
	of the License, or (at your option) any later version.

	MD4-based checksum utility functions
	Copyright (C) 2000       Jeff Teunissen <d2deek@pmail.net>
]]
--[[
	Port of mdfour.c @xonotic-v0.8.6 (whole file). uint32 arithmetic is kept in [0, 2^32) with bit32.
	The input is a Lua string (bytes); the 16-byte digest is returned as a string.
]]
local mdfour = {}

local band, bor, bxor, bnot, lrotate = bit32.band, bit32.bor, bit32.bxor, bit32.bnot, bit32.lrotate

local function F(x: number, y: number, z: number): number
	return bor(band(x, y), band(bnot(x), z))
end
local function G(x: number, y: number, z: number): number
	return bor(band(x, y), band(x, z), band(y, z))
end
local function H(x: number, y: number, z: number): number
	return bxor(x, y, z)
end

type MD = { A: number, B: number, C: number, D: number, totalN: number }

-- port: mdfour.c mdfour64 L54-105 @xonotic-v0.8.6
local function mdfour64(md: MD, X: { number })
	local A, B, C, D = md.A, md.B, md.C, md.D
	local AA, BB, CC, DD = A, B, C, D
	local function R1(a: number, b: number, c: number, d: number, k: number, s: number): number
		return lrotate((a + F(b, c, d) + X[k + 1]) % 4294967296, s)
	end
	local function R2(a: number, b: number, c: number, d: number, k: number, s: number): number
		return lrotate((a + G(b, c, d) + X[k + 1] + 0x5A827999) % 4294967296, s)
	end
	local function R3(a: number, b: number, c: number, d: number, k: number, s: number): number
		return lrotate((a + H(b, c, d) + X[k + 1] + 0x6ED9EBA1) % 4294967296, s)
	end
	for _, k in { 0, 4, 8, 12 } do
		A = R1(A, B, C, D, k, 3)
		D = R1(D, A, B, C, k + 1, 7)
		C = R1(C, D, A, B, k + 2, 11)
		B = R1(B, C, D, A, k + 3, 19)
	end
	for _, k in { 0, 1, 2, 3 } do
		A = R2(A, B, C, D, k, 3)
		D = R2(D, A, B, C, k + 4, 5)
		C = R2(C, D, A, B, k + 8, 9)
		B = R2(B, C, D, A, k + 12, 13)
	end
	for _, k in { 0, 2, 1, 3 } do
		A = R3(A, B, C, D, k, 3)
		D = R3(D, A, B, C, k + 8, 9)
		C = R3(C, D, A, B, k + 4, 11)
		B = R3(B, C, D, A, k + 12, 15)
	end
	md.A = (A + AA) % 4294967296
	md.B = (B + BB) % 4294967296
	md.C = (C + CC) % 4294967296
	md.D = (D + DD) % 4294967296
end

-- port: mdfour.c copy64 L107-114 @xonotic-v0.8.6 (in: buffer, byte offset)
local function copy64(inb: buffer, o: number): { number }
	local M = table.create(16, 0)
	for i = 0, 15 do
		M[i + 1] = buffer.readu32(inb, o + i * 4) -- little-endian, as the C byte assembly
	end
	return M
end

-- port: mdfour.c mdfour_begin L124-131 @xonotic-v0.8.6
function mdfour.mdfour_begin(): MD
	return { A = 0x67452301, B = 0xefcdab89, C = 0x98badcfe, D = 0x10325476, totalN = 0 }
end

-- port: mdfour.c mdfour_tail L134-159 @xonotic-v0.8.6
local function mdfour_tail(md: MD, inb: buffer, o: number, n: number)
	md.totalN += n
	local b = (md.totalN * 8) % 4294967296
	local buf = buffer.create(128)
	if n > 0 then
		buffer.copy(buf, 0, inb, o, n)
	end
	buffer.writeu8(buf, n, 0x80)
	if n <= 55 then
		buffer.writeu32(buf, 56, b)
		mdfour64(md, copy64(buf, 0))
	else
		buffer.writeu32(buf, 120, b)
		mdfour64(md, copy64(buf, 0))
		mdfour64(md, copy64(buf, 64))
	end
end

-- port: mdfour.c mdfour_update L161-179 @xonotic-v0.8.6
function mdfour.mdfour_update(md: MD, data: string)
	local inb = buffer.fromstring(data)
	local o, n = 0, #data
	while n >= 64 do
		mdfour64(md, copy64(inb, o))
		o += 64
		n -= 64
		md.totalN += 64
	end
	mdfour_tail(md, inb, o, n)
end

-- port: mdfour.c mdfour_result L182-188 @xonotic-v0.8.6
function mdfour.mdfour_result(md: MD): string
	local out = buffer.create(16)
	buffer.writeu32(out, 0, md.A)
	buffer.writeu32(out, 4, md.B)
	buffer.writeu32(out, 8, md.C)
	buffer.writeu32(out, 12, md.D)
	return buffer.tostring(out)
end

-- port: mdfour.c mdfour L191-197 @xonotic-v0.8.6
function mdfour.mdfour(data: string): string
	local md = mdfour.mdfour_begin()
	mdfour.mdfour_update(md, data)
	return mdfour.mdfour_result(md)
end

-- port: mdfour.c Com_BlockChecksum L207-217 @xonotic-v0.8.6
function mdfour.Com_BlockChecksum(data: string): number
	local d = buffer.fromstring(mdfour.mdfour(data))
	return bxor(buffer.readu32(d, 0), buffer.readu32(d, 4), buffer.readu32(d, 8), buffer.readu32(d, 12))
end

-- port: mdfour.c Com_BlockFullChecksum L219-222 @xonotic-v0.8.6
function mdfour.Com_BlockFullChecksum(data: string): string
	return mdfour.mdfour(data)
end

return mdfour
