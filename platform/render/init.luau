--!strict
--[[
	platform/render: Roblox backend replacing DarkPlaces' OpenGL renderer (gl_backend.c, gl_rmain.c, gl_rsurf.c, gl_textures.c, gl_draw.c, vid_*.c).
	Only OS-facing code lives here; the engine/ port calls it through the same
	entry points the C code calls (see docs/subsystems/platform.md).
]]
local M = {}

M.NOT_YET_PORTED = "render backend (task M5-RENDER)"

return M
