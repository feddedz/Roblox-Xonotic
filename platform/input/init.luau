--!strict
--[[
	platform/input: Roblox backend replacing DarkPlaces' window and input (vid_sdl.c input, in_*, keys.c device side).
	Only OS-facing code lives here; the engine/ port calls it through the same
	entry points the C code calls (see docs/subsystems/platform.md).
]]
local M = {}

M.NOT_YET_PORTED = "input backend (task M5-INPUT)"

return M
