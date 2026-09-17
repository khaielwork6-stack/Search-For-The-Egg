--!strict
-- The big centre-top announcement: one dark-kit plate under the objective pill for the round's rare
-- moments (THE EGG IS UNCOVERED!, Soryn has the Egg!, EGG RETURNED!, a first Rainbow Feather). The
-- server sends them through AnnouncementService; any controller may also call `show` locally.
--
--   * one at a time: a second announcement queues behind the first and never stacks on it;
--   * identical text merges: the same words again (showing or queued) refresh the one plate;
--   * slides down a few pixels and pops in (Back-out), holds ~2.6 s (shorter while others wait),
--     then shrinks away; reduced motion fades without the slide or the pop;
--   * big display lettering with a black stroke, a tone accent: gold, a rainbow ramp that drifts
--     (static on the low tier and under reduced motion) or green;
--   * sits below the objective pill and well above the crosshair; toasts step down while it shows.
--
-- It is not a second notification system: no sound, no dedupe window of its own beyond the merge,
-- and everyday feedback stays on Components/Toast and UI/Feedback.deny.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local TextService = game:GetService("TextService")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local Motion = require(Shared.Design.Motion)
local Depth = require(script.Parent.Components.Depth)
local FrameKit = require(script.Parent.Components.Frame)
local SafeArea = require(script.Parent.SafeArea)

local AnnouncementBanner = {}
AnnouncementBanner.__index = AnnouncementBanner

export type Payload = {
	kind: string?,
	text: string,
	sub: string?,
	tone: string?, -- "gold" | "rainbow" | "info" | "success"
	userId: number?,
	position: Vector3?,
}

export type Options = {
	motion: () -> Motion.MotionSettings,
	tier: (() -> string)?,
	-- Stage-pixel y of the plate's top edge (the objective pill's bottom plus a gap).
	topPx: (() -> number)?,
	-- The plate's height while it shows, and 0 once it has gone (the toast stack steps aside).
	onSpace: ((px: number) -> ())?,
	holdSeconds: number?,
	-- Tests: queue logic only, no instances and no timers.
	headless: boolean?,
}

export type AnnouncementBanner = typeof(setmetatable(
	{} :: {
		_parent: Instance,
		_options: Options,
		_queue: { Payload },
		_current: Payload?,
		_token: number,
		_card: Frame?,
		_parts: { [string]: any },
		_spin: RBXScriptConnection?,
		shown: number,
		merged: number,
		dropped: number,
	},
	AnnouncementBanner
))

AnnouncementBanner.HOLD_SECONDS = 2.6
AnnouncementBanner.QUEUED_HOLD_SECONDS = 1.8
AnnouncementBanner.MAX_QUEUE = 4
AnnouncementBanner.TITLE_PX = 34
AnnouncementBanner.SUB_PX = 16

-- The game's one rainbow ramp (the banner, the Plume pill, the bag flash, the rainbow burst).
AnnouncementBanner.RAINBOW_STOPS = table.freeze({
	{ 0, Color3.fromRGB(255, 92, 92) },
	{ 0.18, Color3.fromRGB(255, 176, 60) },
	{ 0.36, Color3.fromRGB(255, 236, 90) },
	{ 0.54, Color3.fromRGB(110, 230, 110) },
	{ 0.72, Color3.fromRGB(80, 190, 255) },
	{ 0.88, Color3.fromRGB(170, 110, 255) },
	{ 1, Color3.fromRGB(255, 92, 200) },
})
local rainbowSequence: ColorSequence? = nil

function AnnouncementBanner.rainbow(): ColorSequence
	if not rainbowSequence then
		local keypoints = {}
		for _, stop in ipairs(AnnouncementBanner.RAINBOW_STOPS) do
			table.insert(keypoints, ColorSequenceKeypoint.new(stop[1], stop[2]))
		end
		rainbowSequence = ColorSequence.new(keypoints)
	end
	return rainbowSequence :: ColorSequence
end

local function toneOf(tone: string?): { accent: Color3, title: ColorSequence, glow: Color3 }
	if tone == "rainbow" then
		return { accent = Color3.fromRGB(226, 150, 255), title = AnnouncementBanner.rainbow(), glow = Color3.fromRGB(226, 150, 255) }
	elseif tone == "success" then
		return {
			accent = Tokens.color.success,
			title = ColorSequence.new(Tokens.color.featherWhite, Tokens.color.leafBright),
			glow = Tokens.color.leafBright,
		}
	elseif tone == "info" then
		return {
			accent = Tokens.color.sky,
			title = ColorSequence.new(Tokens.color.featherWhite, Tokens.color.featherWhite),
			glow = Tokens.color.sky,
		}
	end
	return {
		accent = Tokens.color.gold,
		title = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Tokens.color.goldLight),
			ColorSequenceKeypoint.new(0.55, Tokens.color.gold),
			ColorSequenceKeypoint.new(1, Tokens.color.goldDeep),
		}),
		glow = Tokens.color.goldLight,
	}
end

function AnnouncementBanner.new(parent: Instance, options: Options): AnnouncementBanner
	local self = setmetatable({
		_parent = parent,
		_options = options,
		_queue = {},
		_current = nil,
		_token = 0,
		_card = nil,
		_parts = {},
		_spin = nil,
		shown = 0,
		merged = 0,
		dropped = 0,
	}, AnnouncementBanner)
	if not options.headless then
		self:_build()
	end
	return self
end

-- Shows (or queues) an announcement. Returns false when it merged into the same words already on
-- screen or waiting, or was not showable.
function AnnouncementBanner.show(self: AnnouncementBanner, payload: Payload): boolean
	if type(payload) ~= "table" or type(payload.text) ~= "string" or payload.text == "" then
		return false
	end
	local current = self._current
	if current and current.text == payload.text then
		self.merged += 1
		self:_refresh()
		return false
	end
	for _, queued in ipairs(self._queue) do
		if queued.text == payload.text then
			self.merged += 1
			return false
		end
	end
	table.insert(self._queue, table.clone(payload) :: Payload)
	while #self._queue > AnnouncementBanner.MAX_QUEUE do
		table.remove(self._queue, 1)
		self.dropped += 1
	end
	if not current then
		self:_next()
	end
	return true
end

function AnnouncementBanner.isShowing(self: AnnouncementBanner): boolean
	return self._current ~= nil
end

function AnnouncementBanner.current(self: AnnouncementBanner): Payload?
	return self._current
end

function AnnouncementBanner.queueLength(self: AnnouncementBanner): number
	return #self._queue
end

-- Drops everything (round over, returning to the lobby).
function AnnouncementBanner.clear(self: AnnouncementBanner)
	table.clear(self._queue)
	self._token += 1
	self._current = nil
	if self._card then
		self._card.Visible = false
	end
	self:_stopSpin()
	if self._options.onSpace then
		self._options.onSpace(0)
	end
end

-- Test hook: finishes the current plate at once (headless only uses this).
function AnnouncementBanner.advance(self: AnnouncementBanner)
	self._token += 1
	self._current = nil
	self:_next()
end

function AnnouncementBanner._next(self: AnnouncementBanner)
	local payload = table.remove(self._queue, 1)
	if not payload then
		self._current = nil
		if self._options.onSpace then
			self._options.onSpace(0)
		end
		return
	end
	self._current = payload
	self.shown += 1
	self._token += 1
	if self._options.headless then
		return
	end
	self:_present(payload, self._token)
end

-- ---------------------------------------------------------------------------------------------
-- The plate (built once, re-dressed per announcement)
-- ---------------------------------------------------------------------------------------------

function AnnouncementBanner._build(self: AnnouncementBanner)
	local z = Tokens.zIndex.toast + 2
	local card = Instance.new("Frame")
	card.Name = "Announcement"
	card.AnchorPoint = Vector2.new(0.5, 0)
	card.Position = UDim2.new(0.5, 0, 0, 72)
	card.Size = UDim2.fromOffset(360, 72)
	card.BackgroundColor3 = Tokens.color.panelDeep
	card.BackgroundTransparency = 0.04
	card.BorderSizePixel = 0
	card.Visible = false
	card.ZIndex = z
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, Tokens.radius.lg)
	corner.Parent = card
	local keyline = Depth.keyline(card, Tokens.depth.keyline)
	local scale = Instance.new("UIScale")
	scale.Parent = card

	-- Soft glow behind the plate in the tone colour (a wide, very transparent halo, not a dim).
	local glow = Instance.new("Frame")
	glow.Name = "Glow"
	glow.AnchorPoint = Vector2.new(0.5, 0.5)
	glow.Position = UDim2.fromScale(0.5, 0.5)
	glow.Size = UDim2.new(1, 36, 1, 26)
	glow.BackgroundColor3 = Tokens.color.gold
	glow.BackgroundTransparency = 0.78
	glow.BorderSizePixel = 0
	glow.ZIndex = z - 1
	local glowCorner = Instance.new("UICorner")
	glowCorner.CornerRadius = UDim.new(0, Tokens.radius.xl + 8)
	glowCorner.Parent = glow
	local glowFade = Instance.new("UIGradient")
	glowFade.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.2, 0.2),
		NumberSequenceKeypoint.new(0.8, 0.2),
		NumberSequenceKeypoint.new(1, 1),
	})
	glowFade.Parent = glow
	glow.Parent = card

	-- The face: slate with the kit's sheen, inset so the tone rim reads inside the black keyline.
	local face = Instance.new("Frame")
	face.Name = "Face"
	face.AnchorPoint = Vector2.new(0.5, 0.5)
	face.Position = UDim2.fromScale(0.5, 0.5)
	face.Size = UDim2.new(1, -6, 1, -6)
	face.BackgroundColor3 = Tokens.color.surface
	face.BorderSizePixel = 0
	face.ClipsDescendants = true
	face.ZIndex = z + 1
	local faceCorner = Instance.new("UICorner")
	faceCorner.CornerRadius = UDim.new(0, Tokens.radius.lg - 3)
	faceCorner.Parent = face
	Depth.applySheen(face, Tokens.color.surface)
	local rim = Instance.new("UIStroke")
	rim.Name = "ToneRim"
	rim.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	rim.Thickness = 2.5
	rim.Color = Color3.new(1, 1, 1)
	rim.Parent = face
	local rimGradient = Instance.new("UIGradient")
	rimGradient.Name = "RimTone"
	rimGradient.Parent = rim
	face.Parent = card

	-- Accent bar along the top edge of the face.
	local bar = Instance.new("Frame")
	bar.Name = "Accent"
	bar.Size = UDim2.new(1, 0, 0, 5)
	bar.BackgroundColor3 = Color3.new(1, 1, 1)
	bar.BorderSizePixel = 0
	bar.ZIndex = z + 2
	local barGradient = Instance.new("UIGradient")
	barGradient.Name = "BarTone"
	barGradient.Parent = bar
	bar.Parent = face

	-- One sheen sweep across the plate as it lands.
	local sweep = Instance.new("Frame")
	sweep.Name = "Sweep"
	sweep.Size = UDim2.fromScale(1, 1)
	sweep.BackgroundColor3 = Color3.new(1, 1, 1)
	sweep.BackgroundTransparency = 0
	sweep.BorderSizePixel = 0
	sweep.ZIndex = z + 2
	local sweepGradient = Instance.new("UIGradient")
	sweepGradient.Rotation = 20
	sweepGradient.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.42, 1),
		NumberSequenceKeypoint.new(0.5, 0.72),
		NumberSequenceKeypoint.new(0.58, 1),
		NumberSequenceKeypoint.new(1, 1),
	})
	sweepGradient.Offset = Vector2.new(-1, 0)
	sweepGradient.Parent = sweep
	sweep.Parent = face

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.AnchorPoint = Vector2.new(0.5, 0)
	title.BackgroundTransparency = 1
	title.Font = Tokens.typography.display.font
	title.TextColor3 = Color3.new(1, 1, 1)
	title.TextScaled = true
	title.ZIndex = z + 3
	local titleSize = Instance.new("UITextSizeConstraint")
	titleSize.MaxTextSize = AnnouncementBanner.TITLE_PX
	titleSize.MinTextSize = 18
	titleSize.Parent = title
	local titleStroke = FrameKit.outline(title, 3, Tokens.color.outline)
	local titleGradient = Instance.new("UIGradient")
	titleGradient.Name = "TitleTone"
	titleGradient.Rotation = 90
	titleGradient.Parent = title
	title.Parent = face

	local sub = Instance.new("TextLabel")
	sub.Name = "Sub"
	sub.AnchorPoint = Vector2.new(0.5, 0)
	sub.BackgroundTransparency = 1
	sub.Font = Tokens.typography.body.font
	sub.TextColor3 = Tokens.color.ink
	sub.TextScaled = true
	sub.ZIndex = z + 3
	local subSize = Instance.new("UITextSizeConstraint")
	subSize.MaxTextSize = AnnouncementBanner.SUB_PX
	subSize.MinTextSize = Tokens.typography.minimumBodySize
	subSize.Parent = sub
	local subStroke = FrameKit.outline(sub, 1.8, Tokens.color.outline)
	sub.Parent = face

	card.Parent = self._parent
	self._card = card
	self._parts = {
		scale = scale,
		glow = glow,
		face = face,
		rimGradient = rimGradient,
		barGradient = barGradient,
		sweepGradient = sweepGradient,
		title = title,
		titleSize = titleSize,
		titleGradient = titleGradient,
		sub = sub,
		subSize = subSize,
		keyline = keyline,
		rim = rim,
		titleStroke = titleStroke,
		subStroke = subStroke,
	}
end

function AnnouncementBanner._stopSpin(self: AnnouncementBanner)
	if self._spin then
		self._spin:Disconnect()
		self._spin = nil
	end
end

-- Lays the plate out for `payload`: width hugs the words, capped to the stage; height grows for a sub.
function AnnouncementBanner._layout(self: AnnouncementBanner, payload: Payload): (number, number)
	local card = self._card :: Frame
	local parts = self._parts
	local stageWidth = 800
	local parentObject = self._parent
	if parentObject:IsA("GuiObject") and parentObject.AbsoluteSize.X > 0 then
		stageWidth = parentObject.AbsoluteSize.X / math.max(0.1, SafeArea.scaleOf(parentObject))
	end
	-- Phones get a smaller plate: at full size it reached the middle of a landscape phone and sat on the
	-- crosshair, and its subtitle was cut off.
	local phone = parentObject:IsA("GuiObject") and SafeArea.classOf(parentObject) == "phone"
	local titlePx = if phone then 22 else AnnouncementBanner.TITLE_PX
	local subPx = if phone then 12 else AnnouncementBanner.SUB_PX
	parts.titleSize.MaxTextSize = titlePx
	parts.titleSize.MinTextSize = math.min(18, titlePx - 4)
	parts.subSize.MaxTextSize = subPx
	parts.subSize.MinTextSize = math.min(Tokens.typography.minimumBodySize, subPx - 2)
	local titleWidth = TextService:GetTextSize(payload.text, titlePx, Tokens.typography.display.font, Vector2.new(4096, 256)).X
	local hasSub = type(payload.sub) == "string" and payload.sub ~= ""
	local subWidth = if hasSub
		then TextService:GetTextSize(payload.sub :: string, subPx, Tokens.typography.body.font, Vector2.new(4096, 256)).X
		else 0
	local padX = if phone then Tokens.spacing.lg else Tokens.spacing.xl + Tokens.spacing.sm
	local minWidth = if phone then 200 else 280
	local width =
		math.clamp(math.max(titleWidth, subWidth) + padX * 2 + 8, minWidth, math.max(minWidth, stageWidth * (if phone then 0.7 else 0.86)))
	local titleTop = if phone then Tokens.spacing.xs + 3 else Tokens.spacing.sm + 5
	local titleHeight = titlePx + 6
	local height = titleTop
		+ titleHeight
		+ (if hasSub then subPx + 4 else 0)
		+ (if phone then Tokens.spacing.xs + 4 else Tokens.spacing.sm + 6)
	card.Size = UDim2.fromOffset(width, height)
	parts.title.Position = UDim2.new(0.5, 0, 0, titleTop)
	parts.title.Size = UDim2.new(1, -padX * 2, 0, titleHeight)
	parts.sub.Visible = hasSub
	parts.sub.Position = UDim2.new(0.5, 0, 0, titleTop + titleHeight)
	parts.sub.Size = UDim2.new(1, -padX * 2, 0, subPx + 4)
	return width, height
end

function AnnouncementBanner._present(self: AnnouncementBanner, payload: Payload, token: number)
	local card = self._card
	if not card then
		return
	end
	local parts = self._parts
	local motion = self._options.motion()
	local lowTier = self._options.tier ~= nil and self._options.tier() == "low"
	local tone = toneOf(payload.tone)
	parts.title.Text = payload.text
	parts.sub.Text = payload.sub or ""
	parts.titleGradient.Color = tone.title
	parts.rimGradient.Color = if payload.tone == "rainbow" then AnnouncementBanner.rainbow() else ColorSequence.new(tone.accent)
	parts.barGradient.Color = if payload.tone == "rainbow" then AnnouncementBanner.rainbow() else ColorSequence.new(tone.glow, tone.accent)
	parts.glow.BackgroundColor3 = tone.glow
	local _, height = self:_layout(payload)
	local top = if self._options.topPx then self._options.topPx() else 72
	local rest = UDim2.new(0.5, 0, 0, top)
	if self._options.onSpace then
		self._options.onSpace(height + Tokens.spacing.sm)
	end

	-- Entrance.
	card.Visible = true
	card.BackgroundTransparency = 0.04
	parts.face.BackgroundTransparency = 0
	parts.title.TextTransparency = 0
	parts.sub.TextTransparency = 0
	for _, stroke in ipairs({ parts.keyline, parts.rim, parts.titleStroke, parts.subStroke }) do
		stroke.Transparency = 0
	end
	self:_stopSpin()
	if motion.reducedMotion then
		card.Position = rest
		parts.scale.Scale = 1
		parts.glow.BackgroundTransparency = 0.78
	else
		card.Position = rest + UDim2.fromOffset(0, -16)
		parts.scale.Scale = 0.62
		TweenService:Create(card, TweenInfo.new(0.32, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Position = rest }):Play()
		local grow =
			TweenService:Create(parts.scale, TweenInfo.new(0.34, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1.06 })
		grow:Play()
		grow.Completed:Once(function()
			if self._token == token then
				TweenService:Create(parts.scale, TweenInfo.new(0.22, Enum.EasingStyle.Sine, Enum.EasingDirection.Out), { Scale = 1 }):Play()
			end
		end)
		parts.glow.BackgroundTransparency = 0.45
		TweenService
			:Create(parts.glow, TweenInfo.new(0.9, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { BackgroundTransparency = 0.8 })
			:Play()
		parts.sweepGradient.Offset = Vector2.new(-1, 0)
		TweenService:Create(
			parts.sweepGradient,
			TweenInfo.new(0.7, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, 0, false, 0.12),
			{ Offset = Vector2.new(1, 0) }
		):Play()
		if payload.tone == "rainbow" and not lowTier then
			-- The rainbow drifts along the rim and the bar while the plate shows.
			local started = os.clock()
			self._spin = RunService.RenderStepped:Connect(function()
				local t = os.clock() - started
				-- The rim's ramp turns; the bar's sways (an offset past either end would flood one colour).
				parts.rimGradient.Rotation = (t * 120) % 360
				parts.barGradient.Offset = Vector2.new(math.sin(t * 2.2) * 0.2, 0)
			end)
		end
	end
	if not (payload.tone == "rainbow" and self._spin) then
		parts.rimGradient.Rotation = 0
		parts.barGradient.Offset = Vector2.zero
	end
	self:_schedule(token)
end

-- (Re)starts the hold for the plate on screen.
function AnnouncementBanner._schedule(self: AnnouncementBanner, token: number)
	local this = self :: any
	this._holdToken = (this._holdToken or 0) + 1
	local holdToken = this._holdToken
	local hold = self._options.holdSeconds or AnnouncementBanner.HOLD_SECONDS
	task.delay(hold, function()
		if self._token == token and this._holdToken == holdToken then
			self:_dismiss(token)
		end
	end)
	-- With others waiting, the plate on screen gives way sooner.
	task.delay(AnnouncementBanner.QUEUED_HOLD_SECONDS, function()
		if self._token == token and this._holdToken == holdToken and #self._queue > 0 then
			this._holdToken += 1
			self:_dismiss(token)
		end
	end)
end

-- Same words again: a small pop and a fresh hold instead of a second plate.
function AnnouncementBanner._refresh(self: AnnouncementBanner)
	if self._options.headless or not self._card or not self._card.Visible then
		return
	end
	local motion = self._options.motion()
	if not motion.reducedMotion then
		self._parts.scale.Scale = 1.05
		TweenService:Create(self._parts.scale, TweenInfo.new(0.24, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
	end
	self:_schedule(self._token)
end

function AnnouncementBanner._dismiss(self: AnnouncementBanner, token: number)
	local card = self._card
	if not card or self._token ~= token then
		return
	end
	local parts = self._parts
	local motion = self._options.motion()
	local seconds = Motion.clampSeconds(0.24, motion)
	local fade = TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	TweenService:Create(parts.title, fade, { TextTransparency = 1 }):Play()
	TweenService:Create(parts.sub, fade, { TextTransparency = 1 }):Play()
	TweenService:Create(card, fade, { BackgroundTransparency = 1 }):Play()
	TweenService:Create(parts.face, fade, { BackgroundTransparency = 1 }):Play()
	for _, stroke in ipairs({ parts.keyline, parts.rim, parts.titleStroke, parts.subStroke }) do
		TweenService:Create(stroke, fade, { Transparency = 1 }):Play()
	end
	TweenService:Create(parts.glow, fade, { BackgroundTransparency = 1 }):Play()
	if not motion.reducedMotion then
		TweenService:Create(parts.scale, fade, { Scale = 0.86 }):Play()
	end
	task.delay(seconds + 0.02, function()
		if self._token ~= token then
			return
		end
		card.Visible = false
		self:_stopSpin()
		self._current = nil
		self:_next()
	end)
end

function AnnouncementBanner.destroy(self: AnnouncementBanner)
	self._token += 1
	table.clear(self._queue)
	self._current = nil
	self:_stopSpin()
	if self._card then
		self._card:Destroy()
		self._card = nil
	end
end

return AnnouncementBanner
