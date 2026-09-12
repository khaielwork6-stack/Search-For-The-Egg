--!strict
-- Token-driven button with press/hover motion semantics, minimum tap target enforcement, and
-- controller selection styling. Returns the TextButton plus a cleanup function.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local Motion = require(Shared.Design.Motion)

local Button = {}

export type Options = {
	text: string,
	variant: ("primary" | "secondary" | "ghost")?,
	minimumTapTarget: number,
	motion: Motion.MotionSettings,
	onActivated: (() -> ())?,
	size: UDim2?,
}

local VARIANTS = {
	primary = { background = Tokens.color.ember, text = Tokens.color.cream, stroke = Tokens.color.emberDeep },
	secondary = { background = Tokens.color.straw, text = Tokens.color.inkStrong, stroke = Tokens.color.strawDeep },
	ghost = { background = Tokens.color.surfaceAlt, text = Tokens.color.ink, stroke = Tokens.color.creamDeep },
}

function Button.create(parent: Instance, options: Options): (TextButton, () -> ())
	local variant = VARIANTS[options.variant or "primary"]
	local button = Instance.new("TextButton")
	button.Name = "Button_" .. options.text
	button.AutoButtonColor = false
	button.BackgroundColor3 = variant.background
	button.TextColor3 = variant.text
	button.Font = Tokens.typography.heading.font
	button.TextSize = Tokens.typography.heading.size
	button.Text = options.text
	button.Size = options.size or UDim2.fromOffset(160, options.minimumTapTarget)
	button.Selectable = true
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, Tokens.radius.md)
	corner.Parent = button
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = Tokens.stroke.standard
	stroke.Color = variant.stroke
	stroke.Parent = button
	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, Tokens.spacing.lg)
	padding.PaddingRight = UDim.new(0, Tokens.spacing.lg)
	padding.Parent = button
	local constraint = Instance.new("UISizeConstraint")
	constraint.MinSize = Vector2.new(options.minimumTapTarget, options.minimumTapTarget)
	constraint.Parent = button
	local scale = Instance.new("UIScale")
	scale.Parent = button

	local function tweenScale(target: number, token: string)
		local info = TweenInfo.new(Motion.duration(token, options.motion), Tokens.motion.easeOut, Enum.EasingDirection.Out)
		TweenService:Create(scale, info, { Scale = target }):Play()
	end

	local connections = {
		button.MouseEnter:Connect(function()
			tweenScale(1 + Motion.amplitude(Tokens.motion.hoverScale - 1, options.motion), "quick")
		end),
		button.MouseLeave:Connect(function()
			tweenScale(1, "quick")
		end),
		button.MouseButton1Down:Connect(function()
			tweenScale(1 - Motion.amplitude(1 - Tokens.motion.pressScale, options.motion), "instant")
		end),
		button.MouseButton1Up:Connect(function()
			tweenScale(1, "quick")
		end),
		button.SelectionGained:Connect(function()
			stroke.Thickness = Tokens.stroke.bold
			stroke.Color = Tokens.color.sky
		end),
		button.SelectionLost:Connect(function()
			stroke.Thickness = Tokens.stroke.standard
			stroke.Color = variant.stroke
		end),
	}
	if options.onActivated then
		table.insert(connections, button.Activated:Connect(options.onActivated))
	end
	button.Parent = parent
	return button, function()
		for _, connection in ipairs(connections) do
			connection:Disconnect()
		end
		button:Destroy()
	end
end

return Button
