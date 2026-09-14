--!strict
-- Classes modal: all eight configured classes as rarity-tinted cards with their exact odds (luck
-- transform shown when owned), equipped slots, Roll (config Gem cost), Auto roll, and an original
-- reveal: a highlight runs across the cards and slows onto the server's committed class; the
-- result text, toast, and equip change appear only after the animation lands. Auto roll stops on
-- request, on insufficient Gems, on any refusal, and when the modal closes.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local ClassRoll = require(Shared.Domain.ClassRoll)
local Tween = require(script.Parent.Parent.Components.Tween)
local FrameKit = require(script.Parent.Parent.Components.Frame)
local Button = require(script.Parent.Parent.Components.Button)
local Skin = require(script.Parent.Parent.Components.Skin)
local Icons = require(script.Parent.Parent.Components.Icons)
local Confetti = require(script.Parent.Parent.Components.Confetti)

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

function ClassesModal.build(container: ScrollingFrame, api: any, deps: Deps): () -> ()
	local cleanups: { any } = {}
	local cfg = deps.config
	local motion = deps.accessibility:motionSettings()
	local tap = deps.minimumTapTarget
	local z = container.ZIndex + 1
	local state = { rolling = false, auto = false, slot = 1, closed = false, lastReveal = nil :: string? }
	local stats = { rolls = 0, autoRolls = 0, reveals = 0, autoStops = 0 }

	local function entitlements(): { [string]: boolean }
		return deps.entitlements() or {}
	end
	local function slotCount(): number
		local projection = deps.profile.projection
		return if projection then projection.classes.slotCount else cfg.classes.slotsDefault
	end

	-- Header: balance, odds note, slot chips.
	local header = FrameKit.text(container, "Balance", "", "heading", { zIndex = z, color = Tokens.color.inkStrong })
	header.LayoutOrder = 1
	local slots = Instance.new("Frame")
	slots.Name = "Slots"
	slots.BackgroundTransparency = 1
	slots.Size = UDim2.new(1, 0, 0, tap)
	slots.LayoutOrder = 2
	slots.ZIndex = z
	local slotsLayout = Instance.new("UIListLayout")
	slotsLayout.FillDirection = Enum.FillDirection.Horizontal
	slotsLayout.SortOrder = Enum.SortOrder.LayoutOrder
	slotsLayout.Padding = UDim.new(0, Tokens.spacing.sm)
	slotsLayout.Parent = slots
	slots.Parent = container
	local slotHandles: { any } = {}
	for index = 1, cfg.classes.maximumSlots do
		local handle = Button.build(slots, {
			text = "Slot " .. index,
			variant = "secondary",
			minimumTapTarget = tap,
			motion = motion,
			size = UDim2.fromOffset(220, tap),
			textSize = Tokens.typography.body.size,
			zIndex = z + 1,
			sound = function()
				deps.audio:play(Tokens.sound.uiTab)
			end,
			hoverSound = function()
				deps.audio:play(Tokens.sound.uiHover)
			end,
			onActivated = function()
				state.slot = index
				for slotIndex, slotHandle in ipairs(slotHandles) do
					slotHandle.setSelected(slotIndex == state.slot)
				end
			end,
		})
		handle.button.LayoutOrder = index
		table.insert(slotHandles, handle)
		table.insert(cleanups, handle.destroy)
	end

	-- Result line: filled only after the animation lands.
	local resultLine = FrameKit.pill(container, "Result", " ", { size = UDim2.new(1, 0, 0, tap), zIndex = z + 1 })
	resultLine.LayoutOrder = 3
	resultLine.TextXAlignment = Enum.TextXAlignment.Center
	resultLine.Visible = false

	-- Card grid.
	local grid = Instance.new("Frame")
	grid.Name = "Cards"
	grid.BackgroundTransparency = 1
	grid.Size = UDim2.fromScale(1, 0)
	grid.AutomaticSize = Enum.AutomaticSize.Y
	grid.LayoutOrder = 4
	grid.ZIndex = z
	local gridLayout = Instance.new("UIGridLayout")
	gridLayout.CellSize = UDim2.new(0.5, -Tokens.spacing.xs, 0, tap * 2 + Tokens.spacing.xxl)
	gridLayout.CellPadding = UDim2.fromOffset(Tokens.spacing.sm, Tokens.spacing.sm)
	gridLayout.SortOrder = Enum.SortOrder.LayoutOrder
	gridLayout.Parent = grid
	grid.Parent = container

	type Card = {
		frame: Frame,
		name: TextLabel,
		odds: TextLabel,
		effect: TextLabel,
		stroke: UIStroke,
		scale: UIScale,
		equip: any,
		id: string,
		art: ImageLabel?,
		rarity: string,
		lockIcon: Frame,
		checkIcon: Frame,
		stateBadge: Frame,
	}
	local cards: { Card } = {}
	local byId: { [string]: Card } = {}
	for index, entry in ipairs(cfg.classes.weights) do
		local rarity = (Tokens.rarity :: any)[ClassRoll.rarity(entry.weight)]
		local rarityName = ClassRoll.rarity(entry.weight)
		local frame = Instance.new("Frame")
		frame.Name = "Card_" .. entry.id
		frame.LayoutOrder = index
		frame.BackgroundColor3 = Tokens.color.featherWhite
		frame.ZIndex = z + 1
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, Tokens.radius.lg)
		corner.Parent = frame
		local stroke = Instance.new("UIStroke")
		stroke.Thickness = Tokens.stroke.bold
		stroke.Color = rarity.deep
		stroke.Parent = frame
		local gradient = Instance.new("UIGradient")
		gradient.Rotation = 90
		gradient.Color =
			ColorSequence.new({ ColorSequenceKeypoint.new(0, Tokens.color.featherWhite), ColorSequenceKeypoint.new(1, Tokens.color.cream) })
		gradient.Parent = frame
		local art = Skin.label(frame, "class." .. rarityName .. ".locked", { zIndex = z + 1, inset = 2, name = "ArtFrame" })
		if art then
			stroke.Enabled = false
		end
		-- Rarity ribbon along the top edge.
		local ribbon = Instance.new("Frame")
		ribbon.Name = "Ribbon"
		ribbon.Size = UDim2.new(1, 0, 0, 6)
		ribbon.BackgroundColor3 = rarity.fill
		ribbon.BorderSizePixel = 0
		ribbon.ZIndex = z + 2
		local ribbonCorner = Instance.new("UICorner")
		ribbonCorner.CornerRadius = UDim.new(0, Tokens.radius.lg)
		ribbonCorner.Parent = ribbon
		ribbon.Parent = frame
		-- Content sits in a padded child so the art frame keeps the card's full size.
		local content = Instance.new("Frame")
		content.Name = "Content"
		content.Size = UDim2.fromScale(1, 1)
		content.BackgroundTransparency = 1
		content.ZIndex = z + 3
		content.Parent = frame
		local padding = Instance.new("UIPadding")
		padding.PaddingLeft = UDim.new(0, Tokens.spacing.lg)
		padding.PaddingRight = UDim.new(0, Tokens.spacing.lg)
		padding.PaddingTop = UDim.new(0, Tokens.spacing.md + Tokens.spacing.xs)
		padding.PaddingBottom = UDim.new(0, Tokens.spacing.md)
		padding.Parent = content
		local scale = Instance.new("UIScale")
		scale.Parent = frame
		-- State badge (lock / check) top-right.
		local stateBadge = Instance.new("Frame")
		stateBadge.Name = "StateBadge"
		stateBadge.AnchorPoint = Vector2.new(1, 0)
		stateBadge.Position = UDim2.new(1, -Tokens.spacing.sm, 0, Tokens.spacing.sm)
		stateBadge.Size = UDim2.fromOffset(Tokens.icon.md + 6, Tokens.icon.md + 6)
		stateBadge.BackgroundColor3 = Tokens.color.creamPill
		stateBadge.ZIndex = z + 4
		local stateCorner = Instance.new("UICorner")
		stateCorner.CornerRadius = UDim.new(1, 0)
		stateCorner.Parent = stateBadge
		local stateStroke = Instance.new("UIStroke")
		stateStroke.Thickness = Tokens.stroke.standard
		stateStroke.Color = Tokens.color.outline
		stateStroke.Parent = stateBadge
		stateBadge.Parent = frame
		local lockIcon = Icons.lock(stateBadge, Tokens.icon.md - 2, { zIndex = z + 5 })
		lockIcon.AnchorPoint = Vector2.new(0.5, 0.5)
		lockIcon.Position = UDim2.fromScale(0.5, 0.5)
		local checkIcon = Icons.check(stateBadge, Tokens.icon.md - 2, { zIndex = z + 5, color = Tokens.color.featherWhite })
		checkIcon.AnchorPoint = Vector2.new(0.5, 0.5)
		checkIcon.Position = UDim2.fromScale(0.5, 0.5)
		checkIcon.Visible = false
		local name = FrameKit.pill(content, "Name", entry.displayName, {
			size = UDim2.new(1, -(Tokens.icon.md + Tokens.spacing.md), 0, Tokens.typography.label.size + Tokens.spacing.sm),
			textSize = Tokens.typography.body.size,
			zIndex = z + 4,
			art = false,
			fill = rarity.fill,
			textColor = Tokens.color.featherWhite,
		})
		name.TextStrokeTransparency = 0.4
		name.Position = UDim2.fromOffset(0, 0)
		local odds = FrameKit.text(content, "Odds", "", "caption", { zIndex = z + 4, color = Tokens.color.inkMuted })
		odds.Position = UDim2.fromOffset(0, Tokens.typography.label.size + Tokens.spacing.md)
		local effect = FrameKit.text(content, "Effect", "", "caption", { zIndex = z + 4, color = Tokens.color.inkStrong })
		effect.Position = UDim2.fromOffset(0, Tokens.typography.label.size + Tokens.spacing.md + Tokens.typography.caption.size + 2)
		effect.Size = UDim2.new(1, -(tap + Tokens.spacing.sm), 0, Tokens.typography.caption.size * 2 + 4)
		local equip = Button.build(content, {
			text = "Equip",
			variant = "teal",
			minimumTapTarget = tap,
			motion = motion,
			size = UDim2.fromOffset(tap * 2 + Tokens.spacing.sm, tap - Tokens.spacing.xs),
			zIndex = z + 4,
			textSize = Tokens.typography.caption.size,
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
				local result = deps.net:request("ClassEquip", { classId = entry.id, slot = state.slot })
				if result.ok then
					deps.audio:play(Tokens.sound.uiConfirm)
					deps.haptics:pulse(0.3, 0.06)
				else
					deps.audio:play(Tokens.sound.uiError)
					deps.toasts:push(
						if result.code == "not_authorized" then "Roll to unlock this class first" else "Could not equip",
						"warning"
					)
				end
			end,
		})
		equip.button.AnchorPoint = Vector2.new(1, 1)
		equip.button.Position = UDim2.fromScale(1, 1)
		table.insert(cleanups, equip.destroy)
		frame.Parent = grid
		local card: Card = {
			frame = frame,
			name = name,
			odds = odds,
			effect = effect,
			stroke = stroke,
			scale = scale,
			equip = equip,
			id = entry.id,
			art = art,
			rarity = rarityName,
			lockIcon = lockIcon,
			checkIcon = checkIcon,
			stateBadge = stateBadge,
		}
		table.insert(cards, card)
		byId[entry.id] = card
	end

	local function describeEffect(entry: any): string
		local parts = {}
		for key, value in pairs(entry.effect or {}) do
			if key == "bagCapacityMultiplier" then
				table.insert(parts, string.format("Bag x%.1f", value))
			elseif key == "sellMultiplier" then
				table.insert(parts, string.format("Sales x%.1f", value))
			elseif key == "rakeYieldMultiplier" then
				table.insert(parts, string.format("Rake x%.2f", value))
			elseif key == "rakeUpgradeCostMultiplier" then
				table.insert(parts, string.format("Rake paths %d%% off", math.floor((1 - value) * 100 + 0.5)))
			elseif key == "blastRadiusMultiplier" then
				table.insert(parts, string.format("Blast x%.1f", value))
			elseif key == "miniChargeChance" then
				table.insert(parts, string.format("%d%% mini-charges", math.floor(value * 100 + 0.5)))
			elseif key == "gemFindChance" then
				table.insert(parts, string.format("%d%% Gem finds", math.floor(value * 100 + 0.5)))
			elseif key == "grantsScoutChick" then
				table.insert(parts, "Free Scout Chick")
			elseif key == "grantsAllPassiveBonuses" then
				table.insert(parts, "Every passive bonus")
			end
		end
		table.sort(parts)
		return if #parts == 0 then "Steady and dependable" else table.concat(parts, "  -  ")
	end

	-- Roll controls.
	local controls = Instance.new("Frame")
	controls.Name = "Controls"
	controls.BackgroundTransparency = 1
	controls.Size = UDim2.new(1, 0, 0, tap)
	controls.AutomaticSize = Enum.AutomaticSize.Y
	controls.LayoutOrder = 5
	controls.ZIndex = z
	local controlsLayout = Instance.new("UIListLayout")
	controlsLayout.FillDirection = Enum.FillDirection.Horizontal
	controlsLayout.SortOrder = Enum.SortOrder.LayoutOrder
	controlsLayout.Padding = UDim.new(0, Tokens.spacing.sm)
	controlsLayout.Wraps = true
	controlsLayout.Parent = controls
	controls.Parent = container
	local rollHandle, autoHandle

	local function refreshHeader()
		local projection = deps.profile.projection
		local gems = projection and projection.currencies.gems or 0
		local ent = entitlements()
		header.Text = string.format(
			"Gems %d    -    Roll costs %d Gems%s%s",
			gems,
			cfg.classes.rollGemCost,
			if ent.doubleLuck then "    -    2x Luck active" else "",
			if ent.fastRolls then "    -    Fast Rolls" else ""
		)
	end

	local function render()
		local projection = deps.profile.projection
		if not projection then
			return
		end
		refreshHeader()
		local ent = entitlements()
		local odds = ClassRoll.odds(cfg, ent.doubleLuck == true)
		local count = slotCount()
		for index, handle in ipairs(slotHandles) do
			handle.button.Visible = index <= count
			local equipped = projection.classes.equipped[index]
			local entry = equipped and cfg.classes.weights[table.find(odds, nil) or 1]
			local _ = entry
			local displayName = "empty"
			for _, weightEntry in ipairs(cfg.classes.weights) do
				if weightEntry.id == equipped then
					displayName = weightEntry.displayName
				end
			end
			handle.setText(string.format("Slot %d: %s", index, displayName))
			handle.button.BackgroundColor3 = if index == state.slot then Tokens.color.gold else Tokens.color.creamPill
		end
		for index, card in ipairs(cards) do
			local entry = cfg.classes.weights[index]
			local owned = projection.classes.owned[entry.id] == true
			local equippedIndex = table.find(projection.classes.equipped, entry.id)
			card.odds.Text = string.format("%.1f%% chance%s", odds[index].percent, if owned then "  -  owned" else "")
			card.effect.Text = describeEffect(entry)
			card.equip.button.Visible = owned
			card.equip.setText(if equippedIndex then "Equipped" else "Equip")
			card.equip.setEnabled(equippedIndex == nil and not state.rolling)
			card.equip.setSelected(equippedIndex ~= nil)
			card.stroke.Color = if equippedIndex then Tokens.color.goldLight else (Tokens.rarity :: any)[card.rarity].deep
			card.stroke.Thickness = if equippedIndex then Tokens.stroke.frame else Tokens.stroke.bold
			if card.art then
				Skin.apply(
					card.art,
					"class." .. card.rarity .. (if equippedIndex then ".equipped" elseif owned then ".owned" else ".locked")
				)
			end
			card.lockIcon.Visible = not owned
			card.checkIcon.Visible = equippedIndex ~= nil
			card.stateBadge.Visible = not owned or equippedIndex ~= nil
			card.stateBadge.BackgroundColor3 = if equippedIndex then Tokens.color.success else Tokens.color.creamPill
			card.frame.BackgroundTransparency = if owned then 0 else 0.35
			card.effect.TextTransparency = if owned then 0 else 0.35
		end
		if rollHandle then
			local gems = projection.currencies.gems
			rollHandle.setEnabled(not state.rolling and gems >= cfg.classes.rollGemCost)
		end
	end

	-- Reveal animation: a highlight sweeps the cards, decelerating, and lands on the committed class.
	local function reveal(result: any, onLanded: () -> ())
		local seconds = result.animationSeconds or cfg.lobby.classRollAnimationSeconds
		local scaled = seconds * deps.accessibility:motionScale()
		local landing = byId[result.classId]
		local started = os.clock()
		local index = 1
		deps.audio:play(Tokens.sound.rollSpin)
		task.spawn(function()
			local lastHighlight: Card? = nil
			while os.clock() - started < scaled and not state.closed do
				local t = (os.clock() - started) / math.max(scaled, 0.05)
				local card = cards[(index % #cards) + 1]
				index += 1
				if lastHighlight then
					lastHighlight.scale.Scale = 1
				end
				card.scale.Scale = 1.04
				lastHighlight = card
				deps.audio:play(Tokens.sound.uiTap, { pitchVariance = 0.08 })
				task.wait(0.05 + t * t * 0.28) -- decelerate toward the landing
			end
			if lastHighlight then
				lastHighlight.scale.Scale = 1
			end
			if state.closed then
				return
			end
			-- Land: pop the committed card, then announce.
			landing.scale.Scale = 1.1
			Tween.scale(landing.scale, "release", motion, 1)
			Tween.rotationPunch(landing.frame, motion, 0)
			Confetti.burst(landing.frame, {
				origin = UDim2.fromScale(0.5, 0.4),
				count = 24,
				spread = 140,
				motion = motion,
				tier = deps.quality and deps.quality:tier() or nil,
				zIndex = z + 8,
			})
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
				autoHandle.setText("Auto roll: off")
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
			deps.toasts:push("Not enough Gems for a roll", "warning")
			stopAuto(if auto then "Auto roll stopped: out of Gems" else nil)
			return
		end
		state.rolling = true
		resultLine.Visible = false
		render()
		if rollHandle then
			rollHandle.setPending(true, "Rolling...")
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
				then "Not enough Gems for a roll"
				elseif result.code == "rate_limited" then "Rolling too fast"
				elseif result.message == "not_in_lobby" then "Rolls happen between searches"
				else "Roll unavailable"
			deps.toasts:push(message, "warning")
			stopAuto(if auto then "Auto roll stopped" else nil)
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
		text = string.format("Roll  -  %d Gems", cfg.classes.rollGemCost),
		variant = "primary",
		icon = nil,
		sound = function()
			deps.audio:play(Tokens.sound.uiTap)
		end,
		hoverSound = function()
			deps.audio:play(Tokens.sound.uiHover)
		end,
		minimumTapTarget = tap,
		motion = motion,
		size = UDim2.fromOffset(200, tap),
		zIndex = z + 1,
		onActivated = function()
			rollOnce(false)
		end,
	})
	rollHandle.button.LayoutOrder = 1
	rollHandle.button.Name = "RollButton"
	autoHandle = Button.build(controls, {
		text = "Auto roll: off",
		variant = "secondary",
		minimumTapTarget = tap,
		motion = motion,
		size = UDim2.fromOffset(170, tap),
		zIndex = z + 1,
		onActivated = function()
			if state.auto then
				stopAuto("Auto roll stopped")
			else
				state.auto = true
				autoHandle.setText("Auto roll: on (tap to stop)")
				deps.audio:play(Tokens.sound.uiConfirm)
				rollOnce(true)
			end
		end,
	})
	autoHandle.button.LayoutOrder = 2
	autoHandle.button.Name = "AutoRollButton"
	table.insert(cleanups, rollHandle.destroy)
	table.insert(cleanups, autoHandle.destroy)
	api.setInitialFocus(rollHandle.button)

	-- Odds/terms line (readable before action).
	local terms = FrameKit.text(
		container,
		"Terms",
		"Odds are shown on every card. A roll always unlocks or re-equips the class it lands on; duplicates are not refunded.",
		"caption",
		{ zIndex = z, color = Tokens.color.inkMuted }
	)
	terms.LayoutOrder = 6
	terms.Size = UDim2.new(1, 0, 0, Tokens.typography.caption.size * 2 + 6)

	render()
	table.insert(
		cleanups,
		deps.profile.changed:Connect(function()
			if not state.rolling then
				render()
			else
				refreshHeader()
			end
		end)
	)
	deps.audio:play(Tokens.sound.uiOpen)
	-- Studio verification hook: the same routines the Roll / Auto buttons call (never a shortcut).
	if api.registerDebug then
		api.registerDebug({
			roll = function()
				rollOnce(false)
				return { rolling = state.rolling }
			end,
			auto = function()
				if state.auto then
					stopAuto("Auto roll stopped")
				else
					state.auto = true
					autoHandle.setText("Auto roll: on (tap to stop)")
					rollOnce(true)
				end
				return { auto = state.auto }
			end,
			stop = function()
				stopAuto("Auto roll stopped")
				return { auto = state.auto, stops = stats.autoStops }
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
