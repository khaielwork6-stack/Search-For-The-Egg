--!strict
-- Daily quests: which three a player has today, how far along each one is, and when the set rolls
-- over. Pure, so the whole thing is unit-tested without a server.
--
-- The three are drawn deterministically from the player and the day rather than stored, so a rejoin,
-- a server hop or a rollback all show the same three, and nothing has to be written when a day turns.
-- Only progress and claims are persisted.

local DailyQuests = {}

export type Quest = { id: string, metric: string, target: number, gems: number, title: string, detail: string }
export type View = {
	id: string,
	title: string,
	detail: string,
	metric: string,
	target: number,
	gems: number,
	progress: number,
	fraction: number,
	complete: boolean,
	claimed: boolean,
}

-- Which day bucket a timestamp falls in. Buckets are whole `resetSeconds` since the epoch, so every
-- player in the world rolls over at the same instant and nobody can farm a reset by rejoining.
function DailyQuests.dayIndex(nowSeconds: number, resetSeconds: number): number
	return math.floor(nowSeconds / math.max(1, resetSeconds))
end

function DailyQuests.secondsUntilReset(nowSeconds: number, resetSeconds: number): number
	local span = math.max(1, resetSeconds)
	return span - (nowSeconds % span)
end

-- A stable scramble of two integers. Same inputs, same order, on every machine.
local function hash(a: number, b: number): number
	local x = (a * 73856093 + b * 19349663) % 2147483647
	x = (x * 1103515245 + 12345) % 2147483647
	return x / 2147483647
end

-- The player's quests for a day: `slots` distinct entries drawn from the pool. Drawing without
-- replacement keeps two copies of the same objective off one board.
function DailyQuests.select(config: { [string]: any }, userId: number, dayIndex: number): { Quest }
	local settings = config.dailyQuests
	local pool: { Quest } = settings.pool
	local wanted = math.clamp(settings.slots, 1, #pool)
	local remaining: { Quest } = table.clone(pool)
	local chosen: { Quest } = {}
	for slot = 1, wanted do
		local roll = hash(userId + slot * 7919, dayIndex)
		local index = math.clamp(math.floor(roll * #remaining) + 1, 1, #remaining)
		table.insert(chosen, remaining[index])
		table.remove(remaining, index)
	end
	return chosen
end

-- The idempotency key for a claim. Tied to the day, so yesterday's claim cannot pay again today and
-- a retry of today's cannot pay twice.
function DailyQuests.transactionKey(userId: number, dayIndex: number, questId: string): string
	return string.format("quest:%d:%d:%s", userId, dayIndex, questId)
end

-- What the client draws. `state` is the persisted `{ day, progress, claimed }` record; a state from a
-- previous day reads as zero progress rather than carrying yesterday's numbers forward.
function DailyQuests.view(config: { [string]: any }, state: { [string]: any }?, userId: number, nowSeconds: number): ({ View }, number)
	local settings = config.dailyQuests
	local day = DailyQuests.dayIndex(nowSeconds, settings.resetSeconds)
	local fresh = state == nil or (state :: any).day ~= day
	local progress: { [string]: number } = if fresh then {} else ((state :: any).progress or {})
	local claimed: { [string]: boolean } = if fresh then {} else ((state :: any).claimed or {})
	local out: { View } = {}
	for _, quest in ipairs(DailyQuests.select(config, userId, day)) do
		local done = math.max(0, progress[quest.id] or 0)
		local target = math.max(1, quest.target)
		table.insert(out, {
			id = quest.id,
			title = (string.gsub(quest.title, "{target}", tostring(quest.target))),
			detail = quest.detail,
			metric = quest.metric,
			target = target,
			gems = quest.gems,
			progress = math.min(done, target),
			fraction = math.clamp(done / target, 0, 1),
			complete = done >= target,
			claimed = claimed[quest.id] == true,
		})
	end
	return out, DailyQuests.secondsUntilReset(nowSeconds, settings.resetSeconds)
end

-- The quest on today's board with this id, or nil. Used by the server before paying a claim, so a
-- request naming a quest the player does not have is refused rather than trusted.
function DailyQuests.questFor(config: { [string]: any }, userId: number, dayIndex: number, questId: string): Quest?
	for _, quest in ipairs(DailyQuests.select(config, userId, dayIndex)) do
		if quest.id == questId then
			return quest
		end
	end
	return nil
end

return DailyQuests
