--!strict
-- Plume's Market: one centred frame with PERKS / GEMS / FOREVER tabs. Perks is a 2x2 card grid
-- (art panel, level, pips, before/after strip, one green gem button) with the two permanent
-- products as minis under it; Gems is its own three-bundle page; Forever holds only the two
-- permanent products. The gem balance sits in the header next to the close knob. Every element
-- is Scale relative to the content frame: nothing crops, scrolls or leaves the frame.
-- Prices come from config, ownership from the profile, and purchases go through the same remotes.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local Depth = require(script.Parent.Parent.Components.Depth)
local Perks = require(Shared.Domain.Perks)
local Tween = require(script.Parent.Parent.Components.Tween)
local Button = require(script.Parent.Parent.Components.Button)
local Icons = require(script.Parent.Parent.Components.Icons)
local Skin = require(script.Parent.Parent.Components.Skin)
local Confetti = require(script.Parent.Parent.Components.Confetti)
local Fit = require(script.Parent.Parent.Components.Fit)
local GemChip = require(script.Parent.Parent.Components.GemChip)
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
	openGemShop: (() -> ())?,
}

local COPY: { [string]: { title: string, icon: string, art: string, fill: Color3, deep: Color3, word: string } } = {
	bagSize = {
		title = "Bag Size",
		icon = "feather",
		art = "icon.feather",
		fill = Color3.fromRGB(104, 178, 76),
		deep = Color3.fromRGB(52, 116, 40),
		word = "CAPACITY",
	},
	handGrab = {
		title = "Hand Grab",
		icon = "star",
		art = "tool.hand.normal",
		fill = Color3.fromRGB(248, 176, 48),
		deep = Color3.fromRGB(196, 118, 14),
		word = "RANGE",
	},
	gemValue = {
		title = "Gem Value",
		icon = "gem",
		art = "hud.gem",
		fill = Color3.fromRGB(154, 92, 224),
		deep = Color3.fromRGB(96, 44, 160),
		word = "VALUE",
	},
	featherValue = {
		title = "Feather Value",
		icon = "coin",
		art = "hud.token",
		fill = Color3.fromRGB(96, 178, 236),
		deep = Color3.fromRGB(40, 110, 176),
		word = "VALUE",
	},
}

-- The two permanent products sold here (prices from config, ownership from entitlements).
type Pass = { key: string, name: string, blurb: string, art: string, icon: string, robux: number }
local function passes(cfg: { [string]: any }): { Pass }
	local list: { Pass } = {}
	local config = cfg.monetization and cfg.monetization.passes or {}
	if config.doubleGems then
		table.insert(list, {
			key = "doubleGems",
			name = "2× GEMS",
			blurb = "Every Gem you earn is doubled. Forever.",
			art = "hud.gem",
			icon = "gem",
			robux = config.doubleGems.robux,
		})
	end
	if config.infiniteBag then
		table.insert(list, {
			key = "infiniteBag",
			name = "INFINITE BAG",
			blurb = "Your bag never fills. Gather without a trip to the crate.",
			art = "icon.feather",
			icon = "feather",
			robux = config.infiniteBag.robux,
		})
	end
	return list
end

local WOOD = Color3.fromRGB(150, 108, 60)
local WOOD_DEEP = Color3.fromRGB(96, 64, 34)
local WOOD_LIGHT = Color3.fromRGB(204, 158, 100)
local PAPER = Color3.fromRGB(250, 241, 220)
local PARCHMENT = Color3.fromRGB(238, 224, 190)
local INK = Color3.fromRGB(70, 46, 24)
local RAINBOW = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 80, 80)),
	ColorSequenceKeypoint.new(0.2, Color3.fromRGB(255, 190, 60)),
	ColorSequenceKeypoint.new(0.4, Color3.fromRGB(120, 230, 90)),
	ColorSequenceKeypoint.new(0.6, Color3.fromRGB(80, 210, 255)),
	ColorSequenceKeypoint.new(0.8, Color3.fromRGB(200, 110, 255)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 80, 80)),
})
local BUNDLE_FACES = {
	{ fill = Color3.fromRGB(96, 178, 236), deep = Color3.fromRGB(40, 110, 176) },
	{ fill = Color3.fromRGB(154, 92, 224), deep = Color3.fromRGB(96, 44, 160) },
	{ fill = Color3.fromRGB(246, 196, 84), deep = Color3.fromRGB(196, 132, 12) },
}

local function withCommas(n: number): string
	local text = tostring(n)
	return (text:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", ""))
end

-- Painted art if the owner supplied it (role given), else the icon the item has always used.
local function itemArt(parent: GuiObject, painted: string, art: string, icon: string, z: number): GuiObject
	local image = Fit.image(parent, painted, { zIndex = z, name = "Art" }) or Fit.image(parent, art, { zIndex = z, name = "Art" })
	if image then
		return image
	end
	local glyph = Icons.build(icon, parent, 10, { zIndex = z })
	glyph.Name = "Art"
	glyph.AnchorPoint = Vector2.new(0.5, 0.5)
	glyph.Position = UDim2.fromScale(0.5, 0.5)
	glyph.Size = UDim2.fromScale(1, 1)
	return glyph
end

local function paper(parent: GuiObject, name: string, position: UDim2, size: UDim2, z: number, face: Color3?, rim: Color3?): Frame
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.Position = position
	frame.Size = size
	frame.BorderSizePixel = 0
	frame.ZIndex = z
	Depth.panel(frame, face or PAPER, { radius = Tokens.radius.md, rim = Color3.new(1, 1, 1) })
	Fit.corner(frame, 0.08)
	local line = Depth.keylineOf(frame)
	if line then
		line.Color = rim or WOOD
		line.Thickness = 2
	end
	frame.Parent = parent
	return frame
end

local function plank(parent: GuiObject, name: string, position: UDim2, size: UDim2, z: number): Frame
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.Position = position
	frame.Size = size
	frame.BorderSizePixel = 0
	frame.ZIndex = z
	Depth.panel(frame, WOOD, { radius = Tokens.radius.md, rim = WOOD_LIGHT })
	Fit.corner(frame, 0.22)
	frame.Parent = parent
	return frame
end

-- A green price button with a leading gem or the Robux mark. Returns the handle.
local function priceButton(parent: GuiObject, name: string, text: string, options: any, gem: boolean): any
	local handle = Button.build(parent, {
		text = text,
		variant = "success",
		minimumTapTarget = options.tap,
		motion = options.motion,
		size = options.size,
		zIndex = options.zIndex or 5,
		sound = function()
			options.audio:play(Tokens.sound.uiTap)
		end,
		hoverSound = function()
			options.audio:play(Tokens.sound.uiHover)
		end,
		onActivated = options.onActivated,
	})
	handle.button.Name = name
	handle.button.Position = options.position or handle.button.Position
	handle.button.AnchorPoint = options.anchor or handle.button.AnchorPoint
	if options.relax then
		options.relax(handle.button)
	end
	local label = Fit.buttonText(handle, options.max or 28)
	if gem and label then
		local pad = label:FindFirstChildOfClass("UIPadding")
		if pad then
			pad.PaddingLeft = UDim.new(0.24, 0)
			pad.PaddingRight = UDim.new(0.04, 0)
		end
		local face = handle.button:FindFirstChild("Face")
		if face then
			local icon = Fit.image(
				face,
				"hud.gem",
				{ size = UDim2.fromScale(0, 0.7), position = UDim2.fromScale(0.14, 0.5), zIndex = 6, name = "Gem" }
			)
			if icon then
				Fit.aspect(icon, 1, Enum.DominantAxis.Height)
			end
		end
	end
	return handle
end

local function ownedBadge(parent: GuiObject, position: UDim2, size: UDim2, anchor: Vector2?, z: number): Frame
	local badge = Instance.new("Frame")
	badge.Name = "Owned"
	badge.Position = position
	badge.Size = size
	badge.AnchorPoint = anchor or Vector2.new(0, 0)
	badge.BorderSizePixel = 0
	badge.ZIndex = z
	badge.Visible = false
	Depth.panel(badge, Tokens.color.gold, { radius = Tokens.radius.md, rim = Tokens.color.goldLight })
	Fit.corner(badge, 0.3)
	Fit.text(badge, "Label", "OWNED", {
		font = Tokens.typography.label.font,
		color = Tokens.color.featherWhite,
		max = 24,
		outline = 1.5,
		outlineColor = Tokens.color.goldDeep,
		zIndex = z + 1,
		size = UDim2.fromScale(0.9, 0.7),
		position = UDim2.fromScale(0.5, 0.5),
		anchor = Vector2.new(0.5, 0.5),
	})
	badge.Parent = parent
	return badge
end

function ShopModal.build(container: ScrollingFrame, api: any, deps: Deps, initialTab: string?): () -> ()
	local cleanups: { any } = {}
	local cfg = deps.config
	local motion = deps.accessibility:motionSettings()
	local tap = deps.minimumTapTarget
	local tier = deps.quality and deps.quality:tier() or nil
	local shell = api.shell
	local promptDeps = { net = deps.net, audio = deps.audio, toasts = deps.toasts }
	local phone = SafeArea.classOf(container) == "phone"
	-- Phones give controls their Scale height; the 44 px floor would stack them over each other.
	local function relax(button: GuiObject)
		if phone then
			local constraint = button:FindFirstChildOfClass("UISizeConstraint")
			if constraint then
				constraint.MinSize = Vector2.new(0, 0)
			end
		end
	end
	local function entitlements(): { [string]: boolean }
		return deps.entitlements and deps.entitlements() or {}
	end
	local render: () -> ()

	container.AutomaticCanvasSize = Enum.AutomaticSize.None
	container.CanvasSize = UDim2.fromScale(0, 0)
	container.ScrollingEnabled = false
	container.ScrollBarThickness = 0
	local root = Fit.frame(container, "Market", UDim2.fromScale(0, 0), UDim2.fromScale(1, 1), 1)
	local tab = initialTab or "perks"
	local setTab: (name: string) -> ()

	-- Header chip ----------------------------------------------------------------------------------
	local chip = GemChip.build(shell.headerRight, {
		count = (deps.profile.projection and deps.profile.projection.currencies.gems) or 0,
		zIndex = 1,
		minimumTapTarget = tap,
		sound = function()
			deps.audio:play(Tokens.sound.uiTap)
		end,
		onPlus = function()
			setTab("gems")
		end,
	})
	chip.root.LayoutOrder = 1
	table.insert(cleanups, chip.destroy)

	-- Tabs -------------------------------------------------------------------------------------------
	local tabsRow = Fit.frame(root, "Tabs", UDim2.fromScale(0, 0), UDim2.fromScale(1, 0.105), 2)
	Fit.row(tabsRow, { gap = 0.015, halign = Enum.HorizontalAlignment.Left })
	type TabView = { name: string, button: TextButton, face: Frame, label: TextLabel, glyph: GuiObject? }
	local tabViews: { TabView } = {}
	local function buildTab(name: string, text: string, order: number, art: string?, glyphText: string?)
		local button = Instance.new("TextButton")
		button.Name = "Tab_" .. name
		button.Text = ""
		button.AutoButtonColor = false
		button.LayoutOrder = order
		button.Size = UDim2.fromScale(0.21, 1)
		button.BackgroundColor3 = WOOD_DEEP
		button.BorderSizePixel = 0
		button.ZIndex = 2
		button.Selectable = true
		Fit.corner(button, 0.28)
		Depth.keyline(button)
		local minSize = Instance.new("UISizeConstraint")
		minSize.MinSize = Vector2.new(tap, tap)
		minSize.Parent = button
		relax(button)
		local face = Instance.new("Frame")
		face.Name = "Face"
		face.Size = UDim2.fromScale(1, 0.9)
		face.BackgroundColor3 = PARCHMENT
		face.BorderSizePixel = 0
		face.ZIndex = 2
		Fit.corner(face, 0.28)
		Depth.applySheen(face, PARCHMENT)
		Depth.rim(face, PARCHMENT)
		face.Parent = button
		local glyph: GuiObject? = nil
		if art then
			glyph =
				Fit.image(face, art, { size = UDim2.fromScale(0, 0.66), position = UDim2.fromScale(0.16, 0.5), zIndex = 4, name = "Glyph" })
			if glyph then
				Fit.aspect(glyph :: GuiObject, 1, Enum.DominantAxis.Height)
			end
		end
		if not glyph then
			glyph = Fit.text(face, "Glyph", glyphText or "•", {
				font = Tokens.typography.display.font,
				color = INK,
				max = 30,
				zIndex = 4,
				size = UDim2.fromScale(0.18, 0.7),
				position = UDim2.fromScale(0.16, 0.5),
				anchor = Vector2.new(0.5, 0.5),
			})
		end
		local label = Fit.text(face, "Label", text, {
			font = Tokens.typography.title.font,
			color = INK,
			max = 26,
			zIndex = 4,
			size = UDim2.fromScale(0.62, 0.7),
			position = UDim2.fromScale(0.3, 0.15),
			align = Enum.TextXAlignment.Left,
		})
		local scale = Instance.new("UIScale")
		scale.Parent = button
		table.insert(
			cleanups,
			button.MouseEnter:Connect(function()
				deps.audio:play(Tokens.sound.uiHover)
				Tween.scale(scale, "hover", motion, 1.03)
			end)
		)
		table.insert(
			cleanups,
			button.MouseLeave:Connect(function()
				Tween.scale(scale, "release", motion, 1)
			end)
		)
		table.insert(
			cleanups,
			button.Activated:Connect(function()
				deps.audio:play(Tokens.sound.uiTab)
				setTab(name)
			end)
		)
		button.Parent = tabsRow
		table.insert(tabViews, { name = name, button = button, face = face, label = label, glyph = glyph })
	end
	buildTab("perks", "PERKS", 1, "icon.feather", nil)
	buildTab("gems", "GEMS", 2, "hud.gem", nil)
	buildTab("forever", "FOREVER", 3, nil, "∞")

	local pages = Fit.frame(root, "Pages", UDim2.fromScale(0, 0.125), UDim2.fromScale(1, 0.875), 2)
	local pageViews: { [string]: Frame } = {}
	local function page(name: string): Frame
		local frame = Fit.frame(pages, "Page_" .. name, UDim2.fromScale(0, 0), UDim2.fromScale(1, 1), 1)
		frame.Visible = false
		pageViews[name] = frame
		return frame
	end

	-- PERKS ------------------------------------------------------------------------------------------
	local perksPage = page("perks")
	type PerkRecord = {
		perkId: string,
		root: Frame,
		scale: UIScale,
		level: TextLabel,
		pips: { Frame },
		nextLine: TextLabel,
		buy: any,
		maxBadge: Frame,
		afterArt: GuiObject,
		displayedLevel: number?,
	}
	local perkCards: { PerkRecord } = {}
	-- Desktop: a 2x2 grid that fits. Phone: one row of taller cards the player swipes through.
	local grid: GuiObject = perksPage
	local span = 0.48 * #Perks.IDS + 0.02
	if phone then
		local scroller = Instance.new("ScrollingFrame")
		scroller.Name = "Grid"
		scroller.BackgroundTransparency = 1
		scroller.BorderSizePixel = 0
		scroller.Size = UDim2.fromScale(1, 0.8)
		-- Canvas Scale is measured against the page, not the scroller, so it copies the 0.78 height.
		scroller.CanvasSize = UDim2.fromScale(span, 0.78)
		scroller.ScrollingDirection = Enum.ScrollingDirection.X
		scroller.ScrollBarThickness = 4
		scroller.ScrollBarImageColor3 = Tokens.color.goldDeep
		scroller.ElasticBehavior = Enum.ElasticBehavior.Never
		scroller.ZIndex = 2
		scroller.Parent = perksPage
		grid = scroller
	end
	for index, perkId in ipairs(Perks.IDS) do
		local copy = COPY[perkId]
			or { title = perkId, icon = "star", art = "icon.egg", fill = Tokens.color.gold, deep = Tokens.color.goldDeep, word = "" }
		local col = (index - 1) % 2
		local row = math.floor((index - 1) / 2)
		local card = paper(
			grid,
			"Perk_" .. perkId,
			if phone then UDim2.fromScale((index - 1) * 0.48 / span, 0.02) else UDim2.fromScale(col * 0.505, row * 0.405),
			if phone then UDim2.fromScale(0.46 / span, 0.96) else UDim2.fromScale(0.495, 0.385),
			2,
			PAPER,
			copy.deep
		)
		local scale = Instance.new("UIScale")
		scale.Parent = card
		local artPanel = Instance.new("Frame")
		artPanel.Name = "ArtPanel"
		artPanel.Position = UDim2.fromScale(0.02, 0.045)
		artPanel.Size = UDim2.fromScale(0.42, 0.66)
		artPanel.BorderSizePixel = 0
		artPanel.ZIndex = 3
		artPanel.ClipsDescendants = true
		Depth.panel(artPanel, copy.fill, { radius = Tokens.radius.md, rim = Color3.new(1, 1, 1) })
		Fit.corner(artPanel, 0.1)
		artPanel.Parent = card
		local burst = Skin.texture(artPanel, "texture.sunburst", { transparency = 0.7, name = "Burst", zIndex = 1 })
		if burst then
			burst.AnchorPoint = Vector2.new(0.5, 0.5)
			burst.Position = UDim2.fromScale(0.5, 0.5)
			burst.Size = UDim2.fromScale(1.8, 1.8)
		end
		local artBox = Fit.frame(artPanel, "ArtBox", UDim2.fromScale(0.5, 0.5), UDim2.fromScale(0.7, 0.72), 3, Vector2.new(0.5, 0.5))
		itemArt(artBox, "perk." .. perkId, copy.art, copy.icon, 3)
		local nextLine = Fit.text(card, "Next", "NEXT: +10% " .. copy.word, {
			font = Tokens.typography.label.font,
			color = INK,
			max = 18,
			zIndex = 3,
			size = UDim2.fromScale(0.42, 0.2),
			position = UDim2.fromScale(0.02, 0.74),
			align = Enum.TextXAlignment.Left,
		})
		Fit.text(card, "Title", string.upper(copy.title), {
			font = Tokens.typography.title.font,
			color = INK,
			max = 30,
			zIndex = 3,
			size = UDim2.fromScale(0.5, 0.17),
			position = UDim2.fromScale(0.47, 0.05),
			align = Enum.TextXAlignment.Left,
		})
		local levelBadge = Instance.new("Frame")
		levelBadge.Name = "Level"
		levelBadge.Position = UDim2.fromScale(0.47, 0.25)
		levelBadge.Size = UDim2.fromScale(0.16, 0.14)
		levelBadge.BackgroundColor3 = copy.deep
		levelBadge.BorderSizePixel = 0
		levelBadge.ZIndex = 3
		Fit.corner(levelBadge, 0.4)
		levelBadge.Parent = card
		local level = Fit.text(levelBadge, "Text", "LV 0", {
			font = Tokens.typography.label.font,
			color = Tokens.color.featherWhite,
			max = 16,
			zIndex = 4,
			size = UDim2.fromScale(0.9, 0.76),
			position = UDim2.fromScale(0.5, 0.5),
			anchor = Vector2.new(0.5, 0.5),
		})
		local pipRow = Fit.frame(card, "Pips", UDim2.fromScale(0.47, 0.42), UDim2.fromScale(0.5, 0.09), 3)
		Fit.row(pipRow, { gap = 0.012, halign = Enum.HorizontalAlignment.Left })
		local pips: { Frame } = {}
		local maxLevel = cfg.permanentPerks[perkId].maxLevel
		for lv = 1, maxLevel do
			local dot = Instance.new("Frame")
			dot.Name = "Pip" .. lv
			dot.LayoutOrder = lv
			dot.Size = UDim2.fromScale(0, 0.8)
			dot.BackgroundColor3 = WOOD_DEEP
			dot.BackgroundTransparency = 0.3
			dot.BorderSizePixel = 0
			dot.ZIndex = 4
			Fit.aspect(dot, 1, Enum.DominantAxis.Height)
			Fit.corner(dot, 0.5)
			dot.Parent = pipRow
			table.insert(pips, dot)
		end
		local preview = paper(card, "Preview", UDim2.fromScale(0.47, 0.55), UDim2.fromScale(0.5, 0.17), 3, PARCHMENT, WOOD_LIGHT)
		local beforeBox = Fit.frame(preview, "Before", UDim2.fromScale(0.28, 0.5), UDim2.fromScale(0, 0.62), 4, Vector2.new(0.5, 0.5))
		Fit.aspect(beforeBox, 1, Enum.DominantAxis.Height)
		itemArt(beforeBox, "perk." .. perkId, copy.art, copy.icon, 4)
		Fit.text(preview, "Arrow", "→", {
			font = Tokens.typography.display.font,
			color = Tokens.color.leafBright,
			max = 30,
			outline = 1.5,
			outlineColor = Tokens.color.leafDeep,
			zIndex = 4,
			size = UDim2.fromScale(0.2, 0.8),
			position = UDim2.fromScale(0.5, 0.5),
			anchor = Vector2.new(0.5, 0.5),
		})
		local afterBox = Fit.frame(preview, "After", UDim2.fromScale(0.74, 0.5), UDim2.fromScale(0, 0.86), 4, Vector2.new(0.5, 0.5))
		Fit.aspect(afterBox, 1, Enum.DominantAxis.Height)
		local afterArt = itemArt(afterBox, "perk." .. perkId, copy.art, copy.icon, 4)
		local buy = priceButton(card, "Buy", "25 GEMS", {
			tap = tap,
			motion = motion,
			audio = deps.audio,
			relax = relax,
			size = UDim2.fromScale(0.5, 0.2),
			position = UDim2.fromScale(0.47, 0.76),
			zIndex = 4,
			max = 26,
		}, true)
		table.insert(cleanups, buy.destroy)
		local maxBadge = ownedBadge(card, UDim2.fromScale(0.47, 0.76), UDim2.fromScale(0.5, 0.2), nil, 4)
		maxBadge.Name = "Maxed"
		local maxLabel = maxBadge:FindFirstChild("Label") :: TextLabel
		maxLabel.Text = "MAXED"
		local record: PerkRecord = {
			perkId = perkId,
			root = card,
			scale = scale,
			level = level,
			pips = pips,
			nextLine = nextLine,
			buy = buy,
			maxBadge = maxBadge,
			afterArt = afterArt,
			displayedLevel = nil,
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
					scale.Scale = 1.04
					Tween.scale(scale, "release", motion, 1)
					Confetti.burst(
						card,
						{ origin = UDim2.fromScale(0.5, 0.45), count = 22, spread = 140, motion = motion, tier = tier, zIndex = 9 }
					)
					deps.audio:play(Tokens.sound.uiConfetti)
					deps.toasts:push(string.format("%s reached level %d", copy.title, result.data.level), "success")
				else
					deps.audio:play(Tokens.sound.uiError)
					Tween.shake(card, motion)
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

	-- Perks strip: note, the two permanent products as minis, and the link to the Forever tab.
	local passList = passes(cfg)
	type MiniView = { key: string, buy: any, owned: Frame }
	local passMinis: { MiniView } = {}
	local note = paper(perksPage, "Note", UDim2.fromScale(0.005, 0.835), UDim2.fromScale(0.17, 0.16), 2, PARCHMENT, WOOD_LIGHT)
	note.Rotation = -2.5
	Fit.text(note, "Text", "Premium Upgrades\nLast Forever!", {
		font = Tokens.typography.title.font,
		color = INK,
		max = 18,
		zIndex = 3,
		size = UDim2.fromScale(0.9, 0.8),
		position = UDim2.fromScale(0.5, 0.5),
		anchor = Vector2.new(0.5, 0.5),
	})
	for index, pass in ipairs(passList) do
		local mini = paper(
			perksPage,
			"Mini_" .. pass.key,
			UDim2.fromScale(0.195 + (index - 1) * 0.225, 0.835),
			UDim2.fromScale(0.215, 0.16),
			2,
			PAPER,
			WOOD
		)
		local artBox = Fit.frame(mini, "ArtBox", UDim2.fromScale(0.15, 0.5), UDim2.fromScale(0, 0.74), 3, Vector2.new(0.5, 0.5))
		Fit.aspect(artBox, 1, Enum.DominantAxis.Height)
		itemArt(artBox, "pass." .. pass.key, pass.art, pass.icon, 3)
		Fit.text(mini, "Name", pass.name, {
			font = Tokens.typography.title.font,
			color = INK,
			max = 18,
			zIndex = 3,
			size = UDim2.fromScale(0.34, 0.42),
			position = UDim2.fromScale(0.29, 0.1),
			align = Enum.TextXAlignment.Left,
		})
		Fit.text(mini, "Forever", "FOREVER", {
			font = Tokens.typography.caption.font,
			color = WOOD,
			max = 12,
			zIndex = 3,
			size = UDim2.fromScale(0.34, 0.3),
			position = UDim2.fromScale(0.29, 0.56),
			align = Enum.TextXAlignment.Left,
		})
		local buy = priceButton(mini, "Buy", "R$ " .. tostring(pass.robux), {
			tap = tap,
			motion = motion,
			audio = deps.audio,
			relax = relax,
			size = UDim2.fromScale(0.3, 0.58),
			position = UDim2.fromScale(0.97, 0.5),
			anchor = Vector2.new(1, 0.5),
			zIndex = 4,
			max = 18,
			onActivated = function()
				UpgradeActions.promptPurchase(promptDeps, pass.key, pass.name)
			end,
		}, false)
		table.insert(cleanups, buy.destroy)
		local owned = ownedBadge(mini, UDim2.fromScale(0.97, 0.5), UDim2.fromScale(0.3, 0.58), Vector2.new(1, 0.5), 4)
		table.insert(passMinis, { key = pass.key, buy = buy, owned = owned })
	end
	local viewForever = Button.build(perksPage, {
		text = "VIEW FOREVER PERKS  >",
		variant = "primary",
		minimumTapTarget = tap,
		motion = motion,
		size = UDim2.fromScale(0.3, 0.14),
		zIndex = 3,
		sound = function()
			deps.audio:play(Tokens.sound.uiTab)
		end,
		onActivated = function()
			setTab("forever")
		end,
	})
	viewForever.button.Name = "ViewForever"
	viewForever.button.AnchorPoint = Vector2.new(1, 0.5)
	viewForever.button.Position = UDim2.fromScale(0.995, 0.915)
	relax(viewForever.button)
	Fit.buttonText(viewForever, 20)
	table.insert(cleanups, viewForever.destroy)

	-- GEMS -------------------------------------------------------------------------------------------
	local gemsPage = page("gems")
	local bundles = cfg.monetization and cfg.monetization.gemBundles or {}
	local bestIndex = 1
	local bestRate = 0
	for index, bundle in ipairs(bundles) do
		local rate = bundle.gems / math.max(1, bundle.robux)
		if rate > bestRate then
			bestRate = rate
			bestIndex = index
		end
	end
	local animated: { UIGradient } = {}
	local bundleWidth = 0.32
	local bundleGap = (1 - bundleWidth * #bundles) / math.max(1, #bundles - 1)
	for index, bundle in ipairs(bundles) do
		local face = BUNDLE_FACES[math.min(index, #BUNDLE_FACES)]
		local best = index == bestIndex
		local card = paper(
			gemsPage,
			"Bundle_" .. tostring(bundle.gems),
			UDim2.fromScale((index - 1) * (bundleWidth + bundleGap), 0.0),
			UDim2.fromScale(bundleWidth, 0.8),
			2,
			face.fill,
			face.deep
		)
		card.ClipsDescendants = false
		local line = Depth.keylineOf(card)
		if line then
			line.Thickness = if best then 5 else 2.5
			if best then
				local gradient = Instance.new("UIGradient")
				gradient.Color = RAINBOW
				gradient.Parent = line
				table.insert(animated, gradient)
			end
		end
		local burst = Skin.texture(card, "texture.sunburst", { transparency = 0.72, name = "Burst", zIndex = 1 })
		if burst then
			burst.AnchorPoint = Vector2.new(0.5, 0.5)
			burst.Position = UDim2.fromScale(0.5, 0.5)
			burst.Size = UDim2.fromScale(1.6, 1.6)
		end
		Fit.text(card, "Title", withCommas(bundle.gems) .. " GEMS", {
			font = Tokens.typography.display.font,
			color = Tokens.color.featherWhite,
			max = 44,
			outline = 2.5,
			outlineColor = face.deep,
			zIndex = 3,
			size = UDim2.fromScale(0.9, 0.16),
			position = UDim2.fromScale(0.5, 0.12),
			anchor = Vector2.new(0.5, 0.5),
		})
		local artSize = 0.42 + index * 0.1
		local artBox =
			Fit.frame(card, "ArtBox", UDim2.fromScale(0.5, 0.5), UDim2.fromScale(artSize, artSize * 0.8), 3, Vector2.new(0.5, 0.5))
		itemArt(artBox, "bundle.gems" .. tostring(bundle.gems), "hud.gem", "gem", 3)
		if best then
			local badge = Instance.new("Frame")
			badge.Name = "BestValue"
			badge.AnchorPoint = Vector2.new(0.5, 0.5)
			badge.Position = UDim2.fromScale(0.8, 0.32)
			badge.Size = UDim2.fromScale(0.34, 0.17)
			badge.BorderSizePixel = 0
			badge.ZIndex = 5
			badge.Rotation = 6
			Depth.panel(badge, Tokens.color.emberDeep, { radius = Tokens.radius.md, rim = Tokens.color.goldLight })
			Fit.corner(badge, 0.2)
			Fit.text(badge, "Text", "BEST\nVALUE", {
				font = Tokens.typography.title.font,
				color = Tokens.color.goldLight,
				max = 18,
				outline = 1.5,
				outlineColor = Tokens.color.emberDeep,
				zIndex = 6,
				size = UDim2.fromScale(0.9, 0.84),
				position = UDim2.fromScale(0.5, 0.5),
				anchor = Vector2.new(0.5, 0.5),
			})
			badge.Parent = card
		end
		if bundle.popular == true then
			local ribbon = paper(
				card,
				"Popular",
				UDim2.fromScale(0.86, if best then 0.52 else 0.32),
				UDim2.fromScale(0.36, 0.11),
				5,
				PARCHMENT,
				Tokens.color.goldDeep
			)
			ribbon.AnchorPoint = Vector2.new(0.5, 0.5)
			ribbon.Rotation = -4
			Fit.text(ribbon, "Text", "POPULAR", {
				font = Tokens.typography.label.font,
				color = INK,
				max = 16,
				zIndex = 6,
				size = UDim2.fromScale(0.9, 0.7),
				position = UDim2.fromScale(0.5, 0.5),
				anchor = Vector2.new(0.5, 0.5),
			})
		end
		local buy = priceButton(card, "Buy", "R$" .. tostring(bundle.robux), {
			tap = tap,
			motion = motion,
			audio = deps.audio,
			relax = relax,
			size = UDim2.fromScale(0.84, 0.16),
			position = UDim2.fromScale(0.5, 0.88),
			anchor = Vector2.new(0.5, 0.5),
			zIndex = 4,
			max = 34,
			onActivated = function()
				UpgradeActions.promptPurchase(promptDeps, "gemBundle" .. tostring(bundle.gems), withCommas(bundle.gems) .. " Gems")
			end,
		}, false)
		table.insert(cleanups, buy.destroy)
	end
	Fit.text(gemsPage, "Instant", "—  GEMS ARRIVE INSTANTLY  —", {
		font = Tokens.typography.label.font,
		color = WOOD,
		max = 20,
		zIndex = 3,
		size = UDim2.fromScale(0.7, 0.06),
		position = UDim2.fromScale(0.5, 0.845),
		anchor = Vector2.new(0.5, 0.5),
	})
	local banner = plank(gemsPage, "Banner", UDim2.fromScale(0.5, 0.945), UDim2.fromScale(0.96, 0.1), 3)
	banner.AnchorPoint = Vector2.new(0.5, 0.5)
	local bannerGem = Fit.image(banner, "hud.gem", { size = UDim2.fromScale(0, 0.8), position = UDim2.fromScale(0.05, 0.5), zIndex = 4 })
	if bannerGem then
		Fit.aspect(bannerGem, 1, Enum.DominantAxis.Height)
	end
	Fit.text(banner, "Text", "USE GEMS FOR PERKS & CLASS SPINS", {
		font = Tokens.typography.title.font,
		color = PAPER,
		max = 24,
		outline = 1.5,
		outlineColor = WOOD_DEEP,
		zIndex = 4,
		size = UDim2.fromScale(0.7, 0.7),
		position = UDim2.fromScale(0.5, 0.5),
		anchor = Vector2.new(0.5, 0.5),
	})
	local bannerFeather =
		Fit.image(banner, "icon.feather", { size = UDim2.fromScale(0, 0.8), position = UDim2.fromScale(0.91, 0.5), zIndex = 4 })
	if bannerFeather then
		Fit.aspect(bannerFeather, 1, Enum.DominantAxis.Height)
	end
	local bannerEgg = Fit.image(banner, "icon.egg", { size = UDim2.fromScale(0, 0.8), position = UDim2.fromScale(0.96, 0.5), zIndex = 4 })
	if bannerEgg then
		Fit.aspect(bannerEgg, 1, Enum.DominantAxis.Height)
	end

	-- FOREVER ----------------------------------------------------------------------------------------
	local foreverPage = page("forever")
	type PassView = { key: string, buy: any, owned: Frame }
	local passCards: { PassView } = {}
	local passWidth = 0.36
	local passStart = (1 - (passWidth * #passList + 0.06 * math.max(0, #passList - 1))) / 2
	for index, pass in ipairs(passList) do
		local card = paper(
			foreverPage,
			"Pass_" .. pass.key,
			UDim2.fromScale(passStart + (index - 1) * (passWidth + 0.06), 0.03),
			UDim2.fromScale(passWidth, 0.9),
			2,
			Tokens.color.gold,
			Tokens.color.goldDeep
		)
		local burst = Skin.texture(card, "texture.sunburst", { transparency = 0.7, name = "Burst", zIndex = 1 })
		if burst then
			burst.AnchorPoint = Vector2.new(0.5, 0.5)
			burst.Position = UDim2.fromScale(0.5, 0.42)
			burst.Size = UDim2.fromScale(1.6, 1.4)
		end
		Fit.text(card, "Name", pass.name, {
			font = Tokens.typography.display.font,
			color = Tokens.color.featherWhite,
			max = 42,
			outline = 2.5,
			outlineColor = Tokens.color.goldDeep,
			zIndex = 3,
			size = UDim2.fromScale(0.9, 0.14),
			position = UDim2.fromScale(0.5, 0.1),
			anchor = Vector2.new(0.5, 0.5),
		})
		local foreverTag = plank(card, "ForeverTag", UDim2.fromScale(0.5, 0.21), UDim2.fromScale(0.36, 0.08), 3)
		foreverTag.AnchorPoint = Vector2.new(0.5, 0.5)
		Fit.text(foreverTag, "Text", "FOREVER", {
			font = Tokens.typography.label.font,
			color = PAPER,
			max = 16,
			zIndex = 4,
			size = UDim2.fromScale(0.9, 0.7),
			position = UDim2.fromScale(0.5, 0.5),
			anchor = Vector2.new(0.5, 0.5),
		})
		local artBox = Fit.frame(card, "ArtBox", UDim2.fromScale(0.5, 0.5), UDim2.fromScale(0.5, 0.36), 3, Vector2.new(0.5, 0.5))
		itemArt(artBox, "pass." .. pass.key, pass.art, pass.icon, 3)
		Fit.text(card, "Blurb", pass.blurb, {
			font = Tokens.typography.body.font,
			color = INK,
			max = 18,
			zIndex = 3,
			size = UDim2.fromScale(0.84, 0.12),
			position = UDim2.fromScale(0.5, 0.75),
			anchor = Vector2.new(0.5, 0.5),
		})
		local buy = priceButton(card, "Buy", "R$" .. tostring(pass.robux), {
			tap = tap,
			motion = motion,
			audio = deps.audio,
			relax = relax,
			size = UDim2.fromScale(0.7, 0.14),
			position = UDim2.fromScale(0.5, 0.9),
			anchor = Vector2.new(0.5, 0.5),
			zIndex = 4,
			max = 32,
			onActivated = function()
				UpgradeActions.promptPurchase(promptDeps, pass.key, pass.name)
			end,
		}, false)
		table.insert(cleanups, buy.destroy)
		local owned = ownedBadge(card, UDim2.fromScale(0.5, 0.9), UDim2.fromScale(0.7, 0.14), Vector2.new(0.5, 0.5), 4)
		table.insert(passCards, { key = pass.key, buy = buy, owned = owned })
	end

	-- Tabs and rendering -------------------------------------------------------------------------
	setTab = function(name: string)
		if not pageViews[name] then
			return
		end
		tab = name
		for pageName, frame in pairs(pageViews) do
			frame.Visible = pageName == name
		end
		for _, view in ipairs(tabViews) do
			local selected = view.name == name
			view.face.BackgroundColor3 = if selected then Tokens.color.gold else PARCHMENT
			view.label.TextColor3 = if selected then Tokens.color.featherWhite else INK
			local sheen = view.face:FindFirstChildOfClass("UIGradient")
			if sheen then
				sheen.Color = Depth.sheen(if selected then Tokens.color.gold else PARCHMENT)
			end
			local outline = view.label:FindFirstChild("TextOutline") :: UIStroke?
			if selected and not outline then
				local stroke = Instance.new("UIStroke")
				stroke.Name = "TextOutline"
				stroke.Thickness = 1.6
				stroke.Color = Tokens.color.goldDeep
				stroke.Parent = view.label
			elseif outline then
				outline.Enabled = selected
			end
			if view.glyph and view.glyph:IsA("TextLabel") then
				view.glyph.TextColor3 = if selected then Tokens.color.featherWhite else INK
			end
		end
		container:SetAttribute("SFE_ShopTab", name)
	end

	render = function()
		local projection = deps.profile.projection
		if not projection then
			return
		end
		chip.setCount(projection.currencies.gems or 0)
		for _, record in ipairs(perkCards) do
			local preview = Perks.preview(cfg, record.perkId, projection.permanentPerks[record.perkId] or 0)
			local copy = COPY[record.perkId]
			local grew = record.displayedLevel ~= nil and record.displayedLevel ~= preview.level
			record.displayedLevel = preview.level
			for lv, dot in ipairs(record.pips) do
				local lit = lv <= preview.level
				dot.BackgroundColor3 = if lit then Tokens.color.leafBright else WOOD_DEEP
				dot.BackgroundTransparency = if lit then 0 else 0.3
				if lit and grew and lv == preview.level then
					local dotScale = dot:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
					dotScale.Parent = dot
					dotScale.Scale = 1.8
					TweenService:Create(dotScale, TweenInfo.new(0.4, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
				end
			end
			record.level.Text = string.format("LV %d", preview.level)
			local word = copy and copy.word or ""
			if preview.maxed then
				record.nextLine.Text = string.format("MAX: +%d%% %s", math.floor((preview.currentMultiplier - 1) * 100 + 0.5), word)
				record.buy.button.Visible = false
				record.maxBadge.Visible = true
			else
				local nextPct = math.floor(((preview.nextMultiplier or 1) - 1) * 100 + 0.5)
				record.nextLine.Text = string.format("NEXT: +%d%% %s", nextPct, word)
				record.buy.button.Visible = true
				record.maxBadge.Visible = false
				local affordable = (projection.currencies.gems or 0) >= (preview.costGems or 0)
				record.buy.setText(string.format("%d GEMS", preview.costGems or 0))
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
				setTab(name)
				return { tab = tab }
			end,
			state = function()
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

function ShopModal.buildGems(container: ScrollingFrame, api: any, deps: Deps): () -> ()
	return ShopModal.build(container, api, deps, "gems")
end

return ShopModal
