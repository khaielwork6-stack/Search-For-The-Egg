--!strict
-- Plume's Market. One wooden frame, three tabs: PERKS (the four permanent Gem perks as big cards
-- with level pips, what the next level gives, and a green Gem price), GEMS (the bundles, the popular
-- one and the best value called out) and FOREVER (the two permanent passes). The Gem balance sits on
-- the frame's top-right with a "+" that jumps to the GEMS tab. Every price is the live config price;
-- every purchase goes through the server (Gems: PerkPurchase; Robux: PurchasePromptRequest).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
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
local SafeArea = require(script.Parent.Parent.SafeArea)

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

local WOOD = Color3.fromRGB(150, 112, 66)
local WOOD_DEEP = Color3.fromRGB(104, 74, 42)
local WOOD_LIGHT = Color3.fromRGB(196, 150, 96)
local PAPER = Color3.fromRGB(248, 238, 214)
local PARCHMENT = Color3.fromRGB(238, 224, 190)
local RAINBOW = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 96, 96)),
	ColorSequenceKeypoint.new(0.2, Color3.fromRGB(255, 190, 60)),
	ColorSequenceKeypoint.new(0.4, Color3.fromRGB(120, 230, 90)),
	ColorSequenceKeypoint.new(0.6, Color3.fromRGB(80, 210, 255)),
	ColorSequenceKeypoint.new(0.8, Color3.fromRGB(180, 110, 255)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 96, 96)),
})
local NEXT_WORD = { bagSize = "CAPACITY", handGrab = "RANGE", gemValue = "VALUE", featherValue = "VALUE" }

local function withCommas(n: number): string
	local text = tostring(n)
	return (text:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", ""))
end

-- Painted art if the owner supplied it (role given), else the icon the item has always used.
local function itemArt(parent: GuiObject, painted: string, art: string, icon: string, px: number, z: number): GuiObject
	local glyph = Skin.icon(parent, painted, px, z) or Skin.icon(parent, art, px, z) or Icons.build(icon, parent, px, { zIndex = z })
	glyph.AnchorPoint = Vector2.new(0.5, 0.5)
	glyph.Position = UDim2.fromScale(0.5, 0.5)
	return glyph
end

local function paperNote(parent: GuiObject, name: string, text: string, z: number, size: UDim2): Frame
	local note = Instance.new("Frame")
	note.Name = name
	note.Size = size
	note.BackgroundColor3 = PARCHMENT
	note.ZIndex = z
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, Tokens.radius.sm)
	corner.Parent = note
	Depth.keyline(note, Tokens.stroke.standard, WOOD_DEEP)
	local label = FrameKit.text(
		note,
		"Text",
		text,
		"caption",
		{ zIndex = z + 1, color = Tokens.color.inkStrong, align = Enum.TextXAlignment.Center, wrap = true }
	)
	label.Font = Tokens.typography.label.font
	label.Size = UDim2.new(1, -Tokens.spacing.sm, 1, 0)
	label.Position = UDim2.fromOffset(Tokens.spacing.xs, 0)
	label.TextScaled = true
	local cap = Instance.new("UITextSizeConstraint")
	cap.MaxTextSize = Tokens.typography.caption.size + 2
	cap.MinTextSize = 10
	cap.Parent = label
	note.Parent = parent
	return note
end

function ShopModal.build(container: ScrollingFrame, api: any, deps: Deps, initialTab: string?): () -> ()
	local cleanups: { any } = {}
	local cfg = deps.config
	local motion = deps.accessibility:motionSettings()
	local tap = deps.minimumTapTarget
	local z = container.ZIndex + 1
	local tier = deps.quality and deps.quality:tier() or nil
	local compact = SafeArea.classOf(container) == "phone"
	local promptDeps = { net = deps.net, audio = deps.audio, toasts = deps.toasts }
	local function entitlements(): { [string]: boolean }
		return deps.entitlements and deps.entitlements() or {}
	end
	local animated: { UIGradient } = {}
	local tab = initialTab or "perks"
	local setTab -- forward

	-- Gem balance and "+" on the frame.
	do
		local shell = api.shell
		if shell and shell.headerRight then
			local chip, chipLabel, chipIcon =
				FrameKit.chip(shell.headerRight, "Gems", { zIndex = shell.headerRight.ZIndex + 1, height = tap })
			chipIcon.Visible = true
			if not Skin.icon(chipIcon, "hud.gem", Tokens.icon.md, chipIcon.ZIndex + 1) then
				Icons.gem(chipIcon, Tokens.icon.md, { zIndex = chipIcon.ZIndex + 1 })
			end
			chip.AnchorPoint = Vector2.new(1, 0.5)
			chip.Position = UDim2.new(1, -(tap + Tokens.spacing.xs), 0.5, 0)
			local plus = Button.build(shell.headerRight, {
				text = "+",
				variant = "success",
				round = true,
				minimumTapTarget = tap,
				motion = motion,
				size = UDim2.fromOffset(tap, tap),
				zIndex = shell.headerRight.ZIndex + 1,
				textSize = Tokens.typography.title.size,
				sound = function()
					deps.audio:play(Tokens.sound.uiTap)
				end,
				onActivated = function()
					setTab("gems")
				end,
			})
			plus.button.AnchorPoint = Vector2.new(1, 0.5)
			plus.button.Position = UDim2.fromScale(1, 0.5)
			table.insert(cleanups, plus.destroy)
			local function refreshChip()
				local projection = deps.profile.projection
				chipLabel.Text = tostring(projection and projection.currencies.gems or 0)
			end
			refreshChip()
			table.insert(cleanups, deps.profile.changed:Connect(refreshChip))
		end
	end

	-- Tabs -----------------------------------------------------------------------------------------
	local tabsRow = Instance.new("Frame")
	tabsRow.Name = "Tabs"
	tabsRow.BackgroundTransparency = 1
	tabsRow.Size = UDim2.new(1, 0, 0, tap + 8)
	tabsRow.LayoutOrder = 1
	tabsRow.ZIndex = z
	tabsRow.Parent = container
	local tabsLayout = Instance.new("UIListLayout")
	tabsLayout.FillDirection = Enum.FillDirection.Horizontal
	tabsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
	tabsLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	tabsLayout.Padding = UDim.new(0, Tokens.spacing.sm)
	tabsLayout.SortOrder = Enum.SortOrder.LayoutOrder
	tabsLayout.Parent = tabsRow
	local tabHandles: { [string]: any } = {}
	for index, spec in ipairs({
		{ "perks", "PERKS", "icon.feather", "feather" },
		{ "gems", "GEMS", "hud.gem", "gem" },
		{ "forever", "FOREVER", "", "star" },
	}) do
		local handle = Button.build(tabsRow, {
			text = "      " .. spec[2],
			variant = "secondary",
			minimumTapTarget = tap,
			motion = motion,
			size = UDim2.new(if compact then 0.32 else 0.24, -Tokens.spacing.xs, 0, tap + 4),
			zIndex = z + 1,
			textSize = Tokens.typography.label.size,
			sound = function()
				deps.audio:play(Tokens.sound.uiTab)
			end,
			hoverSound = function()
				deps.audio:play(Tokens.sound.uiHover)
			end,
			onActivated = function()
				setTab(spec[1])
			end,
		})
		handle.button.LayoutOrder = index
		local face = handle.button:FindFirstChild("Face")
		if face then
			local glyph = if spec[3] ~= "" then Skin.icon(face, spec[3], Tokens.icon.md, z + 4) else nil
			glyph = glyph or Icons.build(spec[4], face, Tokens.icon.md, { zIndex = z + 4, color = Tokens.color.goldDeep })
			glyph.AnchorPoint = Vector2.new(0, 0.5)
			glyph.Position = UDim2.new(0, Tokens.spacing.md, 0.5, 0)
		end
		tabHandles[spec[1]] = handle
		table.insert(cleanups, handle.destroy)
	end

	-- Pages ----------------------------------------------------------------------------------------
	local pages: { [string]: Frame } = {}
	local function page(name: string, height: number): Frame
		local frame = Instance.new("Frame")
		frame.Name = "Page_" .. name
		frame.BackgroundTransparency = 1
		frame.Size = UDim2.new(1, 0, 0, height)
		frame.LayoutOrder = 2
		frame.ZIndex = z
		frame.Visible = false
		frame.Parent = container
		pages[name] = frame
		return frame
	end

	-- PERKS: four cards, two by two, with the passes strip under them.
	local perkCardH = if compact then tap * 4.6 else tap * 4.2
	local stripH = tap + Tokens.spacing.lg
	local perksPage = page("perks", perkCardH * 2 + Tokens.spacing.sm + Tokens.spacing.md + stripH)
	local grid = Instance.new("Frame")
	grid.Name = "Grid"
	grid.BackgroundTransparency = 1
	grid.Size = UDim2.new(1, 0, 0, perkCardH * 2 + Tokens.spacing.sm)
	grid.ZIndex = z
	grid.Parent = perksPage
	local gridLayout = Instance.new("UIGridLayout")
	gridLayout.CellSize = UDim2.new(0.5, -Tokens.spacing.xs, 0, perkCardH)
	gridLayout.CellPadding = UDim2.fromOffset(Tokens.spacing.sm, Tokens.spacing.sm)
	gridLayout.SortOrder = Enum.SortOrder.LayoutOrder
	gridLayout.Parent = grid
	type PerkCard = {
		perkId: string,
		root: Frame,
		scale: UIScale,
		pips: { Frame },
		buy: any,
		level: TextLabel,
		nextLine: TextLabel,
		maxBadge: TextLabel,
		displayedLevel: number?,
		afterArt: GuiObject,
	}
	local perkCards: { PerkCard } = {}
	for index, perkId in ipairs(Perks.IDS) do
		local copy = COPY[perkId]
		local root = Instance.new("Frame")
		root.Name = "Perk_" .. perkId
		root.BackgroundColor3 = PAPER
		root.LayoutOrder = index
		root.ZIndex = z + 1
		local rootCorner = Instance.new("UICorner")
		rootCorner.CornerRadius = UDim.new(0, Tokens.radius.lg)
		rootCorner.Parent = root
		Depth.keyline(root, Tokens.stroke.bold, WOOD_DEEP)
		Depth.rim(root, PAPER)
		local scale = Instance.new("UIScale")
		scale.Parent = root
		root.Parent = grid
		-- Art panel: the perk's colour, a sunburst, the item.
		local artPanel = Instance.new("Frame")
		artPanel.Name = "ArtPanel"
		artPanel.Position = UDim2.fromOffset(4, 4)
		artPanel.Size = UDim2.new(0.42, -4, 1, -8)
		artPanel.BackgroundColor3 = copy.fill
		artPanel.ZIndex = z + 2
		artPanel.ClipsDescendants = true
		local artCorner = Instance.new("UICorner")
		artCorner.CornerRadius = UDim.new(0, Tokens.radius.md)
		artCorner.Parent = artPanel
		Depth.applySheen(artPanel, copy.fill)
		artPanel.Parent = root
		local burst = Skin.texture(artPanel, "texture.sunburst", { zIndex = z + 2, transparency = 0.6, color = Tokens.color.featherWhite })
		local artHolder = Instance.new("Frame")
		artHolder.Name = "Art"
		artHolder.AnchorPoint = Vector2.new(0.5, 0.5)
		artHolder.Position = UDim2.fromScale(0.5, 0.42)
		artHolder.Size = UDim2.fromScale(0.78, 0.6)
		artHolder.BackgroundTransparency = 1
		artHolder.ZIndex = z + 3
		local artRatio = Instance.new("UIAspectRatioConstraint")
		artRatio.Parent = artHolder
		artHolder.Parent = artPanel
		local art = itemArt(artHolder, "perk." .. perkId, copy.art, copy.icon, 160, z + 4)
		art.Size = UDim2.fromScale(1, 1)
		local nextLine = FrameKit.text(
			artPanel,
			"Next",
			"",
			"caption",
			{ zIndex = z + 4, color = Tokens.color.featherWhite, align = Enum.TextXAlignment.Center }
		)
		nextLine.Font = Tokens.typography.label.font
		nextLine.AnchorPoint = Vector2.new(0.5, 1)
		nextLine.Position = UDim2.new(0.5, 0, 1, -Tokens.spacing.sm)
		nextLine.Size = UDim2.new(1, -Tokens.spacing.sm, 0, Tokens.typography.caption.size + 6)
		nextLine.TextScaled = true
		FrameKit.outline(nextLine, 2, WOOD_DEEP)
		-- Right side: title, level pill, pips, before -> after, price.
		local body = Instance.new("Frame")
		body.Name = "Body"
		body.Position = UDim2.new(0.42, Tokens.spacing.sm, 0, Tokens.spacing.sm)
		body.Size = UDim2.new(0.58, -Tokens.spacing.sm * 2, 1, -Tokens.spacing.sm * 2)
		body.BackgroundTransparency = 1
		body.ZIndex = z + 2
		body.Parent = root
		local title = FrameKit.text(body, "Title", string.upper(copy.title), "title", { zIndex = z + 3, color = Tokens.color.inkStrong })
		title.Size = UDim2.new(1, 0, 0, Tokens.typography.title.size + 2)
		title.TextScaled = true
		local titleCap = Instance.new("UITextSizeConstraint")
		titleCap.MaxTextSize = Tokens.typography.title.size
		titleCap.MinTextSize = 14
		titleCap.Parent = title
		local level = FrameKit.badge(body, "Level", "LV 0", WOOD_DEEP, z + 4)
		level.Position = UDim2.fromOffset(0, Tokens.typography.title.size + 6)
		local pipsRow = Instance.new("Frame")
		pipsRow.Name = "Pips"
		pipsRow.Position = UDim2.fromOffset(0, Tokens.typography.title.size + 6 + Tokens.typography.caption.size + 16)
		pipsRow.Size = UDim2.new(1, 0, 0, 12)
		pipsRow.BackgroundTransparency = 1
		pipsRow.ZIndex = z + 3
		local pipLayout = Instance.new("UIListLayout")
		pipLayout.FillDirection = Enum.FillDirection.Horizontal
		pipLayout.VerticalAlignment = Enum.VerticalAlignment.Center
		pipLayout.Padding = UDim.new(0, 4)
		pipLayout.SortOrder = Enum.SortOrder.LayoutOrder
		pipLayout.Parent = pipsRow
		pipsRow.Parent = body
		local pips: { Frame } = {}
		for lv = 1, cfg.permanentPerks[perkId].maxLevel do
			local dot = Instance.new("Frame")
			dot.Name = "Pip" .. lv
			dot.Size = UDim2.fromOffset(12, 12)
			dot.BackgroundColor3 = WOOD_DEEP
			dot.BackgroundTransparency = 0.25
			dot.BorderSizePixel = 0
			dot.LayoutOrder = lv
			dot.ZIndex = z + 3
			local dotCorner = Instance.new("UICorner")
			dotCorner.CornerRadius = UDim.new(1, 0)
			dotCorner.Parent = dot
			dot.Parent = pipsRow
			table.insert(pips, dot)
		end
		-- Before -> after: two small arts and an arrow on a paper strip.
		local strip = Instance.new("Frame")
		strip.Name = "Preview"
		strip.Position = UDim2.fromOffset(0, Tokens.typography.title.size + Tokens.typography.caption.size + 40)
		strip.Size = UDim2.new(1, 0, 0, tap + 4)
		strip.BackgroundColor3 = PARCHMENT
		strip.ZIndex = z + 3
		local stripCorner = Instance.new("UICorner")
		stripCorner.CornerRadius = UDim.new(0, Tokens.radius.sm)
		stripCorner.Parent = strip
		Depth.keyline(strip, Tokens.stroke.hairline + 0.5, WOOD_DEEP)
		strip.Parent = body
		local before = Instance.new("Frame")
		before.Name = "Before"
		before.AnchorPoint = Vector2.new(0.5, 0.5)
		before.Position = UDim2.fromScale(0.28, 0.5)
		before.Size = UDim2.fromOffset(tap - 14, tap - 14)
		before.BackgroundTransparency = 1
		before.ZIndex = z + 4
		before.Parent = strip
		itemArt(before, "perk." .. perkId, copy.art, copy.icon, tap - 14, z + 5).Size = UDim2.fromScale(1, 1)
		local arrowGlyph = Icons.chevron(strip, Tokens.icon.md, { zIndex = z + 5, color = Tokens.color.success })
		arrowGlyph.AnchorPoint = Vector2.new(0.5, 0.5)
		arrowGlyph.Position = UDim2.fromScale(0.5, 0.5)
		local after = Instance.new("Frame")
		after.Name = "After"
		after.AnchorPoint = Vector2.new(0.5, 0.5)
		after.Position = UDim2.fromScale(0.72, 0.5)
		after.Size = UDim2.fromOffset(tap - 6, tap - 6)
		after.BackgroundTransparency = 1
		after.ZIndex = z + 4
		after.Parent = strip
		local afterArt = itemArt(after, "perk." .. perkId, copy.art, copy.icon, tap - 6, z + 5)
		afterArt.Size = UDim2.fromScale(1, 1)
		local buy = Button.build(body, {
			text = "",
			variant = "success",
			minimumTapTarget = tap,
			motion = motion,
			size = UDim2.new(1, 0, 0, tap + 4),
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
		buy.button.Position = UDim2.fromScale(0.5, 1)
		do
			local face = buy.button:FindFirstChild("Face")
			local gem = if face then (Skin.icon(face, "hud.gem", tap - 18, z + 6) or Icons.gem(face, tap - 20, { zIndex = z + 6 })) else nil
			if gem then
				gem.AnchorPoint = Vector2.new(0, 0.5)
				gem.Position = UDim2.new(0, Tokens.spacing.md, 0.5, 0)
			end
		end
		table.insert(cleanups, buy.destroy)
		local maxBadge = FrameKit.badge(body, "Max", "MAXED", Tokens.color.success, z + 4)
		maxBadge.AnchorPoint = Vector2.new(0.5, 1)
		maxBadge.Position = UDim2.new(0.5, 0, 1, -Tokens.spacing.sm)
		maxBadge.Visible = false
		local record: PerkCard = {
			perkId = perkId,
			root = root,
			scale = scale,
			pips = pips,
			buy = buy,
			level = level,
			nextLine = nextLine,
			maxBadge = maxBadge,
			displayedLevel = nil,
			afterArt = afterArt,
		}
		table.insert(perkCards, record)
		table.insert(
			cleanups,
			buy.button.Activated:Connect(function()
				local projection = deps.profile.projection
				if not projection then
					return
				end
				local lv = projection.permanentPerks[perkId] or 0
				buy.setPending(true, "...")
				local result = deps.net:request("PerkPurchase", { perkId = perkId, expectedLevel = lv })
				buy.setPending(false)
				if result.ok then
					deps.audio:play(Tokens.sound.purchase)
					deps.haptics:pulse(0.5, 0.1)
					scale.Scale = 1.05
					Tween.scale(scale, "release", motion, 1)
					Confetti.burst(
						root,
						{ origin = UDim2.fromScale(0.5, 0.45), count = 22, spread = 140, motion = motion, tier = tier, zIndex = z + 8 }
					)
					deps.audio:play(Tokens.sound.uiConfetti)
					deps.toasts:push(string.format("%s reached level %d", copy.title, result.data.level), "success")
				else
					deps.audio:play(Tokens.sound.uiError)
					Tween.shake(root, motion)
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
		if burst and not motion.reducedMotion then
			table.insert(
				cleanups,
				RunService.RenderStepped:Connect(function(dt)
					if burst.Parent then
						burst.Rotation = (burst.Rotation + dt * 6 * (if index % 2 == 0 then -1 else 1)) % 360
					end
				end)
			)
		end
	end
	-- The passes strip under the perks: a note, the two passes, a link to FOREVER.
	local strip = Instance.new("Frame")
	strip.Name = "Strip"
	strip.AnchorPoint = Vector2.new(0, 1)
	strip.Position = UDim2.fromScale(0, 1)
	strip.Size = UDim2.new(1, 0, 0, stripH)
	strip.ZIndex = z
	Depth.panel(strip, WOOD, { radius = Tokens.radius.md, rim = WOOD_LIGHT })
	strip.Parent = perksPage
	local stripLayout = Instance.new("UIListLayout")
	stripLayout.FillDirection = Enum.FillDirection.Horizontal
	stripLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	stripLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	stripLayout.Padding = UDim.new(0, Tokens.spacing.md)
	stripLayout.SortOrder = Enum.SortOrder.LayoutOrder
	stripLayout.Parent = strip
	local note = paperNote(strip, "Note", "Premium Upgrades\nLast Forever!", z + 1, UDim2.fromOffset(170, tap))
	note.LayoutOrder = 1
	note.Rotation = -2
	note.Visible = not compact
	type PassMini = { key: string, buy: any, owned: TextLabel }
	local passMinis: { PassMini } = {}
	local allOffers = offers(cfg)
	local order = 2
	for _, offer in ipairs(allOffers) do
		if offer.pass then
			local mini = Instance.new("Frame")
			mini.Name = "Mini_" .. offer.key
			mini.Size = UDim2.fromOffset(if compact then 150 else 210, tap + 2)
			mini.BackgroundColor3 = PARCHMENT
			mini.LayoutOrder = order
			mini.ZIndex = z + 1
			local miniCorner = Instance.new("UICorner")
			miniCorner.CornerRadius = UDim.new(0, Tokens.radius.sm)
			miniCorner.Parent = mini
			Depth.keyline(mini, Tokens.stroke.standard, WOOD_DEEP)
			mini.Parent = strip
			local artHolder = Instance.new("Frame")
			artHolder.AnchorPoint = Vector2.new(0, 0.5)
			artHolder.Position = UDim2.new(0, 4, 0.5, 0)
			artHolder.Size = UDim2.fromOffset(tap - 12, tap - 12)
			artHolder.BackgroundTransparency = 1
			artHolder.ZIndex = z + 2
			artHolder.Parent = mini
			itemArt(artHolder, "pass." .. offer.key, offer.art, offer.icon, tap - 12, z + 3).Size = UDim2.fromScale(1, 1)
			local name =
				FrameKit.text(mini, "Name", string.upper(offer.name), "caption", { zIndex = z + 2, color = Tokens.color.inkStrong })
			name.Font = Tokens.typography.label.font
			name.Position = UDim2.fromOffset(tap - 4, 2)
			name.Size = UDim2.new(1, -(tap + 4), 0, Tokens.typography.caption.size + 2)
			local forever = FrameKit.text(mini, "Forever", "FOREVER", "caption", { zIndex = z + 2, color = Tokens.color.inkMuted })
			forever.Position = UDim2.fromOffset(tap - 4, Tokens.typography.caption.size + 2)
			forever.Size = UDim2.new(0.4, 0, 0, Tokens.typography.caption.size)
			forever.TextSize = 10
			local buy = Button.build(mini, {
				text = string.format("R$ %d", offer.robux or 0),
				variant = "success",
				minimumTapTarget = tap,
				motion = motion,
				size = UDim2.fromOffset(74, tap - 16),
				zIndex = z + 3,
				textSize = Tokens.typography.caption.size + 1,
				sound = function()
					deps.audio:play(Tokens.sound.uiTap)
				end,
				onActivated = function()
					UpgradeActions.promptPurchase(promptDeps, offer.key, offer.name)
				end,
			})
			buy.button.AnchorPoint = Vector2.new(1, 1)
			buy.button.Position = UDim2.new(1, -4, 1, -3)
			table.insert(cleanups, buy.destroy)
			local owned = FrameKit.badge(mini, "Owned", "OWNED", Tokens.color.success, z + 4)
			owned.AnchorPoint = Vector2.new(1, 0.5)
			owned.Position = UDim2.new(1, -6, 0.5, 0)
			owned.Visible = false
			table.insert(passMinis, { key = offer.pass, buy = buy, owned = owned })
			order += 1
		end
	end
	local viewForever = Button.build(strip, {
		text = "VIEW FOREVER PERKS  >",
		variant = "pill",
		minimumTapTarget = tap,
		motion = motion,
		size = UDim2.fromOffset(if compact then 150 else 220, tap - 6),
		zIndex = z + 1,
		textSize = Tokens.typography.caption.size + 1,
		sound = function()
			deps.audio:play(Tokens.sound.uiTab)
		end,
		onActivated = function()
			setTab("forever")
		end,
	})
	viewForever.button.LayoutOrder = order
	table.insert(cleanups, viewForever.destroy)

	-- GEMS: the bundles, side by side.
	local bundleH = if compact then tap * 5.2 else tap * 6
	local gemsPage = page("gems", bundleH + Tokens.spacing.md + Tokens.typography.caption.size + 8 + Tokens.spacing.md + tap)
	local bundlesRow = Instance.new("Frame")
	bundlesRow.Name = "Bundles"
	bundlesRow.BackgroundTransparency = 1
	bundlesRow.Size = UDim2.new(1, 0, 0, bundleH)
	bundlesRow.ZIndex = z
	bundlesRow.Parent = gemsPage
	local bundlesLayout = Instance.new("UIListLayout")
	bundlesLayout.FillDirection = Enum.FillDirection.Horizontal
	bundlesLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	bundlesLayout.VerticalAlignment = Enum.VerticalAlignment.Bottom
	bundlesLayout.Padding = UDim.new(0, Tokens.spacing.md)
	bundlesLayout.SortOrder = Enum.SortOrder.LayoutOrder
	bundlesLayout.Parent = bundlesRow
	local bundles = cfg.monetization and cfg.monetization.gemBundles or {}
	local bestIndex, bestRatio = 0, 0
	for index, bundle in ipairs(bundles) do
		local ratio = bundle.gems / math.max(1, bundle.robux)
		if ratio > bestRatio then
			bestIndex, bestRatio = index, ratio
		end
	end
	local bundleFills = { Tokens.color.sky, Tokens.color.gem, Color3.fromRGB(70, 44, 110) }
	local bundleDeeps = { Tokens.color.skyDeep, Tokens.color.gemDeep, Color3.fromRGB(40, 24, 70) }
	for index, bundle in ipairs(bundles) do
		local isBest = index == bestIndex
		local isPopular = bundle.popular == true
		local fill = bundleFills[math.min(index, #bundleFills)]
		local deep = bundleDeeps[math.min(index, #bundleDeeps)]
		local card = Instance.new("Frame")
		card.Name = "Bundle_" .. tostring(bundle.gems)
		card.Size = UDim2.fromScale(if compact then 0.31 else 0.27, if isBest then 1 else 0.92)
		card.BackgroundColor3 = deep
		card.LayoutOrder = index
		card.ZIndex = z + 1
		local cardCorner = Instance.new("UICorner")
		cardCorner.CornerRadius = UDim.new(0, Tokens.radius.lg)
		cardCorner.Parent = card
		local outline = Depth.keyline(card, Tokens.stroke.bold, WOOD_DEEP)
		if isBest then
			outline.Thickness = Tokens.stroke.frame + 1
			outline.Color = Color3.new(1, 1, 1)
			local gradient = Instance.new("UIGradient")
			gradient.Color = RAINBOW
			gradient.Parent = outline
			table.insert(animated, gradient)
		end
		local scale = Instance.new("UIScale")
		scale.Parent = card
		card.Parent = bundlesRow
		local face = Instance.new("Frame")
		face.Name = "Face"
		face.AnchorPoint = Vector2.new(0.5, 0)
		face.Position = UDim2.new(0.5, 0, 0, 5)
		face.Size = UDim2.new(1, -10, 1, -12)
		face.BackgroundColor3 = fill
		face.BorderSizePixel = 0
		face.ZIndex = z + 2
		local faceCorner = Instance.new("UICorner")
		faceCorner.CornerRadius = UDim.new(0, Tokens.radius.md)
		faceCorner.Parent = face
		Depth.applySheen(face, fill)
		face.Parent = card
		local amount = FrameKit.text(
			face,
			"Amount",
			withCommas(bundle.gems) .. " GEMS",
			"display",
			{ zIndex = z + 4, color = Tokens.color.featherWhite, align = Enum.TextXAlignment.Center }
		)
		amount.Position = UDim2.fromScale(0, 0.04)
		amount.Size = UDim2.fromScale(1, 0.14)
		amount.TextScaled = true
		FrameKit.outline(amount, 3, deep)
		local artHolder = Instance.new("Frame")
		artHolder.Name = "Art"
		artHolder.AnchorPoint = Vector2.new(0.5, 0.5)
		artHolder.Position = UDim2.fromScale(0.5, 0.5)
		artHolder.Size = UDim2.fromScale(0.7, 0.5)
		artHolder.BackgroundTransparency = 1
		artHolder.ZIndex = z + 3
		local artRatio = Instance.new("UIAspectRatioConstraint")
		artRatio.Parent = artHolder
		artHolder.Parent = face
		local burst = Skin.texture(
			artHolder,
			"texture.sunburst",
			{ zIndex = z + 3, transparency = if isBest then 0.35 else 0.55, color = Tokens.color.featherWhite }
		)
		if burst and not motion.reducedMotion then
			table.insert(
				cleanups,
				RunService.RenderStepped:Connect(function(dt)
					if burst.Parent then
						burst.Rotation = (burst.Rotation + dt * 10) % 360
					end
				end)
			)
		end
		itemArt(artHolder, "bundle.gems" .. tostring(bundle.gems), "hud.gem", "gem", 200, z + 4).Size = UDim2.fromScale(0.8, 0.8)
		local buy = Button.build(face, {
			text = string.format("R$%d", bundle.robux),
			variant = "success",
			minimumTapTarget = tap,
			motion = motion,
			size = UDim2.new(1, -Tokens.spacing.lg, 0, tap + 8),
			zIndex = z + 4,
			textSize = Tokens.typography.title.size,
			sound = function()
				deps.audio:play(Tokens.sound.uiTap)
			end,
			hoverSound = function()
				deps.audio:play(Tokens.sound.uiHover)
			end,
			onActivated = function()
				local result =
					UpgradeActions.promptPurchase(promptDeps, "gemBundle" .. tostring(bundle.gems), withCommas(bundle.gems) .. " Gems")
				if result.ok then
					scale.Scale = 1.05
					Tween.scale(scale, "release", motion, 1)
				end
			end,
		})
		buy.button.AnchorPoint = Vector2.new(0.5, 1)
		buy.button.Position = UDim2.new(0.5, 0, 1, -Tokens.spacing.md)
		table.insert(cleanups, buy.destroy)
		if isPopular then
			local ribbon = FrameKit.badge(card, "Popular", "POPULAR", Tokens.color.goldDeep, z + 6)
			ribbon.AnchorPoint = Vector2.new(1, 0)
			ribbon.Position = UDim2.new(1, Tokens.spacing.xs, 0, Tokens.spacing.xl)
			ribbon.Rotation = 8
		end
		if isBest then
			local ribbon = FrameKit.badge(card, "Best", "BEST VALUE", Tokens.color.danger, z + 6)
			ribbon.AnchorPoint = Vector2.new(1, 0)
			ribbon.Position = UDim2.new(1, Tokens.spacing.xs, 0, if isPopular then Tokens.spacing.xl + 30 else Tokens.spacing.xl)
			ribbon.Rotation = 8
		end
		if isBest and not motion.reducedMotion then
			table.insert(cleanups, Tween.pulseLoop(scale, motion, 0.015))
		end
	end
	local arrive = FrameKit.text(
		gemsPage,
		"Arrive",
		">  GEMS ARRIVE INSTANTLY  <",
		"caption",
		{ zIndex = z + 1, color = Tokens.color.inkStrong, align = Enum.TextXAlignment.Center }
	)
	arrive.Font = Tokens.typography.label.font
	arrive.Position = UDim2.fromOffset(0, bundleH + Tokens.spacing.md)
	arrive.Size = UDim2.new(1, 0, 0, Tokens.typography.caption.size + 8)
	local useNote = Instance.new("Frame")
	useNote.Name = "Use"
	useNote.AnchorPoint = Vector2.new(0.5, 1)
	useNote.Position = UDim2.fromScale(0.5, 1)
	useNote.Size = UDim2.new(0.86, 0, 0, tap)
	useNote.ZIndex = z
	Depth.panel(useNote, Tokens.color.gold, { radius = Tokens.radius.md, rim = Tokens.color.goldLight })
	useNote.Parent = gemsPage
	local useText = FrameKit.text(
		useNote,
		"Text",
		"USE GEMS FOR PERKS & CLASS SPINS",
		"label",
		{ zIndex = z + 1, color = Tokens.color.featherWhite, align = Enum.TextXAlignment.Center, size = UDim2.fromScale(1, 1) }
	)
	useText.TextScaled = true
	FrameKit.outline(useText, 2, Tokens.color.goldDeep)

	-- FOREVER: the two permanent passes, large.
	local passH = if compact then tap * 4.4 else tap * 5
	local foreverPage = page("forever", passH + Tokens.spacing.md + tap)
	local passesRow = Instance.new("Frame")
	passesRow.Name = "Passes"
	passesRow.BackgroundTransparency = 1
	passesRow.Size = UDim2.new(1, 0, 0, passH)
	passesRow.ZIndex = z
	passesRow.Parent = foreverPage
	local passesLayout = Instance.new("UIListLayout")
	passesLayout.FillDirection = Enum.FillDirection.Horizontal
	passesLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	passesLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	passesLayout.Padding = UDim.new(0, Tokens.spacing.lg)
	passesLayout.SortOrder = Enum.SortOrder.LayoutOrder
	passesLayout.Parent = passesRow
	type PassCard = { key: string, buy: any, owned: TextLabel }
	local passCards: { PassCard } = {}
	local passOrder = 1
	for _, offer in ipairs(allOffers) do
		if offer.pass then
			local card = Instance.new("Frame")
			card.Name = "Pass_" .. offer.key
			card.Size = UDim2.fromScale(if compact then 0.46 else 0.38, 1)
			card.BackgroundColor3 = Tokens.color.goldDeep
			card.LayoutOrder = passOrder
			card.ZIndex = z + 1
			local cardCorner = Instance.new("UICorner")
			cardCorner.CornerRadius = UDim.new(0, Tokens.radius.lg)
			cardCorner.Parent = card
			Depth.keyline(card, Tokens.stroke.bold, WOOD_DEEP)
			card.Parent = passesRow
			local face = Instance.new("Frame")
			face.AnchorPoint = Vector2.new(0.5, 0)
			face.Position = UDim2.new(0.5, 0, 0, 5)
			face.Size = UDim2.new(1, -10, 1, -12)
			face.BackgroundColor3 = Tokens.color.gold
			face.BorderSizePixel = 0
			face.ZIndex = z + 2
			local faceCorner = Instance.new("UICorner")
			faceCorner.CornerRadius = UDim.new(0, Tokens.radius.md)
			faceCorner.Parent = face
			Depth.applySheen(face, Tokens.color.gold, Tokens.color.goldLight)
			face.Parent = card
			local name = FrameKit.text(
				face,
				"Name",
				string.upper(offer.name),
				"display",
				{ zIndex = z + 4, color = Tokens.color.featherWhite, align = Enum.TextXAlignment.Center }
			)
			name.Position = UDim2.fromScale(0, 0.05)
			name.Size = UDim2.fromScale(1, 0.14)
			name.TextScaled = true
			FrameKit.outline(name, 3, Tokens.color.goldDeep)
			local tag = FrameKit.badge(card, "Forever", "FOREVER", Tokens.color.gemDeep, z + 6)
			tag.AnchorPoint = Vector2.new(1, 0)
			tag.Position = UDim2.new(1, Tokens.spacing.xs, 0, -Tokens.spacing.sm)
			tag.Rotation = 8
			local artHolder = Instance.new("Frame")
			artHolder.AnchorPoint = Vector2.new(0.5, 0.5)
			artHolder.Position = UDim2.fromScale(0.5, 0.5)
			artHolder.Size = UDim2.fromScale(0.6, 0.48)
			artHolder.BackgroundTransparency = 1
			artHolder.ZIndex = z + 3
			local artRatio = Instance.new("UIAspectRatioConstraint")
			artRatio.Parent = artHolder
			artHolder.Parent = face
			Skin.texture(artHolder, "texture.sunburst", { zIndex = z + 3, transparency = 0.45, color = Tokens.color.featherWhite })
			itemArt(artHolder, "pass." .. offer.key, offer.art, offer.icon, 200, z + 4).Size = UDim2.fromScale(0.8, 0.8)
			local buy = Button.build(face, {
				text = string.format("R$%d", offer.robux or 0),
				variant = "success",
				minimumTapTarget = tap,
				motion = motion,
				size = UDim2.new(1, -Tokens.spacing.lg, 0, tap + 8),
				zIndex = z + 4,
				textSize = Tokens.typography.title.size,
				sound = function()
					deps.audio:play(Tokens.sound.uiTap)
				end,
				onActivated = function()
					UpgradeActions.promptPurchase(promptDeps, offer.key, offer.name)
				end,
			})
			buy.button.AnchorPoint = Vector2.new(0.5, 1)
			buy.button.Position = UDim2.new(0.5, 0, 1, -Tokens.spacing.md)
			table.insert(cleanups, buy.destroy)
			local owned = FrameKit.badge(face, "Owned", "OWNED", Tokens.color.success, z + 5)
			owned.AnchorPoint = Vector2.new(0.5, 1)
			owned.Position = UDim2.new(0.5, 0, 1, -Tokens.spacing.lg)
			owned.Visible = false
			table.insert(passCards, { key = offer.pass, buy = buy, owned = owned })
			passOrder += 1
		end
	end
	local foreverNote =
		paperNote(foreverPage, "Note", "Premium upgrades last forever - buy once, keep every round.", z, UDim2.new(0.7, 0, 0, tap - 6))
	foreverNote.AnchorPoint = Vector2.new(0.5, 1)
	foreverNote.Position = UDim2.fromScale(0.5, 1)

	-- Tab switching ---------------------------------------------------------------------------------
	setTab = function(name: string)
		if not pages[name] then
			return
		end
		tab = name
		for key, frame in pairs(pages) do
			frame.Visible = key == name
		end
		for key, handle in ipairs({ "perks", "gems", "forever" }) do
			local h = tabHandles[handle]
			h.setVariant(if handle == name then "primary" else "secondary")
			h.setSelected(handle == name)
			local _ = key
		end
		container:SetAttribute("SFE_ShopTab", name)
	end

	-- Rendering ------------------------------------------------------------------------------------
	local function render()
		local projection = deps.profile.projection
		if not projection then
			return
		end
		for _, record in ipairs(perkCards) do
			local preview = Perks.preview(cfg, record.perkId, projection.permanentPerks[record.perkId] or 0)
			local grew = record.displayedLevel ~= nil and record.displayedLevel ~= preview.level
			record.displayedLevel = preview.level
			for lv, dot in ipairs(record.pips) do
				local lit = lv <= preview.level
				dot.BackgroundColor3 = if lit then Tokens.color.leafBright else WOOD_DEEP
				dot.BackgroundTransparency = if lit then 0 else 0.25
				if lit and grew and lv == preview.level then
					local dotScale = dot:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
					dotScale.Parent = dot
					dotScale.Scale = 1.8
					TweenService:Create(dotScale, TweenInfo.new(0.4, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
				end
			end
			record.level.Text = string.format("LV %d", preview.level)
			if preview.maxed then
				record.nextLine.Text =
					string.format("MAX: +%d%% %s", math.floor((preview.currentMultiplier - 1) * 100 + 0.5), NEXT_WORD[record.perkId] or "")
				record.buy.button.Visible = false
				record.maxBadge.Visible = true
			else
				local nextPct = math.floor(((preview.nextMultiplier or 1) - 1) * 100 + 0.5)
				record.nextLine.Text = string.format("NEXT: +%d%% %s", nextPct, NEXT_WORD[record.perkId] or "")
				record.buy.button.Visible = true
				record.maxBadge.Visible = false
				local affordable = projection.currencies.gems >= (preview.costGems or 0)
				record.buy.setText(string.format("     %d GEMS", preview.costGems or 0))
				record.buy.setEnabled(affordable)
			end
		end
		local ent = entitlements()
		for _, mini in ipairs(passMinis) do
			local ownedPass = ent[mini.key] == true
			mini.buy.button.Visible = not ownedPass
			mini.owned.Visible = ownedPass
		end
		for _, card in ipairs(passCards) do
			local ownedPass = ent[card.key] == true
			card.buy.button.Visible = not ownedPass
			card.owned.Visible = ownedPass
		end
	end

	setTab(tab)
	render()
	if perkCards[1] then
		api.setInitialFocus(perkCards[1].buy.button)
	end
	table.insert(cleanups, deps.profile.changed:Connect(render))
	table.insert(
		cleanups,
		RunService.RenderStepped:Connect(function(dt)
			for _, gradient in ipairs(animated) do
				gradient.Rotation = (gradient.Rotation + dt * 50) % 360
			end
		end)
	)
	if api.registerDebug then
		api.registerDebug({
			tab = function(name: string)
				setTab(tostring(name))
				return { tab = tab }
			end,
		})
	end
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

-- The "gems" station: the same market, opened on the GEMS tab.
function ShopModal.buildGems(container: ScrollingFrame, api: any, deps: Deps): () -> ()
	return ShopModal.build(container, api, deps, "gems")
end

return ShopModal
