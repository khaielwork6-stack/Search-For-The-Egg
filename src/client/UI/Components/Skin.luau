--!strict
-- Image skins: nine-sliced ImageLabels from the asset manifest that sit behind live text so art
-- never stretches or blurs and every string stays a Roblox TextLabel. Roles without art return nil
-- and callers keep their token-drawn fallback.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local AssetManifest = require(Shared.Design.AssetManifest)

local Skin = {}

-- Frame art (buttons, chips, banners, cards, text boxes) is retired: those pieces are drawn in code
-- so nothing reads as a pasted kit. Icons, glyphs, textures and station faces still come from art.
Skin.frameArtEnabled = false
local FRAME_PREFIXES = {
	"button.",
	"hud.chip",
	"hud.banner",
	"hud.timer",
	"hud.cash",
	"hud.bag",
	"hud.prompt",
	"hotbar.slot",
	"hotbar.status",
	"class.",
	"daily.",
	"textbox.",
	"party.",
	"modal.title",
	"modal.row",
	"prompt.action",
	"focus.ring",
	"victory.plate",
	"cutscene.caption",
	"meter.",
}
local function isFrameRole(role: string): boolean
	for _, prefix in ipairs(FRAME_PREFIXES) do
		if string.sub(role, 1, #prefix) == prefix then
			return true
		end
	end
	return false
end

-- A painted piece of the barn laid over a control: a glossy rim over a button face, a rarity frame
-- over a class card, the crate frame around a panel. Full-size (plus `inset` past the edges), sliced
-- at `sliceScale`, drawn at `zIndex`. This deliberately ignores the frame-art gate above: the gate
-- retired the old full-face art; these are rims and frames the owner asked for by name.
function Skin.overlay(
	parent: GuiObject,
	role: string,
	options: { zIndex: number?, inset: number?, sliceScale: number?, name: string?, color: Color3?, transparency: number? }?
): ImageLabel?
	local opts = (options or {}) :: any
	local id, rect = AssetManifest.skin(role)
	if not id then
		return nil
	end
	local inset = opts.inset or 0
	local label = Instance.new("ImageLabel")
	label.Name = opts.name or ("Skin_" .. role)
	label.BackgroundTransparency = 1
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromScale(0.5, 0.5)
	label.Size = UDim2.new(1, inset * 2, 1, inset * 2)
	label.Image = id
	if rect then
		label.ScaleType = Enum.ScaleType.Slice
		label.SliceCenter = rect
		label.SliceScale = opts.sliceScale or 1
	else
		label.ScaleType = Enum.ScaleType.Fit
	end
	if opts.color then
		label.ImageColor3 = opts.color
	end
	label.ImageTransparency = opts.transparency or 0
	label.ZIndex = opts.zIndex or (parent.ZIndex + 1)
	label.Parent = parent
	return label
end

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
	if not Skin.frameArtEnabled and isFrameRole(role) then
		return nil
	end
	local id = AssetManifest.image(role)
	if not id then
		return nil
	end
	local label = Instance.new("ImageLabel")
	label.Name = opts.name or "Skin"
	label.BackgroundTransparency = 1
	local inset = opts.inset or 0
	local padding = parent:FindFirstChildOfClass("UIPadding")
	local left = if padding then padding.PaddingLeft.Offset else 0
	local right = if padding then padding.PaddingRight.Offset else 0
	local top = if padding then padding.PaddingTop.Offset else 0
	local bottom = if padding then padding.PaddingBottom.Offset else 0
	label.Position = UDim2.fromOffset(-inset - left, -inset - top)
	label.Size = UDim2.new(1, inset * 2 + left + right, 1, inset * 2 + top + bottom)
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
	if not Skin.frameArtEnabled and isFrameRole(role) then
		return false
	end
	return AssetManifest.image(role) ~= nil
end

-- Texture overlay (rays / studs) stretched or tiled across a surface at low alpha.
function Skin.texture(
	parent: GuiObject,
	role: string,
	options: { zIndex: number?, transparency: number?, color: Color3?, tile: number?, name: string? }?
): ImageLabel?
	local opts = (options or {}) :: any
	local id = AssetManifest.image(role)
	if not id then
		return nil
	end
	local label = Instance.new("ImageLabel")
	label.Name = opts.name or "Texture"
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Image = id
	label.ImageTransparency = opts.transparency or 0.9
	label.ImageColor3 = opts.color or Color3.new(1, 1, 1)
	if opts.tile then
		label.ScaleType = Enum.ScaleType.Tile
		label.TileSize = UDim2.fromOffset(opts.tile, opts.tile)
	else
		label.ScaleType = Enum.ScaleType.Crop
	end
	label.ZIndex = opts.zIndex or parent.ZIndex
	label.Parent = parent
	return label
end

return Skin
