--!strict
-- Quality tiers and effect budgets. "auto" picks a tier from platform class (touch => mobile
-- budgets) and the user's Roblox graphics quality; explicit settings override. Budgets come from
-- polishBudgets in config.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Shared = ReplicatedStorage.Shared
local Signal = require(Shared.Util.Signal)
local Trove = require(Shared.Util.Trove)

local QualityController = {}
QualityController.__index = QualityController

export type Tier = "low" | "medium" | "high"

export type Budgets = {
	particles: number,
	strands: number,
	oneShotSounds: number,
	loopingAmbient: number,
	ambientActors: number,
	targetFps: number,
}

export type QualityController = typeof(setmetatable(
	{} :: { _mode: string, _tier: Tier, _config: { [string]: any }, changed: any, _trove: Trove.Trove },
	QualityController
))

function QualityController.platformClass(): string
	if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		return "mobile"
	end
	if UserInputService.GamepadEnabled and not UserInputService.KeyboardEnabled then
		return "console"
	end
	return "desktop"
end

local function autoTier(): Tier
	local platform = QualityController.platformClass()
	if platform == "mobile" then
		return "low"
	end
	local ok, level = pcall(function()
		return (UserSettings():GetService("UserGameSettings") :: any).SavedQualityLevel
	end)
	if ok and level and level ~= Enum.SavedQualitySetting.Automatic and level.Value <= 4 then
		return "medium"
	end
	return "high"
end

function QualityController.new(profile: any, config: { [string]: any }): QualityController
	local self =
		setmetatable({ _mode = "auto", _tier = "high", _config = config, changed = Signal.new(), _trove = Trove.new() }, QualityController)
	local function pull(projection)
		local mode = projection and projection.settings and projection.settings.qualityMode or "auto"
		self:setMode(mode)
	end
	pull(profile.projection)
	self._trove:add(profile.changed:Connect(pull))
	self:setMode(self._mode)
	return self
end

function QualityController.setMode(self: QualityController, mode: string)
	self._mode = mode
	local tier: Tier = if mode == "auto" then autoTier() else mode :: Tier
	if tier ~= self._tier then
		self._tier = tier
		self.changed:Fire(tier)
	end
end

function QualityController.tier(self: QualityController): Tier
	return self._tier
end

function QualityController.budgets(self: QualityController): Budgets
	local p = self._config.polishBudgets
	local rep = self._config.collection.pileRepresentation
	if self._tier == "low" then
		return {
			particles = p.maximumActiveParticlesMobile,
			strands = rep.clientVisualStrandPoolMobile,
			oneShotSounds = math.floor(p.maximumConcurrentOneShotSounds / 2),
			loopingAmbient = math.floor(p.maximumLoopingAmbientSounds / 2),
			ambientActors = 12,
			targetFps = p.targetFpsMobileLowTier,
		}
	elseif self._tier == "medium" then
		return {
			particles = math.floor((p.maximumActiveParticlesMobile + p.maximumActiveParticlesDesktop) / 2),
			strands = math.floor((rep.clientVisualStrandPoolMobile + rep.clientVisualStrandPoolDesktop) / 2),
			oneShotSounds = p.maximumConcurrentOneShotSounds,
			loopingAmbient = p.maximumLoopingAmbientSounds,
			ambientActors = 24,
			targetFps = p.targetFpsDesktop,
		}
	end
	return {
		particles = p.maximumActiveParticlesDesktop,
		strands = rep.clientVisualStrandPoolDesktop,
		oneShotSounds = p.maximumConcurrentOneShotSounds,
		loopingAmbient = p.maximumLoopingAmbientSounds,
		ambientActors = 40,
		targetFps = p.targetFpsDesktop,
	}
end

function QualityController.destroy(self: QualityController)
	self._trove:destroy()
	self.changed:Destroy()
end

return QualityController
