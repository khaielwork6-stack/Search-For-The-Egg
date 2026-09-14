--!strict
-- Small tween helpers that turn the shared motion recipes into TweenService calls. Every UI motion
-- goes through here so the tween cap and reduced-motion scale apply uniformly. Also hosts the
-- rebuilt-UI motions: count-up, pulse loops (attention only when useful), shakes, sheen sweeps,
-- floating deltas, and slide-ins.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Shared = ReplicatedStorage.Shared
local Motion = require(Shared.Design.Motion)
local Tokens = require(Shared.Design.Tokens)

local Tween = {}

-- Plays a recipe tween on `instance` toward `goal`. Returns the Tween.
function Tween.recipe(
	instance: Instance,
	recipeName: string,
	settings: Motion.MotionSettings,
	goal: { [string]: any },
	delayTime: number?
): Tween
	local resolved = Motion.recipe(recipeName, settings)
	local tween = TweenService:Create(instance, Motion.tweenInfo(resolved, delayTime), goal)
	tween:Play()
	return tween
end

-- Scale recipe on a UIScale (hover / press / release / pop).
function Tween.scale(uiScale: UIScale, recipeName: string, settings: Motion.MotionSettings, override: number?): Tween
	local resolved = Motion.recipe(recipeName, settings)
	local target = override or resolved.scale or 1
	local tween = TweenService:Create(uiScale, Motion.tweenInfo(resolved), { Scale = target })
	tween:Play()
	return tween
end

-- Rotation punch: quick kick then elastic settle back to `restDegrees`.
function Tween.rotationPunch(object: GuiObject, settings: Motion.MotionSettings, restDegrees: number?)
	local kick = Motion.recipe("rotationKick", settings)
	local rest = restDegrees or 0
	local kickTween = TweenService:Create(object, Motion.tweenInfo(kick), { Rotation = rest + (kick.degrees or 0) })
	kickTween:Play()
	kickTween.Completed:Once(function()
		local settle = Motion.recipe("rotationSettle", settings)
		TweenService:Create(object, Motion.tweenInfo(settle), { Rotation = rest }):Play()
	end)
end

-- Error shake: a short side-to-side rotation that settles (never loops).
function Tween.shake(object: GuiObject, settings: Motion.MotionSettings)
	local recipe = Motion.recipe("shake", settings)
	object.Rotation = recipe.degrees or 3
	TweenService:Create(object, Motion.tweenInfo(recipe), { Rotation = 0 }):Play()
end

-- Click ripple: a pill that grows from the click point and fades. Self-cleaning.
function Tween.ripple(parent: GuiObject, settings: Motion.MotionSettings, color: Color3, atScale: Vector2?)
	local ripple = Instance.new("Frame")
	ripple.Name = "Ripple"
	ripple.AnchorPoint = Vector2.new(0.5, 0.5)
	local origin = atScale or Vector2.new(0.5, 0.5)
	ripple.Position = UDim2.fromScale(origin.X, origin.Y)
	ripple.Size = UDim2.fromScale(0.2, 0.6)
	ripple.SizeConstraint = Enum.SizeConstraint.RelativeYY
	ripple.BackgroundColor3 = color
	ripple.BackgroundTransparency = 0.55
	ripple.BorderSizePixel = 0
	ripple.ZIndex = parent.ZIndex + 3
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = ripple
	ripple.Parent = parent
	local resolved = Motion.recipe("ripple", settings)
	local grow = TweenService:Create(
		ripple,
		Motion.tweenInfo(resolved),
		{ Size = UDim2.fromScale(0.6 * (resolved.scale or 2.4), 1.8 * (resolved.scale or 2.4)), BackgroundTransparency = 1 }
	)
	grow:Play()
	grow.Completed:Once(function()
		ripple:Destroy()
	end)
end

-- Notification entrance: grow (Back-out) then pop (Elastic). Returns a shrink function for exit.
function Tween.notify(card: GuiObject, scale: UIScale, settings: Motion.MotionSettings): () -> ()
	local grow = Motion.recipe("notifyGrow", settings)
	scale.Scale = grow.fromScale or 0.6
	card.Visible = true
	local growTween = TweenService:Create(scale, Motion.tweenInfo(grow), { Scale = 1 })
	growTween:Play()
	growTween.Completed:Once(function()
		local pop = Motion.recipe("notifyPop", settings)
		scale.Scale = pop.scale or 1.06
		TweenService:Create(scale, Motion.tweenInfo(pop), { Scale = 1 }):Play()
	end)
	return function()
		local shrink = Motion.recipe("notifyShrink", settings)
		local shrinkTween = TweenService:Create(scale, Motion.tweenInfo(shrink), { Scale = shrink.toScale or 0.7 })
		shrinkTween:Play()
		shrinkTween.Completed:Once(function()
			card:Destroy()
		end)
	end
end

-- Count-up: calls `apply` with an eased integer from `from` to `to` over the countUp recipe.
function Tween.countUp(from: number, to: number, settings: Motion.MotionSettings, apply: (value: number) -> ()): thread
	local recipe = Motion.recipe("countUp", settings)
	local duration = math.max(0.01, recipe.duration)
	local started = os.clock()
	return task.spawn(function()
		while true do
			local t = math.clamp((os.clock() - started) / duration, 0, 1)
			local eased = 1 - (1 - t) * (1 - t)
			apply(math.floor(from + (to - from) * eased + 0.5))
			if t >= 1 then
				break
			end
			task.wait()
		end
	end)
end

-- Attention pulse loop on a UIScale (gentle breathe). Returns a stop function that settles to 1.
-- Use only while something needs the player (a claimable reward, a full bag), never constantly.
function Tween.pulseLoop(scale: UIScale, settings: Motion.MotionSettings, amount: number?): () -> ()
	local recipe = Motion.recipe("pulse", settings)
	local amplitude = Motion.amplitude(amount or ((recipe.scale or 1.05) - 1), settings)
	local info = TweenInfo.new(recipe.duration, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
	local tween = TweenService:Create(scale, info, { Scale = 1 + amplitude })
	if amplitude > 0 then
		tween:Play()
	end
	return function()
		tween:Cancel()
		TweenService:Create(scale, TweenInfo.new(Motion.duration("quick", settings), Tokens.motion.easeOut), { Scale = 1 }):Play()
	end
end

-- Sheen: sweeps a UIGradient's offset across a surface once (ambient sparkle on gold frames).
function Tween.sheen(gradient: UIGradient, settings: Motion.MotionSettings, onDone: (() -> ())?)
	local recipe = Motion.recipe("sheen", settings)
	gradient.Offset = Vector2.new(-1, 0)
	local tween = TweenService:Create(gradient, Motion.tweenInfo(recipe), { Offset = Vector2.new(1, 0) })
	tween:Play()
	if onDone then
		tween.Completed:Once(onDone)
	end
end

-- Floating delta label ("+$1.20", "+3"): rises and fades from `anchor`, then destroys itself.
function Tween.floatText(parent: GuiObject, text: string, color: Color3, settings: Motion.MotionSettings, zIndex: number?)
	local label = Instance.new("TextLabel")
	label.Name = "Float"
	label.AnchorPoint = Vector2.new(0.5, 1)
	label.Position = UDim2.fromScale(0.5, 0)
	label.Size = UDim2.new(1, 0, 0, Tokens.typography.numeral.size + Tokens.spacing.xs)
	label.BackgroundTransparency = 1
	label.Font = Tokens.typography.label.font
	label.TextSize = Tokens.typography.numeral.size
	label.TextColor3 = color
	label.TextStrokeColor3 = Tokens.color.outline
	label.TextStrokeTransparency = 0.4
	label.Text = text
	label.ZIndex = (zIndex or parent.ZIndex) + 3
	label.Parent = parent
	local duration = Motion.clampSeconds(0.9, settings)
	local rise = Motion.amplitude(28, settings)
	local tween = TweenService:Create(
		label,
		TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Position = UDim2.new(0.5, 0, 0, -rise), TextTransparency = 1, TextStrokeTransparency = 1 }
	)
	tween:Play()
	tween.Completed:Once(function()
		label:Destroy()
	end)
end

-- Slide-in from an offset (toast / banner entrances), Back-out.
function Tween.slideIn(object: GuiObject, settings: Motion.MotionSettings, fromOffset: Vector2, restPosition: UDim2)
	local recipe = Motion.recipe("toastSlide", settings)
	local dx = Motion.amplitude(fromOffset.X, settings)
	local dy = Motion.amplitude(fromOffset.Y, settings)
	object.Position = restPosition + UDim2.fromOffset(dx, dy)
	TweenService:Create(object, Motion.tweenInfo(recipe), { Position = restPosition }):Play()
end

-- Fade helper for any GuiObject: background + text + stroke transparencies together.
function Tween.fade(object: GuiObject, settings: Motion.MotionSettings, toTransparency: number, token: string?): Tween
	local info = TweenInfo.new(Motion.duration(token or "quick", settings), Tokens.motion.easeOut)
	local goal: { [string]: any } = { BackgroundTransparency = toTransparency }
	if object:IsA("TextLabel") or object:IsA("TextButton") then
		goal.TextTransparency = toTransparency
	end
	if object:IsA("ImageLabel") or object:IsA("ImageButton") then
		goal.ImageTransparency = toTransparency
	end
	local tween = TweenService:Create(object, info, goal)
	tween:Play()
	return tween
end

return Tween
