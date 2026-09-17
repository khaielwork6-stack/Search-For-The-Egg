--!strict
-- Class Forge, drawn to the owner's reference clip (17 Sep 2026): the shell's charcoal card holds a
-- dark slate reel well with a thick black keyline, a five-card fan of dark slate class cards under
-- one golden egg pointer (the chosen card largest, gold-edged and lit, the neighbours smaller and
-- tilted behind it), an EQUIPPED column on the right, one big green SPIN CLASS button with its gem
-- cost, a row of dark pills (Luck / Fast Rolls / Auto / Skip) that turn green when on, and a CLASS
-- INFO pill that slides a drawer in over the reel with every obtainable class, its odds and its exact
-- bonuses read from config. Every element is Scale relative to the shell's content frame and every
-- label carries a black stroke. Odds, prices and slots come from config and the profile; the roll,
-- equip and purchases go through the same remotes as before.

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
local FrameKit = require(script.Parent.Parent.Components.Frame)
local GemChip = require(script.Parent.Parent.Components.GemChip)
local UpgradeActions = require(script.Parent.Parent.UpgradeActions)
local SafeArea = require(script.Parent.Parent.SafeArea)

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

-- Fallback art per class when the painted card is missing.
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
-- Rarity headers to the reference clip: grey for common, then green, blue, purple, orange, and
-- gold for the top band (whose edge also carries the rainbow). Every value is a token.
local RARITY_BAND: { [string]: { fill: Color3, deep: Color3 } } = {
	common = { fill = Tokens.color.cocoa, deep = Tokens.color.panelDeep },
	uncommon = { fill = Tokens.color.leaf, deep = Tokens.color.leafDeep },
	rare = { fill = Tokens.color.sky, deep = Tokens.color.skyDeep },
	epic = { fill = Tokens.color.gem, deep = Tokens.color.gemDeep },
	legendary = { fill = Tokens.rarity.legendary.fill, deep = Tokens.rarity.legendary.deep },
	mythic = { fill = Tokens.color.gold, deep = Tokens.color.goldDeep },
}

local function tierFor(entry: any): string
	if entry.weight < MYTHIC_WEIGHT then
		return "mythic"
	end
	return ClassRoll.rarity(entry.weight)
end

local function colorsFor(tier: string): { fill: Color3, deep: Color3 }
	return RARITY_BAND[tier] or RARITY_BAND.common
end

local function percent(value: number): string
	local pct = math.floor(value * 100 * 100 + 0.5) / 100
	if pct == math.floor(pct) then
		return string.format("%d%%", pct)
	end
	return string.format("%.1f%%", pct)
end

-- Exact bonus lines per effect key, in a stable order, read straight from the class config.
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
local function lineFor(key: string, value: any, effect: { [string]: any }): string?
	if key == "bagCapacityMultiplier" then
		return string.format("+%s bag capacity", percent(value - 1))
	elseif key == "sellMultiplier" then
		return string.format("Feathers sell for +%s", percent(value - 1))
	elseif key == "rakeYieldMultiplier" then
		return string.format("+%s feathers per rake sweep", percent(value - 1))
	elseif key == "rakeUpgradeCostMultiplier" then
		return string.format("Rake upgrades cost %s less", percent(1 - value))
	elseif key == "blastRadiusMultiplier" then
		return string.format("+%s blast radius", percent(value - 1))
	elseif key == "miniChargeChance" then
		return string.format("%s chance a blast spawns %d mini-charges", percent(value), effect.miniChargeCount or 0)
	elseif key == "gemFindChance" then
		return string.format("%s chance a feather drops Gems", percent(value))
	elseif key == "diamondFeatherChance" then
		return string.format("%s chance of a diamond feather", percent(value))
	elseif key == "grantsScoutChick" and value == true then
		return "Free Scout Chick every search"
	elseif key == "droneSpeedMultiplier" then
		return string.format("Chick moves +%s faster", percent(value - 1))
	elseif key == "droneCapacityMultiplier" then
		return string.format("Chick carries +%s more", percent(value - 1))
	elseif key == "swarmChancePerTrip" then
		return string.format("%s chance per trip of %d helper chicks", percent(value), effect.swarmCount or 0)
	elseif key == "goldenRushChancePerMinute" then
		return string.format("%s chance each minute of a %ds Golden Rush", percent(value), effect.goldenRushSeconds or 0)
	end
	return nil
end

-- Every bonus a class grants. "Every passive bonus" expands to the passive bonuses of every other
-- class so the 0.1 % card lists everything it grants.
local function effectLines(entry: any, weights: { any }): { string }
	local lines = {}
	local effect = entry.effect or {}
	for _, key in ipairs(ORDER) do
		local value = effect[key]
		if value ~= nil then
			local line = lineFor(key, value, effect)
			if line then
				table.insert(lines, line)
			end
		end
	end
	if effect.grantsAllPassiveBonuses == true then
		local seen = {}
		for _, other in ipairs(weights) do
			if other.id ~= entry.id then
				for _, key in ipairs(ORDER) do
					local value = (other.effect or {})[key]
					if value ~= nil and not seen[key] then
						local line = lineFor(key, value, other.effect or {})
						if line then
							seen[key] = true
							table.insert(lines, line)
						end
					end
				end
			end
		end
	end
	return lines
end

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
	if #chips < 3 and effect.grantsAllPassiveBonuses == true then
		table.insert(chips, BONUS_TITLE.grantsAllPassiveBonuses)
	end
	return chips
end

-- Palette: the shell's dark kit, every surface a token. Slate for cards and rows, a deeper slate
-- for the reel well and the column, the near-black keyline around everything, white lettering.
local SLATE = Tokens.color.surface
local WELL = Tokens.color.surfaceAlt
local DEEP = Tokens.color.panelDeep
local OUTLINE = Tokens.color.outline
local WHITE = Tokens.color.featherWhite
local MUTED = Tokens.color.inkMuted
local KEYLINE = Tokens.depth.keyline
local STROKE = 2.6 -- the black stroke on every label
local CARD_ASPECT = 0.74

-- Reel geometry by distance from the centre slot (Scale of the reel): x offset, card height, tilt
-- and drop. Neighbours sit slightly behind the chosen card, like cards fanned on a shelf.
local REEL_OFFSET = { [0] = 0, 0.255, 0.43, 0.5 }
local REEL_HEIGHT = { [0] = 0.9, 0.66, 0.44, 0.34 }
local REEL_TILT = { [0] = 0, 5, 9, 12 }
local REEL_DROP = { [0] = 0, 0.035, 0.06, 0.08 }
local function reelAt(distance: number): (number, number, number, number)
	local d = math.clamp(distance, 0, 3)
	local lo = math.floor(d)
	local hi = math.min(lo + 1, 3)
	local t = d - lo
	local function mix(list: { [number]: number }): number
		return list[lo] + (list[hi] - list[lo]) * t
	end
	return mix(REEL_OFFSET), mix(REEL_HEIGHT), mix(REEL_TILT), mix(REEL_DROP)
end

local function wrapRel(value: number, count: number): number
	local rel = value % count
	if rel > count / 2 then
		rel -= count
	end
	return rel
end

-- Accelerate, pass the pointer, decelerate, snap.
local function spinEase(t: number): number
	if t < 0.5 then
		return 4 * t * t * t
	end
	local u = -2 * t + 2
	return 1 - (u * u * u) / 2
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

-- A small dark pill with a stroked label (odds, rarity, captions). Returns the pill and its label.
local function pill(
	parent: GuiObject,
	name: string,
	value: string,
	position: UDim2,
	size: UDim2,
	z: number,
	options: { fill: Color3?, line: Color3?, max: number?, color: Color3?, anchor: Vector2? }?
): (Frame, TextLabel)
	local opts = (options or {}) :: any
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.AnchorPoint = opts.anchor or Vector2.new(0.5, 0.5)
	frame.Position = position
	frame.Size = size
	frame.BackgroundColor3 = opts.fill or DEEP
	frame.BorderSizePixel = 0
	frame.ZIndex = z
	Fit.corner(frame, 0.5)
	Depth.keyline(frame, Tokens.depth.keylineThin, opts.line)
	local label = text(frame, "Label", value, {
		font = Tokens.typography.label.font,
		color = opts.color,
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

-- A rarity-coloured header band across the top of a card: rounded at the top, square where it
-- meets the body. Returns the band.
local function headerBand(parent: GuiObject, height: number, fill: Color3, z: number, radius: number): Frame
	local band = Instance.new("Frame")
	band.Name = "Header"
	band.Size = UDim2.fromScale(1, height)
	band.BackgroundColor3 = fill
	band.BorderSizePixel = 0
	band.ZIndex = z
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius)
	corner.Parent = band
	-- Flat, like the reference's headers: a sheen split across the band and its patch would seam.
	local patch = Instance.new("Frame")
	patch.Name = "Patch"
	patch.Position = UDim2.fromScale(0, 0.5)
	patch.Size = UDim2.fromScale(1, 0.5)
	patch.BackgroundColor3 = fill
	patch.BorderSizePixel = 0
	patch.ZIndex = z
	patch.Parent = band
	band.Parent = parent
	return band
end

-- The gem cost line under a button's lettering: painted gem, then the number, white and stroked.
-- Returns the number label so a caller can restate the cost.
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
		max = 26,
		min = 6,
		zIndex = z,
		size = UDim2.fromScale(0.56, 0.9),
		position = UDim2.fromScale(0.42, 0.05),
		align = Enum.TextXAlignment.Left,
	})
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
	edge: UIStroke,
	sheen: UIGradient,
	entry: any,
	tier: string,
	rainbow: UIGradient?,
}

-- One class card: dark slate with a thick black keyline (gold when chosen, rainbow for mythic), a
-- rarity-coloured header carrying the name and the odds in a small dark pill, the painted art, and
-- a rarity pill at the foot. Sized by its parent (height-driven).
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
	Depth.panel(face, SLATE, { radius = Tokens.radius.md })
	face.Parent = root
	local edge = Depth.keylineOf(face) or Depth.keyline(face)
	edge.Thickness = KEYLINE
	edge.Transparency = 0
	headerBand(face, 0.25, colors.fill, 2, Tokens.radius.md)
	-- Shimmer: a light band that sweeps the face now and then.
	local shine = Instance.new("Frame")
	shine.Name = "Shine"
	shine.Size = UDim2.fromScale(1, 1)
	shine.BackgroundColor3 = WHITE
	shine.BackgroundTransparency = 0.75
	shine.BorderSizePixel = 0
	shine.ZIndex = 3
	local sheen = Instance.new("UIGradient")
	sheen.Rotation = 25
	sheen.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.45, 1),
		NumberSequenceKeypoint.new(0.5, 0.2),
		NumberSequenceKeypoint.new(0.55, 1),
		NumberSequenceKeypoint.new(1, 1),
	})
	sheen.Offset = Vector2.new(-1, 0)
	sheen.Parent = shine
	shine.Parent = face

	-- The face keyline is the card's edge: black, gold when chosen, the rainbow for mythic (a
	-- gradient multiplies the stroke colour, so that edge stays white underneath).
	local rainbow: UIGradient? = nil
	if tier == "mythic" then
		edge.Color = WHITE
		local gradient = Instance.new("UIGradient")
		gradient.Color = RAINBOW
		gradient.Parent = edge
		rainbow = gradient
	end

	local name = text(root, "Name", string.upper(entry.displayName), {
		font = Tokens.typography.title.font,
		max = 24,
		min = 4,
		outline = 2,
		zIndex = 5,
		size = UDim2.fromScale(0.9, 0.11),
		position = UDim2.fromScale(0.5, 0.075),
		anchor = Vector2.new(0.5, 0.5),
	})
	local _, odds = pill(root, "OddsPill", "0%", UDim2.fromScale(0.5, 0.185), UDim2.fromScale(0.5, 0.085), 5, { max = 18 })
	odds.Name = "Odds"
	local artBox = Fit.frame(root, "ArtBox", UDim2.fromScale(0.5, 0.55), UDim2.fromScale(0.76, 0.46), 3, Vector2.new(0.5, 0.5))
	classArt(artBox, entry, 3)
	local rarity = pill(
		root,
		"Pill",
		string.upper(RARITY_LABEL[tier] or tier),
		UDim2.fromScale(0.5, 0.9),
		UDim2.fromScale(0.72, 0.095),
		5,
		{ line = if tier == "mythic" then WHITE else colors.fill }
	)
	if tier == "mythic" then
		local line = Depth.keylineOf(rarity)
		if line then
			local gradient = Instance.new("UIGradient")
			gradient.Color = RAINBOW
			gradient.Parent = line
		end
	end

	local hit = Instance.new("TextButton")
	hit.Name = "Hit"
	hit.Text = ""
	hit.BackgroundTransparency = 1
	hit.Size = UDim2.fromScale(1, 1)
	hit.ZIndex = 8
	hit.Selectable = true
	hit.Parent = root
	root.Parent = parent
	return {
		root = root,
		scale = scale,
		face = face,
		odds = odds,
		name = name,
		hit = hit,
		edge = edge,
		sheen = sheen,
		entry = entry,
		tier = tier,
		rainbow = rainbow,
	}
end

function ClassesModal.build(container: ScrollingFrame, api: any, deps: Deps): () -> ()
	local cleanups: { any } = {}
	local cfg = deps.config
	local motion = deps.accessibility:motionSettings()
	local tap = deps.minimumTapTarget
	local tier = deps.quality and deps.quality:tier() or nil
	local shell = api.shell
	local phone = SafeArea.classOf(container) == "phone"
	-- Phones give the rows their Scale height; the 44 px floor would stack them over each other.
	local function relax(button: GuiObject)
		if phone then
			local constraint = button:FindFirstChildOfClass("UISizeConstraint")
			if constraint then
				constraint.MinSize = Vector2.new(0, 0)
			end
		end
	end
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

	-- The content frame is the one root: no scrolling, every child in Scale. The shell's charcoal
	-- card is the machine's body; nothing here recolours it.
	container.AutomaticCanvasSize = Enum.AutomaticSize.None
	container.CanvasSize = UDim2.fromScale(0, 0)
	container.ScrollingEnabled = false
	container.ScrollBarThickness = 0
	container.Position = UDim2.fromScale(0.012, 0.02)
	container.Size = UDim2.fromScale(0.976, 0.96)

	local root = Fit.frame(container, "Forge", UDim2.fromScale(0, 0), UDim2.fromScale(1, 1), 1)

	local state = {
		center = 1, -- continuous reel position (1-based, wraps)
		selected = 1,
		slot = 1,
		rolling = false,
		auto = cfg.classes.autoRollDefault == true,
		skip = false,
		closed = false,
		infoOpen = false,
		infoSelected = 1,
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
	local REEL_X, REEL_W = 0.045, 0.69
	local REEL_CX = REEL_X + REEL_W / 2
	local REEL_Y = 0.115
	local REEL_H = if phone then 0.55 else 0.585
	local RIGHT_X = 0.775
	local SPIN_Y = if phone then 0.795 else 0.805
	local SPIN_H = 0.15
	local TOGGLE_Y = 0.93
	local TOGGLE_H = if phone then 0.1 else 0.085

	-- Captions either side of the golden egg pointer over the reel's centre.
	text(root, "CaptionLeft", "SPIN FOR A NEW CLASS!", {
		font = Tokens.typography.label.font,
		max = 20,
		zIndex = 3,
		size = UDim2.fromScale(0.28, 0.06),
		position = UDim2.fromScale(REEL_X + 0.01, 0.025),
		align = Enum.TextXAlignment.Left,
	})
	text(root, "CaptionRight", "EVERY FORAGER STARTS SOMEWHERE!", {
		font = Tokens.typography.label.font,
		color = MUTED,
		max = 20,
		zIndex = 3,
		size = UDim2.fromScale(0.3, 0.06),
		position = UDim2.fromScale(REEL_X + REEL_W - 0.01, 0.025),
		anchor = Vector2.new(1, 0),
		align = Enum.TextXAlignment.Right,
	})
	local pointer = Fit.frame(root, "Pointer", UDim2.fromScale(REEL_CX, 0.0), UDim2.fromScale(0, 0.2), 9, Vector2.new(0.5, 0))
	Fit.aspect(pointer, 0.7, Enum.DominantAxis.Height)
	local eggBox = { size = UDim2.fromScale(1.1, 0.68), position = UDim2.fromScale(0.5, 0.34), zIndex = 2, name = "Egg" }
	local egg = Fit.image(pointer, "forge.egg", eggBox) or Fit.image(pointer, "icon.egg", eggBox)
	if not egg then
		local glyph = Icons.egg(pointer, 10, { zIndex = 2, color = Tokens.color.gold })
		glyph.AnchorPoint = Vector2.new(0.5, 0.5)
		glyph.Position = UDim2.fromScale(0.5, 0.34)
		glyph.Size = UDim2.fromScale(1, 0.62)
	end
	local arrowDown = text(pointer, "Arrow", "▼", {
		font = Tokens.typography.display.font,
		color = Tokens.color.gold,
		max = 44,
		zIndex = 2,
		size = UDim2.fromScale(1, 0.4),
		position = UDim2.fromScale(0.5, 0.8),
		anchor = Vector2.new(0.5, 0.5),
	})

	-- Reel: a dark slate well with a thick black keyline; the clipping frame inside holds the fan.
	slab(
		root,
		"ReelFrame",
		UDim2.fromScale(REEL_X - 0.012, REEL_Y - 0.02),
		UDim2.fromScale(REEL_W + 0.024, REEL_H + 0.04),
		2,
		WELL,
		Tokens.radius.xl
	)
	local reel = Instance.new("Frame")
	reel.Name = "Reel"
	reel.Position = UDim2.fromScale(REEL_X, REEL_Y)
	reel.Size = UDim2.fromScale(REEL_W, REEL_H)
	reel.BackgroundTransparency = 1
	reel.BorderSizePixel = 0
	reel.ZIndex = 3
	reel.ClipsDescendants = true
	reel.Parent = root
	-- A soft dark band along the top of the well so the cards sit in it rather than on it.
	local lintel = Instance.new("Frame")
	lintel.Name = "Lintel"
	lintel.Size = UDim2.fromScale(1, 0.1)
	lintel.BackgroundColor3 = Tokens.color.shadow
	lintel.BackgroundTransparency = 0.6
	lintel.BorderSizePixel = 0
	lintel.ZIndex = 1
	local lintelFade = Instance.new("UIGradient")
	lintelFade.Rotation = 90
	lintelFade.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 1) })
	lintelFade.Parent = lintel
	lintel.Parent = reel
	local floorBand = Instance.new("Frame")
	floorBand.Name = "Floor"
	floorBand.Position = UDim2.fromScale(0, 0.9)
	floorBand.Size = UDim2.fromScale(1, 0.1)
	floorBand.BackgroundColor3 = Tokens.color.shadow
	floorBand.BackgroundTransparency = 0.6
	floorBand.BorderSizePixel = 0
	floorBand.ZIndex = 1
	local floorFade = Instance.new("UIGradient")
	floorFade.Rotation = 90
	floorFade.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(1, 0) })
	floorFade.Parent = floorBand
	floorBand.Parent = reel

	-- Cards: one per class, positioned by distance from the reel centre.
	local cards: { CardView } = {}
	local animated: { { gradient: UIGradient, speed: number } } = {}
	for _, entry in ipairs(weights) do
		local view = buildCard(reel, entry, tierFor(entry), 6)
		table.insert(cards, view)
		if view.rainbow then
			table.insert(animated, { gradient = view.rainbow, speed = 90 })
		end
	end
	local hovered: { [CardView]: boolean } = {}
	local function layoutReel()
		for index, view in ipairs(cards) do
			local rel = wrapRel(index - state.center, count)
			local distance = math.abs(rel)
			local offset, height, tilt, drop = reelAt(distance)
			local visible = distance < 2.6
			view.root.Visible = visible
			if visible then
				local side = if rel < 0 then -1 else 1
				view.root.Position = UDim2.fromScale(0.5 + side * offset, 0.5 + drop)
				view.root.Size = UDim2.fromScale(0, height)
				view.root.Rotation = side * tilt + (if hovered[view] then side * 1.5 else 0)
				view.root.ZIndex = 8 - math.floor(distance + 0.5)
				view.hit.Selectable = distance < 2.5
				-- Edge: the chosen card wears a thicker gold keyline, the rest the black one; a
				-- mythic card keeps its rainbow edge and only thickens.
				local lit = math.clamp(1 - distance, 0, 1)
				view.edge.Thickness = KEYLINE + lit * 2
				if not view.rainbow then
					view.edge.Color = if lit > 0.5 then Tokens.color.gold else OUTLINE
				end
			end
		end
	end

	-- Arrows: dark slate squares riding the well's edges.
	local function arrow(name: string, x: number, glyph: string, step: number): TextButton
		local button = Instance.new("TextButton")
		button.Name = name
		button.Text = ""
		button.AutoButtonColor = false
		button.AnchorPoint = Vector2.new(0.5, 0.5)
		button.Position = UDim2.fromScale(x, REEL_Y + REEL_H / 2)
		button.Size = UDim2.fromScale(0, 0.115)
		button.BackgroundColor3 = DEEP
		button.BorderSizePixel = 0
		button.ZIndex = 10
		button.Selectable = true
		Fit.aspect(button, 0.78, Enum.DominantAxis.Height)
		local minSize = Instance.new("UISizeConstraint")
		minSize.MinSize = Vector2.new(tap, tap)
		minSize.Parent = button
		relax(button)
		Fit.corner(button, 0.3)
		Depth.keyline(button)
		local face = Instance.new("Frame")
		face.Name = "Face"
		face.Size = UDim2.fromScale(1, 0.9)
		face.BackgroundColor3 = SLATE
		face.BorderSizePixel = 0
		face.ZIndex = 2
		Fit.corner(face, 0.3)
		Depth.applySheen(face, SLATE)
		Depth.rim(face, SLATE)
		face.Parent = button
		text(face, "Glyph", glyph, {
			font = Tokens.typography.display.font,
			max = 36,
			zIndex = 3,
			size = UDim2.fromScale(0.7, 0.7),
			position = UDim2.fromScale(0.5, 0.5),
			anchor = Vector2.new(0.5, 0.5),
		})
		local scale = Instance.new("UIScale")
		scale.Parent = button
		table.insert(
			cleanups,
			button.MouseEnter:Connect(function()
				Tween.scale(scale, "hover", motion, 1.08)
			end)
		)
		table.insert(
			cleanups,
			button.MouseLeave:Connect(function()
				Tween.scale(scale, "release", motion, 1)
			end)
		)
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
				scale.Scale = 0.9
				Tween.scale(scale, "release", motion, 1)
				local from = state.center
				local started = os.clock()
				local seconds = 0.3
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
	arrow("ArrowLeft", REEL_X - 0.008, "<", -1)
	arrow("ArrowRight", REEL_X + REEL_W + 0.008, ">", 1)

	local function selectClass(index: number)
		if state.rolling then
			return
		end
		local target = ((index - 1) % count) + 1
		local rel = wrapRel(target - state.center, count)
		state.selected = target
		local from = state.center
		local started = os.clock()
		local seconds = if math.abs(rel) < 0.01 then 0 else 0.32
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
					hovered[view] = true
					deps.audio:play(Tokens.sound.uiHover)
					Tween.scale(view.scale, "hover", motion, 1.05)
					layoutReel()
				end
			end)
		)
		table.insert(
			cleanups,
			view.hit.MouseLeave:Connect(function()
				hovered[view] = nil
				Tween.scale(view.scale, "release", motion, 1)
				layoutReel()
			end)
		)
	end

	-- Equipped column: a dark slate column titled EQUIPPED with one slate row per slot ----------
	local right = slab(root, "Equipped", UDim2.fromScale(RIGHT_X, 0.0), UDim2.fromScale(0.985 - RIGHT_X, 0.76), 3, WELL, Tokens.radius.xl)
	text(right, "Title", "EQUIPPED", {
		font = Tokens.typography.title.font,
		max = 26,
		zIndex = 4,
		size = UDim2.fromScale(0.9, 0.08),
		position = UDim2.fromScale(0.5, 0.06),
		anchor = Vector2.new(0.5, 0.5),
	})
	local rightBody = Fit.frame(right, "Body", UDim2.fromScale(0, 0.12), UDim2.fromScale(1, 0.87), 4)

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
		local slotTop = 0.02 + (index - 1) * (0.96 / maximumSlots)
		local slotHeight = 0.96 / maximumSlots - 0.03
		text(rightBody, "SlotLabel" .. index, "SLOT " .. index, {
			font = Tokens.typography.label.font,
			color = MUTED,
			max = 16,
			outline = 2,
			zIndex = 3,
			size = UDim2.fromScale(0.9, slotHeight * 0.13),
			position = UDim2.fromScale(0.5, slotTop),
			anchor = Vector2.new(0.5, 0),
		})
		local frame = slab(
			rightBody,
			"Slot" .. index,
			UDim2.fromScale(0.06, slotTop + slotHeight * 0.15),
			UDim2.fromScale(0.88, slotHeight * 0.84),
			3,
			SLATE,
			Tokens.radius.md
		)
		local line = Depth.keylineOf(frame) or Depth.keyline(frame)
		local artBox = Fit.frame(frame, "ArtBox", UDim2.fromScale(0.5, 0.3), UDim2.fromScale(0.5, 0.42), 4, Vector2.new(0.5, 0.5))
		local name = text(frame, "Name", "", {
			font = Tokens.typography.title.font,
			max = 20,
			zIndex = 4,
			size = UDim2.fromScale(0.9, 0.16),
			position = UDim2.fromScale(0.5, 0.62),
			anchor = Vector2.new(0.5, 0.5),
		})
		local slotPill, pillText = pill(frame, "Pill", "COMMON", UDim2.fromScale(0.5, 0.82), UDim2.fromScale(0.7, 0.16), 4, {
			fill = Tokens.color.sky,
			max = 14,
		})
		local lock = Icons.lock(frame, 10, { zIndex = 4, color = MUTED })
		lock.AnchorPoint = Vector2.new(0.5, 0.5)
		lock.Position = UDim2.fromScale(0.5, 0.28)
		lock.Size = UDim2.fromScale(0, 0.3)
		Fit.aspect(lock, 1, Enum.DominantAxis.Height)
		local empty = text(frame, "Empty", "EMPTY", {
			font = Tokens.typography.label.font,
			color = MUTED,
			max = 16,
			zIndex = 4,
			size = UDim2.fromScale(0.9, 0.16),
			position = UDim2.fromScale(0.5, 0.64),
			anchor = Vector2.new(0.5, 0.5),
		})
		local buy = Button.build(frame, {
			text = "+1 SLOT\nR$" .. tostring(cfg.classes.products.extraSlotRobux),
			variant = "gem",
			minimumTapTarget = tap,
			motion = motion,
			size = UDim2.fromScale(0.88, if phone then 0.5 else 0.42),
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
		buy.button.Position = UDim2.fromScale(0.5, 0.96)
		relax(buy.button)
		Fit.buttonText(buy, 22, 4)
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
			pill = slotPill,
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

	-- SPIN CLASS: the one irresistible button. Big, green, the gem cost under its lettering.
	local rollHandle = Button.build(root, {
		text = "SPIN CLASS",
		variant = "success",
		minimumTapTarget = tap,
		motion = motion,
		size = UDim2.fromScale(0.42, SPIN_H),
		zIndex = 4,
		sound = function()
			deps.audio:play(Tokens.sound.uiConfirm)
		end,
	})
	rollHandle.button.Name = "RollButton"
	rollHandle.button.AnchorPoint = Vector2.new(0.5, 0.5)
	rollHandle.button.Position = UDim2.fromScale(REEL_CX, SPIN_Y)
	local rollLabel = Fit.buttonText(rollHandle, 46)
	if rollLabel then
		rollLabel.Size = UDim2.fromScale(1, 0.64)
		local pad = rollLabel:FindFirstChildOfClass("UIPadding")
		if pad then
			pad.PaddingTop = UDim.new(0.1, 0)
			pad.PaddingBottom = UDim.new(0.02, 0)
		end
	end
	local rollFace = rollHandle.button:FindFirstChild("Face")
	if rollFace and rollFace:IsA("Frame") then
		costRow(rollFace, cfg.classes.rollGemCost, UDim2.fromScale(0.5, 0.78), UDim2.fromScale(0.5, 0.3), rollFace.ZIndex + 6)
	end
	table.insert(cleanups, rollHandle.destroy)
	rollHandle.pulse(true)

	-- Pills under the button: the two passes and the two toggles, dark slate, green when on.
	local toggles =
		Fit.frame(root, "Toggles", UDim2.fromScale(REEL_CX, TOGGLE_Y), UDim2.fromScale(0.68, TOGGLE_H), 4, Vector2.new(0.5, 0.5))
	Fit.row(toggles, { gap = 0.015 })
	local function togglePill(name: string, label: string, order: number, sound: string, onActivated: (() -> ())?): any
		local handle = Button.build(toggles, {
			text = label,
			variant = "pill",
			minimumTapTarget = tap,
			motion = motion,
			size = UDim2.fromScale(0.235, 1),
			zIndex = 4,
			sound = function()
				deps.audio:play(sound)
			end,
			hoverSound = function()
				deps.audio:play(Tokens.sound.uiHover)
			end,
			onActivated = onActivated,
		})
		handle.button.Name = name
		handle.button.LayoutOrder = order
		Fit.buttonText(handle, 18, 6)
		relax(handle.button)
		table.insert(cleanups, handle.destroy)
		return handle
	end
	local passHandles: { [string]: any } = {}
	local function passPill(name: string, passKey: string, label: string, priceKey: string, order: number)
		local handle = togglePill(
			name,
			string.format("%s  R$%d", label, cfg.classes.products[priceKey]),
			order,
			Tokens.sound.uiTap,
			function()
				-- An owned pass is "on"; pressing it again has nothing to sell.
				if entitlements()[passKey] == true then
					return
				end
				UpgradeActions.promptPurchase({ net = deps.net, audio = deps.audio, toasts = deps.toasts }, passKey, label)
			end
		)
		passHandles[passKey] = { handle = handle, label = label, priceKey = priceKey }
	end
	passPill("LuckPass", "doubleLuck", "2× LUCK", "doubleLuckRobux", 1)
	passPill("FastPass", "fastRolls", "FAST ROLLS", "fastRollsRobux", 2)
	local autoHandle = togglePill("AutoButton", "AUTO: OFF", 3, Tokens.sound.uiSwitch)
	local skipHandle = togglePill("SkipButton", "SKIP: OFF", 4, Tokens.sound.uiSwitch)
	local function paintToggles()
		autoHandle.setText(if state.auto then "AUTO: ON" else "AUTO: OFF")
		autoHandle.setVariant(if state.auto then "success" else "pill")
		skipHandle.setText(if state.skip then "SKIP: ON" else "SKIP: OFF")
		skipHandle.setVariant(if state.skip then "success" else "pill")
	end

	-- CLASS INFO drawer ----------------------------------------------------------------------------
	local infoTab = Instance.new("TextButton")
	infoTab.Name = "InfoTab"
	infoTab.Text = ""
	infoTab.AutoButtonColor = false
	infoTab.AnchorPoint = Vector2.new(1, 0.5)
	infoTab.Position = UDim2.fromScale(REEL_X + REEL_W - 0.018, REEL_Y + 0.045)
	infoTab.Size = UDim2.fromScale(0.13, 0.07)
	infoTab.BackgroundColor3 = DEEP
	infoTab.BorderSizePixel = 0
	infoTab.ZIndex = 11
	infoTab.Selectable = true
	local infoMin = Instance.new("UISizeConstraint")
	infoMin.MinSize = Vector2.new(tap, tap)
	infoMin.Parent = infoTab
	relax(infoTab)
	Fit.corner(infoTab, 0.5)
	Depth.keyline(infoTab)
	local infoFace = Instance.new("Frame")
	infoFace.Name = "Face"
	infoFace.Size = UDim2.fromScale(1, 0.9)
	infoFace.BackgroundColor3 = SLATE
	infoFace.BorderSizePixel = 0
	infoFace.ZIndex = 2
	Fit.corner(infoFace, 0.5)
	Depth.applySheen(infoFace, SLATE)
	Depth.rim(infoFace, SLATE)
	infoFace.Parent = infoTab
	text(infoFace, "Glyph", "i", {
		font = Tokens.typography.display.font,
		color = Tokens.color.sky,
		max = 26,
		zIndex = 3,
		size = UDim2.fromScale(0.16, 0.7),
		position = UDim2.fromScale(0.12, 0.5),
		anchor = Vector2.new(0.5, 0.5),
	})
	text(infoFace, "Label", "CLASS INFO", {
		font = Tokens.typography.label.font,
		max = 18,
		zIndex = 3,
		size = UDim2.fromScale(0.72, 0.66),
		position = UDim2.fromScale(0.24, 0.17),
		align = Enum.TextXAlignment.Left,
	})
	local infoTabScale = Instance.new("UIScale")
	infoTabScale.Parent = infoTab
	infoTab.Parent = root

	local DRAWER_X = 0.36
	local drawer = slab(
		root,
		"InfoDrawer",
		UDim2.fromScale(1.02, 0.01),
		UDim2.fromScale(1 - DRAWER_X - 0.01, 0.98),
		12,
		Tokens.color.panel,
		Tokens.radius.xl
	)
	drawer.Visible = false
	local drawerPage = slab(drawer, "Page", UDim2.fromScale(0.02, 0.03), UDim2.fromScale(0.96, 0.94), 1, WELL, Tokens.radius.lg)
	text(drawerPage, "Title", "CLASS INFO", {
		font = Tokens.typography.title.font,
		max = 30,
		zIndex = 3,
		size = UDim2.fromScale(0.5, 0.09),
		position = UDim2.fromScale(0.5, 0.06),
		anchor = Vector2.new(0.5, 0.5),
	})
	text(drawerPage, "Sub", "EVERY CLASS THE FORGE CAN ROLL, WITH ITS EXACT ODDS AND BONUSES", {
		font = Tokens.typography.caption.font,
		color = MUTED,
		max = 13,
		outline = 2,
		zIndex = 2,
		size = UDim2.fromScale(0.7, 0.05),
		position = UDim2.fromScale(0.5, 0.135),
		anchor = Vector2.new(0.5, 0.5),
	})
	local drawerClose = Instance.new("TextButton")
	drawerClose.Name = "DrawerClose"
	drawerClose.Text = ""
	drawerClose.AutoButtonColor = false
	drawerClose.AnchorPoint = Vector2.new(0.5, 0.5)
	drawerClose.Position = UDim2.fromScale(0.955, 0.065)
	drawerClose.Size = UDim2.fromScale(0, 0.09)
	drawerClose.BackgroundColor3 = Tokens.color.emberDeep
	drawerClose.BorderSizePixel = 0
	drawerClose.ZIndex = 4
	drawerClose.Selectable = true
	Fit.aspect(drawerClose, 1, Enum.DominantAxis.Height)
	local drawerCloseMin = Instance.new("UISizeConstraint")
	drawerCloseMin.MinSize = Vector2.new(tap, tap)
	drawerCloseMin.Parent = drawerClose
	relax(drawerClose)
	Fit.corner(drawerClose, 0.3)
	Depth.keyline(drawerClose)
	local drawerCloseFace = Instance.new("Frame")
	drawerCloseFace.Name = "Face"
	drawerCloseFace.Size = UDim2.fromScale(1, 0.9)
	drawerCloseFace.BackgroundColor3 = Tokens.color.ember
	drawerCloseFace.BorderSizePixel = 0
	drawerCloseFace.ZIndex = 2
	Fit.corner(drawerCloseFace, 0.3)
	Depth.applySheen(drawerCloseFace, Tokens.color.ember)
	Depth.rim(drawerCloseFace, Tokens.color.ember)
	drawerCloseFace.Parent = drawerClose
	text(drawerCloseFace, "X", "X", {
		font = Tokens.typography.display.font,
		max = 36,
		zIndex = 3,
		size = UDim2.fromScale(0.8, 0.8),
		position = UDim2.fromScale(0.5, 0.5),
		anchor = Vector2.new(0.5, 0.5),
	})
	drawerClose.Parent = drawerPage

	-- Class tiles: two rows, every class in roll order.
	local grid = Fit.frame(drawerPage, "Grid", UDim2.fromScale(0.03, 0.17), UDim2.fromScale(0.94, 0.5), 2)
	local columns = math.ceil(count / 2)
	type InfoTile = { root: Frame, line: UIStroke, odds: TextLabel, hit: TextButton, index: number }
	local infoTiles: { InfoTile } = {}
	for index, entry in ipairs(weights) do
		local entryTier = tierFor(entry)
		local colors = colorsFor(entryTier)
		local col = (index - 1) % columns
		local row = math.floor((index - 1) / columns)
		local tile = slab(
			grid,
			"Tile_" .. entry.id,
			UDim2.fromScale(col / columns + 0.005, row * 0.51),
			UDim2.fromScale(1 / columns - 0.01, 0.48),
			2,
			SLATE,
			Tokens.radius.md
		)
		tile.ClipsDescendants = true
		local line = Depth.keylineOf(tile) or Depth.keyline(tile)
		headerBand(tile, 0.22, colors.fill, 2, Tokens.radius.md)
		if entryTier == "mythic" then
			line.Color = WHITE
			local gradient = Instance.new("UIGradient")
			gradient.Color = RAINBOW
			gradient.Parent = line
			table.insert(animated, { gradient = gradient, speed = 90 })
		end
		text(tile, "Name", string.upper(entry.displayName), {
			font = Tokens.typography.label.font,
			max = 15,
			min = 5,
			outline = 2,
			zIndex = 4,
			size = UDim2.fromScale(0.94, 0.16),
			position = UDim2.fromScale(0.5, 0.11),
			anchor = Vector2.new(0.5, 0.5),
		})
		local tileArt = Fit.frame(tile, "ArtBox", UDim2.fromScale(0.5, 0.52), UDim2.fromScale(0.7, 0.48), 3, Vector2.new(0.5, 0.5))
		classArt(tileArt, entry, 3)
		local _, tileOdds = pill(tile, "OddsPill", "", UDim2.fromScale(0.5, 0.87), UDim2.fromScale(0.7, 0.16), 4, { max = 16 })
		tileOdds.Name = "Odds"
		local tileHit = Instance.new("TextButton")
		tileHit.Name = "Hit"
		tileHit.Text = ""
		tileHit.BackgroundTransparency = 1
		tileHit.Size = UDim2.fromScale(1, 1)
		tileHit.ZIndex = 6
		tileHit.Selectable = true
		tileHit.Parent = tile
		table.insert(infoTiles, { root = tile, line = line, odds = tileOdds, hit = tileHit, index = index })
	end
	-- Breakdown: the selected class's exact numbers.
	local breakdown = slab(drawerPage, "Breakdown", UDim2.fromScale(0.03, 0.69), UDim2.fromScale(0.94, 0.29), 2, SLATE, Tokens.radius.lg)
	local breakdownArt = Fit.frame(breakdown, "ArtBox", UDim2.fromScale(0.09, 0.5), UDim2.fromScale(0, 0.8), 3, Vector2.new(0.5, 0.5))
	Fit.aspect(breakdownArt, 1, Enum.DominantAxis.Height)
	local breakdownName = text(breakdown, "Name", "", {
		font = Tokens.typography.title.font,
		max = 24,
		zIndex = 3,
		size = UDim2.fromScale(0.5, 0.26),
		position = UDim2.fromScale(0.19, 0.06),
		align = Enum.TextXAlignment.Left,
	})
	local breakdownRarity, breakdownRarityText = pill(
		breakdown,
		"Rarity",
		"",
		UDim2.fromScale(0.97, 0.08),
		UDim2.fromScale(0.26, 0.22),
		3,
		{ fill = Tokens.color.sky, max = 14, anchor = Vector2.new(1, 0) }
	)
	-- The bonus list scrolls when a class grants more lines than the strip can hold (Master Forager).
	local breakdownScroll = Instance.new("ScrollingFrame")
	breakdownScroll.Name = "LinesScroll"
	breakdownScroll.BackgroundTransparency = 1
	breakdownScroll.BorderSizePixel = 0
	breakdownScroll.Position = UDim2.fromScale(0.19, 0.34)
	breakdownScroll.Size = UDim2.fromScale(0.78, 0.62)
	breakdownScroll.CanvasSize = UDim2.fromScale(0, 0)
	breakdownScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	breakdownScroll.ScrollingDirection = Enum.ScrollingDirection.Y
	breakdownScroll.ScrollBarThickness = 4
	breakdownScroll.ScrollBarImageColor3 = MUTED
	breakdownScroll.ElasticBehavior = Enum.ElasticBehavior.Never
	breakdownScroll.ZIndex = 3
	breakdownScroll.Parent = breakdown
	local breakdownLines = Instance.new("TextLabel")
	breakdownLines.Name = "Lines"
	breakdownLines.BackgroundTransparency = 1
	breakdownLines.Size = UDim2.new(1, -8, 0, 0)
	breakdownLines.AutomaticSize = Enum.AutomaticSize.Y
	breakdownLines.Font = Tokens.typography.body.font
	breakdownLines.TextSize = if phone then 11 else 15
	breakdownLines.TextColor3 = WHITE
	breakdownLines.TextWrapped = true
	breakdownLines.TextXAlignment = Enum.TextXAlignment.Left
	breakdownLines.TextYAlignment = Enum.TextYAlignment.Top
	breakdownLines.ZIndex = 3
	FrameKit.outline(breakdownLines, 2, OUTLINE)
	breakdownLines.Parent = breakdownScroll
	local breakdownArtView: GuiObject? = nil
	local function renderInfo()
		local projection = deps.profile.projection
		local ent = entitlements()
		local odds = ClassRoll.odds(cfg, ent.doubleLuck == true)
		for _, tile in ipairs(infoTiles) do
			local record = odds[tile.index]
			tile.odds.Text = if record then string.format("%.1f%%", record.percent) else ""
			local selected = tile.index == state.infoSelected
			tile.line.Thickness = if selected then KEYLINE + 2 else KEYLINE
			local tileTier = tierFor(weights[tile.index])
			if tileTier ~= "mythic" then
				tile.line.Color = if selected then Tokens.color.gold else OUTLINE
			end
		end
		local entry = weights[state.infoSelected]
		if not entry then
			return
		end
		local entryTier = tierFor(entry)
		local record = odds[state.infoSelected]
		breakdownName.Text = string.format(
			"%s  -  %s ROLL CHANCE",
			string.upper(entry.displayName),
			if record then string.format("%.1f%%", record.percent) else ""
		)
		breakdownRarity.BackgroundColor3 = colorsFor(entryTier).fill
		breakdownRarityText.Text = string.upper(RARITY_LABEL[entryTier] or entryTier)
		local lines = effectLines(entry, weights)
		local owned = projection and projection.classes.owned[entry.id] == true
		if #lines == 0 then
			table.insert(lines, "No bonuses. Every forager starts somewhere.")
		end
		local lineText = "• " .. table.concat(lines, "\n• ")
		if owned then
			lineText ..= "\n✓ OWNED"
		end
		breakdownLines.Text = lineText
		if breakdownArtView == nil or breakdownArtView:GetAttribute("SFE_ClassId") ~= entry.id then
			if breakdownArtView then
				breakdownArtView:Destroy()
			end
			local art = classArt(breakdownArt, entry, 3)
			art:SetAttribute("SFE_ClassId", entry.id)
			breakdownArtView = art
		end
	end
	for _, tile in ipairs(infoTiles) do
		table.insert(
			cleanups,
			tile.hit.Activated:Connect(function()
				deps.audio:play(Tokens.sound.uiTab)
				state.infoSelected = tile.index
				renderInfo()
			end)
		)
	end
	local function setInfo(open: boolean)
		if state.infoOpen == open then
			return
		end
		state.infoOpen = open
		container:SetAttribute("SFE_ClassesInfoOpen", open)
		if open then
			state.infoSelected = state.selected
			renderInfo()
			drawer.Visible = true
			drawer.Position = UDim2.fromScale(1.02, 0.01)
			deps.audio:play(Tokens.sound.uiPageFlip)
			TweenService:Create(
				drawer,
				TweenInfo.new(if motion.reducedMotion then 0.12 else 0.42, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
				{ Position = UDim2.fromScale(DRAWER_X, 0.01) }
			):Play()
			api.setInitialFocus(drawerClose)
		else
			deps.audio:play(Tokens.sound.uiClose)
			local slide = TweenService:Create(
				drawer,
				TweenInfo.new(if motion.reducedMotion then 0.1 else 0.26, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
				{ Position = UDim2.fromScale(1.02, 0.01) }
			)
			slide:Play()
			slide.Completed:Once(function()
				if not state.infoOpen then
					drawer.Visible = false
				end
			end)
		end
	end
	table.insert(
		cleanups,
		infoTab.Activated:Connect(function()
			deps.audio:play(Tokens.sound.uiTap)
			setInfo(not state.infoOpen)
		end)
	)
	table.insert(
		cleanups,
		infoTab.MouseEnter:Connect(function()
			Tween.scale(infoTabScale, "hover", motion, 1.05)
		end)
	)
	table.insert(
		cleanups,
		infoTab.MouseLeave:Connect(function()
			Tween.scale(infoTabScale, "release", motion, 1)
		end)
	)
	table.insert(
		cleanups,
		drawerClose.Activated:Connect(function()
			setInfo(false)
		end)
	)

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
			view.line.Color = if active then Tokens.color.gold else OUTLINE
			view.line.Thickness = if active then KEYLINE + 1 else KEYLINE
		end
		for passKey, record in pairs(passHandles) do
			local owned = ent[passKey] == true
			record.handle.setText(
				if owned then record.label .. ": ON" else string.format("%s  R$%d", record.label, cfg.classes.products[record.priceKey])
			)
			record.handle.setVariant(if owned then "success" else "pill")
		end
		local canRoll = not state.rolling and (projection.currencies.gems or 0) >= cfg.classes.rollGemCost
		rollHandle.setEnabled(canRoll or state.rolling)
		paintToggles()
		if state.infoOpen then
			renderInfo()
		end
	end

	-- Reveal screen --------------------------------------------------------------------------------
	local currentResult: { finish: () -> (), keep: () -> () }? = nil
	local function showResult(result: any, previousClassId: string?, onDone: () -> ()): () -> ()
		local entry = entryFor(result.classId)
			or { id = result.classId, displayName = result.displayName or result.classId, weight = 1, effect = {} }
		local entryTier = tierFor(entry)
		local colors = colorsFor(entryTier)
		-- A dark slab over the whole card, headed in the rarity colour.
		local overlay = Instance.new("Frame")
		overlay.Name = "Result"
		overlay.Size = UDim2.fromScale(1, 1)
		overlay.BackgroundColor3 = DEEP
		overlay.BackgroundTransparency = 0.06
		overlay.BorderSizePixel = 0
		overlay.ZIndex = 5
		overlay.ClipsDescendants = true
		Fit.corner(overlay, 0.04)
		overlay.Parent = shell.card
		shell.plaque.Visible = false
		shell.headerRight.Visible = false
		-- The controls under the overlay rest while the result is up.
		toggles.Visible = false
		local rays = Skin.texture(overlay, "texture.rays", { transparency = 0.72, name = "Rays", zIndex = 1 })
		if rays then
			rays.AnchorPoint = Vector2.new(0.5, 0.5)
			rays.Position = UDim2.fromScale(0.5, 0.55)
			rays.Size = UDim2.fromScale(1.4, 1.4)
			rays.ImageColor3 = if entryTier == "mythic" then WHITE else colors.fill
		end
		local aura = Instance.new("Frame")
		aura.Name = "Aura"
		aura.AnchorPoint = Vector2.new(0.5, 0.5)
		aura.Position = UDim2.fromScale(0.5, 0.55)
		aura.Size = UDim2.fromScale(0.4, 0.62)
		aura.BackgroundColor3 = if entryTier == "mythic" then WHITE else colors.fill
		aura.BackgroundTransparency = 0.6
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

		local band = headerBand(overlay, 0.16, colors.fill, 3, Tokens.radius.xl)
		if entryTier == "mythic" then
			local bandRainbow = Instance.new("UIGradient")
			bandRainbow.Color = RAINBOW
			bandRainbow.Parent = band
			table.insert(animated, { gradient = bandRainbow, speed = 40 })
		end
		local title = text(band, "Title", string.upper(RARITY_LABEL[entryTier] or entryTier) .. " CLASS!", {
			font = Tokens.typography.display.font,
			max = 66,
			outline = 3.2,
			zIndex = 4,
			size = UDim2.fromScale(0.6, 0.8),
			position = UDim2.fromScale(0.5, 0.5),
			anchor = Vector2.new(0.5, 0.5),
		})
		if entryTier == "mythic" then
			local titleGradient = Instance.new("UIGradient")
			titleGradient.Color = RAINBOW
			titleGradient.Parent = title
			table.insert(animated, { gradient = titleGradient, speed = 60 })
		end
		pill(
			overlay,
			"Sub",
			string.format("%s  -  %s", string.upper(entry.displayName), percent(result.percent or (entry.weight / 100))),
			UDim2.fromScale(0.5, 0.235),
			UDim2.fromScale(0.4, 0.07),
			4,
			{ fill = SLATE, max = 26 }
		)
		local sparkles: { Frame } = {}
		for index, spot in ipairs({ { 0.26, 0.4 }, { 0.74, 0.38 }, { 0.27, 0.7 }, { 0.73, 0.72 }, { 0.34, 0.54 }, { 0.66, 0.56 } }) do
			local star = Icons.star(overlay, 10, { zIndex = 4, color = Tokens.color.goldLight })
			star.Name = "Sparkle" .. index
			star.AnchorPoint = Vector2.new(0.5, 0.5)
			star.Position = UDim2.fromScale(spot[1], spot[2])
			star.Size = UDim2.fromScale(0, 0.03 + (index % 3) * 0.008)
			Fit.aspect(star, 1, Enum.DominantAxis.Height)
			table.insert(sparkles, star)
		end

		local holder = Fit.frame(overlay, "CardHolder", UDim2.fromScale(0.5, 0.53), UDim2.fromScale(0, 0.48), 5, Vector2.new(0.5, 0.5))
		Fit.aspect(holder, CARD_ASPECT, Enum.DominantAxis.Height)
		local card = buildCard(holder, entry, entryTier, 1)
		card.root.Position = UDim2.fromScale(0.5, 0.5)
		card.root.Size = UDim2.fromScale(0, 1)
		card.odds.Text = percent(result.percent or (entry.weight / 100))
		card.hit:Destroy()
		card.edge.Thickness = KEYLINE + 2
		if not card.rainbow then
			card.edge.Color = Tokens.color.gold
		end
		card.scale.Scale = 0.2
		Tween.scale(card.scale, "release", motion, 1)
		if card.rainbow then
			table.insert(animated, { gradient = card.rainbow, speed = 90 })
		end

		local chips = bonusChips(entry)
		local chipRow = Fit.frame(overlay, "Bonuses", UDim2.fromScale(0.5, 0.825), UDim2.fromScale(0.8, 0.095), 5, Vector2.new(0.5, 0.5))
		Fit.row(chipRow, { gap = 0.02 })
		local shown: { { title: string, icon: string } } = if #chips == 0 then { { title = "STARTING CLASS", icon = "feather" } } else chips
		for index, bonus in ipairs(shown) do
			local bonusChip = slab(chipRow, "Bonus" .. index, UDim2.fromScale(0, 0), UDim2.fromScale(0.3, 1), 5, SLATE, Tokens.radius.md)
			bonusChip.LayoutOrder = index
			local glyph = Icons.build(bonus.icon, bonusChip, 10, { zIndex = 6, color = Tokens.color.goldLight })
			glyph.AnchorPoint = Vector2.new(0.5, 0.5)
			glyph.Position = UDim2.fromScale(0.13, 0.5)
			glyph.Size = UDim2.fromScale(0, 0.62)
			Fit.aspect(glyph, 1, Enum.DominantAxis.Height)
			text(bonusChip, "Title", bonus.title, {
				font = Tokens.typography.label.font,
				max = 20,
				zIndex = 6,
				size = UDim2.fromScale(0.7, 0.42),
				position = UDim2.fromScale(0.26, 0.1),
				align = Enum.TextXAlignment.Left,
			})
			text(bonusChip, "Applied", if #chips == 0 then "NO BONUSES" else "BONUS APPLIED", {
				font = Tokens.typography.caption.font,
				color = if #chips == 0 then MUTED else Tokens.color.leafBright,
				max = 14,
				outline = 2,
				zIndex = 6,
				size = UDim2.fromScale(0.7, 0.32),
				position = UDim2.fromScale(0.26, 0.56),
				align = Enum.TextXAlignment.Left,
			})
		end

		local done = false
		local function finish()
			if done then
				return
			end
			done = true
			currentResult = nil
			shell.plaque.Visible = true
			shell.headerRight.Visible = true
			toggles.Visible = true
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
		local actions = Fit.frame(overlay, "Actions", UDim2.fromScale(0.5, 0.93), UDim2.fromScale(0.56, 0.1), 5, Vector2.new(0.5, 0.5))
		Fit.row(actions, { gap = 0.03 })
		local equipNow = Button.build(actions, {
			text = "EQUIP NOW",
			variant = "success",
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
			variant = "danger",
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
		local tag = text(overlay, "Unlocked", if result.duplicate then "ALREADY OWNED - EQUIPPED" else "NEW CLASS UNLOCKED!", {
			font = Tokens.typography.label.font,
			color = if result.duplicate then MUTED else Tokens.color.leafBright,
			max = 20,
			outline = 2,
			zIndex = 6,
			size = UDim2.fromScale(0.17, 0.045),
			position = UDim2.fromScale(0.985, 0.985),
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
				if rays and rays.Parent then
					rays.Rotation = (rays.Rotation + dt * 10) % 360
				end
				if aura.Parent then
					aura.BackgroundTransparency = 0.6 + 0.12 * math.sin(now * 3)
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
				shell.headerRight.Visible = true
				shell.headerRight.Visible = true
				toggles.Visible = true
				if overlay.Parent then
					overlay:Destroy()
				end
			end
		end)
		return finish
	end

	-- Spin: the reel accelerates, passes the pointer, slows and snaps onto the committed class;
	-- the landing sound and the reveal come only after the final card is in place --------------
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
			state.center = from + distance * spinEase(t)
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
					landing.scale.Scale = 1.14
					Tween.scale(landing.scale, "release", motion, 1)
					Tween.sheen(landing.sheen, motion)
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
				task.delay(if state.skip then 0.05 else 0.4, function()
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
		setInfo(false)
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
	-- Life: rainbow rims turn, the egg bobs, the chosen card breathes, a shimmer sweeps it now
	-- and then.
	local nextShimmer = os.clock() + 2
	table.insert(
		cleanups,
		RunService.RenderStepped:Connect(function(dt)
			local now = os.clock()
			for _, entry in ipairs(animated) do
				entry.gradient.Rotation = (entry.gradient.Rotation + dt * entry.speed) % 360
			end
			if motion.reducedMotion then
				return
			end
			pointer.Position = UDim2.fromScale(REEL_CX, math.sin(now * 3) * 0.006)
			arrowDown.TextTransparency = 0.1 + 0.1 * math.sin(now * 4)
			if not state.rolling then
				local chosen = cards[state.selected]
				if chosen and not hovered[chosen] then
					chosen.scale.Scale = 1 + 0.015 * math.sin(now * 2)
				end
				if now > nextShimmer then
					nextShimmer = now + 3.5
					if chosen then
						Tween.sheen(chosen.sheen, motion)
					end
				end
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
			info = function(open: any)
				setInfo(if open == nil then not state.infoOpen else open == true or open == 1 or open == "on")
				return { open = state.infoOpen }
			end,
			infoSelect = function(index: number)
				state.infoSelected = math.clamp(index, 1, count)
				renderInfo()
				return { selected = state.infoSelected, lines = breakdownLines.Text }
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
					info = state.infoOpen,
					stats = stats,
				}
			end,
		})
	end
	container:SetAttribute("SFE_ClassesRolling", false)
	container:SetAttribute("SFE_ClassesInfoOpen", false)
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
