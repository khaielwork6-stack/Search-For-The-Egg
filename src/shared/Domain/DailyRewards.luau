--!strict
-- Pure daily-reward timing (MASTER_SPEC 11 "Daily rewards", ASSUMED A-META-01..03). Server time only.
-- State lives in profile.rewards: dailyIndex (1..N, the NEXT day to claim), dailyLastClaimAt,
-- dailyStreakStartedAt. Evaluation never mutates; `apply` returns the new reward state.

local DailyRewards = {}

export type RewardState = { dailyIndex: number, dailyLastClaimAt: number?, dailyStreakStartedAt: number? }

export type Evaluation = {
	status: "ready" | "early" | "reset", -- reset = grace expired; the claim restarts at day 1
	dayIndex: number, -- day that a claim right now would grant
	gems: number,
	nextClaimInSeconds: number, -- 0 when ready
	graceRemainingSeconds: number, -- seconds left before the streak resets (0 when reset/never claimed)
	streakStartedAt: number?,
}

local function dayCount(cfg: { [string]: any }): number
	return #cfg.dailyRewards
end

function DailyRewards.evaluate(cfg: { [string]: any }, state: RewardState, now: number): Evaluation
	local rules = cfg.dailyRewardRules
	local last = state.dailyLastClaimAt
	local index = math.clamp(state.dailyIndex or 1, 1, dayCount(cfg))
	if last == nil then
		return {
			status = "ready",
			dayIndex = index,
			gems = cfg.dailyRewards[index].gems,
			nextClaimInSeconds = 0,
			graceRemainingSeconds = 0,
			streakStartedAt = state.dailyStreakStartedAt,
		}
	end
	local elapsed = now - last
	if elapsed < rules.claimCooldownSeconds then
		return {
			status = "early",
			dayIndex = index,
			gems = cfg.dailyRewards[index].gems,
			nextClaimInSeconds = math.ceil(rules.claimCooldownSeconds - elapsed),
			graceRemainingSeconds = math.max(0, math.ceil(rules.gracePeriodSeconds - elapsed)),
			streakStartedAt = state.dailyStreakStartedAt,
		}
	end
	if elapsed > rules.gracePeriodSeconds and rules.missPolicy == "reset_to_day1_after_grace" then
		return {
			status = "reset",
			dayIndex = 1,
			gems = cfg.dailyRewards[1].gems,
			nextClaimInSeconds = 0,
			graceRemainingSeconds = 0,
			streakStartedAt = nil,
		}
	end
	return {
		status = "ready",
		dayIndex = index,
		gems = cfg.dailyRewards[index].gems,
		nextClaimInSeconds = 0,
		graceRemainingSeconds = math.max(0, math.ceil(rules.gracePeriodSeconds - elapsed)),
		streakStartedAt = state.dailyStreakStartedAt,
	}
end

-- Next state after claiming `evaluation.dayIndex` at `now`.
function DailyRewards.apply(cfg: { [string]: any }, evaluation: Evaluation, now: number): RewardState
	local rules = cfg.dailyRewardRules
	local nextIndex = evaluation.dayIndex + 1
	if nextIndex > dayCount(cfg) then
		nextIndex = if rules.afterDay8 == "loop_to_day1" then 1 else dayCount(cfg)
	end
	return {
		dailyIndex = nextIndex,
		dailyLastClaimAt = now,
		dailyStreakStartedAt = if evaluation.dayIndex == 1 then now else (evaluation.streakStartedAt or now),
	}
end

-- Idempotency key for one claim: the streak it belongs to plus the day claimed.
function DailyRewards.transactionKey(evaluation: Evaluation, now: number): string
	local streak = if evaluation.dayIndex == 1 then now else (evaluation.streakStartedAt or now)
	return string.format("daily:%d:%d", math.floor(streak), evaluation.dayIndex)
end

-- Client-safe calendar view (amounts from config, claimed flags from the index).
function DailyRewards.calendar(
	cfg: { [string]: any },
	evaluation: Evaluation
): { { day: number, gems: number, claimed: boolean, current: boolean } }
	local out = {}
	for _, entry in ipairs(cfg.dailyRewards) do
		table.insert(out, {
			day = entry.day,
			gems = entry.gems,
			claimed = entry.day < evaluation.dayIndex,
			current = entry.day == evaluation.dayIndex,
		})
	end
	return out
end

return DailyRewards
