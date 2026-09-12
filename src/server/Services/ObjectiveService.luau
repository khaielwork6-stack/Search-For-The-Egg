--!strict
-- Objective / tutorial authority (MASTER_SPEC section 7). Steps are strict-ordered state ids that
-- persist by tutorial version in the profile. Clients receive ObjectiveChanged { step } and map the
-- id to copy; they never receive raw strings.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local Objectives = require(Shared.Domain.Objectives)
local Signal = require(Shared.Util.Signal)

local ObjectiveService = {}
ObjectiveService.__index = ObjectiveService

export type ObjectiveService = typeof(setmetatable(
	{} :: {
		_getProfile: (userId: number) -> any?,
		_analytics: any?,
		_current: { [number]: string },
		changed: any, -- (userId, step)
	},
	ObjectiveService
))

function ObjectiveService.new(options: { getProfile: (userId: number) -> any?, analytics: any? }): ObjectiveService
	return setmetatable(
		{ _getProfile = options.getProfile, _analytics = options.analytics, _current = {}, changed = Signal.new() },
		ObjectiveService
	)
end

-- Resumes from the profile's persisted tutorial state.
function ObjectiveService.load(self: ObjectiveService, userId: number): string
	local profile = self._getProfile(userId)
	local step = Objectives.STEPS[1]
	if profile then
		step = Objectives.resume(profile.data.tutorial.completedSteps, profile.data.tutorial.completed)
	end
	self._current[userId] = step
	self.changed:Fire(userId, step)
	return step
end

function ObjectiveService.current(self: ObjectiveService, userId: number): string
	return self._current[userId] or Objectives.COMPLETE
end

function ObjectiveService.forget(self: ObjectiveService, userId: number)
	self._current[userId] = nil
end

-- Completes `step` only if it is the current step; persists and advances. Returns the new step.
function ObjectiveService.complete(self: ObjectiveService, userId: number, step: string): (boolean, string)
	local current = self:current(userId)
	if not Objectives.canComplete(current, step) then
		return false, current
	end
	local nextStep = Objectives.next(step)
	local profile = self._getProfile(userId)
	if profile and profile:isActive() then
		profile:update(function(data)
			data.tutorial.completedSteps[step] = true
			if nextStep == Objectives.COMPLETE then
				data.tutorial.completed = true
			end
		end)
	end
	self._current[userId] = nextStep
	if self._analytics then
		self._analytics:track("tutorial_step", { step = step }, userId)
	end
	self.changed:Fire(userId, nextStep)
	return true, nextStep
end

-- Skips the remaining tutorial (allowed after the story setup): marks every step complete.
function ObjectiveService.skip(self: ObjectiveService, userId: number): string
	local profile = self._getProfile(userId)
	if profile and profile:isActive() then
		profile:update(function(data)
			for _, step in ipairs(Objectives.STEPS) do
				data.tutorial.completedSteps[step] = true
			end
			data.tutorial.completed = true
		end)
	end
	self._current[userId] = Objectives.COMPLETE
	self.changed:Fire(userId, Objectives.COMPLETE)
	return Objectives.COMPLETE
end

-- Round-scoped objective shown to players whose tutorial is complete.
function ObjectiveService.roundObjective(self: ObjectiveService, userId: number, eggRevealed: boolean): string
	local current = self:current(userId)
	if current ~= Objectives.COMPLETE then
		return current
	end
	return if eggRevealed then "claim_or_complete_round" else "search_for_egg"
end

return ObjectiveService
