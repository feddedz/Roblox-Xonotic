--!strict
--[[
	DarkPlaces filesystem (fs.c), Copyright (C) 2003-2006 Mathieu Olivier; GPLv2 or later.
]]
--[[
	Port of fs.c @xonotic-v0.8.6. PARTIAL: FS_LoadFile, FS_FileExists, FS_Search (pack-file branch).
	Pack contents come from a provider (headless: tests/_lib/vfs_provider.luau over work/vfs-*; Roblox:
	M1-RTVFS). The provider resolves the release's search path order (tools/pk3/vfs.py, mirrors
	FS_AddGameDirectory) and pk3 symlinks (FS_OpenReadFile, G-031), so it hands out what DarkPlaces opens.
	Files written by the game (FS_OpenRealFile, <fs_gamedir>/<path>) live in fs.realfiles, which is searched
	before the packs, as the userdir gamedir is in DarkPlaces.
	NOT YET PORTED: persistence of written files across servers (M2-FSWRITE), real search paths (gamedirs,
	dlcache), FS_Seek/FS_Read beyond Getc, FS_Init*, listdirectory for OS directories.
]]
local filematch = require("./filematch")
local libc = require("./_port/libc")

local fs = {}

export type Provider = {
	-- every file path in the pack files (any order; FS_Search sorts)
	files: { string },
	-- file contents as DarkPlaces reads them, or nil if not found
	load: (vpath: string) -> string?,
	-- pk3 file name the file comes from (FS_WhichPack), nil if not in a pack
	pack: ((vpath: string) -> string?)?,
}

local provider: Provider? = nil

-- files written through FS_OpenRealFile, by path relative to fs_gamedir (the userdir gamedir)
fs.realfiles = {} :: { [string]: string }

export type QFile = {
	data: string,
	pos: number, -- 0-based read offset
	ungetc: number, -- EOF (-1) = none
	writepath: string?, -- set for files opened for writing; committed to fs.realfiles on FS_Close
	out: { string },
}

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
	local real = fs.realfiles[path]
	if real then
		return real
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

-- port: fs.c FS_OpenRealFile L2711-2728 @xonotic-v0.8.6 (in-memory gamedir, see fs.realfiles)
function fs.FS_OpenRealFile(filepath: string, mode: string, quiet: boolean): QFile?
	if fs.FS_CheckNastyPath(filepath, false) ~= 0 then
		print(
			string.format(
				'FS_OpenRealFile("%s", "%s", %s): nasty filename rejected',
				filepath,
				mode,
				if quiet then "true" else "false"
			)
		)
		return nil
	end
	local m = string.sub(mode, 1, 1)
	if m == "w" then
		return { data = "", pos = 0, ungetc = -1, writepath = filepath, out = {} }
	elseif m == "a" then
		return { data = "", pos = 0, ungetc = -1, writepath = filepath, out = { fs.realfiles[filepath] or "" } }
	end
	local d = fs.realfiles[filepath]
	if not d then
		return nil
	end
	return { data = d, pos = 0, ungetc = -1, out = {} }
end

-- port: fs.c FS_OpenVirtualFile L2738-2751 @xonotic-v0.8.6
function fs.FS_OpenVirtualFile(filepath: string, quiet: boolean): QFile?
	if fs.FS_CheckNastyPath(filepath, false) ~= 0 then
		print(
			string.format(
				'FS_OpenVirtualFile("%s", %s): nasty filename rejected',
				filepath,
				if quiet then "true" else "false"
			)
		)
		return nil
	end
	local d = fs.FS_LoadFile(filepath, quiet)
	if not d then
		return nil
	end
	return { data = d, pos = 0, ungetc = -1, out = {} }
end

-- port: fs.c FS_Close L2780-2815 @xonotic-v0.8.6
function fs.FS_Close(file: QFile): number
	if file.writepath then
		fs.realfiles[file.writepath] = table.concat(file.out)
	end
	return 0
end

-- port: fs.c FS_Write L2829-2866 @xonotic-v0.8.6
function fs.FS_Write(file: QFile, data: string): number
	table.insert(file.out, data)
	return #data
end

-- port: fs.c FS_Getc L3133-3141 @xonotic-v0.8.6 (FS_Read of 1 byte, ungetc first)
function fs.FS_Getc(file: QFile): number
	if file.ungetc ~= -1 then
		local c = file.ungetc
		file.ungetc = -1
		return c
	end
	if file.pos >= #file.data then
		return -1
	end
	file.pos += 1
	return string.byte(file.data, file.pos)
end

-- port: fs.c FS_UnGetc L3151-3159 @xonotic-v0.8.6
function fs.FS_UnGetc(file: QFile, c: number): number
	if file.ungetc ~= -1 then
		return -1
	end
	file.ungetc = c
	return c
end

-- port: fs.c FS_WhichPack L3886-3896 @xonotic-v0.8.6 (FS_FindFile: written files first, then the packs)
function fs.FS_WhichPack(filename: string): string?
	if fs.realfiles[filename] then
		return "" -- found, not in a pack
	end
	if not provider then
		return nil
	end
	local pk = (provider :: Provider).pack
	if pk then
		return pk(filename)
	end
	return if (provider :: Provider).load(filename) then "" else nil
end

local _ = libc
return fs
