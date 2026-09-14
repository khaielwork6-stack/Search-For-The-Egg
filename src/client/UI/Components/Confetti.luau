--!strict
-- 2D confetti burst for reward reveals, sales, roll landings and victory: small rotated pieces in
-- the palette tumble out from an origin and fade. Count scales with the quality tier and drops to a
-- gentle handful under reduced motion; every piece cleans itself up. Never loops.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local Motion = require(Shared.Design.Motion)

local Confetti = {}

local PALETTE = {
	Tokens.color.gold,
	Tokens.color.goldLight,
	Tokens.color.featherWhite,
	Tokens.color.tealLight,
	Tokens.color.leafBright,
	Tokens.color.ember,
	Tokens.color.cream,
}

export type Options = {
	origin: UDim2?, -- in the parent's space; default centre
	count: number?,
	spread: number?, -- px
	motion: Motion.MotionSettings,
	tier: string?, -- "low" trims the count
	zIndex: number?,
	seconds: number?,
}

function Confetti.burst(parent: GuiObject, options: Options)
	local motion = options.motion
	local base = options.count or 28
	if options.tier == "low" then
		base = math.floor(base * 0.4)
	elseif options.tier == "medium" then
		base = math.floor(base * 0.7)
	end
	if motion.reducedMotion then
		base = math.min(base, 8)
	end
	if base <= 0 then
		return
	end
	local layer = Instance.new("Frame")
	layer.Name = "Confetti"
	layer.Size = UDim2.fromScale(1, 1)
	layer.BackgroundTransparency = 1
	layer.ZIndex = options.zIndex or (parent.ZIndex + 5)
	layer.ClipsDescendants = false
	layer.Parent = parent
	local origin = options.origin or UDim2.fromScale(0.5, 0.5)
	local spread = Motion.amplitude(options.spread or 160, motion)
	local seconds = Motion.clampSeconds(options.seconds or 0.9, motion) * (if motion.reducedMotion then 1 else 2)
	for index = 1, base do
		local piece = Instance.new("Frame")
		piece.Name = "Piece" .. index
		local w = math.random(6, 11)
		piece.Size = UDim2.fromOffset(w, math.random(4, 8))
		piece.AnchorPoint = Vector2.new(0.5, 0.5)
		piece.Position = origin
		piece.BackgroundColor3 = PALETTE[math.random(1, #PALETTE)]
		piece.BorderSizePixel = 0
		piece.Rotation = math.random(0, 360)
		piece.ZIndex = layer.ZIndex
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 2)
		corner.Parent = piece
		piece.Parent = layer
		local angle = math.rad(math.random(200, 340)) -- upward fan
		local distance = spread * (0.4 + math.random() * 0.8)
		local dx = math.cos(angle) * distance
		local dy = math.sin(angle) * distance
		local up = TweenService:Create(
			piece,
			TweenInfo.new(seconds * 0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Position = origin + UDim2.fromOffset(dx, dy), Rotation = piece.Rotation + math.random(-240, 240) }
		)
		up:Play()
		up.Completed:Once(function()
			local fall = TweenService:Create(piece, TweenInfo.new(seconds * 0.55, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
				Position = origin + UDim2.fromOffset(dx * 1.15, dy + spread * 0.9),
				BackgroundTransparency = 1,
				Rotation = piece.Rotation + math.random(-120, 120),
			})
			fall:Play()
		end)
	end
	task.delay(seconds + 0.2, function()
		layer:Destroy()
	end)
end

return Confetti
