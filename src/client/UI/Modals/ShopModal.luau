--!strict
-- Plume's Market, drawn to the owner's reference clip (17 Sep 2026): the shell's charcoal card with
-- PERKS / GEMS / FOREVER tab pills (dark slate, the active one green), a white stroked section label
-- on every page, and rows of chunky cards. Perks is a 2x2 grid of dark slate cards (painted perk art
-- in a well, level pill, pips, before/after strip, one green UPGRADE button with the gem cost or a
-- red-rimmed MAX) with the two permanent products as minis under it; Gems is three purple-tinted
-- bundle cards with the painted art large; Forever holds the two passes on a blue and a gold card.
-- The gem balance sits in the header next to the close knob. Every element is Scale relative to the
-- content frame and every label carries a black stroke: nothing crops, scrolls or leaves the frame.
-- Prices come from config, ownership from the profile, and purchases go through the same remotes.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local Depth = require(script.Parent.Parent.Components.Depth)
local Perks = require(Shared.Domain.Perks)
local Tween = require(script.Parent.Parent.Components.Tween)
local Button = require(script.Parent.Parent.Components.Button)
local Icons = require(script.Parent.Parent.Components.Icons)
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

local COPY: { [string]: { title: string, icon: string, art: string, word: string } } = {
	bagSize = { title = "Bag Size", icon = "feather", art = "icon.feather", word = "CAPACITY" },
	handGrab = { title = "Hand Grab", icon = "star", art = "tool.hand.normal", word = "RANGE" },
	gemValue = { title = "Gem Value", icon = "gem", art = "hud.gem", word = "VALUE" },
	featherValue = { title = "Feather Value", icon = "coin", art = "hud.token", word = "VALUE" },
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

-- Palette: the shell's dark kit, every surface a token. Slate cards, a deeper well inside them,
-- the near-black keyline around everything, white lettering. Gem cards are slate tinted towards
-- the gem purple; the two passes sit on blue (currency) and gold (VIP) tints.
local SLATE = Tokens.color.surface
local WELL = Tokens.color.surfaceAlt
local DEEP = Tokens.color.panelDeep
local OUTLINE = Tokens.color.outline
local WHITE = Tokens.color.featherWhite
local MUTED = Tokens.color.inkMuted
local KEYLINE = Tokens.depth.keyline
local STROKE = 2.6 -- the black stroke on every label
local GEM_CARD = Depth.mix(SLATE, Tokens.color.gem, 0.38)
local PASS_FACES = { Depth.mix(SLATE, Tokens.color.sky, 0.45), Depth.mix(SLATE, Tokens.color.gold, 0.5) }

local function withCommas(n: number): string
	local text = tostring(n)
	return (text:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", ""))
end

-- A white label with the black stroke every piece of lettering carries.
local function text(parent: Instance, name: string, value: string, options: Fit.TextOptions?): TextLabel
	local opts = (options or {}) :: any
	if opts.color == nil then
		opts.color = WHITE
	end
	if opts.outline == nil then
		opts.outline = STROKE
	end
	if opts.outlineColor == nil then
		opts.outlineColor = OUTLINE
	end
	return Fit.text(parent, name, value, opts)
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

-- A dark slate slab: thick black keyline, faint rim, glossy ramp, rounded.
local function slab(parent: GuiObject, name: string, position: UDim2, size: UDim2, z: number, face: Color3?, radius: number?): Frame
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.Position = position
	frame.Size = size
	frame.BorderSizePixel = 0
	frame.ZIndex = z
	Depth.panel(frame, face or SLATE, { radius = radius or Tokens.radius.lg })
	frame.Parent = parent
	return frame
end

-- A small dark pill with a stroked label (levels, tags). Returns the pill and its label.
local function pill(
	parent: GuiObject,
	name: string,
	value: string,
	position: UDim2,
	size: UDim2,
	z: number,
	options: { fill: Color3?, line: Color3?, max: number?, anchor: Vector2? }?
): (Frame, TextLabel)
	local opts = (options or {}) :: any
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.AnchorPoint = opts.anchor or Vector2.new(0, 0)
	frame.Position = position
	frame.Size = size
	frame.BackgroundColor3 = opts.fill or DEEP
	frame.BorderSizePixel = 0
	frame.ZIndex = z
	Fit.corner(frame, 0.5)
	Depth.keyline(frame, Tokens.depth.keylineThin, opts.line)
	local label = text(frame, "Label", value, {
		font = Tokens.typography.label.font,
		max = opts.max or 16,
		min = 4,
		outline = 2,
		zIndex = z + 1,
		size = UDim2.fromScale(0.88, 0.76),
		position = UDim2.fromScale(0.5, 0.5),
		anchor = Vector2.new(0.5, 0.5),
	})
	frame.Parent = parent
	return frame, label
end

-- The section label at the top-left of a page ("PERKS", "GEMS", "PASSES").
local function section(page: GuiObject, name: string): TextLabel
	return text(page, "Section", name, {
		font = Tokens.typography.title.font,
		max = 30,
		zIndex = 3,
		size = UDim2.fromScale(0.5, 0.075),
		position = UDim2.fromScale(0.01, 0),
		align = Enum.TextXAlignment.Left,
	})
end

-- The gem cost line under a button's lettering: painted gem, then the number, white and stroked.
-- Returns the number label so render can restate the cost.
local function costRow(parent: GuiObject, amount: number, position: UDim2, size: UDim2, z: number): TextLabel
	local row = Fit.frame(parent, "Cost", position, size, z, Vector2.new(0.5, 0.5))
	local gem = Fit.image(row, "hud.gem", {
		size = UDim2.fromScale(0, 0.9),
		position = UDim2.fromScale(0.3, 0.5),
		zIndex = z,
		name = "Gem",
	})
	if gem then
		Fit.aspect(gem, 1, Enum.DominantAxis.Height)
	else
		local glyph = Icons.gem(row, 10, { zIndex = z })
		glyph.AnchorPoint = Vector2.new(0.5, 0.5)
		glyph.Position = UDim2.fromScale(0.3, 0.5)
		glyph.Size = UDim2.fromScale(0, 0.8)
		Fit.aspect(glyph, 1, Enum.DominantAxis.Height)
	end
	return text(row, "Amount", tostring(amount), {
		font = Tokens.typography.numeral.font,
		max = 24,
		min = 6,
		zIndex = z,
		size = UDim2.fromScale(0.56, 0.9),
		position = UDim2.fromScale(0.42, 0.05),
		align = Enum.TextXAlignment.Left,
	})
end

-- A green price button. With `gem` the lettering sits over a gem-cost row (returned as the second
-- value so the cost can be restated); without, the text is the Robux price itself.
local function priceButton(parent: GuiObject, name: string, label: string, options: any, gem: boolean): (any, TextLabel?)
	local handle = Button.build(parent, {
		text = label,
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
	local lettering = Fit.buttonText(handle, options.max or 28, 6)
	local cost: TextLabel? = nil
	if gem and lettering then
		lettering.Size = UDim2.fromScale(1, 0.6)
		local pad = lettering:FindFirstChildOfClass("UIPadding")
		if pad then
			pad.PaddingTop = UDim.new(0.08, 0)
			pad.PaddingBottom = UDim.new(0.02, 0)
		end
		local face = handle.button:FindFirstChild("Face")
		if face and face:IsA("Frame") then
			cost = costRow(face, options.cost or 0, UDim2.fromScale(0.5, 0.76), UDim2.fromScale(0.6, 0.36), face.ZIndex + 6)
		end
	end
	return handle, cost
end

-- OWNED: a gold tag in the price button's place.
local function ownedBadge(parent: GuiObject, position: UDim2, size: UDim2, anchor: Vector2?, z: number): Frame
	local badge = slab(parent, "Owned", position, size, z, Tokens.color.gold, Tokens.radius.md)
	badge.AnchorPoint = anchor or Vector2.new(0, 0)
	badge.Visible = false
	text(badge, "Label", "OWNED", {
		font = Tokens.typography.label.font,
		max = 24,
		zIndex = z + 1,
		size = UDim2.fromScale(0.9, 0.7),
		position = UDim2.fromScale(0.5, 0.5),
		anchor = Vector2.new(0.5, 0.5),
	})
	return badge
end

-- MAX: a dark tag with a red rim where the UPGRADE button was.
local function maxBadge(parent: GuiObject, position: UDim2, size: UDim2, z: number): Frame
	local badge = slab(parent, "Maxed", position, size, z, DEEP, Tokens.radius.md)
	badge.Visible = false
	local line = Depth.keylineOf(badge)
	if line then
		line.Color = Tokens.color.danger
	end
	text(badge, "Label", "MAX", {
		font = Tokens.typography.title.font,
		max = 26,
		zIndex = z + 1,
		size = UDim2.fromScale(0.9, 0.7),
		position = UDim2.fromScale(0.5, 0.5),
		anchor = Vector2.new(0.5, 0.5),
	})
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

	-- Tabs: dark slate pills, the active one green ---------------------------------------------
	local tabsRow = Fit.frame(root, "Tabs", UDim2.fromScale(0, 0), UDim2.fromScale(1, 0.105), 2)
	Fit.row(tabsRow, { gap = 0.015, halign = Enum.HorizontalAlignment.Left })
	type TabView = { name: string, button: TextButton, face: Frame, label: TextLabel, glyph: GuiObject? }
	local tabViews: { TabView } = {}
	local function buildTab(name: string, label: string, order: number, art: string?, glyphText: string?)
		local button = Instance.new("TextButton")
		button.Name = "Tab_" .. name
		button.Text = ""
		button.AutoButtonColor = false
		button.LayoutOrder = order
		button.Size = UDim2.fromScale(0.21, 1)
		button.BackgroundColor3 = DEEP
		button.BorderSizePixel = 0
		button.ZIndex = 2
		button.Selectable = true
		Fit.corner(button, 0.5)
		Depth.keyline(button)
		local minSize = Instance.new("UISizeConstraint")
		minSize.MinSize = Vector2.new(tap, tap)
		minSize.Parent = button
		relax(button)
		local face = Instance.new("Frame")
		face.Name = "Face"
		face.Size = UDim2.fromScale(1, 0.9)
		face.BackgroundColor3 = SLATE
		face.BorderSizePixel = 0
		face.ZIndex = 2
		Fit.corner(face, 0.5)
		Depth.applySheen(face, SLATE)
		Depth.rim(face, SLATE)
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
			glyph = text(face, "Glyph", glyphText or "•", {
				font = Tokens.typography.display.font,
				max = 30,
				zIndex = 4,
				size = UDim2.fromScale(0.18, 0.7),
				position = UDim2.fromScale(0.16, 0.5),
				anchor = Vector2.new(0.5, 0.5),
			})
		end
		local lettering = text(face, "Label", label, {
			font = Tokens.typography.title.font,
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
		table.insert(tabViews, { name = name, button = button, face = face, label = lettering, glyph = glyph })
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
	section(perksPage, "PERKS")
	type PerkRecord = {
		perkId: string,
		root: Frame,
		scale: UIScale,
		level: TextLabel,
		pips: { Frame },
		nextLine: TextLabel,
		buy: any,
		cost: TextLabel?,
		maxBadge: Frame,
		afterArt: GuiObject,
		displayedLevel: number?,
	}
	local perkCards: { PerkRecord } = {}
	-- Desktop: a 2x2 grid under the section label. Phone: one row of taller cards the player
	-- swipes through.
	local GRID_Y = 0.08
	local grid: GuiObject = perksPage
	local span = 0.48 * #Perks.IDS + 0.02
	if phone then
		local scroller = Instance.new("ScrollingFrame")
		scroller.Name = "Grid"
		scroller.BackgroundTransparency = 1
		scroller.BorderSizePixel = 0
		scroller.Position = UDim2.fromScale(0, GRID_Y)
		scroller.Size = UDim2.fromScale(1, 0.75)
		-- Canvas Scale is measured against the page, not the scroller, so it copies the height.
		scroller.CanvasSize = UDim2.fromScale(span, 0.73)
		scroller.ScrollingDirection = Enum.ScrollingDirection.X
		scroller.ScrollBarThickness = 4
		scroller.ScrollBarImageColor3 = MUTED
		scroller.ElasticBehavior = Enum.ElasticBehavior.Never
		scroller.ZIndex = 2
		scroller.Parent = perksPage
		grid = scroller
	end
	for index, perkId in ipairs(Perks.IDS) do
		local copy = COPY[perkId] or { title = perkId, icon = "star", art = "icon.egg", word = "" }
		local col = (index - 1) % 2
		local row = math.floor((index - 1) / 2)
		local card = slab(
			grid,
			"Perk_" .. perkId,
			if phone then UDim2.fromScale((index - 1) * 0.48 / span, 0.02) else UDim2.fromScale(col * 0.505, GRID_Y + row * 0.385),
			if phone then UDim2.fromScale(0.46 / span, 0.96) else UDim2.fromScale(0.495, 0.365),
			2
		)
		local scale = Instance.new("UIScale")
		scale.Parent = card
		local artPanel = slab(card, "ArtPanel", UDim2.fromScale(0.02, 0.045), UDim2.fromScale(0.42, 0.66), 3, WELL, Tokens.radius.md)
		artPanel.ClipsDescendants = true
		local artBox = Fit.frame(artPanel, "ArtBox", UDim2.fromScale(0.5, 0.5), UDim2.fromScale(0.74, 0.76), 3, Vector2.new(0.5, 0.5))
		itemArt(artBox, "perk." .. perkId, copy.art, copy.icon, 3)
		local nextLine = text(card, "Next", "NEXT: +10% " .. copy.word, {
			font = Tokens.typography.label.font,
			color = MUTED,
			max = 18,
			outline = 2,
			zIndex = 3,
			size = UDim2.fromScale(0.42, 0.2),
			position = UDim2.fromScale(0.02, 0.74),
			align = Enum.TextXAlignment.Left,
		})
		text(card, "Title", string.upper(copy.title), {
			font = Tokens.typography.title.font,
			max = 30,
			zIndex = 3,
			size = UDim2.fromScale(0.5, 0.17),
			position = UDim2.fromScale(0.47, 0.05),
			align = Enum.TextXAlignment.Left,
		})
		local _, level = pill(card, "Level", "LV 0", UDim2.fromScale(0.47, 0.25), UDim2.fromScale(0.16, 0.14), 3, { max = 16 })
		level.Name = "Text"
		local pipRow = Fit.frame(card, "Pips", UDim2.fromScale(0.47, 0.42), UDim2.fromScale(0.5, 0.09), 3)
		Fit.row(pipRow, { gap = 0.012, halign = Enum.HorizontalAlignment.Left })
		local pips: { Frame } = {}
		local maxLevel = cfg.permanentPerks[perkId].maxLevel
		for lv = 1, maxLevel do
			local dot = Instance.new("Frame")
			dot.Name = "Pip" .. lv
			dot.LayoutOrder = lv
			dot.Size = UDim2.fromScale(0, 0.8)
			dot.BackgroundColor3 = DEEP
			dot.BorderSizePixel = 0
			dot.ZIndex = 4
			Fit.aspect(dot, 1, Enum.DominantAxis.Height)
			Fit.corner(dot, 0.5)
			Depth.keyline(dot, 2)
			dot.Parent = pipRow
			table.insert(pips, dot)
		end
		local preview = slab(card, "Preview", UDim2.fromScale(0.47, 0.55), UDim2.fromScale(0.5, 0.17), 3, WELL, Tokens.radius.md)
		local beforeBox = Fit.frame(preview, "Before", UDim2.fromScale(0.28, 0.5), UDim2.fromScale(0, 0.62), 4, Vector2.new(0.5, 0.5))
		Fit.aspect(beforeBox, 1, Enum.DominantAxis.Height)
		itemArt(beforeBox, "perk." .. perkId, copy.art, copy.icon, 4)
		text(preview, "Arrow", "→", {
			font = Tokens.typography.display.font,
			color = Tokens.color.leafBright,
			max = 30,
			zIndex = 4,
			size = UDim2.fromScale(0.2, 0.8),
			position = UDim2.fromScale(0.5, 0.5),
			anchor = Vector2.new(0.5, 0.5),
		})
		local afterBox = Fit.frame(preview, "After", UDim2.fromScale(0.74, 0.5), UDim2.fromScale(0, 0.86), 4, Vector2.new(0.5, 0.5))
		Fit.aspect(afterBox, 1, Enum.DominantAxis.Height)
		local afterArt = itemArt(afterBox, "perk." .. perkId, copy.art, copy.icon, 4)
		local buy, cost = priceButton(card, "Buy", "UPGRADE", {
			tap = tap,
			motion = motion,
			audio = deps.audio,
			relax = relax,
			size = UDim2.fromScale(0.5, 0.22),
			position = UDim2.fromScale(0.47, 0.75),
			zIndex = 4,
			max = 26,
			cost = 0,
		}, true)
		table.insert(cleanups, buy.destroy)
		local maxed = maxBadge(card, UDim2.fromScale(0.47, 0.75), UDim2.fromScale(0.5, 0.22), 4)
		local record: PerkRecord = {
			perkId = perkId,
			root = card,
			scale = scale,
			level = level,
			pips = pips,
			nextLine = nextLine,
			buy = buy,
			cost = cost,
			maxBadge = maxed,
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
	local STRIP_Y = 0.85
	local STRIP_H = 0.15
	local passList = passes(cfg)
	type MiniView = { key: string, buy: any, owned: Frame }
	local passMinis: { MiniView } = {}
	local note = slab(perksPage, "Note", UDim2.fromScale(0.005, STRIP_Y), UDim2.fromScale(0.17, STRIP_H), 2, WELL, Tokens.radius.md)
	text(note, "Text", "PREMIUM UPGRADES\nLAST FOREVER!", {
		font = Tokens.typography.label.font,
		max = 18,
		outline = 2,
		zIndex = 3,
		size = UDim2.fromScale(0.9, 0.8),
		position = UDim2.fromScale(0.5, 0.5),
		anchor = Vector2.new(0.5, 0.5),
	})
	for index, pass in ipairs(passList) do
		local mini = slab(
			perksPage,
			"Mini_" .. pass.key,
			UDim2.fromScale(0.195 + (index - 1) * 0.225, STRIP_Y),
			UDim2.fromScale(0.215, STRIP_H),
			2,
			SLATE,
			Tokens.radius.md
		)
		local artBox = Fit.frame(mini, "ArtBox", UDim2.fromScale(0.15, 0.5), UDim2.fromScale(0, 0.74), 3, Vector2.new(0.5, 0.5))
		Fit.aspect(artBox, 1, Enum.DominantAxis.Height)
		itemArt(artBox, "pass." .. pass.key, pass.art, pass.icon, 3)
		text(mini, "Name", pass.name, {
			font = Tokens.typography.title.font,
			max = 18,
			zIndex = 3,
			size = UDim2.fromScale(0.34, 0.42),
			position = UDim2.fromScale(0.29, 0.1),
			align = Enum.TextXAlignment.Left,
		})
		text(mini, "Forever", "FOREVER", {
			font = Tokens.typography.caption.font,
			color = MUTED,
			max = 12,
			outline = 2,
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
		variant = "secondary",
		minimumTapTarget = tap,
		motion = motion,
		size = UDim2.fromScale(0.3, 0.13),
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
	viewForever.button.Position = UDim2.fromScale(0.995, STRIP_Y + STRIP_H / 2)
	relax(viewForever.button)
	Fit.buttonText(viewForever, 20)
	table.insert(cleanups, viewForever.destroy)

	-- GEMS -------------------------------------------------------------------------------------------
	local gemsPage = page("gems")
	section(gemsPage, "GEMS")
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
	local bundleWidth = 0.32
	local bundleGap = (1 - bundleWidth * #bundles) / math.max(1, #bundles - 1)
	for index, bundle in ipairs(bundles) do
		local best = index == bestIndex
		local card = slab(
			gemsPage,
			"Bundle_" .. tostring(bundle.gems),
			UDim2.fromScale((index - 1) * (bundleWidth + bundleGap), 0.09),
			UDim2.fromScale(bundleWidth, 0.73),
			2,
			GEM_CARD,
			Tokens.radius.xl
		)
		local line = Depth.keylineOf(card)
		if line and best then
			line.Color = Tokens.color.gold
			line.Thickness = KEYLINE + 1
		end
		text(card, "Title", withCommas(bundle.gems) .. " GEMS", {
			font = Tokens.typography.display.font,
			max = 44,
			outline = 3,
			zIndex = 3,
			size = UDim2.fromScale(0.9, 0.16),
			position = UDim2.fromScale(0.5, 0.12),
			anchor = Vector2.new(0.5, 0.5),
		})
		local artSize = 0.5 + index * 0.1
		local artBox =
			Fit.frame(card, "ArtBox", UDim2.fromScale(0.5, 0.5), UDim2.fromScale(artSize, artSize * 0.8), 3, Vector2.new(0.5, 0.5))
		itemArt(artBox, "bundle.gems" .. tostring(bundle.gems), "hud.gem", "gem", 3)
		if best then
			local badge =
				slab(card, "BestValue", UDim2.fromScale(0.8, 0.3), UDim2.fromScale(0.34, 0.17), 5, Tokens.color.gold, Tokens.radius.md)
			badge.AnchorPoint = Vector2.new(0.5, 0.5)
			badge.Rotation = 6
			text(badge, "Text", "BEST\nVALUE", {
				font = Tokens.typography.title.font,
				max = 18,
				outline = 2,
				zIndex = 6,
				size = UDim2.fromScale(0.9, 0.84),
				position = UDim2.fromScale(0.5, 0.5),
				anchor = Vector2.new(0.5, 0.5),
			})
		end
		if bundle.popular == true then
			pill(card, "Popular", "POPULAR", UDim2.fromScale(0.86, if best then 0.5 else 0.3), UDim2.fromScale(0.36, 0.11), 5, {
				anchor = Vector2.new(0.5, 0.5),
				line = Tokens.color.gold,
			})
		end
		local buy = priceButton(card, "Buy", "R$" .. tostring(bundle.robux), {
			tap = tap,
			motion = motion,
			audio = deps.audio,
			relax = relax,
			size = UDim2.fromScale(0.84, 0.17),
			position = UDim2.fromScale(0.5, 0.87),
			anchor = Vector2.new(0.5, 0.5),
			zIndex = 4,
			max = 34,
			onActivated = function()
				UpgradeActions.promptPurchase(promptDeps, "gemBundle" .. tostring(bundle.gems), withCommas(bundle.gems) .. " Gems")
			end,
		}, false)
		table.insert(cleanups, buy.destroy)
	end
	text(gemsPage, "Instant", "—  GEMS ARRIVE INSTANTLY  —", {
		font = Tokens.typography.label.font,
		color = MUTED,
		max = 20,
		outline = 2,
		zIndex = 3,
		size = UDim2.fromScale(0.7, 0.06),
		position = UDim2.fromScale(0.5, 0.86),
		anchor = Vector2.new(0.5, 0.5),
	})
	local banner = slab(gemsPage, "Banner", UDim2.fromScale(0.5, 0.945), UDim2.fromScale(0.96, 0.1), 3, SLATE, Tokens.radius.md)
	banner.AnchorPoint = Vector2.new(0.5, 0.5)
	local bannerGem = Fit.image(banner, "hud.gem", { size = UDim2.fromScale(0, 0.8), position = UDim2.fromScale(0.05, 0.5), zIndex = 4 })
	if bannerGem then
		Fit.aspect(bannerGem, 1, Enum.DominantAxis.Height)
	end
	text(banner, "Text", "USE GEMS FOR PERKS & CLASS SPINS", {
		font = Tokens.typography.title.font,
		max = 24,
		zIndex = 4,
		size = UDim2.fromScale(0.7, 0.7),
		position = UDim2.fromScale(0.5, 0.5),
		anchor = Vector2.new(0.5, 0.5),
	})
	local bannerFeather =
		Fit.image(banner, "icon.feather", { size = UDim2.fromScale(0, 0.8), position = UDim2.fromScale(0.95, 0.5), zIndex = 4 })
	if bannerFeather then
		Fit.aspect(bannerFeather, 1, Enum.DominantAxis.Height)
	end

	-- FOREVER ----------------------------------------------------------------------------------------
	local foreverPage = page("forever")
	section(foreverPage, "PASSES")
	type PassView = { key: string, buy: any, owned: Frame }
	local passCards: { PassView } = {}
	local passWidth = 0.36
	local passStart = (1 - (passWidth * #passList + 0.06 * math.max(0, #passList - 1))) / 2
	for index, pass in ipairs(passList) do
		local card = slab(
			foreverPage,
			"Pass_" .. pass.key,
			UDim2.fromScale(passStart + (index - 1) * (passWidth + 0.06), 0.09),
			UDim2.fromScale(passWidth, 0.88),
			2,
			PASS_FACES[math.min(index, #PASS_FACES)],
			Tokens.radius.xl
		)
		text(card, "Name", pass.name, {
			font = Tokens.typography.display.font,
			max = 42,
			outline = 3,
			zIndex = 3,
			size = UDim2.fromScale(0.9, 0.14),
			position = UDim2.fromScale(0.5, 0.1),
			anchor = Vector2.new(0.5, 0.5),
		})
		pill(card, "ForeverTag", "FOREVER", UDim2.fromScale(0.5, 0.21), UDim2.fromScale(0.36, 0.08), 3, { anchor = Vector2.new(0.5, 0.5) })
		local artBox = Fit.frame(card, "ArtBox", UDim2.fromScale(0.5, 0.5), UDim2.fromScale(0.5, 0.36), 3, Vector2.new(0.5, 0.5))
		itemArt(artBox, "pass." .. pass.key, pass.art, pass.icon, 3)
		text(card, "Blurb", pass.blurb, {
			font = Tokens.typography.body.font,
			max = 18,
			outline = 2,
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
			local face = if selected then Tokens.color.success else SLATE
			view.face.BackgroundColor3 = face
			Depth.applySheen(view.face, face, if selected then Tokens.color.leafBright else nil)
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
				dot.BackgroundColor3 = if lit then Tokens.color.success else DEEP
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
				if record.cost then
					record.cost.Text = tostring(preview.costGems or 0)
				else
					record.buy.setText(string.format("%d GEMS", preview.costGems or 0))
				end
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
