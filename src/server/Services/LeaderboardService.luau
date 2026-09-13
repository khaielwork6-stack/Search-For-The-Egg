--!strict
-- Leaderboards (MASTER_SPEC 11 "Stats and leaderboards", ASSUMED A-META-08): bounded writes to an
-- ordered store and a bounded refresh cadence. Writes happen only on victory commits and on leave,
-- never per feather; per player and board a write is skipped when the value is unchanged and
-- deferred while the minimum write interval has not elapsed (the latest value wins at flush time).
-- Refresh fetches the configured top N per board and publishes a sanitized projection.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local Signal = require(Shared.Util.Signal)

local LeaderboardService = {}
LeaderboardService.__index = LeaderboardService

export type Board = { id: string, ascending: boolean, label: string, unit: string }

-- Board definitions keyed by the ids configured in leaderboards.boards. Unknown ids are refused at
-- construction so a config typo never creates an empty board silently.
local BOARDS: { [string]: Board } = {
	totalWins = { id = "totalWins", ascending = false, label = "Most Eggs Won", unit = "wins" },
	bestTimeChapter1Normal = { id = "bestTimeChapter1Normal", ascending = true, label = "Fastest Henhouse", unit = "ms" },
	feathersCollected = { id = "feathersCollected", ascending = false, label = "Feathers Gathered", unit = "feathers" },
	eggsFound = { id = "eggsFound", ascending = false, label = "Eggs Found", unit = "eggs" },
}

export type LeaderboardService = typeof(setmetatable(
	{} :: {
		_config: { [string]: any },
		_clock: any,
		_store: any,
		_getDisplayName: (userId: number) -> string,
		_log: any?,
		_boards: { Board },
		_lastWritten: { [number]: { [string]: { value: number, at: number } } },
		_pending: { [number]: { [string]: number } },
		_cache: { [string]: { { userId: number, name: string, value: number } } },
		_refreshedAt: number?,
		refreshed: any, -- (snapshot)
		stats: { writes: number, skippedUnchanged: number, deferred: number, refreshes: number, failures: number },
	},
	LeaderboardService
))

function LeaderboardService.new(options: {
	config: { [string]: any },
	clock: any,
	store: any,
	getDisplayName: (userId: number) -> string,
	log: any?,
}): LeaderboardService
	local boards = {}
	for _, id in ipairs(options.config.leaderboards.boards) do
		local board = BOARDS[id]
		assert(board, "LeaderboardService: unknown board id " .. tostring(id))
		table.insert(boards, board)
	end
	return setmetatable({
		_config = options.config,
		_clock = options.clock,
		_store = options.store,
		_getDisplayName = options.getDisplayName,
		_log = options.log,
		_boards = boards,
		_lastWritten = {},
		_pending = {},
		_cache = {},
		_refreshedAt = nil,
		refreshed = Signal.new(),
		stats = { writes = 0, skippedUnchanged = 0, deferred = 0, refreshes = 0, failures = 0 },
	}, LeaderboardService)
end

-- Values a profile contributes to each board (nil = nothing to submit for that board).
function LeaderboardService.valuesFor(self: LeaderboardService, data: { [string]: any }): { [string]: number }
	local out: { [string]: number } = {}
	for _, board in ipairs(self._boards) do
		if board.id == "totalWins" and data.progression.totalWins > 0 then
			out[board.id] = data.progression.totalWins
		elseif board.id == "bestTimeChapter1Normal" then
			local best = data.progression.bestTimeMs.chapter1 and data.progression.bestTimeMs.chapter1.normal
			if best then
				out[board.id] = best
			end
		elseif board.id == "feathersCollected" and data.stats.feathersCollected > 0 then
			out[board.id] = data.stats.feathersCollected
		elseif board.id == "eggsFound" and data.stats.eggsFound > 0 then
			out[board.id] = data.stats.eggsFound
		end
	end
	return out
end

local function write(self: LeaderboardService, userId: number, boardId: string, value: number, now: number): boolean
	local ok = self._store:setAsync(boardId, tostring(userId), value)
	if ok then
		self.stats.writes += 1
		self._lastWritten[userId] = self._lastWritten[userId] or {}
		self._lastWritten[userId][boardId] = { value = value, at = now }
	else
		self.stats.failures += 1
	end
	return ok
end

-- Submits the latest values for a player. Unchanged values are skipped; values inside the write
-- interval are deferred (latest wins) unless `force` (leave/shutdown). Returns writes performed.
function LeaderboardService.submit(self: LeaderboardService, userId: number, values: { [string]: number }, force: boolean?): number
	local now = self._clock:monotonic()
	local interval = self._config.leaderboards.writeMinIntervalSeconds
	local written = 0
	for boardId, value in pairs(values) do
		local last = self._lastWritten[userId] and self._lastWritten[userId][boardId]
		if last and last.value == value then
			self.stats.skippedUnchanged += 1
			continue
		end
		if not force and last and (now - last.at) < interval then
			self._pending[userId] = self._pending[userId] or {}
			self._pending[userId][boardId] = value
			self.stats.deferred += 1
			continue
		end
		if write(self, userId, boardId, value, now) then
			written += 1
			if self._pending[userId] then
				self._pending[userId][boardId] = nil
			end
		end
	end
	return written
end

-- Flushes deferred values whose interval has elapsed (or all of them when `force`).
function LeaderboardService.flushPending(self: LeaderboardService, force: boolean?): number
	local now = self._clock:monotonic()
	local interval = self._config.leaderboards.writeMinIntervalSeconds
	local written = 0
	for userId, boards in pairs(table.clone(self._pending)) do
		for boardId, value in pairs(table.clone(boards)) do
			local last = self._lastWritten[userId] and self._lastWritten[userId][boardId]
			if force or not last or (now - last.at) >= interval then
				if write(self, userId, boardId, value, now) then
					written += 1
				end
				boards[boardId] = nil
			end
		end
		if next(boards) == nil then
			self._pending[userId] = nil
		end
	end
	return written
end

-- Called on player leave: flush that player's deferred values and forget their write history.
function LeaderboardService.forget(self: LeaderboardService, userId: number)
	local pending = self._pending[userId]
	if pending then
		local now = self._clock:monotonic()
		for boardId, value in pairs(pending) do
			write(self, userId, boardId, value, now)
		end
		self._pending[userId] = nil
	end
	self._lastWritten[userId] = nil
end

-- Refreshes every board from the store. Returns true when every fetch succeeded.
function LeaderboardService.refresh(self: LeaderboardService): boolean
	local allOk = true
	local topCount = self._config.leaderboards.topCount
	for _, board in ipairs(self._boards) do
		local ok, entries = self._store:topAsync(board.id, board.ascending, topCount)
		if ok and entries then
			local rows = {}
			for _, entry in ipairs(entries) do
				local userId = tonumber(entry.key)
				if userId then
					table.insert(rows, { userId = userId, name = self._getDisplayName(userId), value = entry.value })
				end
			end
			self._cache[board.id] = rows
		else
			allOk = false
			self.stats.failures += 1
		end
	end
	self._refreshedAt = self._clock:monotonic()
	self.stats.refreshes += 1
	self.refreshed:Fire(self:snapshot())
	return allOk
end

-- Refreshes when the cadence has elapsed; flushes deferred writes. Returns whether a refresh ran.
function LeaderboardService.tick(self: LeaderboardService): boolean
	self:flushPending(false)
	local now = self._clock:monotonic()
	if self._refreshedAt == nil or (now - self._refreshedAt) >= self._config.leaderboards.refreshSeconds then
		self:refresh()
		return true
	end
	return false
end

-- Sanitized projection: board metadata plus cached rows (ids, display names, integer values).
function LeaderboardService.snapshot(self: LeaderboardService): { [string]: any }
	local boards = {}
	for _, board in ipairs(self._boards) do
		local rows = {}
		for index, row in ipairs(self._cache[board.id] or {}) do
			rows[index] = { userId = row.userId, name = row.name, value = row.value }
		end
		table.insert(boards, { id = board.id, label = board.label, unit = board.unit, ascending = board.ascending, rows = rows })
	end
	return {
		boards = boards,
		refreshSeconds = self._config.leaderboards.refreshSeconds,
		ageSeconds = if self._refreshedAt then math.floor(self._clock:monotonic() - self._refreshedAt) else nil,
	}
end

function LeaderboardService.pendingCount(self: LeaderboardService): number
	local n = 0
	for _, boards in pairs(self._pending) do
		for _ in pairs(boards) do
			n += 1
		end
	end
	return n
end

return LeaderboardService
