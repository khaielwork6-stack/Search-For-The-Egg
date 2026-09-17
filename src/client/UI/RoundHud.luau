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
	},
	RoundHud
))

local TIMER_WIDTH = 138
local BAG_WIDTH = 210
local CASH_WIDTH = 142

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

	local cashFrame, cashText = chip(root, "Cash", 3, CASH_WIDTH, "hud.token", "coin")
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
	self.root:Destroy()
end

return RoundHud
