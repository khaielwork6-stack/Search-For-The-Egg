--!strict
-- Round HUD strip: bag meter (fill bar + count with squash on award and a stronger full pulse),
-- cash chip with accelerating count-up, and the count-up timer. Hidden outside rounds.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local Motion = require(Shared.Design.Motion)
local EconomyMath = require(Shared.EconomyMath)

local RoundHud = {}
RoundHud.__index = RoundHud

export type RoundHud = typeof(setmetatable(
	{} :: {
		root: Frame,
		bagFill: Frame,
		bagText: TextLabel,
		cashText: TextLabel,
		timerText: TextLabel,
		_bagScale: UIScale,
		_motion: () -> Motion.MotionSettings,
		_displayedCents: number,
		_targetCents: number,
		_countThread: thread?,
	},
	RoundHud
))

local function chip(parent: Instance, name: string, order: number, width: number): (Frame, TextLabel)
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.LayoutOrder = order
	frame.Size = UDim2.fromOffset(width, Tokens.layout.minimumTapTargetPx)
	frame.BackgroundColor3 = Tokens.color.surface
	frame.ZIndex = Tokens.zIndex.hud
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, Tokens.radius.pill)
	corner.Parent = frame
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = Tokens.stroke.standard
	stroke.Color = Tokens.color.creamDeep
	stroke.Parent = frame
	local text = Instance.new("TextLabel")
	text.Name = "Text"
	text.Size = UDim2.fromScale(1, 1)
	text.BackgroundTransparency = 1
	text.Font = Tokens.typography.numeral.font
	text.TextSize = Tokens.typography.numeral.size
	text.TextColor3 = Tokens.color.inkStrong
	text.ZIndex = Tokens.zIndex.hud + 2
	text.Parent = frame
	frame.Parent = parent
	return frame, text
end

function RoundHud.new(gui: ScreenGui, motion: () -> Motion.MotionSettings): RoundHud
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

	local timerFrame, timerText = chip(root, "Timer", 1, 130)
	timerText.Text = "00:00.00"
	local _ = timerFrame

	local bagFrame, bagText = chip(root, "Bag", 2, 190)
	local bagFill = Instance.new("Frame")
	bagFill.Name = "Fill"
	bagFill.Size = UDim2.fromScale(0, 1)
	bagFill.BackgroundColor3 = Tokens.color.straw
	bagFill.BorderSizePixel = 0
	bagFill.ZIndex = Tokens.zIndex.hud + 1
	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0, Tokens.radius.pill)
	fillCorner.Parent = bagFill
	bagFill.Parent = bagFrame
	bagText.Text = "Bag 0 / 25"
	local bagScale = Instance.new("UIScale")
	bagScale.Parent = bagFrame

	local _cashFrame, cashText = chip(root, "Cash", 3, 130)
	cashText.Text = "$0.00"
	cashText.TextColor3 = Tokens.color.leafDeep

	return setmetatable({
		root = root,
		bagFill = bagFill,
		bagText = bagText,
		cashText = cashText,
		timerText = timerText,
		_bagScale = bagScale,
		_motion = motion,
		_displayedCents = 0,
		_targetCents = 0,
		_countThread = nil,
	}, RoundHud)
end

function RoundHud.setVisible(self: RoundHud, visible: boolean)
	self.root.Visible = visible
end

function RoundHud.setTimer(self: RoundHud, ms: number)
	local totalSeconds = math.floor(ms / 1000)
	self.timerText.Text = string.format("%02d:%02d.%02d", math.floor(totalSeconds / 60), totalSeconds % 60, math.floor((ms % 1000) / 10))
end

-- Bag meter with restrained squash; a stronger pulse when full.
function RoundHud.setBag(self: RoundHud, carried: number, capacity: number, infinite: boolean, animate: boolean?)
	if infinite then
		self.bagText.Text = string.format("Bag %d / Infinite", carried)
		self.bagFill.Size = UDim2.fromScale(1, 1)
	else
		self.bagText.Text = string.format("Bag %d / %d", carried, capacity)
		local fraction = if capacity > 0 then math.clamp(carried / capacity, 0, 1) else 0
		TweenService:Create(
			self.bagFill,
			TweenInfo.new(Motion.duration("quick", self._motion()), Tokens.motion.easeOut),
			{ Size = UDim2.fromScale(fraction, 1) }
		):Play()
		self.bagFill.BackgroundColor3 = if fraction >= 1 then Tokens.color.ember else Tokens.color.straw
	end
	if animate then
		local full = not infinite and carried >= capacity
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
	self._targetCents = cents
	if not animate then
		self._displayedCents = cents
		self.cashText.Text = EconomyMath.formatCents(cents)
		return
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
	self.root:Destroy()
end

return RoundHud
