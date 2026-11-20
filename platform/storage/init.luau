--!strict
--[[
	platform/storage: Roblox backend replacing DarkPlaces' filesystem writes and config persistence (fs.c write paths) via DataStores.
	Only OS-facing code lives here; the engine/ port calls it through the same
	entry points the C code calls (see docs/subsystems/platform.md).
]]
local M = {}

M.NOT_YET_PORTED = "storage backend (task M7-STORAGE)"

return M
