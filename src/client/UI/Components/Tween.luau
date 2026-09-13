--!strict
-- Small tween helpers that turn the shared motion recipes into TweenService calls. Every UI motion
-- goes through here so the tween cap and reduced-motion scale apply uniformly.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Shared = ReplicatedStorage.Shared
local Motion = require(Shared.Design.Motion)

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

-- Notification envelope: grow in (Back), pop (Elastic), and later shrink out (Quad in). Returns a
-- function that plays the shrink and destroys the object.
function Tween.notify(object: GuiObject, uiScale: UIScale, settings: Motion.MotionSettings): () -> ()
	local grow = Motion.recipe("notifyGrow", settings)
	uiScale.Scale = grow.fromScale or 0.6
	object.Visible = true
	local growTween = TweenService:Create(uiScale, Motion.tweenInfo(grow), { Scale = 1 })
	growTween:Play()
	growTween.Completed:Once(function()
		local pop = Motion.recipe("notifyPop", settings)
		uiScale.Scale = pop.scale or 1.06
		TweenService:Create(uiScale, Motion.tweenInfo(pop), { Scale = 1 }):Play()
	end)
	return function()
		local shrink = Motion.recipe("notifyShrink", settings)
		local out = TweenService:Create(uiScale, Motion.tweenInfo(shrink), { Scale = shrink.toScale or 0.7 })
		out:Play()
		out.Completed:Once(function()
			object:Destroy()
		end)
	end
end

-- Count-up for numeric labels; `format(value)` renders each frame. Returns a cancel function.
function Tween.countUp(
	from: number,
	to: number,
	settings: Motion.MotionSettings,
	format: (value: number) -> (),
	onTick: (() -> ())?
): () -> ()
	local resolved = Motion.recipe("countUp", settings)
	local duration = math.max(0.01, resolved.duration)
	local started = os.clock()
	local thread = task.spawn(function()
		local ticks = 0
		while true do
			local t = math.clamp((os.clock() - started) / duration, 0, 1)
			local eased = 1 - (1 - t) * (1 - t)
			format(math.floor(from + (to - from) * eased + 0.5))
			if onTick and ticks % 3 == 0 and ticks < 12 then
				onTick()
			end
			ticks += 1
			if t >= 1 then
				break
			end
			task.wait()
		end
	end)
	return function()
		if coroutine.status(thread) ~= "dead" then
			task.cancel(thread)
		end
		format(to)
	end
end

return Tween
