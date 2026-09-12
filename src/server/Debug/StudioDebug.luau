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
