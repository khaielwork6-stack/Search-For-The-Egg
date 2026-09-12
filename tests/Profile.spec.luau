--!nocheck
-- Profile schema defaults/reconciliation, migrations, and the ProfileStore session-lock lifecycle
-- with injected mock DataStore, fake clock, and no-op waits.

return function(describe, it, expect)
	local ServerStorage = game:GetService("ServerStorage")
	local Shared = game:GetService("ReplicatedStorage").Shared
	local Server = game:GetService("ServerScriptService").Server
	local Config = require(Shared.Config)
	local Clock = require(Shared.Clock)
	local TableUtil = require(Shared.Util.TableUtil)
	local ProfileSchema = require(Server.Data.ProfileSchema)
	local Migrations = require(Server.Data.Migrations)
	local MockDataStore = require(Server.Data.MockDataStore)
	local ProfileStore = require(Server.Data.ProfileStore)
	local Log = require(Server.Log)
	local cfg = Config.fromRaw(require(ServerStorage.SFE.SystemConfig))

	local function newStore(dataStore, jobId, clock)
		local log = Log.capture("test")
		return ProfileStore.new({
			dataStore = dataStore,
			clock = clock or Clock.fake(1000),
			config = cfg,
			jobId = jobId or "jobA",
			wait = function() end,
			log = log,
		})
	end

	describe("ProfileSchema", function()
		it("default matches DATASTORE_SCHEMA defaults", function()
			local d = ProfileSchema.default(50)
			expect(d.schemaVersion).toBe(1)
			expect(d.currencies).toEqual({ gems = 0, eventTokens = 0 })
			expect(d.classes.equipped).toEqual({ "newcomer" })
			expect(d.progression.unlockedChapters).toEqual({ chapter1 = true, chapter2 = false })
			expect(d.inventory.equippedSkins.nestRake).toBe("defaultRake")
			expect(d.settings.qualityMode).toBe("auto")
			expect(d.pendingTransactions).toEqual({})
		end)

		it("empty/non-table input reconciles to default", function()
			local profile, issues = ProfileSchema.reconcile(nil, cfg, 10)
			expect(profile.currencies.gems).toBe(0)
			expect(#issues).toBeGreaterThan(0)
			local fromEmpty = ProfileSchema.reconcile({}, cfg, 10)
			expect(fromEmpty.classes.equipped).toEqual({ "newcomer" })
		end)

		it("clamps currencies, levels, volumes, and slot counts", function()
			local raw = ProfileSchema.default(10)
			raw.currencies.gems = cfg.currencies.gems.maximum + 100
			raw.currencies.eventTokens = -5
			raw.permanentPerks.bagSize = 99
			raw.settings.musicVolume = 4
			raw.classes.slotCount = 10
			raw.rewards.dailyIndex = 40
			local profile = ProfileSchema.reconcile(raw, cfg, 10)
			expect(profile.currencies.gems).toBe(cfg.currencies.gems.maximum)
			expect(profile.currencies.eventTokens).toBe(0)
			expect(profile.permanentPerks.bagSize).toBe(cfg.permanentPerks.bagSize.maxLevel)
			expect(profile.settings.musicVolume).toBe(1)
			expect(profile.classes.slotCount).toBe(cfg.classes.maximumSlots)
			expect(profile.rewards.dailyIndex).toBe(#cfg.dailyRewards)
		end)

		it("removes unknown class/skin ids and falls back equipped skins", function()
			local raw = ProfileSchema.default(10)
			raw.classes.owned.hackerClass = true
			raw.classes.equipped = { "hackerClass", "newcomer", "newcomer" }
			raw.inventory.toolSkins.goldenRake = true
			raw.inventory.equippedSkins.nestRake = "goldenRake"
			local profile = ProfileSchema.reconcile(raw, cfg, 10)
			expect(profile.classes.owned.hackerClass).toBeNil()
			expect(profile.classes.equipped).toEqual({ "newcomer" })
			expect(profile.inventory.toolSkins.goldenRake).toBeNil()
			expect(profile.inventory.equippedSkins.nestRake).toBe("defaultRake")
		end)

		it("keeps known event skins", function()
			local raw = ProfileSchema.default(10)
			raw.inventory.toolSkins.alienRakeSkin = true
			raw.inventory.equippedSkins.nestRake = "alienRakeSkin"
			local profile = ProfileSchema.reconcile(raw, cfg, 10)
			expect(profile.inventory.equippedSkins.nestRake).toBe("alienRakeSkin")
		end)

		it("recomputes unlocks from wins and never trusts stored booleans", function()
			local raw = ProfileSchema.default(10)
			raw.progression.unlockedChapters.chapter2 = true
			raw.progression.unlockedDifficulties.chapter1.hard = true
			local profile = ProfileSchema.reconcile(raw, cfg, 10)
			expect(profile.progression.unlockedChapters.chapter2).toBe(false)
			expect(profile.progression.unlockedDifficulties.chapter1.hard).toBe(false)
			raw.progression.chapterWins.chapter1.normal = 1
			profile = ProfileSchema.reconcile(raw, cfg, 10)
			expect(profile.progression.unlockedChapters.chapter2).toBe(true)
		end)

		it("repairs malformed fields and drops unknown top-level keys", function()
			local raw = ProfileSchema.default(10)
			raw.currencies = "nope"
			raw.settings.qualityMode = "ultra"
			raw.stats.eggsFound = 0 / 0
			raw.injectedCash = 1e9
			raw.migrationHistory = { "a", "a", 5 }
			local profile, issues = ProfileSchema.reconcile(raw, cfg, 10)
			expect(profile.currencies.gems).toBe(0)
			expect(profile.settings.qualityMode).toBe("auto")
			expect(profile.stats.eggsFound).toBe(0)
			expect(profile.injectedCash).toBeNil()
			expect(profile.migrationHistory).toEqual({ "a" })
			expect(#issues).toBeGreaterThan(3)
		end)

		it("does not mutate the input and produces no issues for a default profile", function()
			local raw = ProfileSchema.default(10)
			local snapshot = TableUtil.deepCopy(raw)
			local _, issues = ProfileSchema.reconcile(raw, cfg, 10)
			expect(issues).toEqual({})
			expect(TableUtil.deepEqual(raw, snapshot)).toBe(true)
		end)
	end)

	describe("Migrations", function()
		it("migrates a v0 profile once and is idempotent on re-run", function()
			local legacy = { gems = 42 }
			local migrated, applied = Migrations.apply(legacy, 5)
			expect(applied).toEqual({ "v0_to_v1_initial_profile" })
			expect(migrated.schemaVersion).toBe(1)
			expect(migrated.currencies.gems).toBe(42)
			local again, appliedAgain = Migrations.apply(migrated, 6)
			expect(appliedAgain).toEqual({})
			expect(again.migrationHistory).toEqual({ "v0_to_v1_initial_profile" })
		end)

		it("never reduces gems or owned cosmetics", function()
			local profile = ProfileSchema.default(1)
			profile.currencies.gems = 500
			profile.inventory.toolSkins.alienRakeSkin = true
			profile.schemaVersion = 0
			profile.migrationHistory = {}
			local migrated = Migrations.apply(profile, 2)
			expect(migrated.currencies.gems).toBe(500)
			expect(migrated.inventory.toolSkins.alienRakeSkin).toBe(true)
		end)

		it("applies nothing to an up-to-date profile", function()
			local _, applied = Migrations.apply(ProfileSchema.default(1), 2)
			expect(applied).toEqual({})
			expect(Migrations.latestVersion()).toBe(ProfileSchema.SCHEMA_VERSION)
		end)
	end)

	describe("ProfileStore", function()
		it("creates, locks, saves, and releases a new profile", function()
			local ds = MockDataStore.new("profiles")
			local store = newStore(ds)
			local result = store:loadAsync(7)
			expect(result.profile).toBeTruthy()
			local profile = result.profile
			expect(profile.dirty).toBe(true) -- created
			expect(store:activeCount()).toBe(1)
			local record = ds:peek(store:keyFor(7))
			expect(record.lock.jobId).toBe("jobA")
			profile:update(function(data)
				data.currencies.gems = 10
			end)
			expect(store:saveAsync(profile)).toBe(true)
			expect(profile.dirty).toBe(false)
			expect(ds:peek(store:keyFor(7)).data.currencies.gems).toBe(10)
			expect(store:releaseAsync(profile)).toBe(true)
			expect(ds:peek(store:keyFor(7)).lock).toBeNil()
			expect(store:activeCount()).toBe(0)
			expect(profile.active).toBe(false)
		end)

		it("session lock prevents two live writers", function()
			local ds = MockDataStore.new("profiles")
			local a = newStore(ds, "jobA")
			local b = newStore(ds, "jobB")
			local first = a:loadAsync(1)
			expect(first.profile).toBeTruthy()
			local second = b:loadAsync(1)
			expect(second.profile).toBeNil()
			expect(second.reason).toBe("locked")
			expect(b.stats.lockConflicts).toBeGreaterThan(0)
			a:releaseAsync(first.profile)
			local third = b:loadAsync(1)
			expect(third.profile).toBeTruthy()
		end)

		it("a stale lock from a dead server is taken over after the timeout", function()
			local ds = MockDataStore.new("profiles")
			local clock = Clock.fake(1000)
			local a = newStore(ds, "jobA", clock)
			a:loadAsync(1)
			local b = newStore(ds, "jobB", clock)
			expect(b:loadAsync(1).profile).toBeNil()
			clock:advance(1000)
			expect(b:loadAsync(1).profile).toBeTruthy()
		end)

		it("failed initial load never starts a writable default profile", function()
			local ds = MockDataStore.new("profiles")
			ds:failNext(100)
			local store = newStore(ds)
			local result = store:loadAsync(3)
			expect(result.profile).toBeNil()
			expect(result.reason).toBe("unavailable")
			expect(store:activeCount()).toBe(0)
			expect(ds:keyCount()).toBe(0)
			expect(store.stats.loadFailures).toBe(1)
		end)

		it("transient load failure recovers on retry", function()
			local ds = MockDataStore.new("profiles")
			ds:failNext(2)
			local store = newStore(ds)
			local result = store:loadAsync(3)
			expect(result.profile).toBeTruthy()
			expect(ds.calls.failed).toBe(2)
		end)

		it("save failure keeps the profile dirty and succeeds later", function()
			local ds = MockDataStore.new("profiles")
			local store = newStore(ds)
			local profile = store:loadAsync(9).profile
			profile:update(function(data)
				data.currencies.gems = 77
			end)
			ds:failNext(10)
			expect(store:saveAsync(profile)).toBe(false)
			expect(profile.dirty).toBe(true)
			expect(ds:peek(store:keyFor(9)).data.currencies.gems).toBe(0)
			ds:failNext(0)
			expect(store:saveAsync(profile)).toBe(true)
			expect(ds:peek(store:keyFor(9)).data.currencies.gems).toBe(77)
		end)

		it("lost lock stops further writes", function()
			local ds = MockDataStore.new("profiles")
			local clock = Clock.fake(1000)
			local a = newStore(ds, "jobA", clock)
			local profile = a:loadAsync(5).profile
			clock:advance(1000)
			local b = newStore(ds, "jobB", clock)
			expect(b:loadAsync(5).profile).toBeTruthy()
			profile:update(function(data)
				data.currencies.gems = 1
			end)
			local ok, reason = a:saveAsync(profile)
			expect(ok).toBe(false)
			expect(reason).toBe("lock_lost")
			expect(profile.lockLost).toBe(true)
			expect(a:activeCount()).toBe(0)
			expect(ds:peek(a:keyFor(5)).data.currencies.gems).toBe(0)
		end)

		it("loads, migrates, and reconciles a legacy record and marks it dirty", function()
			local ds = MockDataStore.new("profiles")
			local store = newStore(ds)
			ds:seed(store:keyFor(11), { data = { gems = 12, junk = true }, meta = { saveCount = 3 } })
			local profile = store:loadAsync(11).profile
			expect(profile.data.currencies.gems).toBe(12)
			expect(profile.migrationsApplied).toEqual({ "v0_to_v1_initial_profile" })
			expect(profile.dirty).toBe(true)
			expect(profile.saveCount).toBe(3)
		end)

		it("autosave saves only dirty profiles and flushAll releases everything", function()
			local ds = MockDataStore.new("profiles")
			local store = newStore(ds)
			local p1 = store:loadAsync(1).profile
			local p2 = store:loadAsync(2).profile
			store:saveAsync(p1)
			store:saveAsync(p2)
			p2:update(function(data)
				data.currencies.gems = 3
			end)
			local tick = store:autosaveTick()
			expect(tick.attempted).toBe(1)
			expect(tick.saved).toBe(1)
			local flush = store:flushAll()
			expect(flush.released).toBe(2)
			expect(store:activeCount()).toBe(0)
			expect(ds:peek(store:keyFor(1)).lock).toBeNil()
			expect(ds:peek(store:keyFor(2)).lock).toBeNil()
		end)

		it("refuses to load the same user twice on one server", function()
			local ds = MockDataStore.new("profiles")
			local store = newStore(ds)
			store:loadAsync(1)
			expect(function()
				store:loadAsync(1)
			end).toThrow()
		end)
	end)
end
