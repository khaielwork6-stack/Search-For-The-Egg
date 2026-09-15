--!strict
-- Perk Shop (the Perk Seller's stall): permanent account perks as big illustrated tiles in a 2 x 2
-- grid - tinted face, art, level pips and a gem price button - beside a column of gem bundles and
-- permanent passes bought with Robux. Perk purchases are atomic server requests; Robux items open
-- the native prompt through the server. Tiles pop and shower confetti when a purchase lands.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local Depth = require(script.Parent.Parent.Components.Depth)
local Perks = require(Shared.Domain.Perks)
local Tween = require(script.Parent.Parent.Components.Tween)
local FrameKit = require(script.Parent.Parent.Components.Frame)
local Button = require(script.Parent.Parent.Components.Button)
local Icons = require(script.Parent.Parent.Components.Icons)
local Skin = require(script.Parent.Parent.Components.Skin)
local Confetti = require(script.Parent.Parent.Components.Confetti)
local UpgradeActions = require(script.Parent.Parent.UpgradeActions)

local ShopModal = {}

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

local COPY: { [string]: { title: string, what: string, icon: string, art: string, fill: Color3, deep: Color3 } } = {
	bagSize = {
		title = "Bag Size",
		what = "bag capacity",
		icon = "feather",
		art = "icon.feather",
		fill = Tokens.color.leaf,
		deep = Tokens.color.leafDeep,
	},
	handGrab = {
		title = "Hand Grab",
		what = "Hand grasp",
		icon = "star",
		art = "tool.hand.normal",
		fill = Tokens.color.gold,
		deep = Tokens.color.goldDeep,
	},
	gemValue = {
		title = "Gem Value",
		what = "Gem rewards",
		icon = "gem",
		art = "hud.gem",
		fill = Tokens.color.tealAccent,
		deep = Tokens.color.tealDeep,
	},
	featherValue = {
		title = "Feather Value",
		what = "sale value",
		icon = "coin",
		art = "hud.token",
		fill = Tokens.color.sky,
		deep = Tokens.color.skyDeep,
	},
}

-- Robux column: gem bundles first, then the two permanent passes sold here.
type Offer = { key: string, name: string, caption: string, art: string, icon: string, robux: number?, pass: string?, popular: boolean? }

local function offers(cfg: { [string]: any }): { Offer }
	local list: { Offer } = {}
	local bundles = cfg.monetization and cfg.monetization.gemBundles or {}
	for index, bundle in ipairs(bundles) do
		table.insert(list, {
			key = "gemBundle" .. tostring(bundle.gems),
			name = string.format("%s Gems", (tostring(bundle.gems):reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", ""))),
			caption = "Added at once",
			art = "hud.gem",
			icon = "gem",
			robux = bundle.robux,
			popular = bundle.popular == true or (index == #bundles and not bundle.popular),
		})
	end
	local passes = cfg.monetization and cfg.monetization.passes or {}
	if passes.doubleGems then
		table.insert(list, {
			key = "doubleGems",
			name = "2x Gems",
			caption = "Permanent",
			art = "hud.gem",
			icon = "gem",
			robux = passes.doubleGems.robux,
			pass = "doubleGems",
		})
	end
	if passes.infiniteBag then
		table.insert(list, {
			key = "infiniteBag",
			name = "Infinite Bag",
			caption = "Permanent",
			art = "icon.feather",
			icon = "feather",
			robux = passes.infiniteBag.robux,
			pass = "infiniteBag",
		})
	end
	return list
end

local function centredArt(parent: GuiObject, art: string, icon: string, px: number, z: number): GuiObject
	local glyph = Skin.icon(parent, art, px, z) or Icons.build(icon, parent, px, { zIndex = z })
	glyph.AnchorPoint = Vector2.new(0.5, 0.5)
	glyph.Position = UDim2.fromScale(0.5, 0.5)
	return glyph
end

function ShopModal.build(container: ScrollingFrame, api: any, deps: Deps): () -> ()
	local cleanups: { any } = {}
	local cfg = deps.config
	local motion = deps.accessibility:motionSettings()
	local tap = deps.minimumTapTarget
	local z = container.ZIndex + 1
	local tier = deps.quality and deps.quality:tier() or nil
	local function entitlements(): { [string]: boolean }
		return deps.entitlements and deps.entitlements() or {}
	end

	-- Top row: subtitle on the left, gem balance chip with a "+" on the right.
	local top = Instance.new("Frame")
	top.Name = "Top"
	top.BackgroundTransparency = 1
	top.Size = UDim2.new(1, 0, 0, tap)
	top.LayoutOrder = 1
	top.ZIndex = z
	top.Parent = container
	local subtitle = FrameKit.text(top, "Subtitle", "PERMANENT PERKS", "title", { zIndex = z, color = Tokens.color.goldDeep })
	subtitle.Size = UDim2.new(1, -(tap * 4), 1, 0)
	subtitle.TextYAlignment = Enum.TextYAlignment.Center
	FrameKit.outline(subtitle, 2, Tokens.color.featherWhite)
	local balanceChip, balanceLabel, balanceIcon = FrameKit.chip(top, "Balance", { zIndex = z + 1, height = tap - Tokens.spacing.xs })
	balanceIcon.Visible = true
	if not Skin.icon(balanceIcon, "hud.gem", Tokens.icon.md, balanceIcon.ZIndex + 1) then
		Icons.gem(balanceIcon, Tokens.icon.md, { zIndex = balanceIcon.ZIndex + 1 })
	end
	balanceLabel.Text = "0"
	balanceChip.AnchorPoint = Vector2.new(1, 0.5)
	balanceChip.Position = UDim2.new(1, -(tap - Tokens.spacing.xs + Tokens.spacing.xs), 0.5, 0)
	local plus = Button.build(top, {
		text = "+",
		variant = "success",
		round = true,
		minimumTapTarget = tap,
		motion = motion,
		size = UDim2.fromOffset(tap - Tokens.spacing.xs, tap - Tokens.spacing.xs),
		zIndex = z + 1,
		textSize = Tokens.typography.title.size,
		sound = function()
			deps.audio:play(Tokens.sound.uiTap)
		end,
		hoverSound = function()
			deps.audio:play(Tokens.sound.uiHover)
		end,
	})
	plus.button.AnchorPoint = Vector2.new(1, 0.5)
	plus.button.Position = UDim2.fromScale(1, 0.5)
	table.insert(cleanups, plus.destroy)
	-- The opener itself is connected once, further down, together with the rail acknowledgement.

	-- Body: perk grid (left) and the Robux column (right), sized by scale so phones fit.
	local body = Instance.new("Frame")
	body.Name = "Body"
	body.BackgroundTransparency = 1
	body.Size = UDim2.fromScale(1, 0)
	body.AutomaticSize = Enum.AutomaticSize.Y
	body.LayoutOrder = 2
	body.ZIndex = z
	body.Parent = container

	local tileHeight = tap * 4 + Tokens.spacing.xxl + Tokens.spacing.lg
	local grid = Instance.new("Frame")
	grid.Name = "Perks"
	grid.BackgroundColor3 = Tokens.color.creamDeep
	grid.Size = UDim2.new(0.66, -Tokens.spacing.sm, 0, tileHeight * 2 + Tokens.spacing.sm * 3)
	grid.ZIndex = z
	local gridCorner = Instance.new("UICorner")
	gridCorner.CornerRadius = UDim.new(0, Tokens.radius.xl)
	gridCorner.Parent = grid
	local gridStroke = Instance.new("UIStroke")
	gridStroke.Thickness = Tokens.stroke.standard
	gridStroke.Color = Tokens.color.strawDeep
	gridStroke.Transparency = 0.4
	gridStroke.Parent = grid
	local gridPadding = Instance.new("UIPadding")
	gridPadding.PaddingLeft = UDim.new(0, Tokens.spacing.sm)
	gridPadding.PaddingRight = UDim.new(0, Tokens.spacing.sm)
	gridPadding.PaddingTop = UDim.new(0, Tokens.spacing.sm)
	gridPadding.PaddingBottom = UDim.new(0, Tokens.spacing.sm)
	gridPadding.Parent = grid
	local gridLayout = Instance.new("UIGridLayout")
	gridLayout.CellSize = UDim2.new(0.5, -Tokens.spacing.xs, 0, tileHeight)
	gridLayout.CellPadding = UDim2.fromOffset(Tokens.spacing.sm, Tokens.spacing.sm)
	gridLayout.SortOrder = Enum.SortOrder.LayoutOrder
	gridLayout.Parent = grid
	grid.Parent = body

	local column = Instance.new("Frame")
	column.Name = "Offers"
	column.BackgroundTransparency = 1
	column.AnchorPoint = Vector2.new(1, 0)
	column.Position = UDim2.fromScale(1, 0)
	column.Size = UDim2.new(0.34, -Tokens.spacing.sm, 0, 0)
	column.AutomaticSize = Enum.AutomaticSize.Y
	column.ZIndex = z
	local columnLayout = Instance.new("UIListLayout")
	columnLayout.SortOrder = Enum.SortOrder.LayoutOrder
	columnLayout.Padding = UDim.new(0, Tokens.spacing.sm)
	columnLayout.Parent = column
	column.Parent = body

	-- Perk tiles ----------------------------------------------------------------------------------
	type Tile = {
		perkId: string,
		tile: Frame,
		scale: UIScale,
		pips: { Frame },
		buy: any,
		levelLabel: TextLabel,
		maxBadge: TextLabel,
		displayedLevel: number?,
	}
	local tiles: { Tile } = {}
	for index, perkId in ipairs(Perks.IDS) do
		local copy = COPY[perkId]
		local tile, face =
			FrameKit.tile(grid, "Perk_" .. perkId, { fill = copy.fill, deep = copy.deep, zIndex = z + 1, radius = Tokens.radius.lg })
		tile.LayoutOrder = index
		local scale = Instance.new("UIScale")
		scale.Parent = tile
		-- Title strip along the top of the face.
		local title = FrameKit.text(face, "Title", string.upper(copy.title), "label", {
			zIndex = z + 3,
			color = Tokens.color.featherWhite,
			align = Enum.TextXAlignment.Center,
		})
		title.Position = UDim2.fromOffset(0, Tokens.spacing.sm)
		title.Size = UDim2.new(1, 0, 0, Tokens.typography.label.size + 6)
		FrameKit.outline(title, 2.2)
		-- Illustration on a soft sunburst.
		local artHolder = Instance.new("Frame")
		artHolder.Name = "Art"
		artHolder.AnchorPoint = Vector2.new(0.5, 0)
		artHolder.Position = UDim2.new(0.5, 0, 0, Tokens.typography.label.size + Tokens.spacing.md)
		artHolder.Size = UDim2.fromOffset(tap * 2 + Tokens.spacing.sm, tap * 2 + Tokens.spacing.sm)
		artHolder.BackgroundTransparency = 1
		artHolder.ZIndex = z + 2
		artHolder.Parent = face
		Skin.texture(artHolder, "texture.sunburst", { zIndex = z + 2, transparency = 0.66, color = Tokens.color.featherWhite })
		centredArt(artHolder, copy.art, copy.icon, tap * 2 - Tokens.spacing.xs, z + 4)
		-- Level pips: one per level, lit up to the current one.
		local pips = Instance.new("Frame")
		pips.Name = "Pips"
		pips.AnchorPoint = Vector2.new(0.5, 1)
		pips.Position = UDim2.new(0.5, 0, 1, -(tap + Tokens.spacing.md + 4))
		pips.Size = UDim2.new(1, -Tokens.spacing.md * 2, 0, 10)
		pips.BackgroundTransparency = 1
		pips.ZIndex = z + 3
		local pipLayout = Instance.new("UIListLayout")
		pipLayout.FillDirection = Enum.FillDirection.Horizontal
		pipLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
		pipLayout.VerticalAlignment = Enum.VerticalAlignment.Center
		pipLayout.Padding = UDim.new(0, 3)
		-- Explicit order: sorted by name "Pip10" lands between "Pip1" and "Pip2" and hides a level.
		pipLayout.SortOrder = Enum.SortOrder.LayoutOrder
		pipLayout.Parent = pips
		pips.Parent = face
		local pipDots: { Frame } = {}
		local maxLevel = cfg.permanentPerks[perkId].maxLevel
		for level = 1, maxLevel do
			local dot = Instance.new("Frame")
			dot.Name = "Pip" .. level
			dot.Size = UDim2.fromOffset(if maxLevel > 6 then 11 else 14, if maxLevel > 6 then 11 else 14)
			dot.BackgroundColor3 = Tokens.color.overlay
			dot.BackgroundTransparency = 0.55
			dot.BorderSizePixel = 0
			dot.ZIndex = z + 3
			dot.LayoutOrder = level
			local dotCorner = Instance.new("UICorner")
			dotCorner.CornerRadius = UDim.new(1, 0)
			dotCorner.Parent = dot
			dot.Parent = pips
			table.insert(pipDots, dot)
		end
		-- Level badge in the top-left corner; the bonus reads from the pips.
		local levelLabel = FrameKit.badge(face, "Level", "LV 0", Tokens.color.overlay, z + 4)
		levelLabel.AnchorPoint = Vector2.new(0.5, 1)
		levelLabel.Position = UDim2.new(0.5, 0, 1, -(tap + Tokens.spacing.md + 22))
		levelLabel.BackgroundTransparency = 0.35
		-- Price button across the bottom.
		local buy = Button.build(face, {
			text = "",
			variant = "primary",
			minimumTapTarget = tap,
			motion = motion,
			size = UDim2.new(1, -Tokens.spacing.md, 0, tap + Tokens.spacing.xs),
			zIndex = z + 3,
			textSize = Tokens.typography.title.size - 2,
			sound = function()
				deps.audio:play(Tokens.sound.uiTap)
			end,
			hoverSound = function()
				deps.audio:play(Tokens.sound.uiHover)
			end,
		})
		buy.button.AnchorPoint = Vector2.new(0.5, 1)
		buy.button.Position = UDim2.new(0.5, 0, 1, -Tokens.spacing.sm)
		table.insert(cleanups, buy.destroy)
		local maxBadge = FrameKit.badge(face, "Max", "MAXED", Tokens.color.success, z + 4)
		maxBadge.AnchorPoint = Vector2.new(0.5, 1)
		maxBadge.Position = UDim2.new(0.5, 0, 1, -Tokens.spacing.md)
		maxBadge.Visible = false
		local record: Tile = {
			perkId = perkId,
			tile = tile,
			scale = scale,
			pips = pipDots,
			buy = buy,
			levelLabel = levelLabel,
			maxBadge = maxBadge,
			displayedLevel = nil,
		}
		table.insert(tiles, record)
		table.insert(
			cleanups,
			buy.button.Activated:Connect(function()
				local projection = deps.profile.projection
				if not projection then
					return
				end
				local level = projection.permanentPerks[perkId] or 0
				buy.setPending(true, "...")
				local result = deps.net:request("PerkPurchase", { perkId = perkId, expectedLevel = level })
				buy.setPending(false)
				if result.ok then
					deps.audio:play(Tokens.sound.purchase)
					deps.haptics:pulse(0.5, 0.1)
					scale.Scale = 1.06
					Tween.scale(scale, "release", motion, 1)
					Confetti.burst(tile, {
						origin = UDim2.fromScale(0.5, 0.45),
						count = 22,
						spread = 140,
						motion = motion,
						tier = tier,
						zIndex = z + 8,
					})
					deps.audio:play(Tokens.sound.uiConfetti)
					deps.toasts:push(string.format("%s reached level %d", copy.title, result.data.level), "success")
				else
					deps.audio:play(Tokens.sound.uiError)
					Tween.shake(tile, motion)
					local message = if result.code == "insufficient_funds"
						then "Not enough Gems"
						elseif result.code == "stale_token" then "Levels changed - try again"
						elseif result.message == "maxed" then "Already at the top"
						elseif result.message == "not_in_lobby" then "Perks change between searches"
						else "Purchase unavailable"
					deps.toasts:push(message, "warning")
				end
			end)
		)
	end
	if tiles[1] then
		api.setInitialFocus(tiles[1].buy.button)
	end

	-- Robux offers ---------------------------------------------------------------------------------
	type OfferCard = { offer: Offer, tile: Frame, buy: any, owned: TextLabel, scale: UIScale }
	local offerCards: { OfferCard } = {}
	local offerHeight = tap * 3 + Tokens.spacing.lg
	for index, offer in ipairs(offers(cfg)) do
		local fill = if offer.pass then Tokens.color.gem else Tokens.color.sky
		local deep = if offer.pass then Tokens.color.gemDeep else Tokens.color.skyDeep
		local tile, face = FrameKit.tile(column, "Offer_" .. offer.key, {
			fill = fill,
			deep = deep,
			zIndex = z + 1,
			radius = Tokens.radius.lg,
			size = UDim2.new(1, 0, 0, offerHeight),
		})
		tile.LayoutOrder = index
		local scale = Instance.new("UIScale")
		scale.Parent = tile
		-- Name on top, art in the middle, price across the bottom (the column is narrow).
		local name = FrameKit.text(face, "Name", offer.name, "label", {
			zIndex = z + 3,
			color = Tokens.color.featherWhite,
			align = Enum.TextXAlignment.Center,
		})
		name.Position = UDim2.fromOffset(0, Tokens.spacing.xs)
		name.Size = UDim2.new(1, 0, 0, Tokens.typography.label.size + 4)
		FrameKit.outline(name, 2)
		local artHolder = Instance.new("Frame")
		artHolder.Name = "Art"
		artHolder.AnchorPoint = Vector2.new(0.5, 0)
		artHolder.Position = UDim2.new(0.5, 0, 0, Tokens.typography.label.size + Tokens.spacing.sm)
		artHolder.Size = UDim2.fromOffset(tap + Tokens.spacing.lg, tap + Tokens.spacing.lg)
		artHolder.BackgroundTransparency = 1
		artHolder.ZIndex = z + 2
		artHolder.Parent = face
		Skin.texture(artHolder, "texture.sunburst", { zIndex = z + 2, transparency = 0.62, color = Tokens.color.featherWhite })
		centredArt(artHolder, offer.art, offer.icon, tap + Tokens.spacing.sm, z + 4)
		if offer.pass then
			local tag = FrameKit.badge(tile, "Tag", "PERMANENT", Tokens.color.gemDeep, z + 5)
			tag.AnchorPoint = Vector2.new(1, 0)
			tag.Position = UDim2.new(1, Tokens.spacing.xs, 0, -Tokens.spacing.sm)
			tag.Rotation = 8
			tag.TextSize = Tokens.typography.caption.size - 2
		end
		local buy = Button.build(face, {
			text = if offer.robux then string.format("R$ %d", offer.robux) else "R$",
			variant = "primary",
			minimumTapTarget = tap,
			motion = motion,
			size = UDim2.new(1, -Tokens.spacing.md, 0, tap - Tokens.spacing.xs),
			zIndex = z + 3,
			textSize = Tokens.typography.label.size + 1,
			sound = function()
				deps.audio:play(Tokens.sound.uiTap)
			end,
			hoverSound = function()
				deps.audio:play(Tokens.sound.uiHover)
			end,
			onActivated = function()
				local result =
					UpgradeActions.promptPurchase({ net = deps.net, audio = deps.audio, toasts = deps.toasts }, offer.key, offer.name)
				if result.ok then
					scale.Scale = 1.05
					Tween.scale(scale, "release", motion, 1)
				end
			end,
		})
		buy.button.AnchorPoint = Vector2.new(0.5, 1)
		buy.button.Position = UDim2.new(0.5, 0, 1, -Tokens.spacing.sm)
		table.insert(cleanups, buy.destroy)
		local owned = FrameKit.badge(face, "Owned", "OWNED", Tokens.color.success, z + 4)
		owned.AnchorPoint = Vector2.new(0.5, 1)
		owned.Position = UDim2.new(0.5, 0, 1, -Tokens.spacing.md)
		owned.Visible = false
		if offer.popular then
			local ribbon = FrameKit.badge(tile, "Popular", "POPULAR", Tokens.color.ember, z + 5)
			ribbon.AnchorPoint = Vector2.new(1, 0)
			ribbon.Position = UDim2.new(1, Tokens.spacing.xs, 0, -Tokens.spacing.sm)
			ribbon.Rotation = 8
		end
		table.insert(offerCards, { offer = offer, tile = tile, buy = buy, owned = owned, scale = scale })
	end
	local firstBundle = offerCards[1]
	-- Deliberately not a second Activated connection on `plus`: it already opens the gem shop, and
	-- connecting twice made one tap do two things. The rail's attention pop is exposed as a function
	-- the opener calls instead.
	local function flashFirstBundle()
		do
			if firstBundle then
				firstBundle.scale.Scale = 1.08
				Tween.scale(firstBundle.scale, "release", motion, 1)
				local stroke = Depth.keylineOf(firstBundle.tile) :: UIStroke?
				if stroke then
					stroke.Color = Tokens.color.goldLight
					TweenService:Create(stroke, TweenInfo.new(0.8), { Color = Tokens.color.outline }):Play()
				end
			end
		end
	end

	-- One tap on "+" does one thing: it opens the gem shop, and the rail acknowledges it.
	if deps.openGemShop then
		table.insert(
			cleanups,
			plus.button.Activated:Connect(function()
				deps.openGemShop()
				flashFirstBundle()
			end)
		)
	end

	-- Close ----------------------------------------------------------------------------------------
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

	local function render()
		local projection = deps.profile.projection
		if not projection then
			return
		end
		balanceLabel.Text = tostring(projection.currencies.gems)
		for _, record in ipairs(tiles) do
			local preview = Perks.preview(cfg, record.perkId, projection.permanentPerks[record.perkId] or 0)
			local currentPct = math.floor((preview.currentMultiplier - 1) * 100 + 0.5)
			local grew = record.displayedLevel ~= nil and record.displayedLevel ~= preview.level
			record.displayedLevel = preview.level
			for level, dot in ipairs(record.pips) do
				local lit = level <= preview.level
				dot.BackgroundColor3 = if lit then Tokens.color.goldLight else Tokens.color.overlay
				dot.BackgroundTransparency = if lit then 0 else 0.55
				if lit and grew and level == preview.level then
					local dotScale = dot:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
					dotScale.Parent = dot
					dotScale.Scale = 1.8
					TweenService:Create(dotScale, TweenInfo.new(0.4, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
				end
			end
			-- What this level gives, and what the next one would: the card used to compute the next
			-- figure and throw it away, so a player could not see what they were buying.
			record.levelLabel.RichText = true
			if preview.maxed then
				record.levelLabel.Text = string.format("LV %d  ·  +%d%%  MAX", preview.level, currentPct)
				record.buy.button.Visible = false
				record.maxBadge.Visible = true
			else
				local nextPct = math.floor(((preview.nextMultiplier or 1) - 1) * 100 + 0.5)
				record.levelLabel.Text =
					string.format('LV %d  ·  +%d%% <font color="#FFE26E">→</font> +%d%%', preview.level, currentPct, nextPct)
				record.buy.button.Visible = true
				record.maxBadge.Visible = false
				local affordable = projection.currencies.gems >= (preview.costGems or 0)
				record.buy.setText(string.format("%d Gems", preview.costGems or 0))
				record.buy.setEnabled(affordable)
			end
		end
		local ent = entitlements()
		for _, card in ipairs(offerCards) do
			local ownedPass = card.offer.pass ~= nil and ent[card.offer.pass :: string] == true
			card.buy.button.Visible = not ownedPass
			card.owned.Visible = ownedPass
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

return ShopModal
