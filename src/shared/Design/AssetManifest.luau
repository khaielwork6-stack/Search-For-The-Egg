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

-- The canonical mesh asset id per model role. Rojo's rbxm sync drops the MeshId/MeshSize metadata off
-- MeshParts (the synced template renders as a blank box), so `warm()` rebuilds the mesh from these
-- ids and applies it to the template in place. These are the ids the owner's source meshes carry.
AssetManifest.meshAssets = table.freeze({
	feather = "rbxassetid://439102658",
	egg = "rbxassetid://873833344",
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

-- True when the template's mesh actually loaded (non-zero MeshSize). A blank MeshPart (Rojo-stripped
-- MeshId or unloaded metadata) reports MeshSize (0,0,0) and renders as its bounding box.
local function meshHealthy(template: Instance): boolean
	if not template:IsA("MeshPart") then
		return true
	end
	local okProps, meshSize = pcall(function()
		return (template :: any).MeshSize
	end)
	return not okProps or (typeof(meshSize) == "Vector3" and meshSize.Magnitude > 0)
end

-- Returns the template instance for a model role (or nil when the asset folder is unavailable).
function AssetManifest.model(role: string): Instance?
	local name = (AssetManifest.models :: any)[role]
	if type(name) ~= "string" then
		return nil
	end
	local folder = assetFolder()
	local template = folder and folder:FindFirstChild(name)
	-- Only hand out a mesh template once its mesh is loaded; otherwise callers should use their own
	-- fallback (a plain part) rather than clone a blank box that renders as a slab.
	if template and template:IsA("MeshPart") and not meshHealthy(template) then
		return nil
	end
	return template
end

-- Rebuilds each model role's mesh from `meshAssets` when the synced template is blank, applying the
-- fresh mesh in place and keeping the template's Size, colour, material, and double-sided flag.
-- Yields once per repaired mesh. Safe to call on server and client, more than once (idempotent), and
-- no-ops outside Roblox or when InsertService/asset access is unavailable. Returns the repair count.
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
	for role, name in pairs(AssetManifest.models) do
		local template = folder:FindFirstChild(name)
		local meshId = (AssetManifest.meshAssets :: any)[role]
		if template and template:IsA("MeshPart") and type(meshId) == "string" and meshId ~= "" and not meshHealthy(template) then
			local okCreate, created = pcall(function()
				return (InsertService :: any):CreateMeshPartAsync(meshId, Enum.CollisionFidelity.Box, Enum.RenderFidelity.Precise)
			end)
			if okCreate and created then
				local size = template.Size
				local okApply = pcall(function()
					(template :: any):ApplyMesh(created)
				end)
				template.Size = size
				-- Distance LOD and both faces: a big pile of these clones stays cheap and never shows a
				-- culled back face at a grazing angle.
				pcall(function()
					local t = template :: any
					t.RenderFidelity = Enum.RenderFidelity.Automatic
					t.DoubleSided = true
				end)
				created:Destroy()
				if okApply and meshHealthy(template) then
					repaired += 1
				end
			end
		end
	end
	return repaired
end

return AssetManifest
