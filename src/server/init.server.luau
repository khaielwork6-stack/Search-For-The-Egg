--!strict
-- Server bootstrap for Search for the Egg. Composes adapters and services with explicit
-- dependency injection, publishes the client config projection, builds remotes, wires Roblox
-- player events, the same-place round flow (Phase 2 vertical slice), autosave, and shutdown flush.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Clock = require(Shared.Clock)
local WeightedRandom = require(Shared.WeightedRandom)
local ChapterLayout = require(Shared.Domain.ChapterLayout)
local AssetManifest = require(Shared.Design.AssetManifest)
local Objectives = require(Shared.Domain.Objectives)
local Envelope = require(Shared.Net.Envelope)
local RoundReducer = require(Shared.Reducers.RoundReducer)

local Log = require(script.Log)
local ServerPolicy = require(script.ServerPolicy)
local BuildInfo = require(script.BuildInfo)
local ProductIds = require(script.Deployment.ProductIds)
local ProductMap = require(script.Deployment.ProductMap)
local DataStoreAdapter = require(script.Data.DataStoreAdapter)
local MockDataStore = require(script.Data.MockDataStore)
local ProfileStore = require(script.Data.ProfileStore)
local ReceiptLedger = require(script.Data.ReceiptLedger)
local MarketplaceAdapter = require(script.Adapters.MarketplaceAdapter)
local TeleportAdapter = require(script.Adapters.TeleportAdapter)
local AnalyticsAdapter = require(script.Adapters.AnalyticsAdapter)
local RemoteRegistryCore = require(script.Net.RemoteRegistryCore)
local RemoteRegistry = require(script.Net.RemoteRegistry)
local AnalyticsService = require(script.Services.AnalyticsService)
local SecurityService = require(script.Services.SecurityService)
local EntitlementService = require(script.Services.EntitlementService)
local ReceiptService = require(script.Services.ReceiptService)
local SessionService = require(script.Services.SessionService)
local PartyService = require(script.Services.PartyService)
local RoundService = require(script.Services.RoundService)
local PlayerDataService = require(script.Services.PlayerDataService)
local WorldShellService = require(script.Services.WorldShellService)
local PartyPadService = require(script.Services.PartyPadService)
local ChapterShellService = require(script.Services.ChapterShellService)
local CollectionService = require(script.Services.CollectionService)
local SellingService = require(script.Services.SellingService)
local UpgradeService = require(script.Services.UpgradeService)
local ToolService = require(script.Services.ToolService)
local EggService = require(script.Services.EggService)
local VictoryService = require(script.Services.VictoryService)
local ObjectiveService = require(script.Services.ObjectiveService)
local ClassService = require(script.Services.ClassService)
local PerkService = require(script.Services.PerkService)
local RewardService = require(script.Services.RewardService)
local InventoryService = require(script.Services.InventoryService)
local LeaderboardService = require(script.Services.LeaderboardService)
local OrderedStoreAdapter = require(script.Adapters.OrderedStoreAdapter)
local GroupAdapter = require(script.Adapters.GroupAdapter)
local ClassRoll = require(Shared.Domain.ClassRoll)
local StudioDebug = require(script.Debug.StudioDebug)

local log = Log.new("Server")
local bootStarted = os.clock()

-- 1. Configuration: validate + freeze, publish the sanitized client projection.
local config = Config.get()
local existingRuntime = ReplicatedStorage:FindFirstChild(Config.RUNTIME_FOLDER_NAME)
local runtimeFolder: Folder
if existingRuntime and existingRuntime:IsA("Folder") then
	runtimeFolder = existingRuntime
else
	runtimeFolder = Instance.new("Folder")
	runtimeFolder.Name = Config.RUNTIME_FOLDER_NAME
	runtimeFolder.Parent = ReplicatedStorage
end
Config.publishClientProjection(runtimeFolder)

-- 2. Cross-cutting primitives.
local clock = Clock.real()
local function idGen(): string
	return HttpService:GenerateGUID(false)
end
local rng = WeightedRandom.fromFunction(function()
	return math.random()
end)
local productMap = ProductMap.new(config, ProductIds)
local security = SecurityService.new({ log = log, sampleRate = ServerPolicy.securityLogSampleRate })
-- Studio uses the counting adapter (Roblox AnalyticsService prints a line per event in Studio and
-- would flood Output); published servers use the real adapter.
local analyticsAdapter = if RunService:IsStudio() then AnalyticsAdapter.mock() else AnalyticsAdapter.real(Players)
local analytics = AnalyticsService.new({ adapter = analyticsAdapter, config = config, buildInfo = BuildInfo })

-- 3. Persistence. Studio without API access falls back to an in-memory store so Play Solo never
--    touches live data by accident; the choice is logged and shown in the debug status.
local dataStoreKind = "real"
local profileDataStore: any
local receiptDataStore: any
if RunService:IsStudio() and not DataStoreAdapter.isAvailable() then
	dataStoreKind = "studio-memory"
	profileDataStore = MockDataStore.new(ServerPolicy.profileStoreName)
	receiptDataStore = MockDataStore.new(ServerPolicy.receiptStoreName)
else
	profileDataStore = DataStoreAdapter.new(ServerPolicy.profileStoreName)
	receiptDataStore = DataStoreAdapter.new(ServerPolicy.receiptStoreName)
end
local profiles = ProfileStore.new({
	dataStore = profileDataStore,
	clock = clock,
	config = config,
	jobId = if game.JobId ~= "" then game.JobId else "studio-" .. idGen(),
	log = log,
	-- A Studio session that was closed mid-round leaves its lock behind; the next Studio session must
	-- not wait out the timeout (and get kicked) for a "server" that can never release it.
	stealLockPrefix = if RunService:IsStudio() then "studio-" else nil,
})
local receiptLedger = ReceiptLedger.new(receiptDataStore)

-- 4. Marketplace / entitlements / receipts.
local marketplace = MarketplaceAdapter.real()
local entitlements = EntitlementService.new({
	marketplace = marketplace,
	productMap = productMap,
	clock = clock,
	cacheSeconds = ServerPolicy.entitlementCacheSeconds,
})
local receipts = ReceiptService.new({
	productMap = productMap,
	profiles = profiles,
	receiptLedger = receiptLedger,
	clock = clock,
	log = log,
	analytics = analytics,
})
marketplace:bindProcessReceipt(function(receiptInfo)
	return receipts:processReceipt(receiptInfo)
end)

-- 5. Networking.
local core = RemoteRegistryCore.new({
	config = config,
	monotonic = function()
		return clock:monotonic()
	end,
	security = security,
	log = log,
})
local registry = RemoteRegistry.new(core, runtimeFolder, log)
local function send(player: any, name: string, payload: { [string]: any })
	-- Player doubles (Studio debug hooks, tests) are plain tables; only real Players receive remotes.
	if typeof(player) ~= "Instance" then
		return
	end
	registry:fireClient(name, player, payload)
end

-- 6. Sessions, player data, parties, rounds, gameplay services.
local sessions = SessionService.new({ idGen = idGen, clock = clock, log = log })
local playerData = PlayerDataService.new({
	profiles = profiles,
	sessions = sessions,
	entitlements = entitlements,
	clock = clock,
	policy = ServerPolicy,
	send = send,
	analytics = analytics,
	log = log,
})
local teleport: any = if productMap:placeId("chapter1") then TeleportAdapter.real(productMap) else TeleportAdapter.localAdapter(idGen)
local parties = PartyService.new({
	config = config,
	clock = clock,
	idGen = idGen,
	sessions = sessions,
	getProgression = function(userId)
		return playerData:getProgression(userId)
	end,
	teleport = teleport,
	analytics = analytics,
	log = log,
})
local rounds =
	RoundService.new({ config = config, clock = clock, idGen = idGen, rng = rng, sessions = sessions, analytics = analytics, log = log })

local function getCharacterPosition(userId: number): Vector3?
	local player = playerData:playerOf(userId)
	if not player or typeof(player) ~= "Instance" then
		return nil
	end
	local character = (player :: Player).Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return if root then (root :: BasePart).Position else nil
end
local function getProfileData(userId: number): any?
	local profile = profiles:get(userId)
	return profile and profile.data or nil
end
-- Verified entitlements (Roblox ownership through the adapter) merged with Studio-only debug overrides
-- (the mock entitlement adapter for Phase 3 verification; never active outside Studio/allowlist).
local debugEntitlements: { [number]: { [string]: boolean } } = {}
local function getEntitlements(userId: number): { [string]: boolean }
	local snapshot = entitlements:snapshot(userId)
	local overrides = debugEntitlements[userId]
	if overrides then
		for key, value in pairs(overrides) do
			snapshot[key] = value
		end
	end
	return snapshot
end
local collection = CollectionService.new({
	config = config,
	clock = clock,
	rounds = rounds,
	sessions = sessions,
	idGen = idGen,
	getCharacterPosition = getCharacterPosition,
	getProfileData = getProfileData,
	getEntitlements = getEntitlements,
	analytics = analytics,
})
local selling = SellingService.new({
	config = config,
	rounds = rounds,
	sessions = sessions,
	getCharacterPosition = getCharacterPosition,
	getProfileData = getProfileData,
	analytics = analytics,
})
local upgrades = UpgradeService.new({
	config = config,
	rounds = rounds,
	sessions = sessions,
	getCharacterPosition = getCharacterPosition,
	getProfileData = getProfileData,
	getProfile = function(userId)
		return profiles:get(userId)
	end,
	getEntitlements = getEntitlements,
	analytics = analytics,
})
local tools = ToolService.new({
	config = config,
	clock = clock,
	rounds = rounds,
	sessions = sessions,
	collection = collection,
	rng = rng,
	idGen = idGen,
	getCharacterPosition = getCharacterPosition,
	getEntitlements = getEntitlements,
	analytics = analytics,
	log = log,
})
local egg =
	EggService.new({ config = config, rounds = rounds, clock = clock, getCharacterPosition = getCharacterPosition, analytics = analytics })
local victory = VictoryService.new({
	config = config,
	clock = clock,
	rounds = rounds,
	getProfile = function(userId)
		return profiles:get(userId)
	end,
	saveProfile = function(profile)
		return profiles:saveAsync(profile)
	end,
	analytics = analytics,
	log = log,
})
local objectives = ObjectiveService.new({
	getProfile = function(userId)
		return profiles:get(userId)
	end,
	analytics = analytics,
})

-- 6b. Lobby / meta services (Phase 4): classes, perks, rewards, inventory, leaderboards.
local function getProfile(userId: number): any?
	return profiles:get(userId)
end
local classes = ClassService.new({
	config = config,
	clock = clock,
	rng = rng,
	sessions = sessions,
	getProfile = getProfile,
	getEntitlements = getEntitlements,
	analytics = analytics,
})
local perks = PerkService.new({ config = config, sessions = sessions, getProfile = getProfile, analytics = analytics })
local groupAdapter: any = if RunService:IsStudio() and not ProductIds.social.groupId
	then GroupAdapter.mock(false)
	else GroupAdapter.real(ProductIds.social.groupId, Players)
local rewards = RewardService.new({
	config = config,
	clock = clock,
	getProfile = getProfile,
	getEntitlements = getEntitlements,
	group = groupAdapter,
	analytics = analytics,
	log = log,
})
local inventory = InventoryService.new({ config = config, getProfile = getProfile, analytics = analytics })
local displayNames: { [number]: string } = {}
local function displayNameOf(userId: number): string
	local cached = displayNames[userId]
	if cached then
		return cached
	end
	local player = playerData:playerOf(userId)
	if player and typeof(player) == "Instance" then
		displayNames[userId] = (player :: Player).DisplayName
		return displayNames[userId]
	elseif player then
		displayNames[userId] = tostring(player.Name)
		return displayNames[userId]
	end
	local ok, name = pcall(function()
		return Players:GetNameFromUserIdAsync(userId)
	end)
	displayNames[userId] = if ok and type(name) == "string" then name else "Forager"
	return displayNames[userId]
end
local leaderboardStore: any = if dataStoreKind == "studio-memory"
	then OrderedStoreAdapter.mock()
	else OrderedStoreAdapter.real(ServerPolicy.globalStatsStoreName)
local leaderboards = LeaderboardService.new({
	config = config,
	clock = clock,
	store = leaderboardStore,
	getDisplayName = displayNameOf,
	log = log,
})
playerData:setProjectionExtras(function(userId, data)
	return {
		daily = rewards:dailyEvaluation(data),
		slotCount = ClassRoll.slotCount(config, getEntitlements(userId)),
	}
end)

-- 7. World: lobby shell and the Chapter 1 arena (same place; see ChapterLayout).
Players.CharacterAutoLoads = false
-- Repair mesh templates (mesh metadata) before any shell clones them; replicates to every client.
local repairedMeshes = AssetManifest.warm()
local lobbyShell = WorldShellService.build(workspace, workspace:FindFirstChildOfClass("SpawnLocation"), config)
local arena = ChapterShellService.build(workspace, config)
local mapMode = WorldShellService.isMapMode(lobbyShell)

-- Party nest pads (A-LOBBY-06): the map's "Join Match" nests form parties by standing on them.
local pads = PartyPadService.new({
	config = config,
	parties = parties,
	sessions = sessions,
	clock = clock,
	getCharacterPosition = function(userId)
		local player = playerData:playerOf(userId)
		local character = player and typeof(player) == "Instance" and (player :: Player).Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		return if root then (root :: BasePart).Position else nil
	end,
	players = function()
		local ids = {}
		for _, player in ipairs(Players:GetPlayers()) do
			table.insert(ids, player.UserId)
		end
		return ids
	end,
	setSign = function(index, text)
		if mapMode then
			WorldShellService.setPadSign(workspace, index, text)
		end
	end,
})
leaderboards.refreshed:Connect(function(snapshot)
	if mapMode then
		WorldShellService.applyLeaderboards(workspace, snapshot)
	end
end)

local function placeCharacter(player: Player, position: Vector3, lookAt: Vector3?)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root then
		local target = lookAt or (position + Vector3.new(0, 0, 1));
		(root :: BasePart).CFrame = CFrame.lookAt(position, Vector3.new(target.X, position.Y, target.Z))
	end
end

local function memberPlayers(members: { number }): { Player }
	local out = {}
	for _, userId in ipairs(members) do
		local player = playerData:playerOf(userId)
		if player and typeof(player) == "Instance" then
			table.insert(out, player :: Player)
		end
	end
	return out
end

local function sendObjective(userId: number)
	local player = playerData:playerOf(userId)
	if not player then
		return
	end
	local runtime = rounds:roundOf(userId)
	local step = objectives:roundObjective(userId, runtime ~= nil and runtime.state.phase == "EggRevealed")
	if runtime == nil and objectives:current(userId) == Objectives.COMPLETE then
		step = Objectives.COMPLETE
	end
	send(player, "ObjectiveChanged", { step = step, inRound = runtime ~= nil })
end

-- Player projection plus the resolved bag capacity (entitlements + class + level) for the HUD.
local function projectPlayerFor(roundId: string, userId: number): { [string]: any }?
	local projection = rounds:projectPlayer(roundId, userId)
	local runtime = rounds:runtime(roundId)
	if projection and runtime and runtime.players[userId] then
		local capacity = collection:bagCapacity(runtime, userId)
		projection.bagCapacity = capacity.capacity
		projection.bagInfinite = capacity.infinite
	end
	return projection
end

local function pushPreviews(player: Player)
	local runtime = rounds:roundOf(player.UserId)
	if not runtime then
		return
	end
	local state = runtime.players[player.UserId]
	send(player, "UpgradeResult", {
		previews = upgrades:previews(state, runtime, player.UserId),
		cashCents = state.cashCents,
		player = projectPlayerFor(runtime.state.roundId, player.UserId),
	})
end

-- Party -> round hand-off (local adapter) or real teleport.
parties.started:Connect(function(party, reservation)
	if reservation.isLocal then
		rounds:createForParty(party)
		parties:finish(party.partyId, true)
	else
		local ok = teleport:teleport(reservation, memberPlayers(party.members), { reservation = reservation.code, party = party.partyId })
		parties:finish(party.partyId, ok)
	end
end)
local function partyListPayload(): { [string]: any }
	local list = parties:openParties()
	for _, entry in ipairs(list) do
		entry.leaderName = displayNameOf(entry.leaderUserId)
	end
	return { parties = list }
end
local function broadcastPartyList()
	local payload = partyListPayload()
	for _, player in ipairs(Players:GetPlayers()) do
		local session = sessions:get(player.UserId)
		if session and (session.phase == "Lobby" or session.phase == "Party") then
			send(player, "PartyListProjection", payload)
		end
	end
end
parties.changed:Connect(function(party)
	local projection = parties:project(party)
	local names = {}
	for _, memberId in ipairs(party.members) do
		names[tostring(memberId)] = displayNameOf(memberId)
	end
	projection.memberNames = names
	for _, player in ipairs(memberPlayers(party.members)) do
		send(player, "PartyProjection", projection)
	end
	broadcastPartyList()
end)
sessions.changed:Connect(function(userId)
	local player = playerData:playerOf(userId)
	if player then
		playerData:pushSession(player)
	end
end)

-- Round created: move characters into the arena, send the full snapshot, objectives, previews.
rounds.created:Connect(function(state, runtime)
	-- Starting grants (permanent entitlements at max levels, class Scout Chick) before the first snapshot.
	tools:grantStartingTools(runtime)
	local layout = ChapterLayout[state.chapter]
	for _, player in ipairs(memberPlayers(state.members)) do
		placeCharacter(player, layout.spawn, layout.nestCenter)
		local snapshot = rounds:project(state.roundId, true) :: any
		snapshot.player = projectPlayerFor(state.roundId, player.UserId)
		send(player, "RoundSnapshot", snapshot)
		objectives:complete(player.UserId, "enter_party")
		sendObjective(player.UserId)
		pushPreviews(player)
	end
end)

-- Phase changes: lightweight snapshot (no pile) to every member; victory announcement.
rounds.changed:Connect(function(state)
	if state.phase == "Bootstrapping" then
		return
	end
	local runtime = rounds:runtime(state.roundId)
	if runtime and not RoundReducer.acceptsGameplay(state) then
		tools:onRoundEnded(runtime) -- live charges, vac heat, chick units, bundles end with gameplay
	end
	local projection = rounds:project(state.roundId, false)
	if not projection then
		return
	end
	for _, player in ipairs(memberPlayers(state.members)) do
		send(player, "RoundSnapshot", projection)
	end
	if state.phase == "Victory" and state.victory then
		local finder = playerData:playerOf(state.victory.finderUserId)
		local finderName = if finder and typeof(finder) == "Instance" then (finder :: Player).DisplayName else "A forager"
		for _, player in ipairs(memberPlayers(state.members)) do
			send(player, "VictoryStarted", {
				finderUserId = state.victory.finderUserId,
				finderName = finderName,
				elapsedMs = state.victory.elapsedMs,
				chapter = state.chapter,
				difficulty = state.difficulty,
			})
		end
	end
end)

rounds.deltaFlushed:Connect(function(roundId, delta)
	local state = rounds:get(roundId)
	if not state then
		return
	end
	for _, player in ipairs(memberPlayers(state.members)) do
		local payload = table.clone(delta)
		payload.player = projectPlayerFor(roundId, player.UserId)
		send(player, "RoundDelta", payload)
	end
end)

local function onFeathersAwarded(userId: number, runtime: any)
	if egg:checkReveal(runtime) then
		return
	end
	if
		objectives:current(userId) == "collect_25"
		and runtime.players[userId].contribution.feathersCollected >= config.collection.startingBagCapacity
	then
		objectives:complete(userId, "collect_25")
		sendObjective(userId)
	end
end
collection.collected:Connect(onFeathersAwarded)
tools.awarded:Connect(onFeathersAwarded)

-- Tool / bundle events: broadcast to the round (or one member when targeted).
local function broadcastToolEvent(roundId: string, payload: { [string]: any }, targetUserId: number?)
	local state = rounds:get(roundId)
	if not state then
		return
	end
	if targetUserId then
		local player = playerData:playerOf(targetUserId)
		if player then
			send(player, "ToolEvent", payload)
		end
		return
	end
	for _, player in ipairs(memberPlayers(state.members)) do
		send(player, "ToolEvent", payload)
	end
end
tools.event:Connect(broadcastToolEvent)
collection.event:Connect(broadcastToolEvent)
tools.deposited:Connect(function(userId, _runtime, sale)
	local player = playerData:playerOf(userId)
	if player then
		send(
			player,
			"ToolEvent",
			{ kind = "chick_deposit", userId = userId, cents = sale.finalCents, feathers = sale.feathers, cashCents = sale.cashCents }
		)
		pushPreviews(player :: Player)
	end
end)
upgrades.acquired:Connect(function(userId, runtime, toolId)
	broadcastToolEvent(runtime.state.roundId, { kind = "tools_granted", tools = { toolId }, userId = userId })
	-- Gem-priced acquisitions change the profile: refresh the client projection (currency chips).
	local player = playerData:playerOf(userId)
	if player and typeof(player) == "Instance" then
		playerData:pushProjection(player, config)
	end
end)

selling.sold:Connect(function(userId, runtime, sale)
	local player = playerData:playerOf(userId)
	if player then
		local payload = table.clone(sale)
		payload.player = projectPlayerFor(runtime.state.roundId, userId)
		send(player, "SaleResult", payload)
		pushPreviews(player :: Player)
	end
	if objectives:current(userId) == "sell_first_bag" then
		objectives:complete(userId, "sell_first_bag")
		sendObjective(userId)
	end
end)

upgrades.purchased:Connect(function(userId, runtime, result)
	local player = playerData:playerOf(userId)
	if player then
		local payload = table.clone(result)
		payload.player = projectPlayerFor(runtime.state.roundId, userId)
		send(player, "UpgradeResult", payload)
		local character = (player :: Player).Character
		if result.walkSpeed and character then
			local humanoid = character:FindFirstChildOfClass("Humanoid")
			if humanoid then
				humanoid.WalkSpeed = result.walkSpeed
			end
		end
		pushPreviews(player :: Player)
	end
	if objectives:current(userId) == "buy_first_upgrade" then
		objectives:complete(userId, "buy_first_upgrade")
		sendObjective(userId)
	end
end)

egg.revealed:Connect(function(runtime, position)
	ChapterShellService.spawnEgg(arena, position, config)
	for _, player in ipairs(memberPlayers(runtime.state.members)) do
		send(player, "EggRevealed", {
			x = position.X,
			y = position.Y,
			z = position.Z,
			coverCells = table.clone(runtime.eggNode.coverIndexes),
			roundId = runtime.state.roundId,
		})
		if objectives:current(player.UserId) == "search_for_egg" then
			objectives:complete(player.UserId, "search_for_egg")
		end
		sendObjective(player.UserId)
	end
end)

egg.claimed:Connect(function(runtime, userId)
	if objectives:current(userId) == "claim_or_complete_round" then
		objectives:complete(userId, "claim_or_complete_round")
	end
	victory:start(runtime.state.roundId)
end)

victory.committed:Connect(function(runtime, results)
	for _, player in ipairs(memberPlayers(runtime.state.members)) do
		local result = results[player.UserId]
		if result then
			send(player, "RewardsCommitted", { roundId = runtime.state.roundId, saved = result.saved })
			local finder = playerData:playerOf(result.finderUserId)
			local payload = table.clone(result)
			payload.finderName = if finder and typeof(finder) == "Instance" then (finder :: Player).DisplayName else "A forager"
			payload.roundId = runtime.state.roundId
			send(player, "ResultsProjection", payload)
			if objectives:current(player.UserId) == "claim_or_complete_round" then
				objectives:complete(player.UserId, "claim_or_complete_round")
			end
			playerData:pushProjection(player, config)
			local profile = profiles:get(player.UserId)
			if profile then
				leaderboards:submit(player.UserId, leaderboards:valuesFor(profile.data))
			end
		end
	end
end)

-- Round returned: characters back to the lobby, remove the Egg, refresh projections, replay.
rounds.returned:Connect(function(state, runtime)
	local eggPart = arena:FindFirstChild("SFE_Egg")
	if eggPart then
		eggPart:Destroy()
	end
	for _, player in ipairs(memberPlayers(state.members)) do
		placeCharacter(player, ChapterLayout.lobby.spawn, ChapterLayout.lobby.portal)
		send(player, "RoundSnapshot", {
			roundId = state.roundId,
			phase = "Returning",
			members = {},
			elapsedMs = 0,
			joinClosed = true,
			version = state.version,
			serverNowMs = clock:nowMs(),
		})
		playerData:pushProjection(player, config)
		sendObjective(player.UserId)
		if runtime.returnVotes[player.UserId] == "replay" then
			task.defer(function()
				local party = parties:create(player.UserId, state.chapter, state.difficulty)
				if party then
					parties:start(player.UserId, party.partyId)
				end
			end)
		end
	end
end)

-- 8. Request handlers.
local function fail(err: string?): Envelope.Envelope<any>
	return Envelope.fail(Envelope.Codes.INVALID_STATE, err)
end
registry:onRequest("PartyCreate", function(player, payload)
	local party, err = parties:create(player.UserId, payload.chapter, payload.difficulty)
	return if party then Envelope.ok(parties:project(party)) else fail(err)
end)
registry:onRequest("PartyJoin", function(player, payload)
	local party, err = parties:join(player.UserId, payload.partyId)
	return if party then Envelope.ok(parties:project(party)) else fail(err)
end)
registry:onRequest("PartyLeave", function(player)
	local party, err = parties:leave(player.UserId)
	return if party then Envelope.ok(parties:project(party)) else fail(err)
end)
registry:onRequest("PartySetDestination", function(player, payload)
	local party, err = parties:setDestination(player.UserId, payload.chapter, payload.difficulty)
	return if party then Envelope.ok(parties:project(party)) else fail(err)
end)
registry:onRequest("PartyStart", function(player, payload)
	local party, err = parties:start(player.UserId, payload.partyId)
	return if party then Envelope.ok(parties:project(party)) else fail(err)
end)
registry:onRequest("PartyCancel", function(player, payload)
	local party, err = parties:cancel(player.UserId, payload.partyId)
	return if party then Envelope.ok(parties:project(party)) else fail(err)
end)
-- Lobby / meta handlers (Phase 4). Every grant pushes the profile projection after commit so the
-- client animates currency changes only from the acknowledged state.
local function pushAfter(player: Player, result: Envelope.Envelope<any>): Envelope.Envelope<any>
	if result.ok then
		playerData:pushProjection(player, config)
	end
	return result
end
registry:onRequest("ClassRoll", function(player, payload)
	return pushAfter(player, classes:roll(player.UserId, payload.slot))
end)
registry:onRequest("ClassEquip", function(player, payload)
	return pushAfter(player, classes:equip(player.UserId, payload.classId, payload.slot))
end)
registry:onRequest("PerkPurchase", function(player, payload)
	return pushAfter(player, perks:purchase(player.UserId, payload.perkId, payload.expectedLevel))
end)
registry:onRequest("DailyClaim", function(player)
	return pushAfter(player, rewards:claimDaily(player.UserId))
end)
registry:onRequest("CodeRedeem", function(player, payload)
	return pushAfter(player, rewards:redeemCode(player.UserId, payload.code))
end)
registry:onRequest("GroupRewardClaim", function(player)
	return pushAfter(player, rewards:claimGroupReward(player.UserId))
end)
registry:onRequest("InventoryEquip", function(player, payload)
	return pushAfter(player, inventory:equip(player.UserId, payload.category, payload.itemId))
end)
registry:onRequest("LeaderboardRequest", function(player)
	local snapshot = leaderboards:snapshot()
	send(player, "LeaderboardProjection", snapshot)
	return Envelope.ok({ ageSeconds = snapshot.ageSeconds })
end)
rewards.granted:Connect(function(userId, grant)
	local player = playerData:playerOf(userId)
	if player then
		send(player, "RewardGranted", grant)
	end
end)
leaderboards.refreshed:Connect(function(snapshot)
	for _, player in ipairs(Players:GetPlayers()) do
		send(player, "LeaderboardProjection", snapshot)
	end
end)
registry:onRequest("RoundSkipVote", function(player, payload)
	local okToken, tokenErr = sessions:validate(player.UserId, payload.sessionToken, "Round")
	if not okToken then
		return Envelope.fail(Envelope.Codes.STALE_TOKEN, tokenErr)
	end
	local runtime = rounds:roundOf(player.UserId)
	if not runtime then
		return fail("no_round")
	end
	local state, err = rounds:voteSkip(runtime.state.roundId, player.UserId)
	return if state then Envelope.ok({ votes = state.skipVotes }) else fail(err)
end)
registry:onRequest("CollectAction", function(player, payload)
	return collection:collect(player.UserId, payload)
end)
registry:onRequest("BundleGather", function(player, payload)
	return collection:gatherBundle(player.UserId, payload)
end)
registry:onRequest("ToolEquip", function(player, payload)
	return tools:equip(player.UserId, payload.toolId)
end)
registry:onRequest("ToolActionBegin", function(player, payload)
	return tools:actionBegin(player.UserId, payload)
end)
registry:onRequest("ToolActionEnd", function(player, payload)
	return tools:actionEnd(player.UserId, payload)
end)
registry:onRequest("SellRequest", function(player, payload)
	return selling:sell(player.UserId, payload.sessionToken)
end)
registry:onRequest("UpgradePurchase", function(player, payload)
	return upgrades:purchase(player.UserId, payload.sessionToken, payload.upgradeId, payload.expectedLevel)
end)
registry:onRequest("EggClaim", function(player, payload)
	return egg:claim(player.UserId, payload.sessionToken)
end)
registry:onRequest("ResultsAction", function(player, payload)
	local runtime = rounds:roundOf(player.UserId)
	if not runtime then
		return fail("no_round")
	end
	if runtime.resultsShownAt and (clock:monotonic() - runtime.resultsShownAt) < config.round.resultScreenMinimumSeconds then
		return Envelope.fail(Envelope.Codes.RATE_LIMITED, "results_minimum")
	end
	local ok, err = rounds:resultsAction(runtime.state.roundId, player.UserId, payload.action)
	return if ok then Envelope.ok({ action = payload.action }) else fail(err)
end)
registry:onRequest("TutorialAction", function(player, payload)
	if payload.action == "skip" then
		objectives:skip(player.UserId)
		sendObjective(player.UserId)
		return Envelope.ok({ step = Objectives.COMPLETE })
	end
	return fail("unsupported")
end)
registry:onRequest("SettingsUpdate", function(player, payload)
	local profile = playerData:getProfile(player.UserId)
	if not profile or not profile:isActive() then
		return fail()
	end
	profile:update(function(data)
		for key, value in pairs(payload) do
			data.settings[key] = value
		end
	end)
	playerData:pushProjection(player, config)
	return Envelope.ok({ settings = table.clone(profile.data.settings) })
end)

-- 9. Player lifecycle wiring.
local function onCharacterAdded(player: Player, character: Model)
	task.wait(0.1)
	local runtime = rounds:roundOf(player.UserId)
	if runtime then
		local layout = ChapterLayout[runtime.state.chapter]
		placeCharacter(player, layout.spawn, layout.nestCenter)
		local snapshot = rounds:project(runtime.state.roundId, true) :: any
		snapshot.player = projectPlayerFor(runtime.state.roundId, player.UserId)
		send(player, "RoundSnapshot", snapshot)
		local state = runtime.players[player.UserId]
		local speed = state and config.handUpgrades.speed[state.handLevels.speed + 1]
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid and speed then
			humanoid.WalkSpeed = speed.walkSpeed
		end
	else
		placeCharacter(player, ChapterLayout.lobby.spawn, ChapterLayout.lobby.portal)
	end
	local humanoid = character:WaitForChild("Humanoid", 5) :: Humanoid?
	if humanoid then
		humanoid.Died:Connect(function()
			analytics:track("player_died", { inRound = rounds:roundOf(player.UserId) ~= nil }, player.UserId)
			tools:onDeath(player.UserId)
			-- Death preserves bag/cash/tools (ASSUMED A-RND-07); respawn after the configured delay.
			task.delay(config.death.respawnSeconds, function()
				if player.Parent then
					player:LoadCharacter()
				end
			end)
		end)
	end
end

local function onPlayerLoaded(player: Player)
	objectives:load(player.UserId)
	sendObjective(player.UserId)
	send(player, "PartyListProjection", partyListPayload())
	send(player, "LeaderboardProjection", leaderboards:snapshot())
	player.CharacterAdded:Connect(function(character)
		onCharacterAdded(player, character)
	end)
	if player.Character then
		task.spawn(onCharacterAdded, player, player.Character)
	end
end

Players.PlayerAdded:Connect(function(player)
	if playerData:onPlayerAdded(player, config) == "loaded" then
		onPlayerLoaded(player)
	end
end)
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(function()
		if playerData:onPlayerAdded(player, config) == "loaded" then
			onPlayerLoaded(player)
		end
	end)
end
Players.PlayerRemoving:Connect(function(player)
	local runtime = rounds:roundOf(player.UserId)
	if runtime then
		tools:onLeave(player.UserId)
		rounds:setPresent(runtime.state.roundId, player.UserId, false)
	end
	if parties:partyOf(player.UserId) then
		parties:leave(player.UserId)
	end
	local leavingProfile = profiles:get(player.UserId)
	if leavingProfile then
		leaderboards:submit(player.UserId, leaderboards:valuesFor(leavingProfile.data), true)
	end
	leaderboards:forget(player.UserId)
	classes:forget(player.UserId)
	displayNames[player.UserId] = nil
	playerData:onPlayerRemoving(player)
	objectives:forget(player.UserId)
	core:forgetPlayer(player.UserId)
	security:forget(player.UserId)
end)

-- 10. Loops: autosave with jitter, service ticks, delta replication, rate-limiter sweeps.
task.spawn(function()
	while true do
		task.wait(ServerPolicy.autosaveMinSeconds + math.random() * (ServerPolicy.autosaveMaxSeconds - ServerPolicy.autosaveMinSeconds))
		local result = playerData:autosaveTick()
		if result.attempted > 0 then
			log:info("autosave", result)
		end
	end
end)
task.spawn(function()
	while true do
		task.wait(0.25)
		pads:tick()
		parties:tick()
		rounds:tick()
		victory:tick()
	end
end)
task.spawn(function()
	while true do
		task.wait(ServerPolicy.leaderboardTickSeconds)
		leaderboards:tick()
	end
end)
task.spawn(function()
	while true do
		task.wait(ServerPolicy.toolTickSeconds)
		tools:tick()
	end
end)
task.spawn(function()
	local interval = 1 / config.collection.pileRepresentation.replicationHz
	while true do
		task.wait(interval)
		rounds:flushDeltas()
	end
end)
task.spawn(function()
	while true do
		task.wait(ServerPolicy.rateLimiterSweepSeconds)
		core:sweep(ServerPolicy.rateLimiterIdleSeconds)
	end
end)

-- 11. Shutdown flush within Roblox's budget.
game:BindToClose(function()
	local result = playerData:flushAll()
	log:info("shutdown_flush", result)
end)

-- 12. Studio-only debug hooks.
local container = {
	config = config,
	buildInfo = BuildInfo,
	clock = clock,
	profiles = profiles,
	sessions = sessions,
	parties = parties,
	rounds = rounds,
	registry = registry,
	security = security,
	analytics = analytics,
	productMap = productMap,
	playerData = playerData,
	dataStoreKind = dataStoreKind,
	profileDataStore = profileDataStore,
	collection = collection,
	selling = selling,
	upgrades = upgrades,
	egg = egg,
	tools = tools,
	entitlements = entitlements,
	debugEntitlements = debugEntitlements,
	pushPreviews = pushPreviews,
	log = log,
	victory = victory,
	objectives = objectives,
	arena = arena,
	lobbyShell = lobbyShell,
	placeCharacter = placeCharacter,
	classes = classes,
	perks = perks,
	rewards = rewards,
	inventory = inventory,
	leaderboards = leaderboards,
	groupAdapter = groupAdapter,
	broadcastPartyList = broadcastPartyList,
	displayNameOf = displayNameOf,
	pads = pads,
	mapMode = mapMode,
}
local debugHooks = StudioDebug.install(container)

runtimeFolder:SetAttribute("SFE_ServerReady", true)
runtimeFolder:SetAttribute("SFE_BuildLabel", BuildInfo.buildLabel)
log:info("server_ready", {
	buildLabel = BuildInfo.buildLabel,
	configVersion = config.configVersion,
	remotes = registry:remoteCount(),
	dataStoreKind = dataStoreKind,
	missingDeploymentIds = #productMap:missingKeys(),
	debugHooks = debugHooks ~= nil,
	meshesRepaired = repairedMeshes,
	mapMode = mapMode,
	bootMs = math.floor((os.clock() - bootStarted) * 1000),
})
