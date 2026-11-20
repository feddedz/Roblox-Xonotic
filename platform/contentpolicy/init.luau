--!strict
--[[
	Content-policy switch (HANDOFF D-016, docs/policy/gentle-mode.md "Isolation").
	THE ONLY PLACE the blood/gore mode is chosen. Changing MODE must be the whole change.

	  "player-choice"  Xonotic behaviour: cl_gentle default 0, menu checkbox works, gore assets loaded.
	  "forced-gentle"  cl_gentle locked to 1; gore assets loaded but never shown by the game code.
	  "removed"        cl_gentle locked to 1; gore asset group never uploaded/loaded; the VFS serves
	                   policy placeholders for gore paths so precache order, index numbers and server
	                   model loading stay identical (no missing-asset errors).
	QuakeC is never edited; the server never reads cl_gentle, so no mode changes gameplay.
	Owner decision on the mode is deferred until before publishing (Q-007).
]]

export type Mode = "player-choice" | "forced-gentle" | "removed"

local MODE: Mode = "player-choice"

local ContentPolicy = {}

local VALID = { ["player-choice"] = true, ["forced-gentle"] = true, ["removed"] = true }

-- Overridable for tests only; the game always uses MODE.
local active: Mode = MODE

function ContentPolicy.mode(): Mode
	return active
end

function ContentPolicy._setModeForTest(m: Mode)
	assert(VALID[m], "unknown content-policy mode " .. tostring(m))
	active = m
end

-- Cvars the engine must hold at a fixed value (applied after configs load; menu shows them locked).
function ContentPolicy.lockedCvars(): { [string]: string }
	if active == "player-choice" then
		return {}
	end
	return { cl_gentle = "1" }
end

-- Whether the gore asset group (assets/optional/gore/) is uploaded and loaded at all.
function ContentPolicy.goreAssetsEnabled(): boolean
	return active ~= "removed"
end

-- How the runtime VFS / asset loader should serve a path. isGore comes from the gore manifest.
-- "normal": the real asset. "placeholder": a policy placeholder with the same name (removed mode only).
function ContentPolicy.resolve(isGore: boolean): "normal" | "placeholder"
	if isGore and active == "removed" then
		return "placeholder"
	end
	return "normal"
end

return ContentPolicy
