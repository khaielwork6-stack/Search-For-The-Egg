--!strict
-- Toast queue: at most three visible, each auto-dismissing. Cream cards with a tone strip and a
-- vector glyph slide in from above (Back-out), pop, and shrink away. Non-blocking, inside the safe
-- area at the top-center. Reward toasts count their amount up only after the server acknowledged
-- the grant, with a coin icon.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local Motion = require(Shared.Design.Motion)
local Tween = require(script.Parent.Tween)
local FrameKit = require(script.Parent.Frame)
local Icons = require(script.Parent.Icons)
local Skin = require(script.Parent.Skin)

local Toast = {}
Toast.__index = Toast

export type Toast = typeof(setmetatable(
	{} :: {
		_container: Frame,
		_motion: () -> Motion.MotionSettings,
		_queue: { { text: string, tone: string, amount: number?, seconds: number? } },
		_visible: number,
		_max: number,
		_onShow: ((tone: string) -> ())?,
		shown: number,
	},
	Toast
))

local TONES: { [string]: { color: Color3, icon: string } } = {
	info = { color = Tokens.color.tealAccent, icon = "feather" },
	success = { color = Tokens.color.success, icon = "check" },
	warning = { color = Tokens.color.warning, icon = "star" },
	danger = { color = Tokens.color.danger, icon = "close" },
	reward = { color = Tokens.color.gold, icon = "coin" },
}

local HOLD_SECONDS = 2.8

function Toast.new(gui: Instance, motion: () -> Motion.MotionSettings, onShow: ((tone: string) -> ())?): Toast
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
	return setmetatable(
		{ _container = container, _motion = motion, _queue = {}, _visible = 0, _max = 3, _onShow = onShow, shown = 0 },
		Toast
	)
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
		local tone = TONES[item.tone] or TONES.info
		local card = Instance.new("Frame")
		card.Name = "Toast"
		card.Size = UDim2.new(1, 0, 0, Tokens.layout.minimumTapTargetPx + Tokens.spacing.xs)
		card.BackgroundColor3 = Tokens.color.goldDeep
		card.ZIndex = Tokens.zIndex.toast
		card.Visible = false
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, Tokens.radius.pill)
		corner.Parent = card
		local stroke = Instance.new("UIStroke")
		stroke.Thickness = Tokens.stroke.bold
		stroke.Color = Tokens.color.outline
		stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		stroke.Parent = card
		local scale = Instance.new("UIScale")
		scale.Parent = card
		local face = Instance.new("Frame")
		face.Name = "Face"
		face.Size = UDim2.new(1, 0, 1, -4)
		face.BackgroundColor3 = Tokens.color.featherWhite
		face.BorderSizePixel = 0
		face.ZIndex = card.ZIndex + 1
		local faceCorner = Instance.new("UICorner")
		faceCorner.CornerRadius = UDim.new(0, Tokens.radius.pill)
		faceCorner.Parent = face
		local gradient = Instance.new("UIGradient")
		gradient.Rotation = 90
		gradient.Color =
			ColorSequence.new({ ColorSequenceKeypoint.new(0, Tokens.color.featherWhite), ColorSequenceKeypoint.new(1, Tokens.color.cream) })
		gradient.Parent = face
		face.Parent = card
		-- Tone glyph in a coloured disc on the left.
		local glyphBadge = Instance.new("Frame")
		glyphBadge.Name = "Glyph"
		glyphBadge.AnchorPoint = Vector2.new(0, 0.5)
		glyphBadge.Position = UDim2.new(0, Tokens.spacing.xs + 2, 0.5, 0)
		glyphBadge.Size = UDim2.fromOffset(Tokens.icon.lg + 2, Tokens.icon.lg + 2)
		glyphBadge.BackgroundColor3 = tone.color
		glyphBadge.ZIndex = card.ZIndex + 2
		local glyphCorner = Instance.new("UICorner")
		glyphCorner.CornerRadius = UDim.new(1, 0)
		glyphCorner.Parent = glyphBadge
		local glyphStroke = Instance.new("UIStroke")
		glyphStroke.Thickness = Tokens.stroke.standard
		glyphStroke.Color = Tokens.color.outline
		glyphStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		glyphStroke.Parent = glyphBadge
		local art = Skin.icon(glyphBadge, "toast.icon." .. item.tone, Tokens.icon.lg + 2, card.ZIndex + 3)
		if art then
			glyphBadge.BackgroundTransparency = 1
			glyphStroke.Enabled = false
			art.AnchorPoint = Vector2.new(0.5, 0.5)
			art.Position = UDim2.fromScale(0.5, 0.5)
		else
			local glyph = Icons.build(
				tone.icon,
				glyphBadge,
				Tokens.icon.md,
				{ zIndex = card.ZIndex + 3, color = Tokens.color.featherWhite, outline = false }
			)
			glyph.AnchorPoint = Vector2.new(0.5, 0.5)
			glyph.Position = UDim2.fromScale(0.5, 0.5)
		end
		glyphBadge.Parent = face
		local textLeft = Tokens.spacing.xs + 2 + Tokens.icon.lg + 2 + Tokens.spacing.md
		local label = FrameKit.text(
			face,
			"Text",
			item.text,
			"body",
			{ align = Enum.TextXAlignment.Left, zIndex = card.ZIndex + 2, color = Tokens.color.inkStrong }
		)
		label.Font = Tokens.typography.heading.font
		label.Position = UDim2.fromOffset(textLeft, 0)
		label.Size = UDim2.new(1, -(textLeft + Tokens.spacing.lg), 1, 0)
		label.TextYAlignment = Enum.TextYAlignment.Center
		if item.amount then
			local amountLabel = FrameKit.text(
				face,
				"Amount",
				"+0",
				"numeral",
				{ align = Enum.TextXAlignment.Right, color = Tokens.color.goldDeep, zIndex = card.ZIndex + 2 }
			)
			amountLabel.Font = Tokens.typography.label.font
			amountLabel.AnchorPoint = Vector2.new(1, 0.5)
			amountLabel.Position = UDim2.new(1, -Tokens.spacing.lg, 0.5, 0)
			amountLabel.Size = UDim2.fromOffset(120, Tokens.typography.numeral.size + Tokens.spacing.xs)
			amountLabel.TextYAlignment = Enum.TextYAlignment.Center
			FrameKit.outline(amountLabel, 1.2)
			label.Size = UDim2.new(1, -(textLeft + 120 + Tokens.spacing.lg), 1, 0)
			Tween.countUp(0, item.amount :: number, self._motion(), function(value)
				amountLabel.Text = string.format("+%d Gems", value)
			end)
		end
		card.Parent = self._container
		-- The card hugs its text (plus the amount column on rewards) instead of spanning the container.
		local function fit()
			local extra = if item.amount then 120 + Tokens.spacing.lg else Tokens.spacing.lg
			local wanted = textLeft + math.ceil(label.TextBounds.X) + extra + Tokens.spacing.sm
			card.Size = UDim2.fromOffset(math.clamp(wanted, 240, 440), Tokens.layout.minimumTapTargetPx + Tokens.spacing.xs)
		end
		label:GetPropertyChangedSignal("TextBounds"):Connect(fit)
		fit()
		local shrink = Tween.notify(card, scale, self._motion())
		if self._onShow then
			self._onShow(item.tone)
		end
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
