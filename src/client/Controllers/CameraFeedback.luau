--!strict
-- Camera feedback with reduced-motion and camera-shake settings applied. Two effects share one
-- RenderStepped binding that exists only while something is moving:
--   * `impulse` - the old energy shake (rake sweeps, blasts): random jitter that bleeds off;
--   * `nudge`   - the pickup kick: a microscopic dip, pitch and FOV pulse that rises and returns
--                 exactly to neutral over `returnSeconds`. Repeated nudges accumulate to a clamp,
--                 never past it, so twenty fast clicks feel like a rhythm and not a tremor.
-- Every offset is applied after the camera script has written its frame and removed before the
-- next one, so nothing here ever changes where the camera *is*.

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local Trove = require(Shared.Util.Trove)

local CameraFeedback = {}
CameraFeedback.__index = CameraFeedback

export type Nudge = { studs: number, degrees: number, fov: number, returnSeconds: number }

export type CameraFeedback = typeof(setmetatable(
	{} :: {
		_accessibility: any,
		_config: { [string]: any },
		_energy: number,
		_bound: boolean,
		_trove: Trove.Trove,
		_kick: number,
		_phase: number,
		_nudge: Nudge?,
		_appliedFov: number,
		stats: { impulses: number, nudges: number },
	},
	CameraFeedback
))

local BIND_NAME = "SFE_CameraFeedback"
local KICK_CLAMP = 1.6

function CameraFeedback.new(accessibility: any, config: { [string]: any }): CameraFeedback
	return setmetatable({
		_accessibility = accessibility,
		_config = config,
		_energy = 0,
		_bound = false,
		_trove = Trove.new(),
		_kick = 0,
		_phase = 0,
		_nudge = nil,
		_appliedFov = 0,
		stats = { impulses = 0, nudges = 0 },
	}, CameraFeedback)
end

function CameraFeedback._bind(self: CameraFeedback)
	if not self._bound then
		self._bound = true
		RunService:BindToRenderStep(BIND_NAME, Enum.RenderPriority.Camera.Value + 1, function(dt)
			self:_step(dt)
		end)
	end
end

-- Adds an impulse (0..1). Ignored when camera shake is off; scaled for reduced motion.
function CameraFeedback.impulse(self: CameraFeedback, strength: number)
	if not self._accessibility:cameraShake() then
		return
	end
	self.stats.impulses += 1
	self._energy = math.clamp(self._energy + strength * self._accessibility:motionScale(), 0, 1)
	self:_bind()
end

-- The pickup kick. `spec` is the configured amplitude set; the kick is scaled by the motion scale
-- and clamped so overlapping picks never pile up past KICK_CLAMP times one kick.
function CameraFeedback.nudge(self: CameraFeedback, spec: Nudge)
	if not self._accessibility:cameraShake() then
		return
	end
	local scale = self._accessibility:motionScale()
	if scale <= 0 then
		return
	end
	self.stats.nudges += 1
	self._nudge = { studs = spec.studs * scale, degrees = spec.degrees * scale, fov = spec.fov * scale, returnSeconds = spec.returnSeconds }
	-- A kick landing mid-return restarts the pulse with whatever is left of the last one added in.
	local remaining = if self._phase < spec.returnSeconds then self._kick * (1 - self._phase / spec.returnSeconds) else 0
	self._kick = math.min(KICK_CLAMP, 1 + remaining * 0.5)
	self._phase = 0
	self:_bind()
end

function CameraFeedback._step(self: CameraFeedback, dt: number)
	local camera = workspace.CurrentCamera
	if not camera then
		self._energy = 0
		self._kick = 0
		self:_unbind()
		return
	end
	-- Remove last frame's FOV delta before deciding this frame's.
	if self._appliedFov ~= 0 then
		camera.FieldOfView -= self._appliedFov
		self._appliedFov = 0
	end
	local active = false
	if self._energy > 0.001 then
		local amplitude = self._energy * 0.35
		local offset = CFrame.Angles((math.random() * 2 - 1) * amplitude * 0.02, (math.random() * 2 - 1) * amplitude * 0.02, 0)
		camera.CFrame = camera.CFrame * offset
		self._energy = math.max(0, self._energy - dt * 3)
		active = true
	else
		self._energy = 0
	end
	local nudge = self._nudge
	if nudge and self._kick > 0 then
		self._phase += dt
		local t = self._phase / math.max(0.016, nudge.returnSeconds)
		if t < 1 then
			-- One half sine: out and back, zero at both ends, so the camera is never left offset.
			local wave = math.sin(t * math.pi) * self._kick
			camera.CFrame = camera.CFrame * CFrame.new(0, -nudge.studs * wave, 0) * CFrame.Angles(-math.rad(nudge.degrees) * wave, 0, 0)
			local fovDelta = nudge.fov * wave
			camera.FieldOfView += fovDelta
			self._appliedFov = fovDelta
			active = true
		else
			self._kick = 0
			self._phase = 0
			self._nudge = nil
		end
	end
	if not active then
		self:_unbind()
	end
end

function CameraFeedback._unbind(self: CameraFeedback)
	if self._bound then
		self._bound = false
		RunService:UnbindFromRenderStep(BIND_NAME)
	end
	local camera = workspace.CurrentCamera
	if camera and self._appliedFov ~= 0 then
		camera.FieldOfView -= self._appliedFov
	end
	self._appliedFov = 0
	self._kick = 0
	self._phase = 0
	self._nudge = nil
end

function CameraFeedback.isActive(self: CameraFeedback): boolean
	return self._bound
end

-- Studio check: true when no offset of any kind is being applied.
function CameraFeedback.isNeutral(self: CameraFeedback): boolean
	return not self._bound and self._appliedFov == 0 and self._kick == 0 and self._energy == 0
end

function CameraFeedback.destroy(self: CameraFeedback)
	self:_unbind()
	self._trove:destroy()
end

return CameraFeedback
