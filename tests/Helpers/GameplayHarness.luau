--!nocheck
-- Shared gameplay harness for the Phase 2/3 suites: real services with injected adapters, fake
-- players, a fake clock, and helpers to start a round, aim, collect, and fast-forward the pile.
-- Nothing here bypasses validation; helpers only place characters and advance the clock.

local Shared = game:GetService("ReplicatedStorage").Shared
local Server = game:GetService("ServerScriptService").Server
local Clock = require(Shared.Clock)
local WeightedRandom = require(Shared.WeightedRandom)
local PileGrid = require(Shared.Domain.PileGrid)
local FeatherLayout = require(Shared.Domain.FeatherLayout)
local PileSurface = require(Shared.Domain.PileSurface)
local ChapterLayout = require(Shared.Domain.ChapterLayout)
local RoundReducer = require(Shared.Reducers.RoundReducer)
local MockDataStore = require(Server.Data.MockDataStore)
local ProfileStore = require(Server.Data.ProfileStore)
local ProductMap = require(Server.Deployment.ProductMap)
local MarketplaceAdapter = require(Server.Adapters.MarketplaceAdapter)
local TeleportAdapter = require(Server.Adapters.TeleportAdapter)
local AnalyticsAdapter = require(Server.Adapters.AnalyticsAdapter)
local AnalyticsService = require(Server.Services.AnalyticsService)
local EntitlementService = require(Server.Services.EntitlementService)
local SessionService = require(Server.Services.SessionService)
local PartyService = require(Server.Services.PartyService)
local RoundService = require(Server.Services.RoundService)
local PlayerDataService = require(Server.Services.PlayerDataService)
local CollectionService = require(Server.Services.CollectionService)
local SellingService = require(Server.Services.SellingService)
local UpgradeService = require(Server.Services.UpgradeService)
local ToolService = require(Server.Services.ToolService)
local PileTerrainService = require(Server.Services.PileTerrainService)
local EggService = require(Server.Services.EggService)
local VictoryService = require(Server.Services.VictoryService)
local ObjectiveService = require(Server.Services.ObjectiveService)
local ClassService = require(Server.Services.ClassService)
local PerkService = require(Server.Services.PerkService)
local RewardService = require(Server.Services.RewardService)
local InventoryService = require(Server.Services.InventoryService)
local LeaderboardService = require(Server.Services.LeaderboardService)
local OrderedStoreAdapter = require(Server.Adapters.OrderedStoreAdapter)
local GroupAdapter = require(Server.Adapters.GroupAdapter)
local ClassRoll = require(Shared.Domain.ClassRoll)
local ServerPolicy = require(Server.ServerPolicy)
local Log = require(Server.Log)

local GameplayHarness = {}

function GameplayHarness.fakePlayer(userId)
	return { UserId = userId, Name = "P" .. userId, Kick = function() end, LoadCharacter = function() end }
end

-- options: { seed, difficulty }
function GameplayHarness.new(cfg, options)
	options = options or {}
	local layout = ChapterLayout.chapter1
	local clock = Clock.fake(1000)
	local counter = 0
	local function idGen()
		counter += 1
		return "id-" .. string.format("%08d", counter)
	end
	local log = Log.capture("gameplay")
	local dataStore = MockDataStore.new("profiles")
	local profiles =
		ProfileStore.new({ dataStore = dataStore, clock = clock, config = cfg, jobId = "job", wait = function() end, log = log })
	local marketplace = MarketplaceAdapter.mock()
	local productMap = ProductMap.new(cfg, { placeIds = {}, gamePasses = {}, developerProducts = {} })
	local entitlements = EntitlementService.new({ marketplace = marketplace, productMap = productMap, clock = clock, cacheSeconds = 60 })
	local analyticsAdapter = AnalyticsAdapter.mock()
	local analytics = AnalyticsService.new({
		adapter = analyticsAdapter,
		config = cfg,
		buildInfo = { buildLabel = "test" },
		rng = function()
			return 0
		end,
	})
	local sent = {}
	local sessions = SessionService.new({ idGen = idGen, clock = clock })
	local playerData = PlayerDataService.new({
		profiles = profiles,
		sessions = sessions,
		entitlements = entitlements,
		clock = clock,
		policy = ServerPolicy,
		send = function(player, name, payload)
			table.insert(sent, { userId = player.UserId, name = name, payload = payload })
		end,
		analytics = analytics,
		log = log,
	})
	local positions = {}
	local function getCharacterPosition(userId)
		return positions[userId]
	end
	local function getProfileData(userId)
		local profile = profiles:get(userId)
		return profile and profile.data or nil
	end
	-- Mock entitlement adapter: passes flagged here override the (unconfigured) marketplace answer.
	local mockEntitlements = {}
	local function getEntitlements(userId)
		local snapshot = entitlements:snapshot(userId)
		for key, value in pairs(mockEntitlements[userId] or {}) do
			snapshot[key] = value
		end
		return snapshot
	end
	local parties = PartyService.new({
		config = cfg,
		clock = clock,
		idGen = idGen,
		sessions = sessions,
		getProgression = function(userId)
			return playerData:getProgression(userId)
		end,
		teleport = TeleportAdapter.localAdapter(idGen),
		analytics = analytics,
	})
	local rounds = RoundService.new({
		config = cfg,
		clock = clock,
		idGen = idGen,
		rng = WeightedRandom.fromSeed(options.seed or 11),
		sessions = sessions,
		analytics = analytics,
	})
	local lineOfSightBlocked = false
	local collection = CollectionService.new({
		config = cfg,
		clock = clock,
		rounds = rounds,
		sessions = sessions,
		idGen = idGen,
		lineOfSight = function()
			return not lineOfSightBlocked
		end,
		getCharacterPosition = getCharacterPosition,
		getProfileData = getProfileData,
		getEntitlements = getEntitlements,
		analytics = analytics,
	})
	local selling = SellingService.new({
		config = cfg,
		rounds = rounds,
		sessions = sessions,
		getCharacterPosition = getCharacterPosition,
		getProfileData = getProfileData,
		analytics = analytics,
	})
	local upgrades = UpgradeService.new({
		config = cfg,
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
	local toolRng = WeightedRandom.fromSeed(options.toolSeed or 23)
	local tools = ToolService.new({
		config = cfg,
		clock = clock,
		rounds = rounds,
		sessions = sessions,
		collection = collection,
		rng = toolRng,
		idGen = idGen,
		getCharacterPosition = getCharacterPosition,
		getEntitlements = getEntitlements,
		analytics = analytics,
		log = log,
	})
	local egg = EggService.new({
		config = cfg,
		rounds = rounds,
		clock = clock,
		getCharacterPosition = getCharacterPosition,
		analytics = analytics,
	})
	local saveShouldFail = false
	local victory = VictoryService.new({
		config = cfg,
		clock = clock,
		rounds = rounds,
		getProfile = function(userId)
			return profiles:get(userId)
		end,
		saveProfile = function(profile)
			if saveShouldFail then
				return false
			end
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
	-- Phase 4 meta services (lobby): classes, perks, rewards, inventory, leaderboards.
	local classRng = WeightedRandom.fromSeed(options.classSeed or 41)
	local classes = ClassService.new({
		config = cfg,
		clock = clock,
		rng = classRng,
		sessions = sessions,
		getProfile = function(userId)
			return profiles:get(userId)
		end,
		getEntitlements = getEntitlements,
		analytics = analytics,
	})
	local perks = PerkService.new({
		config = cfg,
		sessions = sessions,
		getProfile = function(userId)
			return profiles:get(userId)
		end,
		analytics = analytics,
	})
	local group = GroupAdapter.mock(true)
	local rewards = RewardService.new({
		config = cfg,
		clock = clock,
		getProfile = function(userId)
			return profiles:get(userId)
		end,
		getEntitlements = getEntitlements,
		group = group,
		analytics = analytics,
		log = log,
	})
	local inventory = InventoryService.new({
		config = cfg,
		getProfile = function(userId)
			return profiles:get(userId)
		end,
		analytics = analytics,
	})
	local leaderboardStore = OrderedStoreAdapter.mock()
	local leaderboards = LeaderboardService.new({
		config = cfg,
		clock = clock,
		store = leaderboardStore,
		getDisplayName = function(userId)
			return "P" .. tostring(userId)
		end,
		log = log,
	})
	playerData:setProjectionExtras(function(userId, data)
		return { daily = rewards:dailyEvaluation(data), slotCount = ClassRoll.slotCount(cfg, getEntitlements(userId)) }
	end)
	local toolEvents = {}
	local terrainAdapter = PileTerrainService.mockAdapter()
	local pileTerrain = PileTerrainService.new({ config = cfg, adapter = terrainAdapter })
	rounds.created:Connect(function(_state, runtime)
		pileTerrain:build(runtime)
	end)
	rounds.returned:Connect(function(_state, runtime)
		pileTerrain:clear(runtime)
	end)
	egg.revealed:Connect(function(runtime, position)
		pileTerrain:openEggHollow(runtime, position)
	end)
	collection.collected:Connect(function(_userId, runtime, result)
		pileTerrain:onAwarded(runtime, result)
		egg:checkReveal(runtime)
	end)
	tools.awarded:Connect(function(_userId, runtime, result)
		if type(result) == "table" then
			pileTerrain:onAwarded(runtime, result)
		end
		egg:checkReveal(runtime)
	end)
	tools.event:Connect(function(roundId, payload, targetUserId)
		table.insert(toolEvents, { roundId = roundId, payload = payload, targetUserId = targetUserId })
	end)
	collection.event:Connect(function(roundId, payload)
		table.insert(toolEvents, { roundId = roundId, payload = payload })
	end)
	egg.claimed:Connect(function(runtime)
		victory:start(runtime.state.roundId)
	end)
	parties.started:Connect(function(party, reservation)
		if reservation.isLocal then
			rounds:createForParty(party)
			parties:finish(party.partyId, true)
		end
	end)
	rounds.created:Connect(function(_state, runtime)
		tools:grantStartingTools(runtime)
	end)
	rounds.changed:Connect(function(state)
		local runtime = rounds:runtime(state.roundId)
		if runtime and not RoundReducer.acceptsGameplay(state) then
			tools:onRoundEnded(runtime)
		end
	end)

	local h = {}
	h.cfg, h.layout = cfg, layout
	h.clock, h.profiles, h.dataStore, h.sessions, h.playerData, h.parties, h.rounds =
		clock, profiles, dataStore, sessions, playerData, parties, rounds
	h.collection, h.selling, h.upgrades, h.tools, h.egg, h.victory, h.objectives, h.analyticsAdapter, h.sent =
		collection, selling, upgrades, tools, egg, victory, objectives, analyticsAdapter, sent
	h.positions = positions
	h.mockEntitlements = mockEntitlements
	h.classes, h.perks, h.rewards, h.inventory, h.leaderboards, h.leaderboardStore, h.group, h.classRng =
		classes, perks, rewards, inventory, leaderboards, leaderboardStore, group, classRng
	h.entitlements = entitlements
	h.toolEvents = toolEvents
	h.toolRng = toolRng
	h.pileTerrain = pileTerrain
	h.terrainAdapter = terrainAdapter
	function h.setLineOfSightBlocked(value)
		lineOfSightBlocked = value
	end
	function h.setSaveFailing(value)
		saveShouldFail = value
	end
	function h.join(userId)
		playerData:onPlayerAdded(GameplayHarness.fakePlayer(userId), cfg)
		positions[userId] = ChapterLayout.lobby.spawn
		objectives:load(userId)
	end
	function h.token(userId)
		return sessions:get(userId).sessionToken
	end
	function h.profile(userId)
		return profiles:get(userId)
	end
	-- Server-owned test injections (never through remotes): equipped classes, gems, wins.
	function h.setClasses(userId, classIds)
		profiles:get(userId):update(function(data)
			data.classes.equipped = table.clone(classIds)
		end)
	end
	function h.grantGems(userId, gems)
		profiles:get(userId):update(function(data)
			data.currencies.gems += gems
		end)
	end
	function h.setEntitlement(userId, key, value)
		mockEntitlements[userId] = mockEntitlements[userId] or {}
		mockEntitlements[userId][key] = value
	end
	-- Creates a party of the given members, starts it, and advances to Searching.
	function h.startRound(members, difficulty)
		local leader = members[1]
		local party, err = parties:create(leader, "chapter1", difficulty or options.difficulty or "normal")
		assert(party, err)
		for i = 2, #members do
			parties:join(members[i], party.partyId)
		end
		parties:start(leader, party.partyId)
		clock:advance(cfg.round.countdownSeconds)
		parties:tick()
		local roundId = sessions:get(leader).roundId
		for _, userId in ipairs(members) do
			rounds:voteSkip(roundId, userId)
			positions[userId] = layout.spawn
		end
		rounds:tick()
		clock:advance(cfg.round.countdownSeconds)
		rounds:tick()
		tools:tick()
		return roundId, rounds:runtime(roundId)
	end
	-- Aim from `userId` at cell (x, z) of the pile: places the character beside the cell and aims down.
	-- Aim from `userId` at the exposed top feather of cell (x, z): places the character beside the
	-- feather and aims straight at its server-side position. Returns origin, direction, featherId.
	function h.aimAt(userId, runtime, x, z)
		local grid = runtime.grid
		local cell = PileGrid.get(grid, x, z)
		local slot = cell and PileGrid.topSlot(cell) or 1
		local minCorner = ChapterLayout.gridMinCorner(layout, grid.width, grid.depth, grid.cellSize)
		-- Aim where the client seats the record (the mound as built, slot depth below it), which is
		-- what the server resolves too; a bare cell aims at the current surface.
		local feather
		if cell then
			feather = collection:featherPosition(runtime, cell, slot, nil, minCorner)
		else
			local field = PileSurface.buildField(cfg, PileGrid.snapshot(grid), layout)
			local placement = FeatherLayout.placement(cfg.pile.visual, PileGrid.index(grid.width, x, z), slot, grid.cellSize)
			feather = FeatherLayout.worldPosition(field, minCorner, x, z, placement)
		end
		local standing = Vector3.new(feather.X, feather.Y + 2, feather.Z)
		positions[userId] = standing
		local origin = standing + Vector3.new(0, 1.5, 0)
		return origin, (feather - origin).Unit, cell and FeatherLayout.featherId(cell.index, slot) or nil
	end
	function h.collectAt(userId, runtime, x, z, toolId)
		local origin, direction, featherId = h.aimAt(userId, runtime, x, z)
		clock:advance(1) -- clears the tool cooldown between calls
		return collection:collect(userId, {
			sessionToken = h.token(userId),
			origin = origin,
			direction = direction,
			toolId = toolId or "hand",
			featherId = if (toolId or "hand") == "hand" then featherId else nil,
		})
	end
	function h.equip(userId, toolId)
		return tools:equip(userId, toolId)
	end
	function h.beginAt(userId, runtime, toolId, x, z)
		local origin, direction = h.aimAt(userId, runtime, x, z)
		return tools:actionBegin(userId, { sessionToken = h.token(userId), toolId = toolId, origin = origin, direction = direction })
	end
	function h.endAction(userId, toolId)
		return tools:actionEnd(userId, { sessionToken = h.token(userId), toolId = toolId })
	end
	-- Advances the fake clock in `step` increments, ticking the tool service each step.
	function h.advanceTools(seconds, step)
		step = step or 0.1
		local elapsed = 0
		while elapsed < seconds - 1e-9 do
			local slice = math.min(step, seconds - elapsed)
			clock:advance(slice)
			tools:tick()
			elapsed += slice
		end
	end
	function h.standAt(userId, position)
		positions[userId] = position
	end
	function h.standAtBoard(userId)
		positions[userId] = layout.upgradeBoard + Vector3.new(0, 3, 4)
	end
	function h.buy(userId, upgradeId, expectedLevel)
		return upgrades:purchase(userId, h.token(userId), upgradeId, expectedLevel)
	end
	function h.previewOf(userId, upgradeId)
		local runtime = rounds:roundOf(userId)
		return upgrades:preview(runtime.players[userId], upgradeId, runtime, userId)
	end
	function h.eventsOfKind(kind)
		local out = {}
		for _, entry in ipairs(toolEvents) do
			if entry.payload.kind == kind then
				table.insert(out, entry.payload)
			end
		end
		return out
	end
	function h.trackedEvents(name)
		local out = {}
		for _, entry in ipairs(analyticsAdapter.events or {}) do
			if entry.name == name then
				table.insert(out, entry)
			end
		end
		return out
	end
	-- Clears the whole pile except the Egg cover through direct grid mutation (fast-forward helper).
	function h.clearGridExcept(runtime, keepIndexes)
		local keep = {}
		for _, index in ipairs(keepIndexes or {}) do
			keep[index] = true
		end
		for _, cell in ipairs(runtime.grid.cells) do
			if not keep[cell.index] then
				PileGrid.remove(runtime.grid, cell, cell.remaining)
			end
		end
	end
	return h
end

return GameplayHarness
