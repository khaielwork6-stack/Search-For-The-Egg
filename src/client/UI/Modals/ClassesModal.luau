--!strict
-- Class Forge: a wooden forging machine. Warm wood interior with hay, a five-card reel under one
-- golden egg pointer (the chosen card largest and lit, the neighbours smaller, tilted and behind
-- it), a hanging EQUIPPED CLASSES board on the right, one big SPIN button, AUTO / SKIP toggles and
-- the two passes along the bottom, and an (i) CLASS INFO drawer that slides in over the reel with
-- every obtainable class, its odds and its exact bonuses read from config. Every element is Scale
-- relative to the shell's content frame. Odds, prices and slots come from config and the profile;
-- the roll, equip and purchases go through the same remotes as before.

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

-- Palette: warm wood, never black.
local WOOD = Color3.fromRGB(150, 108, 60)
local WOOD_DEEP = Color3.fromRGB(96, 64, 34)
local WOOD_LIGHT = Color3.fromRGB(204, 158, 100)
local WOOD_WARM = Color3.fromRGB(128, 86, 48)
local BARREL = Color3.fromRGB(118, 76, 40)
local BARREL_DEEP = Color3.fromRGB(78, 48, 26)
local BARREL_GLOW = Color3.fromRGB(196, 132, 62)
local PAPER = Color3.fromRGB(250, 241, 220)
local PARCHMENT = Color3.fromRGB(238, 224, 190)
local STRAW = Color3.fromRGB(240, 204, 104)
local STRAW_DEEP = Color3.fromRGB(198, 150, 60)
local CARD_ASPECT = 0.74

-- Reel geometry by distance from the centre slot (Scale of the reel): x offset, card height, tilt
-- and drop. Neighbours sit slightly behind the chosen card, like cards fanned on a shelf.
local REEL_OFFSET = { [0] = 0, 0.255, 0.4, 0.48 }
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

-- Wood plank with a light rim and a dark keyline.
local function plank(parent: GuiObject, name: string, position: UDim2, size: UDim2, z: number, face: Color3?): Frame
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.Position = position
	frame.Size = size
	frame.BorderSizePixel = 0
	frame.ZIndex = z
	Depth.panel(frame, face or WOOD, { radius = Tokens.radius.md, rim = WOOD_LIGHT })
	Fit.corner(frame, 0.22)
	frame.Parent = parent
	return frame
end

-- A leaf sprig (painted when available) at a Scale spot.
local function leaf(parent: GuiObject, name: string, position: UDim2, height: number, z: number, rotation: number?, left: boolean?)
	local image = Fit.image(parent, if left then "modal.leaf.left" else "modal.leaf.right", {
		size = UDim2.fromScale(0, height),
		position = position,
		zIndex = z,
		name = name,
	})
	if image then
		Fit.aspect(image, 1, Enum.DominantAxis.Height)
		image.Rotation = rotation or 0
	end
	return image
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

-- One class card: rarity face with a sunburst, the pack's rarity rim (rainbow for mythic), art,
-- name, odds, the rarity pill and a rarity-coloured edge light. Sized by its parent (height-driven).
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
	local edge = Depth.keylineOf(face) or Depth.keyline(face)
	edge.Color = colors.fill:Lerp(Color3.new(1, 1, 1), 0.35)
	edge.Thickness = 2
	edge.Transparency = 0.2
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
	-- Shimmer: a light band that sweeps the face now and then.
	local shine = Instance.new("Frame")
	shine.Name = "Shine"
	shine.Size = UDim2.fromScale(1, 1)
	shine.BackgroundColor3 = Color3.new(1, 1, 1)
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
	elseif tier == "mythic" then
		local gradient = Instance.new("UIGradient")
		gradient.Color = RAINBOW
		gradient.Parent = edge
		rainbow = gradient
	end

	local artBox = Fit.frame(root, "ArtBox", UDim2.fromScale(0.5, 0.36), UDim2.fromScale(0.74, 0.48), 3, Vector2.new(0.5, 0.5))
	classArt(artBox, entry, 3)
	local name = Fit.text(root, "Name", string.upper(entry.displayName), {
		font = Tokens.typography.title.font,
		color = Tokens.color.featherWhite,
		max = 26,
		min = 4,
		outline = 2,
		outlineColor = colors.deep,
		zIndex = 5,
		size = UDim2.fromScale(0.9, 0.12),
		position = UDim2.fromScale(0.5, 0.675),
		anchor = Vector2.new(0.5, 0.5),
	})
	local odds = Fit.text(root, "Odds", "0%", {
		font = Tokens.typography.display.font,
		color = Tokens.color.featherWhite,
		max = 26,
		min = 4,
		outline = 2,
		outlineColor = colors.deep,
		zIndex = 5,
		size = UDim2.fromScale(0.8, 0.11),
		position = UDim2.fromScale(0.5, 0.78),
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
		min = 4,
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

	-- The content frame is the one root: no scrolling, every child in Scale. The shell's parchment
	-- becomes the machine's inner bevel and the plaque grows into the carved sign.
	container.AutomaticCanvasSize = Enum.AutomaticSize.None
	container.CanvasSize = UDim2.fromScale(0, 0)
	container.ScrollingEnabled = false
	container.ScrollBarThickness = 0
	container.Position = UDim2.fromScale(0.012, 0.02)
	container.Size = UDim2.fromScale(0.976, 0.96)
	shell.panel.BackgroundColor3 = BARREL_DEEP
	local panelSheen = shell.panel:FindFirstChildOfClass("UIGradient")
	if panelSheen then
		panelSheen.Color = Depth.sheen(BARREL_DEEP)
	end
	for _, name in ipairs({ "Weave", "SFE_InnerShadow" }) do
		local child = shell.panel:FindFirstChild(name)
		if child then
			child.Visible = false
		end
	end
	shell.plaque.Size = UDim2.fromScale(if phone then 0.44 else 0.48, 1.24)
	shell.plaque.Position = UDim2.fromScale(0.5, 0.6)
	local titleConstraint = shell.titleLabel:FindFirstChildOfClass("UITextSizeConstraint")
	if titleConstraint then
		titleConstraint.MaxTextSize = 64
	end
	shell.titleLabel.Size = UDim2.fromScale(0.66, 0.66)
	shell.titleLabel.Position = UDim2.fromScale(0.56, 0.5)

	local root = Instance.new("Frame")
	root.Name = "Forge"
	root.Size = UDim2.fromScale(1, 1)
	root.BackgroundColor3 = WOOD_WARM
	root.BorderSizePixel = 0
	root.ZIndex = 1
	Fit.corner(root, 0.035)
	root.Parent = container
	-- Warm interior: lighter towards the reel, darker at the edges; vertical planks.
	local roomLight = Instance.new("UIGradient")
	roomLight.Rotation = 90
	roomLight.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(146, 100, 56)),
		ColorSequenceKeypoint.new(0.55, WOOD_WARM),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(104, 68, 36)),
	})
	roomLight.Parent = root
	for index = 1, 9 do
		local seam = Instance.new("Frame")
		seam.Name = "Plank" .. index
		seam.Position = UDim2.fromScale(index / 10, 0)
		seam.Size = UDim2.fromScale(0.003, 1)
		seam.BackgroundColor3 = WOOD_DEEP
		seam.BackgroundTransparency = 0.72
		seam.BorderSizePixel = 0
		seam.ZIndex = 1
		seam.Parent = root
	end
	local warmGlow = Instance.new("Frame")
	warmGlow.Name = "WarmGlow"
	warmGlow.AnchorPoint = Vector2.new(0.5, 0.5)
	warmGlow.Position = UDim2.fromScale(0.39, 0.45)
	warmGlow.Size = UDim2.fromScale(0.78, 0.9)
	warmGlow.BackgroundColor3 = BARREL_GLOW
	warmGlow.BackgroundTransparency = 0.72
	warmGlow.BorderSizePixel = 0
	warmGlow.ZIndex = 1
	Fit.corner(warmGlow, 0.5)
	local warmFade = Instance.new("UIGradient")
	warmFade.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.5, 0),
		NumberSequenceKeypoint.new(1, 1),
	})
	warmFade.Parent = warmGlow
	warmGlow.Parent = root
	local bevel = Depth.keyline(root, 3, WOOD_LIGHT)
	bevel.Transparency = 0.35

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
	local PASS_Y = 0.905
	local PASS_H = if phone then 0.14 else 0.125

	-- Caption plank with the golden egg pointer over the reel's centre.
	local top = plank(root, "TopPlank", UDim2.fromScale(REEL_X, 0.018), UDim2.fromScale(REEL_W, 0.082), 2)
	Fit.text(top, "CaptionLeft", "SPIN FOR A NEW CLASS!", {
		font = Tokens.typography.label.font,
		color = PAPER,
		max = 18,
		zIndex = 3,
		size = UDim2.fromScale(0.36, 0.6),
		position = UDim2.fromScale(0.07, 0.2),
		align = Enum.TextXAlignment.Left,
	})
	Fit.text(top, "CaptionRight", "EVERY FORAGER STARTS SOMEWHERE!", {
		font = Tokens.typography.label.font,
		color = PAPER,
		max = 18,
		zIndex = 3,
		size = UDim2.fromScale(0.4, 0.6),
		position = UDim2.fromScale(0.93, 0.2),
		anchor = Vector2.new(1, 0),
		align = Enum.TextXAlignment.Right,
	})
	leaf(top, "LeafLeft", UDim2.fromScale(0.035, 0.5), 0.72, 3, -10, true)
	leaf(top, "LeafRight", UDim2.fromScale(0.965, 0.5), 0.72, 3, 10, false)
	local pointer = Fit.frame(root, "Pointer", UDim2.fromScale(REEL_CX, 0.0), UDim2.fromScale(0, 0.2), 9, Vector2.new(0.5, 0))
	Fit.aspect(pointer, 0.7, Enum.DominantAxis.Height)
	local pointerGlow = Instance.new("Frame")
	pointerGlow.Name = "Glow"
	pointerGlow.AnchorPoint = Vector2.new(0.5, 0.5)
	pointerGlow.Position = UDim2.fromScale(0.5, 0.36)
	pointerGlow.Size = UDim2.fromScale(1.7, 0.95)
	pointerGlow.BackgroundColor3 = Tokens.color.goldLight
	pointerGlow.BackgroundTransparency = 0.55
	pointerGlow.BorderSizePixel = 0
	pointerGlow.ZIndex = 1
	Fit.corner(pointerGlow, 0.5)
	local pointerFade = Instance.new("UIGradient")
	pointerFade.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.5, 0),
		NumberSequenceKeypoint.new(1, 1),
	})
	pointerFade.Parent = pointerGlow
	pointerGlow.Parent = pointer
	local eggBox = { size = UDim2.fromScale(1.1, 0.68), position = UDim2.fromScale(0.5, 0.34), zIndex = 2, name = "Egg" }
	local egg = Fit.image(pointer, "forge.egg", eggBox) or Fit.image(pointer, "icon.egg", eggBox)
	if not egg then
		local glyph = Icons.egg(pointer, 10, { zIndex = 2, color = Tokens.color.gold })
		glyph.AnchorPoint = Vector2.new(0.5, 0.5)
		glyph.Position = UDim2.fromScale(0.5, 0.34)
		glyph.Size = UDim2.fromScale(1, 0.62)
	end
	local arrowDown = Fit.text(pointer, "Arrow", "▼", {
		font = Tokens.typography.display.font,
		color = Tokens.color.gold,
		max = 44,
		outline = 2,
		outlineColor = WOOD_DEEP,
		zIndex = 2,
		size = UDim2.fromScale(1, 0.4),
		position = UDim2.fromScale(0.5, 0.8),
		anchor = Vector2.new(0.5, 0.5),
	})

	-- Reel: the forge's display window. Warm barrel interior, curved lintel, gold trim, staves, a
	-- lit centre and a hay bed with tufts and stray feathers.
	local reelFrame = Instance.new("Frame")
	reelFrame.Name = "ReelFrame"
	reelFrame.Position = UDim2.fromScale(REEL_X - 0.012, REEL_Y - 0.02)
	reelFrame.Size = UDim2.fromScale(REEL_W + 0.024, REEL_H + 0.04)
	reelFrame.BorderSizePixel = 0
	reelFrame.ZIndex = 2
	Depth.panel(reelFrame, WOOD_DEEP, { radius = Tokens.radius.xl, rim = Tokens.color.gold })
	Fit.corner(reelFrame, 0.09)
	local trim = Depth.keylineOf(reelFrame)
	if trim then
		trim.Color = Tokens.color.goldDeep
		trim.Thickness = 3
	end
	reelFrame.Parent = root
	local reel = Instance.new("Frame")
	reel.Name = "Reel"
	reel.Position = UDim2.fromScale(REEL_X, REEL_Y)
	reel.Size = UDim2.fromScale(REEL_W, REEL_H)
	reel.BorderSizePixel = 0
	reel.ZIndex = 3
	reel.ClipsDescendants = true
	reel.BackgroundColor3 = BARREL
	Fit.corner(reel, 0.08)
	reel.Parent = root
	local barrelGradient = Instance.new("UIGradient")
	barrelGradient.Rotation = 0
	barrelGradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, BARREL_DEEP),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(150, 98, 52)),
		ColorSequenceKeypoint.new(1, BARREL_DEEP),
	})
	barrelGradient.Parent = reel
	for index = 1, 7 do
		local stave = Instance.new("Frame")
		stave.Name = "Stave" .. index
		stave.Position = UDim2.fromScale(index / 8, 0)
		stave.Size = UDim2.fromScale(0.004, 1)
		stave.BackgroundColor3 = BARREL_DEEP
		stave.BackgroundTransparency = 0.45
		stave.BorderSizePixel = 0
		stave.ZIndex = 1
		stave.Parent = reel
	end
	local lantern = Instance.new("Frame")
	lantern.Name = "Lantern"
	lantern.AnchorPoint = Vector2.new(0.5, 0.5)
	lantern.Position = UDim2.fromScale(0.5, 0.5)
	lantern.Size = UDim2.fromScale(0.42, 1.2)
	lantern.BackgroundColor3 = Color3.fromRGB(255, 214, 120)
	lantern.BackgroundTransparency = 0.55
	lantern.BorderSizePixel = 0
	lantern.ZIndex = 2
	Fit.corner(lantern, 0.5)
	local lanternFade = Instance.new("UIGradient")
	lanternFade.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.5, 0),
		NumberSequenceKeypoint.new(1, 1),
	})
	lanternFade.Parent = lantern
	lantern.Parent = reel
	local rays = Skin.texture(reel, "texture.rays", { transparency = 0.82, name = "Rays", zIndex = 2 })
	if rays then
		rays.AnchorPoint = Vector2.new(0.5, 0.5)
		rays.Position = UDim2.fromScale(0.5, 0.5)
		rays.Size = UDim2.fromScale(0.7, 1.6)
		rays.ImageColor3 = Tokens.color.goldLight
	end
	local lintel = Instance.new("Frame")
	lintel.Name = "Lintel"
	lintel.Size = UDim2.fromScale(1, 0.09)
	lintel.BackgroundColor3 = WOOD_DEEP
	lintel.BackgroundTransparency = 0.15
	lintel.BorderSizePixel = 0
	lintel.ZIndex = 4
	local lintelFade = Instance.new("UIGradient")
	lintelFade.Rotation = 90
	lintelFade.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 1) })
	lintelFade.Parent = lintel
	lintel.Parent = reel
	-- Hay bed.
	local hay = Instance.new("Frame")
	hay.Name = "Hay"
	hay.Position = UDim2.fromScale(0, 0.86)
	hay.Size = UDim2.fromScale(1, 0.14)
	hay.BackgroundColor3 = STRAW
	hay.BorderSizePixel = 0
	hay.ZIndex = 4
	local hayFade = Instance.new("UIGradient")
	hayFade.Rotation = 90
	hayFade.Color = ColorSequence.new({ ColorSequenceKeypoint.new(0, STRAW), ColorSequenceKeypoint.new(1, STRAW_DEEP) })
	hayFade.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.35), NumberSequenceKeypoint.new(1, 0) })
	hayFade.Parent = hay
	hay.Parent = reel
	for index = 1, 26 do
		local strand = Instance.new("Frame")
		strand.Name = "Straw" .. index
		strand.AnchorPoint = Vector2.new(0.5, 1)
		strand.Position = UDim2.fromScale((index - 0.5) / 26 + ((index % 3) - 1) * 0.008, 0.97 + (index % 2) * 0.02)
		strand.Size = UDim2.fromScale(0.006, 0.09 + (index % 4) * 0.02)
		strand.Rotation = ((index * 53) % 70) - 35
		strand.BackgroundColor3 = if index % 2 == 0 then Color3.fromRGB(252, 226, 140) else STRAW_DEEP
		strand.BackgroundTransparency = 0.15
		strand.BorderSizePixel = 0
		strand.ZIndex = 4
		Fit.corner(strand, 0.5)
		strand.Parent = reel
	end
	for index, spot in ipairs({ { 0.08, 0.93 }, { 0.5, 0.95 }, { 0.9, 0.92 } }) do
		local feather = Fit.image(reel, "icon.feather", {
			size = UDim2.fromScale(0, 0.09),
			position = UDim2.fromScale(spot[1], spot[2]),
			zIndex = 5,
			name = "HayFeather" .. index,
		})
		if feather then
			Fit.aspect(feather, 1, Enum.DominantAxis.Height)
			feather.Rotation = -20 + index * 25
		end
	end
	-- Leaves on the frame corners.
	leaf(root, "CornerLeafLeft", UDim2.fromScale(REEL_X - 0.005, REEL_Y - 0.005), 0.075, 9, -25, true)
	leaf(root, "CornerLeafRight", UDim2.fromScale(REEL_X + REEL_W + 0.005, REEL_Y - 0.005), 0.075, 9, 25, false)

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
				-- Edge light: the chosen card burns bright, the rest keep a soft rarity rim.
				local lit = math.clamp(1 - distance, 0, 1)
				view.edge.Thickness = 2 + lit * 3
				view.edge.Transparency = 0.45 - lit * 0.4
			end
		end
	end

	-- Arrows: wooden tabs riding the frame's edges.
	local function arrow(name: string, x: number, glyph: string, step: number): TextButton
		local button = Instance.new("TextButton")
		button.Name = name
		button.Text = ""
		button.AutoButtonColor = false
		button.AnchorPoint = Vector2.new(0.5, 0.5)
		button.Position = UDim2.fromScale(x, REEL_Y + REEL_H / 2)
		button.Size = UDim2.fromScale(0, 0.115)
		button.BackgroundColor3 = WOOD_DEEP
		button.BorderSizePixel = 0
		button.ZIndex = 10
		button.Selectable = true
		Fit.aspect(button, 0.78, Enum.DominantAxis.Height)
		local minSize = Instance.new("UISizeConstraint")
		minSize.MinSize = Vector2.new(tap, tap)
		minSize.Parent = button
		relax(button)
		Fit.corner(button, 0.3)
		Depth.keyline(button, 2, Tokens.color.goldDeep)
		local face = Instance.new("Frame")
		face.Name = "Face"
		face.Size = UDim2.fromScale(1, 0.9)
		face.BackgroundColor3 = Tokens.color.gold
		face.BorderSizePixel = 0
		face.ZIndex = 2
		Fit.corner(face, 0.3)
		Depth.applySheen(face, Tokens.color.gold, Tokens.color.goldLight)
		Depth.rim(face, Tokens.color.gold)
		face.Parent = button
		Fit.text(face, "Glyph", glyph, {
			font = Tokens.typography.display.font,
			color = WOOD_DEEP,
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

	-- Equipped board: a wooden board hanging from two ropes ----------------------------------
	local right = Fit.frame(root, "Equipped", UDim2.fromScale(RIGHT_X, 0.0), UDim2.fromScale(0.985 - RIGHT_X, 0.76), 3)
	for index, x in ipairs({ 0.22, 0.78 }) do
		local rope = Instance.new("Frame")
		rope.Name = "Rope" .. index
		rope.AnchorPoint = Vector2.new(0.5, 0)
		rope.Position = UDim2.fromScale(x, 0)
		rope.Size = UDim2.fromScale(0.03, 0.06)
		rope.BackgroundColor3 = STRAW_DEEP
		rope.BorderSizePixel = 0
		rope.ZIndex = 2
		Fit.corner(rope, 0.5)
		rope.Parent = right
	end
	local rightHead = plank(right, "Head", UDim2.fromScale(0, 0.05), UDim2.fromScale(1, 0.105), 3, WOOD_DEEP)
	local headLine = Depth.keylineOf(rightHead)
	if headLine then
		headLine.Color = Tokens.color.goldDeep
	end
	Fit.text(rightHead, "Title", "EQUIPPED CLASSES", {
		font = Tokens.typography.label.font,
		color = Tokens.color.goldLight,
		max = 20,
		zIndex = 4,
		outline = 1.5,
		outlineColor = WOOD_DEEP,
		size = UDim2.fromScale(0.9, 0.62),
		position = UDim2.fromScale(0.5, 0.5),
		anchor = Vector2.new(0.5, 0.5),
	})
	local rightBody = Instance.new("Frame")
	rightBody.Name = "Body"
	rightBody.Position = UDim2.fromScale(0, 0.165)
	rightBody.Size = UDim2.fromScale(1, 0.835)
	rightBody.BorderSizePixel = 0
	rightBody.ZIndex = 2
	Depth.panel(rightBody, WOOD, { radius = Tokens.radius.md, rim = WOOD_LIGHT })
	Fit.corner(rightBody, 0.06)
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
			color = PAPER,
			max = 16,
			zIndex = 3,
			outline = 1.2,
			outlineColor = WOOD_DEEP,
			size = UDim2.fromScale(0.9, slotHeight * 0.14),
			position = UDim2.fromScale(0.5, slotTop),
			anchor = Vector2.new(0.5, 0),
		})
		local frame = Instance.new("Frame")
		frame.Name = "Slot" .. index
		frame.Position = UDim2.fromScale(0.07, slotTop + slotHeight * 0.16)
		frame.Size = UDim2.fromScale(0.86, slotHeight * 0.82)
		frame.BorderSizePixel = 0
		frame.ZIndex = 3
		Depth.panel(frame, PAPER, { radius = Tokens.radius.md, rim = Color3.new(1, 1, 1) })
		Fit.corner(frame, 0.08)
		local line = Depth.keylineOf(frame) or Depth.keyline(frame)
		line.Color = WOOD_DEEP
		line.Thickness = 2
		frame.Parent = rightBody
		local artBox = Fit.frame(frame, "ArtBox", UDim2.fromScale(0.5, 0.3), UDim2.fromScale(0.5, 0.42), 4, Vector2.new(0.5, 0.5))
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
		lock.Position = UDim2.fromScale(0.5, 0.28)
		lock.Size = UDim2.fromScale(0, 0.3)
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
			size = UDim2.fromScale(0.88, 0.42),
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

	-- SPIN: the one irresistible button. Gold-orange face, inner highlight, glow behind it.
	local spinGlow = Instance.new("Frame")
	spinGlow.Name = "SpinGlow"
	spinGlow.AnchorPoint = Vector2.new(0.5, 0.5)
	spinGlow.Position = UDim2.fromScale(REEL_CX, SPIN_Y)
	spinGlow.Size = UDim2.fromScale(0.48, SPIN_H * 1.7)
	spinGlow.BackgroundColor3 = Tokens.color.goldLight
	spinGlow.BackgroundTransparency = 0.6
	spinGlow.BorderSizePixel = 0
	spinGlow.ZIndex = 3
	Fit.corner(spinGlow, 0.5)
	local spinGlowFade = Instance.new("UIGradient")
	spinGlowFade.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.5, 0),
		NumberSequenceKeypoint.new(1, 1),
	})
	spinGlowFade.Parent = spinGlow
	spinGlow.Parent = root
	local rollHandle = Button.build(root, {
		text = string.format("SPIN  -  %d GEMS", cfg.classes.rollGemCost),
		variant = "primary",
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
		local pad = rollLabel:FindFirstChildOfClass("UIPadding")
		if pad then
			pad.PaddingLeft = UDim.new(0.17, 0)
			pad.PaddingRight = UDim.new(0.04, 0)
		end
	end
	local rollFace = rollHandle.button:FindFirstChild("Face")
	if rollFace and rollFace:IsA("Frame") then
		local faceGradient = rollFace:FindFirstChildOfClass("UIGradient")
		if faceGradient then
			faceGradient.Rotation = 90
			faceGradient.Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 226, 120)),
				ColorSequenceKeypoint.new(0.45, Color3.fromRGB(255, 176, 48)),
				ColorSequenceKeypoint.new(1, Color3.fromRGB(240, 128, 28)),
			})
		end
		local highlight = Instance.new("Frame")
		highlight.Name = "Highlight"
		highlight.Position = UDim2.fromScale(0.03, 0.06)
		highlight.Size = UDim2.fromScale(0.94, 0.34)
		highlight.BackgroundColor3 = Color3.new(1, 1, 1)
		highlight.BackgroundTransparency = 0.72
		highlight.BorderSizePixel = 0
		highlight.ZIndex = rollFace.ZIndex + 1
		Fit.corner(highlight, 0.5)
		highlight.Parent = rollFace
		local gemIcon = Fit.image(rollFace, "hud.gem", {
			size = UDim2.fromScale(0, 0.74),
			position = UDim2.fromScale(0.1, 0.5),
			zIndex = rollFace.ZIndex + 6,
			name = "Gem",
		})
		if gemIcon then
			Fit.aspect(gemIcon, 1, Enum.DominantAxis.Height)
		end
	end
	table.insert(cleanups, rollHandle.destroy)
	rollHandle.pulse(true)

	local toggles =
		Fit.frame(root, "Toggles", UDim2.fromScale(REEL_CX, TOGGLE_Y), UDim2.fromScale(0.36, TOGGLE_H), 4, Vector2.new(0.5, 0.5))
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
		local label = Fit.buttonText(handle, 18)
		if label then
			local pad = label:FindFirstChildOfClass("UIPadding")
			if pad then
				pad.PaddingLeft = UDim.new(0.27, 0)
				pad.PaddingRight = UDim.new(0.05, 0)
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
		relax(handle.button)
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
			size = UDim2.fromScale(0.15, PASS_H),
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
		handle.button.Position = UDim2.fromScale(x, PASS_Y)
		relax(handle.button)
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
	passButton("LuckPass", "doubleLuck", "2× LUCK", "doubleLuckRobux", "success", 0.095, "star")
	passButton("FastPass", "fastRolls", "FAST ROLLS", "fastRollsRobux", "teal", 0.9, "flame")

	-- CLASS INFO drawer ----------------------------------------------------------------------------
	local infoTab = Instance.new("TextButton")
	infoTab.Name = "InfoTab"
	infoTab.Text = ""
	infoTab.AutoButtonColor = false
	infoTab.AnchorPoint = Vector2.new(0.5, 0.5)
	infoTab.Position = UDim2.fromScale(REEL_X + REEL_W - 0.028, REEL_Y + 0.045)
	infoTab.Size = UDim2.fromScale(0, 0.085)
	infoTab.BackgroundColor3 = WOOD_DEEP
	infoTab.BorderSizePixel = 0
	infoTab.ZIndex = 11
	infoTab.Selectable = true
	Fit.aspect(infoTab, 1, Enum.DominantAxis.Height)
	local infoMin = Instance.new("UISizeConstraint")
	infoMin.MinSize = Vector2.new(tap, tap)
	infoMin.Parent = infoTab
	relax(infoTab)
	Fit.corner(infoTab, 0.5)
	Depth.keyline(infoTab, 2, Tokens.color.goldDeep)
	local infoFace = Instance.new("Frame")
	infoFace.Name = "Face"
	infoFace.Size = UDim2.fromScale(1, 0.9)
	infoFace.BackgroundColor3 = Tokens.color.goldLight
	infoFace.BorderSizePixel = 0
	infoFace.ZIndex = 2
	Fit.corner(infoFace, 0.5)
	Depth.applySheen(infoFace, Tokens.color.goldLight)
	infoFace.Parent = infoTab
	Fit.text(infoFace, "Glyph", "i", {
		font = Tokens.typography.display.font,
		color = WOOD_DEEP,
		max = 30,
		zIndex = 3,
		size = UDim2.fromScale(0.7, 0.72),
		position = UDim2.fromScale(0.5, 0.48),
		anchor = Vector2.new(0.5, 0.5),
	})
	local infoTabScale = Instance.new("UIScale")
	infoTabScale.Parent = infoTab
	infoTab.Parent = root
	local infoHint = Fit.text(root, "InfoHint", "CLASS INFO", {
		font = Tokens.typography.label.font,
		color = Tokens.color.goldLight,
		max = 14,
		outline = 1.2,
		outlineColor = WOOD_DEEP,
		zIndex = 11,
		size = UDim2.fromScale(0.1, 0.035),
		position = UDim2.fromScale(REEL_X + REEL_W - 0.06, REEL_Y + 0.045),
		anchor = Vector2.new(1, 0.5),
		align = Enum.TextXAlignment.Right,
	})
	infoHint.TextTransparency = 0.15

	local DRAWER_X = 0.36
	local drawer = Instance.new("Frame")
	drawer.Name = "InfoDrawer"
	drawer.Position = UDim2.fromScale(1.02, 0.01)
	drawer.Size = UDim2.fromScale(1 - DRAWER_X - 0.01, 0.98)
	drawer.BorderSizePixel = 0
	drawer.ZIndex = 12
	drawer.Visible = false
	Depth.panel(drawer, WOOD_DEEP, { radius = Tokens.radius.xl, rim = Tokens.color.gold })
	Fit.corner(drawer, 0.04)
	drawer.Parent = root
	local drawerPage = Instance.new("Frame")
	drawerPage.Name = "Page"
	drawerPage.Position = UDim2.fromScale(0.02, 0.03)
	drawerPage.Size = UDim2.fromScale(0.96, 0.94)
	drawerPage.BorderSizePixel = 0
	drawerPage.ZIndex = 1
	Depth.panel(drawerPage, PAPER, { radius = Tokens.radius.lg, rim = Color3.new(1, 1, 1) })
	Fit.corner(drawerPage, 0.035)
	drawerPage.Parent = drawer
	local drawerTitle = plank(drawerPage, "Title", UDim2.fromScale(0.5, 0.06), UDim2.fromScale(0.5, 0.1), 2)
	drawerTitle.AnchorPoint = Vector2.new(0.5, 0.5)
	Fit.text(drawerTitle, "Text", "CLASS INFO", {
		font = Tokens.typography.title.font,
		color = Tokens.color.goldLight,
		max = 24,
		outline = 1.5,
		outlineColor = WOOD_DEEP,
		zIndex = 3,
		size = UDim2.fromScale(0.8, 0.7),
		position = UDim2.fromScale(0.5, 0.5),
		anchor = Vector2.new(0.5, 0.5),
	})
	Fit.text(drawerPage, "Sub", "EVERY CLASS THE FORGE CAN ROLL, WITH ITS EXACT ODDS AND BONUSES", {
		font = Tokens.typography.caption.font,
		color = WOOD,
		max = 13,
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
	Fit.corner(drawerClose, 0.5)
	Depth.keyline(drawerClose)
	local drawerCloseFace = Instance.new("Frame")
	drawerCloseFace.Name = "Face"
	drawerCloseFace.Size = UDim2.fromScale(1, 0.9)
	drawerCloseFace.BackgroundColor3 = Tokens.color.ember
	drawerCloseFace.BorderSizePixel = 0
	drawerCloseFace.ZIndex = 2
	Fit.corner(drawerCloseFace, 0.5)
	Depth.applySheen(drawerCloseFace, Tokens.color.ember)
	drawerCloseFace.Parent = drawerClose
	local cross = Icons.close(drawerCloseFace, 10, { color = Tokens.color.featherWhite, zIndex = 3 })
	cross.AnchorPoint = Vector2.new(0.5, 0.5)
	cross.Position = UDim2.fromScale(0.5, 0.5)
	cross.Size = UDim2.fromScale(0.46, 0.46)
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
		local tile = Instance.new("Frame")
		tile.Name = "Tile_" .. entry.id
		tile.Position = UDim2.fromScale(col / columns + 0.005, row * 0.51)
		tile.Size = UDim2.fromScale(1 / columns - 0.01, 0.48)
		tile.BorderSizePixel = 0
		tile.ZIndex = 2
		Depth.panel(tile, colors.fill, { radius = Tokens.radius.md, rim = Color3.new(1, 1, 1) })
		Fit.corner(tile, 0.1)
		local line = Depth.keylineOf(tile) or Depth.keyline(tile)
		line.Color = colors.deep
		line.Thickness = 2
		tile.Parent = grid
		if entryTier == "mythic" then
			local gradient = Instance.new("UIGradient")
			gradient.Color = RAINBOW
			gradient.Parent = line
			table.insert(animated, { gradient = gradient, speed = 90 })
		end
		local tileArt = Fit.frame(tile, "ArtBox", UDim2.fromScale(0.5, 0.36), UDim2.fromScale(0.7, 0.56), 3, Vector2.new(0.5, 0.5))
		classArt(tileArt, entry, 3)
		Fit.text(tile, "Name", string.upper(entry.displayName), {
			font = Tokens.typography.label.font,
			color = Tokens.color.featherWhite,
			max = 15,
			min = 5,
			outline = 1.5,
			outlineColor = colors.deep,
			zIndex = 4,
			size = UDim2.fromScale(0.94, 0.15),
			position = UDim2.fromScale(0.5, 0.71),
			anchor = Vector2.new(0.5, 0.5),
		})
		local tileOdds = Fit.text(tile, "Odds", "", {
			font = Tokens.typography.display.font,
			color = Tokens.color.featherWhite,
			max = 16,
			min = 5,
			outline = 1.5,
			outlineColor = colors.deep,
			zIndex = 4,
			size = UDim2.fromScale(0.9, 0.16),
			position = UDim2.fromScale(0.5, 0.87),
			anchor = Vector2.new(0.5, 0.5),
		})
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
	local breakdown = Instance.new("Frame")
	breakdown.Name = "Breakdown"
	breakdown.Position = UDim2.fromScale(0.03, 0.69)
	breakdown.Size = UDim2.fromScale(0.94, 0.29)
	breakdown.BorderSizePixel = 0
	breakdown.ZIndex = 2
	Depth.panel(breakdown, PARCHMENT, { radius = Tokens.radius.md, rim = Color3.new(1, 1, 1) })
	Fit.corner(breakdown, 0.08)
	local breakdownLine = Depth.keylineOf(breakdown)
	if breakdownLine then
		breakdownLine.Color = WOOD
	end
	breakdown.Parent = drawerPage
	local breakdownArt = Fit.frame(breakdown, "ArtBox", UDim2.fromScale(0.09, 0.5), UDim2.fromScale(0, 0.8), 3, Vector2.new(0.5, 0.5))
	Fit.aspect(breakdownArt, 1, Enum.DominantAxis.Height)
	local breakdownName = Fit.text(breakdown, "Name", "", {
		font = Tokens.typography.title.font,
		color = Tokens.color.inkStrong,
		max = 24,
		zIndex = 3,
		size = UDim2.fromScale(0.5, 0.26),
		position = UDim2.fromScale(0.19, 0.06),
		align = Enum.TextXAlignment.Left,
	})
	local breakdownRarity = Instance.new("Frame")
	breakdownRarity.Name = "Rarity"
	breakdownRarity.AnchorPoint = Vector2.new(1, 0)
	breakdownRarity.Position = UDim2.fromScale(0.97, 0.08)
	breakdownRarity.Size = UDim2.fromScale(0.26, 0.22)
	breakdownRarity.BorderSizePixel = 0
	breakdownRarity.ZIndex = 3
	Fit.corner(breakdownRarity, 0.5)
	local breakdownRarityText = Fit.text(breakdownRarity, "Label", "", {
		font = Tokens.typography.label.font,
		color = Tokens.color.featherWhite,
		max = 14,
		zIndex = 4,
		size = UDim2.fromScale(0.9, 0.76),
		position = UDim2.fromScale(0.5, 0.5),
		anchor = Vector2.new(0.5, 0.5),
	})
	breakdownRarity.Parent = breakdown
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
	breakdownScroll.ScrollBarImageColor3 = WOOD
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
	breakdownLines.TextColor3 = Tokens.color.inkStrong
	breakdownLines.TextWrapped = true
	breakdownLines.TextXAlignment = Enum.TextXAlignment.Left
	breakdownLines.TextYAlignment = Enum.TextYAlignment.Top
	breakdownLines.ZIndex = 3
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
			tile.line.Thickness = if selected then 4 else 2
			local tileTier = tierFor(weights[tile.index])
			if tileTier ~= "mythic" then
				tile.line.Color = if selected then Tokens.color.goldLight else colorsFor(tileTier).deep
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
		local text = "• " .. table.concat(lines, "\n• ")
		if owned then
			text ..= "\n✓ OWNED"
		end
		breakdownLines.Text = text
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
			Tween.scale(infoTabScale, "hover", motion, 1.1)
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

	-- Drifting feathers over the scene.
	local drifters: { { image: ImageLabel, x: number, y: number, speed: number, phase: number } } = {}
	if not motion.reducedMotion then
		for index = 1, 5 do
			local image = Fit.image(root, "icon.feather", {
				size = UDim2.fromScale(0, 0.06),
				position = UDim2.fromScale((index * 0.19) % 1, (index * 0.23) % 1),
				zIndex = 2,
				name = "Drift" .. index,
				transparency = 0.35,
			})
			if image then
				Fit.aspect(image, 1, Enum.DominantAxis.Height)
				table.insert(drifters, {
					image = image,
					x = (index * 0.19) % 1,
					y = (index * 0.23) % 1,
					speed = 0.018 + index * 0.004,
					phase = index * 1.3,
				})
			end
		end
	end

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
			view.line.Color = if active then Tokens.color.gold else WOOD_DEEP
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
		local overlay = Instance.new("Frame")
		overlay.Name = "Result"
		overlay.Size = UDim2.fromScale(1, 1)
		overlay.BackgroundColor3 = Color3.fromRGB(46, 30, 16)
		overlay.BackgroundTransparency = 0.25
		overlay.BorderSizePixel = 0
		overlay.ZIndex = 5
		overlay.ClipsDescendants = true
		Fit.corner(overlay, 0.03)
		overlay.Parent = shell.card
		shell.plaque.Visible = false
		-- The controls under the overlay rest while the result is up.
		toggles.Visible = false
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

		local title = Fit.text(overlay, "Title", string.upper(RARITY_LABEL[entryTier] or entryTier) .. " CLASS!", {
			font = Tokens.typography.display.font,
			color = Tokens.color.goldLight,
			max = 66,
			outline = 3,
			outlineColor = WOOD_DEEP,
			zIndex = 4,
			size = UDim2.fromScale(0.42, 0.13),
			position = UDim2.fromScale(0.47, 0.08),
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
		local sub = plank(overlay, "Sub", UDim2.fromScale(0.5, 0.185), UDim2.fromScale(0.4, 0.07), 4)
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
				size = UDim2.fromScale(0.72, 0.7),
				position = UDim2.fromScale(0.5, 0.5),
				anchor = Vector2.new(0.5, 0.5),
			}
		)
		Fit.image(sub, "modal.leaf.left", { size = UDim2.fromScale(0.07, 0.7), position = UDim2.fromScale(0.05, 0.5), zIndex = 5 })
		Fit.image(sub, "modal.leaf.right", { size = UDim2.fromScale(0.07, 0.7), position = UDim2.fromScale(0.95, 0.5), zIndex = 5 })
		local sparkles: { Frame } = {}
		for index, spot in ipairs({ { 0.26, 0.36 }, { 0.74, 0.34 }, { 0.27, 0.66 }, { 0.73, 0.68 }, { 0.34, 0.5 }, { 0.66, 0.52 } }) do
			local star = Icons.star(overlay, 10, { zIndex = 4, color = Tokens.color.goldLight })
			star.Name = "Sparkle" .. index
			star.AnchorPoint = Vector2.new(0.5, 0.5)
			star.Position = UDim2.fromScale(spot[1], spot[2])
			star.Size = UDim2.fromScale(0, 0.03 + (index % 3) * 0.008)
			Fit.aspect(star, 1, Enum.DominantAxis.Height)
			table.insert(sparkles, star)
		end

		local holder = Fit.frame(overlay, "CardHolder", UDim2.fromScale(0.5, 0.5), UDim2.fromScale(0, 0.5), 5, Vector2.new(0.5, 0.5))
		Fit.aspect(holder, CARD_ASPECT, Enum.DominantAxis.Height)
		local card = buildCard(holder, entry, entryTier, 1)
		card.root.Position = UDim2.fromScale(0.5, 0.5)
		card.root.Size = UDim2.fromScale(0, 1)
		card.odds.Text = percent(result.percent or (entry.weight / 100))
		card.hit:Destroy()
		card.edge.Thickness = 5
		card.edge.Transparency = 0.05
		card.scale.Scale = 0.2
		Tween.scale(card.scale, "release", motion, 1)
		if card.rainbow then
			table.insert(animated, { gradient = card.rainbow, speed = 90 })
		end

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

		local done = false
		local function finish()
			if done then
				return
			end
			done = true
			currentResult = nil
			shell.plaque.Visible = true
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
		local actions = Fit.frame(overlay, "Actions", UDim2.fromScale(0.5, 0.925), UDim2.fromScale(0.56, 0.1), 5, Vector2.new(0.5, 0.5))
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
	-- Life: rainbow rims turn, the lantern breathes, the egg bobs, the chosen card breathes, a
	-- shimmer sweeps a card now and then, feathers drift.
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
			lantern.BackgroundTransparency = 0.55 + 0.1 * math.sin(now * 1.6)
			warmGlow.BackgroundTransparency = 0.72 + 0.06 * math.sin(now * 0.9)
			if rays then
				rays.Rotation = math.sin(now * 0.5) * 4
			end
			pointer.Position = UDim2.fromScale(REEL_CX, math.sin(now * 3) * 0.006)
			pointerGlow.BackgroundTransparency = 0.5 + 0.2 * math.sin(now * 2)
			arrowDown.TextTransparency = 0.1 + 0.1 * math.sin(now * 4)
			spinGlow.BackgroundTransparency = 0.6 + 0.15 * math.sin(now * 2.2)
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
			for _, drifter in ipairs(drifters) do
				drifter.y += dt * drifter.speed
				if drifter.y > 1.05 then
					drifter.y = -0.08
					drifter.x = (drifter.x + 0.37) % 1
				end
				local sway = math.sin(now * 1.2 + drifter.phase) * 0.02
				drifter.image.Position = UDim2.fromScale(drifter.x + sway, drifter.y)
				drifter.image.Rotation = math.sin(now * 0.8 + drifter.phase) * 25
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
