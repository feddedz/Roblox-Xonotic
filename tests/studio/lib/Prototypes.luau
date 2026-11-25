--!strict
-- Visual prototypes. Each builds a fixed scene and a fixed camera so screenshots are comparable.
-- Press the key shown in the on-screen help; take a 1920x1080 screenshot; note the printed result.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Report = require("./Report")
local Geometry = require("./Geometry")

local Prototypes = {}

local current: Folder? = nil
local gui: ScreenGui? = nil
local conn: RBXScriptConnection? = nil

local function reset(): Folder
	if conn then
		conn:Disconnect()
		conn = nil
	end
	if current then
		current:Destroy()
	end
	if gui then
		gui:Destroy()
		gui = nil
	end
	local f = Instance.new("Folder")
	f.Name = "StudioTestScene"
	f.Parent = workspace
	current = f
	return f
end

local function fixedCamera(cf: CFrame, vfov: number)
	local cam = workspace.CurrentCamera
	cam.CameraType = Enum.CameraType.Scriptable
	cam.CFrame = cf
	cam.FieldOfView = vfov
end

local function lightAt(parent: Instance, pos: Vector3, range: number, brightness: number)
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.Transparency = 1
	p.Size = Vector3.one * 0.2
	p.Position = pos
	p.Parent = parent
	local l = Instance.new("PointLight")
	l.Range = range
	l.Brightness = brightness
	l.Shadows = true
	l.Parent = p
end

local function label(parent: Instance, pos: Vector3, text: string)
	local a = Instance.new("Part")
	a.Anchored = true
	a.CanCollide = false
	a.Transparency = 1
	a.Size = Vector3.one * 0.1
	a.Position = pos
	a.Parent = parent
	local b = Instance.new("BillboardGui")
	b.Size = UDim2.fromOffset(120, 24)
	b.AlwaysOnTop = true
	b.Parent = a
	local t = Instance.new("TextLabel")
	t.Size = UDim2.fromScale(1, 1)
	t.BackgroundTransparency = 1
	t.TextColor3 = Color3.new(1, 1, 1)
	t.TextStrokeTransparency = 0
	t.Text = text
	t.Parent = b
end

-- Simple test scene used by V2/V3: coloured blocks on a floor, one point light.
local function blocksScene(parent: Instance)
	local floor = Instance.new("Part")
	floor.Anchored = true
	floor.Size = Vector3.new(60, 1, 60)
	floor.Position = Vector3.new(0, -0.5, 0)
	floor.Color = Color3.fromRGB(150, 150, 150)
	floor.Parent = parent
	local colours = { Color3.fromRGB(200, 40, 40), Color3.fromRGB(40, 200, 40), Color3.fromRGB(40, 40, 200) }
	for i = 1, 9 do
		local b = Instance.new("Part")
		b.Anchored = true
		b.Size = Vector3.new(3, 2 + i % 3 * 2, 3)
		b.Position = Vector3.new((i - 5) * 5, b.Size.Y / 2, -10 + (i % 2) * 6)
		b.Color = colours[i % 3 + 1]
		b.Parent = parent
	end
	lightAt(parent, Vector3.new(0, 10, 0), 40, 3)
end

-- V1: specular calibration rig. Roughness 0..1 (columns) x metalness 0/1 (rows), grey albedo, flat normal,
-- one shadowed point light, black environment (studio-tests.project.json neutralises Lighting).
function Prototypes.specularRig()
	local scene = reset()
	local steps = { 0, 0.2, 0.4, 0.6, 0.8, 1 }
	for row, metal in { 0, 1 } do
		for col, rough in steps do
			local q = Geometry.quad(4, 4)
			q.CFrame = CFrame.new((col - 3.5) * 5, 8 - row * 5, 0)
			q.Parent = scene
			Geometry.applyMaps(q, {
				ColorMap = Geometry.solidImage(16, 128, 128, 128, 255),
				RoughnessMap = Geometry.solidImage(16, math.round(rough * 255), 0, 0, 255),
				MetalnessMap = Geometry.solidImage(16, math.round(metal * 255), 0, 0, 255),
				NormalMap = Geometry.solidImage(16, 128, 128, 255, 255),
			})
			label(scene, q.Position + Vector3.new(0, 2.6, 0), string.format("r=%.1f m=%d", rough, metal))
		end
	end
	lightAt(scene, Vector3.new(0, 5.5, 6), 30, 4)
	fixedCamera(CFrame.lookAt(Vector3.new(0, 5.5, 22), Vector3.new(0, 5.5, 0)), 50)
	Report.add(
		"V1-SPECULAR",
		"rig shown: screenshot it; compare highlight size/strength per cell with the Ultra reference"
	)
end

-- V2: what a ViewportFrame loses (the basis for scripted reflections and FOV stitching).
-- Left half: the real 3D view. Right half: the same scene and camera inside a ViewportFrame.
function Prototypes.viewportFidelity()
	local scene = reset()
	blocksScene(scene)
	local camCf = CFrame.lookAt(Vector3.new(0, 12, 25), Vector3.new(0, 2, -5))
	fixedCamera(camCf, 60)
	local sg = Instance.new("ScreenGui")
	sg.IgnoreGuiInset = true
	sg.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	gui = sg
	local vf = Instance.new("ViewportFrame")
	vf.Size = UDim2.fromScale(0.5, 1)
	vf.Position = UDim2.fromScale(0.5, 0)
	vf.BackgroundColor3 = Color3.new(0, 0, 0)
	vf.Parent = sg
	local wm = Instance.new("WorldModel")
	wm.Parent = vf
	for _, c in scene:GetChildren() do
		c:Clone().Parent = wm
	end
	local vcam = Instance.new("Camera")
	vcam.FieldOfView = 60
	vcam.CFrame = camCf
	vcam.Parent = vf
	vf.CurrentCamera = vcam
	Report.add("V2-VIEWPORT", "left = real render, right = ViewportFrame; note missing shadows/point light/post")
end

-- V3: 170 deg horizontal view stitched from three ViewportFrames (each its own camera).
-- DarkPlaces draws one perspective projection; this shows the seams/distortion of stitching.
function Prototypes.wideFov()
	local scene = reset()
	blocksScene(scene)
	local sg = Instance.new("ScreenGui")
	sg.IgnoreGuiInset = true
	sg.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	gui = sg
	local eye = CFrame.new(0, 4, 20)
	local hTotal = math.rad(170)
	local hEach = hTotal / 3
	local viewport = workspace.CurrentCamera.ViewportSize
	local panelAspect = (viewport.X / 3) / viewport.Y
	local vfov = math.deg(2 * math.atan(math.tan(hEach / 2) / panelAspect))
	for i = -1, 1 do
		local vf = Instance.new("ViewportFrame")
		vf.Size = UDim2.fromScale(1 / 3, 1)
		vf.Position = UDim2.fromScale((i + 1) / 3, 0)
		vf.BackgroundColor3 = Color3.new(0, 0, 0)
		vf.Parent = sg
		local wm = Instance.new("WorldModel")
		wm.Parent = vf
		for _, c in scene:GetChildren() do
			c:Clone().Parent = wm
		end
		local cam = Instance.new("Camera")
		cam.FieldOfView = math.clamp(vfov, 1, 120)
		cam.CFrame = eye * CFrame.Angles(0, -i * hEach, 0)
		cam.Parent = vf
		vf.CurrentCamera = cam
	end
	Report.add(
		"V3-WIDEFOV",
		string.format("3 panels x %.1f deg h, panel vfov %.1f (clamped to 120)", math.deg(hEach), vfov)
	)
end

-- V4: capacity of exact CPU-premultiplied (texture x lightmap) surfaces, the GL_DST_COLOR GL_ZERO
-- replacement. Creates unique 1024x1024 premultiplied quads until the EditableImage budget runs out,
-- then measures frame time. NOTE: uploaded image assets have a different budget (needs M1-UPLOAD).
function Prototypes.premultiplyCapacity()
	local scene = reset()
	fixedCamera(CFrame.lookAt(Vector3.new(0, 20, 60), Vector3.new(0, 0, 0)), 70)
	local n = 0
	for i = 1, 128 do
		local shade = i
		local img = Geometry.imageFrom(1024, function(x, y)
			local tex = if ((x // 64) + (y // 64)) % 2 == 0 then 220 else 90 -- checker "texture"
			local lm = 0.25 + 0.75 * (x / 1023) * (1 - y / 2047) -- smooth "lightmap"
			local v = math.clamp(math.round(tex * lm), 0, 255)
			return v, (v + shade) % 256, v, 255
		end)
		if img == nil then
			break
		end
		local q = Geometry.quad(8, 8)
		q.CFrame = CFrame.new(((i - 1) % 12 - 5.5) * 9, 0, -((i - 1) // 12) * 9)
		q.Parent = scene
		Geometry.applyMaps(q, { ColorMap = img })
		n = i
		task.wait()
	end
	local frames, t0 = 0, os.clock()
	local done = false
	conn = RunService.RenderStepped:Connect(function()
		frames += 1
		if not done and os.clock() - t0 >= 3 then
			done = true
			Report.add(
				"V4-PREMULTIPLY",
				string.format("%d unique 1024^2 surfaces; %.1f FPS", n, frames / (os.clock() - t0))
			)
		end
	end)
end

return Prototypes
