--!strict
-- Class Forge: a five-card reel under one fixed golden egg pointer (centre card largest, sides
-- readable), the equipped slots on the right, one SPIN button, AUTO and SKIP toggles, and the two
-- passes in the bottom corners. Every element is Scale relative to the shell's content frame,
-- so nothing crops, scrolls or overlaps at any size. The reveal screen covers the card with the
-- won class, its bonuses, EQUIP NOW / KEEP CURRENT. Odds, prices and slots come from config and
-- the profile; the roll, equip and purchases go through the same remotes as before.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local Depth = require(script.Parent.Parent.Components.Depth)
local ClassRoll = require(Shared.Domain.ClassRoll)
local Tween = require(script.Parent.Parent.Components.Tween)
local Button = require(script.Parent.Parent.Components.Button)
local Skin = require(script.Parent.Parent.Components.Skin)
local Icons = require(script.Parent.Parent.Components.Icons)
local Confetti = require(script.Parent.Parent.Components.Confetti)
local Fit = require(script.Parent.Parent.Components.Fit)
local GemChip = require(script.Parent.Parent.Components.GemChip)
local UpgradeActions = require(script.Parent.Parent.UpgradeActions)

local ClassesModal = {}

export type Deps = {
	net: any,
	profile: any,
	audio: any,
	haptics: any,
	accessibility: any,
	config: { [string]: any },
	minimumTapTarget: number,
	toasts: any,
	entitlements: () -> { [string]: boolean },
	quality: any?,
	openGemShop: (() -> ())?,
}

-- Art per class (falls back to the effect summary for unknown ids).
local CLASS_COPY: { [string]: { art: string, icon: string } } = {
	newcomer = { art = "icon.feather", icon = "feather" },
	nestCarrier = { art = "tool.hand.normal", icon = "star" },
	eggTrader = { art = "icon.egg", icon = "egg" },
	rakeExpert = { art = "tool.nestRake.normal", icon = "star" },
	blastArtist = { art = "tool.confettiCharge.normal", icon = "star" },
	gemSeeker = { art = "hud.gem", icon = "gem" },
	automationExpert = { art = "tool.scoutChick.normal", icon = "egg" },
	masterForager = { art = "station.classes.normal", icon = "star" },
}

local RARITY_LABEL = { common = "Common", uncommon = "Uncommon", rare = "Rare", epic = "Epic", legendary = "Legendary", mythic = "Mythic" }
-- Visual tier: the 0.1 % class gets its own band above legendary (rainbow border, shimmer, aura).
local MYTHIC_WEIGHT = 0.5
local RAINBOW = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 80, 80)),
	ColorSequenceKeypoint.new(0.17, Color3.fromRGB(255, 190, 60)),
	ColorSequenceKeypoint.new(0.34, Color3.fromRGB(120, 230, 90)),
	ColorSequenceKeypoint.new(0.5, Color3.fromRGB(80, 210, 255)),
	ColorSequenceKeypoint.new(0.67, Color3.fromRGB(140, 110, 255)),
	ColorSequenceKeypoint.new(0.84, Color3.fromRGB(255, 110, 220)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 80, 80)),
})
local MYTHIC_COLORS = { fill = Color3.fromRGB(120, 70, 170), deep = Color3.fromRGB(60, 30, 90) }

local function tierFor(entry: any): string
	if entry.weight < MYTHIC_WEIGHT then
		return "mythic"
	end
	return ClassRoll.rarity(entry.weight)
end

local function colorsFor(tier: string): { fill: Color3, deep: Color3 }
	if tier == "mythic" then
		return MYTHIC_COLORS
	end
	return (Tokens.rarity :: any)[tier]
end

local function percent(value: number): string
	local pct = math.floor(value * 100 * 100 + 0.5) / 100
	if pct == math.floor(pct) then
		return string.format("%d%%", pct)
	end
	return string.format("%.1f%%", pct)
end

-- Bonus chips for the reveal screen: one short title per effect, in a stable order.
local ORDER = {
	"bagCapacityMultiplier",
	"sellMultiplier",
	"rakeYieldMultiplier",
	"rakeUpgradeCostMultiplier",
	"blastRadiusMultiplier",
	"miniChargeChance",
	"gemFindChance",
	"diamondFeatherChance",
	"grantsScoutChick",
	"droneSpeedMultiplier",
	"droneCapacityMultiplier",
	"swarmChancePerTrip",
	"goldenRushChancePerMinute",
	"grantsAllPassiveBonuses",
}
local BONUS_TITLE: { [string]: { title: string, icon: string } } = {
	bagCapacityMultiplier = { title = "BAG CAPACITY", icon = "feather" },
	sellMultiplier = { title = "FEATHER VALUE", icon = "coin" },
	rakeYieldMultiplier = { title = "RAKE YIELD", icon = "star" },
	rakeUpgradeCostMultiplier = { title = "RAKE DISCOUNT", icon = "coin" },
	blastRadiusMultiplier = { title = "BLAST RADIUS", icon = "flame" },
	miniChargeChance = { title = "MINI CHARGES", icon = "flame" },
	gemFindChance = { title = "GEM FINDS", icon = "gem" },
	diamondFeatherChance = { title = "DIAMOND FEATHERS", icon = "gem" },
	grantsScoutChick = { title = "SCOUT CHICK", icon = "egg" },
	droneSpeedMultiplier = { title = "CHICK SPEED", icon = "egg" },
	droneCapacityMultiplier = { title = "CHICK CARRY", icon = "egg" },
	swarmChancePerTrip = { title = "HELPER SWARM", icon = "egg" },
	goldenRushChancePerMinute = { title = "GOLDEN RUSH", icon = "star" },
	grantsAllPassiveBonuses = { title = "EVERY BONUS", icon = "star" },
}
local function bonusChips(entry: any): { { title: string, icon: string } }
	local chips = {}
	local effect = entry.effect or {}
	for _, key in ipairs(ORDER) do
		local value = effect[key]
		if value ~= nil and value ~= false and BONUS_TITLE[key] then
			table.insert(chips, BONUS_TITLE[key])
			if #chips == 3 then
				break
			end
		end
	end
	return chips
end

local WOOD = Color3.fromRGB(150, 108, 60)
local WOOD_DEEP = Color3.fromRGB(96, 64, 34)
local WOOD_LIGHT = Color3.fromRGB(204, 158, 100)
local BARREL = Color3.fromRGB(92, 62, 34)
local BARREL_DEEP = Color3.fromRGB(58, 38, 22)
local PAPER = Color3.fromRGB(250, 241, 220)
local PARCHMENT = Color3.fromRGB(238, 224, 190)
local STRAW = Color3.fromRGB(232, 196, 96)
local CARD_ASPECT = 0.74

-- Reel geometry by distance from the centre slot (Scale of the reel): x offset and card height.
local REEL_OFFSET = { [0] = 0, 0.215, 0.39, 0.5 }
local REEL_HEIGHT = { [0] = 0.86, 0.71, 0.57, 0.46 }
local function reelAt(distance: number): (number, number)
	local d = math.clamp(distance, 0, 3)
	local lo = math.floor(d)
	local hi = math.min(lo + 1, 3)
	local t = d - lo
	local offset = REEL_OFFSET[lo] + (REEL_OFFSET[hi] - REEL_OFFSET[lo]) * t
	local height = REEL_HEIGHT[lo] + (REEL_HEIGHT[hi] - REEL_HEIGHT[lo]) * t
	return offset, height
end

local function wrapRel(value: number, count: number): number
	local rel = value % count
	if rel > count / 2 then
		rel -= count
	end
	return rel
end

-- Wood plank with paper lettering.
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

-- Painted class art if the owner supplied it, else the icon the class has always used.
local function classArt(parent: GuiObject, entry: any, z: number): GuiObject
	local copy = CLASS_COPY[entry.id] or { art = "icon.egg", icon = "egg" }
	local image = Fit.image(parent, "class.card." .. entry.id, { zIndex = z, name = "Art" })
		or Fit.image(parent, copy.art, { zIndex = z, name = "Art" })
	if image then
		return image
	end
	local glyph = Icons.build(copy.icon, parent, 10, { zIndex = z })
	glyph.Name = "Art"
	glyph.AnchorPoint = Vector2.new(0.5, 0.5)
	glyph.Position = UDim2.fromScale(0.5, 0.5)
	glyph.Size = UDim2.fromScale(1, 1)
	return glyph
end

type CardView = {
	root: Frame,
	scale: UIScale,
	face: Frame,
	odds: TextLabel,
	name: TextLabel,
	hit: TextButton,
	entry: any,
	tier: string,
	rainbow: UIGradient?,
}

-- One class card: rarity face with a sunburst, the pack's rarity rim (rainbow for mythic), art,
-- name, odds and the rarity pill. Sized by its parent; the caller sets Size (height-driven).
local function buildCard(parent: GuiObject, entry: any, tier: string, z: number): CardView
	local colors = colorsFor(tier)
	local root = Instance.new("Frame")
	root.Name = "Card_" .. entry.id
	root.AnchorPoint = Vector2.new(0.5, 0.5)
	root.BackgroundTransparency = 1
	root.ZIndex = z
	Fit.aspect(root, CARD_ASPECT, Enum.DominantAxis.Height)
	local scale = Instance.new("UIScale")
	scale.Parent = root

	local face = Instance.new("Frame")
	face.Name = "Face"
	face.Size = UDim2.fromScale(1, 1)
	face.BorderSizePixel = 0
	face.ZIndex = 1
	face.ClipsDescendants = true
	Depth.panel(face, colors.fill, { radius = Tokens.radius.md, rim = Color3.new(1, 1, 1) })
	Fit.corner(face, 0.07)
	face.Parent = root
	local burst = Skin.texture(face, "texture.sunburst", { transparency = 0.7, name = "Burst", zIndex = 2 })
	if burst then
		burst.AnchorPoint = Vector2.new(0.5, 0.5)
		burst.Position = UDim2.fromScale(0.5, 0.38)
		burst.Size = UDim2.fromScale(1.6, 1.1)
	end
	local foot = Instance.new("Frame")
	foot.Name = "Foot"
	foot.Position = UDim2.fromScale(0, 0.58)
	foot.Size = UDim2.fromScale(1, 0.42)
	foot.BackgroundColor3 = colors.deep
	foot.BackgroundTransparency = 0.35
	foot.BorderSizePixel = 0
	foot.ZIndex = 2
	local footFade = Instance.new("UIGradient")
	footFade.Rotation = 90
	footFade.Transparency =
		NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.4, 0), NumberSequenceKeypoint.new(1, 0) })
	footFade.Parent = foot
	foot.Parent = face

	local frameRole = "class." .. (if tier == "mythic" then "legendary" else tier) .. ".owned"
	local packFrame = Skin.overlay(root, frameRole, { zIndex = 4, name = "PackFrame", sliceScale = 0.5 })
	local rainbow: UIGradient? = nil
	if packFrame then
		if tier == "mythic" then
			local gradient = Instance.new("UIGradient")
			gradient.Color = RAINBOW
			gradient.Parent = packFrame
			rainbow = gradient
		end
	else
		local line = Depth.keyline(face, 3, colors.deep)
		if tier == "mythic" then
			local gradient = Instance.new("UIGradient")
			gradient.Color = RAINBOW
			gradient.Parent = line
			rainbow = gradient
		end
	end

	local artBox = Fit.frame(root, "ArtBox", UDim2.fromScale(0.5, 0.35), UDim2.fromScale(0.68, 0.44), 3, Vector2.new(0.5, 0.5))
	classArt(artBox, entry, 3)
	local name = Fit.text(root, "Name", string.upper(entry.displayName), {
		font = Tokens.typography.title.font,
		color = Tokens.color.featherWhite,
		max = 26,
		outline = 2,
		outlineColor = colors.deep,
		zIndex = 5,
		size = UDim2.fromScale(0.9, 0.12),
		position = UDim2.fromScale(0.5, 0.665),
		anchor = Vector2.new(0.5, 0.5),
	})
	local odds = Fit.text(root, "Odds", "0%", {
		font = Tokens.typography.display.font,
		color = Tokens.color.featherWhite,
		max = 26,
		outline = 2,
		outlineColor = colors.deep,
		zIndex = 5,
		size = UDim2.fromScale(0.8, 0.11),
		position = UDim2.fromScale(0.5, 0.775),
		anchor = Vector2.new(0.5, 0.5),
	})
	local pill = Instance.new("Frame")
	pill.Name = "Pill"
	pill.AnchorPoint = Vector2.new(0.5, 0.5)
	pill.Position = UDim2.fromScale(0.5, 0.9)
	pill.Size = UDim2.fromScale(0.72, 0.095)
	pill.BackgroundColor3 = colors.deep
	pill.BorderSizePixel = 0
	pill.ZIndex = 5
	Fit.corner(pill, 0.5)
	local pillLine = Depth.keyline(pill, 1.5, Color3.new(1, 1, 1))
	pillLine.Transparency = 0.6
	if tier == "mythic" then
		local gradient = Instance.new("UIGradient")
		gradient.Color = RAINBOW
		gradient.Parent = pill
	end
	Fit.text(pill, "Label", string.upper(RARITY_LABEL[tier] or tier), {
		font = Tokens.typography.label.font,
		color = Tokens.color.featherWhite,
		max = 16,
		zIndex = 6,
		size = UDim2.fromScale(0.9, 0.78),
		position = UDim2.fromScale(0.5, 0.5),
		anchor = Vector2.new(0.5, 0.5),
	})
	pill.Parent = root

	local hit = Instance.new("TextButton")
	hit.Name = "Hit"
	hit.Text = ""
	hit.BackgroundTransparency = 1
	hit.Size = UDim2.fromScale(1, 1)
	hit.ZIndex = 8
	hit.Selectable = true
	hit.Parent = root
	root.Parent = parent
	return { root = root, scale = scale, face = face, odds = odds, name = name, hit = hit, entry = entry, tier = tier, rainbow = rainbow }
end

function ClassesModal.build(container: ScrollingFrame, api: any, deps: Deps): () -> ()
	local cleanups: { any } = {}
	local cfg = deps.config
	local motion = deps.accessibility:motionSettings()
	local tap = deps.minimumTapTarget
	local tier = deps.quality and deps.quality:tier() or nil
	local shell = api.shell
	local weights = cfg.classes.weights
	local count = #weights
	local byId: { [string]: number } = {}
	for index, entry in ipairs(weights) do
		byId[entry.id] = index
	end
	local function entryFor(classId: string?): any?
		local index = classId and byId[classId]
		return if index then weights[index] else nil
	end
	local function entitlements(): { [string]: boolean }
		return deps.entitlements() or {}
	end

	-- The content frame is the one root: no scrolling, every child in Scale.
	container.AutomaticCanvasSize = Enum.AutomaticSize.None
	container.CanvasSize = UDim2.fromScale(0, 0)
	container.ScrollingEnabled = false
	container.ScrollBarThickness = 0
	local root = Fit.frame(container, "Forge", UDim2.fromScale(0, 0), UDim2.fromScale(1, 1), 1)

	local state = {
		center = 1, -- continuous reel position (1-based, wraps)
		selected = 1,
		slot = 1,
		rolling = false,
		auto = cfg.classes.autoRollDefault == true,
		skip = false,
		closed = false,
		lastReveal = nil :: string?,
	}
	local stats = { rolls = 0, autoRolls = 0, autoStops = 0, reveals = 0 }
	local render: () -> ()

	-- Header: the gem balance chip next to the close knob.
	local chip = GemChip.build(shell.headerRight, {
		count = (deps.profile.projection and deps.profile.projection.currencies.gems) or 0,
		zIndex = 1,
		minimumTapTarget = tap,
		sound = function()
			deps.audio:play(Tokens.sound.uiTap)
		end,
		onPlus = function()
			if deps.openGemShop then
				deps.openGemShop()
			end
		end,
	})
	chip.root.LayoutOrder = 1
	table.insert(cleanups, chip.destroy)

	-- Geometry (Scale of the content frame).
	local REEL_X, REEL_W = 0.035, 0.715
	local REEL_CX = REEL_X + REEL_W / 2
	local RIGHT_X = 0.785

	-- Top plank with the two captions and the golden egg pointer over the reel's centre.
	local top = plank(root, "TopPlank", UDim2.fromScale(REEL_X, 0.005), UDim2.fromScale(REEL_W, 0.085), 2)
	Fit.text(top, "CaptionLeft", "SPIN FOR A NEW CLASS!", {
		font = Tokens.typography.label.font,
		color = PAPER,
		max = 18,
		zIndex = 3,
		size = UDim2.fromScale(0.36, 0.6),
		position = UDim2.fromScale(0.06, 0.2),
		align = Enum.TextXAlignment.Left,
	})
	Fit.text(top, "CaptionRight", "EVERY FORAGER STARTS SOMEWHERE!", {
		font = Tokens.typography.label.font,
		color = PAPER,
		max = 18,
		zIndex = 3,
		size = UDim2.fromScale(0.4, 0.6),
		position = UDim2.fromScale(0.94, 0.2),
		anchor = Vector2.new(1, 0),
		align = Enum.TextXAlignment.Right,
	})
	Fit.image(top, "modal.leaf.left", { size = UDim2.fromScale(0.03, 0.7), position = UDim2.fromScale(0.03, 0.5), zIndex = 3 })
	Fit.image(top, "modal.leaf.right", { size = UDim2.fromScale(0.03, 0.7), position = UDim2.fromScale(0.97, 0.5), zIndex = 3 })
	local pointer = Fit.frame(root, "Pointer", UDim2.fromScale(REEL_CX, 0.0), UDim2.fromScale(0, 0.15), 9, Vector2.new(0.5, 0))
	Fit.aspect(pointer, 0.7, Enum.DominantAxis.Height)
	local pointerGlow = Instance.new("Frame")
	pointerGlow.Name = "Glow"
	pointerGlow.AnchorPoint = Vector2.new(0.5, 0.5)
	pointerGlow.Position = UDim2.fromScale(0.5, 0.36)
	pointerGlow.Size = UDim2.fromScale(1.5, 0.9)
	pointerGlow.BackgroundColor3 = Tokens.color.goldLight
	pointerGlow.BackgroundTransparency = 0.55
	pointerGlow.BorderSizePixel = 0
	pointerGlow.ZIndex = 1
	Fit.corner(pointerGlow, 0.5)
	pointerGlow.Parent = pointer
	local egg =
		Fit.image(pointer, "icon.egg", { size = UDim2.fromScale(1, 0.62), position = UDim2.fromScale(0.5, 0.33), zIndex = 2, name = "Egg" })
	if not egg then
		local glyph = Icons.egg(pointer, 10, { zIndex = 2, color = Tokens.color.gold })
		glyph.AnchorPoint = Vector2.new(0.5, 0.5)
		glyph.Position = UDim2.fromScale(0.5, 0.33)
		glyph.Size = UDim2.fromScale(1, 0.62)
	end
	local arrowDown = Fit.text(pointer, "Arrow", "▼", {
		font = Tokens.typography.display.font,
		color = Tokens.color.gold,
		max = 40,
		outline = 2,
		outlineColor = WOOD_DEEP,
		zIndex = 2,
		size = UDim2.fromScale(1, 0.34),
		position = UDim2.fromScale(0.5, 0.82),
		anchor = Vector2.new(0.5, 0.5),
	})

	-- Reel: a wooden barrel with a straw bed; the cards ride inside it.
	local reel = Instance.new("Frame")
	reel.Name = "Reel"
	reel.Position = UDim2.fromScale(REEL_X, 0.105)
	reel.Size = UDim2.fromScale(REEL_W, 0.56)
	reel.BorderSizePixel = 0
	reel.ZIndex = 3
	reel.ClipsDescendants = true
	Depth.panel(reel, BARREL, { radius = Tokens.radius.lg, rim = WOOD })
	Fit.corner(reel, 0.06)
	reel.Parent = root
	local barrelGradient = Instance.new("UIGradient")
	barrelGradient.Rotation = 0
	barrelGradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, BARREL_DEEP),
		ColorSequenceKeypoint.new(0.5, BARREL),
		ColorSequenceKeypoint.new(1, BARREL_DEEP),
	})
	local existingSheen = reel:FindFirstChildOfClass("UIGradient")
	if existingSheen then
		existingSheen:Destroy()
	end
	barrelGradient.Parent = reel
	for index = 1, 6 do
		local stave = Instance.new("Frame")
		stave.Name = "Stave" .. index
		stave.Position = UDim2.fromScale(index / 7, 0)
		stave.Size = UDim2.fromScale(0.004, 1)
		stave.BackgroundColor3 = BARREL_DEEP
		stave.BackgroundTransparency = 0.5
		stave.BorderSizePixel = 0
		stave.ZIndex = 1
		stave.Parent = reel
	end
	local straw = Instance.new("Frame")
	straw.Name = "Straw"
	straw.Position = UDim2.fromScale(0, 0.86)
	straw.Size = UDim2.fromScale(1, 0.14)
	straw.BackgroundColor3 = STRAW
	straw.BackgroundTransparency = 0.25
	straw.BorderSizePixel = 0
	straw.ZIndex = 1
	local strawFade = Instance.new("UIGradient")
	strawFade.Rotation = 90
	strawFade.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(1, 0.1) })
	strawFade.Parent = straw
	straw.Parent = reel
	local glow = Instance.new("Frame")
	glow.Name = "Glow"
	glow.AnchorPoint = Vector2.new(0.5, 0.5)
	glow.Position = UDim2.fromScale(0.5, 0.5)
	glow.Size = UDim2.fromScale(0.3, 1.0)
	glow.BackgroundColor3 = Tokens.color.goldLight
	glow.BackgroundTransparency = 0.6
	glow.BorderSizePixel = 0
	glow.ZIndex = 2
	local glowGradient = Instance.new("UIGradient")
	glowGradient.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.5, 0),
		NumberSequenceKeypoint.new(1, 1),
	})
	glowGradient.Parent = glow
	glow.Parent = reel

	-- Cards: one per class, positioned by distance from the reel centre.
	local cards: { CardView } = {}
	local animated: { { gradient: UIGradient, speed: number } } = {}
	for _, entry in ipairs(weights) do
		local view = buildCard(reel, entry, tierFor(entry), 5)
		table.insert(cards, view)
		if view.rainbow then
			table.insert(animated, { gradient = view.rainbow, speed = 90 })
		end
	end

	local function layoutReel()
		for index, view in ipairs(cards) do
			local rel = wrapRel(index - state.center, count)
			local distance = math.abs(rel)
			local offset, height = reelAt(distance)
			local visible = distance < 2.75
			view.root.Visible = visible
			if visible then
				view.root.Position = UDim2.fromScale(0.5 + (if rel < 0 then -offset else offset), 0.5)
				view.root.Size = UDim2.fromScale(0, height)
				view.root.ZIndex = 8 - math.floor(distance + 0.5)
				view.hit.Selectable = distance < 2.5
			end
		end
	end

	-- Arrows straddle the reel's edges.
	local function arrow(name: string, x: number, glyph: string, step: number): TextButton
		local button = Instance.new("TextButton")
		button.Name = name
		button.Text = ""
		button.AutoButtonColor = false
		button.AnchorPoint = Vector2.new(0.5, 0.5)
		button.Position = UDim2.fromScale(x, 0.385)
		button.Size = UDim2.fromScale(0, 0.1)
		button.BackgroundColor3 = WOOD_DEEP
		button.BorderSizePixel = 0
		button.ZIndex = 6
		button.Selectable = true
		Fit.aspect(button, 1, Enum.DominantAxis.Height)
		local minSize = Instance.new("UISizeConstraint")
		minSize.MinSize = Vector2.new(tap, tap)
		minSize.Parent = button
		Fit.corner(button, 0.5)
		Depth.keyline(button)
		local face = Instance.new("Frame")
		face.Name = "Face"
		face.Size = UDim2.fromScale(1, 0.9)
		face.BackgroundColor3 = WOOD_LIGHT
		face.BorderSizePixel = 0
		face.ZIndex = 2
		Fit.corner(face, 0.5)
		Depth.applySheen(face, WOOD_LIGHT)
		Depth.rim(face, WOOD_LIGHT)
		face.Parent = button
		Fit.text(face, "Glyph", glyph, {
			font = Tokens.typography.display.font,
			color = WOOD_DEEP,
			max = 34,
			zIndex = 3,
			size = UDim2.fromScale(0.7, 0.7),
			position = UDim2.fromScale(0.5, 0.5),
			anchor = Vector2.new(0.5, 0.5),
		})
		button.Parent = root
		table.insert(
			cleanups,
			button.Activated:Connect(function()
				if state.rolling then
					return
				end
				deps.audio:play(Tokens.sound.uiTab)
				local target = ((state.selected - 1 + step) % count) + 1
				local rel = wrapRel(target - state.center, count)
				state.selected = target
				TweenService:Create(button, TweenInfo.new(0.08), { Rotation = step * 6 }):Play()
				task.delay(0.09, function()
					TweenService:Create(button, TweenInfo.new(0.16, Enum.EasingStyle.Back), { Rotation = 0 }):Play()
				end)
				local from = state.center
				local started = os.clock()
				local seconds = 0.28
				local conn: RBXScriptConnection
				conn = RunService.RenderStepped:Connect(function()
					local t = math.min(1, (os.clock() - started) / seconds)
					local eased = 1 - (1 - t) * (1 - t)
					state.center = from + rel * eased
					layoutReel()
					if t >= 1 then
						state.center = target
						layoutReel()
						conn:Disconnect()
					end
				end)
			end)
		)
		return button
	end
	arrow("ArrowLeft", REEL_X, "<", -1)
	arrow("ArrowRight", REEL_X + REEL_W, ">", 1)

	local function selectClass(index: number)
		if state.rolling then
			return
		end
		local target = ((index - 1) % count) + 1
		local rel = wrapRel(target - state.center, count)
		state.selected = target
		local from = state.center
		local started = os.clock()
		local seconds = if math.abs(rel) < 0.01 then 0 else 0.3
		if seconds == 0 then
			state.center = target
			layoutReel()
			return
		end
		local conn: RBXScriptConnection
		conn = RunService.RenderStepped:Connect(function()
			local t = math.min(1, (os.clock() - started) / seconds)
			local eased = 1 - (1 - t) * (1 - t)
			state.center = from + rel * eased
			layoutReel()
			if t >= 1 then
				state.center = target
				layoutReel()
				conn:Disconnect()
			end
		end)
	end
	for index, view in ipairs(cards) do
		table.insert(
			cleanups,
			view.hit.Activated:Connect(function()
				deps.audio:play(Tokens.sound.uiTab)
				selectClass(index)
			end)
		)
		table.insert(
			cleanups,
			view.hit.MouseEnter:Connect(function()
				if not state.rolling then
					deps.audio:play(Tokens.sound.uiHover)
					Tween.scale(view.scale, "hover", motion, 1.04)
				end
			end)
		)
		table.insert(
			cleanups,
			view.hit.MouseLeave:Connect(function()
				Tween.scale(view.scale, "release", motion, 1)
			end)
		)
	end

	-- Equipped column ----------------------------------------------------------------------------
	local right = Fit.frame(root, "Equipped", UDim2.fromScale(RIGHT_X, 0.005), UDim2.fromScale(1 - RIGHT_X, 0.79), 3)
	local rightHead = plank(right, "Head", UDim2.fromScale(0, 0), UDim2.fromScale(1, 0.105), 2)
	Fit.text(rightHead, "Title", "EQUIPPED CLASSES", {
		font = Tokens.typography.label.font,
		color = PAPER,
		max = 20,
		zIndex = 3,
		outline = 1.5,
		outlineColor = WOOD_DEEP,
		size = UDim2.fromScale(0.9, 0.62),
		position = UDim2.fromScale(0.5, 0.5),
		anchor = Vector2.new(0.5, 0.5),
	})
	local rightBody = Instance.new("Frame")
	rightBody.Name = "Body"
	rightBody.Position = UDim2.fromScale(0, 0.12)
	rightBody.Size = UDim2.fromScale(1, 0.88)
	rightBody.BorderSizePixel = 0
	rightBody.ZIndex = 2
	Depth.panel(rightBody, PARCHMENT, { radius = Tokens.radius.md, rim = Color3.new(1, 1, 1) })
	Fit.corner(rightBody, 0.06)
	local rightLine = Depth.keylineOf(rightBody)
	if rightLine then
		rightLine.Color = WOOD
		rightLine.Thickness = 2
	end
	rightBody.Parent = right

	type SlotView = {
		index: number,
		frame: Frame,
		artBox: Frame,
		name: TextLabel,
		pill: Frame,
		pillText: TextLabel,
		lock: Frame,
		empty: TextLabel,
		buy: any,
		hit: TextButton,
		line: UIStroke,
		art: GuiObject?,
	}
	local slotViews: { SlotView } = {}
	local maximumSlots = cfg.classes.maximumSlots or 2
	for index = 1, maximumSlots do
		local slotTop = 0.03 + (index - 1) * (0.94 / maximumSlots)
		local slotHeight = 0.94 / maximumSlots - 0.03
		Fit.text(rightBody, "SlotLabel" .. index, "SLOT " .. index, {
			font = Tokens.typography.label.font,
			color = WOOD_DEEP,
			max = 16,
			zIndex = 3,
			size = UDim2.fromScale(0.9, slotHeight * 0.14),
			position = UDim2.fromScale(0.5, slotTop),
			anchor = Vector2.new(0.5, 0),
		})
		local frame = Instance.new("Frame")
		frame.Name = "Slot" .. index
		frame.Position = UDim2.fromScale(0.08, slotTop + slotHeight * 0.16)
		frame.Size = UDim2.fromScale(0.84, slotHeight * 0.82)
		frame.BorderSizePixel = 0
		frame.ZIndex = 3
		Depth.panel(frame, PAPER, { radius = Tokens.radius.md, rim = Color3.new(1, 1, 1) })
		Fit.corner(frame, 0.08)
		local line = Depth.keylineOf(frame) or Depth.keyline(frame)
		line.Color = WOOD
		line.Thickness = 2
		frame.Parent = rightBody
		local artBox = Fit.frame(frame, "ArtBox", UDim2.fromScale(0.5, 0.3), UDim2.fromScale(0.5, 0.4), 4, Vector2.new(0.5, 0.5))
		local name = Fit.text(frame, "Name", "", {
			font = Tokens.typography.title.font,
			color = Tokens.color.inkStrong,
			max = 20,
			zIndex = 4,
			size = UDim2.fromScale(0.9, 0.16),
			position = UDim2.fromScale(0.5, 0.62),
			anchor = Vector2.new(0.5, 0.5),
		})
		local pill = Instance.new("Frame")
		pill.Name = "Pill"
		pill.AnchorPoint = Vector2.new(0.5, 0.5)
		pill.Position = UDim2.fromScale(0.5, 0.82)
		pill.Size = UDim2.fromScale(0.7, 0.16)
		pill.BackgroundColor3 = Tokens.color.sky
		pill.BorderSizePixel = 0
		pill.ZIndex = 4
		Fit.corner(pill, 0.5)
		local pillText = Fit.text(pill, "Label", "COMMON", {
			font = Tokens.typography.label.font,
			color = Tokens.color.featherWhite,
			max = 14,
			zIndex = 5,
			size = UDim2.fromScale(0.9, 0.78),
			position = UDim2.fromScale(0.5, 0.5),
			anchor = Vector2.new(0.5, 0.5),
		})
		pill.Parent = frame
		local lock = Icons.lock(frame, 10, { zIndex = 4, color = WOOD })
		lock.AnchorPoint = Vector2.new(0.5, 0.5)
		lock.Position = UDim2.fromScale(0.5, 0.32)
		lock.Size = UDim2.fromScale(0, 0.36)
		Fit.aspect(lock, 1, Enum.DominantAxis.Height)
		local empty = Fit.text(frame, "Empty", "EMPTY", {
			font = Tokens.typography.label.font,
			color = WOOD,
			max = 16,
			zIndex = 4,
			size = UDim2.fromScale(0.9, 0.16),
			position = UDim2.fromScale(0.5, 0.64),
			anchor = Vector2.new(0.5, 0.5),
		})
		local buy = Button.build(frame, {
			text = "+1 SLOT\nR$" .. tostring(cfg.classes.products.extraSlotRobux),
			variant = "primary",
			minimumTapTarget = tap,
			motion = motion,
			size = UDim2.fromScale(0.86, 0.36),
			zIndex = 5,
			sound = function()
				deps.audio:play(Tokens.sound.uiTap)
			end,
			onActivated = function()
				UpgradeActions.promptPurchase(
					{ net = deps.net, audio = deps.audio, toasts = deps.toasts },
					"extraClassSlot",
					"Extra Class Slot"
				)
			end,
		})
		buy.button.AnchorPoint = Vector2.new(0.5, 1)
		buy.button.Position = UDim2.fromScale(0.5, 0.95)
		Fit.buttonText(buy, 20)
		table.insert(cleanups, buy.destroy)
		local hit = Instance.new("TextButton")
		hit.Name = "Hit"
		hit.Text = ""
		hit.BackgroundTransparency = 1
		hit.Size = UDim2.fromScale(1, 0.56)
		hit.ZIndex = 6
		hit.Parent = frame
		table.insert(slotViews, {
			index = index,
			frame = frame,
			artBox = artBox,
			name = name,
			pill = pill,
			pillText = pillText,
			lock = lock,
			empty = empty,
			buy = buy,
			hit = hit,
			line = line,
			art = nil,
		})
	end
	local slotLocked: { [number]: boolean } = {}
	for _, view in ipairs(slotViews) do
		table.insert(
			cleanups,
			view.hit.Activated:Connect(function()
				if slotLocked[view.index] then
					UpgradeActions.promptPurchase(
						{ net = deps.net, audio = deps.audio, toasts = deps.toasts },
						"extraClassSlot",
						"Extra Class Slot"
					)
					return
				end
				deps.audio:play(Tokens.sound.uiTab)
				state.slot = view.index
				local projection = deps.profile.projection
				local equipped = projection and projection.classes.equipped[view.index]
				local at = byId[equipped or ""]
				if at then
					selectClass(at)
				end
				render()
			end)
		)
	end

	-- Spin button, toggles and the two passes ----------------------------------------------------
	local rollHandle = Button.build(root, {
		text = string.format("SPIN  -  %d GEMS", cfg.classes.rollGemCost),
		variant = "primary",
		minimumTapTarget = tap,
		motion = motion,
		size = UDim2.fromScale(0.44, 0.125),
		zIndex = 4,
		sound = function()
			deps.audio:play(Tokens.sound.uiConfirm)
		end,
	})
	rollHandle.button.Name = "RollButton"
	rollHandle.button.AnchorPoint = Vector2.new(0.5, 0.5)
	rollHandle.button.Position = UDim2.fromScale(REEL_CX, 0.745)
	local rollLabel = Fit.buttonText(rollHandle, 40)
	if rollLabel then
		local pad = rollLabel:FindFirstChildOfClass("UIPadding")
		if pad then
			pad.PaddingLeft = UDim.new(0.16, 0)
			pad.PaddingRight = UDim.new(0.04, 0)
		end
	end
	local rollFace = rollHandle.button:FindFirstChild("Face")
	if rollFace then
		local gemIcon = Fit.image(
			rollFace,
			"hud.gem",
			{ size = UDim2.fromScale(0, 0.74), position = UDim2.fromScale(0.1, 0.5), zIndex = 6, name = "Gem" }
		)
		if gemIcon then
			Fit.aspect(gemIcon, 1, Enum.DominantAxis.Height)
		end
	end
	table.insert(cleanups, rollHandle.destroy)
	rollHandle.pulse(true)

	local toggles = Fit.frame(root, "Toggles", UDim2.fromScale(REEL_CX, 0.875), UDim2.fromScale(0.42, 0.085), 4, Vector2.new(0.5, 0.5))
	Fit.row(toggles, { gap = 0.04 })
	local function toggle(name: string, text: string, order: number): (any, Frame)
		local handle = Button.build(toggles, {
			text = text,
			variant = "pill",
			minimumTapTarget = tap,
			motion = motion,
			size = UDim2.fromScale(0.46, 1),
			zIndex = 4,
			sound = function()
				deps.audio:play(Tokens.sound.uiSwitch)
			end,
		})
		handle.button.Name = name
		handle.button.LayoutOrder = order
		local label = Fit.buttonText(handle, 20)
		if label then
			local pad = label:FindFirstChildOfClass("UIPadding")
			if pad then
				pad.PaddingLeft = UDim.new(0.22, 0)
				pad.PaddingRight = UDim.new(0.06, 0)
			end
		end
		local dot = Instance.new("Frame")
		dot.Name = "Dot"
		dot.AnchorPoint = Vector2.new(0.5, 0.5)
		dot.Position = UDim2.fromScale(0.13, 0.5)
		dot.Size = UDim2.fromScale(0, 0.5)
		dot.BackgroundColor3 = PARCHMENT
		dot.BorderSizePixel = 0
		dot.ZIndex = 6
		Fit.aspect(dot, 1, Enum.DominantAxis.Height)
		Fit.corner(dot, 0.5)
		Depth.keyline(dot, 1.5, WOOD_DEEP)
		local face = handle.button:FindFirstChild("Face")
		dot.Parent = face or handle.button
		table.insert(cleanups, handle.destroy)
		return handle, dot
	end
	local autoHandle, autoDot = toggle("AutoButton", "AUTO: OFF", 1)
	local skipHandle, skipDot = toggle("SkipButton", "SKIP: OFF", 2)
	local function paintToggles()
		autoHandle.setText(if state.auto then "AUTO: ON" else "AUTO: OFF")
		autoHandle.setSelected(state.auto)
		autoDot.BackgroundColor3 = if state.auto then Tokens.color.leafBright else PARCHMENT
		skipHandle.setText(if state.skip then "SKIP: ON" else "SKIP: OFF")
		skipHandle.setSelected(state.skip)
		skipDot.BackgroundColor3 = if state.skip then Tokens.color.leafBright else PARCHMENT
	end

	local passHandles: { [string]: any } = {}
	local function passButton(name: string, passKey: string, label: string, priceKey: string, variant: string, x: number, icon: string)
		local handle = Button.build(root, {
			text = string.format("%s\nR$%d", label, cfg.classes.products[priceKey]),
			variant = variant :: any,
			minimumTapTarget = tap,
			motion = motion,
			size = UDim2.fromScale(0.19, 0.12),
			zIndex = 4,
			sound = function()
				deps.audio:play(Tokens.sound.uiTap)
			end,
			hoverSound = function()
				deps.audio:play(Tokens.sound.uiHover)
			end,
			onActivated = function()
				UpgradeActions.promptPurchase({ net = deps.net, audio = deps.audio, toasts = deps.toasts }, passKey, label)
			end,
		})
		handle.button.Name = name
		handle.button.AnchorPoint = Vector2.new(0.5, 0.5)
		handle.button.Position = UDim2.fromScale(x, 0.9)
		local text = Fit.buttonText(handle, 22)
		if text then
			local pad = text:FindFirstChildOfClass("UIPadding")
			if pad then
				pad.PaddingLeft = UDim.new(0.3, 0)
				pad.PaddingRight = UDim.new(0.04, 0)
			end
		end
		local face = handle.button:FindFirstChild("Face")
		if face then
			local glyph = Icons.build(icon, face, 10, { zIndex = 6, color = Tokens.color.featherWhite })
			glyph.AnchorPoint = Vector2.new(0.5, 0.5)
			glyph.Position = UDim2.fromScale(0.16, 0.5)
			glyph.Size = UDim2.fromScale(0, 0.6)
			Fit.aspect(glyph, 1, Enum.DominantAxis.Height)
		end
		table.insert(cleanups, handle.destroy)
		passHandles[passKey] = { handle = handle, label = label, priceKey = priceKey }
	end
	passButton("LuckPass", "doubleLuck", "2× LUCK", "doubleLuckRobux", "success", 0.13, "star")
	passButton("FastPass", "fastRolls", "FAST ROLLS", "fastRollsRobux", "teal", 0.87, "flame")

	-- Rendering ------------------------------------------------------------------------------------
	render = function()
		local projection = deps.profile.projection
		if not projection then
			return
		end
		local ent = entitlements()
		chip.setCount(projection.currencies.gems or 0)
		local odds = ClassRoll.odds(cfg, ent.doubleLuck == true)
		for index, view in ipairs(cards) do
			local record = odds[index]
			if record then
				view.odds.Text = string.format("%.1f%%", record.percent)
			end
		end
		local slotCount = ClassRoll.slotCount(cfg, ent)
		for _, view in ipairs(slotViews) do
			local locked = view.index > slotCount
			slotLocked[view.index] = locked
			local classId = projection.classes.equipped[view.index]
			local entry = if not locked then entryFor(classId) else nil
			view.lock.Visible = locked
			view.buy.button.Visible = locked
			view.empty.Visible = not locked and entry == nil
			view.name.Visible = entry ~= nil
			view.pill.Visible = entry ~= nil
			view.artBox.Visible = entry ~= nil
			if entry then
				if view.art == nil or view.art:GetAttribute("SFE_ClassId") ~= entry.id then
					if view.art then
						view.art:Destroy()
					end
					local art = classArt(view.artBox, entry, 4)
					art:SetAttribute("SFE_ClassId", entry.id)
					view.art = art
				end
				local entryTier = tierFor(entry)
				view.name.Text = string.upper(entry.displayName)
				view.pillText.Text = string.upper(RARITY_LABEL[entryTier] or entryTier)
				view.pill.BackgroundColor3 = colorsFor(entryTier).fill
			end
			local active = view.index == state.slot and not locked
			view.line.Color = if active then Tokens.color.gold else WOOD
			view.line.Thickness = if active then 3.5 else 2
		end
		for passKey, record in pairs(passHandles) do
			local owned = ent[passKey] == true
			record.handle.setText(
				if owned then record.label .. "\nOWNED" else string.format("%s\nR$%d", record.label, cfg.classes.products[record.priceKey])
			)
			record.handle.setEnabled(not owned)
		end
		local canRoll = not state.rolling and (projection.currencies.gems or 0) >= cfg.classes.rollGemCost
		rollHandle.setEnabled(canRoll or state.rolling)
		paintToggles()
	end

	-- Reveal screen --------------------------------------------------------------------------------
	local currentResult: { finish: () -> (), keep: () -> () }? = nil
	local function showResult(result: any, previousClassId: string?, onDone: () -> ()): () -> ()
		local entry = entryFor(result.classId)
			or { id = result.classId, displayName = result.displayName or result.classId, weight = 1, effect = {} }
		local entryTier = tierFor(entry)
		local colors = colorsFor(entryTier)
		local overlay = Instance.new("Frame")
		overlay.Name = "Result"
		overlay.Size = UDim2.fromScale(1, 1)
		overlay.BackgroundColor3 = Color3.fromRGB(40, 26, 14)
		overlay.BackgroundTransparency = 0.25
		overlay.BorderSizePixel = 0
		overlay.ZIndex = 5
		Fit.corner(overlay, 0.03)
		overlay.Parent = shell.card
		shell.plaque.Visible = false
		local rays = Skin.texture(overlay, "texture.rays", { transparency = 0.6, name = "Rays", zIndex = 1 })
		if rays then
			rays.AnchorPoint = Vector2.new(0.5, 0.5)
			rays.Position = UDim2.fromScale(0.5, 0.5)
			rays.Size = UDim2.fromScale(1.4, 1.4)
			rays.ImageColor3 = if entryTier == "mythic" then Color3.fromRGB(255, 220, 255) else Tokens.color.goldLight
		end
		local burst = Skin.texture(overlay, "texture.sunburst", { transparency = 0.5, name = "Burst", zIndex = 1 })
		if burst then
			burst.AnchorPoint = Vector2.new(0.5, 0.5)
			burst.Position = UDim2.fromScale(0.5, 0.5)
			burst.Size = UDim2.fromScale(0.9, 1.4)
			burst.ImageColor3 = Tokens.color.goldLight
		end
		local aura = Instance.new("Frame")
		aura.Name = "Aura"
		aura.AnchorPoint = Vector2.new(0.5, 0.5)
		aura.Position = UDim2.fromScale(0.5, 0.5)
		aura.Size = UDim2.fromScale(0.4, 0.62)
		aura.BackgroundColor3 = if entryTier == "mythic" then Color3.fromRGB(255, 230, 255) else Tokens.color.goldLight
		aura.BackgroundTransparency = 0.5
		aura.BorderSizePixel = 0
		aura.ZIndex = 2
		Fit.corner(aura, 0.5)
		local auraFade = Instance.new("UIGradient")
		auraFade.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.5, 0),
			NumberSequenceKeypoint.new(1, 1),
		})
		auraFade.Parent = aura
		aura.Parent = overlay

		-- Title and the class sub-plate.
		local title = Fit.text(overlay, "Title", string.upper(RARITY_LABEL[entryTier] or entryTier) .. " CLASS!", {
			font = Tokens.typography.display.font,
			color = Tokens.color.goldLight,
			max = 76,
			outline = 3,
			outlineColor = WOOD_DEEP,
			zIndex = 4,
			size = UDim2.fromScale(0.7, 0.14),
			position = UDim2.fromScale(0.5, 0.085),
			anchor = Vector2.new(0.5, 0.5),
		})
		local titleGradient = Instance.new("UIGradient")
		if entryTier == "mythic" then
			titleGradient.Color = RAINBOW
		else
			titleGradient.Rotation = 90
			titleGradient.Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 246, 210)),
				ColorSequenceKeypoint.new(1, colors.fill:Lerp(Tokens.color.goldLight, 0.5)),
			})
		end
		titleGradient.Parent = title
		local sub = plank(overlay, "Sub", UDim2.fromScale(0.5, 0.185), UDim2.fromScale(0.36, 0.07), 4)
		sub.AnchorPoint = Vector2.new(0.5, 0.5)
		Fit.text(
			sub,
			"Text",
			string.format("%s  -  %s", string.upper(entry.displayName), percent(result.percent or (entry.weight / 100))),
			{
				font = Tokens.typography.title.font,
				color = PAPER,
				max = 26,
				zIndex = 5,
				size = UDim2.fromScale(0.8, 0.7),
				position = UDim2.fromScale(0.5, 0.5),
				anchor = Vector2.new(0.5, 0.5),
			}
		)
		Fit.image(sub, "modal.leaf.left", { size = UDim2.fromScale(0.07, 0.7), position = UDim2.fromScale(0.05, 0.5), zIndex = 5 })
		Fit.image(sub, "modal.leaf.right", { size = UDim2.fromScale(0.07, 0.7), position = UDim2.fromScale(0.95, 0.5), zIndex = 5 })

		-- Cracked golden egg behind the card: two halves of the egg art, tilted apart.
		local function half(name: string, x: number, rotation: number, left: boolean)
			local clip = Fit.frame(overlay, name, UDim2.fromScale(x, 0.56), UDim2.fromScale(0, 0.34), 3, Vector2.new(0.5, 0.5))
			Fit.aspect(clip, 0.5, Enum.DominantAxis.Height)
			clip.ClipsDescendants = true
			clip.Rotation = rotation
			local image = Fit.image(clip, "icon.egg", {
				size = UDim2.fromScale(2, 1),
				position = UDim2.fromScale(if left then 1 else 0, 0.5),
				anchor = Vector2.new(0.5, 0.5),
				zIndex = 3,
				name = "Egg",
			})
			if not image then
				local glyph = Icons.egg(clip, 10, { zIndex = 3, color = Tokens.color.gold })
				glyph.AnchorPoint = Vector2.new(0.5, 0.5)
				glyph.Position = UDim2.fromScale(if left then 1 else 0, 0.5)
				glyph.Size = UDim2.fromScale(2, 1)
			end
		end
		half("ShellLeft", 0.355, -14, true)
		half("ShellRight", 0.645, 14, false)
		-- Sparkles around the card.
		local sparkles: { Frame } = {}
		for index, spot in ipairs({ { 0.3, 0.3 }, { 0.7, 0.28 }, { 0.27, 0.66 }, { 0.73, 0.68 }, { 0.36, 0.2 }, { 0.65, 0.76 } }) do
			local star = Icons.star(overlay, 10, { zIndex = 4, color = Tokens.color.goldLight })
			star.Name = "Sparkle" .. index
			star.AnchorPoint = Vector2.new(0.5, 0.5)
			star.Position = UDim2.fromScale(spot[1], spot[2])
			star.Size = UDim2.fromScale(0, 0.05 + (index % 3) * 0.012)
			Fit.aspect(star, 1, Enum.DominantAxis.Height)
			table.insert(sparkles, star)
		end

		-- The won card.
		local holder = Fit.frame(overlay, "CardHolder", UDim2.fromScale(0.5, 0.5), UDim2.fromScale(0, 0.5), 5, Vector2.new(0.5, 0.5))
		Fit.aspect(holder, CARD_ASPECT, Enum.DominantAxis.Height)
		local card = buildCard(holder, entry, entryTier, 1)
		card.root.Position = UDim2.fromScale(0.5, 0.5)
		card.root.Size = UDim2.fromScale(0, 1)
		card.odds.Text = percent(result.percent or (entry.weight / 100))
		card.hit:Destroy()
		card.scale.Scale = 0.2
		Tween.scale(card.scale, "release", motion, 1)
		if card.rainbow then
			table.insert(animated, { gradient = card.rainbow, speed = 90 })
		end

		-- Bonus chips.
		local chips = bonusChips(entry)
		local chipRow = Fit.frame(overlay, "Bonuses", UDim2.fromScale(0.5, 0.815), UDim2.fromScale(0.8, 0.095), 5, Vector2.new(0.5, 0.5))
		Fit.row(chipRow, { gap = 0.02 })
		local shown: { { title: string, icon: string } } = if #chips == 0 then { { title = "STARTING CLASS", icon = "feather" } } else chips
		for index, bonus in ipairs(shown) do
			local bonusChip = plank(chipRow, "Bonus" .. index, UDim2.fromScale(0, 0), UDim2.fromScale(0.3, 1), 5)
			bonusChip.LayoutOrder = index
			local glyph = Icons.build(bonus.icon, bonusChip, 10, { zIndex = 6, color = Tokens.color.goldLight })
			glyph.AnchorPoint = Vector2.new(0.5, 0.5)
			glyph.Position = UDim2.fromScale(0.13, 0.5)
			glyph.Size = UDim2.fromScale(0, 0.62)
			Fit.aspect(glyph, 1, Enum.DominantAxis.Height)
			Fit.text(bonusChip, "Title", bonus.title, {
				font = Tokens.typography.label.font,
				color = PAPER,
				max = 20,
				zIndex = 6,
				size = UDim2.fromScale(0.7, 0.42),
				position = UDim2.fromScale(0.26, 0.1),
				align = Enum.TextXAlignment.Left,
			})
			Fit.text(bonusChip, "Applied", if #chips == 0 then "NO BONUSES" else "BONUS APPLIED", {
				font = Tokens.typography.caption.font,
				color = Tokens.color.goldLight,
				max = 14,
				zIndex = 6,
				size = UDim2.fromScale(0.7, 0.32),
				position = UDim2.fromScale(0.26, 0.56),
				align = Enum.TextXAlignment.Left,
			})
		end

		-- Actions.
		local done = false
		local function finish()
			if done then
				return
			end
			done = true
			currentResult = nil
			shell.plaque.Visible = true
			TweenService:Create(overlay, TweenInfo.new(0.2), { BackgroundTransparency = 1 }):Play()
			task.delay(0.2, function()
				overlay:Destroy()
			end)
			onDone()
		end
		local previousEntry = entryFor(previousClassId)
		local canKeep = previousEntry ~= nil and previousClassId ~= result.classId
		local function keepCurrent()
			if canKeep and previousEntry then
				local back = deps.net:request("ClassEquip", { classId = previousEntry.id, slot = result.slot })
				if not back.ok then
					deps.toasts:push("Could not restore " .. previousEntry.displayName, "warning")
				end
			end
			finish()
		end
		currentResult = { finish = finish, keep = keepCurrent }
		local actions = Fit.frame(overlay, "Actions", UDim2.fromScale(0.5, 0.925), UDim2.fromScale(0.62, 0.1), 5, Vector2.new(0.5, 0.5))
		Fit.row(actions, { gap = 0.03 })
		local equipNow = Button.build(actions, {
			text = "EQUIP NOW",
			variant = "ember",
			minimumTapTarget = tap,
			motion = motion,
			size = UDim2.fromScale(0.52, 1),
			zIndex = 6,
			sound = function()
				deps.audio:play(Tokens.sound.uiConfirm)
			end,
			onActivated = function()
				-- The roll already placed this class in the slot; keeping it is the whole action.
				deps.haptics:pulse(0.3, 0.06)
				finish()
			end,
		})
		equipNow.button.LayoutOrder = 1
		Fit.buttonText(equipNow, 40)
		equipNow.pulse(true)
		local keep = Button.build(actions, {
			text = "KEEP CURRENT",
			variant = "secondary",
			minimumTapTarget = tap,
			motion = motion,
			size = UDim2.fromScale(0.36, 0.86),
			zIndex = 6,
			sound = function()
				deps.audio:play(Tokens.sound.uiTap)
			end,
			onActivated = keepCurrent,
		})
		keep.button.LayoutOrder = 2
		keep.button.Visible = canKeep
		Fit.buttonText(keep, 24)
		local tag = Fit.text(overlay, "Unlocked", if result.duplicate then "ALREADY OWNED - EQUIPPED" else "NEW CLASS UNLOCKED!", {
			font = Tokens.typography.label.font,
			color = if result.duplicate then PARCHMENT else Tokens.color.leafBright,
			max = 20,
			outline = 1.5,
			outlineColor = WOOD_DEEP,
			zIndex = 6,
			size = UDim2.fromScale(0.22, 0.05),
			position = UDim2.fromScale(0.985, 0.975),
			anchor = Vector2.new(1, 1),
			align = Enum.TextXAlignment.Right,
		})
		tag.Rotation = -4
		api.setInitialFocus(equipNow.button)
		Confetti.burst(overlay, {
			origin = UDim2.fromScale(0.5, 0.45),
			count = if entryTier == "mythic" then 60 elseif entryTier == "legendary" then 44 else 28,
			spread = 260,
			motion = motion,
			tier = tier,
			zIndex = 7,
		})
		if not motion.reducedMotion then
			local conn = RunService.RenderStepped:Connect(function(dt)
				local now = os.clock()
				if burst and burst.Parent then
					burst.Rotation = (burst.Rotation + dt * 14) % 360
				end
				if aura.Parent then
					aura.BackgroundTransparency = 0.5 + 0.12 * math.sin(now * 3)
				end
				for index, star in ipairs(sparkles) do
					star.Rotation = (star.Rotation + dt * 40 * (if index % 2 == 0 then 1 else -1)) % 360
				end
			end)
			table.insert(cleanups, conn)
			overlay.Destroying:Connect(function()
				conn:Disconnect()
			end)
		end
		table.insert(cleanups, function()
			if not done then
				done = true
				shell.plaque.Visible = true
				if overlay.Parent then
					overlay:Destroy()
				end
			end
		end)
		return finish
	end

	-- Spin: the reel runs, slows onto the committed class, then the reveal screen opens ----------
	local function reveal(result: any, previousClassId: string?, onLanded: () -> ())
		local seconds = result.animationSeconds or cfg.lobby.classRollAnimationSeconds
		local scaled = if state.skip then 0.15 else seconds * deps.accessibility:motionScale()
		local landingIndex = byId[result.classId] or state.selected
		local turns = if state.skip then 0 elseif scaled < 1.2 then 1 else 2
		local from = state.center
		local rel = wrapRel(landingIndex - from, count)
		local distance = rel + turns * count
		local started = os.clock()
		local lastTick = math.floor(from)
		local conn: RBXScriptConnection
		conn = RunService.RenderStepped:Connect(function()
			if state.closed then
				conn:Disconnect()
				return
			end
			local t = math.min(1, (os.clock() - started) / math.max(scaled, 0.05))
			local eased = 1 - (1 - t) * (1 - t) * (1 - t)
			state.center = from + distance * eased
			layoutReel()
			local tick = math.floor(state.center)
			if tick ~= lastTick then
				lastTick = tick
				deps.audio:play(Tokens.sound.uiTap, { pitchVariance = 0.08 })
			end
			if t >= 1 then
				conn:Disconnect()
				state.center = landingIndex
				state.selected = landingIndex
				layoutReel()
				local landing = cards[landingIndex]
				if landing then
					landing.scale.Scale = 1.12
					Tween.scale(landing.scale, "release", motion, 1)
				end
				deps.audio:play(Tokens.sound.uiConfetti)
				deps.audio:play(Tokens.sound.rollLand)
				deps.haptics:pulse(0.8, 0.12)
				stats.reveals += 1
				state.lastReveal = result.classId
				deps.toasts:push(
					if result.duplicate then result.displayName .. " (duplicate) equipped" else "Unlocked " .. result.displayName,
					"success"
				)
				task.delay(if state.skip then 0.05 else 0.35, function()
					if state.closed then
						return
					end
					local finish = showResult(result, previousClassId, function()
						render()
						onLanded()
					end)
					if state.auto then
						task.delay(1.4, function()
							if state.auto and not state.closed then
								finish()
							end
						end)
					end
				end)
			end
		end)
	end

	local function stopAuto(reason: string?)
		if state.auto then
			state.auto = false
			stats.autoStops += 1
			paintToggles()
			if reason then
				deps.toasts:push(reason, "info")
			end
		end
	end

	local function rollOnce(auto: boolean)
		if state.rolling or state.closed then
			return
		end
		local projection = deps.profile.projection
		if not projection or projection.currencies.gems < cfg.classes.rollGemCost then
			deps.audio:play(Tokens.sound.uiError)
			deps.toasts:push("Not enough Gems for a spin", "warning")
			stopAuto(if auto then "Auto stopped: out of Gems" else nil)
			return
		end
		local previousClassId = projection.classes.equipped[state.slot]
		state.rolling = true
		render()
		rollHandle.setPending(true, "SPINNING...")
		local result = deps.net:request("ClassRoll", { slot = state.slot })
		if not result.ok then
			state.rolling = false
			rollHandle.setPending(false)
			render()
			deps.audio:play(Tokens.sound.uiError)
			local message = if result.code == "insufficient_funds"
				then "Not enough Gems for a spin"
				elseif result.code == "rate_limited" then "Spinning too fast"
				elseif result.message == "not_in_lobby" then "Spins happen between searches"
				else "Spin unavailable"
			deps.toasts:push(message, "warning")
			stopAuto(if auto then "Auto stopped" else nil)
			return
		end
		stats.rolls += 1
		if auto then
			stats.autoRolls += 1
		end
		deps.audio:play(Tokens.sound.rollSpin)
		reveal(result.data, previousClassId, function()
			state.rolling = false
			rollHandle.setPending(false)
			render()
			if state.auto and not state.closed then
				task.delay(cfg.lobby.classRollMinIntervalSeconds, function()
					if state.auto and not state.closed then
						rollOnce(true)
					end
				end)
			end
		end)
	end
	table.insert(
		cleanups,
		rollHandle.button.Activated:Connect(function()
			rollOnce(false)
		end)
	)
	table.insert(
		cleanups,
		autoHandle.button.Activated:Connect(function()
			if state.auto then
				stopAuto("Auto stopped")
			else
				state.auto = true
				paintToggles()
				rollOnce(true)
			end
		end)
	)
	table.insert(
		cleanups,
		skipHandle.button.Activated:Connect(function()
			state.skip = not state.skip
			paintToggles()
		end)
	)
	api.setInitialFocus(rollHandle.button)

	-- Start on the equipped class when there is one.
	do
		local projection = deps.profile.projection
		local equipped = projection and projection.classes.equipped[1]
		state.selected = byId[equipped or ""] or 1
		state.center = state.selected
	end
	layoutReel()
	render()
	-- Motion: rainbow rims turn, the glow breathes, the egg bobs.
	table.insert(
		cleanups,
		RunService.RenderStepped:Connect(function(dt)
			local now = os.clock()
			for _, entry in ipairs(animated) do
				entry.gradient.Rotation = (entry.gradient.Rotation + dt * entry.speed) % 360
			end
			if not motion.reducedMotion then
				glow.BackgroundTransparency = 0.55 + 0.15 * math.sin(now * 2.4)
				pointer.Position = UDim2.fromScale(REEL_CX, 0.0 + math.sin(now * 3) * 0.006)
				pointerGlow.BackgroundTransparency = 0.5 + 0.2 * math.sin(now * 2)
				arrowDown.TextTransparency = 0.1 + 0.1 * math.sin(now * 4)
			end
		end)
	)
	table.insert(
		cleanups,
		deps.profile.changed:Connect(function()
			if not state.rolling then
				render()
			end
		end)
	)
	deps.audio:play(Tokens.sound.uiOpen)
	if api.registerDebug then
		api.registerDebug({
			roll = function()
				rollOnce(false)
				return { rolling = state.rolling }
			end,
			auto = function()
				if state.auto then
					stopAuto("Auto stopped")
				else
					state.auto = true
					paintToggles()
					rollOnce(true)
				end
				return { auto = state.auto }
			end,
			skip = function()
				state.skip = not state.skip
				paintToggles()
				return { skip = state.skip }
			end,
			stop = function()
				stopAuto("Auto stopped")
				return { auto = state.auto, stops = stats.autoStops }
			end,
			select = function(index: number)
				selectClass(index)
				return { selected = state.selected }
			end,
			slot = function(index: number)
				state.slot = math.clamp(index, 1, maximumSlots)
				render()
				return { slot = state.slot }
			end,
			-- The result screen's two buttons, for the probe.
			dismiss = function()
				if currentResult then
					currentResult.finish()
				end
				return { open = currentResult ~= nil }
			end,
			keep = function()
				if currentResult then
					currentResult.keep()
				end
				return { open = currentResult ~= nil }
			end,
			state = function()
				return {
					selected = state.selected,
					slot = state.slot,
					rolling = state.rolling,
					auto = state.auto,
					skip = state.skip,
					stats = stats,
				}
			end,
		})
	end
	container:SetAttribute("SFE_ClassesRolling", false)
	local attrThread = task.spawn(function()
		while not state.closed do
			container:SetAttribute("SFE_ClassesRolling", state.rolling)
			container:SetAttribute("SFE_ClassesAuto", state.auto)
			container:SetAttribute("SFE_ClassesSkip", state.skip)
			container:SetAttribute("SFE_ClassesReveals", stats.reveals)
			container:SetAttribute("SFE_ClassesLastReveal", state.lastReveal or "")
			task.wait(0.1)
		end
	end)

	return function()
		state.closed = true
		state.auto = false
		if coroutine.status(attrThread) ~= "dead" then
			task.cancel(attrThread)
		end
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

return ClassesModal
