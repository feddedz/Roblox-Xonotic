--!strict
--[[
	DarkPlaces filesystem (fs.c), Copyright (C) 2003-2006 Mathieu Olivier; GPLv2 or later.
]]
--[[
	Port of fs.c @xonotic-v0.8.6. PARTIAL: FS_LoadFile, FS_FileExists, FS_Search (pack-file branch).
	Pack contents come from a provider (headless: tests/_lib/vfs_provider.luau over work/vfs-*; Roblox:
	M1-RTVFS). The provider resolves the release's search path order (tools/pk3/vfs.py, mirrors
	FS_AddGameDirectory) and pk3 symlinks (FS_OpenReadFile, G-031), so it hands out what DarkPlaces opens.
	NOT YET PORTED: real search paths (gamedirs, userdir, dlcache), file handles (FS_Open/Read/Seek),
	writing, FS_Init*, listdirectory for OS directories.
]]
local filematch = require("./filematch")
local libc = require("./_port/libc")

local fs = {}

export type Provider = {
	-- every file path in the pack files (any order; FS_Search sorts)
	files: { string },
	-- file contents as DarkPlaces reads them, or nil if not found
	load: (vpath: string) -> string?,
}

local provider: Provider? = nil

function fs.SetProvider(p: Provider?)
	provider = p
end

-- port: fs.c FS_CheckNastyPath L2449-2494 @xonotic-v0.8.6
function fs.FS_CheckNastyPath(path: string, isgamedir: boolean): number
	if path == "" then
		return 2
	end
	if string.find(path, "\\", 1, true) then
		return 1
	end
	if string.find(path, ":", 1, true) then
		return 1
	end
	if string.find(path, "//", 1, true) then
		return 1
	end
	if string.find(path, "..", 1, true) then
		return 2
	end
	if string.sub(path, 1, 1) == "/" then
		return 2
	end
	if string.find(path, "./", 1, true) then
		return 2
	end
	if isgamedir and string.sub(path, -1) == "/" then
		return 2
	end
	if string.find(path, "/.", 1, true) then
		return 2
	end
	return 0
end

-- port: fs.c FS_LoadFile L3350-3354 + FS_OpenVirtualFile L2738-2751 (+ FS_LoadAndCloseQFile) @xonotic-v0.8.6
-- Returns the file text (the C buffer is NUL-terminated; callers treat it as a C string) or nil.
function fs.FS_LoadFile(path: string, quiet: boolean?): string?
	if fs.FS_CheckNastyPath(path, false) ~= 0 then
		print(
			string.format(
				'FS_OpenVirtualFile("%s", %s): nasty filename rejected',
				path,
				if quiet then "true" else "false"
			)
		)
		return nil
	end
	if not provider then
		print("NOT YET PORTED: fs search paths (no file provider set)")
		return nil
	end
	return (provider :: Provider).load(path)
end

function fs.FS_FileExists(path: string): boolean
	return provider ~= nil and (provider :: Provider).load(path) ~= nil
end

-- port: fs.c FS_Search L3559-3756 @xonotic-v0.8.6 (pack-file branch; caseinsensitive as given)
function fs.FS_Search(pattern: string, _caseinsensitive: boolean, _quiet: boolean): { string }?
	local c = string.byte(pattern, 1)
	if c == 46 or c == 58 or c == 47 or c == 92 then -- . : / \
		print("Don't use punctuation at the beginning of a search pattern!")
		return nil
	end
	if not provider then
		return nil
	end
	local result: { string } = {}
	local seen: { [string]: boolean } = {}
	for _, name in (provider :: Provider).files do
		local temp = name
		while temp ~= "" do
			if filematch.matchpattern(temp, pattern, true) then
				if not seen[temp] then -- strcmp-unique
					seen[temp] = true
					table.insert(result, temp)
				end
			end
			-- strip off one path element at a time until empty
			local cut = 0
			for k = #temp, 1, -1 do
				local b = string.byte(temp, k)
				if b == 47 or b == 92 or b == 58 then
					cut = k
					break
				end
			end
			temp = if cut > 0 then string.sub(temp, 1, cut - 1) else ""
		end
	end
	if #result == 0 then
		return nil
	end
	return filematch.stringlistsort(result, true)
end

local _ = libc
return fs
