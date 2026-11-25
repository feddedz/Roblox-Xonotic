--!strict
-- engine/collision.luau (Collision_NewBrushFromPlanes) and engine/polygon.luau against the release's
-- collision.c / polygon.c compiled unchanged (tests/vectors/collision.tsv, tools/testgen/collision_vectors.sh).
-- Every float is compared bit for bit, including the edgedirs memory the C code overwrites with elements.
local t = require("../_lib/t")
local collision = require("../../engine/collision")
local console = require("../../engine/console")
local f32 = require("../../engine/_port/f32")
local polygon = require("../../engine/polygon")

return function(ctx: t.Ctx)
	local scratch = buffer.create(8)
	local function fb(hex: string): number
		return f32.frombits(tonumber(hex, 16) :: number)
	end
	local function db(hex: string): number
		buffer.writeu32(scratch, 4, tonumber(string.sub(hex, 1, 8), 16) :: number)
		buffer.writeu32(scratch, 0, tonumber(string.sub(hex, 9, 16), 16) :: number)
		return buffer.readf64(scratch, 0)
	end
	local function dh(v: number): string
		buffer.writef64(scratch, 0, v)
		return string.format("%08x%08x", buffer.readu32(scratch, 4), buffer.readu32(scratch, 0))
	end
	local function h32(b: buffer, ofs: number): string
		return string.format("%08x", buffer.readu32(b, ofs))
	end
	local textures = { { index = 0 }, { index = 1 }, { index = 2 }, { index = 3 } }

	local oldsink = console.sink
	console.sink = function(_line: string) end -- Collision_ValidateBrush prints for the degenerate brushes

	local quad: { number } = {}
	local planes: { collision.colplanef_t } = {}
	local header: { string } = {}
	local brush: collision.colbrushf_t? = nil
	local opno = 0
	local name = ""
	for line in string.gmatch(t.read("tests/vectors/collision.tsv"), "[^\r\n]+") do
		local c = string.split(line, "\t")
		local kind = c[1]
		if kind == "QUAD" then
			quad = table.create(12, 0)
			polygon.PolygonD_QuadForPlane(quad, fb(c[2]), fb(c[3]), fb(c[4]), db(c[5]), db(c[6]))
			local parts = {}
			for k = 1, 12 do
				parts[k] = dh(quad[k])
			end
			t.eq(
				ctx,
				table.concat(parts, "\t"),
				table.concat(c, "\t", 7),
				"PolygonD_QuadForPlane " .. c[2] .. " " .. c[3]
			)
		elseif kind == "DIV" then
			local front: { number }, back: { number } = {}, {}
			local nf, nb, on =
				polygon.PolygonD_Divide(4, quad, fb(c[2]), fb(c[3]), fb(c[4]), db(c[5]), 0.0625, 64, front, 64, back)
			local parts = { tostring(nf), tostring(nb), tostring(on) }
			for k = 1, nf * 3 do
				table.insert(parts, dh(front[k]))
			end
			table.insert(parts, "|")
			for k = 1, nb * 3 do
				table.insert(parts, dh(back[k]))
			end
			t.eq(ctx, table.concat(parts, "\t"), table.concat(c, "\t", 6), "PolygonD_Divide " .. c[2] .. " " .. c[5])
		elseif kind == "B" then
			name = "brush " .. c[2]
			header = c
			planes = {}
		elseif kind == "P" then
			table.insert(planes, {
				normal = { fb(c[2]), fb(c[3]), fb(c[4]) },
				dist = fb(c[5]),
				q3surfaceflags = tonumber(c[6]) :: number,
				texture = textures[(tonumber(c[7]) :: number) + 1],
			})
		elseif kind == "R" then
			brush = collision.Collision_NewBrushFromPlanes(
				tonumber(header[3]) :: number,
				planes,
				tonumber(header[4]) :: number,
				tonumber(header[5]) :: number,
				textures[2],
				header[6] ~= "0"
			)
			opno = 0
			local b = brush
			if c[2] == "null" then
				t.ok(ctx, b == nil, name .. ": C returned NULL")
			elseif not b then
				t.ok(ctx, false, name .. ": got nil, C built a brush")
			else
				local got = table.concat({
					if b.isaabb then "1" else "0",
					if b.hasaabbplanes then "1" else "0",
					tostring(b.supercontents),
					tostring(b.q3surfaceflags),
					tostring(b.texture.index),
					tostring(b.numplanes),
					tostring(b.numedgedirs),
					tostring(b.numpoints),
					tostring(b.numtriangles),
					string.format("%08x", f32.tobits(b.mins[1])),
					string.format("%08x", f32.tobits(b.mins[2])),
					string.format("%08x", f32.tobits(b.mins[3])),
					string.format("%08x", f32.tobits(b.maxs[1])),
					string.format("%08x", f32.tobits(b.maxs[2])),
					string.format("%08x", f32.tobits(b.maxs[3])),
				}, "\t")
				t.eq(ctx, got, table.concat(c, "\t", 2), name .. ": result")
			end
		elseif brush and kind == "OP" then
			opno += 1
			local p = brush.planes[opno]
			local got = if p
				then table.concat({
					string.format("%08x", f32.tobits(p.normal[1])),
					string.format("%08x", f32.tobits(p.normal[2])),
					string.format("%08x", f32.tobits(p.normal[3])),
					string.format("%08x", f32.tobits(p.dist)),
					tostring(p.q3surfaceflags),
					tostring(p.texture.index),
				}, "\t")
				else "missing"
			t.eq(ctx, got, table.concat(c, "\t", 2), `{name}: plane {opno}`)
		elseif brush and (kind == "PT" or kind == "ED") then
			local buf = if kind == "PT" then brush.points else brush.edgedirs
			local n = if kind == "PT" then brush.numpoints else brush.numedgedirs
			local parts = {}
			for i = 0, n - 1 do
				parts[i + 1] = h32(buf, i * 12) .. " " .. h32(buf, i * 12 + 4) .. " " .. h32(buf, i * 12 + 8)
			end
			t.eq(ctx, table.concat(parts, "\t"), table.concat(c, "\t", 2), name .. ": " .. kind)
		elseif brush and kind == "EL" then
			local parts = {}
			for i = 0, brush.numtriangles * 3 - 1 do
				parts[i + 1] = tostring(buffer.readi32(brush.elements, i * 4))
			end
			t.eq(ctx, table.concat(parts, "\t"), table.concat(c, "\t", 2), name .. ": elements")
		end
	end
	console.sink = oldsink
end
