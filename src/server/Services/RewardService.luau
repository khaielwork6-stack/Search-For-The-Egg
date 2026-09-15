--!strict
-- Daily reward, redeem code, and group reward authority (MASTER_SPEC 11, DATASTORE_SCHEMA 8,
-- ASSUMED A-META-01..04/06/07). Every grant is one TransactionLedger transaction on the profile, so
-- a retried request replays the original result instead of granting twice. Server time only. Codes
-- are read from the server-only config section and never echoed back to clients. Gem grants apply
-- the permanent Gem Value perk through the resolver (gemValueMultiplier) exactly once.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local DailyRewards = require(Shared.Domain.DailyRewards)
local DailyQuests = require(Shared.Domain.DailyQuests)
local EconomyMath = require(Shared.EconomyMath)
local Config = require(Shared.Config)
local Envelope = require(Shared.Net.Envelope)
local Signal = require(Shared.Util.Signal)
local TransactionLedger = require(script.Parent.Parent.Data.TransactionLedger)
local RoundModifiers = require(script.Parent.RoundModifiers)

local RewardService = {}
RewardService.__index = RewardService

export type RewardService = typeof(setmetatable(
	{} :: {
		_config: { [string]: any },
		_clock: any,
		_getProfile: (userId: number) -> any?,
		_getEntitlements: (userId: number) -> { [string]: boolean },
		_group: any,
		_analytics: any?,
		_log: any?,
		granted: any, -- (userId, grant)
		stats: { daily: number, codes: number, group: number, replays: number, rejected: number, quests: number, questProgress: number },
	},
	RewardService
))

function RewardService.new(options: {
	config: { [string]: any },
	clock: any,
	getProfile: (userId: number) -> any?,
	getEntitlements: (userId: number) -> { [string]: boolean },
	group: any,
	analytics: any?,
	log: any?,
}): RewardService
	return setmetatable({
		_config = options.config,
		_clock = options.clock,
		_getProfile = options.getProfile,
		_getEntitlements = options.getEntitlements,
		_group = options.group,
		_analytics = options.analytics,
		_log = options.log,
		granted = Signal.new(),
		stats = { daily = 0, codes = 0, group = 0, replays = 0, rejected = 0, quests = 0, questProgress = 0 },
	}, RewardService)
end

local function reject(self: RewardService, code: string, message: string?): Envelope.Envelope<any>
	self.stats.rejected += 1
	return Envelope.fail(code, message)
end

-- Gem Value perk applied once to a premium-currency grant (rounded half up, never below the base).
local function gemGrant(self: RewardService, data: { [string]: any }, userId: number, baseGems: number): number
	local modifiers = RoundModifiers.resolve(self._config, data, "normal", self._getEntitlements(userId))
	return math.max(baseGems, EconomyMath.roundHalfUp(baseGems * modifiers.gemValueMultiplier))
end

local function credit(self: RewardService, data: { [string]: any }, gems: number, tokens: number)
	local gemsCfg, tokensCfg = self._config.currencies.gems, self._config.currencies.eventTokens
	data.currencies.gems = EconomyMath.addBounded(data.currencies.gems, gems, gemsCfg.maximum)
	data.currencies.eventTokens = EconomyMath.addBounded(data.currencies.eventTokens, tokens, tokensCfg.maximum)
end

-- Daily ---------------------------------------------------------------------------------------

function RewardService.dailyEvaluation(self: RewardService, data: { [string]: any }): DailyRewards.Evaluation
	return DailyRewards.evaluate(self._config, data.rewards, self._clock:now())
end

function RewardService.claimDaily(self: RewardService, userId: number): Envelope.Envelope<any>
	if not Config.featureEnabled(self._config, "dailyRewardsEnabled") then
		return reject(self, Envelope.Codes.UNAVAILABLE, "daily_disabled")
	end
	local profile = self._getProfile(userId)
	if not profile or not profile:isActive() then
		return reject(self, Envelope.Codes.INVALID_STATE, "profile")
	end
	local now = self._clock:now()
	local data = profile.data
	local evaluation = DailyRewards.evaluate(self._config, data.rewards, now)
	if evaluation.status == "early" then
		-- Retry of the claim that just landed: replay its committed result instead of granting again.
		local lastTx = data.rewards.lastDailyClaimTxId
		if lastTx and TransactionLedger.isCommitted(data, lastTx) then
			self.stats.replays += 1
			local replay = table.clone(data.pendingTransactions[lastTx].result)
			replay.replayed = true
			replay.nextClaimInSeconds = evaluation.nextClaimInSeconds
			return Envelope.ok(replay)
		end
		return reject(self, Envelope.Codes.ALREADY_DONE, "not_ready")
	end
	local txId = DailyRewards.transactionKey(evaluation, now)
	local applied = profile:update(function(profileData)
		return TransactionLedger.apply(profileData, txId, "daily", now, function(mutable)
			local gems = gemGrant(self, mutable, userId, evaluation.gems)
			credit(self, mutable, gems, 0)
			local nextState = DailyRewards.apply(self._config, evaluation, now)
			mutable.rewards.dailyIndex = nextState.dailyIndex
			mutable.rewards.dailyLastClaimAt = nextState.dailyLastClaimAt
			mutable.rewards.dailyStreakStartedAt = nextState.dailyStreakStartedAt
			mutable.rewards.lastDailyClaimTxId = txId
			return {
				kind = "daily",
				dayIndex = evaluation.dayIndex,
				baseGems = evaluation.gems,
				gems = gems,
				streakReset = evaluation.status == "reset",
				nextDayIndex = nextState.dailyIndex,
				gemsBalance = mutable.currencies.gems,
			}
		end)
	end)
	local result = table.clone(applied.result)
	result.replayed = applied.status == "replayed"
	if applied.status == "committed" then
		self.stats.daily += 1
		if self._analytics then
			self._analytics:track("daily_claimed", { day = evaluation.dayIndex, gems = result.gems, reset = result.streakReset }, userId)
		end
		self.granted:Fire(userId, result)
	else
		self.stats.replays += 1
	end
	local after = DailyRewards.evaluate(self._config, profile.data.rewards, now)
	result.nextClaimInSeconds = after.nextClaimInSeconds
	return Envelope.ok(result)
end

-- Daily quests --------------------------------------------------------------------------------
--
-- Progress is fed from counters the server already produces at the end of a run (a sale, a victory,
-- an upgrade), never from the collection hot path, so a busy round costs nothing extra.

-- Rolls the record over when the day has turned. Returns the day index in force.
local function questDay(self: RewardService, data: { [string]: any }): number
	local settings = self._config.dailyQuests
	local day = DailyQuests.dayIndex(self._clock:now(), settings.resetSeconds)
	local record = data.quests
	if record.day ~= day then
		record.day = day
		record.progress = {}
		record.claimed = {}
	end
	return day
end

function RewardService.questView(self: RewardService, data: { [string]: any }, userId: number): ({ DailyQuests.View }, number)
	return DailyQuests.view(self._config, data.quests, userId, self._clock:now())
end

-- Adds to every active quest tracking `metric`. Silently does nothing for a metric no quest wants,
-- so callers can report freely without knowing today's board.
function RewardService.advanceQuests(self: RewardService, userId: number, metric: string, amount: number): boolean
	if amount <= 0 or not Config.featureEnabled(self._config, "dailyQuestsEnabled") then
		return false
	end
	local profile = self._getProfile(userId)
	if not profile or not profile:isActive() then
		return false
	end
	local moved = false
	profile:update(function(data)
		local day = questDay(self, data)
		for _, quest in ipairs(DailyQuests.select(self._config, userId, day)) do
			if quest.metric == metric then
				local current = data.quests.progress[quest.id] or 0
				if current < quest.target then
					-- Held at the target: progress past it carries no meaning and would only make a
					-- stored number grow without bound.
					data.quests.progress[quest.id] = math.min(quest.target, current + amount)
					moved = true
				end
			end
		end
		return data
	end)
	if moved then
		self.stats.questProgress += 1
	end
	return moved
end

function RewardService.claimQuest(self: RewardService, userId: number, questId: string): Envelope.Envelope<any>
	if not Config.featureEnabled(self._config, "dailyQuestsEnabled") then
		return reject(self, Envelope.Codes.UNAVAILABLE, "quests_disabled")
	end
	local profile = self._getProfile(userId)
	if not profile or not profile:isActive() then
		return reject(self, Envelope.Codes.INVALID_STATE, "profile")
	end
	local now = self._clock:now()
	local data = profile.data
	local day = DailyQuests.dayIndex(now, self._config.dailyQuests.resetSeconds)
	-- A request naming a quest the player does not have today is refused, not trusted.
	local quest = DailyQuests.questFor(self._config, userId, day, questId)
	if not quest then
		return reject(self, Envelope.Codes.NOT_FOUND, "quest")
	end
	local record = data.quests
	local progress = if record.day == day then (record.progress[questId] or 0) else 0
	if progress < quest.target then
		return reject(self, Envelope.Codes.INVALID_STATE, "not_complete")
	end
	if record.day == day and record.claimed[questId] then
		return reject(self, Envelope.Codes.ALREADY_DONE, "already_claimed")
	end
	-- Keyed by player, day and quest, so a retry replays rather than paying twice.
	local txId = DailyQuests.transactionKey(userId, day, questId)
	local applied = profile:update(function(profileData)
		return TransactionLedger.apply(profileData, txId, "quest", now, function(mutable)
			local gems = gemGrant(self, mutable, userId, quest.gems)
			credit(self, mutable, gems, 0)
			questDay(self, mutable)
			mutable.quests.claimed[questId] = true
			return { kind = "quest", questId = questId, baseGems = quest.gems, gems = gems, gemsBalance = mutable.currencies.gems }
		end)
	end)
	local result = table.clone(applied.result)
	result.replayed = applied.status == "replayed"
	if applied.status == "committed" then
		self.stats.quests += 1
		if self._analytics then
			self._analytics:track("quest_claimed", { questId = questId, gems = result.gems }, userId)
		end
		self.granted:Fire(userId, result)
	else
		self.stats.replays += 1
	end
	return Envelope.ok(result)
end

-- Codes ---------------------------------------------------------------------------------------

-- ASSUMED A-META-07 normalization: trim, uppercase, strip inner whitespace and separators.
function RewardService.normalizeCode(raw: any): string?
	if type(raw) ~= "string" then
		return nil
	end
	local cleaned = string.upper(string.gsub(raw, "[%s%-_]", ""))
	if #cleaned == 0 then
		return nil
	end
	return cleaned
end

function RewardService.redeemCode(self: RewardService, userId: number, rawCode: any): Envelope.Envelope<any>
	if not Config.featureEnabled(self._config, "codesEnabled") then
		return reject(self, Envelope.Codes.UNAVAILABLE, "codes_disabled")
	end
	local profile = self._getProfile(userId)
	if not profile or not profile:isActive() then
		return reject(self, Envelope.Codes.INVALID_STATE, "profile")
	end
	local code = RewardService.normalizeCode(rawCode)
	if not code or #code > self._config.codePolicy.maxLength then
		return reject(self, Envelope.Codes.NOT_FOUND, "invalid_code")
	end
	local entry = self._config.codes[code]
	local now = self._clock:now()
	if not entry or entry.active ~= true then
		return reject(self, Envelope.Codes.NOT_FOUND, "invalid_code")
	end
	if entry.expiresAt ~= nil and now > entry.expiresAt then
		return reject(self, Envelope.Codes.NOT_FOUND, "expired_code")
	end
	local data = profile.data
	local txId = "code:" .. code
	if data.rewards.claimedCodes[code] ~= nil and not TransactionLedger.isCommitted(data, txId) then
		return reject(self, Envelope.Codes.ALREADY_DONE, "already_claimed")
	end
	local applied = profile:update(function(profileData)
		return TransactionLedger.apply(profileData, txId, "code", now, function(mutable)
			local baseGems = entry.rewards.gems or 0
			local gems = if baseGems > 0 then gemGrant(self, mutable, userId, baseGems) else 0
			local tokens = entry.rewards.eventTokens or 0
			credit(self, mutable, gems, tokens)
			mutable.rewards.claimedCodes[code] = now
			return {
				kind = "code",
				code = code,
				baseGems = baseGems,
				gems = gems,
				eventTokens = tokens,
				gemsBalance = mutable.currencies.gems,
			}
		end)
	end)
	local result = table.clone(applied.result)
	result.replayed = applied.status == "replayed"
	if applied.status == "committed" then
		self.stats.codes += 1
		if self._analytics then
			self._analytics:track("code_redeemed", { gems = result.gems, tokens = result.eventTokens }, userId)
		end
		self.granted:Fire(userId, result)
	else
		self.stats.replays += 1
		return reject(self, Envelope.Codes.ALREADY_DONE, "already_claimed")
	end
	return Envelope.ok(result)
end

-- Group reward ----------------------------------------------------------------------------------

function RewardService.claimGroupReward(self: RewardService, userId: number): Envelope.Envelope<any>
	local profile = self._getProfile(userId)
	if not profile or not profile:isActive() then
		return reject(self, Envelope.Codes.INVALID_STATE, "profile")
	end
	if not self._group:isConfigured() then
		return reject(self, Envelope.Codes.UNAVAILABLE, "no_group")
	end
	local data = profile.data
	local txId = "group:reward"
	if data.rewards.groupRewardClaimed then
		if TransactionLedger.isCommitted(data, txId) then
			self.stats.replays += 1
			local replay = table.clone(data.pendingTransactions[txId].result)
			replay.replayed = true
			return Envelope.ok(replay)
		end
		return reject(self, Envelope.Codes.ALREADY_DONE, "already_claimed")
	end
	local ok, member = self._group:isMember(userId)
	if not ok then
		return reject(self, Envelope.Codes.UNAVAILABLE, "group_check_failed")
	end
	if not member then
		return reject(self, Envelope.Codes.NOT_AUTHORIZED, "not_member")
	end
	local now = self._clock:now()
	local applied = profile:update(function(profileData)
		return TransactionLedger.apply(profileData, txId, "group", now, function(mutable)
			local baseGems = self._config.monetization.groupRewardGems
			local gems = gemGrant(self, mutable, userId, baseGems)
			credit(self, mutable, gems, 0)
			mutable.rewards.groupRewardClaimed = true
			return { kind = "group", baseGems = baseGems, gems = gems, gemsBalance = mutable.currencies.gems }
		end)
	end)
	local result = table.clone(applied.result)
	result.replayed = applied.status == "replayed"
	if applied.status == "committed" then
		self.stats.group += 1
		if self._analytics then
			self._analytics:track("group_reward_claimed", { gems = result.gems }, userId)
		end
		self.granted:Fire(userId, result)
	else
		self.stats.replays += 1
	end
	return Envelope.ok(result)
end

return RewardService
