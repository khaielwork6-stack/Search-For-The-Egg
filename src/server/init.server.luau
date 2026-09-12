--!strict
-- Server bootstrap for Search for the Egg. Composes adapters and services with explicit
-- dependency injection, publishes the client config projection, builds remotes, wires Roblox
-- player events, autosave, and shutdown flush. Order matters and is documented inline.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Clock = require(Shared.Clock)
local WeightedRandom = require(Shared.WeightedRandom)

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
local StudioDebug = require(script.Debug.StudioDebug)
local Envelope = require(Shared.Net.Envelope)

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
local analytics = AnalyticsService.new({ adapter = AnalyticsAdapter.real(Players), config = config, buildInfo = BuildInfo })

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

-- 6. Sessions, parties, rounds.
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

-- Same-place adapter: a local reservation becomes a round in this server.
parties.started:Connect(function(party, reservation)
	if reservation.isLocal then
		rounds:createForParty(party)
		parties:finish(party.partyId, true)
	else
		local members = {}
		for _, userId in ipairs(party.members) do
			local player = playerData:playerOf(userId)
			if player then
				table.insert(members, player)
			end
		end
		local ok = teleport:teleport(reservation, members, { reservation = reservation.code, party = party.partyId })
		parties:finish(party.partyId, ok)
	end
end)

-- Projections: push party/session changes to affected clients.
parties.changed:Connect(function(party)
	local projection = parties:project(party)
	for _, userId in ipairs(party.members) do
		local player = playerData:playerOf(userId)
		if player then
			send(player, "PartyProjection", projection)
		end
	end
end)
sessions.changed:Connect(function(userId, _state)
	local player = playerData:playerOf(userId)
	if player then
		playerData:pushSession(player)
	end
end)

-- 7. Request handlers (Phase 1: party, settings). Every other message is registered by later
--    phases; until then the registry answers UNAVAILABLE after validation and rate limiting.
registry:onRequest("PartyCreate", function(player, payload)
	local party, err = parties:create(player.UserId, payload.chapter, payload.difficulty)
	if not party then
		return Envelope.fail(Envelope.Codes.INVALID_STATE, err)
	end
	return Envelope.ok(parties:project(party))
end)
registry:onRequest("PartyJoin", function(player, payload)
	local party, err = parties:join(player.UserId, payload.partyId)
	if not party then
		return Envelope.fail(Envelope.Codes.INVALID_STATE, err)
	end
	return Envelope.ok(parties:project(party))
end)
registry:onRequest("PartyLeave", function(player)
	local party, err = parties:leave(player.UserId)
	if not party then
		return Envelope.fail(Envelope.Codes.INVALID_STATE, err)
	end
	return Envelope.ok(parties:project(party))
end)
registry:onRequest("PartySetDestination", function(player, payload)
	local party, err = parties:setDestination(player.UserId, payload.chapter, payload.difficulty)
	if not party then
		return Envelope.fail(Envelope.Codes.INVALID_STATE, err)
	end
	return Envelope.ok(parties:project(party))
end)
registry:onRequest("PartyStart", function(player, payload)
	local party, err = parties:start(player.UserId, payload.partyId)
	if not party then
		return Envelope.fail(Envelope.Codes.INVALID_STATE, err)
	end
	return Envelope.ok(parties:project(party))
end)
registry:onRequest("SettingsUpdate", function(player, payload)
	local profile = playerData:getProfile(player.UserId)
	if not profile or not profile:isActive() then
		return Envelope.fail(Envelope.Codes.INVALID_STATE)
	end
	profile:update(function(data)
		for key, value in pairs(payload) do
			data.settings[key] = value
		end
	end)
	playerData:pushProjection(player, config)
	return Envelope.ok({ settings = table.clone(profile.data.settings) })
end)

-- 8. World shell (labeled placeholders) and player lifecycle wiring.
Players.CharacterAutoLoads = false
WorldShellService.build(workspace, workspace:FindFirstChildOfClass("SpawnLocation"))

Players.PlayerAdded:Connect(function(player)
	playerData:onPlayerAdded(player, config)
end)
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(function()
		playerData:onPlayerAdded(player, config)
	end)
end
Players.PlayerRemoving:Connect(function(player)
	playerData:onPlayerRemoving(player)
	core:forgetPlayer(player.UserId)
	security:forget(player.UserId)
end)

-- 9. Autosave with jitter, service ticks, and rate-limiter sweeps.
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
		parties:tick()
		rounds:tick()
	end
end)
task.spawn(function()
	while true do
		task.wait(ServerPolicy.rateLimiterSweepSeconds)
		core:sweep(ServerPolicy.rateLimiterIdleSeconds)
	end
end)

-- 10. Shutdown flush within Roblox's budget.
game:BindToClose(function()
	local result = playerData:flushAll()
	log:info("shutdown_flush", result)
end)

-- 11. Studio-only debug hooks.
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
	bootMs = math.floor((os.clock() - bootStarted) * 1000),
})
