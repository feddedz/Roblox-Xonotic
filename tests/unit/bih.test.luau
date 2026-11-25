--!strict
-- engine/bih.luau against the release's bih.c compiled unchanged (tests/vectors/bih.tsv,
-- tools/testgen/bih_vectors.sh): every node field, the leaf order and box queries, floats bit for bit.
local t = require("../_lib/t")
local bih = require("../../engine/bih")
local f32 = require("../../engine/_port/f32")

return function(ctx: t.Ctx)
	local function fb(hex: string): number
		return f32.frombits(tonumber(hex, 16) :: number)
	end
	local function hx(v: number): string
		return string.format("%08x", f32.tobits(v))
	end
	local name = ""
	local numleafs, maxnodes = 0, 0
	local leafs: { bih.bih_leaf_t } = {}
	local b = bih.new()
	local built = false
	local nodeno = 0
	local function build()
		if not built then
			local err = bih.BIH_Build(b, numleafs, leafs, maxnodes)
			t.eq(ctx, err, b.error, name .. ": return value is bih.error")
			built = true
			nodeno = 0
		end
	end
	for line in string.gmatch(t.read("tests/vectors/bih.tsv"), "[^\r\n]+") do
		local c = string.split(line, "\t")
		local kind = c[1]
		if kind == "CASE" then
			name = c[2]
			numleafs, maxnodes = tonumber(c[3]) :: number, tonumber(c[4]) :: number
			leafs = {}
			b = bih.new()
			built = false
		elseif kind == "L" then
			table.insert(leafs, {
				type = tonumber(c[2]) :: number,
				mins = { fb(c[3]), fb(c[4]), fb(c[5]) },
				maxs = { fb(c[6]), fb(c[7]), fb(c[8]) },
				textureindex = tonumber(c[9]) :: number,
				surfaceindex = tonumber(c[10]) :: number,
				itemindex = tonumber(c[11]) :: number,
			})
		elseif kind == "R" then
			build()
			local got = table.concat({
				tostring(b.error),
				tostring(b.numnodes),
				tostring(b.rootnode),
				hx(b.mins[1]),
				hx(b.mins[2]),
				hx(b.mins[3]),
				hx(b.maxs[1]),
				hx(b.maxs[2]),
				hx(b.maxs[3]),
			}, "\t")
			t.eq(ctx, got, table.concat(c, "\t", 2), name .. ": result")
		elseif kind == "N" then
			local n = b.nodes[nodeno + 1]
			local parts = {
				tostring(n.type),
				hx(n.mins[1]),
				hx(n.mins[2]),
				hx(n.mins[3]),
				hx(n.maxs[1]),
				hx(n.maxs[2]),
				hx(n.maxs[3]),
				tostring(n.front),
				tostring(n.back),
				hx(n.frontmin),
				hx(n.backmax),
			}
			for k = 1, bih.BIH_MAXUNORDEREDCHILDREN do
				table.insert(parts, tostring(n.children[k]))
			end
			t.eq(ctx, table.concat(parts, "\t"), table.concat(c, "\t", 2), `{name}: node {nodeno}`)
			nodeno += 1
		elseif kind == "S" then
			local parts = {}
			for i = 1, numleafs do
				parts[i] = tostring(b.leafsort[i])
			end
			t.eq(ctx, table.concat(parts, "\t"), table.concat(c, "\t", 2), name .. ": leafsort")
		elseif kind == "Q" then
			local mins = { fb(c[2]), fb(c[3]), fb(c[4]) }
			local maxs = { fb(c[5]), fb(c[6]), fb(c[7]) }
			local max = tonumber(c[8]) :: number
			local withsurf = c[9] == "1"
			local idx: { number } = {}
			local surf: { number } = {}
			local n = bih.BIH_GetTriangleListForBox(b, max, idx, if withsurf then surf else nil, mins, maxs)
			local parts = { tostring(n) }
			for j = 1, math.min(n, max) do
				table.insert(parts, `{idx[j]}:{if withsurf then surf[j] else -1}`)
			end
			t.eq(ctx, table.concat(parts, "\t"), table.concat(c, "\t", 10), `{name}: query {c[2]} {c[5]}`)
		end
	end
end
