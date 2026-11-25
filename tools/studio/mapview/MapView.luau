--!strict
--[[
	Debug viewer (NOT the game's renderer, not part of the port): shows the surfaces of a Q3 BSP exactly as
	engine/model_brush.luau loaded them, as textured MeshParts in Workspace.MapView. It exists to look at the
	loader's output in Roblox Studio while the real renderer (platform/render, M5) does not exist yet.

	Data: tools/studio/pack_map.py + studio-mapview.project.json. Run in Studio (edit mode is enough):
	    require(game.ReplicatedStorage.MapView.MapView).run()
	Progress and the result are attributes of Workspace.MapView (Status, Surfaces, Triangles, Parts, Textured).

	What it does NOT do (all of it is the renderer's job later): Q3 shaders (the texture is looked up by the
	shader's name only), lightmaps, vertex colours, sky, fog, transparency, the exact unit scale and camera.
	Quake axes (x east, y north, z up) become Roblox (x, z, -y); SCALE studs per Quake unit is a viewer choice.
]]
local AssetService = game:GetService("AssetService")

local MapView = {}

local SCALE = 0.1
local MAX_TRIANGLES = 20000 -- EditableMesh limits (G-002)
local MAX_VERTICES = 60000
local Q3SURFACEFLAG_SKY = 4
local Q3SURFACEFLAG_NODRAW = 128

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function base64decode(parts: { string }, total: number): buffer
	local lut = table.create(256, 0)
	for i = 1, 64 do
		lut[string.byte(B64, i) + 1] = i - 1
	end
	local out = buffer.create(total + 3)
	local o = 0
	for _, s in parts do
		local src = buffer.fromstring(s)
		for i = 0, #s - 4, 4 do
			local a = lut[buffer.readu8(src, i) + 1]
			local b = lut[buffer.readu8(src, i + 1) + 1]
			local c = lut[buffer.readu8(src, i + 2) + 1]
			local d = lut[buffer.readu8(src, i + 3) + 1]
			local n = a * 262144 + b * 4096 + c * 64 + d
			buffer.writeu8(out, o, n // 65536)
			buffer.writeu8(out, o + 1, (n // 256) % 256)
			buffer.writeu8(out, o + 2, n % 256)
			o += 3
		end
		task.wait()
	end
	return out
end

function MapView.run(): string
	local root = script.Parent :: Instance
	local xonotic = (root.Parent :: Instance):FindFirstChild("Xonotic") :: Instance
	local data = (root.Parent :: Instance):FindFirstChild("MapData") :: Instance
	local info = (require :: any)(data:FindFirstChild("info"))
	local engine = xonotic:FindFirstChild("engine") :: Instance
	local model_brush = (require :: any)(engine:FindFirstChild("model_brush"))
	local textures: { [string]: number } = (require :: any)(
		(xonotic:FindFirstChild("platform") :: any).render.texture_assets
	)

	local old = workspace:FindFirstChild("MapView")
	if old then
		old:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = "MapView"
	folder:SetAttribute("Status", "decoding " .. info.name)
	folder.Parent = workspace

	local parts = table.create(info.parts)
	for i = 1, info.parts do
		parts[i] = (require :: any)(data:FindFirstChild(string.format("part%03d", i)))
	end
	local bytes = base64decode(parts, info.bytes)
	folder:SetAttribute("Status", "loading (engine/model_brush.luau)")
	task.wait()
	local t0 = os.clock()
	local mod = model_brush.newmodel("maps/" .. info.name .. ".bsp")
	model_brush.Mod_IBSP_Load(mod, buffer.readstring(bytes, 0, info.bytes))
	folder:SetAttribute("LoadSeconds", os.clock() - t0)
	task.wait()

	local sm = mod.surfmesh
	local vertex3f: buffer, normal3f: buffer, tc2f: buffer, element3i: buffer =
		sm.data_vertex3f, sm.data_normal3f, sm.data_texcoordtexture2f, sm.data_element3i

	-- triangles per texture (surface order kept)
	local bytex: { [any]: { any } } = {}
	local order: { any } = {}
	local surfaces, triangles = 0, 0
	for _, s in mod.data_surfaces do
		local tex = s.texture
		if not tex or s.num_triangles == 0 then
			continue
		end
		if bit32.band(tex.surfaceflags, Q3SURFACEFLAG_NODRAW + Q3SURFACEFLAG_SKY) ~= 0 then
			continue
		end
		if string.sub(tex.name, 1, 16) == "textures/common/" then
			continue -- caulk, clip, trigger, ...: tool shaders that are never drawn
		end
		if not bytex[tex] then
			bytex[tex] = {}
			table.insert(order, tex)
		end
		table.insert(bytex[tex], s)
		surfaces += 1
		triangles += s.num_triangles
	end
	folder:SetAttribute("Surfaces", surfaces)
	folder:SetAttribute("Triangles", triangles)

	local made, textured, done = 0, 0, 0
	local function flush(tex: any, tris: { number })
		-- tris: flat list of global vertex indexes, 3 per triangle
		local minx, miny, minz = math.huge, math.huge, math.huge
		local maxx, maxy, maxz = -math.huge, -math.huge, -math.huge
		for _, v in tris do
			local x = buffer.readf32(vertex3f, v * 12) * SCALE
			local y = buffer.readf32(vertex3f, v * 12 + 8) * SCALE
			local z = -buffer.readf32(vertex3f, v * 12 + 4) * SCALE
			minx, miny, minz = math.min(minx, x), math.min(miny, y), math.min(minz, z)
			maxx, maxy, maxz = math.max(maxx, x), math.max(maxy, y), math.max(maxz, z)
		end
		local center = Vector3.new((minx + maxx) / 2, (miny + maxy) / 2, (minz + maxz) / 2)
		local em = AssetService:CreateEditableMesh()
		local vid: { [number]: number } = {}
		local uid: { [number]: number } = {}
		local nid: { [number]: number } = {}
		for i = 1, #tris, 3 do
			local ids, uvs, nrm = table.create(3), table.create(3), table.create(3)
			for k = 0, 2 do
				local v = tris[i + k]
				if not vid[v] then
					vid[v] = em:AddVertex(
						Vector3.new(
							buffer.readf32(vertex3f, v * 12) * SCALE,
							buffer.readf32(vertex3f, v * 12 + 8) * SCALE,
							-buffer.readf32(vertex3f, v * 12 + 4) * SCALE
						) - center
					)
					uid[v] = em:AddUV(Vector2.new(buffer.readf32(tc2f, v * 8), buffer.readf32(tc2f, v * 8 + 4)))
					nid[v] = em:AddNormal(
						Vector3.new(
							buffer.readf32(normal3f, v * 12),
							buffer.readf32(normal3f, v * 12 + 8),
							-buffer.readf32(normal3f, v * 12 + 4)
						)
					)
				end
				ids[k + 1], uvs[k + 1], nrm[k + 1] = vid[v], uid[v], nid[v]
			end
			local f = em:AddTriangle(ids[1], ids[2], ids[3])
			em:SetFaceUVs(f, uvs)
			em:SetFaceNormals(f, nrm)
		end
		local part = AssetService:CreateMeshPartAsync(Content.fromObject(em))
		part.Name = tex.name
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CastShadow = false
		part.DoubleSided = true
		part.Material = Enum.Material.SmoothPlastic
		local id = textures[tex.name .. ".jpg"]
		if id then
			part.TextureID = "rbxassetid://" .. tostring(id)
			textured += 1
		else
			-- no image with the shader's name (the shader script names another image): flat colour for now
			local h = 0
			for c = 1, #tex.name do
				h = (h * 31 + string.byte(tex.name, c)) % 360
			end
			part.Color = Color3.fromHSV(h / 360, 0.35, 0.75)
		end
		part.CFrame = CFrame.new(center)
		part.Parent = folder
		made += 1
	end

	for _, tex in order do
		local tris: { number } = {}
		local seen: { [number]: boolean } = {}
		local nverts = 0
		for _, s in bytex[tex] do
			if #tris // 3 + s.num_triangles > MAX_TRIANGLES or nverts + s.num_vertices > MAX_VERTICES then
				if #tris > 0 then
					flush(tex, tris)
				end
				tris, seen, nverts = {}, {}, 0
			end
			for j = 0, s.num_triangles * 3 - 1 do
				local v = buffer.readi32(element3i, (s.num_firsttriangle * 3 + j) * 4)
				if not seen[v] then
					seen[v] = true
					nverts += 1
				end
				table.insert(tris, v)
			end
			-- one surface alone can exceed the limits: split it by triangles
			while #tris // 3 > MAX_TRIANGLES do
				local head = table.move(tris, 1, MAX_TRIANGLES * 3, 1, {})
				flush(tex, head)
				tris = table.move(tris, MAX_TRIANGLES * 3 + 1, #tris, 1, {})
			end
		end
		if #tris > 0 then
			flush(tex, tris)
		end
		done += 1
		folder:SetAttribute("Status", string.format("meshing %d / %d textures", done, #order))
		folder:SetAttribute("Parts", made)
		folder:SetAttribute("Textured", textured)
		task.wait()
	end
	local msg = string.format(
		"%s: %d surfaces, %d triangles, %d parts (%d with their texture), load %.1f s",
		info.name,
		surfaces,
		triangles,
		made,
		textured,
		folder:GetAttribute("LoadSeconds") :: number
	)
	folder:SetAttribute("Status", "done: " .. msg)
	return msg
end

return MapView
