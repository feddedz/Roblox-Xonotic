--!strict
-- Xonotic port: Studio test place (tests/studio/README.md). Runs the automatic probes, then waits
-- for keys 1-4 to build the visual prototypes. Results are printed between BEGIN/END markers.
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local lib = ReplicatedStorage:WaitForChild("StudioTests")
local Report = require(lib:WaitForChild("Report")) :: any
local Probes = require(lib:WaitForChild("Probes")) :: any
local Prototypes = require(lib:WaitForChild("Prototypes")) :: any
local AudioSlice = require(lib:WaitForChild("AudioSlice")) :: any

print(
	"[StudioTests] keys: 1 specular rig, 2 ViewportFrame fidelity, 3 wide FOV stitch, 4 premultiply capacity, 5 audio slices, 0 dump"
)
Probes.runAll()
Report.dump("XONOTIC STUDIO PROBES")

local actions = {
	[Enum.KeyCode.One] = Prototypes.specularRig,
	[Enum.KeyCode.Two] = Prototypes.viewportFidelity,
	[Enum.KeyCode.Three] = Prototypes.wideFov,
	[Enum.KeyCode.Four] = Prototypes.premultiplyCapacity,
	[Enum.KeyCode.Five] = AudioSlice.run,
	[Enum.KeyCode.Zero] = function()
		Report.dump("XONOTIC STUDIO RESULTS")
	end,
}
UserInputService.InputBegan:Connect(function(input, processed)
	local fn = actions[input.KeyCode]
	if fn and not processed then
		task.spawn(fn)
	end
end)
