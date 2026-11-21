--!strict
-- Headless file provider for engine/fs.luau: file list from assets/manifest/vfs-<build>.tsv, contents
-- from work/vfs-<build>/ (python3 tools/pk3/manifest.py --build <build> --extract; symlinks resolved, G-031).
local fs = require("@lune/fs")

return function(build: string?): any
	local b = build or "high"
	local root = "work/vfs-" .. b .. "/"
	if not fs.isFile(root .. "quake.rc") then
		return nil
	end
	local files: { string } = {}
	for line in string.gmatch(fs.readFile("assets/manifest/vfs-" .. b .. ".tsv"), "[^\n]+") do
		if string.sub(line, 1, 1) ~= "#" then
			table.insert(files, string.match(line, "^[^\t]+") :: string)
		end
	end
	local known: { [string]: boolean } = {}
	for _, f in files do
		known[f] = true
	end
	return {
		files = files,
		load = function(p: string): string?
			if not known[p] then
				return nil -- pk3 lookup is case-sensitive
			end
			return fs.readFile(root .. p)
		end,
	}
end
