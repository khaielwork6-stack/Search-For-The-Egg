--!strict
-- Studio-only debug/test hooks. Enabled only when RunService:IsStudio() or the place is an
-- allowlisted private test place; callers must also be allowlisted when a user id is involved.
-- Exposed through `shared.SFE_Debug` for the command bar and the MCP verification protocol.
-- Never creates remotes; clients cannot reach these functions.

local RunService = game:GetService("RunService")
local DebugAllowlist = require(script.Parent.Parent.Deployment.DebugAllowlist)

local StudioDebug = {}

function StudioDebug.isEnabled(placeId: number): boolean
	if RunService:IsStudio() then
		return true
	end
	return table.find(DebugAllowlist.privateTestPlaceIds, placeId) ~= nil
end

function StudioDebug.isUserAllowed(userId: number): boolean
	if RunService:IsStudio() then
		return true
	end
	return table.find(DebugAllowlist.userIds, userId) ~= nil
end

-- Builds the hook table from the live service container. Every hook re-checks enablement.
function StudioDebug.install(container: any): any?
	if not StudioDebug.isEnabled(game.PlaceId) then
		return nil
	end
	local hooks = {}

	function hooks.status()
		return {
			buildLabel = container.buildInfo.buildLabel,
			configVersion = container.config.configVersion,
			activeProfiles = container.profiles:activeCount(),
			sessions = container.sessions:count(),
			parties = container.parties:count(),
			rounds = container.rounds:count(),
			remotes = container.registry and container.registry:remoteCount() or 0,
			profileStats = table.clone(container.profiles.stats),
			registryStats = table.clone(container.registry.core.stats),
			securityRejections = container.security.total,
			analytics = table.clone(container.analytics.stats),
			missingDeploymentIds = container.productMap:missingKeys(),
			dataStoreKind = container.dataStoreKind,
		}
	end

	function hooks.dumpProfile(userId: number)
		if not StudioDebug.isUserAllowed(userId) then
			return nil
		end
		local profile = container.profiles:get(userId)
		return profile
				and {
					data = profile.data,
					dirty = profile.dirty,
					issues = profile.issues,
					migrations = profile.migrationsApplied,
					saveCount = profile.saveCount,
				}
			or nil
	end

	function hooks.session(userId: number)
		return container.sessions:get(userId)
	end

	function hooks.projection(userId: number)
		return container.playerData:buildProjection(userId, container.config)
	end

	-- Resets the active profile to defaults in memory and saves (Studio test protocol A step 1).
	function hooks.resetProfile(userId: number)
		if not StudioDebug.isUserAllowed(userId) then
			return false
		end
		local profile = container.profiles:get(userId)
		if not profile then
			return false
		end
		local ProfileSchema = require(script.Parent.Parent.Data.ProfileSchema)
		profile:update(function(data)
			local fresh = ProfileSchema.default(container.clock:now())
			for key in pairs(data) do
				data[key] = nil
			end
			for key, value in pairs(fresh) do
				data[key] = value
			end
		end)
		return container.profiles:saveAsync(profile)
	end

	-- Simulates an additional player joining/leaving the LIVE server services (real ProfileStore,
	-- sessions, entitlements) with a player double. Proves separate profiles/locks per user in
	-- Play Solo, where Studio only provides one real Player. Studio-only.
	local simulatedPlayers: { [number]: any } = {}
	function hooks.simulatePlayerJoin(userId: number)
		if simulatedPlayers[userId] then
			return { error = "already_simulated" }
		end
		local double = {
			UserId = userId,
			Name = "Sim" .. tostring(userId),
			kicked = nil,
			Kick = function(self, message)
				self.kicked = message
			end,
			LoadCharacter = function() end,
		}
		simulatedPlayers[userId] = double
		local outcome = container.playerData:onPlayerAdded(double, container.config)
		local profile = container.profiles:get(userId)
		return {
			outcome = outcome,
			kicked = double.kicked,
			activeProfiles = container.profiles:activeCount(),
			sessions = container.sessions:count(),
			sessionPhase = container.sessions:get(userId) and container.sessions:get(userId).phase or nil,
			profileGems = profile and profile.data.currencies.gems or nil,
			profileKey = profile and profile.key or nil,
		}
	end
	function hooks.simulatePlayerLeave(userId: number)
		local double = simulatedPlayers[userId]
		if not double then
			return { error = "not_simulated" }
		end
		simulatedPlayers[userId] = nil
		local released = container.playerData:onPlayerRemoving(double)
		return { released = released, activeProfiles = container.profiles:activeCount(), sessions = container.sessions:count() }
	end
	-- Releases the live profile (final save + lock release) and loads it again through the real
	-- ProfileStore: proves persistence through the store without restarting Play (Studio memory
	-- store cannot survive a Play restart). Returns before/after snapshots of persistent fields.
	function hooks.reloadProfile(userId: number)
		if not StudioDebug.isUserAllowed(userId) then
			return { error = "not_allowed" }
		end
		local profile = container.profiles:get(userId)
		if not profile then
			return { error = "no_profile" }
		end
		local function summarize(data)
			return {
				gems = data.currencies.gems,
				totalWins = data.progression.totalWins,
				chapter1Normal = data.progression.chapterWins.chapter1.normal,
				bestMs = data.progression.bestTimeMs.chapter1.normal,
				hardUnlocked = data.progression.unlockedDifficulties.chapter1.hard,
				chapter2Unlocked = data.progression.unlockedChapters.chapter2,
				eggsFound = data.stats.eggsFound,
				tutorialCompleted = data.tutorial.completed,
			}
		end
		local before = summarize(profile.data)
		local released = container.profiles:releaseAsync(profile)
		local record = container.profileDataStore.peek and container.profileDataStore:peek(container.profiles:keyFor(userId)) or nil
		local reloaded = container.profiles:loadAsync(userId)
		local after = reloaded.profile and summarize(reloaded.profile.data) or nil
		return {
			released = released,
			lockClearedInStore = record ~= nil and record.lock == nil,
			before = before,
			after = after,
			roundActive = container.rounds:roundOf(userId) ~= nil,
		}
	end
	function hooks.round(userId: number)
		local runtime = container.rounds:roundOf(userId)
		if not runtime then
			return { active = false }
		end
		local PileGrid = require(game:GetService("ReplicatedStorage").Shared.Domain.PileGrid)
		return {
			active = true,
			phase = runtime.state.phase,
			removedFraction = PileGrid.removedFraction(runtime.grid),
			eggDepthFraction = runtime.eggDepthFraction,
			eggCoverCleared = runtime.eggCoverCleared,
			eggNode = runtime.eggNode.id,
			player = container.rounds:projectPlayer(runtime.state.roundId, userId),
			elapsedMs = container.rounds:project(runtime.state.roundId).elapsedMs,
			collection = table.clone(container.collection.stats),
			selling = table.clone(container.selling.stats),
			upgrades = table.clone(container.upgrades.stats),
			egg = table.clone(container.egg.stats),
			victory = table.clone(container.victory.stats),
		}
	end
	function hooks.flushAll()
		return container.playerData:flushAll()
	end
	function hooks.dataStoreRecord(userId: number)
		local store = container.profileDataStore
		if not store or type(store.peek) ~= "function" then
			return { error = "not_inspectable" }
		end
		local record = store:peek(container.profiles:keyFor(userId))
		return record
				and {
					hasLock = record.lock ~= nil,
					lockJob = record.lock and record.lock.jobId,
					saveCount = record.meta and record.meta.saveCount,
					gems = record.data and record.data.currencies.gems,
				}
			or nil
	end

	function hooks.runTests(filter: string?)
		local TestRunner = require(script.Parent.TestRunner)
		return TestRunner.run(filter)
	end

	-- Drives a full party -> round -> victory -> results -> lobby lifecycle for one user without
	-- gameplay (Phase 1 skeleton proof). Returns the phase trace.
	function hooks.simulateLifecycle(userId: number)
		if not StudioDebug.isUserAllowed(userId) then
			return nil
		end
		local trace = {}
		local function record(label: string)
			local session = container.sessions:get(userId)
			table.insert(trace, label .. ":" .. (session and session.phase or "none"))
		end
		record("start")
		local party, err = container.parties:create(userId, "chapter1", "normal")
		if not party then
			table.insert(trace, "party_create_failed:" .. tostring(err))
			return trace
		end
		record("party_created")
		local started, startErr = container.parties:start(userId, party.partyId)
		if not started then
			table.insert(trace, "party_start_failed:" .. tostring(startErr))
			return trace
		end
		record("countdown")
		-- Fast-forward: wait for the countdown to elapse then tick.
		task.wait(container.config.round.countdownSeconds + 0.1)
		container.parties:tick()
		record("reserved")
		local roundId = container.sessions:get(userId).roundId
		if not roundId then
			table.insert(trace, "no_round")
			return trace
		end
		container.rounds:voteSkip(roundId, userId)
		container.rounds:tick()
		record("cutscene_skipped")
		task.wait(container.config.round.countdownSeconds + 0.1)
		container.rounds:tick()
		table.insert(trace, "round:" .. container.rounds:get(roundId).phase)
		container.rounds:markEggRevealed(roundId)
		local claimed, claimErr = container.rounds:claim(roundId, userId, container.sessions:get(userId).sessionToken)
		table.insert(trace, "claim:" .. (claimed and claimed.phase or tostring(claimErr)))
		local results = container.rounds:commitAndFinish(roundId, function()
			return true
		end)
		table.insert(trace, "results:" .. (results and results.phase or "nil"))
		record("results")
		container.rounds:returnToLobby(roundId)
		record("returned")
		return trace
	end

	-- Phase 3 verification hooks. Every grant is labelled DEBUG in the server log and never touches a
	-- remote; they exist so the acceptance evidence can inject funds and entitlements deterministically.
	local function debugLog(label: string, props: { [string]: any })
		if container.log then
			container.log:warn("DEBUG_" .. label, props)
		else
			warn("[SFE][DEBUG_" .. label .. "]", game:GetService("HttpService"):JSONEncode(props))
		end
	end

	function hooks.debugGrantCash(userId: number, cents: number)
		if not StudioDebug.isUserAllowed(userId) then
			return nil
		end
		local runtime = container.rounds:roundOf(userId)
		local state = runtime and runtime.players[userId]
		if not state then
			return { error = "no_round" }
		end
		cents = math.floor(tonumber(cents) or 0)
		local before = state.cashCents
		state.cashCents = math.max(0, state.cashCents + cents)
		debugLog("GRANT_CASH", { userId = userId, cents = cents, before = before, after = state.cashCents })
		local player = container.playerData:playerOf(userId)
		if player and container.pushPreviews then
			container.pushPreviews(player)
		end
		return { before = before, after = state.cashCents }
	end

	function hooks.debugGrantGems(userId: number, gems: number)
		if not StudioDebug.isUserAllowed(userId) then
			return nil
		end
		local profile = container.profiles:get(userId)
		if not profile or not profile:isActive() then
			return { error = "no_profile" }
		end
		gems = math.floor(tonumber(gems) or 0)
		local before = profile.data.currencies.gems
		profile:update(function(data)
			data.currencies.gems = math.max(0, data.currencies.gems + gems)
		end)
		debugLog("GRANT_GEMS", { userId = userId, gems = gems, before = before, after = profile.data.currencies.gems })
		local player = container.playerData:playerOf(userId)
		if player then
			container.playerData:pushProjection(player, container.config)
		end
		return { before = before, after = profile.data.currencies.gems }
	end

	-- Debug class selection (server-owned profile mutation; the Gem roll is Phase 4).
	function hooks.setClasses(userId: number, classIdsCsv: string)
		if not StudioDebug.isUserAllowed(userId) then
			return nil
		end
		local profile = container.profiles:get(userId)
		if not profile or not profile:isActive() then
			return { error = "no_profile" }
		end
		local Config = require(game:GetService("ReplicatedStorage").Shared.Config)
		local ids = {}
		for id in string.gmatch(tostring(classIdsCsv or ""), "[%w_]+") do
			if not Config.class(container.config, id) then
				return { error = "unknown_class", id = id }
			end
			table.insert(ids, id)
		end
		if #ids > container.config.classes.maximumSlots then
			return { error = "too_many_slots", maximum = container.config.classes.maximumSlots }
		end
		profile:update(function(data)
			for _, id in ipairs(ids) do
				data.classes.owned[id] = true
			end
			data.classes.equipped = ids
			data.classes.slotCount = math.max(data.classes.slotCount or 1, #ids)
		end)
		debugLog("SET_CLASSES", { userId = userId, classes = ids })
		return { equipped = table.clone(profile.data.classes.equipped) }
	end

	-- Mock entitlement adapter: overrides pass ownership for one user until the server restarts.
	function hooks.setEntitlement(userId: number, key: string, owned: boolean)
		if not StudioDebug.isUserAllowed(userId) then
			return nil
		end
		container.debugEntitlements[userId] = container.debugEntitlements[userId] or {}
		container.debugEntitlements[userId][key] = owned == true or owned == "true"
		debugLog("SET_ENTITLEMENT", { userId = userId, key = key, owned = container.debugEntitlements[userId][key] })
		return table.clone(container.debugEntitlements[userId])
	end

	function hooks.grantWins(userId: number, wins: number)
		if not StudioDebug.isUserAllowed(userId) then
			return nil
		end
		local profile = container.profiles:get(userId)
		if not profile or not profile:isActive() then
			return { error = "no_profile" }
		end
		wins = math.floor(tonumber(wins) or 0)
		profile:update(function(data)
			data.progression.totalWins = (data.progression.totalWins or 0) + wins
			data.progression.chapterWins.chapter1.normal = (data.progression.chapterWins.chapter1.normal or 0) + wins
		end)
		debugLog("GRANT_WINS", { userId = userId, wins = wins, total = profile.data.progression.totalWins })
		return { wins = profile.data.progression.totalWins, progression = container.playerData:getProgression(userId) }
	end

	-- One-round tool grant (the same interface a Phase 5 receipt uses).
	function hooks.grantTool(userId: number, toolId: string)
		if not StudioDebug.isUserAllowed(userId) then
			return nil
		end
		local ok = container.tools:grantOneRound(userId, toolId, "debug")
		debugLog("GRANT_TOOL", { userId = userId, toolId = toolId, ok = ok })
		local player = container.playerData:playerOf(userId)
		if ok and player and container.pushPreviews then
			container.pushPreviews(player)
		end
		return { ok = ok }
	end

	function hooks.tools(userId: number)
		local snapshot = container.tools:inspect(userId)
		if snapshot then
			local runtime = container.rounds:roundOf(userId)
			snapshot.previews = container.upgrades:previews(runtime.players[userId], runtime, userId)
			snapshot.cashCents = runtime.players[userId].cashCents
			snapshot.carried = runtime.players[userId].carriedStandard + runtime.players[userId].carriedRainbow
			snapshot.removedFraction = container.rounds:project(runtime.state.roundId).removedFraction
		end
		return snapshot
	end

	function hooks.pileRemaining(userId: number)
		local runtime = container.rounds:roundOf(userId)
		if not runtime then
			return nil
		end
		return { removed = runtime.grid.removed, total = runtime.grid.total, fraction = runtime.grid.removed / runtime.grid.total }
	end

	-- Phase 4 verification hooks: every action goes through the real services (never remotes); the
	-- group adapter mock and simulated party members are labelled DEBUG in Output.
	function hooks.rollClass(userId: number, slot: number?)
		if not StudioDebug.isUserAllowed(userId) then
			return nil
		end
		return container.classes:roll(userId, tonumber(slot) or 1)
	end
	function hooks.equipClass(userId: number, classId: string, slot: number?)
		if not StudioDebug.isUserAllowed(userId) then
			return nil
		end
		return container.classes:equip(userId, classId, tonumber(slot) or 1)
	end
	function hooks.classView(userId: number)
		return container.classes:view(userId)
	end
	function hooks.buyPerk(userId: number, perkId: string, expectedLevel: number?)
		if not StudioDebug.isUserAllowed(userId) then
			return nil
		end
		local profile = container.profiles:get(userId)
		local level = tonumber(expectedLevel) or (profile and profile.data.permanentPerks[perkId]) or 0
		return container.perks:purchase(userId, perkId, level)
	end
	function hooks.perkPreviews(userId: number)
		return container.perks:previews(userId)
	end
	function hooks.claimDaily(userId: number)
		if not StudioDebug.isUserAllowed(userId) then
			return nil
		end
		return container.rewards:claimDaily(userId)
	end
	-- Moves the profile's daily clock so the cadence cases (early / on time / grace / expired) can be
	-- exercised in one session. Labelled DEBUG; never touches remotes.
	function hooks.shiftDailyClock(userId: number, seconds: number)
		if not StudioDebug.isUserAllowed(userId) then
			return nil
		end
		local profile = container.profiles:get(userId)
		if not profile or not profile:isActive() then
			return { error = "no_profile" }
		end
		local delta = tonumber(seconds) or 0
		profile:update(function(data)
			if data.rewards.dailyLastClaimAt then
				data.rewards.dailyLastClaimAt -= delta
			end
			if data.rewards.dailyStreakStartedAt then
				data.rewards.dailyStreakStartedAt -= delta
			end
		end)
		debugLog("SHIFT_DAILY_CLOCK", { userId = userId, seconds = delta })
		return container.rewards:dailyEvaluation(profile.data)
	end
	function hooks.redeemCode(userId: number, code: string)
		if not StudioDebug.isUserAllowed(userId) then
			return nil
		end
		return container.rewards:redeemCode(userId, code)
	end
	function hooks.setGroupMember(userId: number, member: boolean)
		if not StudioDebug.isUserAllowed(userId) then
			return nil
		end
		local adapter = container.groupAdapter
		if adapter.kind ~= "mock" then
			return { error = "real_group_adapter" }
		end
		adapter:setConfigured(true)
		adapter:setMember(userId, member == true or member == "true")
		debugLog("SET_GROUP_MEMBER", { userId = userId, member = member == true or member == "true" })
		return { configured = adapter:isConfigured() }
	end
	function hooks.claimGroup(userId: number)
		if not StudioDebug.isUserAllowed(userId) then
			return nil
		end
		return container.rewards:claimGroupReward(userId)
	end
	function hooks.equipSkin(userId: number, category: string, itemId: string)
		if not StudioDebug.isUserAllowed(userId) then
			return nil
		end
		return container.inventory:equip(userId, category, itemId)
	end
	function hooks.grantSkin(userId: number, skinId: string)
		if not StudioDebug.isUserAllowed(userId) then
			return nil
		end
		local profile = container.profiles:get(userId)
		if not profile or not profile:isActive() then
			return { error = "no_profile" }
		end
		profile:update(function(data)
			data.inventory.toolSkins[skinId] = true
		end)
		debugLog("GRANT_SKIN", { userId = userId, skinId = skinId })
		local player = container.playerData:playerOf(userId)
		if player then
			container.playerData:pushProjection(player, container.config)
		end
		return container.inventory:view(userId)
	end
	function hooks.inventoryView(userId: number)
		return container.inventory:view(userId)
	end
	function hooks.leaderboards()
		container.leaderboards:refresh()
		local snapshot = container.leaderboards:snapshot()
		snapshot.stats = table.clone(container.leaderboards.stats)
		snapshot.pending = container.leaderboards:pendingCount()
		return snapshot
	end
	function hooks.partyList()
		return container.parties:openParties()
	end
	function hooks.party(userId: number)
		local state = container.parties:partyOf(userId)
		return state and container.parties:project(state) or { inParty = false }
	end
	-- Simulated members drive the real PartyService through their live sessions (player doubles).
	function hooks.simJoinParty(userId: number, partyId: string)
		local state, err = container.parties:join(userId, partyId)
		return { ok = state ~= nil, err = err, party = state and container.parties:project(state) or nil }
	end
	function hooks.simLeaveParty(userId: number)
		local state, err = container.parties:leave(userId)
		return { ok = state ~= nil, err = err, party = state and container.parties:project(state) or nil }
	end
	function hooks.metaStats()
		return {
			classes = table.clone(container.classes.stats),
			perks = table.clone(container.perks.stats),
			rewards = table.clone(container.rewards.stats),
			inventory = table.clone(container.inventory.stats),
			leaderboards = table.clone(container.leaderboards.stats),
			parties = container.parties:count(),
		}
	end

	-- selene: allow(global_usage)
	shared.SFE_Debug = hooks

	-- Bridge for the command bar / Studio MCP (a different Luau VM with its own `shared`):
	-- ServerStorage.SFE_DebugInvoke:Invoke("status") -> JSON string. Server-only, never replicated.
	local ServerStorage = game:GetService("ServerStorage")
	local HttpService = game:GetService("HttpService")
	local bridge = ServerStorage:FindFirstChild("SFE_DebugInvoke") or Instance.new("BindableFunction")
	bridge.Name = "SFE_DebugInvoke"
	bridge.Parent = ServerStorage
	bridge.OnInvoke = function(name: string, ...)
		local hook = hooks[name]
		if type(hook) ~= "function" then
			return HttpService:JSONEncode({ error = "unknown_hook", name = name })
		end
		local ok, result = pcall(hook, ...)
		if not ok then
			return HttpService:JSONEncode({ error = "hook_failed", name = name, message = tostring(result) })
		end
		return HttpService:JSONEncode(result)
	end
	return hooks
end

return StudioDebug
