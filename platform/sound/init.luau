--!strict
--[[
	platform/sound: Roblox backend replacing DarkPlaces' sound mixer and output (snd_main.c, snd_mix.c, snd_sdl.c, snd_mem.c, snd_ogg.c).
	Only OS-facing code lives here; the engine/ port calls it through the same
	entry points the C code calls (see docs/subsystems/platform.md).
]]
local M = {}

M.NOT_YET_PORTED = "sound backend (task M8-SOUND)"

return M
