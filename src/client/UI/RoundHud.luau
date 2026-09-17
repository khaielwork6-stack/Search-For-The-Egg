--!strict
-- Round HUD strip: timer pill, bag meter (a recessed dark track, a clipped fill that grows with the
-- bag and turns green when it is full, white stroked count, squash on award, FULL - DEPOSIT state
-- that pulses gently until the bag is emptied), and the cash pill with a gold coin, an accelerating
-- count-up and a floating "+$" delta. Hidden outside rounds. All vector, dark slate pills with white
-- stroked lettering like the rest of the HUD.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local Motion = require(Shared.Design.Motion)
local EconomyMath = require(Shared.EconomyMath)
local FrameKit = require(script.Parent.Components.Frame)
local Depth = require(script.Parent.Components.Depth)
local Icons = require(script.Parent.Components.Icons)
local Skin = require(script.Parent.Components.Skin)
local Tween = require(script.Parent.Components.Tween)
local AnnouncementBanner = require(script.Parent.AnnouncementBanner)

local RoundHud = {}
RoundHud.__index = RoundHud

export type RoundHud = typeof(setmetatable(
	{} :: {
		root: Frame,
		bagFill: Frame,
		bagText: TextLabel,
		cashText: TextLabel,
		timerText: TextLabel,
		_bagFrame: Frame,
		_bagScale: UIScale,
		_motion: () -> Motion.MotionSettings,
		_displayedCents: number,
		_targetCents: number,
		_countThread: thread?,
		_stopPulse: (() -> ())?,
		_full: boolean,
		_fullThread: thread?,
		_lastBagText: string,
		_plume: { [string]: any },
		_rainbowTag: TextLabel?,
		_rainbowToken: number,
	},
	RoundHud
))

local TIMER_WIDTH = 138
local BAG_WIDTH = 210
local CASH_WIDTH = 142
local PLUME_WIDTH = 172

local function chip(
	parent: Instance,
	name: string,
	order: number,
	width: number,
	iconRole: string?,
	iconFallback: string?
): (Frame, TextLabel)
	local frame, text, iconSlot = FrameKit.chip(parent, name, { width = width, zIndex = Tokens.zIndex.hud })
	frame.LayoutOrder = order
	text.Font = Tokens.typography.label.font
	text.TextSize = Tokens.typography.label.size + 1
	text.TextXAlignment = Enum.TextXAlignment.Center
	text.TextColor3 = Tokens.color.featherWhite
	local outline = text:FindFirstChild("TextOutline") :: UIStroke?
	if outline then
		outline.Thickness = 2.4
	end
	if iconRole or iconFallback then
		iconSlot.Visible = true
		local art = if iconRole then Skin.icon(iconSlot, iconRole, Tokens.icon.md + 2, iconSlot.ZIndex + 1) else nil
		if not art and iconFallback then
			Icons.build(iconFallback, iconSlot, Tokens.icon.md + 2, { zIndex = iconSlot.ZIndex + 1 })
		end
	end
	text.Size = UDim2.fromOffset(
		width - Tokens.spacing.md - Tokens.spacing.lg - (if iconRole or iconFallback then Tokens.icon.md + 2 + Tokens.spacing.sm else 0),
		Tokens.layout.minimumTapTargetPx - 4
	)
	return frame, text
end

function RoundHud.new(gui: Instance, motion: () -> Motion.MotionSettings): RoundHud
	local root = Instance.new("Frame")
	root.Name = "RoundHud"
	root.AnchorPoint = Vector2.new(0.5, 1)
	root.Position = UDim2.new(0.5, 0, 1, -Tokens.layout.safeAreaPaddingPx)
	root.Size = UDim2.fromOffset(0, Tokens.layout.minimumTapTargetPx)
	root.AutomaticSize = Enum.AutomaticSize.X
	root.BackgroundTransparency = 1
	root.Visible = false
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.Padding = UDim.new(0, Tokens.spacing.sm)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Parent = root
	root.Parent = gui

	local _timerFrame, timerText = chip(root, "Timer", 1, TIMER_WIDTH, nil, "clock")
	timerText.Text = "00:00.00"

	-- Bag: the chip face is the recessed track; the fill grows inside it, under the count.
	local bagFrame, bagText = chip(root, "Bag", 2, BAG_WIDTH, nil, nil)
	local face = bagFrame:FindFirstChild("Face") :: Frame
	face.BackgroundColor3 = Tokens.color.panelDeep
	local faceGradient = face:FindFirstChildOfClass("UIGradient")
	if faceGradient then
		faceGradient.Enabled = false
	end
	face.ClipsDescendants = true
	local bagFill = Instance.new("Frame")
	bagFill.Name = "Fill"
	bagFill.Size = UDim2.fromScale(0, 1)
	bagFill.BackgroundColor3 = Tokens.color.leafDeep
	bagFill.BorderSizePixel = 0
	bagFill.ZIndex = face.ZIndex + 1
	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0, Tokens.radius.pill)
	fillCorner.Parent = bagFill
	Depth.applySheen(bagFill, Tokens.color.leafDeep)
	bagFill.Parent = face
	bagText.Text = "Bag 0 / 25"
	bagText.TextColor3 = Tokens.color.featherWhite
	local bagScale = bagFrame:FindFirstChildOfClass("UIScale") :: UIScale

	-- Plume progress: "7/10 FOR PLUME" over a rainbow fill, READY FOR PLUME (gold, breathing) at the
	-- cost, PLUME USED once this round's clue is spent. Hidden until a round projection says Plume is
	-- there to visit (RainbowFeatherController drives it).
	local plumeFrame, plumeText = chip(root, "Plume", 3, PLUME_WIDTH, nil, nil)
	plumeFrame.Visible = false
	local plumeFace = plumeFrame:FindFirstChild("Face") :: Frame
	plumeFace.BackgroundColor3 = Tokens.color.panelDeep
	local plumeFaceGradient = plumeFace:FindFirstChildOfClass("UIGradient")
	if plumeFaceGradient then
		plumeFaceGradient.Enabled = false
	end
	plumeFace.ClipsDescendants = true
	local plumeFill = Instance.new("Frame")
	plumeFill.Name = "Fill"
	plumeFill.Size = UDim2.fromScale(0, 1)
	plumeFill.BackgroundColor3 = Color3.new(1, 1, 1)
	plumeFill.BackgroundTransparency = 0.12
	plumeFill.BorderSizePixel = 0
	plumeFill.ZIndex = plumeFace.ZIndex + 1
	local plumeFillCorner = Instance.new("UICorner")
	plumeFillCorner.CornerRadius = UDim.new(0, Tokens.radius.pill)
	plumeFillCorner.Parent = plumeFill
	local plumeGradient = Instance.new("UIGradient")
	plumeGradient.Name = "Rainbow"
	plumeGradient.Color = AnnouncementBanner.rainbow()
	plumeGradient.Parent = plumeFill
	plumeFill.Parent = plumeFace
	-- A dark wash over the fill so the white lettering keeps its contrast on the yellow band.
	local plumeShade = Instance.new("Frame")
	plumeShade.Name = "Shade"
	plumeShade.Size = UDim2.fromScale(1, 1)
	plumeShade.BackgroundColor3 = Tokens.color.outline
	plumeShade.BackgroundTransparency = 0.72
	plumeShade.BorderSizePixel = 0
	plumeShade.ZIndex = plumeFace.ZIndex + 2
	plumeShade.Parent = plumeFace
	plumeText.TextScaled = true
	local plumeTextSize = Instance.new("UITextSizeConstraint")
	plumeTextSize.MaxTextSize = Tokens.typography.label.size - 2
	plumeTextSize.MinTextSize = Tokens.typography.minimumBodySize
	plumeTextSize.Parent = plumeText
	plumeText.Text = "0/10 FOR PLUME"
	local plumeOutline = plumeFrame:FindFirstChildOfClass("UIStroke")

	local cashFrame, cashText = chip(root, "Cash", 4, CASH_WIDTH, "hud.token", "coin")
	cashText.Text = "$0.00"
	cashText.TextColor3 = Tokens.color.featherWhite
	local cashArt = cashFrame:FindFirstChild("IconSlot", true)
	local cashIcon = cashArt and cashArt:FindFirstChildWhichIsA("ImageLabel")
	if cashIcon then
		cashIcon.ImageColor3 = Tokens.color.gold
	end

	return setmetatable({
		root = root,
		bagFill = bagFill,
		bagText = bagText,
		cashText = cashText,
		timerText = timerText,
		_bagFrame = bagFrame,
		_bagScale = bagScale,
		_motion = motion,
		_displayedCents = 0,
		_targetCents = 0,
		_countThread = nil,
		_stopPulse = nil,
		_full = false,
		_fullThread = nil,
		_lastBagText = "",
		_plume = {
			frame = plumeFrame,
			fill = plumeFill,
			gradient = plumeGradient,
			text = plumeText,
			outline = plumeOutline,
			scale = plumeFrame:FindFirstChildOfClass("UIScale"),
			state = "",
			stopPulse = nil,
		},
		_rainbowTag = nil,
		_rainbowToken = 0,
	}, RoundHud)
end

function RoundHud.setVisible(self: RoundHud, visible: boolean)
	self.root.Visible = visible
end

function RoundHud.setTimer(self: RoundHud, ms: number)
	local totalSeconds = math.floor(ms / 1000)
	self.timerText.Text = string.format("%02d:%02d.%02d", math.floor(totalSeconds / 60), totalSeconds % 60, math.floor((ms % 1000) / 10))
end

-- FULL - DEPOSIT: the bag chip alternates its count with the deposit prompt and breathes gently;
-- the pulse stops the moment the bag has room again (attention only while it is useful).
function RoundHud._setFull(self: RoundHud, full: boolean)
	if full == self._full then
		return
	end
	self._full = full
	if full then
		self._stopPulse = Tween.pulseLoop(self._bagScale, self._motion(), 0.04)
		self.bagText.TextColor3 = Tokens.color.featherWhite
		local outline = self.bagText:FindFirstChild("TextOutline") :: UIStroke?
		if outline then
			outline.Thickness = 3
		end
		-- The bag pill goes green when it is full: the one time the meter is the whole message.
		self.bagFill.BackgroundColor3 = Tokens.color.success
		Depth.applySheen(self.bagFill, Tokens.color.success)
		self._fullThread = task.spawn(function()
			local showPrompt = true
			while self._full do
				self.bagText.Text = if showPrompt then "FULL - DEPOSIT" else self._lastBagText
				showPrompt = not showPrompt
				task.wait(1.1)
			end
		end)
	else
		if self._stopPulse then
			self._stopPulse()
			self._stopPulse = nil
		end
		if self._fullThread then
			task.cancel(self._fullThread)
			self._fullThread = nil
		end
		self.bagText.TextColor3 = Tokens.color.featherWhite
		local outline = self.bagText:FindFirstChild("TextOutline") :: UIStroke?
		if outline then
			outline.Thickness = 2.4
		end
		self.bagFill.BackgroundColor3 = Tokens.color.leafDeep
		Depth.applySheen(self.bagFill, Tokens.color.leafDeep)
		self.bagText.Text = self._lastBagText
	end
end

function RoundHud.setBag(self: RoundHud, carried: number, capacity: number, infinite: boolean, animate: boolean?)
	local fraction: number
	if infinite then
		self._lastBagText = string.format("Bag %d / Infinite", carried)
		fraction = 1
	else
		self._lastBagText = string.format("Bag %d / %d", carried, capacity)
		fraction = if capacity > 0 then math.clamp(carried / capacity, 0, 1) else 0
	end
	local full = not infinite and carried >= capacity and capacity > 0
	local target = UDim2.fromScale(fraction, 1)
	if animate then
		TweenService:Create(self.bagFill, TweenInfo.new(Motion.duration("quick", self._motion()), Tokens.motion.easeOut), { Size = target })
			:Play()
	else
		self.bagFill.Size = target
	end
	if infinite then
		self.bagFill.BackgroundColor3 = Tokens.color.sky
		Depth.applySheen(self.bagFill, Tokens.color.sky)
	elseif not full then
		self.bagFill.BackgroundColor3 = Tokens.color.leafDeep
		Depth.applySheen(self.bagFill, Tokens.color.leafDeep)
	end
	if not self._full or not full then
		self.bagText.Text = self._lastBagText
	end
	self:_setFull(full)
	if animate then
		local amplitude = Motion.amplitude(if full then 0.14 else 0.12, self._motion())
		self._bagScale.Scale = 1 + amplitude
		TweenService:Create(
			self._bagScale,
			TweenInfo.new(Motion.duration(if full then "standard" else "quick", self._motion()), Tokens.motion.easeBack),
			{ Scale = 1 }
		):Play()
	end
end

-- The Plume pill. `state` = { visible, carried, cost, used }.
function RoundHud.setPlume(self: RoundHud, state: { visible: boolean, carried: number, cost: number, used: boolean })
	local plume = self._plume
	local frame = plume.frame :: Frame
	frame.Visible = state.visible
	local cost = math.max(1, state.cost)
	local ready = not state.used and state.carried >= cost
	local mode = if not state.visible then "hidden" elseif state.used then "used" elseif ready then "ready" else "progress"
	local text = if state.used
		then "PLUME USED"
		elseif ready then "READY FOR PLUME"
		else string.format("%d/%d FOR PLUME", math.max(0, state.carried), cost)
	plume.text.Text = text
	local fraction = if state.used then 0 else math.clamp(state.carried / cost, 0, 1)
	local motion = self._motion()
	TweenService:Create(plume.fill, TweenInfo.new(Motion.duration("quick", motion), Tokens.motion.easeOut), {
		Size = UDim2.fromScale(fraction, 1),
	}):Play()
	plume.text.TextColor3 = if state.used then Tokens.color.inkMuted else Tokens.color.featherWhite
	if mode == plume.state then
		return
	end
	local previous = plume.state
	plume.state = mode
	if plume.stopPulse then
		plume.stopPulse()
		plume.stopPulse = nil
	end
	if plume.outline then
		plume.outline.Color = if mode == "ready" then Tokens.color.gold else Tokens.color.outline
	end
	if mode == "ready" then
		-- Attention only while it is useful: breathe gold until the clue is bought or the bag is sold.
		plume.stopPulse = Tween.pulseLoop(plume.scale, motion, 0.05)
		if previous == "progress" and plume.scale then
			plume.scale.Scale = 1 + Motion.amplitude(0.16, motion)
			TweenService:Create(plume.scale, TweenInfo.new(Motion.duration("standard", motion), Tokens.motion.easeBack), { Scale = 1 })
				:Play()
		end
	end
end

function RoundHud.plumeState(self: RoundHud): string
	return self._plume.state
end

-- A Rainbow Feather reached the bag: the count flashes through the rainbow, the chip pops, and a
-- "+N RAINBOW" tag rises off it. One pooled tag; a second flash restarts it.
function RoundHud.flashRainbow(self: RoundHud, count: number?)
	local motion = self._motion()
	self._rainbowToken += 1
	local token = self._rainbowToken
	local gradient = self.bagText:FindFirstChild("RainbowFlash") :: UIGradient?
	if not gradient then
		local made = Instance.new("UIGradient")
		made.Name = "RainbowFlash"
		made.Color = AnnouncementBanner.rainbow()
		made.Parent = self.bagText
		gradient = made
	end
	local flash = gradient :: UIGradient
	flash.Enabled = true
	flash.Offset = Vector2.new(-0.6, 0)
	-- Deliberately longer than the UI tween cap: this is a moment, not a control responding.
	local flashSeconds = if motion.reducedMotion then 0.5 else 0.9
	TweenService:Create(flash, TweenInfo.new(flashSeconds, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {
		Offset = Vector2.new(0.6, 0),
	}):Play()
	local fill = self.bagFill
	local fillColor = fill.BackgroundColor3
	fill.BackgroundColor3 = Color3.fromRGB(226, 150, 255)
	TweenService:Create(fill, TweenInfo.new(flashSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		BackgroundColor3 = fillColor,
	}):Play()
	self._bagScale.Scale = 1 + Motion.amplitude(0.2, motion)
	TweenService:Create(self._bagScale, TweenInfo.new(Motion.duration("standard", motion), Tokens.motion.easeBack), { Scale = 1 }):Play()
	task.delay(flashSeconds + 0.05, function()
		if self._rainbowToken == token then
			flash.Enabled = false
		end
	end)

	local tag = self._rainbowTag
	if not tag then
		local made = Instance.new("TextLabel")
		made.Name = "RainbowTag"
		made.AnchorPoint = Vector2.new(0.5, 1)
		made.BackgroundTransparency = 1
		made.Size = UDim2.fromOffset(BAG_WIDTH, Tokens.typography.numeral.size + Tokens.spacing.xs)
		made.Font = Tokens.typography.display.font
		made.TextSize = Tokens.typography.numeral.size
		made.TextColor3 = Color3.new(1, 1, 1)
		made.ZIndex = Tokens.zIndex.hud + 6
		local tagGradient = Instance.new("UIGradient")
		tagGradient.Color = AnnouncementBanner.rainbow()
		tagGradient.Parent = made
		FrameKit.outline(made, 2.6)
		made.Parent = self._bagFrame
		self._rainbowTag = made
		tag = made
	end
	local label = tag :: TextLabel
	local stroke = label:FindFirstChild("TextOutline") :: UIStroke?
	label.Text = string.format("+%d RAINBOW", math.max(1, count or 1))
	label.Visible = true
	label.TextTransparency = 0
	if stroke then
		stroke.Transparency = 0
	end
	local seconds = if motion.reducedMotion then 0.8 else 1.1
	local rise = Motion.amplitude(34, motion)
	label.Position = UDim2.new(0.5, 0, 0, -2)
	TweenService:Create(label, TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Position = UDim2.new(0.5, 0, 0, -2 - rise),
	}):Play()
	task.delay(seconds * 0.55, function()
		if self._rainbowToken ~= token then
			return
		end
		local fade = TweenInfo.new(seconds * 0.45)
		TweenService:Create(label, fade, { TextTransparency = 1 }):Play()
		if stroke then
			TweenService:Create(stroke, fade, { Transparency = 1 }):Play()
		end
	end)
end

function RoundHud.setCash(self: RoundHud, cents: number, animate: boolean?, onTick: (() -> ())?)
	local previous = self._targetCents
	self._targetCents = cents
	if not animate then
		self._displayedCents = cents
		self.cashText.Text = EconomyMath.formatCents(cents)
		return
	end
	if cents > previous then
		Tween.floatText(
			self.cashText.Parent.Parent :: GuiObject,
			"+" .. EconomyMath.formatCents(cents - previous),
			Tokens.color.featherWhite,
			self._motion()
		)
	end
	if self._countThread then
		task.cancel(self._countThread)
	end
	local duration = Motion.duration("slow", self._motion()) * 2
	local startCents = self._displayedCents
	local started = os.clock()
	self._countThread = task.spawn(function()
		local ticks = 0
		while true do
			local t = math.clamp((os.clock() - started) / duration, 0, 1)
			local eased = 1 - (1 - t) * (1 - t) * (1 - t)
			local value = math.floor(startCents + (cents - startCents) * eased + 0.5)
			self._displayedCents = value
			self.cashText.Text = EconomyMath.formatCents(value)
			if onTick and ticks % 3 == 0 and ticks < 18 then
				onTick()
			end
			ticks += 1
			if t >= 1 then
				break
			end
			task.wait()
		end
		self._countThread = nil
	end)
end

function RoundHud.destroy(self: RoundHud)
	if self._countThread then
		task.cancel(self._countThread)
	end
	self:_setFull(false)
	if self._plume.stopPulse then
		self._plume.stopPulse()
	end
	self.root:Destroy()
end

return RoundHud
