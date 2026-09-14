--!strict
-- Image skins: nine-sliced ImageLabels from the asset manifest that sit behind live text so art
-- never stretches or blurs and every string stays a Roblox TextLabel. Roles without art return nil
-- and callers keep their token-drawn fallback.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local AssetManifest = require(Shared.Design.AssetManifest)

local Skin = {}

-- Applies a role's image + slice settings to an existing ImageLabel/ImageButton. Returns success.
function Skin.apply(image: ImageLabel | ImageButton, role: string): boolean
	local id, rect, scale = AssetManifest.skin(role)
	if not id then
		return false
	end
	image.Image = id
	if rect then
		image.ScaleType = Enum.ScaleType.Slice
		image.SliceCenter = rect
		image.SliceScale = scale
	else
		image.ScaleType = Enum.ScaleType.Fit
	end
	return true
end

-- Creates a full-size skin behind the parent's content (ZIndex just above the parent's own
-- background). `inset` grows the label past the parent's edges so art with outer shadow fits.
function Skin.label(parent: GuiObject, role: string, options: { zIndex: number?, inset: number?, name: string? }?): ImageLabel?
	local opts = (options or {}) :: any
	local id = AssetManifest.image(role)
	if not id then
		return nil
	end
	local label = Instance.new("ImageLabel")
	label.Name = opts.name or "Skin"
	label.BackgroundTransparency = 1
	local inset = opts.inset or 0
	label.Position = UDim2.fromOffset(-inset, -inset)
	label.Size = UDim2.new(1, inset * 2, 1, inset * 2)
	label.ZIndex = opts.zIndex or parent.ZIndex
	Skin.apply(label, role)
	label.Parent = parent
	return label
end

-- Icon image (Fit) sized to px, or nil without art.
function Skin.icon(parent: Instance, role: string, px: number, zIndex: number?): ImageLabel?
	local id = AssetManifest.image(role)
	if not id then
		return nil
	end
	local label = Instance.new("ImageLabel")
	label.Name = "Icon_" .. role
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromOffset(px, px)
	label.Image = id
	label.ScaleType = Enum.ScaleType.Fit
	label.ZIndex = zIndex or 1
	label.Parent = parent
	return label
end

function Skin.has(role: string): boolean
	return AssetManifest.image(role) ~= nil
end

return Skin
