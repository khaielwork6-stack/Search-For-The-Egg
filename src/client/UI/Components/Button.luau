--!strict
-- Token-driven button in the owner's language (gold bevel / teal / cream pill variants) with the
-- supplied motion recipes: hover Back-out, press Sine-in, release Elastic, click ripple. Enforces the
-- minimum tap target, styles controller selection, supports touch press feedback, disabled and
-- pending states, and an optional image face (station buttons). Returns the button plus cleanup.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local Motion = require(Shared.Design.Motion)
local Tween = require(script.Parent.Tween)

local Button = {}

export type Variant = "primary" | "secondary" | "ghost" | "gold" | "pill" | "danger"

export type Options = {
	text: string,
	variant: Variant?,
	minimumTapTarget: number,
	motion: Motion.MotionSettings,
	onActivated: (() -> ())?,
	size: UDim2?,
	image: string?, -- asset id for an image face (text becomes the pill caption below the art)
	caption: string?, -- pill caption under an image face
	zIndex: number?,
	sound: (() -> ())?,
}

export type Handle = {
	button: TextButton,
	setEnabled: (enabled: boolean) -> (),
	setPending: (pending: boolean, label: string?) -> (),
	setText: (text: string) -> (),
	punch: () -> (),
	destroy: () -> (),
}

local VARIANTS: { [string]: { background: Color3, text: Color3, stroke: Color3, gradientTop: Color3?, gradientBottom: Color3? } } = {
	primary = { background = Tokens.color.ember, text = Tokens.color.cream, stroke = Tokens.color.emberDeep },
	secondary = { background = Tokens.color.straw, text = Tokens.color.inkStrong, stroke = Tokens.color.strawDeep },
	ghost = { background = Tokens.color.tealLight, text = Tokens.color.cream, stroke = Tokens.color.tealDeep },
	gold = {
		background = Tokens.color.gold,
		text = Tokens.color.inkStrong,
		stroke = Tokens.color.outline,
		gradientTop = Tokens.color.goldLight,
		gradientBottom = Tokens.color.goldDeep,
	},
	pill = {
		background = Tokens.color.creamPill,
		text = Tokens.color.gold,
		stroke = Tokens.color.outline,
		gradientTop = Tokens.color.surface,
		gradientBottom = Tokens.color.creamPill,
	},
	danger = { background = Tokens.color.danger, text = Tokens.color.cream, stroke = Tokens.color.outline },
}

function Button.create(parent: Instance, options: Options): (TextButton, () -> ())
	local handle = Button.build(parent, options)
	return handle.button, handle.destroy
end

function Button.build(parent: Instance, options: Options): Handle
	local variantName = options.variant or "primary"
	local variant = VARIANTS[variantName]
	local z = options.zIndex or 1
	local button = Instance.new("TextButton")
	button.Name = "Button_" .. options.text
	button.AutoButtonColor = false
	button.BackgroundColor3 = variant.background
	button.TextColor3 = variant.text
	button.Font = if variantName == "pill" or variantName == "gold" then Tokens.typography.label.font else Tokens.typography.heading.font
	button.TextSize = if variantName == "pill" then Tokens.typography.label.size else Tokens.typography.heading.size
	button.Text = if options.image then "" else options.text
	button.TextStrokeColor3 = Tokens.color.outline
	button.TextStrokeTransparency = if variantName == "pill" or variantName == "gold" then 0.2 else 1
	button.Size = options.size or UDim2.fromOffset(160, options.minimumTapTarget)
	button.Selectable = true
	button.ZIndex = z
	button.ClipsDescendants = true
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, if variantName == "pill" then Tokens.radius.pill else Tokens.radius.md)
	corner.Parent = button
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = if variantName == "gold" or variantName == "pill" then Tokens.stroke.bold else Tokens.stroke.standard
	stroke.Color = variant.stroke
	stroke.Parent = button
	if variant.gradientTop then
		local gradient = Instance.new("UIGradient")
		gradient.Rotation = 90
		gradient.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, variant.gradientTop :: Color3),
			ColorSequenceKeypoint.new(1, variant.gradientBottom :: Color3),
		})
		gradient.Parent = button
	end
	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, Tokens.spacing.lg)
	padding.PaddingRight = UDim.new(0, Tokens.spacing.lg)
	padding.Parent = button
	local constraint = Instance.new("UISizeConstraint")
	constraint.MinSize = Vector2.new(options.minimumTapTarget, options.minimumTapTarget)
	constraint.Parent = button
	local scale = Instance.new("UIScale")
	scale.Parent = button

	-- Optional image face with a pill caption (station buttons).
	local imageLabel: ImageLabel? = nil
	if options.image then
		padding.PaddingLeft = UDim.new(0, 0)
		padding.PaddingRight = UDim.new(0, 0)
		local image = Instance.new("ImageLabel")
		image.Name = "Face"
		image.BackgroundTransparency = 1
		image.Size = UDim2.fromScale(1, 1)
		image.Image = options.image :: string
		image.ScaleType = Enum.ScaleType.Fit
		image.ZIndex = z + 1
		image.Parent = button
		imageLabel = image
		button.BackgroundTransparency = 1
		stroke.Enabled = false
	elseif options.caption then
		button.Text = options.caption
	end

	local enabled = true
	local pending = false
	local baseText = button.Text
	local motion = options.motion

	local function tweenScale(recipe: string, override: number?)
		Tween.scale(scale, recipe, motion, override)
	end

	local connections: { RBXScriptConnection } = {
		button.MouseEnter:Connect(function()
			if enabled then
				tweenScale("hover")
			end
		end),
		button.MouseLeave:Connect(function()
			tweenScale("release", 1)
		end),
		button.MouseButton1Down:Connect(function()
			if enabled then
				tweenScale("press")
			end
		end),
		button.MouseButton1Up:Connect(function()
			tweenScale("release", 1)
		end),
		button.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.Touch and enabled then
				tweenScale("press")
			end
		end),
		button.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.Touch then
				tweenScale("release", 1)
			end
		end),
		button.SelectionGained:Connect(function()
			stroke.Enabled = true
			stroke.Thickness = Tokens.stroke.frame
			stroke.Color = Tokens.color.goldLight
			tweenScale("hover")
		end),
		button.SelectionLost:Connect(function()
			stroke.Thickness = if variantName == "gold" or variantName == "pill" then Tokens.stroke.bold else Tokens.stroke.standard
			stroke.Color = variant.stroke
			stroke.Enabled = imageLabel == nil
			tweenScale("release", 1)
		end),
	}
	table.insert(
		connections,
		button.Activated:Connect(function(inputObject)
			if not enabled or pending then
				return
			end
			local at: Vector2? = nil
			if inputObject and (inputObject :: any).Position then
				local pos = (inputObject :: any).Position
				local abs = button.AbsolutePosition
				local size = button.AbsoluteSize
				if size.X > 0 and size.Y > 0 then
					at = Vector2.new(math.clamp((pos.X - abs.X) / size.X, 0, 1), math.clamp((pos.Y - abs.Y) / size.Y, 0, 1))
				end
			end
			Tween.ripple(button, motion, if imageLabel then Tokens.color.goldLight else Tokens.color.cream, at)
			tweenScale("press")
			task.delay(Motion.recipe("press", motion).duration, function()
				tweenScale("release", 1)
			end)
			if options.sound then
				options.sound()
			end
			if options.onActivated then
				options.onActivated()
			end
		end)
	)
	button.Parent = parent

	local handle: Handle = {
		button = button,
		setEnabled = function(value: boolean)
			enabled = value
			button.Active = value
			button.Selectable = value
			button.BackgroundTransparency = if imageLabel then 1 elseif value then 0 else 0.35
			button.TextTransparency = if value then 0 else 0.4
			if imageLabel then
				imageLabel.ImageTransparency = if value then 0 else 0.45
			end
		end,
		setPending = function(value: boolean, label: string?)
			pending = value
			if not imageLabel then
				button.Text = if value then (label or "...") else baseText
			end
			button.TextTransparency = if value then 0.3 else 0
		end,
		setText = function(text: string)
			baseText = text
			if not pending and not imageLabel then
				button.Text = text
			end
		end,
		punch = function()
			Tween.rotationPunch(button, motion, 0)
		end,
		destroy = function()
			for _, connection in ipairs(connections) do
				connection:Disconnect()
			end
			button:Destroy()
		end,
	}
	return handle
end

return Button
