--!strict
--[[
Copyright (C) 1996-1997 Id Software, Inc. (DarkPlaces console.c; GPLv2 or later, see engine/prvm_edict.luau)
]]
--[[
	Port of console.c @xonotic-v0.8.6. PARTIAL: Con_Print / Con_Printf / Con_DPrint / Con_DPrintf only,
	writing complete lines to a sink (default: print). Tests replace the sink to capture output.
	NOT YET PORTED: console buffer, log file, notify lines, colour codes, rcon redirect, Con_Init cvars.
]]
local console = {}

local partial = ""
console.sink = function(line: string)
	print(line)
end

-- developer cvar lookup without a require cycle (cvar.luau requires this module)
console.getcvar = nil :: ((name: string) -> any)?

-- port: console.c Con_Print L1436-1439 @xonotic-v0.8.6 (output part)
function console.Con_Print(msg: string)
	partial ..= msg
	while true do
		local nl = string.find(partial, "\n", 1, true)
		if not nl then
			break
		end
		console.sink(string.sub(partial, 1, nl - 1))
		partial = string.sub(partial, nl + 1)
	end
end

-- port: console.c Con_Printf L1446-1456 @xonotic-v0.8.6
function console.Con_Printf(fmt: string, ...: any)
	console.Con_Print(string.format(fmt, ...))
end

local function developer(): boolean
	local get = console.getcvar
	local v = get and get("developer")
	return v ~= nil and v.integer > 0 -- DP adds them to the buffer hidden at 0, drops them below 0
end

-- port: console.c Con_DPrint L1463-1469 @xonotic-v0.8.6
function console.Con_DPrint(msg: string)
	if developer() then
		console.Con_Print(msg)
	end
end

-- port: console.c Con_DPrintf L1476-1489 @xonotic-v0.8.6
function console.Con_DPrintf(fmt: string, ...: any)
	if developer() then
		console.Con_Print(string.format(fmt, ...))
	end
end

-- flush a trailing partial line (tests)
function console.flush()
	if partial ~= "" then
		console.sink(partial)
		partial = ""
	end
end

return console
