--!strict
-- The one asset manifest: semantic roles -> Roblox asset ids or ReplicatedStorage model names. UI
-- and world code reference roles, never raw ids, so an art swap touches this file only.
-- Image ids are the owner's station-button PNGs uploaded as image assets (docs/HANDOFF_PHASE4.md);
-- an empty string means "no image yet" and components fall back to the token-drawn frame.

local AssetManifest = {}

-- Station button images (owner-supplied art). Roles without art render the token frame + label.
AssetManifest.images = table.freeze({
	["station.shop"] = "rbxassetid://77310855238760",
	["station.classes"] = "rbxassetid://107137366563970",
	["station.stats"] = "rbxassetid://95977114214993",
	["station.daily"] = "",
	["station.inventory"] = "",
	["station.codes"] = "",
	["station.party"] = "",
	["station.event"] = "",
})

-- Models under ReplicatedStorage.SFE_Assets (Rojo maps assets/models). Free Creator Store meshes with
-- their source ids recorded as attributes on the instances (SFE_SourceAssetId).
AssetManifest.models = table.freeze({
	feather = "Feather",
	egg = "Egg",
})

function AssetManifest.image(role: string): string?
	local id = (AssetManifest.images :: any)[role]
	if type(id) ~= "string" or id == "" or string.find(id, "ASSET_", 1, true) then
		return nil
	end
	return id
end

local function assetFolder(): Instance?
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	return ReplicatedStorage:FindFirstChild("SFE_Assets")
end

-- Returns the template instance for a model role (or nil when the asset folder is unavailable).
function AssetManifest.model(role: string): Instance?
	local name = (AssetManifest.models :: any)[role]
	if type(name) ~= "string" then
		return nil
	end
	local folder = assetFolder()
	return folder and folder:FindFirstChild(name) or nil
end

-- A MeshPart whose mesh metadata never loaded (MeshSize 0,0,0) renders its mesh at the mesh's native
-- scale instead of its Size; the repo's Rojo-synced templates ship without that metadata, so a
-- 0.5-stud feather drew as a ~322-stud slab. Warm-up recreates each mesh through InsertService and
-- applies it to the template in place, keeping Size, colour, material, and attributes. Yields once
-- per mesh; safe to call anywhere (no-op outside Roblox, on healthy templates, or when the service
-- is unavailable). Returns the number of templates repaired.
function AssetManifest.warm(): number
	local folder = assetFolder()
	if not folder then
		return 0
	end
	local okService, InsertService = pcall(game.GetService, game, "InsertService")
	if not okService or not InsertService then
		return 0
	end
	local repaired = 0
	for _, name in pairs(AssetManifest.models) do
		local template = folder:FindFirstChild(name)
		if template and template:IsA("MeshPart") then
			-- Property reads are guarded: headless hosts may not model MeshPart metadata at all.
			local okProps, meshId, meshSize, collision, fidelity = pcall(function()
				local t = template :: any
				return t.MeshId, t.MeshSize, t.CollisionFidelity, t.RenderFidelity
			end)
			local healthy = not okProps
				or type(meshId) ~= "string"
				or meshId == ""
				or (typeof(meshSize) == "Vector3" and meshSize.Magnitude > 0)
			if not healthy then
				local okCreate, created = pcall(function()
					return (InsertService :: any):CreateMeshPartAsync(meshId, collision, fidelity)
				end)
				if okCreate and created then
					local size = template.Size
					local okApply = pcall(function()
						(template :: any):ApplyMesh(created)
					end)
					template.Size = size
					created:Destroy()
					if okApply then
						repaired += 1
					end
				end
			end
		end
	end
	return repaired
end

return AssetManifest
