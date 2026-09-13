--!strict
-- Motion semantics: resolves a token duration against the configured UI tween cap and the
-- player's reduced-motion setting. Pure; the client tween helper consumes the result.
-- Phase 4 adds recipe resolution for the owner-supplied motion recipes (Tokens.recipes).

local Tokens = require(script.Parent.Tokens)

local Motion = {}

export type MotionSettings = { reducedMotion: boolean, maximumUiTweenSeconds: number, reducedMotionScale: number }

export type ResolvedRecipe = {
	name: string,
	duration: number,
	style: string,
	direction: string,
	scale: number?,
	fromScale: number?,
	toScale: number?,
	degrees: number?,
	size: number?,
}

-- Returns the effective duration for a motion token name ("quick", "standard", ...).
function Motion.duration(tokenName: string, settings: MotionSettings): number
	local base = (Tokens.motion :: any)[tokenName]
	assert(type(base) == "number", "unknown motion token " .. tostring(tokenName))
	return Motion.clampSeconds(base, settings)
end

-- Applies the tween cap and reduced-motion scale to a raw duration.
function Motion.clampSeconds(seconds: number, settings: MotionSettings): number
	local duration = math.min(seconds, settings.maximumUiTweenSeconds)
	if settings.reducedMotion then
		duration *= settings.reducedMotionScale
	end
	return duration
end

-- Scales a displacement/scale amplitude for reduced motion (never removes information, only motion).
function Motion.amplitude(value: number, settings: MotionSettings): number
	if settings.reducedMotion then
		return value * settings.reducedMotionScale
	end
	return value
end

-- Builds a TweenInfo-compatible description (style/direction names) so tests can assert on it
-- without Roblox datatypes.
function Motion.describe(
	tokenName: string,
	settings: MotionSettings,
	easing: string?
): { duration: number, easing: string, direction: string }
	return {
		duration = Motion.duration(tokenName, settings),
		easing = easing or "easeOut",
		direction = "Out",
	}
end

-- Resolves a named recipe (Tokens.recipes) against the settings. Amplitudes (scale deltas, degrees,
-- blur size) shrink under reduced motion; durations obey the configured cap.
function Motion.recipe(name: string, settings: MotionSettings): ResolvedRecipe
	local recipe = (Tokens.recipes :: any)[name]
	assert(type(recipe) == "table", "unknown motion recipe " .. tostring(name))
	local out: ResolvedRecipe = {
		name = name,
		duration = Motion.clampSeconds(recipe.seconds, settings),
		style = recipe.style,
		direction = recipe.direction,
	}
	if recipe.scale then
		out.scale = 1 + Motion.amplitude(recipe.scale - 1, settings)
	end
	if recipe.fromScale then
		out.fromScale = 1 - Motion.amplitude(1 - recipe.fromScale, settings)
	end
	if recipe.toScale then
		out.toScale = 1 - Motion.amplitude(1 - recipe.toScale, settings)
	end
	if recipe.degrees then
		out.degrees = Motion.amplitude(recipe.degrees, settings)
	end
	if recipe.size then
		out.size = Motion.amplitude(recipe.size, settings)
	end
	return out
end

-- TweenInfo for a resolved recipe (Roblox datatype; call from client code only).
function Motion.tweenInfo(resolved: ResolvedRecipe, delayTime: number?): TweenInfo
	local style = (Enum.EasingStyle :: any)[resolved.style] or Enum.EasingStyle.Quad
	local direction = (Enum.EasingDirection :: any)[resolved.direction] or Enum.EasingDirection.Out
	return TweenInfo.new(resolved.duration, style, direction, 0, false, delayTime or 0)
end

return Motion
