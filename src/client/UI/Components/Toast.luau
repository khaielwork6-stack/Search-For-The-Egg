--!strict
-- Toast queue: at most three visible, each auto-dismissing, using the notification recipes (grow
-- Back-out, pop Elastic, shrink Quad-in). Non-blocking, inside the safe area at the top-center.
-- Reward toasts carry an amount that counts up only after the server acknowledged the grant.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local Motion = require(Shared.Design.Motion)
local Tween = require(script.Parent.Tween)
local FrameKit = require(script.Parent.Frame)

local Toast = {}
Toast.__index = Toast

export type Toast = typeof(setmetatable(
	{} :: {
		_container: Frame,
		_motion: () -> Motion.MotionSettings,
		_queue: { { text: string, tone: string, amount: number?, seconds: number? } },
		_visible: number,
		_max: number,
		shown: number,
	},
	Toast
))

local TONES = {
	info = Tokens.color.sky,
	success = Tokens.color.leafBright,
	warning = Tokens.color.warning,
	danger = Tokens.color.danger,
	reward = Tokens.color.gold,
}

local HOLD_SECONDS = 2.8

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
	sizeConstraint.MaxSize = Vector2.new(440, 400)
	sizeConstraint.Parent = container
	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, Tokens.spacing.sm)
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.Parent = container
	container.Parent = gui
	return setmetatable({ _container = container, _motion = motion, _queue = {}, _visible = 0, _max = 3, shown = 0 }, Toast)
end

function Toast.push(self: Toast, text: string, tone: string?, seconds: number?)
	table.insert(self._queue, { text = text, tone = tone or "info", seconds = seconds })
	self:_drain()
end

-- Reward toast: the amount counts up from 0 (call only after the server acknowledged the grant).
function Toast.reward(self: Toast, text: string, amount: number)
	table.insert(self._queue, { text = text, tone = "reward", amount = amount, seconds = HOLD_SECONDS + 0.8 })
	self:_drain()
end

function Toast._drain(self: Toast)
	while self._visible < self._max and #self._queue > 0 do
		local item = table.remove(self._queue, 1) :: { text: string, tone: string, amount: number?, seconds: number? }
		self._visible += 1
		self.shown += 1
		local card = Instance.new("Frame")
		card.Name = "Toast"
		card.Size = UDim2.new(1, 0, 0, Tokens.layout.minimumTapTargetPx + Tokens.spacing.xs)
		card.AutomaticSize = Enum.AutomaticSize.Y
		card.BackgroundColor3 = Tokens.color.tealPanel
		card.ZIndex = Tokens.zIndex.toast
		card.Visible = false
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, Tokens.radius.lg)
		corner.Parent = card
		local stroke = Instance.new("UIStroke")
		stroke.Thickness = Tokens.stroke.bold
		stroke.Color = TONES[item.tone] or TONES.info
		stroke.Parent = card
		local padding = Instance.new("UIPadding")
		padding.PaddingLeft = UDim.new(0, Tokens.spacing.md)
		padding.PaddingRight = UDim.new(0, Tokens.spacing.md)
		padding.PaddingTop = UDim.new(0, Tokens.spacing.sm)
		padding.PaddingBottom = UDim.new(0, Tokens.spacing.sm)
		padding.Parent = card
		local scale = Instance.new("UIScale")
		scale.Parent = card
		local label = FrameKit.text(card, "Text", item.text, "body", { align = Enum.TextXAlignment.Center, zIndex = card.ZIndex + 1 })
		label.Size = UDim2.new(1, 0, 0, Tokens.typography.body.size + Tokens.spacing.xs)
		label.AutomaticSize = Enum.AutomaticSize.Y
		if item.amount then
			local amountLabel = FrameKit.text(
				card,
				"Amount",
				"+0",
				"numeral",
				{ align = Enum.TextXAlignment.Center, color = Tokens.color.goldLight, zIndex = card.ZIndex + 1 }
			)
			amountLabel.Position = UDim2.fromOffset(0, Tokens.typography.body.size + Tokens.spacing.sm)
			amountLabel.Size = UDim2.new(1, 0, 0, Tokens.typography.numeral.size + Tokens.spacing.xs)
			label.Size = UDim2.new(1, 0, 0, Tokens.typography.body.size + Tokens.typography.numeral.size + Tokens.spacing.md)
			label.AutomaticSize = Enum.AutomaticSize.None
			label.TextYAlignment = Enum.TextYAlignment.Top
			Tween.countUp(0, item.amount :: number, self._motion(), function(value)
				amountLabel.Text = string.format("+%d", value)
			end)
		end
		card.Parent = self._container
		local shrink = Tween.notify(card, scale, self._motion())
		task.delay(item.seconds or HOLD_SECONDS, function()
			shrink()
			task.delay(Motion.recipe("notifyShrink", self._motion()).duration + 0.05, function()
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
