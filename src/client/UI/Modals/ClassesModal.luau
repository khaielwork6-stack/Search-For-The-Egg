--!strict
-- Class Cards (the Class Master's stall). Three panels: the deck on the left (one rarity-tinted
-- row per class with its odds, lock or check), the spotlight in the middle (the selected class on a
-- sunburst emblem, arrows to browse, the Spin button, Auto, and the 2x Luck / Fast Rolls passes),
-- and the slots panel on the right (equipped slots, the +1 Slot pass, the selected class's story
-- and its Equip button). A spin sweeps the deck and flickers the spotlight name, slowing onto the
-- server's committed class; the result, toast and equip change appear only after it lands. Auto
-- stops on request, on insufficient Gems, on any refusal, and when the modal closes.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
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

local function describeEffect(entry: any, weights: { any }?): string
	local lines = effectLines(entry, weights or {})
	if #lines == 0 then
		return ""
	end
	local out = {}
	for _, line in ipairs(lines) do
		table.insert(out, "•  " .. line)
	end
	return table.concat(out, "\n")
end

local function centredArt(parent: GuiObject, art: string, icon: string, px: number, z: number): GuiObject
	local glyph = Skin.icon(parent, art, px, z) or Icons.build(icon, parent, px, { zIndex = z })
	glyph.AnchorPoint = Vector2.new(0.5, 0.5)
	glyph.Position = UDim2.fromScale(0.5, 0.5)
	return glyph
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

	-- Panels ---------------------------------------------------------------------------------------
	local rowHeight = tap - 2
	local deckHeight = #weights * rowHeight + (#weights - 1) * Tokens.spacing.xs + Tokens.spacing.md * 2
	local layoutHeight = if compact then deckHeight + tap * 6 + Tokens.spacing.md * 3 else deckHeight
	local layout = Instance.new("Frame")
	layout.Name = "Layout"
	layout.BackgroundTransparency = 1
	layout.Size = UDim2.new(1, 0, 0, layoutHeight)
	layout.LayoutOrder = 1
	layout.ZIndex = z
	layout.Parent = container

	local deckWidth = if compact then 0.44 else 0.3
	local sideWidth = if compact then 0.54 else 0.28
	local deck = Instance.new("Frame")
	deck.Name = "Deck"
	deck.BackgroundColor3 = Tokens.color.creamDeep
	deck.Size = UDim2.new(deckWidth, -Tokens.spacing.xs, 0, deckHeight)
	deck.ZIndex = z
	local deckCorner = Instance.new("UICorner")
	deckCorner.CornerRadius = UDim.new(0, Tokens.radius.xl)
	deckCorner.Parent = deck
	local deckStroke = Instance.new("UIStroke")
	deckStroke.Thickness = Tokens.stroke.standard
	deckStroke.Color = Tokens.color.strawDeep
	deckStroke.Transparency = 0.4
	deckStroke.Parent = deck
	local deckPadding = Instance.new("UIPadding")
	deckPadding.PaddingLeft = UDim.new(0, Tokens.spacing.md)
	deckPadding.PaddingRight = UDim.new(0, Tokens.spacing.md)
	deckPadding.PaddingTop = UDim.new(0, Tokens.spacing.md)
	deckPadding.PaddingBottom = UDim.new(0, Tokens.spacing.md)
	deckPadding.Parent = deck
	local deckLayout = Instance.new("UIListLayout")
	deckLayout.SortOrder = Enum.SortOrder.LayoutOrder
	deckLayout.Padding = UDim.new(0, Tokens.spacing.xs)
	deckLayout.Parent = deck
	deck.Parent = layout

	local spotlight = Instance.new("Frame")
	spotlight.Name = "Spotlight"
	spotlight.BackgroundTransparency = 1
	spotlight.ZIndex = z
	spotlight.Parent = layout
	local side = Instance.new("Frame")
	side.Name = "Side"
	side.BackgroundTransparency = 1
	side.ZIndex = z
	side.Parent = layout
	if compact then
		spotlight.AnchorPoint = Vector2.new(1, 0)
		spotlight.Position = UDim2.fromScale(1, 0)
		spotlight.Size = UDim2.new(sideWidth, -Tokens.spacing.xs, 0, deckHeight)
		side.Position = UDim2.fromOffset(0, deckHeight + Tokens.spacing.md)
		side.Size = UDim2.new(1, 0, 0, layoutHeight - deckHeight - Tokens.spacing.md)
	else
		spotlight.Position = UDim2.new(deckWidth, Tokens.spacing.sm, 0, 0)
		spotlight.Size = UDim2.new(1 - deckWidth - sideWidth, -Tokens.spacing.sm * 2, 0, deckHeight)
		side.AnchorPoint = Vector2.new(1, 0)
		side.Position = UDim2.fromScale(1, 0)
		side.Size = UDim2.new(sideWidth, -Tokens.spacing.xs, 0, deckHeight)
	end

	-- Deck rows ------------------------------------------------------------------------------------
	type Row = {
		id: string,
		index: number,
		rarity: string,
		tile: Frame,
		face: Frame,
		scale: UIScale,
		name: TextLabel,
		odds: TextLabel,
		lock: Frame,
		check: Frame,
		button: TextButton,
	}
	local rows: { Row } = {}
	local byId: { [string]: Row } = {}
	local selectClass -- forward
	local animated: { { gradient: UIGradient, speed: number } } = {}
	local sheens: { UIGradient } = {}
	local pulses: { { stroke: UIStroke, phase: number } } = {}
	for index, entry in ipairs(weights) do
		local rarityName = tierFor(entry)
		local rarity = colorsFor(rarityName)
		local tile, face = FrameKit.tile(deck, "Row_" .. entry.id, {
			fill = rarity.fill,
			deep = rarity.deep,
			zIndex = z + 1,
			radius = Tokens.radius.md,
			lip = 4,
			size = UDim2.new(1, 0, 0, rowHeight),
		})
		tile.LayoutOrder = index
		local scale = Instance.new("UIScale")
		scale.Parent = tile
		-- Rarity escalation: rare / epic get a travelling sheen, legendary a pulsing gold glow,
		-- mythic a rotating rainbow border and shimmer.
		if rarityName == "rare" or rarityName == "epic" or rarityName == "legendary" or rarityName == "mythic" then
			local sheenFrame = Instance.new("Frame")
			sheenFrame.Name = "Sheen"
			sheenFrame.Size = UDim2.fromScale(1, 1)
			sheenFrame.BackgroundColor3 = Color3.new(1, 1, 1)
			sheenFrame.BackgroundTransparency = if rarityName == "mythic" then 0.45 else 0.65
			sheenFrame.BorderSizePixel = 0
			sheenFrame.ZIndex = z + 2
			local sheenCorner = Instance.new("UICorner")
			sheenCorner.CornerRadius = UDim.new(0, Tokens.radius.md)
			sheenCorner.Parent = sheenFrame
			local sheen = Instance.new("UIGradient")
			sheen.Rotation = 20
			sheen.Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 1),
				NumberSequenceKeypoint.new(0.42, 1),
				NumberSequenceKeypoint.new(0.5, 0.35),
				NumberSequenceKeypoint.new(0.58, 1),
				NumberSequenceKeypoint.new(1, 1),
			})
			sheen.Offset = Vector2.new(-1 + (index * 0.13) % 1, 0)
			sheen.Parent = sheenFrame
			sheenFrame.Parent = face
			table.insert(sheens, sheen)
		end
		local outline = tile:FindFirstChild("Outline") :: UIStroke?
		if outline and rarityName == "legendary" then
			outline.Color = Tokens.color.goldLight
			table.insert(pulses, { stroke = outline, phase = index })
		elseif outline and rarityName == "mythic" then
			outline.Thickness = Tokens.stroke.frame + 1
			outline.Color = Color3.new(1, 1, 1)
			local gradient = Instance.new("UIGradient")
			gradient.Color = RAINBOW
			gradient.Parent = outline
			table.insert(animated, { gradient = gradient, speed = 50 })
		end
		local copy = CLASS_COPY[entry.id] or { art = "icon.feather", icon = "feather", story = "" }
		local artHolder = Instance.new("Frame")
		artHolder.Name = "Art"
		artHolder.AnchorPoint = Vector2.new(0, 0.5)
		artHolder.Position = UDim2.new(0, Tokens.spacing.xs, 0.5, 0)
		artHolder.Size = UDim2.fromOffset(rowHeight - Tokens.spacing.sm, rowHeight - Tokens.spacing.sm)
		artHolder.BackgroundTransparency = 1
		artHolder.ZIndex = z + 2
		artHolder.Parent = face
		centredArt(artHolder, copy.art, copy.icon, rowHeight - Tokens.spacing.md - 2, z + 3)
		local left = rowHeight + Tokens.spacing.xs
		local name = FrameKit.text(face, "Name", entry.displayName, "label", { zIndex = z + 3, color = Tokens.color.featherWhite })
		name.Position = UDim2.fromOffset(left, 2)
		name.Size = UDim2.new(1, -(left + Tokens.icon.md + Tokens.spacing.md), 0, Tokens.typography.label.size + 2)
		name.TextSize = Tokens.typography.label.size - 2
		FrameKit.outline(name, 2)
		local oddsBar = Instance.new("Frame")
		oddsBar.Name = "OddsBar"
		oddsBar.AnchorPoint = Vector2.new(0, 1)
		oddsBar.Position = UDim2.new(0, left, 1, -4)
		oddsBar.Size = UDim2.new(1, -(left + Tokens.icon.md + Tokens.spacing.md), 0, Tokens.typography.caption.size + 2)
		oddsBar.BackgroundColor3 = Tokens.color.overlay
		oddsBar.BackgroundTransparency = 0.55
		oddsBar.BorderSizePixel = 0
		oddsBar.ZIndex = z + 2
		local oddsCorner = Instance.new("UICorner")
		oddsCorner.CornerRadius = UDim.new(1, 0)
		oddsCorner.Parent = oddsBar
		oddsBar.Parent = face
		local odds = FrameKit.text(oddsBar, "Odds", "", "caption", {
			zIndex = z + 3,
			color = Tokens.color.featherWhite,
			align = Enum.TextXAlignment.Center,
		})
		odds.Font = Tokens.typography.label.font
		odds.Size = UDim2.fromScale(1, 1)
		local badge = Instance.new("Frame")
		badge.Name = "State"
		badge.AnchorPoint = Vector2.new(1, 0.5)
		badge.Position = UDim2.new(1, -Tokens.spacing.xs, 0.5, 0)
		badge.Size = UDim2.fromOffset(Tokens.icon.md + 4, Tokens.icon.md + 4)
		badge.BackgroundColor3 = Tokens.color.creamPill
		badge.ZIndex = z + 3
		local badgeCorner = Instance.new("UICorner")
		badgeCorner.CornerRadius = UDim.new(1, 0)
		badgeCorner.Parent = badge
		local badgeStroke = Instance.new("UIStroke")
		badgeStroke.Thickness = Tokens.stroke.standard
		badgeStroke.Color = Tokens.color.outline
		badgeStroke.Parent = badge
		badge.Parent = face
		local lock = Icons.lock(badge, Tokens.icon.md - 4, { zIndex = z + 4 })
		lock.AnchorPoint = Vector2.new(0.5, 0.5)
		lock.Position = UDim2.fromScale(0.5, 0.5)
		local check = Icons.check(badge, Tokens.icon.md - 4, { zIndex = z + 4, color = Tokens.color.featherWhite })
		check.AnchorPoint = Vector2.new(0.5, 0.5)
		check.Position = UDim2.fromScale(0.5, 0.5)
		check.Visible = false
		-- The whole row is a button: tap to put the class in the spotlight.
		local hit = Instance.new("TextButton")
		hit.Name = "Hit"
		hit.Text = ""
		hit.BackgroundTransparency = 1
		hit.Size = UDim2.fromScale(1, 1)
		hit.ZIndex = z + 5
		hit.Parent = tile
		table.insert(
			cleanups,
			hit.Activated:Connect(function()
				deps.audio:play(Tokens.sound.uiTab)
				selectClass(index)
			end)
		)
		table.insert(
			cleanups,
			hit.MouseEnter:Connect(function()
				if not state.rolling then
					deps.audio:play(Tokens.sound.uiHover)
					TweenService:Create(scale, TweenInfo.new(0.12), { Scale = 1.03 }):Play()
				end
			end)
		)
		table.insert(
			cleanups,
			hit.MouseLeave:Connect(function()
				if not state.rolling then
					TweenService:Create(scale, TweenInfo.new(0.16), { Scale = 1 }):Play()
				end
			end)
		)
		local row: Row = {
			id = entry.id,
			index = index,
			rarity = rarityName,
			tile = tile,
			face = face,
			scale = scale,
			name = name,
			odds = odds,
			lock = lock,
			check = check,
			button = hit,
		}
		table.insert(rows, row)
		byId[entry.id] = row
	end

	-- Spotlight ------------------------------------------------------------------------------------
	local titleRow = Instance.new("Frame")
	titleRow.Name = "TitleRow"
	titleRow.BackgroundTransparency = 1
	titleRow.Size = UDim2.new(1, 0, 0, tap)
	titleRow.ZIndex = z
	titleRow.Parent = spotlight
	local function arrow(name: string, glyphRotation: number, anchorX: number, step: number)
		local handle = Button.build(titleRow, {
			text = "",
			variant = "secondary",
			round = true,
			minimumTapTarget = tap,
			motion = motion,
			size = UDim2.fromOffset(tap - Tokens.spacing.sm, tap - Tokens.spacing.sm),
			zIndex = z + 1,
			sound = function()
				deps.audio:play(Tokens.sound.uiTab)
			end,
			hoverSound = function()
				deps.audio:play(Tokens.sound.uiHover)
			end,
			onActivated = function()
				local next = ((state.selected - 1 + step) % #weights) + 1
				selectClass(next)
			end,
		})
		handle.button.Name = name
		handle.button.AnchorPoint = Vector2.new(anchorX, 0.5)
		handle.button.Position = UDim2.fromScale(anchorX, 0.5)
		local face = handle.button:FindFirstChild("Face") :: Frame
		local chevron = Icons.chevron(face, Tokens.icon.md, { zIndex = z + 3, color = Tokens.color.inkStrong })
		chevron.AnchorPoint = Vector2.new(0.5, 0.5)
		chevron.Position = UDim2.fromScale(0.5, 0.5)
		chevron.Rotation = glyphRotation
		table.insert(cleanups, handle.destroy)
		return handle
	end
	arrow("Previous", 180, 0, -1)
	arrow("Next", 0, 1, 1)
	local spotTitle = FrameKit.text(titleRow, "Title", "", "display", {
		zIndex = z + 1,
		color = Tokens.color.featherWhite,
		align = Enum.TextXAlignment.Center,
	})
	spotTitle.Size = UDim2.new(1, -(tap * 2), 1, 0)
	spotTitle.Position = UDim2.fromOffset(tap, 0)
	spotTitle.TextSize = if compact then Tokens.typography.title.size else Tokens.typography.display.size - 4
	spotTitle.TextScaled = false
	spotTitle.TextTruncate = Enum.TextTruncate.AtEnd
	FrameKit.outline(spotTitle, 3)
	local rarityBadge = FrameKit.badge(spotlight, "Rarity", "COMMON", Tokens.color.sky, z + 2)
	rarityBadge.AnchorPoint = Vector2.new(0.5, 0)
	rarityBadge.Position = UDim2.new(0.5, 0, 0, tap + 2)

	-- Emblem: rarity disc on a sunburst with the class art.
	local emblemSize = if compact then tap * 2 else tap * 3 + Tokens.spacing.md
	local emblemTop = tap + Tokens.spacing.xl + Tokens.spacing.sm
	local emblem = Instance.new("Frame")
	emblem.Name = "Emblem"
	emblem.AnchorPoint = Vector2.new(0.5, 0)
	emblem.Position = UDim2.new(0.5, 0, 0, emblemTop)
	emblem.Size = UDim2.fromOffset(emblemSize, emblemSize)
	emblem.BackgroundColor3 = Tokens.color.sky
	emblem.ZIndex = z + 1
	local emblemCorner = Instance.new("UICorner")
	emblemCorner.CornerRadius = UDim.new(1, 0)
	emblemCorner.Parent = emblem
	local emblemStroke = Instance.new("UIStroke")
	emblemStroke.Thickness = Tokens.stroke.frame
	emblemStroke.Color = Tokens.color.outline
	emblemStroke.Parent = emblem
	local emblemScale = Instance.new("UIScale")
	emblemScale.Parent = emblem
	emblem.Parent = spotlight
	local burst = Skin.texture(emblem, "texture.sunburst", { zIndex = z + 2, transparency = 0.55, color = Tokens.color.featherWhite })
	if burst then
		local burstCorner = Instance.new("UICorner")
		burstCorner.CornerRadius = UDim.new(1, 0)
		burstCorner.Parent = burst
	end
	-- Aura behind the emblem: soft coloured disc that pulses for legendary and cycles for mythic.
	local aura = Instance.new("Frame")
	aura.Name = "Aura"
	aura.AnchorPoint = Vector2.new(0.5, 0.5)
	aura.Position = UDim2.new(0.5, 0, 0, emblemTop + emblemSize / 2)
	aura.Size = UDim2.fromOffset(emblemSize + Tokens.spacing.xl, emblemSize + Tokens.spacing.xl)
	aura.BackgroundColor3 = Tokens.color.goldLight
	aura.BackgroundTransparency = 1
	aura.BorderSizePixel = 0
	aura.ZIndex = z
	local auraCorner = Instance.new("UICorner")
	auraCorner.CornerRadius = UDim.new(1, 0)
	auraCorner.Parent = aura
	local auraGradient = Instance.new("UIGradient")
	auraGradient.Color = RAINBOW
	auraGradient.Enabled = false
	auraGradient.Parent = aura
	aura.Parent = spotlight
	local emblemGradient = Instance.new("UIGradient")
	emblemGradient.Color = RAINBOW
	emblemGradient.Enabled = false
	emblemGradient.Parent = emblemStroke
	local emblemArt: GuiObject? = nil
	local function setEmblemArt(entry: any)
		if emblemArt then
			emblemArt:Destroy()
		end
		local copy = CLASS_COPY[entry.id] or { art = "icon.feather", icon = "feather", story = "" }
		emblemArt = centredArt(emblem, copy.art, copy.icon, math.floor(emblemSize * 0.6), z + 4)
	end

	-- Spin controls under the emblem.
	local controls = Instance.new("Frame")
	controls.Name = "Controls"
	controls.BackgroundTransparency = 1
	controls.AnchorPoint = Vector2.new(0.5, 1)
	controls.Position = UDim2.fromScale(0.5, 1)
	controls.Size = UDim2.new(1, 0, 0, tap * 2 + Tokens.spacing.sm)
	controls.ZIndex = z
	controls.Parent = spotlight
	local rollHandle, autoHandle, luckHandle, fastHandle
	local function passButton(name: string, passKey: string, label: string, priceKey: string, anchorX: number, variant: string): any
		local price = cfg.classes.products and cfg.classes.products[priceKey] or nil
		local handle = Button.build(controls, {
			text = if price then string.format("%s  R$ %d", label, price) else label,
			variant = variant :: any,
			minimumTapTarget = tap,
			motion = motion,
			size = UDim2.new(0.5, -Tokens.spacing.xs, 0, tap - Tokens.spacing.sm),
			zIndex = z + 1,
			textSize = Tokens.typography.caption.size + 1,
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
		handle.button.AnchorPoint = Vector2.new(anchorX, 0)
		handle.button.Position = UDim2.fromScale(anchorX, 0)
		table.insert(cleanups, handle.destroy)
		return handle
	end
	luckHandle = passButton("LuckPass", "doubleLuck", "2x Luck", "doubleLuckRobux", 0, "success")
	fastHandle = passButton("FastPass", "fastRolls", "Fast Rolls", "fastRollsRobux", 1, "teal")
	-- Premium presentation: a rotating rainbow border on 2x Luck, a sheen on both.
	do
		local luckOutline = luckHandle.button:FindFirstChild("Outline", true) :: UIStroke?
		if luckOutline then
			luckOutline.Color = Color3.new(1, 1, 1)
			luckOutline.Thickness = Tokens.stroke.bold + 1
			local gradient = Instance.new("UIGradient")
			gradient.Color = RAINBOW
			gradient.Parent = luckOutline
			table.insert(animated, { gradient = gradient, speed = 70 })
		end
	end

	-- Side panel -----------------------------------------------------------------------------------
	local slotsRow = Instance.new("Frame")
	slotsRow.Name = "Slots"
	slotsRow.BackgroundTransparency = 1
	local slotRowHeight = tap - Tokens.spacing.sm
	slotsRow.Size = UDim2.new(1, 0, 0, (slotRowHeight + Tokens.spacing.xs) * cfg.classes.maximumSlots)
	slotsRow.ZIndex = z
	slotsRow.Parent = side
	local slotHandles: { any } = {}
	local slotLocked: { boolean } = {}
	for index = 1, cfg.classes.maximumSlots do
		local handle = Button.build(slotsRow, {
			text = "Slot " .. index,
			variant = "secondary",
			minimumTapTarget = tap,
			motion = motion,
			size = UDim2.new(1, 0, 0, slotRowHeight),
			textSize = Tokens.typography.caption.size + 2,
			zIndex = z + 1,
			sound = function()
				deps.audio:play(Tokens.sound.uiTab)
			end,
			hoverSound = function()
				deps.audio:play(Tokens.sound.uiHover)
			end,
			onActivated = function()
				if slotLocked[index] then
					UpgradeActions.promptPurchase(
						{ net = deps.net, audio = deps.audio, toasts = deps.toasts },
						"extraClassSlot",
						"Extra Class Slot"
					)
					return
				end
				state.slot = index
				for slotIndex, slotHandle in ipairs(slotHandles) do
					slotHandle.setSelected(slotIndex == state.slot)
				end
			end,
		})
		handle.button.Name = "Slot" .. index
		handle.button.Position = UDim2.fromOffset(0, (index - 1) * (slotRowHeight + Tokens.spacing.xs))
		table.insert(slotHandles, handle)
		table.insert(cleanups, handle.destroy)
	end

	local story = Instance.new("Frame")
	story.Name = "Story"
	story.BackgroundColor3 = Tokens.color.featherWhite
	local storyTop = (slotRowHeight + Tokens.spacing.xs) * cfg.classes.maximumSlots + Tokens.spacing.xs
	story.Position = UDim2.fromOffset(0, storyTop)
	story.Size = UDim2.new(1, 0, 1, -storyTop)
	story.ZIndex = z
	local storyCorner = Instance.new("UICorner")
	storyCorner.CornerRadius = UDim.new(0, Tokens.radius.lg)
	storyCorner.Parent = story
	local storyStroke = Instance.new("UIStroke")
	storyStroke.Thickness = Tokens.stroke.bold
	storyStroke.Color = Tokens.color.outline
	storyStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	storyStroke.Parent = story
	local storyPadding = Instance.new("UIPadding")
	storyPadding.PaddingLeft = UDim.new(0, Tokens.spacing.md)
	storyPadding.PaddingRight = UDim.new(0, Tokens.spacing.md)
	storyPadding.PaddingTop = UDim.new(0, Tokens.spacing.sm)
	storyPadding.PaddingBottom = UDim.new(0, Tokens.spacing.sm)
	storyPadding.Parent = story
	story.Parent = side
	local storyName = FrameKit.text(story, "Name", "", "title", { zIndex = z + 1, color = Tokens.color.inkStrong })
	storyName.Size = UDim2.new(1, 0, 0, Tokens.typography.title.size + 4)
	storyName.TextSize = Tokens.typography.title.size - 2
	FrameKit.divider(story, "Rule", z + 1).Position = UDim2.fromOffset(0, Tokens.typography.title.size + Tokens.spacing.sm)
	local storyText = FrameKit.text(story, "Text", "", "body", { zIndex = z + 1, color = Tokens.color.ink, wrap = true })
	storyText.Position = UDim2.fromOffset(0, Tokens.typography.title.size + Tokens.spacing.lg)
	storyText.Size = UDim2.new(1, 0, 0, Tokens.typography.body.size * 2 + 4)
	storyText.TextYAlignment = Enum.TextYAlignment.Top
	storyText.TextSize = Tokens.typography.body.size - 1
	-- Exact bonuses, one per line; the box scrolls when a class grants many.
	local effectTop = Tokens.typography.title.size + Tokens.spacing.lg + Tokens.typography.body.size * 2 + Tokens.spacing.sm
	local effectScroll = Instance.new("ScrollingFrame")
	effectScroll.Name = "Effects"
	effectScroll.BackgroundTransparency = 1
	effectScroll.BorderSizePixel = 0
	effectScroll.Position = UDim2.fromOffset(0, effectTop)
	effectScroll.Size = UDim2.new(1, 0, 1, -(effectTop + tap + Tokens.typography.caption.size + Tokens.spacing.lg))
	effectScroll.CanvasSize = UDim2.new()
	effectScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	effectScroll.ScrollBarThickness = 4
	effectScroll.ScrollBarImageColor3 = Tokens.color.strawDeep
	effectScroll.ZIndex = z + 1
	effectScroll.Parent = story
	local storyEffect = FrameKit.text(effectScroll, "Effect", "", "caption", { zIndex = z + 1, color = Tokens.color.goldDeep, wrap = true })
	storyEffect.Font = Tokens.typography.label.font
	storyEffect.TextSize = Tokens.typography.caption.size + 1
	storyEffect.Size = UDim2.new(1, -6, 0, 0)
	storyEffect.AutomaticSize = Enum.AutomaticSize.Y
	storyEffect.TextYAlignment = Enum.TextYAlignment.Top
	local storyOdds = FrameKit.text(story, "Odds", "", "caption", { zIndex = z + 1, color = Tokens.color.inkMuted })
	storyOdds.AnchorPoint = Vector2.new(0, 1)
	storyOdds.Position = UDim2.new(0, 0, 1, -(tap + Tokens.spacing.xs))
	storyOdds.Size = UDim2.new(1, 0, 0, Tokens.typography.caption.size + 4)
	local equipHandle = Button.build(story, {
		text = "Equip",
		variant = "teal",
		minimumTapTarget = tap,
		motion = motion,
		size = UDim2.new(1, 0, 0, tap - Tokens.spacing.xs),
		zIndex = z + 1,
		sound = function()
			deps.audio:play(Tokens.sound.uiTap)
		end,
		hoverSound = function()
			deps.audio:play(Tokens.sound.uiHover)
		end,
		onActivated = function()
			if state.rolling then
				return
			end
			local entry = weights[state.selected]
			local result = deps.net:request("ClassEquip", { classId = entry.id, slot = state.slot })
			if result.ok then
				deps.audio:play(Tokens.sound.uiConfirm)
				deps.haptics:pulse(0.3, 0.06)
				emblemScale.Scale = 1.08
				Tween.scale(emblemScale, "release", motion, 1)
				local row = byId[entry.id]
				if row then
					row.scale.Scale = 1.06
					Tween.scale(row.scale, "release", motion, 1)
				end
			else
				deps.audio:play(Tokens.sound.uiError)
				deps.toasts:push(
					if result.code == "not_authorized" then "Spin to unlock this class first" else "Could not equip",
					"warning"
				)
			end
		end,
	})
	equipHandle.button.AnchorPoint = Vector2.new(0.5, 1)
	equipHandle.button.Position = UDim2.fromScale(0.5, 1)
	table.insert(cleanups, equipHandle.destroy)
	local lockedNote = FrameKit.text(story, "Locked", "Spin to unlock", "caption", {
		zIndex = z + 1,
		color = Tokens.color.inkMuted,
		align = Enum.TextXAlignment.Center,
	})
	lockedNote.AnchorPoint = Vector2.new(0.5, 1)
	lockedNote.Position = UDim2.new(0.5, 0, 1, -Tokens.spacing.sm)
	lockedNote.Size = UDim2.new(1, 0, 0, Tokens.typography.caption.size + 4)

	-- Result line under the layout, filled only after a spin lands.
	local resultLine =
		FrameKit.pill(container, "Result", " ", { size = UDim2.new(1, 0, 0, tap - Tokens.spacing.xs), zIndex = z + 1, outline = true })
	resultLine.LayoutOrder = 2
	resultLine.TextXAlignment = Enum.TextXAlignment.Center
	resultLine.Visible = false
	local terms = FrameKit.text(
		container,
		"Terms",
		"Odds are shown on every card. A spin always unlocks or re-equips the class it lands on; duplicates are not refunded.",
		"caption",
		{ zIndex = z, color = Tokens.color.inkMuted }
	)
	terms.LayoutOrder = 3
	terms.Size = UDim2.new(1, 0, 0, Tokens.typography.caption.size * 2 + 6)

	-- Rendering ------------------------------------------------------------------------------------
	local function refreshSpotlight()
		local entry = weights[state.selected]
		local row = rows[state.selected]
		local rarity = colorsFor(row.rarity)
		spotTitle.Text = entry.displayName
		rarityBadge.Text = string.upper(RARITY_LABEL[row.rarity] or row.rarity)
		rarityBadge.BackgroundColor3 = rarity.deep
		emblem.BackgroundColor3 = rarity.fill
		emblemStroke.Color = if row.rarity == "mythic" then Color3.new(1, 1, 1) else rarity.deep
		emblemStroke.Thickness = if row.rarity == "mythic" then Tokens.stroke.frame + 2 else Tokens.stroke.frame
		emblemGradient.Enabled = row.rarity == "mythic"
		auraGradient.Enabled = row.rarity == "mythic"
		aura.BackgroundColor3 = if row.rarity == "legendary" then Tokens.color.goldLight else Tokens.color.featherWhite
		aura.BackgroundTransparency = if row.rarity == "mythic" then 0.45 elseif row.rarity == "legendary" then 0.6 else 1
		setEmblemArt(entry)
		local copy = CLASS_COPY[entry.id]
		storyName.Text = entry.displayName
		storyText.Text = if copy and copy.story ~= "" then copy.story else "A class of its own."
		storyEffect.Text = describeEffect(entry, weights)
		for _, other in ipairs(rows) do
			local outline = other.tile:FindFirstChild("Outline") :: UIStroke?
			if outline then
				outline.Color = if other.index == state.selected then Tokens.color.goldLight else Tokens.color.outline
				outline.Thickness = if other.index == state.selected then Tokens.stroke.frame else Tokens.stroke.bold
			end
		end
	end

	local function render()
		local projection = deps.profile.projection
		if not projection then
			return
		end
		local ent = entitlements()
		local odds = ClassRoll.odds(cfg, ent.doubleLuck == true)
		local count = slotCount()
		for index, handle in ipairs(slotHandles) do
			local unlocked = index <= count
			slotLocked[index] = not unlocked
			if unlocked then
				local equipped = projection.classes.equipped[index]
				local entry = entryFor(equipped)
				handle.setText(string.format("Slot %d  -  %s", index, entry and entry.displayName or "empty"))
				handle.setVariant(if index == state.slot then "primary" else "secondary")
				handle.setSelected(index == state.slot)
			else
				local price = cfg.classes.products and cfg.classes.products.extraSlotRobux or nil
				handle.setText(if price then string.format("+1 Slot  R$ %d", price) else "+1 Slot")
				handle.setVariant("primary")
				handle.setSelected(false)
			end
		end
		for index, row in ipairs(rows) do
			local entry = weights[index]
			local owned = projection.classes.owned[entry.id] == true
			local equippedIndex = table.find(projection.classes.equipped, entry.id)
			row.odds.Text = string.format("%.1f%%", odds[index].percent)
			row.lock.Visible = not owned
			row.check.Visible = equippedIndex ~= nil
			row.lock.Parent.Visible = not owned or equippedIndex ~= nil
			row.lock.Parent.BackgroundColor3 = if equippedIndex then Tokens.color.success else Tokens.color.creamPill
			row.face.BackgroundTransparency = if owned then 0 else 0.35
			row.name.TextTransparency = if owned then 0 else 0.2
		end
		local selected = weights[state.selected]
		local selectedOwned = projection.classes.owned[selected.id] == true
		local selectedEquipped = table.find(projection.classes.equipped, selected.id)
		storyOdds.Text =
			string.format("%.1f%% chance per spin%s", odds[state.selected].percent, if ent.doubleLuck then " (2x Luck)" else "")
		equipHandle.button.Visible = selectedOwned
		equipHandle.setText(if selectedEquipped then "Equipped" else string.format("Equip to slot %d", state.slot))
		equipHandle.setEnabled(selectedEquipped == nil and not state.rolling)
		equipHandle.setSelected(selectedEquipped ~= nil)
		lockedNote.Visible = not selectedOwned
		if luckHandle then
			luckHandle.setText(
				if ent.doubleLuck then "2x Luck  ON" else string.format("2x Luck  R$ %d", cfg.classes.products.doubleLuckRobux)
			)
			luckHandle.setSelected(ent.doubleLuck == true)
			luckHandle.setEnabled(ent.doubleLuck ~= true)
		end
		if fastHandle then
			fastHandle.setText(
				if ent.fastRolls then "Fast Rolls  ON" else string.format("Fast Rolls  R$ %d", cfg.classes.products.fastRollsRobux)
			)
			fastHandle.setSelected(ent.fastRolls == true)
			fastHandle.setEnabled(ent.fastRolls ~= true)
		end
		if rollHandle then
			rollHandle.setEnabled(not state.rolling and projection.currencies.gems >= cfg.classes.rollGemCost)
		end
	end

	selectClass = function(index: number)
		if state.rolling then
			return
		end
		state.selected = index
		refreshSpotlight()
		render()
		emblemScale.Scale = 0.92
		Tween.scale(emblemScale, "release", motion, 1)
	end

	-- Spin reveal: the deck highlight and the spotlight name race, slowing onto the committed class.
	local function reveal(result: any, onLanded: () -> ())
		local seconds = result.animationSeconds or cfg.lobby.classRollAnimationSeconds
		local scaled = seconds * deps.accessibility:motionScale()
		local landing = byId[result.classId]
		local started = os.clock()
		local index = state.selected
		deps.audio:play(Tokens.sound.rollSpin)
		task.spawn(function()
			local lastHighlight: Row? = nil
			while os.clock() - started < scaled and not state.closed do
				local t = (os.clock() - started) / math.max(scaled, 0.05)
				local row = rows[(index % #rows) + 1]
				index += 1
				if lastHighlight then
					lastHighlight.scale.Scale = 1
				end
				row.scale.Scale = 1.05
				lastHighlight = row
				spotTitle.Text = weights[row.index].displayName
				local rarity = colorsFor(row.rarity)
				emblem.BackgroundColor3 = rarity.fill
				deps.audio:play(Tokens.sound.uiTap, { pitchVariance = 0.08 })
				task.wait(0.05 + t * t * 0.28) -- decelerate toward the landing
			end
			if lastHighlight then
				lastHighlight.scale.Scale = 1
			end
			if state.closed then
				return
			end
			-- Land: spotlight the committed class, pop it, shower it (a mythic gets a bigger reveal).
			state.selected = landing.index
			refreshSpotlight()
			local mythic = landing.rarity == "mythic"
			local legendary = landing.rarity == "legendary"
			landing.scale.Scale = if mythic then 1.16 else 1.1
			Tween.scale(landing.scale, "release", motion, 1)
			emblemScale.Scale = if mythic then 1.35 elseif legendary then 1.24 else 1.18
			Tween.scale(emblemScale, "release", motion, 1)
			Tween.rotationPunch(emblem, motion, 0)
			Confetti.burst(spotlight, {
				origin = UDim2.new(0.5, 0, 0, emblemTop + emblemSize / 2),
				count = if mythic then 70 elseif legendary then 44 else 28,
				spread = if mythic then 220 else 170,
				motion = motion,
				tier = tier,
				zIndex = z + 8,
			})
			if mythic and not motion.reducedMotion then
				-- White flash and a second, wider shower a beat later.
				local flash = Instance.new("Frame")
				flash.Size = UDim2.fromScale(1, 1)
				flash.BackgroundColor3 = Color3.new(1, 1, 1)
				flash.BackgroundTransparency = 0.2
				flash.BorderSizePixel = 0
				flash.ZIndex = z + 12
				flash.Parent = container
				TweenService:Create(flash, TweenInfo.new(0.6, Enum.EasingStyle.Quad), { BackgroundTransparency = 1 }):Play()
				task.delay(0.65, function()
					flash:Destroy()
				end)
				task.delay(0.35, function()
					if not state.closed then
						Confetti.burst(
							container,
							{ origin = UDim2.fromScale(0.5, 0.3), count = 60, spread = 260, motion = motion, tier = tier, zIndex = z + 9 }
						)
						deps.audio:play(Tokens.sound.rollLand)
					end
				end)
			end
			deps.audio:play(Tokens.sound.uiConfetti)
			deps.audio:play(Tokens.sound.rollLand)
			deps.haptics:pulse(0.8, 0.12)
			stats.reveals += 1
			state.lastReveal = result.classId
			resultLine.Visible = true
			resultLine.Text = if result.duplicate
				then string.format("%s again - equipped to slot %d", result.displayName, result.slot)
				else string.format("New class: %s!", result.displayName)
			deps.toasts:push(
				if result.duplicate then result.displayName .. " (duplicate) equipped" else "Unlocked " .. result.displayName,
				"success"
			)
			onLanded()
		end)
	end

	local function stopAuto(reason: string?)
		if state.auto then
			state.auto = false
			stats.autoStops += 1
			if autoHandle then
				autoHandle.setText("Auto: Off")
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
		state.rolling = true
		resultLine.Visible = false
		render()
		if rollHandle then
			rollHandle.setPending(true, "Spinning...")
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
		reveal(result.data, function()
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

	rollHandle = Button.build(controls, {
		text = string.format("Spin  -  %d Gems", cfg.classes.rollGemCost),
		variant = "success",
		minimumTapTarget = tap,
		motion = motion,
		size = UDim2.new(0.66, -Tokens.spacing.xs, 0, tap + Tokens.spacing.xs),
		zIndex = z + 1,
		textSize = Tokens.typography.label.size + 2,
		sound = function()
			deps.audio:play(Tokens.sound.uiTap)
		end,
		hoverSound = function()
			deps.audio:play(Tokens.sound.uiHover)
		end,
		onActivated = function()
			rollOnce(false)
		end,
	})
	rollHandle.button.Name = "RollButton"
	rollHandle.button.AnchorPoint = Vector2.new(0, 1)
	rollHandle.button.Position = UDim2.fromScale(0, 1)
	autoHandle = Button.build(controls, {
		text = "Auto: Off",
		variant = "secondary",
		minimumTapTarget = tap,
		motion = motion,
		size = UDim2.new(0.34, -Tokens.spacing.xs, 0, tap + Tokens.spacing.xs),
		zIndex = z + 1,
		textSize = Tokens.typography.body.size,
		onActivated = function()
			if state.auto then
				stopAuto("Auto stopped")
			else
				state.auto = true
				autoHandle.setText("Auto: On")
				autoHandle.setSelected(true)
				deps.audio:play(Tokens.sound.uiConfirm)
				rollOnce(true)
			end
		end,
	})
	autoHandle.button.Name = "AutoRollButton"
	autoHandle.button.AnchorPoint = Vector2.new(1, 1)
	autoHandle.button.Position = UDim2.fromScale(1, 1)
	table.insert(cleanups, rollHandle.destroy)
	table.insert(cleanups, autoHandle.destroy)
	api.setInitialFocus(rollHandle.button)

	-- Start on the equipped class when there is one.
	do
		local projection = deps.profile.projection
		local equipped = projection and projection.classes.equipped[1]
		local entry = entryFor(equipped)
		if entry then
			state.selected = table.find(weights, entry) or 1
		end
	end
	refreshSpotlight()
	render()
	-- Rarity animation: rainbow borders rotate, sheens sweep, legendary glows pulse, the aura breathes.
	local sheenT = 0
	table.insert(
		cleanups,
		RunService.RenderStepped:Connect(function(dt)
			local now = os.clock()
			for _, entry in ipairs(animated) do
				entry.gradient.Rotation = (entry.gradient.Rotation + dt * entry.speed) % 360
			end
			sheenT = (sheenT + dt * 0.35) % 2
			for index, sheen in ipairs(sheens) do
				sheen.Offset = Vector2.new(-1 + ((sheenT + index * 0.31) % 2), 0)
			end
			for _, pulse in ipairs(pulses) do
				pulse.stroke.Transparency = 0.25 + 0.25 * math.sin(now * 3 + pulse.phase)
			end
			if aura.BackgroundTransparency < 1 then
				local breathe = 1 + 0.05 * math.sin(now * 2.2)
				aura.Size = UDim2.fromOffset((emblemSize + Tokens.spacing.xl) * breathe, (emblemSize + Tokens.spacing.xl) * breathe)
				if auraGradient.Enabled then
					auraGradient.Rotation = (auraGradient.Rotation + dt * 60) % 360
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
	-- Studio verification hook: the same routines the Spin / Auto buttons call (never a shortcut).
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
					autoHandle.setText("Auto: On")
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
		})
	end

	-- Expose state for Studio verification through the modal container.
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
