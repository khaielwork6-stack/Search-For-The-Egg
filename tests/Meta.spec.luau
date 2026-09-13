--!nocheck
-- Phase 4 lobby/meta services: classes (weights, luck, roll, equip, sequencing), permanent perks,
-- daily rewards (early / on time / grace / expired / day 8 / replay), codes, group reward,
-- inventory equips, leaderboards (bounded writes, sanitized rows), and the profile projection.

return function(describe, it, expect)
	local ServerStorage = game:GetService("ServerStorage")
	local Shared = game:GetService("ReplicatedStorage").Shared
	local Server = game:GetService("ServerScriptService").Server
	local Config = require(Shared.Config)
	local TableUtil = require(Shared.Util.TableUtil)
	local WeightedRandom = require(Shared.WeightedRandom)
	local ClassRoll = require(Shared.Domain.ClassRoll)
	local DailyRewards = require(Shared.Domain.DailyRewards)
	local Perks = require(Shared.Domain.Perks)
	local SkinCatalog = require(Shared.Domain.SkinCatalog)
	local NetSchema = require(Shared.Net.NetSchema)
	local RoundModifiers = require(Server.Services.RoundModifiers)
	local ProfileProjection = require(Server.Data.ProfileProjection)
	local TransactionLedger = require(Server.Data.TransactionLedger)
	local GameplayHarness = require(ServerStorage.Tests.Helpers.GameplayHarness)
	local rawConfig = require(ServerStorage.SFE.SystemConfig)
	local cfg = Config.fromRaw(rawConfig)

	local function fresh(options)
		local h = GameplayHarness.new(cfg, options)
		h.join(1)
		return h
	end

	describe("Classes", function()
		it("base weights total exactly 100 and displayed odds sum to 100", function()
			expect(WeightedRandom.totalWeight(ClassRoll.weights(cfg, false))).toBeCloseTo(100, 1e-9)
			local sum = 0
			for _, entry in ipairs(ClassRoll.odds(cfg, false)) do
				sum += entry.percent
			end
			expect(sum).toBeCloseTo(100, 0.05)
			expect(#ClassRoll.odds(cfg, false)).toBe(8)
		end)

		it("boundary rolls select every class interval exactly", function()
			local weights = ClassRoll.weights(cfg, false)
			local intervals = WeightedRandom.intervals(weights)
			for _, entry in ipairs(weights) do
				local interval = intervals[entry.id]
				expect(WeightedRandom.selectByRoll(weights, interval.start).id).toBe(entry.id)
				expect(WeightedRandom.selectByRoll(weights, interval.finish - 1e-12).id).toBe(entry.id)
			end
		end)

		it("seeded statistical smoke over 100000 rolls stays within tolerance", function()
			local rng = WeightedRandom.fromSeed(2026)
			local counts = {}
			local n = 100000
			for _ = 1, n do
				local id = ClassRoll.roll(cfg, rng, false)
				counts[id] = (counts[id] or 0) + 1
			end
			for _, entry in ipairs(cfg.classes.weights) do
				local observed = (counts[entry.id] or 0) / n * 100
				local tolerance = math.max(0.35, entry.weight * 0.35)
				expect(math.abs(observed - entry.weight)).toBeLessThanOrEqual(tolerance)
			end
		end)

		it("2x Luck totals 100, never goes negative, doubles rare classes, and only trims the baseline", function()
			local base = ClassRoll.weights(cfg, false)
			local lucky = ClassRoll.weights(cfg, true)
			expect(WeightedRandom.totalWeight(lucky)).toBeCloseTo(100, 1e-9)
			for index, entry in ipairs(lucky) do
				expect(entry.weight).toBeGreaterThanOrEqual(0)
				local baseEntry = base[index]
				if baseEntry.id == "newcomer" then
					expect(entry.weight).toBeLessThan(baseEntry.weight)
				elseif baseEntry.weight <= cfg.classes.luckTransform.rareWeightThreshold then
					expect(entry.weight).toBeCloseTo(baseEntry.weight * 2, 1e-9)
				else
					expect(entry.weight).toBeCloseTo(baseEntry.weight, 1e-9)
				end
			end
		end)

		it("a roll debits exactly the configured Gems, persists the class, and applies its modifiers once", function()
			local h = fresh()
			h.grantGems(1, cfg.classes.rollGemCost)
			local result = h.classes:roll(1, 1)
			expect(result.ok).toBe(true)
			expect(result.data.paidGems).toBe(cfg.classes.rollGemCost)
			expect(h.profile(1).data.currencies.gems).toBe(0)
			expect(h.profile(1).data.classes.owned[result.data.classId]).toBe(true)
			expect(h.profile(1).data.classes.equipped[1]).toBe(result.data.classId)
			expect(h.profile(1).data.classes.rollCount).toBe(1)
			expect(result.data.animationSeconds).toBe(cfg.lobby.classRollAnimationSeconds)
			-- Equip the same class into a second slot (extra slot entitlement): the resolver applies it once.
			h.setEntitlement(1, "extraClassSlot", true)
			local equip = h.classes:equip(1, result.data.classId, 2)
			expect(equip.ok).toBe(true)
			local equipped = h.profile(1).data.classes.equipped
			local seen = 0
			for _, id in ipairs(equipped) do
				if id == result.data.classId then
					seen += 1
				end
			end
			expect(seen).toBe(1)
			local modifiers = RoundModifiers.resolve(cfg, h.profile(1).data, "normal", h.mockEntitlements[1])
			local applied = 0
			for _, source in ipairs(modifiers.appliedSources) do
				if source == "class:" .. result.data.classId then
					applied += 1
				end
			end
			expect(applied).toBe(1)
			expect(h.analyticsAdapter:countOf("class_rolled")).toBe(1)
		end)

		it("duplicate rolls re-equip without a second ownership, insufficient Gems never debit, bad slots fail", function()
			local classes = { owned = { newcomer = true, eggTrader = true }, equipped = { "eggTrader" }, rollCount = 3, slotCount = 1 }
			expect(ClassRoll.applyResult(classes, "eggTrader", 1, 1)).toBe(true)
			expect(classes.equipped).toEqual({ "eggTrader" })
			expect(classes.rollCount).toBe(4)
			local h = fresh()
			local poor = h.classes:roll(1, 1)
			expect(poor.ok).toBe(false)
			expect(poor.code).toBe("insufficient_funds")
			expect(h.profile(1).data.classes.rollCount).toBe(0)
			h.grantGems(1, cfg.classes.rollGemCost * 3)
			local badSlot = h.classes:roll(1, 2) -- default slot count is 1
			expect(badSlot.ok).toBe(false)
			expect(badSlot.code).toBe("invalid_payload")
			expect(h.profile(1).data.currencies.gems).toBe(cfg.classes.rollGemCost * 3)
			local unowned = h.classes:equip(1, "masterForager", 1)
			expect(unowned.ok).toBe(false)
			expect(unowned.code).toBe("not_authorized")
		end)

		it("rolls obey the server minimum interval, the lobby phase, and Fast Rolls timing", function()
			local h = fresh()
			h.grantGems(1, cfg.classes.rollGemCost * 4)
			expect(h.classes:roll(1, 1).ok).toBe(true)
			local tooFast = h.classes:roll(1, 1)
			expect(tooFast.ok).toBe(false)
			expect(tooFast.code).toBe("rate_limited")
			h.clock:advance(cfg.lobby.classRollMinIntervalSeconds)
			expect(h.classes:roll(1, 1).ok).toBe(true)
			h.setEntitlement(1, "fastRolls", true)
			h.clock:advance(cfg.lobby.classRollMinIntervalSeconds)
			local fast = h.classes:roll(1, 1)
			expect(fast.ok).toBe(true)
			expect(fast.data.animationSeconds).toBe(cfg.lobby.classRollFastAnimationSeconds)
			expect(h.classes:view(1).fastRolls).toBe(true)
			-- Inside a round the lobby-only actions are refused.
			h.startRound({ 1 })
			h.clock:advance(cfg.lobby.classRollMinIntervalSeconds)
			local inRound = h.classes:roll(1, 1)
			expect(inRound.ok).toBe(false)
			expect(inRound.message).toBe("not_in_lobby")
			expect(h.classes.stats.rolls).toBe(3)
		end)

		it("ClassRoll and CodeRedeem remote rates come from configuration", function()
			local registry = NetSchema.build(cfg)
			expect(registry.byName.ClassRoll.rate.perSecond).toBeCloseTo(cfg.lobby.autoRollMaxPerMinute / 60, 1e-9)
			expect(registry.byName.CodeRedeem.rate.perSecond).toBeCloseTo(cfg.codePolicy.attemptsPerMinute / 60, 1e-9)
			expect(registry.byName.CodeRedeem.rate.burst).toBe(cfg.codePolicy.burst)
		end)
	end)

	describe("Permanent perks", function()
		it("purchases are atomic, previews show old -> new, stale/insufficient/maxed never debit", function()
			local h = fresh()
			local first = Perks.preview(cfg, "bagSize", 0)
			expect(first.costGems).toBe(cfg.permanentPerks.bagSize.baseGemCost)
			expect(first.nextMultiplier).toBeCloseTo(1 + cfg.permanentPerks.bagSize.valuePerLevel, 1e-9)
			local broke = h.perks:purchase(1, "bagSize", 0)
			expect(broke.ok).toBe(false)
			expect(broke.code).toBe("insufficient_funds")
			h.grantGems(1, first.costGems)
			local stale = h.perks:purchase(1, "bagSize", 1)
			expect(stale.ok).toBe(false)
			expect(stale.code).toBe("stale_token")
			expect(h.profile(1).data.currencies.gems).toBe(first.costGems)
			local bought = h.perks:purchase(1, "bagSize", 0)
			expect(bought.ok).toBe(true)
			expect(bought.data.level).toBe(1)
			expect(bought.data.paidGems).toBe(first.costGems)
			expect(h.profile(1).data.currencies.gems).toBe(0)
			expect(h.profile(1).data.permanentPerks.bagSize).toBe(1)
			local modifiers = RoundModifiers.resolve(cfg, h.profile(1).data, "normal", nil)
			expect(modifiers.bagCapacityMultiplier).toBeCloseTo(1 + cfg.permanentPerks.bagSize.valuePerLevel, 1e-9)
			expect(h.perks:purchase(1, "notAPerk", 0).code).toBe("not_found")
			-- Cap: level maxLevel refuses without debit.
			h.profile(1):update(function(data)
				data.permanentPerks.gemValue = cfg.permanentPerks.gemValue.maxLevel
			end)
			h.grantGems(1, 100000)
			local maxed = h.perks:purchase(1, "gemValue", cfg.permanentPerks.gemValue.maxLevel)
			expect(maxed.ok).toBe(false)
			expect(maxed.message).toBe("maxed")
			expect(h.profile(1).data.currencies.gems).toBe(100000)
			expect(Perks.costGems(cfg, "gemValue", cfg.permanentPerks.gemValue.maxLevel)).toBeNil()
			expect(h.analyticsAdapter:countOf("perk_purchased")).toBe(1)
		end)
	end)

	describe("Daily rewards", function()
		it("grants day 1 once; an immediate retry replays the committed result without a second grant", function()
			local h = fresh()
			local first = h.rewards:claimDaily(1)
			expect(first.ok).toBe(true)
			expect(first.data.dayIndex).toBe(1)
			expect(first.data.gems).toBe(cfg.dailyRewards[1].gems)
			expect(first.data.replayed).toBe(false)
			expect(h.profile(1).data.currencies.gems).toBe(cfg.dailyRewards[1].gems)
			expect(h.profile(1).data.rewards.dailyIndex).toBe(2)
			local retry = h.rewards:claimDaily(1)
			expect(retry.ok).toBe(true)
			expect(retry.data.replayed).toBe(true)
			expect(h.profile(1).data.currencies.gems).toBe(cfg.dailyRewards[1].gems)
			expect(h.rewards.stats.daily).toBe(1)
			expect(h.rewards.stats.replays).toBe(1)
			expect(h.analyticsAdapter:countOf("daily_claimed")).toBe(1)
		end)

		it("early / on-time / grace / expired / day 8 timing follows the configured rules", function()
			local h = fresh()
			local rules = cfg.dailyRewardRules
			h.rewards:claimDaily(1)
			h.clock:advance(rules.claimCooldownSeconds - 1)
			local early = h.rewards:dailyEvaluation(h.profile(1).data)
			expect(early.status).toBe("early")
			expect(early.nextClaimInSeconds).toBe(1)
			h.clock:advance(1)
			local onTime = h.rewards:dailyEvaluation(h.profile(1).data)
			expect(onTime.status).toBe("ready")
			expect(onTime.dayIndex).toBe(2)
			local second = h.rewards:claimDaily(1)
			expect(second.data.gems).toBe(cfg.dailyRewards[2].gems)
			-- Inside the grace window the streak survives.
			h.clock:advance(rules.gracePeriodSeconds - 10)
			expect(h.rewards:dailyEvaluation(h.profile(1).data).status).toBe("ready")
			expect(h.rewards:dailyEvaluation(h.profile(1).data).dayIndex).toBe(3)
			-- Past the grace window the streak resets to day 1.
			h.clock:advance(20)
			local expired = h.rewards:dailyEvaluation(h.profile(1).data)
			expect(expired.status).toBe("reset")
			expect(expired.dayIndex).toBe(1)
			local reset = h.rewards:claimDaily(1)
			expect(reset.data.dayIndex).toBe(1)
			expect(reset.data.streakReset).toBe(true)
			expect(h.profile(1).data.rewards.dailyIndex).toBe(2)
			-- Day 8 loops back to day 1 (afterDay8 policy).
			h.profile(1):update(function(data)
				data.rewards.dailyIndex = #cfg.dailyRewards
				data.rewards.dailyLastClaimAt = nil
			end)
			local day8 = h.rewards:claimDaily(1)
			expect(day8.data.gems).toBe(cfg.dailyRewards[#cfg.dailyRewards].gems)
			expect(day8.data.nextDayIndex).toBe(1)
			expect(h.profile(1).data.rewards.dailyIndex).toBe(1)
		end)

		it("the Gem Value perk applies exactly once to daily grants", function()
			local h = fresh()
			local perk = cfg.permanentPerks.gemValue
			h.profile(1):update(function(data)
				data.permanentPerks.gemValue = perk.maxLevel
			end)
			local claim = h.rewards:claimDaily(1)
			local expected = math.floor(cfg.dailyRewards[1].gems * (1 + perk.maxLevel * perk.valuePerLevel) + 0.5)
			expect(claim.data.gems).toBe(expected)
			expect(claim.data.baseGems).toBe(cfg.dailyRewards[1].gems)
			expect(h.profile(1).data.currencies.gems).toBe(expected)
		end)

		it("transaction keys are stable per streak and day", function()
			local evaluation =
				DailyRewards.evaluate(cfg, { dailyIndex = 3, dailyLastClaimAt = 1000, dailyStreakStartedAt = 900 }, 1000 + 86400)
			expect(DailyRewards.transactionKey(evaluation, 5000)).toBe("daily:900:3")
			local fresh1 = DailyRewards.evaluate(cfg, { dailyIndex = 1 }, 777)
			expect(DailyRewards.transactionKey(fresh1, 777)).toBe("daily:777:1")
		end)
	end)

	describe("Codes and group reward", function()
		it("normalizes input, grants ALIEN once, and refuses replays, unknown, inactive, and expired codes", function()
			local raw = TableUtil.deepCopy(rawConfig)
			raw.codes.SLEEPY = { active = false, expiresAt = nil, rewards = { gems = 5 } }
			raw.codes.GONE = { active = true, expiresAt = 500, rewards = { gems = 5 } }
			local custom = Config.fromRaw(raw)
			local h = GameplayHarness.new(custom)
			h.join(1)
			expect(h.rewards.normalizeCode("  a-l i_en ")).toBe("ALIEN")
			local redeemed = h.rewards:redeemCode(1, "alien")
			expect(redeemed.ok).toBe(true)
			expect(redeemed.data.gems).toBe(custom.codes.ALIEN.rewards.gems)
			expect(redeemed.data.eventTokens).toBe(custom.codes.ALIEN.rewards.eventTokens)
			expect(h.profile(1).data.currencies.gems).toBe(custom.codes.ALIEN.rewards.gems)
			expect(h.profile(1).data.rewards.claimedCodes.ALIEN).toBeTruthy()
			local again = h.rewards:redeemCode(1, "ALIEN")
			expect(again.ok).toBe(false)
			expect(again.code).toBe("already_done")
			expect(h.profile(1).data.currencies.gems).toBe(custom.codes.ALIEN.rewards.gems)
			expect(h.rewards:redeemCode(1, "NOPE").code).toBe("not_found")
			expect(h.rewards:redeemCode(1, "SLEEPY").code).toBe("not_found")
			expect(h.rewards:redeemCode(1, "GONE").message).toBe("expired_code")
			expect(h.rewards:redeemCode(1, "").code).toBe("not_found")
			expect(h.rewards:redeemCode(1, string.rep("A", custom.codePolicy.maxLength + 1)).code).toBe("not_found")
			expect(h.rewards.stats.codes).toBe(1)
			expect(h.analyticsAdapter:countOf("code_redeemed")).toBe(1)
			expect(ProfileProjection.leaks(h.playerData:buildProjection(1, custom))).toBe(false)
		end)

		it("group reward grants once to members only and replays after retries", function()
			local h = fresh()
			local notMember = h.rewards:claimGroupReward(1)
			expect(notMember.ok).toBe(false)
			expect(notMember.code).toBe("not_authorized")
			h.group:setMember(1, true)
			local claim = h.rewards:claimGroupReward(1)
			expect(claim.ok).toBe(true)
			expect(claim.data.gems).toBe(cfg.monetization.groupRewardGems)
			expect(h.profile(1).data.rewards.groupRewardClaimed).toBe(true)
			local replay = h.rewards:claimGroupReward(1)
			expect(replay.ok).toBe(true)
			expect(replay.data.replayed).toBe(true)
			expect(h.profile(1).data.currencies.gems).toBe(cfg.monetization.groupRewardGems)
			expect(TransactionLedger.isCommitted(h.profile(1).data, "group:reward")).toBe(true)
			h.join(2)
			h.group:setConfigured(false)
			expect(h.rewards:claimGroupReward(2).code).toBe("unavailable")
			h.group:setConfigured(true)
			h.group:failNext(1)
			expect(h.rewards:claimGroupReward(2).message).toBe("group_check_failed")
			expect(h.profile(2).data.currencies.gems).toBe(0)
			expect(h.analyticsAdapter:countOf("group_reward_claimed")).toBe(1)
		end)
	end)

	describe("Inventory", function()
		it("equips only owned skins of the right category", function()
			local h = fresh()
			local catalog = SkinCatalog.all(cfg)
			expect(#catalog).toBe(8)
			expect(SkinCatalog.categoryFor(cfg, "alienRakeSkin")).toBe("nestRake")
			expect(SkinCatalog.categoryFor(cfg, "ufoDroneSkin")).toBe("scoutChick")
			local unowned = h.inventory:equip(1, "nestRake", "alienRakeSkin")
			expect(unowned.ok).toBe(false)
			expect(unowned.code).toBe("not_authorized")
			expect(h.inventory:equip(1, "nestRake", "alienVacSkin").code).toBe("not_found")
			expect(h.inventory:equip(1, "hand", "defaultRake").code).toBe("not_found")
			h.profile(1):update(function(data)
				data.inventory.toolSkins.alienRakeSkin = true
			end)
			local equipped = h.inventory:equip(1, "nestRake", "alienRakeSkin")
			expect(equipped.ok).toBe(true)
			expect(h.profile(1).data.inventory.equippedSkins.nestRake).toBe("alienRakeSkin")
			local view = h.inventory:view(1)
			local found
			for _, item in ipairs(view.items) do
				if item.id == "alienRakeSkin" then
					found = item
				end
			end
			expect(found.owned).toBe(true)
			expect(found.equipped).toBe(true)
			expect(h.inventory:equip(1, "nestRake", "alienRakeSkin").data.unchanged).toBe(true)
			expect(h.inventory.stats.equips).toBe(1)
		end)
	end)

	describe("Leaderboards", function()
		it("writes are bounded per player and board, never per feather, and rows are sanitized", function()
			local h = fresh()
			h.join(2)
			local boards = h.leaderboards
			h.profile(1):update(function(data)
				data.progression.totalWins = 3
				data.progression.bestTimeMs.chapter1.normal = 120000
				data.stats.feathersCollected = 500
				data.stats.eggsFound = 3
			end)
			h.profile(2):update(function(data)
				data.progression.totalWins = 5
				data.progression.bestTimeMs.chapter1.normal = 90000
				data.stats.feathersCollected = 40
				data.stats.eggsFound = 5
			end)
			local written = boards:submit(1, boards:valuesFor(h.profile(1).data))
			expect(written).toBe(#cfg.leaderboards.boards)
			expect(boards:submit(1, boards:valuesFor(h.profile(1).data))).toBe(0)
			expect(boards.stats.skippedUnchanged).toBe(#cfg.leaderboards.boards)
			-- A changed value inside the write interval is deferred, not written.
			h.profile(1):update(function(data)
				data.stats.feathersCollected = 501
			end)
			expect(boards:submit(1, boards:valuesFor(h.profile(1).data))).toBe(0)
			expect(boards:pendingCount()).toBe(1)
			expect(h.leaderboardStore.writes).toBe(#cfg.leaderboards.boards)
			-- Simulated collecting between submits never touches the store.
			for _ = 1, 20 do
				h.profile(1):update(function(data)
					data.stats.feathersCollected += 1
				end)
			end
			expect(h.leaderboardStore.writes).toBe(#cfg.leaderboards.boards)
			h.clock:advance(cfg.leaderboards.writeMinIntervalSeconds)
			expect(boards:flushPending(false)).toBe(1)
			expect(h.leaderboardStore:peek("feathersCollected", "1")).toBe(501)
			-- Leaving forces the latest values out and forgets the player's history.
			boards:submit(2, boards:valuesFor(h.profile(2).data), true)
			boards:forget(2)
			expect(boards:pendingCount()).toBe(0)
			expect(boards:refresh()).toBe(true)
			local snapshot = boards:snapshot()
			expect(#snapshot.boards).toBe(#cfg.leaderboards.boards)
			local wins, best
			for _, board in ipairs(snapshot.boards) do
				if board.id == "totalWins" then
					wins = board
				elseif board.id == "bestTimeChapter1Normal" then
					best = board
				end
			end
			expect(wins.rows[1].userId).toBe(2)
			expect(wins.rows[1].value).toBe(5)
			expect(wins.rows[1].name).toBe("P2")
			expect(best.ascending).toBe(true)
			expect(best.rows[1].userId).toBe(2)
			for _, board in ipairs(snapshot.boards) do
				for _, row in ipairs(board.rows) do
					local keys = 0
					for _ in pairs(row) do
						keys += 1
					end
					expect(keys).toBe(3)
				end
			end
			-- Refresh cadence: a tick inside the interval does not refresh again.
			expect(boards:tick()).toBe(false)
			h.clock:advance(cfg.leaderboards.refreshSeconds)
			expect(boards:tick()).toBe(true)
			expect(boards.stats.refreshes).toBe(2)
		end)
	end)

	describe("Profile projection", function()
		it("carries the daily evaluation, entitlement-backed slots, and extra stats without leaking", function()
			local h = fresh()
			h.setEntitlement(1, "extraClassSlot", true)
			local projection = h.playerData:buildProjection(1, cfg)
			expect(ProfileProjection.leaks(projection)).toBe(false)
			expect(projection.rewards.daily.status).toBe("ready")
			expect(projection.rewards.daily.dayIndex).toBe(1)
			expect(projection.classes.slotCount).toBe(2)
			expect(projection.classes.rollCount).toBe(0)
			expect(projection.stats.deaths).toBe(0)
			expect(projection.stats.cashEarnedLifetime).toBe(0)
			expect(projection.rewards.claimedCodes).toBeNil()
			expect(projection.rewards.lastDailyClaimTxId).toBeNil()
			h.rewards:claimDaily(1)
			local after = h.playerData:buildProjection(1, cfg)
			expect(after.rewards.daily.status).toBe("early")
			expect(after.rewards.dailyReady).toBe(false)
		end)
	end)
end
