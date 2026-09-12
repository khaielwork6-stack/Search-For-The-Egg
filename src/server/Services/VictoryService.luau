--!strict
-- Victory pipeline (MASTER_SPEC section 6 "Victory", DATASTORE_SCHEMA section 8). On claim: commit
-- one idempotent reward transaction per present member (base reward x difficulty multiplier, finder
-- bonus for the finder), update progression/best time/unlocks, save every profile BEFORE results,
-- and build per-player results. Save failures keep the round in CommittingRewards and retry on tick.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local RoundReducer = require(Shared.Reducers.RoundReducer)
local EconomyMath = require(Shared.EconomyMath)
local UnlockPolicy = require(Shared.Domain.UnlockPolicy)
local Signal = require(Shared.Util.Signal)
local TransactionLedger = require(script.Parent.Parent.Data.TransactionLedger)

local VictoryService = {}
VictoryService.__index = VictoryService

export type VictoryService = typeof(setmetatable(
	{} :: {
		_config: { [string]: any },
		_clock: any,
		_rounds: any,
		_getProfile: (userId: number) -> any?,
		_saveProfile: (profile: any) -> boolean,
		_analytics: any?,
		_log: any?,
		_pending: { [string]: boolean },
		committed: any, -- (runtime, results: {[userId]: result})
		stats: { commits: number, replays: number, saveRetries: number },
	},
	VictoryService
))

function VictoryService.new(options: {
	config: { [string]: any },
	clock: any,
	rounds: any,
	getProfile: (userId: number) -> any?,
	saveProfile: (profile: any) -> boolean,
	analytics: any?,
	log: any?,
}): VictoryService
	local self = setmetatable({
		_config = options.config,
		_clock = options.clock,
		_rounds = options.rounds,
		_getProfile = options.getProfile,
		_saveProfile = options.saveProfile,
		_analytics = options.analytics,
		_log = options.log,
		_pending = {},
		committed = Signal.new(),
		stats = { commits = 0, replays = 0, saveRetries = 0 },
	}, VictoryService)
	return self
end

-- Applies the reward transaction to one profile (idempotent by victory key). Returns the result.
function VictoryService.applyReward(self: VictoryService, runtime: any, userId: number, profileData: { [string]: any }): any
	local state = runtime.state
	local chapter = self._config.chapters[state.chapter]
	local difficulty = self._config.difficulty[state.difficulty]
	local rewards = if state.difficulty == "hard" then chapter.hardRewards else chapter.normalRewards
	local isFinder = state.victory and state.victory.finderUserId == userId
	local elapsedMs = state.victory and state.victory.elapsedMs or 0
	local txId = TransactionLedger.victoryKey(state.roundId, userId, state.chapter, state.difficulty)
	local applied = TransactionLedger.apply(profileData, txId, "victory", self._clock:now(), function(data)
		local multiplier = difficulty.rewardMultiplier
		local gems = EconomyMath.roundHalfUp(rewards.gems * multiplier)
		local tokens = EconomyMath.roundHalfUp(rewards.eventTokens * multiplier)
		local cashCents = EconomyMath.roundHalfUp(EconomyMath.dollarsToCents(rewards.cash) * multiplier)
		local finderBonus = if isFinder then self._config.victory.finderBonusGems else 0
		local gemsCfg, tokensCfg = self._config.currencies.gems, self._config.currencies.eventTokens
		data.currencies.gems = EconomyMath.addBounded(data.currencies.gems, gems + finderBonus, gemsCfg.maximum)
		data.currencies.eventTokens = EconomyMath.addBounded(data.currencies.eventTokens, tokens, tokensCfg.maximum)
		data.progression.totalWins += rewards.wins
		data.progression.chapterWins[state.chapter][state.difficulty] += rewards.wins
		local best = data.progression.bestTimeMs[state.chapter]
		local previousBest = best[state.difficulty]
		local newBest = previousBest == nil or elapsedMs < previousBest
		if newBest then
			best[state.difficulty] = elapsedMs
		end
		local beforeChapters = table.clone(data.progression.unlockedChapters)
		local beforeDifficulties = {}
		for key, value in pairs(data.progression.unlockedDifficulties) do
			beforeDifficulties[key] = table.clone(value)
		end
		data.progression.unlockedChapters, data.progression.unlockedDifficulties =
			UnlockPolicy.recompute(self._config.chapters, data.progression)
		local unlocked = {}
		for key, value in pairs(data.progression.unlockedChapters) do
			if value and not beforeChapters[key] then
				table.insert(unlocked, key .. ":normal")
			end
		end
		for key, value in pairs(data.progression.unlockedDifficulties) do
			if value.hard and not (beforeDifficulties[key] and beforeDifficulties[key].hard) then
				table.insert(unlocked, key .. ":hard")
			end
		end
		table.sort(unlocked)
		data.stats.roundsCompleted += 1
		data.stats.cashEarnedLifetime += cashCents + (runtime.players[userId] and runtime.players[userId].cashCents or 0)
		if isFinder then
			data.stats.eggsFound += 1
		end
		local playerState = runtime.players[userId]
		if playerState then
			data.stats.feathersCollected += playerState.contribution.feathersCollected
		end
		return {
			gems = gems,
			finderBonusGems = finderBonus,
			eventTokens = tokens,
			cashCents = cashCents,
			wins = rewards.wins,
			elapsedMs = elapsedMs,
			newBest = newBest,
			previousBestMs = previousBest,
			unlocked = unlocked,
			isFinder = isFinder,
		}
	end)
	if applied.status == "replayed" then
		self.stats.replays += 1
	end
	return applied.result
end

-- Commit function handed to RoundService.commitAndFinish. Returns false if any save is pending.
function VictoryService.commitRewards(self: VictoryService, runtime: any): boolean
	if runtime.rewardsCommitted then
		return true -- idempotent: a replayed commit changes nothing and fires nothing
	end
	local allSaved = true
	for _, userId in ipairs(RoundReducer.presentMembers(runtime.state)) do
		local profile = self._getProfile(userId)
		if not profile or not profile:isActive() then
			continue -- member left before commit; nothing to grant on this server
		end
		local result = profile:update(function(data)
			return self:applyReward(runtime, userId, data)
		end)
		local playerState = runtime.players[userId]
		runtime.results[userId] = {
			finderUserId = runtime.state.victory and runtime.state.victory.finderUserId,
			chapter = runtime.state.chapter,
			difficulty = runtime.state.difficulty,
			elapsedMs = result.elapsedMs,
			newBest = result.newBest,
			previousBestMs = result.previousBestMs,
			contribution = playerState and table.clone(playerState.contribution) or { cellsRemoved = 0, feathersCollected = 0 },
			roundCashCents = playerState and playerState.cashCents or 0,
			rewards = {
				gems = result.gems,
				finderBonusGems = result.finderBonusGems,
				eventTokens = result.eventTokens,
				cashCents = result.cashCents,
				wins = result.wins,
			},
			unlocked = result.unlocked,
			isFinder = result.isFinder,
			saved = false,
			autoContinueSeconds = self._config.round.resultScreenAutoContinueSeconds,
			minimumSeconds = self._config.round.resultScreenMinimumSeconds,
		}
		if not runtime.results[userId].saved then
			local saved = self._saveProfile(profile)
			runtime.results[userId].saved = saved
			if not saved then
				allSaved = false
				self.stats.saveRetries += 1
				if self._log then
					self._log:warn("victory_save_pending", { userId = userId, roundId = runtime.state.roundId })
				end
			end
		end
	end
	if allSaved then
		runtime.rewardsCommitted = true
		self.stats.commits += 1
		if self._analytics then
			self._analytics:track("round_completed", {
				chapter = runtime.state.chapter,
				difficulty = runtime.state.difficulty,
				elapsedMs = runtime.state.victory and runtime.state.victory.elapsedMs or 0,
				partySize = #runtime.state.members,
			})
		end
		self.committed:Fire(runtime, runtime.results)
	end
	return allSaved
end

-- Starts the pipeline for a claimed round. Returns the resulting state (Results or CommittingRewards).
function VictoryService.start(self: VictoryService, roundId: string): (any, string?)
	local state, err = self._rounds:commitAndFinish(roundId, function(runtime)
		return self:commitRewards(runtime)
	end)
	if err == "commit_pending" then
		self._pending[roundId] = true
	end
	return state, err
end

-- Retries pending commits (called from the server tick). Returns the number completed.
function VictoryService.tick(self: VictoryService): number
	local completed = 0
	for roundId in pairs(table.clone(self._pending)) do
		local runtime = self._rounds:runtime(roundId)
		if not runtime then
			self._pending[roundId] = nil
			continue
		end
		local _, err = self._rounds:commitAndFinish(roundId, function(rt)
			return self:commitRewards(rt)
		end)
		if err ~= "commit_pending" then
			self._pending[roundId] = nil
			completed += 1
		end
	end
	return completed
end

function VictoryService.pendingCount(self: VictoryService): number
	local n = 0
	for _ in pairs(self._pending) do
		n += 1
	end
	return n
end

return VictoryService
