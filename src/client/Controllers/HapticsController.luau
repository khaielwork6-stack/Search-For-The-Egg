--!strict
-- Haptic feedback wrapper. Respects the haptics setting and degrades silently on devices without
-- vibration support.

local HapticService = game:GetService("HapticService")

local HapticsController = {}
HapticsController.__index = HapticsController

export type HapticsController = typeof(setmetatable({} :: { _accessibility: any, pulses: number }, HapticsController))

function HapticsController.new(accessibility: any): HapticsController
	return setmetatable({ _accessibility = accessibility, pulses = 0 }, HapticsController)
end

-- Short pulse; strength 0..1. Uses the small motor for subtle cues.
function HapticsController.pulse(self: HapticsController, strength: number, seconds: number?)
	if not self._accessibility:haptics() then
		return
	end
	self.pulses += 1
	local ok = pcall(function()
		local input = Enum.UserInputType.Gamepad1
		if HapticService:IsVibrationSupported(input) and HapticService:IsMotorSupported(input, Enum.VibrationMotor.Small) then
			HapticService:SetMotor(input, Enum.VibrationMotor.Small, math.clamp(strength, 0, 1))
			task.delay(seconds or 0.08, function()
				HapticService:SetMotor(input, Enum.VibrationMotor.Small, 0)
			end)
		end
	end)
	if not ok then
		return
	end
end

function HapticsController.destroy(_self: HapticsController)
	pcall(function()
		HapticService:SetMotor(Enum.UserInputType.Gamepad1, Enum.VibrationMotor.Small, 0)
	end)
end

return HapticsController
