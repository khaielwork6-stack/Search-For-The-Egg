--!strict
-- Tool Rack: one tab per tool, then big square skin tiles - art, a green EQUIP, a short name strip,
-- a gold keyline and a check when equipped, a lock and LOCKED when unowned. EQUIP (or tapping an
-- owned tile) equips it; the server validates and the modal re-renders from the profile projection.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local SkinCatalog = require(Shared.Domain.SkinCatalog)
local Depth = require(script.Parent.Parent.Components.Depth)
local FrameKit = require(script.Parent.Parent.Components.Frame)
local Button = require(script.Parent.Parent.Components.Button)
local Tabs = require(script.Parent.Parent.Components.Tabs)
local Skin = require(script.Parent.Parent.Components.Skin)
local Icons = require(script.Parent.Parent.Components.Icons)
local Tween = require(script.Parent.Parent.Components.Tween)

local InventoryModal = {}

export type Deps = {
	net: any,
	profile: any,
	audio: any,
	haptics: any,
	accessibility: any,
	config: { [string]: any },
	minimumTapTarget: number,
	toasts: any,
}

local SHORT_NAMES: { [string]: string } = {
	nestRake = "Rake",
	confettiCharge = "Charge",
	featherVac = "Vac",
	scoutChick = "Chick",
}

-- Card name: "Classic Nest Rake" -> "CLASSIC", "alienRakeSkin" -> "ALIEN".
local function shortName(skin: SkinCatalog.Skin): string
	if skin.source == "default" then
		return "CLASSIC"
	end
	local first = string.match(skin.displayName, "^(%a+)") or skin.displayName
	return string.upper(first)
end

function InventoryModal.build(container: ScrollingFrame, api: any, deps: Deps): () -> ()
	local cleanups: { any } = {}
	local cfg = deps.config
	local motion = deps.accessibility:motionSettings()
	local tap = deps.minimumTapTarget
	local z = container.ZIndex + 1
	local catalog = SkinCatalog.all(cfg)
	local selectedCategory = SkinCatalog.CATEGORIES[1]

	-- Tabs: one per tool.
	local items = {}
	for _, category in ipairs(SkinCatalog.CATEGORIES) do
		table.insert(items, { id = category, label = SHORT_NAMES[category] or cfg.tools[category].displayName })
	end
	local render
	local tabs = Tabs.build(container, {
		items = items,
		selected = selectedCategory,
		minimumTapTarget = tap,
		motion = motion,
		zIndex = z + 1,
		sound = function()
			deps.audio:play(Tokens.sound.uiTab)
		end,
		hoverSound = function()
			deps.audio:play(Tokens.sound.uiHover)
		end,
		onSelect = function(id)
			selectedCategory = id
			render()
		end,
	})
	tabs.frame.LayoutOrder = 1
	table.insert(cleanups, tabs.destroy)

	-- Tile grid: three per row. Each tile is art over an EQUIP button over the name strip.
	local cardSize = tap * 3
	local stripHeight = Tokens.typography.label.size + Tokens.spacing.md
	local equipHeight = math.floor(tap * 0.85)
	local cardHeight = cardSize + equipHeight + Tokens.spacing.sm
	local grid = Instance.new("Frame")
	grid.Name = "Cards"
	grid.BackgroundTransparency = 1
	grid.Size = UDim2.fromScale(1, 0)
	grid.AutomaticSize = Enum.AutomaticSize.Y
	grid.LayoutOrder = 2
	grid.ZIndex = z
	local gridLayout = Instance.new("UIGridLayout")
	gridLayout.CellSize = UDim2.fromOffset(cardSize, cardHeight)
	gridLayout.CellPadding = UDim2.fromOffset(Tokens.spacing.md, Tokens.spacing.md)
	gridLayout.SortOrder = Enum.SortOrder.LayoutOrder
	gridLayout.Parent = grid
	grid.Parent = container

	type Card = {
		skin: SkinCatalog.Skin,
		tile: Frame,
		face: Frame,
		scale: UIScale,
		art: ImageLabel?,
		name: TextLabel,
		lockLabel: TextLabel,
		lockGlyph: Frame,
		check: Frame,
		equip: Button.Handle,
		hit: TextButton,
	}
	local cards: { Card } = {}
	for index, skin in ipairs(catalog) do
		local tile, face = FrameKit.tile(grid, "Skin_" .. skin.id, {
			fill = Tokens.color.surface,
			deep = Tokens.color.panelDeep,
			zIndex = z + 1,
			radius = Tokens.radius.lg,
		})
		tile.LayoutOrder = index
		local scale = Instance.new("UIScale")
		scale.Parent = tile
		local artSize = cardHeight - stripHeight - equipHeight - Tokens.spacing.lg - Tokens.spacing.sm
		local art = Skin.icon(face, "tool." .. skin.category .. ".normal", artSize, z + 3)
		if art then
			art.AnchorPoint = Vector2.new(0.5, 0)
			art.Position = UDim2.new(0.5, 0, 0, Tokens.spacing.sm)
			if skin.source ~= "default" then
				-- Event skins: the same tool, tinted so the tile reads as a different finish.
				art.ImageColor3 = Tokens.color.leafBright
			end
		end
		local strip = Instance.new("Frame")
		strip.Name = "Strip"
		strip.AnchorPoint = Vector2.new(0.5, 1)
		strip.Position = UDim2.fromScale(0.5, 1)
		strip.Size = UDim2.new(1, 0, 0, stripHeight)
		strip.BackgroundColor3 = Tokens.color.panelDeep
		strip.BorderSizePixel = 0
		strip.ZIndex = z + 2
		local stripCorner = Instance.new("UICorner")
		stripCorner.CornerRadius = UDim.new(0, Tokens.radius.lg)
		stripCorner.Parent = strip
		strip.Parent = face
		local name = FrameKit.text(strip, "Name", shortName(skin), "label", {
			zIndex = z + 3,
			color = Tokens.color.featherWhite,
			align = Enum.TextXAlignment.Center,
		})
		name.Size = UDim2.fromScale(1, 1)
		FrameKit.outline(name, 2.5)
		local lockGlyph = Icons.lock(face, Tokens.icon.lg + Tokens.spacing.sm, { zIndex = z + 4, color = Tokens.color.featherWhite })
		lockGlyph.AnchorPoint = Vector2.new(0.5, 0.5)
		lockGlyph.Position = UDim2.new(0.5, 0, 0, Tokens.spacing.sm + artSize / 2)
		lockGlyph.Visible = false
		local lockLabel = FrameKit.text(face, "Locked", "LOCKED", "label", {
			zIndex = z + 4,
			color = Tokens.color.featherWhite,
			align = Enum.TextXAlignment.Center,
		})
		lockLabel.AnchorPoint = Vector2.new(0.5, 1)
		lockLabel.Position = UDim2.new(0.5, 0, 1, -(stripHeight + Tokens.spacing.xs))
		lockLabel.Size = UDim2.new(1, 0, 0, equipHeight)
		lockLabel.TextYAlignment = Enum.TextYAlignment.Center
		FrameKit.outline(lockLabel, 2.6)
		lockLabel.Visible = false
		local check = Instance.new("Frame")
		check.Name = "Check"
		check.AnchorPoint = Vector2.new(1, 0)
		check.Position = UDim2.new(1, Tokens.spacing.xs, 0, -Tokens.spacing.xs)
		check.Size = UDim2.fromOffset(Tokens.icon.lg + 4, Tokens.icon.lg + 4)
		check.BackgroundColor3 = Tokens.color.success
		check.ZIndex = z + 5
		local checkCorner = Instance.new("UICorner")
		checkCorner.CornerRadius = UDim.new(1, 0)
		checkCorner.Parent = check
		local checkStroke = Instance.new("UIStroke")
		checkStroke.Thickness = Tokens.stroke.bold
		checkStroke.Color = Tokens.color.outline
		checkStroke.Parent = check
		local checkGlyph = Icons.check(check, Tokens.icon.md, { zIndex = z + 6, color = Tokens.color.featherWhite })
		checkGlyph.AnchorPoint = Vector2.new(0.5, 0.5)
		checkGlyph.Position = UDim2.fromScale(0.5, 0.5)
		check.Visible = false
		check.Parent = tile
		local hit = Instance.new("TextButton")
		hit.Name = "Hit"
		hit.Text = ""
		hit.BackgroundTransparency = 1
		hit.Size = UDim2.fromScale(1, 1)
		hit.ZIndex = z + 6
		hit.Parent = tile

		-- One equip path for the tile tap and the EQUIP button.
		local function equip()
			local projection = deps.profile.projection
			local owned = skin.source == "default" or (projection and projection.inventory.toolSkins[skin.id] == true)
			if not owned then
				deps.audio:play(Tokens.sound.uiError)
				Tween.shake(tile, motion)
				deps.toasts:push("Drops from the Moonlit Chest", "info")
				return
			end
			deps.audio:play(Tokens.sound.uiTap)
			local result = deps.net:request("InventoryEquip", { category = skin.category, itemId = skin.id })
			if result.ok then
				deps.audio:play(Tokens.sound.uiConfirm)
				deps.haptics:pulse(0.3, 0.06)
				scale.Scale = 1.1
				Tween.scale(scale, "release", motion, 1)
			else
				deps.audio:play(Tokens.sound.uiError)
				deps.toasts:push("Could not equip", "warning")
			end
		end
		-- The button is a sibling of the hit frame, above it, so its own press wins over the tile's.
		local equipHandle = Button.build(tile, {
			text = "EQUIP",
			variant = "success",
			minimumTapTarget = tap,
			motion = motion,
			size = UDim2.new(1, -Tokens.spacing.lg, 0, equipHeight),
			zIndex = z + 7,
			textSize = Tokens.typography.label.size,
			sound = function()
				deps.audio:play(Tokens.sound.uiTap)
			end,
			hoverSound = function()
				deps.audio:play(Tokens.sound.uiHover)
			end,
			onActivated = equip,
		})
		equipHandle.button.Name = "Equip"
		equipHandle.button.AnchorPoint = Vector2.new(0.5, 1)
		equipHandle.button.Position = UDim2.new(0.5, 0, 1, -(stripHeight + Tokens.spacing.xs + 5))
		table.insert(cleanups, equipHandle.destroy)

		local card: Card = {
			skin = skin,
			tile = tile,
			face = face,
			scale = scale,
			art = art,
			name = name,
			lockLabel = lockLabel,
			lockGlyph = lockGlyph,
			check = check,
			equip = equipHandle,
			hit = hit,
		}
		table.insert(cards, card)
		table.insert(
			cleanups,
			hit.MouseEnter:Connect(function()
				deps.audio:play(Tokens.sound.uiHover)
				TweenService:Create(scale, TweenInfo.new(0.12), { Scale = 1.04 }):Play()
			end)
		)
		table.insert(
			cleanups,
			hit.MouseLeave:Connect(function()
				TweenService:Create(scale, TweenInfo.new(0.16), { Scale = 1 }):Play()
			end)
		)
		table.insert(cleanups, hit.Activated:Connect(equip))
	end

	local close = Button.build(container, {
		text = "Close",
		variant = "danger",
		minimumTapTarget = tap,
		motion = motion,
		size = UDim2.new(1, 0, 0, tap),
		zIndex = z + 1,
		sound = function()
			deps.audio:play(Tokens.sound.uiTap)
		end,
		hoverSound = function()
			deps.audio:play(Tokens.sound.uiHover)
		end,
		onActivated = api.close,
	})
	close.button.LayoutOrder = 3
	table.insert(cleanups, close.destroy)

	render = function()
		local projection = deps.profile.projection
		local first: TextButton? = nil
		for _, card in ipairs(cards) do
			local show = card.skin.category == selectedCategory
			card.tile.Visible = show
			if not show then
				continue
			end
			first = first or card.hit
			local owned = card.skin.source == "default" or (projection ~= nil and projection.inventory.toolSkins[card.skin.id] == true)
			local equipped = projection ~= nil and projection.inventory.equippedSkins[card.skin.category] == card.skin.id
			-- Dark slate throughout; the equipped tile earns a gold keyline, a locked one sinks.
			local fill = if owned then Tokens.color.surface else Tokens.color.surfaceAlt
			card.face.BackgroundColor3 = fill
			Depth.applySheen(card.face, fill)
			local keyline = Depth.keylineOf(card.tile)
			if keyline then
				keyline.Color = if equipped then Tokens.color.gold else Tokens.color.outline
				keyline.Thickness = if equipped then Tokens.stroke.frame + 1 else Tokens.stroke.frame
			end
			if card.art then
				card.art.ImageTransparency = if owned then 0 else 0.6
			end
			card.lockGlyph.Visible = not owned
			card.lockLabel.Visible = not owned
			card.equip.button.Visible = owned and not equipped
			card.check.Visible = equipped
		end
		if first then
			api.setInitialFocus(first)
		end
	end

	render()
	table.insert(cleanups, deps.profile.changed:Connect(render))
	deps.audio:play(Tokens.sound.uiOpen)

	return function()
		for _, cleanup in ipairs(cleanups) do
			if type(cleanup) == "function" then
				cleanup()
			else
				cleanup:Disconnect()
			end
		end
		deps.audio:play(Tokens.sound.uiClose)
	end
end

return InventoryModal
