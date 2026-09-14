--!strict
-- Round HUD strip: timer chip, bag meter (art track + art fill that grows with the bag, squash on
-- award, a FULL - DEPOSIT state that pulses gently until the bag is emptied), and the cash chip
-- with an accelerating count-up and a floating "+$" delta. Hidden outside rounds.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local Motion = require(Shared.Design.Motion)
local EconomyMath = require(Shared.EconomyMath)
local FrameKit = require(script.Parent.Components.Frame)
local Icons = require(script.Parent.Components.Icons)
local Skin = require(script.Parent.Components.Skin)
local Tween = require(script.Parent.Components.Tween)

local RoundHud = {}
RoundHud.__index = RoundHud

export type RoundHud = typeof(setmetatable(
	{} :: {
		root: Frame,
		bagFill: GuiObject,
		bagText: TextLabel,
		cashText: TextLabel,
		timerText: TextLabel,
		_bagFrame: Frame,
		_bagScale: UIScale,
		_bagArt: boolean,
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

local TIMER_WIDTH = 132
local BAG_WIDTH = 196
local CASH_WIDTH = 136

local function chip(parent: Instance, name: string, order: number, width: number, art: string, icon: string?): (Frame, TextLabel)
	local frame, text, iconSlot = FrameKit.chip(parent, name, { width = width, art = art, zIndex = Tokens.zIndex.hud })
	frame.LayoutOrder = order
	text.Font = Tokens.typography.numeral.font
	text.TextSize = Tokens.typography.numeral.size - 1
	text.AutomaticSize = Enum.AutomaticSize.None
	text.Size = UDim2.new(1, -(Tokens.icon.md + Tokens.spacing.sm), 1, 0)
	text.TextXAlignment = Enum.TextXAlignment.Center
	if icon then
		iconSlot.Visible = true
		local built = Icons.build(icon, iconSlot, Tokens.icon.md, { zIndex = frame.ZIndex + 2 })
		built.Position = UDim2.fromScale(0, 0)
	else
		text.Size = UDim2.fromScale(1, 1)
	end
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

	local _timerFrame, timerText = chip(root, "Timer", 1, TIMER_WIDTH, "hud.timer", "clock")
	timerText.Text = "00:00.00"

	-- Bag: art track (or cream track) with an art fill that grows from the left.
	local bagFrame, bagText = chip(root, "Bag", 2, BAG_WIDTH, "hud.bag.track", nil)
	bagText.ZIndex = bagFrame.ZIndex + 3
	local bagFill: GuiObject
	local bagArt = Skin.has("hud.bag.fill.normal")
	if bagArt then
		local fill = Instance.new("ImageLabel")
		fill.Name = "Fill"
		fill.BackgroundTransparency = 1
		fill.AnchorPoint = Vector2.new(0, 0.5)
		fill.Position = UDim2.new(0, -Tokens.spacing.md, 0.5, 0)
		fill.Size = UDim2.fromScale(0, 1)
		fill.ZIndex = bagFrame.ZIndex + 2
		Skin.apply(fill, "hud.bag.fill.normal")
		fill.Parent = bagFrame
		bagFill = fill
	else
		local fill = Instance.new("Frame")
		fill.Name = "Fill"
		fill.AnchorPoint = Vector2.new(0, 0.5)
		fill.Position = UDim2.new(0, -Tokens.spacing.md, 0.5, 0)
		fill.Size = UDim2.new(0, 0, 1, -6)
		fill.BackgroundColor3 = Tokens.color.straw
		fill.BorderSizePixel = 0
		fill.ZIndex = bagFrame.ZIndex + 2
		local fillCorner = Instance.new("UICorner")
		fillCorner.CornerRadius = UDim.new(0, Tokens.radius.pill)
		fillCorner.Parent = fill
		fill.Parent = bagFrame
		bagFill = fill
	end
	bagText.Text = "Bag 0 / 25"
	local bagScale = bagFrame:FindFirstChildOfClass("UIScale") :: UIScale

	local _cashFrame, cashText = chip(root, "Cash", 3, CASH_WIDTH, "hud.cash", "coin")
	cashText.Text = "$0.00"
	cashText.TextColor3 = Tokens.color.leafDeep

	return setmetatable({
		root = root,
		bagFill = bagFill,
		bagText = bagText,
		cashText = cashText,
		timerText = timerText,
		_bagFrame = bagFrame,
		_bagScale = bagScale,
		_bagArt = bagArt,
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
		self.bagText.TextColor3 = Tokens.color.emberDeep
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
		self.bagText.TextColor3 = Tokens.color.inkStrong
		self.bagText.Text = self._lastBagText
	end
end

-- Bag meter with restrained squash; a stronger pulse when full.
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
	local width = self._bagFrame.AbsoluteSize.X / math.max(0.01, self._bagScale.Scale)
	local fillWidth = math.floor((BAG_WIDTH + Tokens.spacing.md * 2) * fraction)
	local _ = width
	local target = if self._bagArt then UDim2.new(0, fillWidth, 1, 0) else UDim2.new(0, fillWidth, 1, -6)
	if animate then
		TweenService:Create(self.bagFill, TweenInfo.new(Motion.duration("quick", self._motion()), Tokens.motion.easeOut), { Size = target })
			:Play()
	else
		self.bagFill.Size = target
	end
	if self._bagArt then
		Skin.apply(
			self.bagFill :: ImageLabel,
			if infinite then "hud.bag.fill.infinite" elseif full then "hud.bag.fill.full" else "hud.bag.fill.normal"
		)
	else
		(self.bagFill :: Frame).BackgroundColor3 = if full then Tokens.color.ember else Tokens.color.straw
	end
	if not self._full or not full then
		self.bagText.Text = self._lastBagText
	end
	self:_setFull(full)
	if animate then
		local amplitude = Motion.amplitude(if full then 0.12 else 0.05, self._motion())
		self._bagScale.Scale = 1 + amplitude
		TweenService:Create(
			self._bagScale,
			TweenInfo.new(Motion.duration(if full then "standard" else "quick", self._motion()), Tokens.motion.easeBack),
			{ Scale = 1 }
		):Play()
	end
end

-- Cash count-up with a short accelerating tick; `onTick` lets the caller play a capped tick sound.
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
			self.cashText.Parent :: GuiObject,
			"+" .. EconomyMath.formatCents(cents - previous),
			Tokens.color.leafDeep,
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
