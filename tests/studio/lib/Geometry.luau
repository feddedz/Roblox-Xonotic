--!strict
-- Runtime geometry and images through the documented AssetService routes (docs read 2026-11-20):
-- CreateEditableMesh / CreateMeshPartAsync, CreateEditableImage (max 1024x1024, nil when the
-- per-device budget is exhausted), CreateSurfaceAppearanceAsync (maps fixed at creation; EditableImages
-- do not replicate, so this runs on the client).
local AssetService = game:GetService("AssetService")

local Geometry = {}

-- Solid-colour image; rgba components 0..255.
function Geometry.solidImage(size: number, r: number, g: number, b: number, a: number): any
	local img = AssetService:CreateEditableImage({ Size = Vector2.new(size, size) })
	if img == nil then
		return nil
	end
	local buf = buffer.create(size * size * 4)
	for i = 0, size * size - 1 do
		buffer.writeu8(buf, i * 4, r)
		buffer.writeu8(buf, i * 4 + 1, g)
		buffer.writeu8(buf, i * 4 + 2, b)
		buffer.writeu8(buf, i * 4 + 3, a)
	end
	img:WritePixelsBuffer(Vector2.zero, Vector2.new(size, size), buf)
	return img
end

-- Image from a per-pixel function returning r, g, b, a (0..255).
function Geometry.imageFrom(size: number, fn: (x: number, y: number) -> (number, number, number, number)): any
	local img = AssetService:CreateEditableImage({ Size = Vector2.new(size, size) })
	if img == nil then
		return nil
	end
	local buf = buffer.create(size * size * 4)
	for y = 0, size - 1 do
		for x = 0, size - 1 do
			local r, g, b, a = fn(x, y)
			local o = (y * size + x) * 4
			buffer.writeu8(buf, o, r)
			buffer.writeu8(buf, o + 1, g)
			buffer.writeu8(buf, o + 2, b)
			buffer.writeu8(buf, o + 3, a)
		end
	end
	img:WritePixelsBuffer(Vector2.zero, Vector2.new(size, size), buf)
	return img
end

-- A w x h quad facing +Z (two triangles, UV 0..1), as an anchored MeshPart.
function Geometry.quad(w: number, h: number): MeshPart
	local em = AssetService:CreateEditableMesh()
	local p = {
		em:AddVertex(Vector3.new(-w / 2, -h / 2, 0)),
		em:AddVertex(Vector3.new(w / 2, -h / 2, 0)),
		em:AddVertex(Vector3.new(w / 2, h / 2, 0)),
		em:AddVertex(Vector3.new(-w / 2, h / 2, 0)),
	}
	local uv = {
		em:AddUV(Vector2.new(0, 1)),
		em:AddUV(Vector2.new(1, 1)),
		em:AddUV(Vector2.new(1, 0)),
		em:AddUV(Vector2.new(0, 0)),
	}
	local n = em:AddNormal(Vector3.new(0, 0, 1))
	for _, tri in { { 1, 2, 3 }, { 1, 3, 4 } } do
		local f = em:AddTriangle(p[tri[1]], p[tri[2]], p[tri[3]])
		em:SetFaceUVs(f, { uv[tri[1]], uv[tri[2]], uv[tri[3]] })
		em:SetFaceNormals(f, { n, n, n })
	end
	local part = AssetService:CreateMeshPartAsync(Content.fromObject(em))
	part.Anchored = true
	part.CanCollide = false
	return part
end

-- Applies PBR maps (EditableImages) to a MeshPart. Missing maps are omitted.
function Geometry.applyMaps(part: MeshPart, maps: { [string]: any })
	local content = {}
	for k, img in maps do
		content[k] = Content.fromObject(img)
	end
	local sa = AssetService:CreateSurfaceAppearanceAsync(content)
	sa.Parent = part
end

return Geometry
