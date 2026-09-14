--!strict
-- Token-driven button for the rebuilt UI. Variants: primary (gold bevel), secondary (feather-white),
-- ghost (outline only), teal (accent), pill (cream nameplate), danger; "gold" stays an alias of
-- primary for existing callers. Every interaction answers: hover lift + soft tick, press squash,
-- elastic release, click ripple, selected ring, disabled dim, pending spinner, and a controller
-- focus ring. Enforces the minimum tap target and supports an image face (station buttons) and an
-- optional leading vector icon. Returns the button plus cleanup.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local Motion = require(Shared.Design.Motion)
local Tween = require(script.Parent.Tween)
local Icons = require(script.Parent.Icons)
local FrameKit = require(script.Parent.Frame)

local Button = {}

export type Variant = "primary" | "secondary" | "ghost" | "gold" | "pill" | "danger" | "teal"

export type Options = {
	text: string,
	variant: Variant?,
	minimumTapTarget: number,
	motion: Motion.MotionSettings,
	onActivated: (() -> ())?,
	size: UDim2?,
	image: string?, -- asset id for an image face (station buttons)
	caption: string?,
	icon: string?, -- vector icon role from Icons (leading)
	zIndex: number?,
	sound: (() -> ())?, -- tap sound
	hoverSound: (() -> ())?, -- soft hover tick (mouse only, throttled by the audio layer)
	textSize: number?,
}

export type Handle = {
	button: TextButton,
	setEnabled: (enabled: boolean) -> (),
	setPending: (pending: boolean, label: string?) -> (),
	setSelected: (selected: boolean) -> (),
	setText: (text: string) -> (),
	setVariant: (variant: Variant) -> (),
	punch: () -> (),
	pulse: (on: boolean) -> (),
	destroy: () -> (),
}

type Style = {
	background: Color3,
	text: Color3,
	stroke: Color3,
	gradientTop: Color3?,
	gradientBottom: Color3?,
	textStroke: number,
	font: Enum.Font,
	radius: number,
	strokeWidth: number,
	shadow: boolean,
}

local STYLES: { [string]: Style } = {
	primary = {
		background = Tokens.color.gold,
		text = Tokens.color.inkStrong,
		stroke = Tokens.color.outline,
		gradientTop = Tokens.color.goldLight,
		gradientBottom = Tokens.color.goldDeep,
		textStroke = 1,
		font = Tokens.typography.label.font,
		radius = Tokens.radius.md,
		strokeWidth = Tokens.stroke.bold,
		shadow = true,
	},
	secondary = {
		background = Tokens.color.featherWhite,
		text = Tokens.color.inkStrong,
		stroke = Tokens.color.outline,
		gradientTop = Tokens.color.featherWhite,
		gradientBottom = Tokens.color.creamDeep,
		textStroke = 1,
		font = Tokens.typography.heading.font,
		radius = Tokens.radius.md,
		strokeWidth = Tokens.stroke.standard,
		shadow = true,
	},
	ghost = {
		background = Tokens.color.featherWhite,
		text = Tokens.color.ink,
		stroke = Tokens.color.strawDeep,
		textStroke = 1,
		font = Tokens.typography.heading.font,
		radius = Tokens.radius.md,
		strokeWidth = Tokens.stroke.standard,
		shadow = false,
	},
	teal = {
		background = Tokens.color.tealAccent,
		text = Tokens.color.featherWhite,
		stroke = Tokens.color.tealDeep,
		gradientTop = Tokens.color.tealLight,
		gradientBottom = Tokens.color.tealAccent,
		textStroke = 1,
		font = Tokens.typography.heading.font,
		radius = Tokens.radius.md,
		strokeWidth = Tokens.stroke.standard,
		shadow = true,
	},
	pill = {
		background = Tokens.color.creamPill,
		text = Tokens.color.gold,
		stroke = Tokens.color.outline,
		gradientTop = Tokens.color.featherWhite,
		gradientBottom = Tokens.color.creamPill,
		textStroke = 0.2,
		font = Tokens.typography.label.font,
		radius = Tokens.radius.pill,
		strokeWidth = Tokens.stroke.bold,
		shadow = true,
	},
	danger = {
		background = Tokens.color.danger,
		text = Tokens.color.featherWhite,
		stroke = Tokens.color.outline,
		gradientTop = Tokens.color.ember,
		gradientBottom = Tokens.color.danger,
		textStroke = 1,
		font = Tokens.typography.heading.font,
		radius = Tokens.radius.md,
		strokeWidth = Tokens.stroke.standard,
		shadow = true,
	},
}
STYLES.gold = STYLES.primary

-- Ghost buttons are outline-only: the fill is transparent.
local GHOST_FILL_TRANSPARENCY = 0.55

function Button.create(parent: Instance, options: Options): (TextButton, () -> ())
	local handle = Button.build(parent, options)
	return handle.button, handle.destroy
end

function Button.build(parent: Instance, options: Options): Handle
	local variantName: string = options.variant or "primary"
	local style = STYLES[variantName] or STYLES.primary
	local z = options.zIndex or 1
	local motion = options.motion

	local button = Instance.new("TextButton")
	button.Name = "Button_" .. options.text
	button.AutoButtonColor = false
	button.BackgroundColor3 = style.background
	button.BackgroundTransparency = if variantName == "ghost" then GHOST_FILL_TRANSPARENCY else 0
	button.TextColor3 = style.text
	button.Font = style.font
	button.TextSize = options.textSize or (if variantName == "pill" then Tokens.typography.label.size else Tokens.typography.heading.size)
	button.Text = if options.image then "" else options.text
	button.TextStrokeColor3 = Tokens.color.outline
	button.TextStrokeTransparency = style.textStroke
	button.TextTruncate = Enum.TextTruncate.AtEnd
	button.Size = options.size or UDim2.fromOffset(160, options.minimumTapTarget)
	button.Selectable = true
	button.ZIndex = z
	button.ClipsDescendants = false
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, style.radius)
	corner.Parent = button
	local stroke = Instance.new("UIStroke")
	stroke.Name = "Outline"
	stroke.Thickness = style.strokeWidth
	stroke.Color = style.stroke
	stroke.Parent = button
	local gradient = Instance.new("UIGradient")
	gradient.Name = "Fill"
	gradient.Rotation = 90
	gradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, style.gradientTop or style.background),
		ColorSequenceKeypoint.new(1, style.gradientBottom or style.background),
	})
	gradient.Parent = button
	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, Tokens.spacing.lg)
	padding.PaddingRight = UDim.new(0, Tokens.spacing.lg)
	padding.Parent = button
	local constraint = Instance.new("UISizeConstraint")
	constraint.MinSize = Vector2.new(options.minimumTapTarget, options.minimumTapTarget)
	constraint.Parent = button
	local scale = Instance.new("UIScale")
	scale.Parent = button
	-- Hover highlight: a white wash that fades in over the face.
	local wash = Instance.new("Frame")
	wash.Name = "Wash"
	wash.Position = UDim2.fromOffset(-Tokens.spacing.lg, 0)
	wash.Size = UDim2.new(1, Tokens.spacing.lg * 2, 1, 0)
	wash.BackgroundColor3 = Color3.new(1, 1, 1)
	wash.BackgroundTransparency = 1
	wash.BorderSizePixel = 0
	wash.ZIndex = z + 1
	local washCorner = Instance.new("UICorner")
	washCorner.CornerRadius = UDim.new(0, style.radius)
	washCorner.Parent = wash
	wash.Parent = button
	-- Focus ring for controllers: a second stroke outside the outline, hidden until selected.
	local ring = Instance.new("UIStroke")
	ring.Name = "FocusRing"
	ring.Thickness = 0
	ring.Color = Tokens.color.goldLight
	ring.Transparency = 0.1
	ring.Enabled = false
	ring.Parent = button
	local shadow: Frame? = nil
	if style.shadow and not options.image then
		shadow = FrameKit.shadow(button, { radius = style.radius })
	end

	-- Optional image face (station buttons) or leading vector icon.
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
		wash.Visible = false
	elseif options.caption then
		button.Text = options.caption
	end
	if options.icon and not options.image then
		local iconPx = Tokens.icon.md
		local icon = Icons.build(
			options.icon,
			button,
			iconPx,
			{ zIndex = z + 2, color = if variantName == "teal" or variantName == "danger" then Tokens.color.featherWhite else nil }
		)
		icon.AnchorPoint = Vector2.new(0, 0.5)
		icon.Position = UDim2.fromScale(0, 0.5)
		button.TextXAlignment = Enum.TextXAlignment.Left
		padding.PaddingLeft = UDim.new(0, Tokens.spacing.md)
		-- Shift the text right of the icon.
		button.Text = "      " .. button.Text
	end

	local enabled = true
	local pending = false
	local selected = false
	local hovered = false
	local baseText = button.Text
	local spinner: Frame? = nil
	local spinnerConnection: RBXScriptConnection? = nil
	local stopPulse: (() -> ())? = nil

	local function applyState()
		local dim = not enabled
		button.Active = enabled
		button.Selectable = enabled
		if imageLabel then
			imageLabel.ImageTransparency = if dim then 0.45 else 0
			button.BackgroundTransparency = 1
		else
			button.BackgroundTransparency = if variantName == "ghost"
				then GHOST_FILL_TRANSPARENCY + (if dim then 0.25 else 0)
				else (if dim then 0.35 else 0)
		end
		button.TextTransparency = if dim then 0.45 elseif pending then 0.3 else 0
		stroke.Transparency = if dim then 0.5 else 0
		if selected then
			stroke.Color = Tokens.color.tealAccent
			stroke.Thickness = Tokens.stroke.bold
		else
			stroke.Color = style.stroke
			stroke.Thickness = style.strokeWidth
		end
		if shadow then
			shadow.Visible = not dim
		end
	end

	local function tweenScale(recipe: string, override: number?)
		Tween.scale(scale, recipe, motion, override)
	end

	local function setWash(target: number)
		Tween.fade(wash, motion, target)
	end

	local connections: { RBXScriptConnection } = {
		button.MouseEnter:Connect(function()
			hovered = true
			if enabled then
				tweenScale("hover")
				setWash(0.82)
				if options.hoverSound and UserInputService.MouseEnabled then
					options.hoverSound()
				end
			end
		end),
		button.MouseLeave:Connect(function()
			hovered = false
			tweenScale("release", 1)
			setWash(1)
		end),
		button.MouseButton1Down:Connect(function()
			if enabled then
				tweenScale("press")
			end
		end),
		button.MouseButton1Up:Connect(function()
			tweenScale("release", if hovered and enabled then Motion.recipe("hover", motion).scale else 1)
		end),
		button.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.Touch and enabled then
				tweenScale("press")
				setWash(0.85)
			end
		end),
		button.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.Touch then
				tweenScale("release", 1)
				setWash(1)
			end
		end),
		button.SelectionGained:Connect(function()
			ring.Enabled = true
			ring.Thickness = Tokens.stroke.frame
			tweenScale("hover")
		end),
		button.SelectionLost:Connect(function()
			ring.Enabled = false
			ring.Thickness = 0
			tweenScale("release", 1)
		end),
	}
	table.insert(
		connections,
		button.Activated:Connect(function(inputObject)
			if not enabled or pending then
				if not enabled then
					Tween.shake(button, motion)
				end
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
			Tween.ripple(button, motion, if imageLabel then Tokens.color.goldLight else Tokens.color.featherWhite, at)
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
	applyState()

	local function setPending(value: boolean, label: string?)
		pending = value
		if value then
			if not imageLabel then
				button.Text = label or "..."
			end
			if not spinner then
				local ringFrame = Instance.new("Frame")
				ringFrame.Name = "Spinner"
				ringFrame.AnchorPoint = Vector2.new(1, 0.5)
				ringFrame.Position = UDim2.fromScale(1, 0.5)
				ringFrame.Size = UDim2.fromOffset(Tokens.icon.sm, Tokens.icon.sm)
				ringFrame.BackgroundTransparency = 1
				ringFrame.ZIndex = z + 3
				local arc = Instance.new("UIStroke")
				arc.Thickness = 2.5
				arc.Color = style.text
				arc.Parent = ringFrame
				local arcCorner = Instance.new("UICorner")
				arcCorner.CornerRadius = UDim.new(1, 0)
				arcCorner.Parent = ringFrame
				local notch = Instance.new("Frame")
				notch.AnchorPoint = Vector2.new(0.5, 0)
				notch.Position = UDim2.fromScale(0.5, -0.1)
				notch.Size = UDim2.fromScale(0.4, 0.4)
				notch.BackgroundColor3 = style.background
				notch.BorderSizePixel = 0
				notch.ZIndex = z + 4
				notch.Parent = ringFrame
				ringFrame.Parent = button
				spinner = ringFrame
				spinnerConnection = RunService.RenderStepped:Connect(function(dt)
					ringFrame.Rotation = (ringFrame.Rotation + dt * 360) % 360
				end)
			end
		else
			if not imageLabel then
				button.Text = baseText
			end
			if spinnerConnection then
				spinnerConnection:Disconnect()
				spinnerConnection = nil
			end
			if spinner then
				spinner:Destroy()
				spinner = nil
			end
		end
		applyState()
	end

	local handle: Handle = {
		button = button,
		setEnabled = function(value: boolean)
			enabled = value
			applyState()
		end,
		setPending = setPending,
		setSelected = function(value: boolean)
			selected = value
			applyState()
		end,
		setText = function(text: string)
			baseText = if options.icon and not options.image then "      " .. text else text
			if not pending and not imageLabel then
				button.Text = baseText
			end
		end,
		setVariant = function(variant: Variant)
			variantName = variant
			style = STYLES[variant] or STYLES.primary
			button.BackgroundColor3 = style.background
			button.TextColor3 = style.text
			gradient.Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, style.gradientTop or style.background),
				ColorSequenceKeypoint.new(1, style.gradientBottom or style.background),
			})
			corner.CornerRadius = UDim.new(0, style.radius)
			applyState()
		end,
		punch = function()
			Tween.rotationPunch(button, motion, 0)
		end,
		pulse = function(on: boolean)
			if on and not stopPulse then
				stopPulse = Tween.pulseLoop(scale, motion)
			elseif not on and stopPulse then
				stopPulse()
				stopPulse = nil
			end
		end,
		destroy = function()
			if stopPulse then
				stopPulse()
			end
			setPending(false)
			for _, connection in ipairs(connections) do
				connection:Disconnect()
			end
			button:Destroy()
		end,
	}
	return handle
end

return Button
