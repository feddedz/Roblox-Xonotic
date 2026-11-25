--!strict
-- engine/curves.luau and the mesh helpers of engine/model_shared.luau against the release's curves.c and
-- model_shared.c compiled unchanged (tests/vectors/curves.tsv, tools/testgen/curves_vectors.sh): tesselation
-- levels, tesselated vertices, triangle elements, degenerate-triangle removal, snapping, tangent vectors and
-- seam fixing; floats bit for bit.
local t = require("../_lib/t")
local curves = require("../../engine/curves")
local f32 = require("../../engine/_port/f32")
local model_shared = require("../../engine/model_shared")

return function(ctx: t.Ctx)
	local function fbuf(c: { string }): buffer
		local n = tonumber(c[2]) :: number
		local b = buffer.create(n * 4)
		for i = 1, n do
			buffer.writeu32(b, (i - 1) * 4, tonumber(c[i + 2], 16) :: number)
		end
		return b
	end
	local function fhex(b: buffer, ofs: number, n: number): string
		local parts = table.create(n)
		for i = 0, n - 1 do
			parts[i + 1] = string.format("%08x", buffer.readu32(b, ofs + i * 4))
		end
		return table.concat(parts, "\t")
	end
	local function ihex(b: buffer, ofs: number, n: number): string
		local parts = table.create(n)
		for i = 0, n - 1 do
			parts[i + 1] = tostring(buffer.readi32(b, ofs + i * 4))
		end
		return table.concat(parts, "\t")
	end
	local MAXV = 4096
	local w, h = 0, 0
	local pos, tc, nrm = buffer.create(0), buffer.create(0), buffer.create(0)
	local name = ""
	-- state of the current TESS block
	local opos, otc, onrm = buffer.create(0), buffer.create(0), buffer.create(0)
	local elem, elem2 = buffer.create(0), buffer.create(0)
	local tw, th, fw, fh, firstvertex, nv, nt, ndeg = 0, 0, 0, 0, 0, 0, 0, 0
	local areaweighting = false
	local svec, tvec = buffer.create(0), buffer.create(0)
	local tvecdone = false
	-- seam fixing
	local pa: curves.patchinfo_t, pb: curves.patchinfo_t = nil :: any, nil :: any
	local abuf, bbuf = buffer.create(0), buffer.create(0)

	for line in string.gmatch(t.read("tests/vectors/curves.tsv"), "[^\r\n]+") do
		local c = string.split(line, "\t")
		local kind = c[1]
		if kind == "PATCH" then
			w, h = tonumber(c[2]) :: number, tonumber(c[3]) :: number
			name = `patch {w}x{h} mode {c[4]}`
		elseif kind == "POS" then
			pos = fbuf(c)
		elseif kind == "TC" then
			tc = fbuf(c)
		elseif kind == "NRM" then
			nrm = fbuf(c)
		elseif kind == "TOL" then
			local tol = f32.frombits(tonumber(c[2], 16) :: number)
			local tol2 = f32.round(tol * f32.round(0.001))
			local got = table.concat({
				tostring(curves.Q3PatchTesselationOnX(w, h, 3, pos, 0, tol)),
				tostring(curves.Q3PatchTesselationOnY(w, h, 3, pos, 0, tol)),
				tostring(curves.Q3PatchTesselationOnX(w, h, 2, tc, 0, tol2)),
				tostring(curves.Q3PatchTesselationOnY(w, h, 2, tc, 0, tol2)),
			}, "\t")
			t.eq(ctx, got, table.concat(c, "\t", 3), `{name}: tesselation for tolerance {tol}`)
		elseif kind == "TESS" then
			tw, th = tonumber(c[2]) :: number, tonumber(c[3]) :: number
			fw, fh = curves.Q3PatchDimForTess(w, tw), curves.Q3PatchDimForTess(h, th)
			t.eq(ctx, `{fw}x{fh}`, `{c[4]}x{c[5]}`, name .. ": Q3PatchDimForTess")
			firstvertex = tonumber(c[6]) :: number
			areaweighting = c[7] ~= "0"
			nv, nt = fw * fh, (fw - 1) * (fh - 1) * 2
			opos, otc, onrm = buffer.create(MAXV * 12), buffer.create(MAXV * 8), buffer.create(MAXV * 12)
			curves.Q3PatchTesselateFloat(3, 12, opos, firstvertex * 12, w, h, 12, pos, 0, tw, th)
			curves.Q3PatchTesselateFloat(2, 8, otc, firstvertex * 8, w, h, 8, tc, 0, tw, th)
			curves.Q3PatchTesselateFloat(3, 12, onrm, firstvertex * 12, w, h, 12, nrm, 0, tw, th)
			elem = buffer.create(math.max(nt, 1) * 12)
			curves.Q3PatchTriangleElements(elem, 0, fw, fh, firstvertex)
			elem2 = buffer.create(math.max(nt, 1) * 12)
			ndeg = model_shared.Mod_RemoveDegenerateTriangles(nt, elem, 0, elem2, 0, opos)
			tvecdone = false
			name = `patch {w}x{h} tess {tw}x{th} at {firstvertex}`
		elseif kind == "OPOS" then
			t.eq(ctx, fhex(opos, firstvertex * 12, nv * 3), table.concat(c, "\t", 3), name .. ": vertices")
		elseif kind == "OTC" then
			t.eq(ctx, fhex(otc, firstvertex * 8, nv * 2), table.concat(c, "\t", 3), name .. ": texcoords")
		elseif kind == "ELEM" then
			t.eq(ctx, ihex(elem, 0, nt * 3), table.concat(c, "\t", 3), name .. ": Q3PatchTriangleElements")
		elseif kind == "DEGEN" then
			t.eq(ctx, tostring(ndeg * 3), c[2], name .. ": triangles left")
			t.eq(ctx, ihex(elem2, 0, ndeg * 3), table.concat(c, "\t", 3), name .. ": Mod_RemoveDegenerateTriangles")
		elseif kind == "SNAP" then
			local snapped = buffer.create(nv * 12)
			buffer.copy(snapped, 0, opos, firstvertex * 12, nv * 12)
			model_shared.Mod_SnapVertices(3, nv, snapped, 0, if tw % 2 == 1 then 1.0 else 0.25)
			t.eq(ctx, fhex(snapped, 0, nv * 3), table.concat(c, "\t", 3), name .. ": Mod_SnapVertices")
		elseif kind == "SVEC" or kind == "TVEC" then
			if not tvecdone then
				svec, tvec = buffer.create(MAXV * 12), buffer.create(MAXV * 12)
				model_shared.Mod_BuildTextureVectorsFromNormals(
					firstvertex,
					nv,
					ndeg,
					opos,
					otc,
					onrm,
					elem2,
					0,
					svec,
					tvec,
					areaweighting
				)
				tvecdone = true
			end
			t.eq(
				ctx,
				fhex(if kind == "SVEC" then svec else tvec, firstvertex * 12, nv * 3),
				table.concat(c, "\t", 3),
				`{name}: Mod_BuildTextureVectorsFromNormals {kind} (areaweighting {areaweighting})`
			)
		elseif kind == "ADJ" then
			local n = table.create(12, 0)
			for i = 1, 12 do
				n[i] = tonumber(c[i + 1]) :: number
			end
			pa = {
				xsize = n[1],
				ysize = n[2],
				lods = { { xtess = n[5], ytess = n[6] }, { xtess = n[7], ytess = n[8] } },
			}
			pb = {
				xsize = n[3],
				ysize = n[4],
				lods = { { xtess = n[9], ytess = n[10] }, { xtess = n[11], ytess = n[12] } },
			}
			name = "seam " .. table.concat(c, " ", 2)
		elseif kind == "A" then
			abuf = fbuf(c)
		elseif kind == "B" then
			bbuf = fbuf(c)
		elseif kind == "ADJR" then
			local m = curves.Q3PatchAdjustTesselation(3, pa, abuf, 0, pb, bbuf, 0)
			local got = table.concat({
				if m then "1" else "0",
				tostring(pa.lods[1].xtess),
				tostring(pa.lods[1].ytess),
				tostring(pa.lods[2].xtess),
				tostring(pa.lods[2].ytess),
				tostring(pb.lods[1].xtess),
				tostring(pb.lods[1].ytess),
				tostring(pb.lods[2].xtess),
				tostring(pb.lods[2].ytess),
			}, "\t")
			t.eq(ctx, got, table.concat(c, "\t", 2), name)
		end
	end
end
