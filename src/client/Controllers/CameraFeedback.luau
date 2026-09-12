--!strict
-- Camera impulse/shake interface with reduced-motion and camera-shake settings applied. Uses a
-- single RenderStepped binding while an impulse is active and unbinds when settled.

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local Trove = require(Shared.Util.Trove)

local CameraFeedback = {}
CameraFeedback.__index = CameraFeedback

export type CameraFeedback = typeof(setmetatable(
	{} :: { _accessibility: any, _config: { [string]: any }, _energy: number, _bound: boolean, _trove: Trove.Trove },
	CameraFeedback
))

local BIND_NAME = "SFE_CameraFeedback"

function CameraFeedback.new(accessibility: any, config: { [string]: any }): CameraFeedback
	return setmetatable(
		{ _accessibility = accessibility, _config = config, _energy = 0, _bound = false, _trove = Trove.new() },
		CameraFeedback
	)
end

-- Adds an impulse (0..1). Ignored when camera shake is off; scaled for reduced motion.
function CameraFeedback.impulse(self: CameraFeedback, strength: number)
	if not self._accessibility:cameraShake() then
		return
	end
	self._energy = math.clamp(self._energy + strength * self._accessibility:motionScale(), 0, 1)
	if not self._bound then
		self._bound = true
		RunService:BindToRenderStep(BIND_NAME, Enum.RenderPriority.Camera.Value + 1, function(dt)
			self:_step(dt)
		end)
	end
end

function CameraFeedback._step(self: CameraFeedback, dt: number)
	local camera = workspace.CurrentCamera
	if camera and self._energy > 0.001 then
		local amplitude = self._energy * 0.35
		local offset = CFrame.Angles((math.random() * 2 - 1) * amplitude * 0.02, (math.random() * 2 - 1) * amplitude * 0.02, 0)
		camera.CFrame = camera.CFrame * offset
		self._energy = math.max(0, self._energy - dt * 3)
	else
		self._energy = 0
		self:_unbind()
	end
end

function CameraFeedback._unbind(self: CameraFeedback)
	if self._bound then
		self._bound = false
		RunService:UnbindFromRenderStep(BIND_NAME)
	end
end

function CameraFeedback.isActive(self: CameraFeedback): boolean
	return self._bound
end

function CameraFeedback.destroy(self: CameraFeedback)
	self:_unbind()
	self._trove:destroy()
end

return CameraFeedback
