--!strict
-- What is on screen while a player is at Molly's map: a dark slate banner across the top with the
-- one instruction (or the result), a feather counter on the right (carried against the next crate)
-- with the round's surveys-left pips under it, the top-down nest map in the middle - four big
-- labelled area buttons inside the BACK / FRONT / BARN / FENCE landmarks, each showing its last
-- reading - and at the bottom the one green button with a small red BACK beside it. It draws and
-- reports presses; the MollyController owns every decision.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local Motion = require(Shared.Design.Motion)
local NestSurvey = require(Shared.Domain.NestSurvey)
local FrameKit = require(script.Parent.Components.Frame)
local Button = require(script.Parent.Components.Button)
local Depth = require(script.Parent.Components.Depth)
local Skin = require(script.Parent.Components.Skin)
local SafeArea = require(script.Parent.SafeArea)

local SurveyPanel = {}

local PLATE = Tokens.color.surface
local WELL = Tokens.color.panelDeep
local MAP_W, MAP_H = 620, 420
local DESIGN = Vector2.new(1200, 640) -- the panel's drawn size before the fit scale

export type State = {
	title: string, -- the sign: "PICK AN AREA", "LISTENING...", the result
	caption: string?, -- one short line under the sign, or nothing
	carried: number,
	cost: number, -- the next crate (0 once the round's surveys are spent)
	usesLeft: number?, -- surveys still available this round; nil hides the pips
	usesMax: number?,
	selected: string?, -- the area picked on the map
	readings: { [string]: { signal: string, short: string } }, -- the latest reading of each area
	mapEnabled: boolean, -- false while a scan runs or nothing more can be bought
	primary: string?, -- the button's words; nil hides it
	primaryEnabled: boolean,
	back: boolean, -- show BACK
	tone: ("plain" | "good" | "bad")?,
}

export type Handle = {
	gui: ScreenGui,
	setState: (state: State) -> (),
	primaryButton: TextButton,
	areaButtons: { [string]: TextButton },
	destroy: () -> (),
}

local function outlined(label: TextLabel, thickness: number, color: Color3?)
	FrameKit.outline(label, thickness, color)
end

-- Badge colours per reading: gold for strong, amber for weak, slate for none.
local function badgeColor(signal: string): Color3
	if signal == "strong" then
		return Tokens.color.success
	elseif signal == "weak" then
		return Tokens.color.gold
	end
	return Tokens.color.cocoa
end

function SurveyPanel.create(
	parent: Instance,
	deps: { audio: any, accessibility: any, config: { [string]: any } },
	callbacks: { onSelect: (region: string) -> (), onPrimary: () -> (), onBack: () -> () }
): Handle
	local motion = deps.accessibility:motionSettings()
	local tap = Tokens.layout.minimumTapTargetPx
	local gui = Instance.new("ScreenGui")
	gui.Name = "SFE_Survey"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = Tokens.zIndex.modal - 1
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = parent
	local _, scaleCleanup, stage = SafeArea.applyScale(gui, deps.config)

	-- No visible dim behind the panel (owner, 17 Sep 2026: no dark overlays behind menus).
	local dim = Instance.new("Frame")
	dim.Name = "Dim"
	dim.BackgroundColor3 = Tokens.color.overlay
	dim.BackgroundTransparency = 1
	dim.Size = UDim2.fromScale(1, 1)
	dim.ZIndex = 1
	dim.Parent = stage

	-- Everything below is drawn at one design size and fitted to the screen by a single UIScale, so a
	-- landscape phone gets the same panel smaller instead of offset-sized pieces piling on each other.
	local layout = Instance.new("Frame")
	layout.Name = "Layout"
	layout.AnchorPoint = Vector2.new(0.5, 0.5)
	layout.Position = UDim2.fromScale(0.5, 0.5)
	layout.Size = UDim2.fromOffset(DESIGN.X, DESIGN.Y)
	layout.BackgroundTransparency = 1
	layout.ZIndex = 1
	layout.Parent = stage
	local layoutScale = Instance.new("UIScale")
	layoutScale.Parent = layout
	local function fitLayout()
		local stageScale = math.max(0.1, SafeArea.scaleOf(stage))
		local w = stage.AbsoluteSize.X / stageScale
		local h = stage.AbsoluteSize.Y / stageScale
		if w <= 0 or h <= 0 then
			return
		end
		layoutScale.Scale = math.min(1, w / DESIGN.X, h / DESIGN.Y)
	end
	fitLayout()
	stage:GetPropertyChangedSignal("AbsoluteSize"):Connect(fitLayout)

	-- The sign: a dark slate banner with a green line along its top, hung from the top of the screen.
	local sign = Instance.new("Frame")
	sign.Name = "Sign"
	sign.AnchorPoint = Vector2.new(0.5, 0)
	sign.Position = UDim2.new(0.5, 0, 0, Tokens.spacing.lg)
	sign.Size = UDim2.new(0.5, 0, 0, 104)
	sign.ZIndex = 2
	Depth.panel(sign, PLATE, { radius = Tokens.radius.lg })
	local signCap = Instance.new("UISizeConstraint")
	signCap.MaxSize = Vector2.new(620, 104)
	signCap.MinSize = Vector2.new(300, 104)
	signCap.Parent = sign
	sign.Parent = layout
	local signLine = Instance.new("Frame")
	signLine.Name = "Line"
	signLine.AnchorPoint = Vector2.new(0.5, 0)
	signLine.Position = UDim2.new(0.5, 0, 0, 3)
	signLine.Size = UDim2.new(1, -Tokens.radius.lg * 2, 0, 4)
	signLine.BackgroundColor3 = Tokens.color.success
	signLine.BorderSizePixel = 0
	signLine.ZIndex = 3
	local signLineCorner = Instance.new("UICorner")
	signLineCorner.CornerRadius = UDim.new(1, 0)
	signLineCorner.Parent = signLine
	signLine.Parent = sign
	local inset = Instance.new("Frame")
	inset.Name = "Inset"
	inset.AnchorPoint = Vector2.new(0.5, 0.5)
	inset.Position = UDim2.fromScale(0.5, 0.5)
	inset.Size = UDim2.new(1, -Tokens.spacing.lg * 2, 1, -Tokens.spacing.lg)
	inset.BackgroundTransparency = 1
	inset.ZIndex = 3
	inset.Parent = sign
	local title = FrameKit.text(
		inset,
		"Title",
		"PICK AN AREA",
		"display",
		{ zIndex = 4, color = Tokens.color.featherWhite, align = Enum.TextXAlignment.Center }
	)
	title.Position = UDim2.fromScale(0, 0.04)
	title.Size = UDim2.fromScale(1, 0.58)
	title.TextScaled = true
	outlined(title, 3)
	local caption =
		FrameKit.text(inset, "Caption", "", "caption", { zIndex = 4, color = Tokens.color.inkMuted, align = Enum.TextXAlignment.Center })
	caption.Position = UDim2.fromScale(0, 0.64)
	caption.Size = UDim2.fromScale(1, 0.34)
	caption.TextScaled = true
	outlined(caption, 2)
	local signScale = Instance.new("UIScale")
	signScale.Parent = sign

	-- The feather counter, top right: a slate pill with a dark well for the numerals.
	local counter = Instance.new("Frame")
	counter.Name = "Counter"
	counter.AnchorPoint = Vector2.new(1, 0)
	counter.Position = UDim2.new(1, -Tokens.spacing.lg, 0, Tokens.spacing.lg + 20)
	counter.Size = UDim2.fromOffset(250, 64)
	counter.ZIndex = 2
	Depth.panel(counter, PLATE, { radius = Tokens.radius.lg })
	counter.Parent = layout
	local counterInset = Instance.new("Frame")
	counterInset.Name = "Inset"
	counterInset.AnchorPoint = Vector2.new(0.5, 0.5)
	counterInset.Position = UDim2.fromScale(0.5, 0.5)
	counterInset.Size = UDim2.new(1, -Tokens.spacing.md, 1, -Tokens.spacing.md)
	counterInset.BackgroundColor3 = WELL
	counterInset.ZIndex = 3
	local counterCorner = Instance.new("UICorner")
	counterCorner.CornerRadius = UDim.new(0, Tokens.radius.md)
	counterCorner.Parent = counterInset
	Depth.keyline(counterInset, Tokens.depth.keylineThin)
	counterInset.Parent = counter
	local featherIcon = Skin.icon(counterInset, "icon.feather", 36, 4)
	if featherIcon then
		featherIcon.AnchorPoint = Vector2.new(0, 0.5)
		featherIcon.Position = UDim2.new(0, Tokens.spacing.sm, 0.5, 0)
		featherIcon.ImageColor3 = Tokens.color.featherWhite
	end
	local count = FrameKit.text(
		counterInset,
		"Count",
		"0 / 100",
		"display",
		{ zIndex = 4, color = Tokens.color.featherWhite, align = Enum.TextXAlignment.Right }
	)
	count.AnchorPoint = Vector2.new(1, 0.5)
	count.Position = UDim2.new(1, -Tokens.spacing.md, 0.5, 0)
	count.Size = UDim2.new(1, -60, 0.8, 0)
	count.TextScaled = true
	outlined(count, 3)

	-- Surveys left this round: one pip per survey, lit while it is still to be bought.
	local pips = Instance.new("Frame")
	pips.Name = "Uses"
	pips.AnchorPoint = Vector2.new(1, 0)
	pips.Position = UDim2.new(1, -Tokens.spacing.lg, 0, Tokens.spacing.lg + 20 + 64 + Tokens.spacing.xs)
	pips.Size = UDim2.fromOffset(250, 26)
	pips.BackgroundTransparency = 1
	pips.ZIndex = 2
	pips.Visible = false
	pips.Parent = layout
	local pipsLabel = FrameKit.text(
		pips,
		"Label",
		"SURVEYS LEFT",
		"caption",
		{ zIndex = 3, color = Tokens.color.featherWhite, align = Enum.TextXAlignment.Right }
	)
	pipsLabel.AnchorPoint = Vector2.new(1, 0.5)
	pipsLabel.Position = UDim2.new(1, -Tokens.spacing.md, 0.5, 0)
	pipsLabel.Size = UDim2.fromScale(0.6, 1)
	outlined(pipsLabel, 2)
	local pipDots: { Frame } = {}
	local function buildPips(total: number)
		for _, dot in ipairs(pipDots) do
			dot:Destroy()
		end
		pipDots = {}
		for i = 1, total do
			local dot = Instance.new("Frame")
			dot.Name = "Pip" .. i
			dot.AnchorPoint = Vector2.new(0, 0.5)
			dot.Position = UDim2.new(0, Tokens.spacing.sm + (i - 1) * 26, 0.5, 0)
			dot.Size = UDim2.fromOffset(18, 18)
			dot.BackgroundColor3 = Tokens.color.gold
			dot.ZIndex = 3
			local dotCorner = Instance.new("UICorner")
			dotCorner.CornerRadius = UDim.new(1, 0)
			dotCorner.Parent = dot
			Depth.keyline(dot, Tokens.depth.keylineThin)
			dot.Parent = pips
			table.insert(pipDots, dot)
		end
	end

	-- The nest map: a slate board, the four landmarks on its edges, and a 2x2 of big area buttons laid
	-- the way the yard lies (BARN left, FENCE right, BACK up, FRONT down).
	local map = Instance.new("Frame")
	map.Name = "Map"
	map.AnchorPoint = Vector2.new(0.5, 0.5)
	map.Position = UDim2.new(0.5, 0, 0.5, 10)
	map.Size = UDim2.fromScale(0.62, 0.5)
	map.ZIndex = 2
	Depth.panel(map, PLATE, { radius = Tokens.radius.xl })
	local mapCap = Instance.new("UISizeConstraint")
	mapCap.MaxSize = Vector2.new(MAP_W, MAP_H)
	mapCap.MinSize = Vector2.new(300, 210)
	mapCap.Parent = map
	local mapRatio = Instance.new("UIAspectRatioConstraint")
	mapRatio.AspectRatio = MAP_W / MAP_H
	mapRatio.Parent = map
	map.Parent = layout
	local edge = 0.1 -- the landmark margin, as a fraction of the map on each side
	local function landmark(name: string, text: string, position: UDim2, size: UDim2, rotation: number)
		local mark =
			FrameKit.text(map, name, text, "heading", { zIndex = 4, color = Tokens.color.goldLight, align = Enum.TextXAlignment.Center })
		mark.AnchorPoint = Vector2.new(0.5, 0.5)
		mark.Position = position
		mark.Size = size
		mark.Rotation = rotation
		mark.TextScaled = true
		outlined(mark, 2.5)
	end
	landmark("LandBack", NestSurvey.LANDMARKS.top, UDim2.fromScale(0.5, edge / 2), UDim2.fromScale(0.4, edge * 0.8), 0)
	landmark("LandFront", NestSurvey.LANDMARKS.bottom, UDim2.fromScale(0.5, 1 - edge / 2), UDim2.fromScale(0.4, edge * 0.8), 0)
	landmark("LandBarn", NestSurvey.LANDMARKS.left, UDim2.fromScale(edge / 2, 0.5), UDim2.fromScale(0.4, edge * 0.55), -90)
	landmark("LandFence", NestSurvey.LANDMARKS.right, UDim2.fromScale(1 - edge / 2, 0.5), UDim2.fromScale(0.4, edge * 0.55), 90)
	local field = Instance.new("Frame")
	field.Name = "Field"
	field.AnchorPoint = Vector2.new(0.5, 0.5)
	field.Position = UDim2.fromScale(0.5, 0.5)
	field.Size = UDim2.fromScale(1 - edge * 2, 1 - edge * 2)
	field.BackgroundColor3 = WELL
	field.ZIndex = 3
	local fieldCorner = Instance.new("UICorner")
	fieldCorner.CornerRadius = UDim.new(0, Tokens.radius.lg)
	fieldCorner.Parent = field
	Depth.keyline(field, Tokens.depth.keylineThin)
	field.Parent = map
	local areaHandles: { [string]: any } = {}
	local areaButtons: { [string]: TextButton } = {}
	local badges: { [string]: TextLabel } = {}
	for _, region in ipairs(NestSurvey.REGIONS) do
		local row, col = NestSurvey.rowCol(region)
		local handle = Button.build(field, {
			text = NestSurvey.name(region),
			variant = "secondary",
			minimumTapTarget = tap,
			motion = motion,
			size = UDim2.new(0.5, -Tokens.spacing.md * 1.5, 0.5, -Tokens.spacing.md * 1.5),
			zIndex = 4,
			textSize = 30,
			sound = function()
				deps.audio:play(Tokens.sound.uiSelect)
			end,
			hoverSound = function()
				deps.audio:play(Tokens.sound.uiHover)
			end,
			onActivated = function()
				callbacks.onSelect(region)
			end,
		})
		handle.button.Name = "Area_" .. region
		-- Two lines ("BACK" over "BARN"), scaled to the button: a single truncated line read "BACK...".
		local areaLabel = handle.button:FindFirstChild("Label", true)
		if areaLabel and areaLabel:IsA("TextLabel") then
			areaLabel.Text = string.gsub(NestSurvey.name(region), " ", "\n")
			areaLabel.TextTruncate = Enum.TextTruncate.None
			areaLabel.TextWrapped = true
			areaLabel.TextScaled = true
			-- The top of the button: the reading badge owns the bottom strip.
			areaLabel.AnchorPoint = Vector2.new(0.5, 0)
			areaLabel.Position = UDim2.fromScale(0.5, 0.08)
			areaLabel.Size = UDim2.fromScale(1, 0.56)
			local cap = Instance.new("UITextSizeConstraint")
			cap.MaxTextSize = 30
			cap.MinTextSize = 12
			cap.Parent = areaLabel
		end
		handle.button.AnchorPoint = Vector2.new(col - 1, row - 1)
		handle.button.Position = UDim2.new(
			col - 1,
			if col == 1 then Tokens.spacing.md else -Tokens.spacing.md,
			row - 1,
			if row == 1 then Tokens.spacing.md else -Tokens.spacing.md
		)
		-- The area's last reading, a pill along the bottom of its button.
		local badge = FrameKit.text(
			handle.button,
			"Reading",
			"",
			"label",
			{ zIndex = 10, color = Tokens.color.featherWhite, align = Enum.TextXAlignment.Center }
		)
		badge.AnchorPoint = Vector2.new(0.5, 1)
		badge.Position = UDim2.new(0.5, 0, 1, -Tokens.spacing.md)
		badge.Size = UDim2.fromScale(0.8, 0.26)
		badge.BackgroundTransparency = 0
		badge.TextScaled = true
		badge.Visible = false
		local badgeCorner = Instance.new("UICorner")
		badgeCorner.CornerRadius = UDim.new(1, 0)
		badgeCorner.Parent = badge
		Depth.keyline(badge, Tokens.depth.keylineThin)
		outlined(badge, 2)
		areaHandles[region] = handle
		areaButtons[region] = handle.button
		badges[region] = badge
	end

	-- The bottom row: a red BACK and the green primary.
	local actions = Instance.new("Frame")
	actions.Name = "Actions"
	actions.AnchorPoint = Vector2.new(0.5, 1)
	actions.Position = UDim2.new(0.5, 0, 1, -Tokens.spacing.lg)
	actions.Size = UDim2.new(0.8, 0, 0, 96)
	actions.BackgroundTransparency = 1
	actions.ZIndex = 2
	actions.Parent = layout
	local back = Button.build(actions, {
		text = "X  BACK",
		variant = "danger",
		minimumTapTarget = tap,
		motion = motion,
		size = UDim2.fromOffset(150, 72),
		zIndex = 3,
		textSize = 22,
		sound = function()
			deps.audio:play(Tokens.sound.uiCancel)
		end,
		onActivated = callbacks.onBack,
	})
	back.button.AnchorPoint = Vector2.new(1, 0.5)
	back.button.Position = UDim2.new(0.5, -300, 0.5, 0)
	local primary = Button.build(actions, {
		text = "SURVEY",
		variant = "success",
		minimumTapTarget = tap,
		motion = motion,
		size = UDim2.fromOffset(560, 96),
		zIndex = 3,
		textSize = 40,
		sound = function()
			deps.audio:play(Tokens.sound.uiConfirm)
		end,
		hoverSound = function()
			deps.audio:play(Tokens.sound.uiHover)
		end,
		onActivated = callbacks.onPrimary,
	})
	primary.button.AnchorPoint = Vector2.new(0.5, 0.5)
	primary.button.Position = UDim2.fromScale(0.5, 0.5)
	local primaryCap = Instance.new("UISizeConstraint")
	primaryCap.MaxSize = Vector2.new(560, 96)
	primaryCap.Parent = primary.button

	local lastTitle: string? = nil
	local function setState(state: State)
		if state.title ~= lastTitle and lastTitle ~= nil and not motion.reducedMotion then
			signScale.Scale = 1.06
			TweenService:Create(signScale, TweenInfo.new(Motion.duration("standard", motion), Tokens.motion.easeBack), { Scale = 1 }):Play()
		end
		lastTitle = state.title
		title.Text = state.title
		title.TextColor3 = if state.tone == "good"
			then Tokens.color.success
			elseif state.tone == "bad" then Tokens.color.ember
			else Tokens.color.featherWhite
		caption.Text = state.caption or ""
		caption.Visible = (state.caption or "") ~= ""
		count.Text = if state.cost > 0 then string.format("%d / %d", state.carried, state.cost) else tostring(state.carried)
		count.TextColor3 = if state.carried >= state.cost then Tokens.color.featherWhite else Tokens.color.ember
		local usesMax = state.usesMax or 0
		pips.Visible = state.usesLeft ~= nil and usesMax > 0
		if pips.Visible then
			if #pipDots ~= usesMax then
				buildPips(usesMax)
			end
			local left = state.usesLeft or 0
			for i, dot in ipairs(pipDots) do
				-- Spent pips go dark from the left; the ones still to buy stay lit.
				local lit = i > usesMax - left
				dot.BackgroundColor3 = if lit then Tokens.color.gold else WELL
				dot.BackgroundTransparency = 0
			end
		end
		for region, handle in pairs(areaHandles) do
			handle.setSelected(state.selected == region)
			handle.setEnabled(state.mapEnabled)
			local reading = state.readings[region]
			local badge = badges[region]
			badge.Visible = reading ~= nil
			if reading then
				badge.Text = reading.short
				badge.BackgroundColor3 = badgeColor(reading.signal)
			end
		end
		primary.button.Visible = state.primary ~= nil
		if state.primary then
			primary.setText(state.primary)
		end
		primary.setEnabled(state.primaryEnabled)
		primary.pulse(state.primaryEnabled)
		back.button.Visible = state.back
	end

	return {
		gui = gui,
		primaryButton = primary.button,
		areaButtons = areaButtons,
		setState = setState,
		destroy = function()
			for _, handle in pairs(areaHandles) do
				handle.destroy()
			end
			primary.destroy()
			back.destroy()
			scaleCleanup()
			gui:Destroy()
		end,
	}
end

return SurveyPanel
