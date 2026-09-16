--!strict
-- The Class Forge. A wooden barrel stage with a card carousel in the middle (the chosen class large
-- under a golden egg pointer, its neighbours smaller either side), YOUR CLASSES on the left,
-- EQUIPPED CLASSES on the right, one SPIN button under the barrel with AUTO beside it and the
-- 2x Luck / Fast Rolls passes in the corners. A spin runs the carousel and slows onto the server's
-- committed class, then the result takes the whole frame: "<RARITY> CLASS!", the card cracking out
-- of a golden egg, the bonuses it grants, EQUIP NOW / KEEP CURRENT. Auto stops on request, on
-- insufficient Gems, on any refusal, and when the modal closes. Nothing here decides a roll.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local Depth = require(script.Parent.Parent.Components.Depth)
local ClassRoll = require(Shared.Domain.ClassRoll)
local Tween = require(script.Parent.Parent.Components.Tween)
local FrameKit = require(script.Parent.Parent.Components.Frame)
local Button = require(script.Parent.Parent.Components.Button)
local Skin = require(script.Parent.Parent.Components.Skin)
local Icons = require(script.Parent.Parent.Components.Icons)
local Confetti = require(script.Parent.Parent.Components.Confetti)
local SafeArea = require(script.Parent.Parent.SafeArea)
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
}

-- Art and a one-line story per class (falls back to the effect summary for unknown ids).
local CLASS_COPY: { [string]: { art: string, icon: string, story: string } } = {
	newcomer = { art = "icon.feather", icon = "feather", story = "No bonuses. Every forager starts somewhere." },
	nestCarrier = { art = "tool.hand.normal", icon = "star", story = "Carries a bigger bag: half again as many feathers." },
	eggTrader = { art = "icon.egg", icon = "egg", story = "Sells every feather for 20% more." },
	rakeExpert = { art = "tool.nestRake.normal", icon = "star", story = "Rakes deeper and pays 25% less for rake paths." },
	blastArtist = { art = "tool.confettiCharge.normal", icon = "star", story = "Wider blasts, and one in ten pulls sets off mini-charges." },
	gemSeeker = { art = "hud.gem", icon = "gem", story = "Finds Gems in the nest and the odd diamond feather." },
	automationExpert = {
		art = "tool.scoutChick.normal",
		icon = "egg",
		story = "Starts with a free Scout Chick that works faster and carries more.",
	},
	masterForager = { art = "station.classes.normal", icon = "star", story = "Every passive bonus at once, with golden rush moments." },
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
local MYTHIC_COLORS = { fill = Color3.fromRGB(58, 40, 72), deep = Color3.fromRGB(30, 20, 40) }

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

-- One line per effect with its exact number, in a stable order. "Every passive bonus" expands to
-- the passive bonuses of every other class so the 0.1 % card lists everything it grants.
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
		local count = effect.miniChargeCount or 0
		return string.format("%s chance a blast spawns %d mini-charges", percent(value), count)
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
		local count = effect.swarmCount or 0
		return string.format("%s chance per trip of %d helper chicks", percent(value), count)
	elseif key == "goldenRushChancePerMinute" then
		local seconds = effect.goldenRushSeconds or 0
		return string.format("%s chance each minute of a %ds Golden Rush", percent(value), seconds)
	end
	return nil
end

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
		-- Every other class's passive bonuses (multipliers and grants; class procs stay theirs).
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

local WOOD = Color3.fromRGB(150, 112, 66)
local WOOD_DEEP = Color3.fromRGB(104, 74, 42)
local WOOD_LIGHT = Color3.fromRGB(196, 150, 96)
local BARREL = Color3.fromRGB(88, 60, 34)
local BARREL_DEEP = Color3.fromRGB(58, 38, 22)
local PAPER = Color3.fromRGB(248, 238, 214)
local PARCHMENT = Color3.fromRGB(238, 224, 190)

-- A small wooden plaque with a title, for the side panels.
local function plaque(parent: GuiObject, name: string, text: string, z: number, height: number): Frame
	local plate = Instance.new("Frame")
	plate.Name = name
	plate.Size = UDim2.new(1, 0, 0, height)
	plate.ZIndex = z
	Depth.panel(plate, WOOD, { radius = Tokens.radius.md, rim = WOOD_LIGHT })
	local label = FrameKit.text(plate, "Text", text, "label", {
		zIndex = z + 1,
		color = Tokens.color.featherWhite,
		align = Enum.TextXAlignment.Center,
		size = UDim2.fromScale(1, 1),
	})
	label.TextScaled = true
	local cap = Instance.new("UITextSizeConstraint")
	cap.MaxTextSize = Tokens.typography.label.size
	cap.MinTextSize = 11
	cap.Parent = label
	FrameKit.outline(label, 2, WOOD_DEEP)
	plate.Parent = parent
	return plate
end

-- A parchment board for a side panel's contents.
local function board(parent: GuiObject, name: string, z: number): Frame
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.BackgroundColor3 = PARCHMENT
	frame.ZIndex = z
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, Tokens.radius.lg)
	corner.Parent = frame
	Depth.keyline(frame, Tokens.stroke.standard, WOOD_DEEP)
	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, Tokens.spacing.sm)
	padding.PaddingRight = UDim.new(0, Tokens.spacing.sm)
	padding.PaddingTop = UDim.new(0, Tokens.spacing.sm)
	padding.PaddingBottom = UDim.new(0, Tokens.spacing.sm)
	padding.Parent = frame
	frame.Parent = parent
	return frame
end

-- Class art: a painted card image if the owner has supplied one (role "class.card.<id>"), else the
-- icon the class has always used.
local function classArt(parent: GuiObject, entry: any, px: number, z: number): GuiObject
	local copy = CLASS_COPY[entry.id] or { art = "icon.feather", icon = "feather", story = "" }
	local painted = Skin.icon(parent, "class.card." .. entry.id, px, z)
	local glyph = painted or Skin.icon(parent, copy.art, px, z) or Icons.build(copy.icon, parent, px, { zIndex = z })
	glyph.AnchorPoint = Vector2.new(0.5, 0.5)
	glyph.Position = UDim2.fromScale(0.5, 0.5)
	return glyph
end

-- One class card: rarity face, art, name, odds, rarity pill. Used by the carousel and the result.
local function buildCard(
	parent: GuiObject,
	entry: any,
	tierName: string,
	z: number,
	animated: { any }
): { root: Frame, face: Frame, odds: TextLabel, name: TextLabel, scale: UIScale, pill: TextLabel, hit: TextButton }
	local rarity = colorsFor(tierName)
	local root = Instance.new("Frame")
	root.Name = "Card_" .. entry.id
	root.AnchorPoint = Vector2.new(0.5, 0.5)
	root.BackgroundColor3 = rarity.deep
	root.ZIndex = z
	local rootCorner = Instance.new("UICorner")
	rootCorner.CornerRadius = UDim.new(0, Tokens.radius.lg)
	rootCorner.Parent = root
	local outline = Depth.keyline(root, Tokens.stroke.bold, if tierName == "mythic" then Color3.new(1, 1, 1) else WOOD_DEEP)
	-- The pack's rarity frame, over the face. The mythic wears the legendary frame under a turning
	-- rainbow; without a painting the vector keyline (rainbow for the mythic) stands in.
	local frameRole = "class." .. (if tierName == "mythic" then "legendary" else tierName) .. ".owned"
	local packFrame = Skin.overlay(root, frameRole, { zIndex = z + 5, inset = 4, name = "PackFrame" })
	if packFrame then
		outline.Transparency = 1
		if tierName == "mythic" then
			local gradient = Instance.new("UIGradient")
			gradient.Color = RAINBOW
			gradient.Parent = packFrame
			table.insert(animated, { gradient = gradient, speed = 50 })
		end
	elseif tierName == "mythic" then
		outline.Thickness = Tokens.stroke.frame + 1
		local gradient = Instance.new("UIGradient")
		gradient.Color = RAINBOW
		gradient.Parent = outline
		table.insert(animated, { gradient = gradient, speed = 50 })
	end
	local scale = Instance.new("UIScale")
	scale.Parent = root
	local face = Instance.new("Frame")
	face.Name = "Face"
	face.AnchorPoint = Vector2.new(0.5, 0)
	face.Position = UDim2.new(0.5, 0, 0, 5)
	face.Size = UDim2.new(1, -10, 1, -12)
	face.BackgroundColor3 = rarity.fill
	face.BorderSizePixel = 0
	face.ZIndex = z + 1
	local faceCorner = Instance.new("UICorner")
	faceCorner.CornerRadius = UDim.new(0, Tokens.radius.md)
	faceCorner.Parent = face
	Depth.applySheen(face, rarity.fill)
	Depth.rim(face, rarity.fill)
	face.Parent = root
	-- Rivets in the corners (the painted frame has its own).
	for _, corner in ipairs(if packFrame then {} else { Vector2.new(0, 0), Vector2.new(1, 0), Vector2.new(0, 1), Vector2.new(1, 1) }) do
		local rivet = Instance.new("Frame")
		rivet.Name = "Rivet"
		rivet.AnchorPoint = Vector2.new(0.5, 0.5)
		rivet.Position = UDim2.new(corner.X, if corner.X == 0 then 9 else -9, corner.Y, if corner.Y == 0 then 9 else -9)
		rivet.Size = UDim2.fromOffset(7, 7)
		rivet.BackgroundColor3 = Tokens.color.goldLight
		rivet.ZIndex = z + 4
		local rivetCorner = Instance.new("UICorner")
		rivetCorner.CornerRadius = UDim.new(1, 0)
		rivetCorner.Parent = rivet
		rivet.Parent = face
	end
	-- Sunburst behind the art, then the art.
	local artHolder = Instance.new("Frame")
	artHolder.Name = "Art"
	artHolder.AnchorPoint = Vector2.new(0.5, 0)
	artHolder.Position = UDim2.fromScale(0.5, 0.06)
	artHolder.Size = UDim2.fromScale(0.78, 0.5)
	artHolder.BackgroundTransparency = 1
	artHolder.ZIndex = z + 2
	local artRatio = Instance.new("UIAspectRatioConstraint")
	artRatio.Parent = artHolder
	artHolder.Parent = face
	Skin.texture(artHolder, "texture.sunburst", { zIndex = z + 2, transparency = 0.6, color = Tokens.color.featherWhite })
	local art = classArt(artHolder, entry, 200, z + 3)
	art.Size = UDim2.fromScale(0.86, 0.86)
	local name = FrameKit.text(face, "Name", string.upper(entry.displayName), "label", {
		zIndex = z + 3,
		color = Tokens.color.featherWhite,
		align = Enum.TextXAlignment.Center,
		wrap = true,
	})
	name.Position = UDim2.fromScale(0.04, 0.58)
	name.Size = UDim2.fromScale(0.92, 0.14)
	name.TextScaled = true
	FrameKit.outline(name, 2.5, WOOD_DEEP)
	local odds = FrameKit.text(face, "Odds", "", "display", {
		zIndex = z + 3,
		color = Tokens.color.featherWhite,
		align = Enum.TextXAlignment.Center,
	})
	odds.Position = UDim2.fromScale(0, 0.72)
	odds.Size = UDim2.fromScale(1, 0.14)
	odds.TextScaled = true
	FrameKit.outline(odds, 3, WOOD_DEEP)
	local pill = FrameKit.badge(face, "Rarity", string.upper(RARITY_LABEL[tierName] or tierName), rarity.deep, z + 4)
	pill.AnchorPoint = Vector2.new(0.5, 1)
	pill.Position = UDim2.new(0.5, 0, 1, -8)
	pill.TextSize = Tokens.typography.caption.size
	if tierName == "mythic" then
		pill.BackgroundColor3 = Color3.fromRGB(70, 40, 110)
		local pillGradient = Instance.new("UIGradient")
		pillGradient.Color = RAINBOW
		pillGradient.Parent = pill
		table.insert(animated, { gradient = pillGradient, speed = 40 })
	end
	local hit = Instance.new("TextButton")
	hit.Name = "Hit"
	hit.Text = ""
	hit.BackgroundTransparency = 1
	hit.Size = UDim2.fromScale(1, 1)
	hit.ZIndex = z + 7
	hit.Parent = root
	root.Parent = parent
	return { root = root, face = face, odds = odds, name = name, scale = scale, pill = pill, hit = hit }
end

function ClassesModal.build(container: ScrollingFrame, api: any, deps: Deps): () -> ()
	local cleanups: { any } = {}
	local cfg = deps.config
	local motion = deps.accessibility:motionSettings()
	local tap = deps.minimumTapTarget
	local z = container.ZIndex + 1
	local tier = deps.quality and deps.quality:tier() or nil
	local compact = SafeArea.classOf(container) == "phone"
	local state = { rolling = false, auto = false, slot = 1, closed = false, lastReveal = nil :: string?, selected = 1 }
	local stats = { rolls = 0, autoRolls = 0, reveals = 0, autoStops = 0 }
	local weights = cfg.classes.weights
	local animated: { { gradient: UIGradient, speed: number } } = {}

	local render -- forward
	local function entitlements(): { [string]: boolean }
		return deps.entitlements() or {}
	end
	local function slotCount(): number
		local projection = deps.profile.projection
		return if projection then projection.classes.slotCount else cfg.classes.slotsDefault
	end
	local function entryFor(classId: string?): any?
		for _, entry in ipairs(weights) do
			if entry.id == classId then
				return entry
			end
		end
		return nil
	end
	local function indexOf(classId: string?): number?
		for index, entry in ipairs(weights) do
			if entry.id == classId then
				return index
			end
		end
		return nil
	end

	-- Gem balance chip in the frame's top-right slot.
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
			chip.Position = UDim2.fromScale(1, 0.5)
			local function refreshChip()
				local projection = deps.profile.projection
				chipLabel.Text = tostring(projection and projection.currencies.gems or 0)
			end
			refreshChip()
			table.insert(cleanups, deps.profile.changed:Connect(refreshChip))
		end
	end

	-- Layout ---------------------------------------------------------------------------------------
	local cardW = if compact then 118 else 168
	local cardH = math.floor(cardW * 1.38)
	local barrelH = cardH + Tokens.spacing.xl * 2 + 18
	local stageH = 36 + Tokens.spacing.sm + barrelH + Tokens.spacing.md + (tap + 16) + Tokens.spacing.sm
	local sideW = if compact then 0.5 else 0.21
	local sideH = if compact then tap * 5 else stageH
	local layoutH = if compact then stageH + Tokens.spacing.md + sideH else stageH
	local layout = Instance.new("Frame")
	layout.Name = "Layout"
	layout.BackgroundTransparency = 1
	layout.Size = UDim2.new(1, 0, 0, layoutH)
	layout.LayoutOrder = 1
	layout.ZIndex = z
	layout.Parent = container

	local left = Instance.new("Frame")
	left.Name = "Owned"
	left.BackgroundTransparency = 1
	left.ZIndex = z
	left.Parent = layout
	local right = Instance.new("Frame")
	right.Name = "Equipped"
	right.BackgroundTransparency = 1
	right.ZIndex = z
	right.Parent = layout
	local stage = Instance.new("Frame")
	stage.Name = "Stage"
	stage.BackgroundTransparency = 1
	stage.ZIndex = z
	stage.Parent = layout
	if compact then
		stage.Size = UDim2.new(1, 0, 0, stageH)
		left.Position = UDim2.fromOffset(0, stageH + Tokens.spacing.md)
		left.Size = UDim2.new(sideW, -Tokens.spacing.xs, 0, sideH)
		right.AnchorPoint = Vector2.new(1, 0)
		right.Position = UDim2.new(1, 0, 0, stageH + Tokens.spacing.md)
		right.Size = UDim2.new(sideW, -Tokens.spacing.xs, 0, sideH)
	else
		left.Size = UDim2.new(sideW, -Tokens.spacing.sm, 0, sideH)
		right.AnchorPoint = Vector2.new(1, 0)
		right.Position = UDim2.fromScale(1, 0)
		right.Size = UDim2.new(sideW, -Tokens.spacing.sm, 0, sideH)
		stage.Position = UDim2.fromScale(sideW, 0)
		stage.Size = UDim2.new(1 - sideW * 2, 0, 0, stageH)
	end

	-- Stage: the subtitle plank, the barrel, the carousel, the spin row ----------------------------
	local plank = Instance.new("Frame")
	plank.Name = "Plank"
	plank.Size = UDim2.new(1, -Tokens.spacing.sm * 2, 0, 36)
	plank.Position = UDim2.fromOffset(Tokens.spacing.sm, 0)
	plank.ZIndex = z
	Depth.panel(plank, WOOD, { radius = Tokens.radius.sm, rim = WOOD_LIGHT })
	plank.Parent = stage
	local plankLeft = FrameKit.text(
		plank,
		"Left",
		"SPIN FOR A NEW CLASS!",
		"caption",
		{ zIndex = z + 1, color = PAPER, align = Enum.TextXAlignment.Left }
	)
	plankLeft.Font = Tokens.typography.label.font
	plankLeft.Position = UDim2.fromOffset(Tokens.spacing.lg, 0)
	plankLeft.Size = UDim2.new(0.5, -Tokens.spacing.lg, 1, 0)
	local plankRight = FrameKit.text(
		plank,
		"Right",
		"EVERY FORAGER STARTS SOMEWHERE!",
		"caption",
		{ zIndex = z + 1, color = PAPER, align = Enum.TextXAlignment.Right }
	)
	plankRight.Font = Tokens.typography.label.font
	plankRight.AnchorPoint = Vector2.new(1, 0)
	plankRight.Position = UDim2.new(1, -Tokens.spacing.lg, 0, 0)
	plankRight.Size = UDim2.new(0.5, -Tokens.spacing.lg, 1, 0)
	plankRight.Visible = not compact

	local barrel = Instance.new("Frame")
	barrel.Name = "Barrel"
	barrel.Position = UDim2.fromOffset(0, 36 + Tokens.spacing.sm)
	barrel.Size = UDim2.new(1, 0, 0, barrelH)
	barrel.BackgroundColor3 = BARREL
	barrel.ZIndex = z
	barrel.ClipsDescendants = true
	local barrelCorner = Instance.new("UICorner")
	barrelCorner.CornerRadius = UDim.new(0, Tokens.radius.xl)
	barrelCorner.Parent = barrel
	Depth.keyline(barrel, Tokens.stroke.frame, WOOD_DEEP)
	local barrelGradient = Instance.new("UIGradient")
	barrelGradient.Rotation = 0
	barrelGradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, BARREL_DEEP),
		ColorSequenceKeypoint.new(0.5, BARREL),
		ColorSequenceKeypoint.new(1, BARREL_DEEP),
	})
	barrelGradient.Parent = barrel
	barrel.Parent = stage
	for _, y in ipairs({ 0, 1 }) do
		local band = Instance.new("Frame")
		band.Name = "Band"
		band.AnchorPoint = Vector2.new(0, y)
		band.Position = UDim2.fromScale(0, y)
		band.Size = UDim2.new(1, 0, 0, 10)
		band.BackgroundColor3 = Tokens.color.goldDeep
		band.BorderSizePixel = 0
		band.ZIndex = z + 1
		band.Parent = barrel
	end
	-- Hay along the barrel's foot.
	for i = 1, 14 do
		local straw = Instance.new("Frame")
		straw.Name = "Straw"
		straw.AnchorPoint = Vector2.new(0.5, 1)
		straw.Position = UDim2.new((i - 0.5) / 14, 0, 1, -6)
		straw.Size = UDim2.fromOffset(26, 8 + (i % 3) * 4)
		straw.Rotation = (i % 2 == 0 and 14 or -12)
		straw.BackgroundColor3 = Tokens.color.straw
		straw.BorderSizePixel = 0
		straw.ZIndex = z + 1
		local strawCorner = Instance.new("UICorner")
		strawCorner.CornerRadius = UDim.new(1, 0)
		strawCorner.Parent = straw
		straw.Parent = barrel
	end
	-- The glow behind the chosen card, and the golden egg pointer above it.
	local glow = Instance.new("Frame")
	glow.Name = "Glow"
	glow.AnchorPoint = Vector2.new(0.5, 0.5)
	glow.Position = UDim2.fromScale(0.5, 0.52)
	glow.Size = UDim2.fromOffset(cardW + 34, cardH + 34)
	glow.BackgroundColor3 = Tokens.color.goldLight
	glow.BackgroundTransparency = 0.55
	glow.BorderSizePixel = 0
	glow.ZIndex = z + 1
	local glowCorner = Instance.new("UICorner")
	glowCorner.CornerRadius = UDim.new(0, Tokens.radius.xl)
	glowCorner.Parent = glow
	local glowGradient = Instance.new("UIGradient")
	glowGradient.Rotation = 90
	glowGradient.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.2), NumberSequenceKeypoint.new(1, 0.7) })
	glowGradient.Parent = glow
	glow.Parent = barrel
	local pointer = Instance.new("Frame")
	pointer.Name = "Pointer"
	pointer.AnchorPoint = Vector2.new(0.5, 1)
	pointer.Position = UDim2.new(0.5, 0, 0.52, -(cardH / 2 + 6))
	pointer.Size = UDim2.fromOffset(40, 52)
	pointer.BackgroundTransparency = 1
	pointer.ZIndex = z + 5
	pointer.Parent = barrel
	local egg = Skin.icon(pointer, "forge.egg", 40, z + 6) or Icons.egg(pointer, 34, { zIndex = z + 6, color = Tokens.color.gold })
	egg.AnchorPoint = Vector2.new(0.5, 0)
	egg.Position = UDim2.fromScale(0.5, 0)
	local tip = Instance.new("Frame")
	tip.Name = "Tip"
	tip.AnchorPoint = Vector2.new(0.5, 1)
	tip.Position = UDim2.fromScale(0.5, 1)
	tip.Size = UDim2.fromOffset(12, 12)
	tip.Rotation = 45
	tip.BackgroundColor3 = Tokens.color.gold
	tip.BorderSizePixel = 0
	tip.ZIndex = z + 6
	tip.Parent = pointer

	-- The carousel: every class has a card; five are shown at a time.
	type Card = { index: number, id: string, tier: string, view: any }
	local cards: { Card } = {}
	local byId: { [string]: Card } = {}
	local selectClass -- forward
	for index, entry in ipairs(weights) do
		local tierName = tierFor(entry)
		local view = buildCard(barrel, entry, tierName, z + 2, animated)
		view.root.Size = UDim2.fromOffset(cardW, cardH)
		view.root.Visible = false
		local card: Card = { index = index, id = entry.id, tier = tierName, view = view }
		table.insert(cards, card)
		byId[entry.id] = card
		table.insert(
			cleanups,
			view.hit.Activated:Connect(function()
				if state.rolling then
					return
				end
				deps.audio:play(Tokens.sound.uiTab)
				selectClass(index)
			end)
		)
		table.insert(
			cleanups,
			view.hit.MouseEnter:Connect(function()
				if not state.rolling and state.selected ~= index then
					deps.audio:play(Tokens.sound.uiHover)
				end
			end)
		)
	end
	local slotScales = { [-2] = 0.62, [-1] = 0.8, [0] = 1, [1] = 0.8, [2] = 0.62 }
	-- Five cards across whatever width the barrel has: the outer pair sit half inside its edge.
	local function slotOffset(offset: number): number
		local width = math.max(barrel.AbsoluteSize.X / SafeArea.scaleOf(container), cardW * 3.4)
		local step = math.min(cardW * 0.98, (width / 2 - cardW * 0.5) / 1.7)
		return offset * step * (if math.abs(offset) == 2 then 0.92 else 1)
	end
	local function layoutCarousel(animate: boolean)
		local n = #cards
		local shown: { [number]: boolean } = {}
		for offset = -2, 2 do
			local index = ((state.selected - 1 + offset) % n) + 1
			if shown[index] then
				continue
			end
			shown[index] = true
			local card = cards[index]
			local view = card.view
			view.root.Visible = true
			view.root.ZIndex = z + 2 + (2 - math.abs(offset))
			view.face.ZIndex = view.root.ZIndex + 1
			view.hit.ZIndex = view.root.ZIndex + 6
			local target = UDim2.new(0.5, slotOffset(offset), 0.52, 0)
			local targetScale = slotScales[offset]
			if animate and not motion.reducedMotion then
				TweenService:Create(view.root, TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Position = target })
					:Play()
				TweenService
					:Create(view.scale, TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Scale = targetScale })
					:Play()
			else
				view.root.Position = target
				view.scale.Scale = targetScale
			end
			-- Neighbours sit back in the shade; the chosen card carries the light.
			local dim = if offset == 0 then 0 else 0.25 + math.abs(offset) * 0.1
			view.face.BackgroundTransparency = dim * 0.5
			view.name.TextTransparency = dim
			view.odds.TextTransparency = dim
			local outline = Depth.keylineOf(view.root)
			if outline and card.tier ~= "mythic" then
				outline.Color = if offset == 0 then Tokens.color.goldLight else WOOD_DEEP
				outline.Thickness = if offset == 0 then Tokens.stroke.frame else Tokens.stroke.bold
			end
		end
		for index, card in ipairs(cards) do
			if not shown[index] then
				card.view.root.Visible = false
			end
		end
	end
	table.insert(
		cleanups,
		barrel:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
			if not state.rolling then
				layoutCarousel(false)
			end
		end)
	)
	local function arrow(name: string, glyphRotation: number, anchorX: number, step: number)
		local handle = Button.build(barrel, {
			text = "",
			variant = "secondary",
			round = true,
			minimumTapTarget = tap,
			motion = motion,
			size = UDim2.fromOffset(tap, tap),
			zIndex = z + 8,
			sound = function()
				deps.audio:play(Tokens.sound.uiTab)
			end,
			hoverSound = function()
				deps.audio:play(Tokens.sound.uiHover)
			end,
			onActivated = function()
				if state.rolling then
					return
				end
				selectClass(((state.selected - 1 + step) % #weights) + 1)
			end,
		})
		handle.button.Name = name
		handle.button.AnchorPoint = Vector2.new(anchorX, 0.5)
		handle.button.Position = UDim2.new(anchorX, if anchorX == 0 then Tokens.spacing.sm else -Tokens.spacing.sm, 0.52, 0)
		local face = handle.button:FindFirstChild("Face") :: Frame
		local chevron = Icons.chevron(face, Tokens.icon.md, { zIndex = z + 10, color = Tokens.color.inkStrong })
		chevron.AnchorPoint = Vector2.new(0.5, 0.5)
		chevron.Position = UDim2.fromScale(0.5, 0.5)
		chevron.Rotation = glyphRotation
		table.insert(cleanups, handle.destroy)
		return handle
	end
	arrow("Previous", 180, 0, -1)
	arrow("Next", 0, 1, 1)

	-- The spin row: SPIN - N GEMS, with AUTO beside it.
	local spinRow = Instance.new("Frame")
	spinRow.Name = "SpinRow"
	spinRow.AnchorPoint = Vector2.new(0.5, 1)
	spinRow.Position = UDim2.fromScale(0.5, 1)
	spinRow.Size = UDim2.new(1, 0, 0, tap + 16)
	spinRow.BackgroundTransparency = 1
	spinRow.ZIndex = z
	spinRow.Parent = stage
	local rollHandle, autoHandle, luckHandle, fastHandle
	rollHandle = Button.build(spinRow, {
		text = string.format("SPIN   -   %d GEMS", cfg.classes.rollGemCost),
		variant = "primary",
		minimumTapTarget = tap,
		motion = motion,
		size = UDim2.fromScale(if compact then 0.72 else 0.62, 1),
		zIndex = z + 1,
		textSize = if compact then 26 else 34,
		sound = function()
			deps.audio:play(Tokens.sound.uiTap)
		end,
		hoverSound = function()
			deps.audio:play(Tokens.sound.uiHover)
		end,
	})
	rollHandle.button.Name = "RollButton"
	rollHandle.button.AnchorPoint = Vector2.new(0.5, 0.5)
	rollHandle.button.Position = UDim2.fromScale(0.5, 0.5)
	do
		local face = rollHandle.button:FindFirstChild("Face")
		local gemIcon = if face then (Skin.icon(face, "hud.gem", tap - 14, z + 4) or Icons.gem(face, tap - 16, { zIndex = z + 4 })) else nil
		if gemIcon then
			gemIcon.AnchorPoint = Vector2.new(0, 0.5)
			gemIcon.Position = UDim2.new(0, Tokens.spacing.lg, 0.5, 0)
		end
	end
	table.insert(cleanups, rollHandle.destroy)
	autoHandle = Button.build(spinRow, {
		text = "AUTO OFF",
		variant = "secondary",
		minimumTapTarget = tap,
		motion = motion,
		size = UDim2.new(if compact then 0.26 else 0.19, -Tokens.spacing.xs, 0, tap),
		zIndex = z + 1,
		textSize = Tokens.typography.caption.size + 2,
	})
	autoHandle.button.Name = "AutoRollButton"
	autoHandle.button.AnchorPoint = Vector2.new(1, 0.5)
	autoHandle.button.Position = UDim2.fromScale(1, 0.5)
	table.insert(cleanups, autoHandle.destroy)

	-- The passes, in the corners under the side panels (on a phone, under the stage).
	local function passButton(parent: GuiObject, name: string, passKey: string, label: string, priceKey: string, variant: string): any
		local price = cfg.classes.products and cfg.classes.products[priceKey] or nil
		local handle = Button.build(parent, {
			text = if price then string.format("%s  R$%d", label, price) else label,
			variant = variant :: any,
			minimumTapTarget = tap,
			motion = motion,
			size = UDim2.new(1, 0, 0, tap),
			zIndex = z + 1,
			textSize = Tokens.typography.caption.size + 3,
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
		handle.button.AnchorPoint = Vector2.new(0.5, 1)
		handle.button.Position = UDim2.fromScale(0.5, 1)
		table.insert(cleanups, handle.destroy)
		return handle
	end

	-- Left: YOUR CLASSES ------------------------------------------------------------------------
	plaque(left, "Title", "YOUR CLASSES", z + 1, 34)
	local ownedCount = FrameKit.badge(left, "Count", "0/" .. #weights, Tokens.color.goldDeep, z + 3)
	ownedCount.AnchorPoint = Vector2.new(0.5, 0)
	ownedCount.Position = UDim2.new(0.5, 0, 0, 34 - 8)
	local ownedBoard = board(left, "Board", z)
	ownedBoard.Position = UDim2.fromOffset(0, 34 + Tokens.spacing.md)
	ownedBoard.Size = UDim2.new(1, 0, 1, -(34 + Tokens.spacing.md + tap + Tokens.spacing.sm))
	local ownedList = Instance.new("ScrollingFrame")
	ownedList.Name = "List"
	ownedList.BackgroundTransparency = 1
	ownedList.BorderSizePixel = 0
	ownedList.Size = UDim2.new(1, 0, 1, -(Tokens.typography.caption.size + 6))
	ownedList.CanvasSize = UDim2.new()
	ownedList.AutomaticCanvasSize = Enum.AutomaticSize.Y
	ownedList.ScrollBarThickness = 4
	ownedList.ScrollBarImageColor3 = WOOD_DEEP
	ownedList.ZIndex = z + 1
	ownedList.Parent = ownedBoard
	local ownedLayout = Instance.new("UIListLayout")
	ownedLayout.SortOrder = Enum.SortOrder.LayoutOrder
	ownedLayout.Padding = UDim.new(0, Tokens.spacing.xs)
	ownedLayout.Parent = ownedList
	local collectNote = FrameKit.text(
		ownedBoard,
		"Note",
		"Collect more classes!",
		"caption",
		{ zIndex = z + 1, color = Tokens.color.inkMuted, align = Enum.TextXAlignment.Center }
	)
	collectNote.AnchorPoint = Vector2.new(0.5, 1)
	collectNote.Position = UDim2.fromScale(0.5, 1)
	collectNote.Size = UDim2.new(1, 0, 0, Tokens.typography.caption.size + 4)
	type Chip = { id: string, root: Frame, face: Frame, name: TextLabel, lock: Frame, check: Frame, art: GuiObject }
	local chips: { Chip } = {}
	local chipH = math.max(38, tap - 8)
	for index, entry in ipairs(weights) do
		local tierName = tierFor(entry)
		local rarity = colorsFor(tierName)
		local root, face = FrameKit.tile(ownedList, "Chip_" .. entry.id, {
			fill = rarity.fill,
			deep = rarity.deep,
			zIndex = z + 2,
			radius = Tokens.radius.sm,
			lip = 3,
			size = UDim2.new(1, -6, 0, chipH),
		})
		root.LayoutOrder = index
		local artHolder = Instance.new("Frame")
		artHolder.Name = "Art"
		artHolder.AnchorPoint = Vector2.new(0, 0.5)
		artHolder.Position = UDim2.new(0, 4, 0.5, 0)
		artHolder.Size = UDim2.fromOffset(chipH - 10, chipH - 10)
		artHolder.BackgroundTransparency = 1
		artHolder.ZIndex = z + 3
		artHolder.Parent = face
		local art = classArt(artHolder, entry, chipH - 12, z + 4)
		art.Size = UDim2.fromScale(1, 1)
		local name = FrameKit.text(face, "Name", entry.displayName, "caption", { zIndex = z + 4, color = Tokens.color.featherWhite })
		name.Font = Tokens.typography.label.font
		name.Position = UDim2.fromOffset(chipH, 0)
		name.Size = UDim2.new(1, -(chipH + 26), 1, 0)
		name.TextTruncate = Enum.TextTruncate.AtEnd
		FrameKit.outline(name, 1.5, WOOD_DEEP)
		local badge = Instance.new("Frame")
		badge.Name = "State"
		badge.AnchorPoint = Vector2.new(1, 0.5)
		badge.Position = UDim2.new(1, -4, 0.5, 0)
		badge.Size = UDim2.fromOffset(22, 22)
		badge.BackgroundColor3 = Tokens.color.success
		badge.ZIndex = z + 4
		local badgeCorner = Instance.new("UICorner")
		badgeCorner.CornerRadius = UDim.new(1, 0)
		badgeCorner.Parent = badge
		Depth.keyline(badge, 1.5, WOOD_DEEP)
		badge.Parent = face
		local check = Icons.check(badge, 14, { zIndex = z + 5, color = Tokens.color.featherWhite })
		check.AnchorPoint = Vector2.new(0.5, 0.5)
		check.Position = UDim2.fromScale(0.5, 0.5)
		local lock = Icons.lock(face, 16, { zIndex = z + 5, color = Tokens.color.inkMuted })
		lock.AnchorPoint = Vector2.new(1, 0.5)
		lock.Position = UDim2.new(1, -8, 0.5, 0)
		local hit = Instance.new("TextButton")
		hit.Name = "Hit"
		hit.Text = ""
		hit.BackgroundTransparency = 1
		hit.Size = UDim2.fromScale(1, 1)
		hit.ZIndex = z + 6
		hit.Parent = root
		table.insert(
			cleanups,
			hit.Activated:Connect(function()
				if not state.rolling then
					deps.audio:play(Tokens.sound.uiTab)
					selectClass(index)
				end
			end)
		)
		table.insert(chips, { id = entry.id, root = root, face = face, name = name, lock = lock, check = badge, art = art })
	end
	luckHandle = passButton(left, "LuckPass", "doubleLuck", "2x LUCK", "doubleLuckRobux", "success")
	do
		local outline = Depth.keylineOf(luckHandle.button)
		if outline then
			outline.Color = Color3.new(1, 1, 1)
			outline.Thickness = Tokens.stroke.bold + 1
			local gradient = Instance.new("UIGradient")
			gradient.Color = RAINBOW
			gradient.Parent = outline
			table.insert(animated, { gradient = gradient, speed = 70 })
		end
	end

	-- Right: EQUIPPED CLASSES ---------------------------------------------------------------------
	plaque(right, "Title", "EQUIPPED CLASSES", z + 1, 34)
	local slotsBoard = board(right, "Board", z)
	slotsBoard.Position = UDim2.fromOffset(0, 34 + Tokens.spacing.md)
	slotsBoard.Size = UDim2.new(1, 0, 1, -(34 + Tokens.spacing.md + tap + Tokens.spacing.sm))
	local slotsLayout = Instance.new("UIListLayout")
	slotsLayout.SortOrder = Enum.SortOrder.LayoutOrder
	slotsLayout.Padding = UDim.new(0, Tokens.spacing.sm)
	slotsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	slotsLayout.Parent = slotsBoard
	type SlotView = {
		index: number,
		root: Frame,
		label: TextLabel,
		cardFrame: Frame,
		art: Frame,
		name: TextLabel,
		pill: TextLabel,
		empty: TextLabel,
		lock: Frame,
		buy: any,
		hit: TextButton,
	}
	local slotViews: { SlotView } = {}
	local slotLocked: { boolean } = {}
	local maxSlots = cfg.classes.maximumSlots
	for index = 1, maxSlots do
		local root = Instance.new("Frame")
		root.Name = "Slot" .. index
		root.BackgroundTransparency = 1
		root.Size = UDim2.new(1, 0, 1 / maxSlots, -Tokens.spacing.sm)
		root.LayoutOrder = index
		root.ZIndex = z + 1
		root.Parent = slotsBoard
		local label = FrameKit.text(
			root,
			"Label",
			"SLOT " .. index,
			"caption",
			{ zIndex = z + 2, color = Tokens.color.inkMuted, align = Enum.TextXAlignment.Center }
		)
		label.Font = Tokens.typography.label.font
		label.Size = UDim2.new(1, 0, 0, Tokens.typography.caption.size + 4)
		local cardFrame = Instance.new("Frame")
		cardFrame.Name = "Card"
		cardFrame.Position = UDim2.fromOffset(0, Tokens.typography.caption.size + 6)
		cardFrame.Size = UDim2.new(1, 0, 1, -(Tokens.typography.caption.size + 6))
		cardFrame.BackgroundColor3 = PAPER
		cardFrame.ZIndex = z + 2
		local cardCorner = Instance.new("UICorner")
		cardCorner.CornerRadius = UDim.new(0, Tokens.radius.md)
		cardCorner.Parent = cardFrame
		Depth.keyline(cardFrame, Tokens.stroke.standard, WOOD_DEEP)
		cardFrame.Parent = root
		local art = Instance.new("Frame")
		art.Name = "Art"
		art.AnchorPoint = Vector2.new(0.5, 0)
		art.Position = UDim2.fromScale(0.5, 0.08)
		art.Size = UDim2.fromScale(0.5, 0.42)
		art.BackgroundTransparency = 1
		art.ZIndex = z + 3
		local artRatio = Instance.new("UIAspectRatioConstraint")
		artRatio.Parent = art
		art.Parent = cardFrame
		local name = FrameKit.text(
			cardFrame,
			"Name",
			"",
			"label",
			{ zIndex = z + 3, color = Tokens.color.inkStrong, align = Enum.TextXAlignment.Center }
		)
		name.Position = UDim2.fromScale(0, 0.54)
		name.Size = UDim2.new(1, 0, 0, Tokens.typography.label.size + 4)
		name.TextScaled = true
		local pill = FrameKit.badge(cardFrame, "Rarity", "COMMON", Tokens.color.sky, z + 4)
		pill.AnchorPoint = Vector2.new(0.5, 1)
		pill.Position = UDim2.new(0.5, 0, 1, -Tokens.spacing.sm)
		pill.TextSize = Tokens.typography.caption.size - 1
		local empty = FrameKit.text(
			cardFrame,
			"Empty",
			"EMPTY\nSpin to fill",
			"caption",
			{ zIndex = z + 3, color = Tokens.color.inkMuted, align = Enum.TextXAlignment.Center, wrap = true }
		)
		empty.AnchorPoint = Vector2.new(0.5, 0.5)
		empty.Position = UDim2.fromScale(0.5, 0.5)
		empty.Size = UDim2.new(1, 0, 0, Tokens.typography.caption.size * 2 + 6)
		local lock = Icons.lock(cardFrame, tap - 8, { zIndex = z + 3, color = Tokens.color.inkMuted })
		lock.AnchorPoint = Vector2.new(0.5, 0)
		lock.Position = UDim2.fromScale(0.5, 0.12)
		local buy = Button.build(cardFrame, {
			text = "+1 SLOT",
			variant = "primary",
			minimumTapTarget = tap,
			motion = motion,
			size = UDim2.new(1, -Tokens.spacing.md, 0, tap),
			zIndex = z + 4,
			textSize = Tokens.typography.caption.size + 3,
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
		buy.button.Position = UDim2.new(0.5, 0, 1, -Tokens.spacing.sm)
		table.insert(cleanups, buy.destroy)
		local hit = Instance.new("TextButton")
		hit.Name = "Hit"
		hit.Text = ""
		hit.BackgroundTransparency = 1
		hit.Size = UDim2.new(1, 0, 1, -(tap + Tokens.spacing.md))
		hit.ZIndex = z + 5
		hit.Parent = cardFrame
		table.insert(
			cleanups,
			hit.Activated:Connect(function()
				if slotLocked[index] then
					UpgradeActions.promptPurchase(
						{ net = deps.net, audio = deps.audio, toasts = deps.toasts },
						"extraClassSlot",
						"Extra Class Slot"
					)
					return
				end
				deps.audio:play(Tokens.sound.uiTab)
				state.slot = index
				local projection = deps.profile.projection
				local equipped = projection and projection.classes.equipped[index]
				local at = indexOf(equipped)
				if at then
					selectClass(at)
				else
					render()
				end
			end)
		)
		table.insert(slotViews, {
			index = index,
			root = root,
			label = label,
			cardFrame = cardFrame,
			art = art,
			name = name,
			pill = pill,
			empty = empty,
			lock = lock,
			buy = buy,
			hit = hit,
		})
	end
	fastHandle = passButton(right, "FastPass", "fastRolls", "FAST ROLLS", "fastRollsRobux", "teal")

	-- Rendering ------------------------------------------------------------------------------------
	local slotArt: { [number]: GuiObject } = {}
	render = function()
		local projection = deps.profile.projection
		if not projection then
			return
		end
		local ent = entitlements()
		local odds = ClassRoll.odds(cfg, ent.doubleLuck == true)
		local owned = 0
		for index, card in ipairs(cards) do
			card.view.odds.Text = string.format("%.1f%%", odds[index].percent)
		end
		for index, chip in ipairs(chips) do
			local entry = weights[index]
			local isOwned = projection.classes.owned[entry.id] == true
			local isEquipped = table.find(projection.classes.equipped, entry.id) ~= nil
			if isOwned then
				owned += 1
			end
			chip.face.BackgroundTransparency = if isOwned then 0 else 0.55
			chip.name.TextTransparency = if isOwned then 0 else 0.35
			chip.art.Visible = isOwned
			chip.lock.Visible = not isOwned
			chip.check.Visible = isEquipped
			local outline = Depth.keylineOf(chip.root)
			if outline then
				outline.Color = if index == state.selected then Tokens.color.goldLight else WOOD_DEEP
				outline.Thickness = if index == state.selected then Tokens.stroke.bold else Tokens.stroke.standard
			end
		end
		ownedCount.Text = string.format("%d/%d", owned, #weights)
		collectNote.Visible = owned < #weights
		local count = slotCount()
		for _, view in ipairs(slotViews) do
			local unlocked = view.index <= count
			slotLocked[view.index] = not unlocked
			view.lock.Visible = not unlocked
			view.buy.button.Visible = not unlocked
			view.label.Text = "SLOT " .. view.index
			if unlocked then
				local price = nil
				local equipped = projection.classes.equipped[view.index]
				local entry = entryFor(equipped)
				if slotArt[view.index] then
					slotArt[view.index]:Destroy()
					slotArt[view.index] = nil
				end
				if entry then
					local tierName = tierFor(entry)
					local rarity = colorsFor(tierName)
					slotArt[view.index] = classArt(view.art, entry, 96, z + 4)
					slotArt[view.index].Size = UDim2.fromScale(1, 1)
					view.name.Text = entry.displayName
					view.pill.Text = string.upper(RARITY_LABEL[tierName] or tierName)
					view.pill.BackgroundColor3 = rarity.deep
					view.pill.Visible = true
					view.name.Visible = true
					view.empty.Visible = false
				else
					view.name.Visible = false
					view.pill.Visible = false
					view.empty.Visible = true
				end
				local _ = price
			else
				if slotArt[view.index] then
					slotArt[view.index]:Destroy()
					slotArt[view.index] = nil
				end
				view.name.Visible = false
				view.pill.Visible = false
				view.empty.Visible = false
				local price = cfg.classes.products and cfg.classes.products.extraSlotRobux or nil
				view.buy.setText(if price then string.format("+1 SLOT  R$%d", price) else "+1 SLOT")
			end
			local outline = Depth.keylineOf(view.cardFrame)
			if outline then
				outline.Color = if view.index == state.slot and unlocked then Tokens.color.gold else WOOD_DEEP
				outline.Thickness = if view.index == state.slot and unlocked then Tokens.stroke.frame else Tokens.stroke.standard
			end
		end
		if luckHandle then
			luckHandle.setText(
				if ent.doubleLuck then "2x LUCK  ON" else string.format("2x LUCK  R$%d", cfg.classes.products.doubleLuckRobux)
			)
			luckHandle.setSelected(ent.doubleLuck == true)
			luckHandle.setEnabled(ent.doubleLuck ~= true)
		end
		if fastHandle then
			fastHandle.setText(
				if ent.fastRolls then "FAST ROLLS  ON" else string.format("FAST ROLLS  R$%d", cfg.classes.products.fastRollsRobux)
			)
			fastHandle.setSelected(ent.fastRolls == true)
			fastHandle.setEnabled(ent.fastRolls ~= true)
		end
		if rollHandle then
			local affordable = projection.currencies.gems >= cfg.classes.rollGemCost
			rollHandle.setEnabled(not state.rolling and affordable)
			rollHandle.pulse(not state.rolling and affordable)
		end
	end

	selectClass = function(index: number)
		if state.rolling then
			return
		end
		state.selected = index
		layoutCarousel(true)
		render()
	end

	-- The result: the card cracks out of a golden egg and takes the frame ---------------------------
	local currentResult: { finish: () -> (), keep: () -> () }? = nil
	local function showResult(result: any, previousClassId: string?, onDone: () -> ())
		local landing = byId[result.classId]
		local entry = weights[landing.index]
		local rarity = colorsFor(landing.tier)
		local mythic = landing.tier == "mythic"
		local host: GuiObject = (api.shell and api.shell.card) or container
		local overlay = Instance.new("Frame")
		overlay.Name = "Result"
		overlay.AnchorPoint = Vector2.new(0.5, 0.5)
		overlay.Position = UDim2.fromScale(0.5, 0.5)
		overlay.Size = UDim2.new(1, -8, 1, -8)
		overlay.BackgroundColor3 = Tokens.color.overlay
		overlay.BackgroundTransparency = 0.3
		overlay.BorderSizePixel = 0
		overlay.ClipsDescendants = true
		overlay.ZIndex = host.ZIndex + 20
		local overlayCorner = Instance.new("UICorner")
		overlayCorner.CornerRadius = UDim.new(0, Tokens.radius.xl)
		overlayCorner.Parent = overlay
		overlay.Parent = host
		local oz = overlay.ZIndex + 1
		local done = false
		local function finish()
			if done then
				return
			end
			done = true
			currentResult = nil
			overlay:Destroy()
			onDone()
		end
		-- Light behind everything: the sunburst turning, a warm glow disc.
		local rays = Instance.new("Frame")
		rays.Name = "Rays"
		rays.AnchorPoint = Vector2.new(0.5, 0.5)
		rays.Position = UDim2.fromScale(0.5, 0.46)
		rays.Size = UDim2.fromScale(1.2, 1.2)
		rays.BackgroundTransparency = 1
		rays.ZIndex = oz
		local raysRatio = Instance.new("UIAspectRatioConstraint")
		raysRatio.Parent = rays
		rays.Parent = overlay
		local burst = Skin.texture(
			rays,
			"texture.sunburst",
			{ zIndex = oz, transparency = if mythic then 0.25 else 0.45, color = if mythic then Tokens.color.featherWhite else rarity.fill }
		)
		local glow = Instance.new("Frame")
		glow.Name = "Glow"
		glow.AnchorPoint = Vector2.new(0.5, 0.5)
		glow.Position = UDim2.fromScale(0.5, 0.46)
		glow.Size = UDim2.fromScale(0.42, 0.42)
		glow.BackgroundColor3 = Tokens.color.goldLight
		glow.BackgroundTransparency = 0.55
		glow.BorderSizePixel = 0
		glow.ZIndex = oz
		local glowCorner = Instance.new("UICorner")
		glowCorner.CornerRadius = UDim.new(1, 0)
		glowCorner.Parent = glow
		local glowRatio = Instance.new("UIAspectRatioConstraint")
		glowRatio.Parent = glow
		glow.Parent = overlay
		-- The column: title, plaque, card, bonuses, buttons - nothing overlaps anything.
		local column = Instance.new("Frame")
		column.Name = "Column"
		column.BackgroundTransparency = 1
		column.Size = UDim2.fromScale(1, 1)
		column.ZIndex = oz + 1
		column.Parent = overlay
		local columnLayout = Instance.new("UIListLayout")
		columnLayout.FillDirection = Enum.FillDirection.Vertical
		columnLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
		columnLayout.VerticalAlignment = Enum.VerticalAlignment.Center
		columnLayout.SortOrder = Enum.SortOrder.LayoutOrder
		columnLayout.Padding = UDim.new(0, Tokens.spacing.sm)
		columnLayout.Parent = column
		local title = FrameKit.text(
			column,
			"Title",
			string.upper(RARITY_LABEL[landing.tier] or landing.tier) .. " CLASS!",
			"display",
			{ zIndex = oz + 2, color = rarity.fill, align = Enum.TextXAlignment.Center }
		)
		title.LayoutOrder = 1
		title.Size = UDim2.new(1, 0, 0, if compact then 44 else 62)
		title.TextScaled = true
		FrameKit.outline(title, 4, WOOD_DEEP)
		if mythic then
			local gradient = Instance.new("UIGradient")
			gradient.Color = RAINBOW
			gradient.Parent = title
			table.insert(animated, { gradient = gradient, speed = 40 })
		end
		local titleScale = Instance.new("UIScale")
		titleScale.Scale = 0.6
		titleScale.Parent = title
		TweenService:Create(titleScale, TweenInfo.new(0.45, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
		local sub = Instance.new("Frame")
		sub.Name = "Sub"
		sub.LayoutOrder = 2
		sub.Size = UDim2.new(0.5, 0, 0, 40)
		sub.BackgroundTransparency = 1
		sub.ZIndex = oz + 2
		local subCap = Instance.new("UISizeConstraint")
		subCap.MaxSize = Vector2.new(460, 40)
		subCap.MinSize = Vector2.new(220, 40)
		subCap.Parent = sub
		if not Skin.overlay(sub, "modal.title", { zIndex = oz + 2, name = "Plate" }) then
			Depth.panel(sub, WOOD, { radius = Tokens.radius.md, rim = WOOD_LIGHT })
		end
		local subText = FrameKit.text(
			sub,
			"Text",
			string.format("%s  -  %s", string.upper(entry.displayName), landing.view.odds.Text),
			"label",
			{ zIndex = oz + 4, color = Tokens.color.inkStrong, align = Enum.TextXAlignment.Center, size = UDim2.fromScale(1, 1) }
		)
		subText.TextScaled = true
		local subTextCap = Instance.new("UITextSizeConstraint")
		subTextCap.MaxTextSize = Tokens.typography.label.size + 2
		subTextCap.Parent = subText
		sub.Parent = column
		-- The card, with the golden shell it came out of flying off either side.
		local cardHolder = Instance.new("Frame")
		cardHolder.Name = "CardHolder"
		cardHolder.LayoutOrder = 3
		cardHolder.BackgroundTransparency = 1
		cardHolder.Size = UDim2.fromScale(1, if compact then 0.42 else 0.46)
		cardHolder.ZIndex = oz + 1
		cardHolder.Parent = column
		local view = buildCard(cardHolder, entry, landing.tier, oz + 3, animated)
		view.root.Position = UDim2.fromScale(0.5, 0.5)
		view.root.Size = UDim2.fromScale(0, 1)
		local viewRatio = Instance.new("UIAspectRatioConstraint")
		viewRatio.AspectRatio = cardW / cardH
		viewRatio.Parent = view.root
		view.odds.Text = landing.view.odds.Text
		view.hit:Destroy()
		view.scale.Scale = 0.3
		TweenService:Create(view.scale, TweenInfo.new(0.55, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
		for i = 1, 8 do
			local shard = Instance.new("Frame")
			shard.Name = "Shell" .. i
			shard.AnchorPoint = Vector2.new(0.5, 0.5)
			shard.Position = UDim2.fromScale(0.5, 0.5)
			shard.Size = UDim2.fromOffset(18 + (i % 3) * 10, 14 + (i % 2) * 8)
			shard.Rotation = i * 45
			shard.BackgroundColor3 = if i % 2 == 0 then Tokens.color.gold else Tokens.color.goldLight
			shard.BorderSizePixel = 0
			shard.ZIndex = oz + 2
			local shardCorner = Instance.new("UICorner")
			shardCorner.CornerRadius = UDim.new(0, 5)
			shardCorner.Parent = shard
			Depth.keyline(shard, 1.5, Tokens.color.goldDeep)
			shard.Parent = cardHolder
			local angle = math.rad(i * 45 + 22)
			TweenService:Create(shard, TweenInfo.new(0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				Position = UDim2.new(0.5, math.cos(angle) * 260, 0.5, math.sin(angle) * 150),
				Rotation = i * 45 + 160,
				BackgroundTransparency = 0.4,
			}):Play()
		end
		Confetti.burst(overlay, {
			origin = UDim2.fromScale(0.5, 0.46),
			count = if mythic then 80 elseif landing.tier == "legendary" then 50 else 30,
			spread = if mythic then 320 else 220,
			motion = motion,
			tier = tier,
			zIndex = oz + 8,
		})
		if mythic and not motion.reducedMotion then
			task.delay(0.4, function()
				if not done then
					Confetti.burst(
						overlay,
						{ origin = UDim2.fromScale(0.5, 0.3), count = 60, spread = 340, motion = motion, tier = tier, zIndex = oz + 8 }
					)
				end
			end)
		end
		-- What it grants.
		local lines = effectLines(entry, weights)
		local chipsRow = Instance.new("Frame")
		chipsRow.Name = "Bonuses"
		chipsRow.LayoutOrder = 4
		chipsRow.Size = UDim2.new(0.92, 0, 0, tap + 4)
		chipsRow.BackgroundTransparency = 1
		chipsRow.ZIndex = oz + 2
		chipsRow.Parent = column
		local chipLayout = Instance.new("UIListLayout")
		chipLayout.FillDirection = Enum.FillDirection.Horizontal
		chipLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
		chipLayout.VerticalAlignment = Enum.VerticalAlignment.Center
		chipLayout.Padding = UDim.new(0, Tokens.spacing.sm)
		chipLayout.Parent = chipsRow
		local shown = if #lines == 0 then { "No bonuses - a fresh start" } else lines
		for i = 1, math.min(if compact then 2 else 3, #shown) do
			local chip = Instance.new("Frame")
			chip.Name = "Bonus" .. i
			chip.Size = UDim2.new(0, if compact then 160 else 220, 1, 0)
			chip.ZIndex = oz + 2
			Depth.panel(chip, WOOD, { radius = Tokens.radius.md, rim = WOOD_LIGHT })
			local text = FrameKit.text(
				chip,
				"Text",
				string.upper(shown[i]),
				"caption",
				{ zIndex = oz + 3, color = PAPER, align = Enum.TextXAlignment.Center, wrap = true }
			)
			text.Font = Tokens.typography.label.font
			text.Position = UDim2.fromScale(0, 0.06)
			text.Size = UDim2.fromScale(1, 0.54)
			text.TextScaled = true
			local applied = FrameKit.text(
				chip,
				"Applied",
				if #lines == 0 then "STARTING CLASS" else "BONUS APPLIED",
				"caption",
				{ zIndex = oz + 3, color = Tokens.color.goldLight, align = Enum.TextXAlignment.Center }
			)
			applied.Position = UDim2.fromScale(0, 0.6)
			applied.Size = UDim2.fromScale(1, 0.34)
			applied.TextSize = 11
			chip.Parent = chipsRow
		end
		-- Buttons.
		local row = Instance.new("Frame")
		row.Name = "Actions"
		row.LayoutOrder = 5
		row.Size = UDim2.new(0.92, 0, 0, tap + 16)
		row.BackgroundTransparency = 1
		row.ZIndex = oz + 2
		row.Parent = column
		local rowLayout = Instance.new("UIListLayout")
		rowLayout.FillDirection = Enum.FillDirection.Horizontal
		rowLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
		rowLayout.VerticalAlignment = Enum.VerticalAlignment.Center
		rowLayout.Padding = UDim.new(0, Tokens.spacing.md)
		rowLayout.Parent = row
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
		local equipNow = Button.build(row, {
			text = "EQUIP NOW",
			variant = "ember",
			minimumTapTarget = tap,
			motion = motion,
			size = UDim2.fromOffset(if compact then 220 else 300, tap + 16),
			zIndex = oz + 3,
			textSize = if compact then 24 else 30,
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
		equipNow.pulse(true)
		local keep = Button.build(row, {
			text = "KEEP CURRENT",
			variant = "secondary",
			minimumTapTarget = tap,
			motion = motion,
			size = UDim2.fromOffset(if compact then 160 else 210, tap + 4),
			zIndex = oz + 3,
			textSize = Tokens.typography.label.size,
			sound = function()
				deps.audio:play(Tokens.sound.uiTap)
			end,
			onActivated = keepCurrent,
		})
		keep.button.LayoutOrder = 2
		keep.button.Visible = canKeep
		local tag = FrameKit.badge(
			overlay,
			"Unlocked",
			if result.duplicate then "ALREADY OWNED - EQUIPPED" else "NEW CLASS UNLOCKED!",
			if result.duplicate then Tokens.color.inkMuted else Tokens.color.success,
			oz + 6
		)
		tag.AnchorPoint = Vector2.new(1, 1)
		tag.Position = UDim2.new(1, -Tokens.spacing.lg, 1, -Tokens.spacing.md)
		tag.Rotation = -4
		api.setInitialFocus(equipNow.button)
		if not motion.reducedMotion then
			local conn = RunService.RenderStepped:Connect(function(dt)
				if burst and burst.Parent then
					burst.Rotation = (burst.Rotation + dt * 18) % 360
				end
				if glow.Parent then
					glow.BackgroundTransparency = 0.5 + 0.12 * math.sin(os.clock() * 3)
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
				if overlay.Parent then
					overlay:Destroy()
				end
			end
		end)
		return finish
	end

	-- Spin: the carousel runs and slows onto the committed class -------------------------------------
	local function reveal(result: any, previousClassId: string?, onLanded: () -> ())
		local seconds = result.animationSeconds or cfg.lobby.classRollAnimationSeconds
		local scaled = seconds * deps.accessibility:motionScale()
		local landing = byId[result.classId]
		local started = os.clock()
		task.spawn(function()
			while os.clock() - started < scaled and not state.closed do
				local t = (os.clock() - started) / math.max(scaled, 0.05)
				state.selected = (state.selected % #cards) + 1
				layoutCarousel(false)
				deps.audio:play(Tokens.sound.uiTap, { pitchVariance = 0.08 })
				task.wait(0.05 + t * t * 0.28)
			end
			if state.closed then
				return
			end
			state.selected = landing.index
			layoutCarousel(true)
			landing.view.scale.Scale = 1.12
			Tween.scale(landing.view.scale, "release", motion, 1)
			deps.audio:play(Tokens.sound.uiConfetti)
			deps.audio:play(Tokens.sound.rollLand)
			deps.haptics:pulse(0.8, 0.12)
			stats.reveals += 1
			state.lastReveal = result.classId
			deps.toasts:push(
				if result.duplicate then result.displayName .. " (duplicate) equipped" else "Unlocked " .. result.displayName,
				"success"
			)
			task.wait(0.35)
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

	local function stopAuto(reason: string?)
		if state.auto then
			state.auto = false
			stats.autoStops += 1
			if autoHandle then
				autoHandle.setText("AUTO OFF")
				autoHandle.setSelected(false)
			end
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
		if rollHandle then
			rollHandle.setPending(true, "SPINNING...")
		end
		local result = deps.net:request("ClassRoll", { slot = state.slot })
		if not result.ok then
			state.rolling = false
			if rollHandle then
				rollHandle.setPending(false)
			end
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
		reveal(result.data, previousClassId, function()
			state.rolling = false
			if rollHandle then
				rollHandle.setPending(false)
			end
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
				autoHandle.setText("AUTO ON")
				autoHandle.setSelected(true)
				deps.audio:play(Tokens.sound.uiConfirm)
				rollOnce(true)
			end
		end)
	)
	api.setInitialFocus(rollHandle.button)

	-- Start on the equipped class when there is one.
	do
		local projection = deps.profile.projection
		local equipped = projection and projection.classes.equipped[1]
		state.selected = indexOf(equipped) or 1
	end
	layoutCarousel(false)
	render()
	-- Motion: rainbow borders turn, the glow breathes, the egg bobs.
	table.insert(
		cleanups,
		RunService.RenderStepped:Connect(function(dt)
			local now = os.clock()
			for _, entry in ipairs(animated) do
				entry.gradient.Rotation = (entry.gradient.Rotation + dt * entry.speed) % 360
			end
			if not motion.reducedMotion then
				glow.BackgroundTransparency = 0.5 + 0.15 * math.sin(now * 2.4)
				pointer.Position = UDim2.new(0.5, 0, 0.52, -(cardH / 2 + 6) + math.sin(now * 3) * 4)
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
					autoHandle.setText("AUTO ON")
					rollOnce(true)
				end
				return { auto = state.auto }
			end,
			stop = function()
				stopAuto("Auto stopped")
				return { auto = state.auto, stops = stats.autoStops }
			end,
			select = function(index: number)
				selectClass(index)
				return { selected = state.selected }
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
		})
	end
	container:SetAttribute("SFE_ClassesRolling", false)
	local attrThread = task.spawn(function()
		while not state.closed do
			container:SetAttribute("SFE_ClassesRolling", state.rolling)
			container:SetAttribute("SFE_ClassesAuto", state.auto)
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
