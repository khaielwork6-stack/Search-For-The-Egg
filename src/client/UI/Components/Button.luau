--!strict
-- Hand-drawn button: a coloured face on a darker lip (the face drops onto the lip when pressed),
-- cocoa keyline and a bright inner rim, banded sheen, outlined lettering on strong variants, hover
-- wash and lift, elastic release,
-- selected ring, disabled dim, pending spinner, controller focus ring, and layered sounds.
-- Variants: primary (gold), secondary (cream), ghost (outline only), teal (accent), pill (cream
-- nameplate), danger (ember). "gold" stays an alias of primary. Image faces serve station buttons.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local Depth = require(script.Parent.Depth)
local Motion = require(Shared.Design.Motion)
local Tween = require(script.Parent.Tween)
local Icons = require(script.Parent.Icons)
local FrameKit = require(script.Parent.Frame)
local Skin = require(script.Parent.Skin)

local Button = {}

export type Variant = "primary" | "secondary" | "ghost" | "gold" | "pill" | "danger" | "teal" | "gem" | "success" | "ember"

export type Options = {
	text: string,
	variant: Variant?,
	minimumTapTarget: number,
	motion: Motion.MotionSettings,
	onActivated: (() -> ())?,
	size: UDim2?,
	image: string?,
	pressedImage: string?,
	caption: string?,
	icon: string?,
	zIndex: number?,
	sound: (() -> ())?,
	hoverSound: (() -> ())?,
	textSize: number?,
	art: boolean?,
	round: boolean?,
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
	face: Color3,
	faceLight: Color3,
	lip: Color3,
	text: Color3,
	font: Enum.Font,
	radius: number,
	outlined: boolean,
	ghost: boolean?,
}

local STYLES: { [string]: Style } = {
	primary = {
		face = Tokens.color.gold,
		faceLight = Tokens.color.goldLight,
		lip = Tokens.color.goldDeep,
		text = Tokens.color.featherWhite,
		font = Tokens.typography.label.font,
		radius = Tokens.radius.md,
		outlined = true,
	},
	secondary = {
		face = Tokens.color.creamPill,
		faceLight = Tokens.color.featherWhite,
		lip = Tokens.color.strawDeep,
		text = Tokens.color.inkStrong,
		font = Tokens.typography.label.font,
		radius = Tokens.radius.md,
		outlined = false,
	},
	ghost = {
		face = Tokens.color.featherWhite,
		faceLight = Tokens.color.featherWhite,
		lip = Tokens.color.strawDeep,
		text = Tokens.color.ink,
		font = Tokens.typography.heading.font,
		radius = Tokens.radius.md,
		outlined = false,
		ghost = true,
	},
	teal = {
		face = Tokens.color.tealAccent,
		faceLight = Tokens.color.tealLight,
		lip = Tokens.color.tealDeep,
		text = Tokens.color.featherWhite,
		font = Tokens.typography.label.font,
		radius = Tokens.radius.md,
		outlined = true,
	},
	pill = {
		face = Tokens.color.creamPill,
		faceLight = Tokens.color.featherWhite,
		lip = Tokens.color.strawDeep,
		text = Tokens.color.goldDeep,
		font = Tokens.typography.label.font,
		radius = Tokens.radius.pill,
		outlined = false,
	},
	-- The big warm call-to-action of the NPC cards: orange face, cream lettering.
	ember = {
		face = Tokens.color.ember,
		faceLight = Color3.fromRGB(255, 168, 96),
		lip = Tokens.color.emberDeep,
		text = Tokens.color.featherWhite,
		font = Tokens.typography.label.font,
		radius = Tokens.radius.lg,
		outlined = true,
	},
	danger = {
		face = Tokens.color.ember,
		faceLight = Color3.fromRGB(246, 150, 104),
		lip = Tokens.color.emberDeep,
		text = Tokens.color.featherWhite,
		font = Tokens.typography.label.font,
		radius = Tokens.radius.md,
		outlined = true,
	},
	-- Gem purchases and Robux products: the gem purple of the currency itself.
	gem = {
		face = Tokens.color.gem,
		faceLight = Color3.fromRGB(160, 136, 240),
		lip = Tokens.color.gemDeep,
		text = Tokens.color.featherWhite,
		font = Tokens.typography.label.font,
		radius = Tokens.radius.md,
		outlined = true,
	},
	-- The big "go" action (spin a class, set off): leaf green.
	success = {
		face = Tokens.color.leafBright,
		faceLight = Color3.fromRGB(170, 224, 120),
		lip = Tokens.color.leafDeep,
		text = Tokens.color.featherWhite,
		font = Tokens.typography.label.font,
		radius = Tokens.radius.md,
		outlined = true,
	},
}
STYLES.gold = STYLES.primary

-- The barn's glossy rims, by variant. Laid over the face (never replacing it), so the colour and
-- the lip still come from the style and the rim adds the bevel the reference buttons have.
local RIM_BY_VARIANT: { [string]: string } = {
	primary = "button.primary.normal",
	gold = "button.primary.normal",
	ember = "button.primary.normal",
	danger = "button.danger.normal",
	teal = "button.ghost.normal",
	secondary = "button.secondary.normal",
	pill = "button.secondary.normal",
	success = "button.secondary.normal",
	gem = "button.secondary.normal",
}

-- The lip is what gives the control a thickness. Four pixels was not enough to read as one at any
-- size the game actually draws buttons at.
local LIP = Tokens.depth.lipPx

function Button.create(parent: Instance, options: Options): (TextButton, () -> ())
	local handle = Button.build(parent, options)
	return handle.button, handle.destroy
end

function Button.build(parent: Instance, options: Options): Handle
	local variantName: string = options.variant or "primary"
	local style = STYLES[variantName] or STYLES.primary
	local z = options.zIndex or 1
	local motion = options.motion

	-- The button itself is the lip; the face sits on top and drops when pressed.
	local button = Instance.new("TextButton")
	button.Name = "Button_" .. options.text
	button.AutoButtonColor = false
	button.Text = ""
	button.BackgroundColor3 = style.lip
	button.BackgroundTransparency = if style.ghost then 1 else 0
	button.Size = options.size or UDim2.fromOffset(160, options.minimumTapTarget)
	button.Selectable = true
	button.ZIndex = z
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, if options.round then 999 else style.radius)
	corner.Parent = button
	local outline = Depth.keyline(button)
	outline.Transparency = if style.ghost then 0.35 else 0
	local constraint = Instance.new("UISizeConstraint")
	constraint.MinSize = Vector2.new(options.minimumTapTarget, options.minimumTapTarget)
	constraint.Parent = button
	local scale = Instance.new("UIScale")
	scale.Parent = button
	local ring = Instance.new("UIStroke")
	ring.Name = "FocusRing"
	ring.Thickness = 0
	ring.Color = Tokens.color.goldLight
	ring.Transparency = 0.1
	ring.Enabled = false
	ring.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	ring.Parent = button

	local face = Instance.new("Frame")
	face.Name = "Face"
	face.Size = UDim2.new(1, 0, 1, if style.ghost then 0 else -LIP)
	face.BackgroundColor3 = style.face
	face.BackgroundTransparency = if style.ghost then 0.35 else 0
	face.BorderSizePixel = 0
	face.ZIndex = z + 1
	local faceCorner = Instance.new("UICorner")
	faceCorner.CornerRadius = UDim.new(0, if options.round then 999 else style.radius)
	faceCorner.Parent = face
	-- The banded sheen and the rim are the two things that stop a face reading as a flat rectangle.
	-- The rim goes on the face, not the button, so it traces the lit edge and not the lip.
	local gradient = Depth.applySheen(face, style.face, style.faceLight)
	local rim = Depth.rim(face, style.face)
	rim.Transparency = if style.ghost then 1 else Tokens.depth.rimTransparency
	face.Parent = button
	local wash = Instance.new("Frame")
	wash.Name = "Wash"
	wash.Size = UDim2.fromScale(1, 1)
	wash.BackgroundColor3 = Color3.new(1, 1, 1)
	wash.BackgroundTransparency = 1
	wash.BorderSizePixel = 0
	wash.ZIndex = z + 2
	local washCorner = Instance.new("UICorner")
	washCorner.CornerRadius = UDim.new(0, if options.round then 999 else style.radius)
	washCorner.Parent = wash
	wash.Parent = face

	-- The pack's rim, over the face and under the lettering. Round buttons keep the vector rim.
	local rimRole = RIM_BY_VARIANT[variantName]
	if rimRole and not options.round and not options.image then
		local packRim = Skin.overlay(face, rimRole, { zIndex = z + 3, inset = 3, name = "PackRim" })
		if packRim then
			outline.Transparency = 1
			rim.Transparency = 1
		end
	end
	-- The shine: a streak of light that sweeps the face while the button is pulsing.
	face.ClipsDescendants = true
	local shine = Skin.overlay(face, "texture.rays", { zIndex = z + 2, name = "Shine", transparency = 0.55 })
	if shine then
		shine.AnchorPoint = Vector2.new(0, 0.5)
		shine.Size = UDim2.fromScale(0.6, 1.6)
		shine.Position = UDim2.fromScale(-0.7, 0.5)
		shine.Visible = false
	end

	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = style.font
	label.TextSize = FrameKit.textSize(
		options.textSize or (if variantName == "pill" then Tokens.typography.label.size else Tokens.typography.heading.size + 1)
	)
	label.TextColor3 = style.text
	label.Text = if options.image then "" else options.text
	label.TextTruncate = Enum.TextTruncate.AtEnd
	label.ZIndex = z + 4
	label.Parent = face
	local labelPadding = Instance.new("UIPadding")
	labelPadding.PaddingLeft = UDim.new(0, if options.round then 0 else Tokens.spacing.lg)
	labelPadding.PaddingRight = UDim.new(0, if options.round then 0 else Tokens.spacing.lg)
	labelPadding.Parent = label
	local textOutline = if style.outlined then FrameKit.outline(label, 1.8) else nil

	-- Optional image face (station buttons) or leading vector icon.
	local imageLabel: ImageLabel? = nil
	if options.image then
		local image = Instance.new("ImageLabel")
		image.Name = "Face"
		image.BackgroundTransparency = 1
		image.Size = UDim2.fromScale(1, 1)
		image.Image = options.image :: string
		image.ScaleType = Enum.ScaleType.Fit
		image.ZIndex = z + 4
		image.Parent = button
		imageLabel = image
		button.BackgroundTransparency = 1
		outline.Enabled = false
		face.Visible = false
		if options.pressedImage then
			local pressedImage = options.pressedImage :: string
			local normalImage = options.image :: string
			image.InputBegan:Connect(function()
				image.Image = pressedImage
			end)
			image.InputEnded:Connect(function()
				image.Image = normalImage
			end)
		end
	elseif options.caption then
		label.Text = options.caption
	end
	if options.icon and not options.image then
		local icon = Icons.build(
			options.icon,
			face,
			Tokens.icon.md,
			{ zIndex = z + 4, color = if style.outlined then Tokens.color.featherWhite else nil }
		)
		icon.AnchorPoint = Vector2.new(0, 0.5)
		icon.Position = UDim2.new(0, Tokens.spacing.md, 0.5, 0)
		label.TextXAlignment = Enum.TextXAlignment.Left
		labelPadding.PaddingLeft = UDim.new(0, Tokens.spacing.md + Tokens.icon.md + Tokens.spacing.sm)
	end

	local enabled = true
	local pending = false
	local selected = false
	local hovered = false
	local pressedDown = false
	local baseText = label.Text
	local spinner: Frame? = nil
	local spinnerConnection: RBXScriptConnection? = nil
	local stopPulse: (() -> ())? = nil

	local function setFaceDown(down: boolean)
		if style.ghost or imageLabel then
			return
		end
		local target = if down then UDim2.fromOffset(0, LIP) else UDim2.fromOffset(0, 0)
		TweenService:Create(
			face,
			TweenInfo.new(Motion.duration("instant", motion), Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Position = target }
		):Play()
	end

	local function applyState()
		local dim = not enabled
		button.Active = enabled
		button.Selectable = enabled
		if imageLabel then
			imageLabel.ImageTransparency = if dim then 0.45 else 0
		else
			face.BackgroundTransparency = if style.ghost then (if dim then 0.7 else 0.35) else (if dim then 0.4 else 0)
			button.BackgroundTransparency = if style.ghost then 1 else (if dim then 0.5 else 0)
		end
		label.TextTransparency = if dim and selected then 0.15 elseif dim then 0.45 elseif pending then 0.3 else 0
		if textOutline then
			textOutline.Transparency = if dim then 0.5 else 0
		end
		outline.Transparency = if style.ghost then (if dim then 0.7 else 0.35) else (if dim then 0.4 else 0)
		if selected then
			outline.Color = Tokens.color.tealAccent
			outline.Thickness = Tokens.stroke.frame
			outline.Transparency = 0
		else
			outline.Color = Tokens.color.outline
			outline.Thickness = Tokens.stroke.bold
		end
		outline.Enabled = imageLabel == nil or selected
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
				setWash(0.84)
				if options.hoverSound and UserInputService.MouseEnabled then
					options.hoverSound()
				end
			end
		end),
		button.MouseLeave:Connect(function()
			hovered = false
			pressedDown = false
			tweenScale("release", 1)
			setWash(1)
			setFaceDown(false)
		end),
		button.MouseButton1Down:Connect(function()
			if enabled then
				pressedDown = true
				tweenScale("press")
				setFaceDown(true)
			end
		end),
		button.MouseButton1Up:Connect(function()
			pressedDown = false
			tweenScale("release", if hovered and enabled then Motion.recipe("hover", motion).scale else 1)
			setFaceDown(false)
		end),
		button.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.Touch and enabled then
				tweenScale("press")
				setWash(0.86)
				setFaceDown(true)
			end
		end),
		button.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.Touch then
				tweenScale("release", 1)
				setWash(1)
				setFaceDown(false)
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
			Tween.ripple(if imageLabel then button else face, motion, Tokens.color.featherWhite, at)
			if not pressedDown then
				tweenScale("press")
				task.delay(Motion.recipe("press", motion).duration, function()
					tweenScale("release", 1)
				end)
			end
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

	local function setPending(value: boolean, labelText: string?)
		pending = value
		if value then
			if not imageLabel then
				label.Text = labelText or "..."
			end
			if not spinner then
				local ringFrame = Instance.new("Frame")
				ringFrame.Name = "Spinner"
				ringFrame.AnchorPoint = Vector2.new(1, 0.5)
				ringFrame.Position = UDim2.new(1, -Tokens.spacing.sm, 0.5, 0)
				ringFrame.Size = UDim2.fromOffset(Tokens.icon.sm, Tokens.icon.sm)
				ringFrame.BackgroundTransparency = 1
				ringFrame.ZIndex = z + 5
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
				notch.BackgroundColor3 = style.face
				notch.BorderSizePixel = 0
				notch.ZIndex = z + 6
				notch.Parent = ringFrame
				ringFrame.Parent = face
				spinner = ringFrame
				spinnerConnection = RunService.RenderStepped:Connect(function(dt)
					ringFrame.Rotation = (ringFrame.Rotation + dt * 360) % 360
				end)
			end
		else
			if not imageLabel then
				label.Text = baseText
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
			baseText = text
			if not pending and not imageLabel then
				label.Text = text
			end
		end,
		setVariant = function(variant: Variant)
			variantName = variant
			style = STYLES[variant] or STYLES.primary
			button.BackgroundColor3 = style.lip
			face.BackgroundColor3 = style.face
			label.TextColor3 = style.text
			label.Font = style.font
			gradient.Color = Depth.sheen(style.face, style.faceLight)
			rim.Color = Depth.shade(style.face, 0.45)
			rim.Transparency = if style.ghost then 1 else Tokens.depth.rimTransparency
			face.Size = UDim2.new(1, 0, 1, if style.ghost then 0 else -LIP)
			if textOutline then
				textOutline.Enabled = style.outlined
			elseif style.outlined then
				textOutline = FrameKit.outline(label, 1.8)
			end
			applyState()
		end,
		punch = function()
			Tween.rotationPunch(button, motion, 0)
		end,
		pulse = function(on: boolean)
			if on and not stopPulse then
				stopPulse = Tween.pulseLoop(scale, motion)
				if shine and not motion.reducedMotion then
					shine.Visible = true
					local sweeping = true
					local function sweep()
						if not sweeping or not shine.Parent then
							return
						end
						shine.Position = UDim2.fromScale(-0.7, 0.5)
						local tween = TweenService:Create(shine, TweenInfo.new(0.9, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {
							Position = UDim2.fromScale(1.1, 0.5),
						})
						tween:Play()
						tween.Completed:Once(function()
							if sweeping then
								task.delay(1.8, sweep)
							end
						end)
					end
					sweep()
					local stopScale = stopPulse
					stopPulse = function()
						sweeping = false
						shine.Visible = false
						stopScale()
					end
				end
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
	-- Callers that poke button.Text / TextSize keep working through the label.
	local proxyConnections = {
		button:GetPropertyChangedSignal("Text"):Connect(function()
			if button.Text ~= "" then
				label.Text = button.Text
				baseText = button.Text
				button.Text = ""
			end
		end),
	}
	for _, c in ipairs(proxyConnections) do
		table.insert(connections, c)
	end
	return handle
end

return Button
