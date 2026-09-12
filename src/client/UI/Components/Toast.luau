--!strict
-- Toast queue: at most three visible, each auto-dismissing, with token motion. Non-blocking and
-- placed inside the safe area at the top-center.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local Motion = require(Shared.Design.Motion)

local Toast = {}
Toast.__index = Toast

export type Toast = typeof(setmetatable(
	{} :: {
		_container: Frame,
		_motion: () -> Motion.MotionSettings,
		_queue: { { text: string, tone: string } },
		_visible: number,
		_max: number,
	},
	Toast
))

local TONES = { info = Tokens.color.sky, success = Tokens.color.success, warning = Tokens.color.warning }

function Toast.new(gui: ScreenGui, motion: () -> Motion.MotionSettings): Toast
	local container = Instance.new("Frame")
	container.Name = "Toasts"
	container.AnchorPoint = Vector2.new(0.5, 0)
	-- Sits below the objective banner (safe padding + banner height + caption line + spacing).
	container.Position = UDim2.new(
		0.5,
		0,
		0,
		Tokens.layout.safeAreaPaddingPx + Tokens.layout.minimumTapTargetPx + Tokens.typography.caption.size + Tokens.spacing.xl
	)
	container.Size = UDim2.fromScale(0.6, 0)
	container.AutomaticSize = Enum.AutomaticSize.Y
	container.BackgroundTransparency = 1
	container.ZIndex = Tokens.zIndex.toast
	local sizeConstraint = Instance.new("UISizeConstraint")
	sizeConstraint.MaxSize = Vector2.new(420, 400)
	sizeConstraint.Parent = container
	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, Tokens.spacing.sm)
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.Parent = container
	container.Parent = gui
	return setmetatable({ _container = container, _motion = motion, _queue = {}, _visible = 0, _max = 3 }, Toast)
end

function Toast.push(self: Toast, text: string, tone: string?)
	table.insert(self._queue, { text = text, tone = tone or "info" })
	self:_drain()
end

function Toast._drain(self: Toast)
	while self._visible < self._max and #self._queue > 0 do
		local item = table.remove(self._queue, 1) :: { text: string, tone: string }
		self._visible += 1
		local label = Instance.new("TextLabel")
		label.Name = "Toast"
		label.Size = UDim2.new(1, 0, 0, Tokens.layout.minimumTapTargetPx)
		label.BackgroundColor3 = Tokens.color.surface
		label.TextColor3 = Tokens.color.inkStrong
		label.Font = Tokens.typography.body.font
		label.TextSize = Tokens.typography.body.size
		label.Text = item.text
		label.TextWrapped = true
		label.ZIndex = Tokens.zIndex.toast
		label.BackgroundTransparency = 1
		label.TextTransparency = 1
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, Tokens.radius.md)
		corner.Parent = label
		local stroke = Instance.new("UIStroke")
		stroke.Thickness = Tokens.stroke.bold
		stroke.Color = TONES[item.tone] or TONES.info
		stroke.Parent = label
		label.Parent = self._container
		local motion = self._motion()
		local inInfo = TweenInfo.new(Motion.duration("standard", motion), Tokens.motion.easeOut)
		TweenService:Create(label, inInfo, { BackgroundTransparency = 0, TextTransparency = 0 }):Play()
		task.delay(2.8, function()
			local outInfo = TweenInfo.new(Motion.duration("quick", self._motion()), Tokens.motion.easeInOut)
			local out = TweenService:Create(label, outInfo, { BackgroundTransparency = 1, TextTransparency = 1 })
			out:Play()
			out.Completed:Once(function()
				label:Destroy()
				self._visible -= 1
				self:_drain()
			end)
		end)
	end
end

function Toast.visibleCount(self: Toast): number
	return self._visible
end

function Toast.destroy(self: Toast)
	self._container:Destroy()
	table.clear(self._queue)
end

return Toast
