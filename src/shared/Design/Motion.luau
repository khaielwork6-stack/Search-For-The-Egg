--!strict
-- Motion semantics: resolves a token duration against the configured UI tween cap and the
-- player's reduced-motion setting. Pure; the client tween helper consumes the result.

local Tokens = require(script.Parent.Tokens)

local Motion = {}

export type MotionSettings = { reducedMotion: boolean, maximumUiTweenSeconds: number, reducedMotionScale: number }

-- Returns the effective duration for a motion token name ("quick", "standard", ...).
function Motion.duration(tokenName: string, settings: MotionSettings): number
	local base = (Tokens.motion :: any)[tokenName]
	assert(type(base) == "number", "unknown motion token " .. tostring(tokenName))
	local duration = math.min(base, settings.maximumUiTweenSeconds)
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

return Motion
