--!strict
--!native
--[[
	DarkPlaces bih.c / bih.h: "This code written in 2010 by Forest Hale (darkplacesengine gmail com), and
	placed into public domain."
]]
--[[
	Port of bih.c @xonotic-v0.8.6 (complete). Bounding interval hierarchy over brushes / triangles.

	C arrays (bih->leafs, bih->nodes, leafsort, node->children) are 1-based Luau arrays holding the C element
	i at position i + 1. Every index VALUE keeps its C meaning (0-based leaf / node numbers, -1 = end of a
	children list), so the data can be compared with the C structs field by field.
	float fields hold float32 values; the two float computations of the builder (size, split distance) are
	rounded per operation (D-004).
]]
local f32 = require("./_port/f32")

local bih = {}

local R = f32.round

-- bih.h L10
bih.BIH_MAXUNORDEREDCHILDREN = 8
local BIH_MAXUNORDEREDCHILDREN = bih.BIH_MAXUNORDEREDCHILDREN

-- bih.h biherror_t L12-17
bih.BIHERROR_OK = 0 -- no error, be happy
bih.BIHERROR_OUT_OF_NODES = 1 -- could not produce complete hierarchy, maxnodes too low (should be roughly half of numleafs)

-- bih.h bih_nodetype_t L19-26
bih.BIH_SPLITX = 0
bih.BIH_SPLITY = 1
bih.BIH_SPLITZ = 2
bih.BIH_UNORDERED = 3
local BIH_SPLITX = bih.BIH_SPLITX
local BIH_UNORDERED = bih.BIH_UNORDERED

-- bih.h bih_leaftype_t L28-34
bih.BIH_BRUSH = 4
bih.BIH_COLLISIONTRIANGLE = 5
bih.BIH_RENDERTRIANGLE = 6
local BIH_RENDERTRIANGLE = bih.BIH_RENDERTRIANGLE

-- bih.h bih_node_t L36-52
export type bih_node_t = {
	type: number, -- = BIH_SPLITX and similar values
	mins: { number },
	maxs: { number },
	-- node indexes of children (always > this node's index)
	front: number,
	back: number,
	-- interval of children
	frontmin: number, -- children[0]
	backmax: number, -- children[1]
	-- BIH_UNORDERED uses this for a list of leafindex (all >= 0), -1 = end of list
	children: { number },
}

-- bih.h bih_leaf_t L54-64
export type bih_leaf_t = {
	type: number, -- = BIH_BRUSH And similar values
	mins: { number },
	maxs: { number },
	-- data past this point is generic and entirely up to the caller...
	textureindex: number,
	surfaceindex: number,
	itemindex: number, -- triangle or brush index
}

-- bih.h bih_t L66-86
export type bih_t = {
	-- permanent fields
	-- leafs are constructed by caller before calling BIH_Build
	numleafs: number,
	leafs: { bih_leaf_t },
	-- nodes are constructed by BIH_Build
	numnodes: number,
	nodes: { bih_node_t },
	rootnode: number, -- 0 if numnodes > 0, -1 otherwise
	-- bounds calculated by BIH_Build
	mins: { number },
	maxs: { number },

	-- fields used only during BIH_Build:
	maxnodes: number,
	error: number, -- set to a value if an error occurs in building (such as numnodes == maxnodes)
	leafsort: { number },
	leafsortscratch: { number },
}

-- A zeroed bih_t (C: the caller's struct, memset by BIH_Build).
function bih.new(): bih_t
	return {
		numleafs = 0,
		leafs = {},
		numnodes = 0,
		nodes = {},
		rootnode = 0,
		mins = { 0, 0, 0 },
		maxs = { 0, 0, 0 },
		maxnodes = 0,
		error = 0,
		leafsort = {},
		leafsortscratch = {},
	}
end

-- A zeroed bih_node_t (C: memset(bih->nodes, 0, ...) in BIH_Build).
local function zeronode(): bih_node_t
	return {
		type = 0,
		mins = { 0, 0, 0 },
		maxs = { 0, 0, 0 },
		front = 0,
		back = 0,
		frontmin = 0,
		backmax = 0,
		children = table.create(BIH_MAXUNORDEREDCHILDREN, 0),
	}
end

-- port: bih.c BIH_BuildNode L8-131 @xonotic-v0.8.6
-- leaflist is `b.leafsort + lo` (lo = 0-based offset into leafsort); totalmins / totalmaxs are filled in.
local function BIH_BuildNode(
	b: bih_t,
	numchildren: number,
	lo: number,
	totalmins: { number },
	totalmaxs: { number }
): number
	local leafs = b.leafs
	local leaflist = b.leafsort
	local longestaxis: number
	local axis = 0
	local nodenum: number
	local front = 0
	local back = 0
	local node: bih_node_t
	local child: bih_leaf_t
	local splitdist: number
	local d: number
	local mins = { 0, 0, 0 }
	local maxs = { 0, 0, 0 }
	local size = { 0, 0, 0 }
	local frontmins = { 0, 0, 0 }
	local frontmaxs = { 0, 0, 0 }
	local backmins = { 0, 0, 0 }
	local backmaxs = { 0, 0, 0 }
	-- calculate bounds of children
	child = leafs[leaflist[lo + 1] + 1]
	mins[1] = child.mins[1]
	mins[2] = child.mins[2]
	mins[3] = child.mins[3]
	maxs[1] = child.maxs[1]
	maxs[2] = child.maxs[2]
	maxs[3] = child.maxs[3]
	for i = 1, numchildren - 1 do
		child = leafs[leaflist[lo + i + 1] + 1]
		if mins[1] > child.mins[1] then
			mins[1] = child.mins[1]
		end
		if mins[2] > child.mins[2] then
			mins[2] = child.mins[2]
		end
		if mins[3] > child.mins[3] then
			mins[3] = child.mins[3]
		end
		if maxs[1] < child.maxs[1] then
			maxs[1] = child.maxs[1]
		end
		if maxs[2] < child.maxs[2] then
			maxs[2] = child.maxs[2]
		end
		if maxs[3] < child.maxs[3] then
			maxs[3] = child.maxs[3]
		end
	end
	size[1] = R(maxs[1] - mins[1])
	size[2] = R(maxs[2] - mins[2])
	size[3] = R(maxs[3] - mins[3])
	-- provide bounds to caller
	totalmins[1] = mins[1]
	totalmins[2] = mins[2]
	totalmins[3] = mins[3]
	totalmaxs[1] = maxs[1]
	totalmaxs[2] = maxs[2]
	totalmaxs[3] = maxs[3]
	-- if we run out of nodes it's the caller's fault, but don't crash
	if b.numnodes == b.maxnodes then
		if b.error == 0 then
			b.error = bih.BIHERROR_OUT_OF_NODES
		end
		return 0
	end
	nodenum = b.numnodes
	b.numnodes += 1
	node = b.nodes[nodenum + 1]
	-- store bounds for node
	node.mins[1] = mins[1]
	node.mins[2] = mins[2]
	node.mins[3] = mins[3]
	node.maxs[1] = maxs[1]
	node.maxs[2] = maxs[2]
	node.maxs[3] = maxs[3]
	node.front = 0
	node.back = 0
	node.frontmin = 0
	node.backmax = 0
	for k = 1, BIH_MAXUNORDEREDCHILDREN do
		node.children[k] = -1
	end
	-- check if there are few enough children to store an unordered node
	if numchildren <= BIH_MAXUNORDEREDCHILDREN then
		node.type = BIH_UNORDERED
		for j = 0, numchildren - 1 do
			node.children[j + 1] = leaflist[lo + j + 1]
		end
		return nodenum
	end
	-- pick longest axis
	longestaxis = 0
	if size[1] < size[2] then
		longestaxis = 1
	end
	if size[longestaxis + 1] < size[3] then
		longestaxis = 2
	end
	-- iterate possible split axis choices, starting with the longest axis, if
	-- all fail it means all children have the same bounds and we simply split
	-- the list in half because each node can only have two children.
	local j = 0
	while j < 3 do
		-- pick an axis
		axis = (longestaxis + j) % 3
		-- sort children into front and back lists
		splitdist = R(R(node.mins[axis + 1] + node.maxs[axis + 1]) * 0.5)
		front = 0
		back = 0
		local scratch = b.leafsortscratch
		for i = 0, numchildren - 1 do
			child = leafs[leaflist[lo + i + 1] + 1]
			d = R(R(child.mins[axis + 1] + child.maxs[axis + 1]) * 0.5)
			if d < splitdist then
				scratch[back + 1] = leaflist[lo + i + 1]
				back += 1
			else
				leaflist[lo + front + 1] = leaflist[lo + i + 1]
				front += 1
			end
		end
		-- now copy the back ones into the space made in the leaflist for them
		if back ~= 0 then
			table.move(scratch, 1, back, lo + front + 1, leaflist)
		end
		-- if both sides have some children, it's good enough for us.
		if front ~= 0 and back ~= 0 then
			break
		end
		j += 1
	end
	if j == 3 then
		-- somewhat common case: no good choice, divide children arbitrarily
		axis = 0
		back = bit32.rshift(numchildren, 1)
		front = numchildren - back
	end

	-- we now have front and back children divided in leaflist...
	node.type = BIH_SPLITX + axis
	node.front = BIH_BuildNode(b, front, lo, frontmins, frontmaxs)
	node.frontmin = frontmins[axis + 1]
	node.back = BIH_BuildNode(b, back, lo + front, backmins, backmaxs)
	node.backmax = backmaxs[axis + 1]
	return nodenum
end

-- port: bih.c BIH_Build L133-153 @xonotic-v0.8.6
-- C passes preallocated nodes / temp_leafsort / temp_leafsortscratch arrays; here they are created (zeroed)
-- for maxnodes / numleafs entries, which is all the C code relies on.
function bih.BIH_Build(b: bih_t, numleafs: number, leafs: { bih_leaf_t }, maxnodes: number): number
	b.numleafs = numleafs
	b.leafs = leafs
	b.leafsort = table.create(numleafs, 0)
	b.leafsortscratch = table.create(numleafs, 0)
	b.numnodes = 0
	b.maxnodes = maxnodes
	b.nodes = table.create(maxnodes)
	b.rootnode = 0
	b.mins = { 0, 0, 0 }
	b.maxs = { 0, 0, 0 }
	b.error = 0

	-- clear things we intend to rebuild
	for i = 1, maxnodes do
		b.nodes[i] = zeronode()
	end
	for i = 0, b.numleafs - 1 do
		b.leafsort[i + 1] = i
	end

	b.rootnode = BIH_BuildNode(b, b.numleafs, 0, b.mins, b.maxs)
	return b.error
end

-- port: bih.c BIH_GetTriangleListForBox_Node L155-209 @xonotic-v0.8.6
-- numtrianglespointer is a one-element table (C: int *).
local function BIH_GetTriangleListForBox_Node(
	b: bih_t,
	nodenum: number,
	maxtriangles: number,
	trianglelist_idx: { number },
	trianglelist_surf: { number }?,
	numtrianglespointer: { number },
	mins: { number },
	maxs: { number }
)
	local axis: number
	local node: bih_node_t
	local leaf: bih_leaf_t
	while true do
		node = b.nodes[nodenum + 1]
		-- check if this is an unordered node (which holds an array of leaf numbers)
		if node.type == BIH_UNORDERED then
			axis = 0
			while axis < BIH_MAXUNORDEREDCHILDREN and node.children[axis + 1] >= 0 do
				leaf = b.leafs[node.children[axis + 1] + 1]
				if
					not (
						mins[1] > leaf.maxs[1]
						or maxs[1] < leaf.mins[1]
						or mins[2] > leaf.maxs[2]
						or maxs[2] < leaf.mins[2]
						or mins[3] > leaf.maxs[3]
						or maxs[3] < leaf.mins[3]
					)
				then
					if leaf.type == BIH_RENDERTRIANGLE then
						if numtrianglespointer[1] >= maxtriangles then
							numtrianglespointer[1] += 1 -- so the caller can detect overflow
						else
							if trianglelist_surf then
								trianglelist_surf[numtrianglespointer[1] + 1] = leaf.surfaceindex
							end
							trianglelist_idx[numtrianglespointer[1] + 1] = leaf.itemindex
							numtrianglespointer[1] += 1
						end
					end
				end
				axis += 1
			end
			return
		end
		-- splitting node
		axis = node.type - BIH_SPLITX
		if mins[axis + 1] < node.backmax then
			if maxs[axis + 1] > node.frontmin then
				BIH_GetTriangleListForBox_Node(
					b,
					node.front,
					maxtriangles,
					trianglelist_idx,
					trianglelist_surf,
					numtrianglespointer,
					mins,
					maxs
				)
			end
			nodenum = node.back
			continue
		end
		if maxs[axis + 1] > node.frontmin then
			nodenum = node.front
			continue
		end
		-- fell between the child groups, nothing here
		return
	end
end

-- port: bih.c BIH_GetTriangleListForBox L211-216 @xonotic-v0.8.6
function bih.BIH_GetTriangleListForBox(
	b: bih_t,
	maxtriangles: number,
	trianglelist_idx: { number },
	trianglelist_surf: { number }?,
	mins: { number },
	maxs: { number }
): number
	local numtriangles = { 0 }
	BIH_GetTriangleListForBox_Node(
		b,
		b.rootnode,
		maxtriangles,
		trianglelist_idx,
		trianglelist_surf,
		numtriangles,
		mins,
		maxs
	)
	return numtriangles[1]
end

return bih
