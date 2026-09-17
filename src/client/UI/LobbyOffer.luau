--!strict
-- The permanent 2x Gems offer on the left of the lobby.
--
-- The owner's artwork is the whole button: no frame drawn around it, no label written over it, and
-- the hit area is the image itself. Everything else here is motion - a slow float, a glint that
-- travels across the art, a soft glow behind it, a lift on hover and a press - kept deliberately
-- small so it reads as alive rather than busy. No particles and no lights, so nothing it does can
-- touch the world behind it.
--
-- It decides nothing about ownership or price. The caller tells it whether the pass is owned, and a
-- click is a request that the server validates.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local Motion = require(Shared.Design.Motion)
local AssetManifest = require(Shared.Design.AssetManifest)

local LobbyOffer = {}

export type Offer = {
	frame: Frame,
	button: ImageButton,
	setOwned: (owned: boolean) -> (),
	setVisible: (visible: boolean) -> (),
	destroy: () -> (),
}

export type Options = {
	config: { [string]: any },
	motion: () -> Motion.MotionSettings,
	onActivated: () -> (),
}

local ROLE = "offer.gems2x"

function LobbyOffer.create(parent: Instance, options: Options): Offer?
	local image = AssetManifest.image(ROLE)
	if not image then
		-- No artwork, no offer: better absent than an empty box in the corner.
		warn("[SFE][Lobby] 2x Gems artwork missing (" .. ROLE .. "); offer not shown")
		return nil
	end
	local offer = options.config.lobby.offer

	local frame = Instance.new("Frame")
	frame.Name = "LobbyOffer"
	frame.AnchorPoint = Vector2.new(0, 0.5)
	frame.Position = UDim2.new(0, Tokens.layout.safeAreaPaddingPx, 0.5, 0)
	frame.Size = UDim2.fromOffset(offer.widthPx, offer.widthPx)
	frame.BackgroundTransparency = 1
	frame.ZIndex = Tokens.zIndex.hud
	frame.Parent = parent

	local scale = Instance.new("UIScale")
	scale.Parent = frame

	-- Glow: the same art blurred outward by drawing it larger and very faint behind the button.
	local glow = Instance.new("ImageLabel")
	glow.Name = "Glow"
	glow.AnchorPoint = Vector2.new(0.5, 0.5)
	glow.Position = UDim2.fromScale(0.5, 0.5)
	glow.Size = UDim2.fromScale(1.16, 1.16)
	glow.BackgroundTransparency = 1
	glow.Image = image
	glow.ImageColor3 = Tokens.color.goldLight
	glow.ImageTransparency = offer.glowTransparency
	glow.ZIndex = frame.ZIndex
	glow.Parent = frame

	local button = Instance.new("ImageButton")
	button.Name = "OfferButton"
	button.Size = UDim2.fromScale(1, 1)
	button.BackgroundTransparency = 1
	button.Image = image
	button.AutoButtonColor = false
	button.ZIndex = frame.ZIndex + 1
	button.Parent = frame

	-- The glint travels inside the button's own bounds, so it never streaks across the lobby.
	local shineHost = Instance.new("Frame")
	shineHost.Name = "Shine"
	shineHost.Size = UDim2.fromScale(1, 1)
	shineHost.BackgroundTransparency = 1
	shineHost.ClipsDescendants = true
	shineHost.ZIndex = frame.ZIndex + 2
	shineHost.Parent = frame
	local glint = Instance.new("Frame")
	glint.Name = "Glint"
	glint.AnchorPoint = Vector2.new(0.5, 0.5)
	glint.Position = UDim2.fromScale(-0.4, 0.5)
	glint.Size = UDim2.fromScale(0.18, 1.8)
	glint.Rotation = 18
	glint.BackgroundColor3 = Color3.new(1, 1, 1)
	glint.BorderSizePixel = 0
	glint.ZIndex = shineHost.ZIndex
	glint.Parent = shineHost
	local glintFade = Instance.new("UIGradient")
	glintFade.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.5, offer.shineTransparency),
		NumberSequenceKeypoint.new(1, 1),
	})
	glintFade.Rotation = 90
	glintFade.Parent = glint

	local ownedTag = Instance.new("TextLabel")
	ownedTag.Name = "Owned"
	ownedTag.AnchorPoint = Vector2.new(0.5, 1)
	ownedTag.Position = UDim2.fromScale(0.5, 0.98)
	ownedTag.Size = UDim2.new(0.86, 0, 0, Tokens.typography.label.size + Tokens.spacing.sm)
	ownedTag.BackgroundColor3 = Tokens.color.success
	ownedTag.BorderSizePixel = 0
	ownedTag.Font = Tokens.typography.label.font
	ownedTag.TextSize = Tokens.typography.label.size
	ownedTag.TextColor3 = Tokens.color.featherWhite
	ownedTag.Text = "OWNED"
	ownedTag.Visible = false
	ownedTag.ZIndex = frame.ZIndex + 3
	ownedTag.Parent = frame
	local ownedCorner = Instance.new("UICorner")
	ownedCorner.CornerRadius = UDim.new(0, Tokens.radius.pill)
	ownedCorner.Parent = ownedTag
	local ownedStroke = Instance.new("UIStroke")
	ownedStroke.Thickness = Tokens.depth.keyline
	ownedStroke.Color = Tokens.color.outline
	ownedStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	ownedStroke.Parent = ownedTag
	local ownedText = Instance.new("UIStroke")
	ownedText.Name = "TextOutline"
	ownedText.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	ownedText.Thickness = 2
	ownedText.Color = Tokens.color.outline
	ownedText.LineJoinMode = Enum.LineJoinMode.Round
	ownedText.Parent = ownedTag

	local alive, owned, hovered = true, false, false
	local connections: { RBXScriptConnection } = {}
	local threads: { thread } = {}

	local function settings(): Motion.MotionSettings
		return options.motion()
	end

	-- Idle float and glint run as loops rather than a render step: two tweens cost nothing and stop
	-- cleanly. Reduced motion turns both off rather than merely shortening them, because a permanent
	-- ambient animation is exactly what that setting is for.
	local function startMotion()
		local motion = settings()
		if motion.reducedMotion then
			return
		end
		table.insert(
			threads,
			task.spawn(function()
				while alive do
					local up = TweenService:Create(
						frame,
						TweenInfo.new(offer.floatSeconds, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
						{ Position = UDim2.new(0, Tokens.layout.safeAreaPaddingPx, 0.5, -offer.floatPx) }
					)
					up:Play()
					task.wait(offer.floatSeconds)
					if not alive then
						return
					end
					local down = TweenService:Create(
						frame,
						TweenInfo.new(offer.floatSeconds, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
						{ Position = UDim2.new(0, Tokens.layout.safeAreaPaddingPx, 0.5, offer.floatPx) }
					)
					down:Play()
					task.wait(offer.floatSeconds)
				end
			end)
		)
		table.insert(
			threads,
			task.spawn(function()
				while alive do
					glint.Position = UDim2.fromScale(-0.4, 0.5)
					TweenService:Create(glint, TweenInfo.new(offer.shineSeconds, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {
						Position = UDim2.fromScale(1.4, 0.5),
					}):Play()
					task.wait(offer.shineSeconds + offer.shineGapSeconds)
				end
			end)
		)
	end

	local function applyScale(target: number)
		local motion = settings()
		local seconds = Motion.clampSeconds(0.14, motion)
		if seconds <= 0.01 then
			scale.Scale = target
			return
		end
		TweenService:Create(scale, TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Scale = target }):Play()
	end

	table.insert(
		connections,
		button.MouseEnter:Connect(function()
			hovered = true
			if not owned then
				applyScale(offer.hoverScale)
			end
		end)
	)
	table.insert(
		connections,
		button.MouseLeave:Connect(function()
			hovered = false
			applyScale(1)
		end)
	)
	table.insert(
		connections,
		button.MouseButton1Down:Connect(function()
			if not owned then
				applyScale(offer.pressScale)
			end
		end)
	)
	table.insert(
		connections,
		button.MouseButton1Up:Connect(function()
			applyScale(if hovered and not owned then offer.hoverScale else 1)
		end)
	)
	table.insert(
		connections,
		button.Activated:Connect(function()
			if owned or not alive then
				return -- an owner is never prompted again
			end
			options.onActivated()
		end)
	)

	startMotion()

	local handle: Offer
	handle = {
		frame = frame,
		button = button,
		setOwned = function(isOwned: boolean)
			owned = isOwned
			ownedTag.Visible = isOwned
			button.ImageTransparency = if isOwned then 0.25 else 0
			glow.ImageTransparency = if isOwned then 1 else offer.glowTransparency
			shineHost.Visible = not isOwned
			if isOwned then
				applyScale(1)
			end
		end,
		setVisible = function(visible: boolean)
			frame.Visible = visible
		end,
		destroy = function()
			if not alive then
				return
			end
			alive = false
			for _, connection in ipairs(connections) do
				connection:Disconnect()
			end
			for _, thread in ipairs(threads) do
				pcall(task.cancel, thread)
			end
			frame:Destroy()
		end,
	}
	return handle
end

return LobbyOffer
