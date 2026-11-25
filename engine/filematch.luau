--!strict
--[[
	Port of filematch.c @xonotic-v0.8.6 (DarkPlaces; GPLv2 or later, see engine/prvm_edict.luau).
	PARTIAL: matchpattern, matchpattern_with_separator, stringlistsort.
	NOT YET PORTED: listdirectory (OS directories are a platform/ concern; the release has only pk3s).
]]
local libc = require("./_port/libc")

local filematch = {}

local function at(s: string, i: number): number
	return string.byte(s, i) or 0
end

local function lower(c: number): number
	return if c >= 65 and c <= 90 then c + 32 else c
end

-- port: filematch.c matchpattern_with_separator L19-75 @xonotic-v0.8.6
local function mpws(s: string, i: number, p: string, j: number, ci: boolean, seps: string, least_one: boolean): boolean
	while at(p, j) ~= 0 do
		local pc = at(p, j)
		if pc == 63 then -- '?'
			local c = at(s, i)
			if c == 0 or string.find(seps, string.char(c), 1, true) then
				return false
			end
			i += 1
			j += 1
		elseif pc == 42 then -- '*'
			if least_one then
				local c = at(s, i)
				if c == 0 or string.find(seps, string.char(c), 1, true) then
					return false
				end
				i += 1
			end
			j += 1
			while at(s, i) ~= 0 do
				if string.find(seps, string.char(at(s, i)), 1, true) then
					break
				end
				if mpws(s, i, p, j, ci, seps, least_one) then
					return true
				end
				i += 1
			end
		else
			local c = at(s, i)
			if c ~= pc then
				if not ci then
					return false
				end
				if lower(c) ~= lower(pc) then
					return false
				end
			end
			i += 1
			j += 1
		end
	end
	if at(s, i) ~= 0 then
		return false
	end
	return true
end

function filematch.matchpattern_with_separator(
	s: string,
	p: string,
	ci: boolean,
	seps: string,
	least_one: boolean
): boolean
	return mpws(libc.cstr(s), 1, libc.cstr(p), 1, ci, seps, least_one)
end

-- port: filematch.c matchpattern L12-15 @xonotic-v0.8.6
function filematch.matchpattern(s: string, p: string, ci: boolean): boolean
	return mpws(libc.cstr(s), 1, libc.cstr(p), 1, ci, "/\\:", false)
end

-- port: filematch.c stringlistsort L125-152 @xonotic-v0.8.6 (stringlistsort_cmp = strcasecmp).
-- qsort is not stable; entries equal under strcasecmp keep the first after sorting, and with uniq only
-- one of them survives. Ties are broken by strcmp here so the result is deterministic (G-032).
function filematch.stringlistsort(list: { string }, uniq: boolean): { string }
	table.sort(list, function(a, b)
		local c = libc.strcasecmp(a, b)
		if c ~= 0 then
			return c < 0
		end
		return a < b
	end)
	if not uniq or #list < 1 then
		return list
	end
	local out = { list[1] }
	for i = 2, #list do
		if libc.strcasecmp(list[i], out[#out]) ~= 0 then
			table.insert(out, list[i])
		end
	end
	return out
end

return filematch
