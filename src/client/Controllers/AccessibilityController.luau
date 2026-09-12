--!strict
-- Reduced motion, camera shake, and haptics preferences derived from the server settings
-- projection. Exposes a MotionSettings object for the shared Motion module.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local Signal = require(Shared.Util.Signal)
local Trove = require(Shared.Util.Trove)
local Motion = require(Shared.Design.Motion)

local AccessibilityController = {}
AccessibilityController.__index = AccessibilityController

export type AccessibilityController = typeof(setmetatable(
	{} :: {
		_settings: { reducedMotion: boolean, cameraShake: boolean, haptics: boolean },
		_config: { [string]: any },
		changed: any,
		_trove: Trove.Trove,
	},
	AccessibilityController
))

function AccessibilityController.new(profile: any, config: { [string]: any }): AccessibilityController
	local self = setmetatable({
		_settings = { reducedMotion = false, cameraShake = true, haptics = true },
		_config = config,
		changed = Signal.new(),
		_trove = Trove.new(),
	}, AccessibilityController)
	local function pull(projection)
		if projection and projection.settings then
			self._settings = {
				reducedMotion = projection.settings.reducedMotion == true,
				cameraShake = projection.settings.cameraShake ~= false,
				haptics = projection.settings.haptics ~= false,
			}
			self.changed:Fire(self._settings)
		end
	end
	pull(profile.projection)
	self._trove:add(profile.changed:Connect(pull))
	return self
end

function AccessibilityController.reducedMotion(self: AccessibilityController): boolean
	return self._settings.reducedMotion
end

function AccessibilityController.cameraShake(self: AccessibilityController): boolean
	return self._settings.cameraShake
end

function AccessibilityController.haptics(self: AccessibilityController): boolean
	return self._settings.haptics
end

function AccessibilityController.motionSettings(self: AccessibilityController): Motion.MotionSettings
	return {
		reducedMotion = self._settings.reducedMotion,
		maximumUiTweenSeconds = self._config.polishBudgets.maximumUiTweenSeconds,
		reducedMotionScale = self._config.polishBudgets.reducedMotionScale,
	}
end

function AccessibilityController.motionScale(self: AccessibilityController): number
	return if self._settings.reducedMotion then self._config.polishBudgets.reducedMotionScale else 1
end

function AccessibilityController.destroy(self: AccessibilityController)
	self._trove:destroy()
	self.changed:Destroy()
end

return AccessibilityController
