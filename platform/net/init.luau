--!strict
--[[
	platform/net: Roblox backend replacing DarkPlaces' socket layer (lhnet.c, netconn.c transport).
	Only OS-facing code lives here; the engine/ port calls it through the same
	entry points the C code calls (see docs/subsystems/platform.md).
]]
local M = {}

M.NOT_YET_PORTED = "net backend (task M6-NET)"

return M
