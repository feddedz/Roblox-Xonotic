--!strict
-- Automatic probes: values Roblox's docs leave open (HANDOFF Q-002, Q-005, G-001, G-006, G-009).
-- Every probe is wrapped in pcall and reports what actually happened on this device.
local AssetService = game:GetService("AssetService")
local Lighting = game:GetService("Lighting")
local Report = require("./Report")
local Geometry = require("./Geometry")

local Probes = {}

local function probe(id: string, fn: () -> string)
	local ok, res = pcall(fn)
	Report.add(id, if ok then res else "ERROR " .. tostring(res))
end

function Probes.runAll()
	local cam = workspace.CurrentCamera

	probe("P-NEARPLANE", function()
		return string.format("Camera.NearPlaneZ = %.4f studs", cam.NearPlaneZ)
	end)

	probe("P-FOV", function()
		local old = cam.FieldOfView
		local out = {}
		for _, v in { 120, 121, 130, 170 } do
			cam.FieldOfView = v
			table.insert(out, `{v}->{cam.FieldOfView}`)
		end
		cam.FieldOfView = old
		return "vertical FOV set->read: " .. table.concat(out, " ")
	end)

	probe("P-LIGHTRANGE", function()
		local out = {}
		for _, class in { "PointLight", "SpotLight", "SurfaceLight" } do
			local l = Instance.new(class) :: any
			for _, v in { 60, 61, 100, 1000, 1e6 } do
				l.Range = v
				table.insert(out, `{class} {v}->{l.Range}`)
			end
			l:Destroy()
		end
		return table.concat(out, "; ")
	end)

	probe("P-EIMG-MAXSIZE", function()
		local out = {}
		for _, s in { 1024, 1025, 2048, 4096 } do
			local ok, img = pcall(function()
				return AssetService:CreateEditableImage({ Size = Vector2.new(s, s) })
			end)
			table.insert(
				out,
				`{s}: {if ok then (if img then "created " .. tostring(img.Size) else "nil") else "error"}`
			)
			if ok and img then
				img:Destroy()
			end
		end
		return table.concat(out, "; ")
	end)

	probe("P-EIMG-BUDGET", function()
		local imgs = {}
		for _ = 1, 512 do
			local img = AssetService:CreateEditableImage({ Size = Vector2.new(1024, 1024) })
			if img == nil then
				break
			end
			table.insert(imgs, img)
		end
		local n = #imgs
		for _, img in imgs do
			img:Destroy()
		end
		return `{n} x 1024x1024 EditableImages before nil (cap 512) = {n * 4} MiB RGBA`
	end)

	probe("P-SA-RUNTIME", function()
		local part = Geometry.quad(4, 4)
		Geometry.applyMaps(part, {
			ColorMap = Geometry.solidImage(64, 128, 128, 128, 255),
			RoughnessMap = Geometry.solidImage(64, 128, 0, 0, 255),
			MetalnessMap = Geometry.solidImage(64, 0, 0, 0, 255),
			NormalMap = Geometry.solidImage(64, 128, 128, 255, 255),
		})
		local ok = part:FindFirstChildOfClass("SurfaceAppearance") ~= nil
		part:Destroy()
		return if ok then "EditableMesh quad + CreateSurfaceAppearanceAsync with EditableImage maps: OK" else "no SA"
	end)

	probe("P-LIGHTING", function()
		local kids = {}
		for _, c in Lighting:GetChildren() do
			table.insert(kids, c.ClassName)
		end
		return string.format(
			"Technology=%s Brightness=%s Ambient=%s children=[%s]",
			tostring(Lighting.Technology),
			tostring(Lighting.Brightness),
			tostring(Lighting.Ambient),
			table.concat(kids, ",")
		)
	end)
end

return Probes
