--!strict
-- Gem Shop: the gem bundles as tall cards (the 1,500 POPULAR bundle with chest art, an animated
-- rainbow border and sparkles) plus the 2x Gems pass. Every price comes from the config; every
-- purchase goes through the server's PurchasePromptRequest (mock Marketplace in Studio).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local Depth = require(script.Parent.Parent.Components.Depth)
local FrameKit = require(script.Parent.Parent.Components.Frame)
local Button = require(script.Parent.Parent.Components.Button)
local Skin = require(script.Parent.Parent.Components.Skin)
local Icons = require(script.Parent.Parent.Components.Icons)
local Tween = require(script.Parent.Parent.Components.Tween)
local Confetti = require(script.Parent.Parent.Components.Confetti)
local SafeArea = require(script.Parent.Parent.SafeArea)
local UpgradeActions = require(script.Parent.Parent.UpgradeActions)

local GemShopModal = {}

export type Deps = {
	net: any,
	profile: any,
	audio: any,
	haptics: any,
	accessibility: any,
	config: { [string]: any },
	minimumTapTarget: number,
	toasts: any,
	quality: any?,
	entitlements: (() -> { [string]: boolean })?,
}

local RAINBOW = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 80, 80)),
	ColorSequenceKeypoint.new(0.17, Color3.fromRGB(255, 190, 60)),
	ColorSequenceKeypoint.new(0.34, Color3.fromRGB(120, 230, 90)),
	ColorSequenceKeypoint.new(0.5, Color3.fromRGB(80, 210, 255)),
	ColorSequenceKeypoint.new(0.67, Color3.fromRGB(140, 110, 255)),
	ColorSequenceKeypoint.new(0.84, Color3.fromRGB(255, 110, 220)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 80, 80)),
})

local function formatGems(count: number): string
	local text = tostring(count)
	while true do
		local replaced, n = text:gsub("^(-?%d+)(%d%d%d)", "%1,%2")
		text = replaced
		if n == 0 then
			break
		end
	end
	return text
end

-- Vector chest: a brown box, a domed lid, a gold clasp, and a heap of gems spilling over the rim.
local function chestArt(parent: GuiObject, px: number, z: number): Frame
	local frame = Instance.new("Frame")
	frame.Name = "Chest"
	frame.Size = UDim2.fromOffset(px, px)
	frame.BackgroundTransparency = 1
	frame.ZIndex = z
	frame.Parent = parent
	local function piece(name: string, size: UDim2, position: UDim2, color: Color3, radius: number, order: number, rotation: number?)
		local part = Instance.new("Frame")
		part.Name = name
		part.AnchorPoint = Vector2.new(0.5, 0.5)
		part.Size = size
		part.Position = position
		part.BackgroundColor3 = color
		part.BorderSizePixel = 0
		part.Rotation = rotation or 0
		part.ZIndex = z + order
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, radius)
		corner.Parent = part
		local stroke = Instance.new("UIStroke")
		stroke.Thickness = Tokens.stroke.standard
		stroke.Color = Tokens.color.outline
		stroke.Parent = part
		part.Parent = frame
		return part
	end
	local wood = Color3.fromRGB(150, 96, 52)
	local woodDeep = Color3.fromRGB(110, 66, 34)
	piece("Body", UDim2.fromScale(0.78, 0.42), UDim2.fromScale(0.5, 0.72), wood, math.floor(px * 0.08), 1)
	piece("Band", UDim2.fromScale(0.78, 0.08), UDim2.fromScale(0.5, 0.62), woodDeep, 2, 2)
	piece("Lid", UDim2.fromScale(0.8, 0.26), UDim2.fromScale(0.5, 0.44), woodDeep, math.floor(px * 0.16), 1)
	piece("Clasp", UDim2.fromScale(0.14, 0.14), UDim2.fromScale(0.5, 0.6), Tokens.color.gold, math.floor(px * 0.04), 3)
	-- Gems heaped over the rim.
	local gemColors = { Color3.fromRGB(96, 178, 236), Color3.fromRGB(140, 210, 255), Color3.fromRGB(70, 140, 220) }
	local spots = { { 0.3, 0.38 }, { 0.5, 0.3 }, { 0.7, 0.4 }, { 0.4, 0.46 }, { 0.6, 0.48 } }
	for index, spot in ipairs(spots) do
		local gem = piece(
			"Gem" .. index,
			UDim2.fromScale(0.18, 0.18),
			UDim2.fromScale(spot[1], spot[2]),
			gemColors[(index % 3) + 1],
			math.floor(px * 0.03),
			4,
			45
		)
		local shine = Instance.new("Frame")
		shine.AnchorPoint = Vector2.new(0.5, 0.5)
		shine.Size = UDim2.fromScale(0.35, 0.35)
		shine.Position = UDim2.fromScale(0.35, 0.35)
		shine.BackgroundColor3 = Tokens.color.featherWhite
		shine.BackgroundTransparency = 0.3
		shine.BorderSizePixel = 0
		shine.ZIndex = z + 5
		local shineCorner = Instance.new("UICorner")
		shineCorner.CornerRadius = UDim.new(1, 0)
		shineCorner.Parent = shine
		shine.Parent = gem
	end
	return frame
end

function GemShopModal.build(container: ScrollingFrame, api: any, deps: Deps): () -> ()
	local cleanups: { any } = {}
	local cfg = deps.config
	local motion = deps.accessibility:motionSettings()
	local tap = deps.minimumTapTarget
	local z = container.ZIndex + 1
	local tier = deps.quality and deps.quality:tier() or nil
	local compact = SafeArea.classOf(container) == "phone"
	local function entitlements(): { [string]: boolean }
		return deps.entitlements and deps.entitlements() or {}
	end
	local promptDeps = { net = deps.net, audio = deps.audio, toasts = deps.toasts }

	-- Balance strip.
	local top = Instance.new("Frame")
	top.Name = "Top"
	top.BackgroundTransparency = 1
	top.Size = UDim2.new(1, 0, 0, tap)
	top.LayoutOrder = 1
	top.ZIndex = z
	top.Parent = container
	local subtitle = FrameKit.text(top, "Subtitle", "GEMS FOR SPINS AND PERKS", "title", { zIndex = z, color = Tokens.color.goldDeep })
	subtitle.Size = UDim2.new(1, -(tap * 4), 1, 0)
	subtitle.TextYAlignment = Enum.TextYAlignment.Center
	FrameKit.outline(subtitle, 2, Tokens.color.featherWhite)
	local balanceChip, balanceLabel, balanceIcon = FrameKit.chip(top, "Balance", { zIndex = z + 1, height = tap - Tokens.spacing.xs })
	balanceIcon.Visible = true
	if not Skin.icon(balanceIcon, "hud.gem", Tokens.icon.md, balanceIcon.ZIndex + 1) then
		Icons.gem(balanceIcon, Tokens.icon.md, { zIndex = balanceIcon.ZIndex + 1 })
	end
	balanceChip.AnchorPoint = Vector2.new(1, 0.5)
	balanceChip.Position = UDim2.fromScale(1, 0.5)

	-- Cards row.
	local bundles = cfg.monetization and cfg.monetization.gemBundles or {}
	local passes = cfg.monetization and cfg.monetization.passes or {}
	local cardCount = math.max(1, #bundles + (if passes.doubleGems then 1 else 0))
	local cardHeight = if compact then tap * 4 else tap * 5 + Tokens.spacing.lg
	local row = Instance.new("Frame")
	row.Name = "Cards"
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, cardHeight + Tokens.spacing.lg)
	row.LayoutOrder = 2
	row.ZIndex = z
	local rowLayout = Instance.new("UIListLayout")
	rowLayout.FillDirection = Enum.FillDirection.Horizontal
	rowLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	rowLayout.VerticalAlignment = Enum.VerticalAlignment.Bottom
	rowLayout.Padding = UDim.new(0, Tokens.spacing.sm)
	rowLayout.SortOrder = Enum.SortOrder.LayoutOrder
	rowLayout.Parent = row
	row.Parent = container

	type Card = {
		key: string,
		pass: string?,
		tile: Frame,
		scale: UIScale,
		buy: any,
		owned: TextLabel,
		rainbow: UIGradient?,
		sheen: UIGradient?,
	}
	local cards: { Card } = {}
	local animated: { { gradient: UIGradient, speed: number } } = {}
	local function card(
		order: number,
		key: string,
		name: string,
		caption: string,
		robux: number?,
		options: { popular: boolean?, pass: string?, chest: boolean? }
	)
		local popular = options.popular == true
		local fill = if options.pass then Tokens.color.tealAccent elseif popular then Tokens.color.skyDeep else Tokens.color.sky
		local deep = if options.pass then Tokens.color.tealDeep elseif popular then Color3.fromRGB(44, 96, 150) else Tokens.color.skyDeep
		-- Cards share the row width so every bundle fits on one line at any size.
		local tile, face = FrameKit.tile(row, "Card_" .. key, {
			fill = fill,
			deep = deep,
			zIndex = z + 1,
			radius = Tokens.radius.lg,
			size = UDim2.new(1 / cardCount, -Tokens.spacing.sm, 0, if popular then cardHeight + Tokens.spacing.lg else cardHeight),
		})
		tile.LayoutOrder = order
		local scale = Instance.new("UIScale")
		scale.Parent = tile
		local rainbow: UIGradient? = nil
		local sheen: UIGradient? = nil
		if popular then
			-- Animated rainbow border and a travelling sheen: the premium card.
			local outline = Depth.keylineOf(tile) :: UIStroke?
			if outline then
				outline.Thickness = Tokens.stroke.frame + 2
				outline.Color = Color3.new(1, 1, 1)
				rainbow = Instance.new("UIGradient")
				rainbow.Color = RAINBOW
				rainbow.Parent = outline
				table.insert(animated, { gradient = rainbow :: UIGradient, speed = 40 })
			end
			local sheenFrame = Instance.new("Frame")
			sheenFrame.Name = "Sheen"
			sheenFrame.Size = UDim2.fromScale(1, 1)
			sheenFrame.BackgroundColor3 = Color3.new(1, 1, 1)
			sheenFrame.BackgroundTransparency = 0.7
			sheenFrame.BorderSizePixel = 0
			sheenFrame.ZIndex = z + 2
			local sheenCorner = Instance.new("UICorner")
			sheenCorner.CornerRadius = UDim.new(0, Tokens.radius.lg)
			sheenCorner.Parent = sheenFrame
			sheen = Instance.new("UIGradient")
			sheen.Rotation = 25
			sheen.Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 1),
				NumberSequenceKeypoint.new(0.45, 1),
				NumberSequenceKeypoint.new(0.5, 0.55),
				NumberSequenceKeypoint.new(0.55, 1),
				NumberSequenceKeypoint.new(1, 1),
			})
			sheen.Parent = sheenFrame
			sheenFrame.Parent = face
		end
		local title = FrameKit.text(face, "Name", name, "title", {
			zIndex = z + 3,
			color = Tokens.color.featherWhite,
			align = Enum.TextXAlignment.Center,
		})
		title.Position = UDim2.fromOffset(0, if popular then Tokens.spacing.lg + 2 else Tokens.spacing.sm)
		title.Size = UDim2.new(1, 0, 0, Tokens.typography.title.size + 4)
		title.TextSize = if popular then Tokens.typography.title.size + 2 else Tokens.typography.title.size - 2
		FrameKit.outline(title, 2.4)
		local artHolder = Instance.new("Frame")
		artHolder.Name = "Art"
		artHolder.AnchorPoint = Vector2.new(0.5, 0.5)
		artHolder.Position = UDim2.fromScale(0.5, if popular then 0.47 else 0.45)
		local artPx = if popular then tap * 2 + Tokens.spacing.lg else tap * 2
		artHolder.Size = UDim2.fromOffset(artPx, artPx)
		artHolder.BackgroundTransparency = 1
		artHolder.ZIndex = z + 3
		artHolder.Parent = face
		Skin.texture(artHolder, "texture.sunburst", { zIndex = z + 3, transparency = 0.6, color = Tokens.color.featherWhite })
		if options.chest then
			chestArt(artHolder, artPx, z + 4)
		else
			local glyph = Skin.icon(artHolder, "hud.gem", math.floor(artPx * 0.7), z + 4)
				or Icons.gem(artHolder, math.floor(artPx * 0.7), { zIndex = z + 4 })
			glyph.AnchorPoint = Vector2.new(0.5, 0.5)
			glyph.Position = UDim2.fromScale(0.5, 0.5)
		end
		local captionLabel = FrameKit.text(face, "Caption", caption, "caption", {
			zIndex = z + 3,
			color = Tokens.color.featherWhite,
			align = Enum.TextXAlignment.Center,
		})
		captionLabel.AnchorPoint = Vector2.new(0.5, 1)
		captionLabel.Position = UDim2.new(0.5, 0, 1, -(tap + Tokens.spacing.md))
		captionLabel.Size = UDim2.new(1, 0, 0, Tokens.typography.caption.size + 4)
		FrameKit.outline(captionLabel, 1.6)
		local buy = Button.build(face, {
			text = if robux then string.format("R$ %d", robux) else "R$",
			variant = if popular then "success" else "primary",
			minimumTapTarget = tap,
			motion = motion,
			size = UDim2.new(1, -Tokens.spacing.md, 0, tap - Tokens.spacing.xs),
			zIndex = z + 4,
			textSize = Tokens.typography.label.size + 2,
			sound = function()
				deps.audio:play(Tokens.sound.uiTap)
			end,
			hoverSound = function()
				deps.audio:play(Tokens.sound.uiHover)
			end,
			onActivated = function()
				local result = UpgradeActions.promptPurchase(promptDeps, key, name)
				if result.ok then
					scale.Scale = 1.05
					Tween.scale(scale, "release", motion, 1)
					Confetti.burst(
						tile,
						{ origin = UDim2.fromScale(0.5, 0.45), count = 24, spread = 150, motion = motion, tier = tier, zIndex = z + 9 }
					)
				end
			end,
		})
		buy.button.AnchorPoint = Vector2.new(0.5, 1)
		buy.button.Position = UDim2.new(0.5, 0, 1, -Tokens.spacing.sm)
		table.insert(cleanups, buy.destroy)
		local owned = FrameKit.badge(face, "Owned", "OWNED", Tokens.color.success, z + 5)
		owned.AnchorPoint = Vector2.new(0.5, 1)
		owned.Position = UDim2.new(0.5, 0, 1, -Tokens.spacing.md)
		owned.Visible = false
		if popular then
			local ribbon = FrameKit.badge(tile, "Popular", "POPULAR", Tokens.color.ember, z + 6)
			ribbon.AnchorPoint = Vector2.new(0.5, 0)
			ribbon.Position = UDim2.new(0.5, 0, 0, -Tokens.spacing.md)
			ribbon.TextSize = Tokens.typography.caption.size + 1
			local ribbonGradient = Instance.new("UIGradient")
			ribbonGradient.Color = RAINBOW
			ribbonGradient.Parent = ribbon
			table.insert(animated, { gradient = ribbonGradient, speed = 60 })
		elseif options.pass then
			local tag = FrameKit.badge(tile, "Tag", "PERMANENT", Tokens.color.tealDeep, z + 6)
			tag.AnchorPoint = Vector2.new(0.5, 0)
			tag.Position = UDim2.new(0.5, 0, 0, -Tokens.spacing.md)
		end
		table.insert(
			cards,
			{ key = key, pass = options.pass, tile = tile, scale = scale, buy = buy, owned = owned, rainbow = rainbow, sheen = sheen }
		)
	end
	for index, bundle in ipairs(bundles) do
		local popular = bundle.popular == true
		card(
			index,
			"gemBundle" .. tostring(bundle.gems),
			formatGems(bundle.gems) .. " Gems",
			if popular then "Best value" else "Added at once",
			bundle.robux,
			{
				popular = popular,
				chest = popular or bundle.gems >= 1000,
			}
		)
	end
	if passes.doubleGems then
		card(#bundles + 1, "doubleGems", "2x Gems", "Every gem counts twice", passes.doubleGems.robux, { pass = "doubleGems" })
	end

	-- Sparkles drifting up the popular card while the screen is open (kept light).
	local popularCard: Card? = nil
	for _, entry in ipairs(cards) do
		if entry.rainbow then
			popularCard = entry
		end
	end
	local closed = false
	if popularCard and not motion.reducedMotion then
		task.spawn(function()
			while not closed do
				Confetti.burst((popularCard :: Card).tile, {
					origin = UDim2.fromScale(0.2 + math.random() * 0.6, 0.55),
					count = 3,
					spread = 40,
					motion = motion,
					tier = tier,
					zIndex = z + 9,
				})
				task.wait(0.9)
			end
		end)
	end
	-- Border and sheen animation.
	local sheenT = 0
	table.insert(
		cleanups,
		RunService.RenderStepped:Connect(function(dt)
			for _, entry in ipairs(animated) do
				entry.gradient.Rotation = (entry.gradient.Rotation + dt * entry.speed) % 360
			end
			sheenT = (sheenT + dt * 0.45) % 1.6
			for _, entry in ipairs(cards) do
				if entry.sheen then
					entry.sheen.Offset = Vector2.new(-0.8 + sheenT, 0)
				end
			end
		end)
	)

	local terms = FrameKit.text(
		container,
		"Terms",
		"Gems arrive the moment Roblox confirms the purchase. Prices are shown in Robux before you confirm.",
		"caption",
		{ zIndex = z, color = Tokens.color.inkMuted }
	)
	terms.LayoutOrder = 3
	terms.Size = UDim2.new(1, 0, 0, Tokens.typography.caption.size * 2 + 6)

	local function render()
		local projection = deps.profile.projection
		balanceLabel.Text = if projection then formatGems(projection.currencies.gems or 0) else "0"
		local ent = entitlements()
		for _, entry in ipairs(cards) do
			local ownedPass = entry.pass ~= nil and ent[entry.pass :: string] == true
			entry.owned.Visible = ownedPass
			entry.buy.button.Visible = not ownedPass
		end
	end
	render()
	table.insert(cleanups, deps.profile.changed:Connect(render))
	if cards[1] then
		api.setInitialFocus((popularCard or cards[1]).buy.button)
	end
	deps.audio:play(Tokens.sound.uiOpen)

	return function()
		closed = true
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

return GemShopModal
