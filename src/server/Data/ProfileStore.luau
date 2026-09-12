--!strict
-- Profile adapter: session locking, defaults, reconciliation, migrations, dirty tracking,
-- autosave ticks, shutdown flush, and a load-failure hold state that NEVER produces a writable
-- default profile. All I/O goes through the injected DataStore adapter; time through the clock;
-- sleeping through the injected `wait` so tests run instantly.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TableUtil = require(ReplicatedStorage.Shared.Util.TableUtil)
local ProfileSchema = require(script.Parent.ProfileSchema)
local Migrations = require(script.Parent.Migrations)
local ServerPolicy = require(script.Parent.Parent.ServerPolicy)

local ProfileStore = {}
ProfileStore.__index = ProfileStore

local Profile = {}
Profile.__index = Profile

export type Profile = typeof(setmetatable(
	{} :: {
		userId: number,
		key: string,
		data: { [string]: any },
		dirty: boolean,
		active: boolean,
		lockLost: boolean,
		loadedAt: number,
		saveCount: number,
		issues: { string },
		migrationsApplied: { string },
		_store: any,
	},
	Profile
))

export type LoadResult = { profile: Profile?, reason: string? }

export type ProfileStore = typeof(setmetatable(
	{} :: {
		_dataStore: any,
		_clock: any,
		_config: { [string]: any },
		_jobId: string,
		_wait: (seconds: number) -> (),
		_log: any,
		_active: { [number]: Profile },
		_policy: typeof(ServerPolicy),
		stats: { loads: number, loadFailures: number, saves: number, saveFailures: number, releases: number, lockConflicts: number },
	},
	ProfileStore
))

export type Options = {
	dataStore: any,
	clock: any,
	config: { [string]: any },
	jobId: string,
	wait: ((seconds: number) -> ())?,
	log: any?,
	policy: { [string]: any }?,
}

function ProfileStore.new(options: Options): ProfileStore
	return setmetatable({
		_dataStore = options.dataStore,
		_clock = options.clock,
		_config = options.config,
		_jobId = options.jobId,
		_wait = options.wait or function(seconds: number)
			task.wait(seconds)
		end,
		_log = options.log,
		_active = {},
		_policy = (options.policy or ServerPolicy) :: any,
		stats = { loads = 0, loadFailures = 0, saves = 0, saveFailures = 0, releases = 0, lockConflicts = 0 },
	}, ProfileStore)
end

function ProfileStore.keyFor(self: ProfileStore, userId: number): string
	return self._policy.profileKeyPrefix .. tostring(userId)
end

local function log(self: ProfileStore, level: string, code: string, fields: { [string]: any }?)
	if self._log then
		self._log[level](self._log, code, fields)
	end
end

local function backoff(self: ProfileStore, attempt: number): number
	local base = self._policy.loadBackoffBaseSeconds * (2 ^ (attempt - 1))
	return math.min(self._policy.loadBackoffMaxSeconds, base)
end

-- Load with session lock. Returns { profile } on success or { reason = "locked" | "unavailable" }.
function ProfileStore.loadAsync(self: ProfileStore, userId: number): LoadResult
	assert(not self._active[userId], "ProfileStore: profile already active for user " .. tostring(userId))
	local key = self:keyFor(userId)
	local attempts = self._policy.loadAttempts
	local lastReason = "unavailable"

	for attempt = 1, attempts do
		local now = self._clock:now()
		local outcome = "unknown"
		local ok, record = self._dataStore:updateAsync(key, function(existing: any): any
			if type(existing) ~= "table" then
				-- Brand-new account: create a default profile owned by this server.
				outcome = "created"
				return {
					data = ProfileSchema.default(now),
					lock = { jobId = self._jobId, lockedAt = now },
					meta = { saveCount = 0 },
				}
			end
			local lock = existing.lock
			if
				type(lock) == "table"
				and lock.jobId ~= self._jobId
				and type(lock.lockedAt) == "number"
				and (now - lock.lockedAt) < self._policy.sessionLockTimeoutSeconds
			then
				outcome = "locked"
				return nil -- abort write; another live server owns this profile
			end
			outcome = "acquired"
			existing.lock = { jobId = self._jobId, lockedAt = now }
			return existing
		end)

		if ok and (outcome == "created" or outcome == "acquired") and type(record) == "table" then
			self.stats.loads += 1
			local raw = record.data
			local migrated, applied = Migrations.apply(TableUtil.deepCopy(raw), now)
			local reconciled, issues = ProfileSchema.reconcile(migrated, self._config, now)
			local profile = setmetatable({
				userId = userId,
				key = key,
				data = reconciled,
				dirty = #applied > 0 or #issues > 0 or outcome == "created",
				active = true,
				lockLost = false,
				loadedAt = now,
				saveCount = type(record.meta) == "table" and record.meta.saveCount or 0,
				issues = issues,
				migrationsApplied = applied,
				_store = self,
			}, Profile)
			self._active[userId] = profile
			log(
				self,
				"info",
				"profile_loaded",
				{ userId = userId, created = outcome == "created", migrations = #applied, issues = #issues, attempt = attempt }
			)
			return { profile = profile }
		end

		if ok and outcome == "locked" then
			lastReason = "locked"
			self.stats.lockConflicts += 1
			log(self, "warn", "profile_lock_conflict", { userId = userId, attempt = attempt })
		else
			lastReason = "unavailable"
			log(self, "warn", "profile_load_failed", { userId = userId, attempt = attempt })
		end
		if attempt < attempts then
			self._wait(backoff(self, attempt))
		end
	end

	self.stats.loadFailures += 1
	log(self, "error", "profile_load_exhausted", { userId = userId, reason = lastReason })
	return { reason = lastReason }
end

-- Internal write. `release` clears the lock. Returns (ok, reason?).
local function writeAsync(self: ProfileStore, profile: Profile, release: boolean): (boolean, string?)
	if not profile.active then
		return false, "inactive"
	end
	if profile.lockLost then
		return false, "lock_lost"
	end
	local key = profile.key
	local snapshot = TableUtil.deepCopy(profile.data)
	local attempts = self._policy.saveAttempts
	for attempt = 1, attempts do
		local now = self._clock:now()
		snapshot.updatedAt = now
		local lost = false
		local ok, result = self._dataStore:updateAsync(key, function(existing: any): any
			if type(existing) ~= "table" or type(existing.lock) ~= "table" or existing.lock.jobId ~= self._jobId then
				lost = true
				return nil
			end
			existing.data = snapshot
			existing.meta = existing.meta or {}
			existing.meta.saveCount = (existing.meta.saveCount or 0) + 1
			if release then
				existing.lock = nil
			else
				existing.lock = { jobId = self._jobId, lockedAt = now }
			end
			return existing
		end)
		if ok and lost then
			profile.lockLost = true
			profile.active = false
			self._active[profile.userId] = nil
			self.stats.saveFailures += 1
			log(self, "error", "profile_lock_lost", { userId = profile.userId })
			return false, "lock_lost"
		end
		if ok then
			profile.data.updatedAt = now
			profile.dirty = false
			profile.saveCount += 1
			self.stats.saves += 1
			if type(result) == "table" and type(result.meta) == "table" then
				profile.saveCount = result.meta.saveCount
			end
			return true, nil
		end
		self.stats.saveFailures += 1
		log(self, "warn", "profile_save_failed", { userId = profile.userId, attempt = attempt, release = release })
		if attempt < attempts then
			self._wait(backoff(self, attempt))
		end
	end
	return false, "unavailable"
end

function ProfileStore.saveAsync(self: ProfileStore, profile: Profile): (boolean, string?)
	return writeAsync(self, profile, false)
end

-- Final save + lock release. The profile becomes inactive even when the write fails (the lock
-- times out on its own); dirty data is reported through the return so callers can alert.
function ProfileStore.releaseAsync(self: ProfileStore, profile: Profile): (boolean, string?)
	if not profile.active then
		return false, "inactive"
	end
	local ok, reason = writeAsync(self, profile, true)
	profile.active = false
	self._active[profile.userId] = nil
	self.stats.releases += 1
	log(self, "info", "profile_released", { userId = profile.userId, ok = ok })
	return ok, reason
end

-- Saves every dirty active profile once. Returns counts.
function ProfileStore.autosaveTick(self: ProfileStore): { attempted: number, saved: number }
	local attempted, saved = 0, 0
	for _, profile in pairs(table.clone(self._active)) do
		if profile.dirty and profile.active then
			attempted += 1
			if self:saveAsync(profile) then
				saved += 1
			end
		end
	end
	return { attempted = attempted, saved = saved }
end

-- Shutdown flush: releases every active profile. Returns the number released cleanly.
function ProfileStore.flushAll(self: ProfileStore): { released: number, failed: number }
	local released, failed = 0, 0
	for _, profile in pairs(table.clone(self._active)) do
		if self:releaseAsync(profile) then
			released += 1
		else
			failed += 1
		end
	end
	return { released = released, failed = failed }
end

function ProfileStore.get(self: ProfileStore, userId: number): Profile?
	return self._active[userId]
end

function ProfileStore.activeCount(self: ProfileStore): number
	return TableUtil.count(self._active)
end

function ProfileStore.jobId(self: ProfileStore): string
	return self._jobId
end

-- Profile methods ------------------------------------------------------------------------------

function Profile.markDirty(self: Profile)
	self.dirty = true
end

-- Applies a mutation to the data under the "server only" rule; marks dirty. Returns fn's result.
function Profile.update(self: Profile, fn: (data: { [string]: any }) -> any): any
	assert(self.active, "Profile is not active")
	local result = fn(self.data)
	self.dirty = true
	return result
end

function Profile.isActive(self: Profile): boolean
	return self.active and not self.lockLost
end

ProfileStore.Profile = Profile

return ProfileStore
