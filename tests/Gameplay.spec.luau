--!nocheck
-- Phase 2 vertical-slice authority: pile grid, collection, selling, upgrades, Egg reveal/claim,
-- victory rewards, results, objectives. Runs against the real services with injected adapters.

return function(describe, it, expect)
	local ServerStorage = game:GetService("ServerStorage")
	local Shared = game:GetService("ReplicatedStorage").Shared
	local Server = game:GetService("ServerScriptService").Server
	local Config = require(Shared.Config)
	local Clock = require(Shared.Clock)
	local WeightedRandom = require(Shared.WeightedRandom)
	local PileGrid = require(Shared.Domain.PileGrid)
	local EggNodes = require(Shared.Domain.EggNodes)
	local Objectives = require(Shared.Domain.Objectives)
	local ChapterLayout = require(Shared.Domain.ChapterLayout)
	local EconomyMath = require(Shared.EconomyMath)
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
	local EggService = require(Server.Services.EggService)
	local VictoryService = require(Server.Services.VictoryService)
	local ObjectiveService = require(Server.Services.ObjectiveService)
	local ServerPolicy = require(Server.ServerPolicy)
	local Log = require(Server.Log)
	local cfg = Config.fromRaw(require(ServerStorage.SFE.SystemConfig))
	local layout = ChapterLayout.chapter1

	local function fakePlayer(userId)
		return { UserId = userId, Name = "P" .. userId, Kick = function() end, LoadCharacter = function() end }
	end

	-- Full gameplay harness: joins players, creates a solo/party round, and fast-forwards to Searching.
	local function harness(options)
		options = options or {}
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
		local entitlements =
			EntitlementService.new({ marketplace = marketplace, productMap = productMap, clock = clock, cacheSeconds = 60 })
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
		local collection = CollectionService.new({
			config = cfg,
			clock = clock,
			rounds = rounds,
			sessions = sessions,
			getCharacterPosition = getCharacterPosition,
			getProfileData = getProfileData,
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
			analytics = analytics,
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
		collection.collected:Connect(function(_userId, runtime)
			egg:checkReveal(runtime)
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

		local h = {}
		h.clock, h.profiles, h.dataStore, h.sessions, h.playerData, h.parties, h.rounds =
			clock, profiles, dataStore, sessions, playerData, parties, rounds
		h.collection, h.selling, h.upgrades, h.egg, h.victory, h.objectives, h.analyticsAdapter, h.sent =
			collection, selling, upgrades, egg, victory, objectives, analyticsAdapter, sent
		h.positions = positions
		function h.setSaveFailing(value)
			saveShouldFail = value
		end
		function h.join(userId)
			playerData:onPlayerAdded(fakePlayer(userId), cfg)
			positions[userId] = ChapterLayout.lobby.spawn
			objectives:load(userId)
		end
		function h.token(userId)
			return sessions:get(userId).sessionToken
		end
		-- Creates a party of the given members, starts it, and advances to Searching.
		function h.startRound(members)
			local leader = members[1]
			local party = parties:create(leader, "chapter1", "normal")
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
			return roundId, rounds:runtime(roundId)
		end
		-- Aim from `userId` at cell (x, z) of the pile: places the character beside the cell and aims down.
		function h.aimAt(userId, runtime, x, z)
			local grid = runtime.grid
			local target = ChapterLayout.cellWorldPosition(layout, grid.width, grid.depth, grid.cellSize, x, z, 0)
			local standing = target + Vector3.new(0, 2, -4)
			positions[userId] = standing
			local origin = standing + Vector3.new(0, 1.5, 0)
			local planeY = layout.nestBaseY + cfg.pile.maxVisualHeightStuds * 0.5
			local aim = Vector3.new(target.X, planeY, target.Z)
			return origin, (aim - origin).Unit
		end
		function h.collectAt(userId, runtime, x, z)
			local origin, direction = h.aimAt(userId, runtime, x, z)
			clock:advance(1) -- clears the hand cooldown between calls
			return collection:collect(userId, { sessionToken = h.token(userId), origin = origin, direction = direction, toolId = "hand" })
		end
		function h.standAt(userId, position)
			positions[userId] = position
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

	describe("PileGrid", function()
		it("builds the configured grid with cover density and reports fractions", function()
			local roll = WeightedRandom.fromSeed(3)
			local cover = { [PileGrid.index(cfg.pile.gridWidth, 5, 5)] = true }
			local grid = PileGrid.create(cfg.pile, 1, cover, function()
				return roll:next()
			end)
			expect(#grid.cells).toBe(cfg.collection.pileRepresentation.serverGridCells)
			expect(grid.total).toBeGreaterThan(0)
			local coverCell = PileGrid.get(grid, 5, 5)
			local plain = PileGrid.get(grid, 6, 5)
			expect(coverCell.base).toBeGreaterThanOrEqual(
				math.floor(cfg.pile.baseFeathersPerCell * cfg.pile.coverDepthMultiplier * (1 - cfg.pile.surfaceVariance))
			)
			expect(plain.base).toBeLessThanOrEqual(math.ceil(cfg.pile.baseFeathersPerCell * (1 + cfg.pile.surfaceVariance)))
			expect(PileGrid.removedFraction(grid)).toBe(0)
			local removal = PileGrid.remove(grid, plain, 5)
			expect(removal.removed).toBe(5)
			expect(grid.removed).toBe(5)
			local snapshot = PileGrid.snapshot(grid)
			expect(#snapshot.remaining).toBe(#grid.cells)
			expect(snapshot.remaining[plain.index]).toBe(plain.base - 5)
		end)

		it("cannot remove more than a cell holds and findTarget skips empty cells", function()
			local grid = PileGrid.create(cfg.pile, 1, {}, function()
				return 0.5
			end)
			local cell = PileGrid.get(grid, 2, 2)
			local first = PileGrid.remove(grid, cell, 1000)
			expect(first.removed).toBe(cell.base)
			local second = PileGrid.remove(grid, cell, 1)
			expect(second.removed).toBe(0)
			expect(cell.remaining).toBe(0)
			local target = PileGrid.findTarget(grid, 2, 2, 1)
			expect(target).toBeTruthy()
			expect(target.index).never.toBe(cell.index)
			expect(PileGrid.get(grid, -1, 0)).toBeNil()
		end)

		it("egg nodes cover a full neighbourhood inside the grid and depth rolls within config", function()
			local nodes = EggNodes.build("chapter1", cfg.pile, cfg.eggSpawn)
			expect(#nodes).toBe(cfg.eggSpawn.spawnNodeCountTarget)
			local ids = {}
			for _, node in ipairs(nodes) do
				expect(ids[node.id]).toBeNil()
				ids[node.id] = true
				expect(#node.coverIndexes).toBe((cfg.pile.coverRadiusCells * 2 + 1) ^ 2)
				for _, index in ipairs(node.coverIndexes) do
					expect(index).toBeGreaterThanOrEqual(1)
					expect(index).toBeLessThanOrEqual(cfg.pile.gridWidth * cfg.pile.gridDepth)
				end
			end
			local depth = EggNodes.rollDepth(cfg.eggSpawn, cfg.difficulty.normal, 0.5)
			expect(depth).toBeGreaterThanOrEqual(cfg.eggSpawn.minimumRemovalFraction)
			expect(depth).toBeLessThanOrEqual(cfg.eggSpawn.maximumRemovalFraction)
			local hardDepth = EggNodes.rollDepth(cfg.eggSpawn, cfg.difficulty.hard, 0)
			expect(hardDepth).toBe(cfg.difficulty.hard.eggDepthMinimum)
		end)
	end)

	describe("Collection", function()
		it("removes server-selected cells, fills the bag to capacity, and never exceeds it", function()
			local h = harness()
			h.join(1)
			local _, runtime = h.startRound({ 1 })
			expect(runtime.state.phase).toBe("Searching")
			local capacity = cfg.collection.startingBagCapacity
			local carried, hits = 0, 0
			while carried < capacity and hits < 200 do
				local result = h.collectAt(1, runtime, 4, 4 + (hits % 3))
				expect(result.ok).toBe(true)
				expect(result.data.awarded).toBe(cfg.handUpgrades.grasp[1].amount)
				carried = result.data.carried
				hits += 1
			end
			expect(carried).toBe(capacity)
			expect(runtime.grid.removed).toBe(capacity)
			local full = h.collectAt(1, runtime, 4, 4)
			expect(full.ok).toBe(false)
			expect(full.message).toBe("bag_full")
			expect(runtime.players[1].carriedStandard).toBe(capacity)
			expect(runtime.players[1].contribution.feathersCollected).toBe(capacity)
			expect(h.analyticsAdapter:countOf("bag_full")).toBe(1)
		end)

		it("cell depletion cannot double-award: two hits on a one-feather cell award once", function()
			local h = harness()
			h.join(1)
			h.join(2)
			local _, runtime = h.startRound({ 1, 2 })
			local cell = PileGrid.get(runtime.grid, 6, 6)
			PileGrid.remove(runtime.grid, cell, cell.remaining - 1)
			-- empty every neighbour so findTarget cannot fall back
			for dz = -1, 1 do
				for dx = -1, 1 do
					if dx ~= 0 or dz ~= 0 then
						local n = PileGrid.get(runtime.grid, 6 + dx, 6 + dz)
						PileGrid.remove(runtime.grid, n, n.remaining)
					end
				end
			end
			local first = h.collectAt(1, runtime, 6, 6)
			local second = h.collectAt(2, runtime, 6, 6)
			expect(first.ok).toBe(true)
			expect(first.data.awarded).toBe(1)
			expect(second.ok).toBe(false)
			expect(second.code).toBe("not_found")
			expect(cell.remaining).toBe(0)
		end)

		it("rejects invalid phase, stale token, cooldown, out-of-range origin/aim, and wrong tool", function()
			local h = harness()
			h.join(1)
			local roundId, runtime = h.startRound({ 1 })
			local origin, direction = h.aimAt(1, runtime, 4, 4)
			local token = h.token(1)
			local stale = h.collection:collect(1, { sessionToken = "stale-token", origin = origin, direction = direction, toolId = "hand" })
			expect(stale.code).toBe("stale_token")
			local wrongTool = h.collection:collect(1, { sessionToken = token, origin = origin, direction = direction, toolId = "nestRake" })
			expect(wrongTool.code).toBe("not_authorized")
			local farOrigin = h.collection:collect(
				1,
				{ sessionToken = token, origin = origin + Vector3.new(0, 0, 40), direction = direction, toolId = "hand" }
			)
			expect(farOrigin.code).toBe("out_of_range")
			local up = h.collection:collect(1, { sessionToken = token, origin = origin, direction = Vector3.new(0, 1, 0), toolId = "hand" })
			expect(up.code).toBe("out_of_range")
			h.standAt(1, layout.spawn)
			local tooFar = h.collection:collect(1, {
				sessionToken = token,
				origin = layout.spawn + Vector3.new(0, 1.5, 0),
				direction = Vector3.new(0, -0.3, 1).Unit,
				toolId = "hand",
			})
			expect(tooFar.code).toBe("out_of_range")
			local first = h.collectAt(1, runtime, 4, 4)
			expect(first.ok).toBe(true)
			local origin2, direction2 = h.aimAt(1, runtime, 4, 4)
			local cooldown = h.collection:collect(1, { sessionToken = token, origin = origin2, direction = direction2, toolId = "hand" })
			expect(cooldown.code).toBe("rate_limited")
			expect(cooldown.message).toBe("cooldown")
			h.egg:checkReveal(runtime)
			h.rounds:markEggRevealed(roundId)
			local revealedPhase = h.collectAt(1, runtime, 4, 4)
			expect(revealedPhase.code).toBe("invalid_state")
		end)

		it("cooldown deadline comes from config and the hand amount from the grasp level", function()
			local h = harness()
			h.join(1)
			local _, runtime = h.startRound({ 1 })
			local result = h.collectAt(1, runtime, 5, 5)
			expect(result.data.cooldownMs).toBe(math.floor(cfg.collection.baseHandCooldownSeconds * 1000))
			runtime.players[1].handLevels.grasp = 1
			local upgraded = h.collectAt(1, runtime, 5, 6)
			expect(upgraded.data.awarded).toBe(cfg.handUpgrades.grasp[2].amount)
		end)
	end)

	describe("Selling", function()
		it("25 standard feathers sell for exactly 25 cents at the station and a duplicate pays once", function()
			local h = harness()
			h.join(1)
			local _, runtime = h.startRound({ 1 })
			local carried = 0
			local i = 0
			while carried < cfg.collection.startingBagCapacity do
				carried = h.collectAt(1, runtime, 3 + (i % 4), 3).data.carried
				i += 1
			end
			h.standAt(1, layout.spawn)
			local far = h.selling:sell(1, h.token(1))
			expect(far.code).toBe("out_of_range")
			h.standAt(1, layout.sellStation + Vector3.new(0, 3, 6))
			local sale = h.selling:sell(1, h.token(1))
			expect(sale.ok).toBe(true)
			expect(sale.data.standardCount).toBe(25)
			expect(sale.data.finalCents).toBe(25)
			expect(sale.data.cashCents).toBe(25)
			expect(EconomyMath.formatCents(sale.data.cashCents)).toBe("$0.25")
			local duplicate = h.selling:sell(1, h.token(1))
			expect(duplicate.ok).toBe(false)
			expect(duplicate.code).toBe("already_done")
			expect(runtime.players[1].cashCents).toBe(25)
			expect(runtime.players[1].carriedStandard).toBe(0)
			expect(h.analyticsAdapter:countOf("sell_completed")).toBe(1)
		end)
	end)

	describe("Upgrades", function()
		it("starter upgrade purchase path: preview, debit, level, stale level, funds, maxed", function()
			local h = harness()
			h.join(1)
			local _, runtime = h.startRound({ 1 })
			local state = runtime.players[1]
			local previews = h.upgrades:previews(state)
			expect(#previews).toBe(#UpgradeService.IDS)
			local graspPreview = h.upgrades:preview(state, "handGrasp")
			expect(graspPreview.costCents).toBe(EconomyMath.dollarsToCents(cfg.handUpgrades.grasp[1].nextCash))
			expect(graspPreview.next.amount).toBe(cfg.handUpgrades.grasp[2].amount)
			h.standAt(1, layout.upgradeBoard + Vector3.new(0, 3, -5))
			local broke = h.upgrades:purchase(1, h.token(1), "handGrasp", 0)
			expect(broke.code).toBe("insufficient_funds")
			state.cashCents = 1000
			local stale = h.upgrades:purchase(1, h.token(1), "handGrasp", 1)
			expect(stale.code).toBe("stale_token")
			local bought = h.upgrades:purchase(1, h.token(1), "handGrasp", 0)
			expect(bought.ok).toBe(true)
			expect(bought.data.level).toBe(1)
			expect(bought.data.paidCents).toBe(graspPreview.costCents)
			expect(state.cashCents).toBe(1000 - graspPreview.costCents)
			expect(state.handLevels.grasp).toBe(1)
			h.standAt(1, layout.spawn)
			expect(h.upgrades:purchase(1, h.token(1), "bag", 1).code).toBe("out_of_range")
			h.standAt(1, layout.upgradeBoard)
			state.cashCents = 100000
			for level = 1, cfg.bags.maxLevel - 1 do
				expect(h.upgrades:purchase(1, h.token(1), "bag", level).ok).toBe(true)
			end
			local maxed = h.upgrades:purchase(1, h.token(1), "bag", cfg.bags.maxLevel)
			expect(maxed.code).toBe("invalid_state")
			expect(maxed.message).toBe("maxed")
			expect(h.collection:bagCapacity(runtime, 1).capacity).toBe(cfg.bags.levels[cfg.bags.maxLevel].capacity)
			expect(h.upgrades:purchase(1, h.token(1), "unknownUpgrade", 0).code).toBe("not_found")
		end)
	end)

	describe("Egg", function()
		it("selected node is valid, stays concealed until cover and depth are met, reveals once", function()
			local h = harness()
			h.join(1)
			local roundId, runtime = h.startRound({ 1 })
			expect(EggNodes.byId(runtime.nodes, runtime.eggNode.id)).toBeTruthy()
			expect(runtime.eggDepthFraction).toBeGreaterThanOrEqual(cfg.eggSpawn.minimumRemovalFraction)
			expect(runtime.eggDepthFraction).toBeLessThanOrEqual(cfg.eggSpawn.maximumRemovalFraction)
			expect(h.rounds:project(roundId, true).eggNodeId).toBeNil()
			-- Cover cleared but depth not reached: still concealed.
			for _, index in ipairs(runtime.eggNode.coverIndexes) do
				local cell = runtime.grid.cells[index]
				PileGrid.remove(runtime.grid, cell, cell.remaining)
			end
			expect(h.egg:checkReveal(runtime)).toBe(false)
			expect(runtime.eggCoverCleared).toBe(true)
			expect(runtime.state.phase).toBe("Searching")
			-- Reach the depth fraction through the rest of the pile.
			for _, cell in ipairs(runtime.grid.cells) do
				if PileGrid.removedFraction(runtime.grid) >= runtime.eggDepthFraction then
					break
				end
				PileGrid.remove(runtime.grid, cell, cell.remaining)
			end
			expect(h.egg:checkReveal(runtime)).toBe(true)
			expect(runtime.state.phase).toBe("EggRevealed")
			expect(runtime.state.joinClosed).toBe(true)
			expect(h.egg:checkReveal(runtime)).toBe(false)
			expect(h.egg.stats.reveals).toBe(1)
			expect(h.analyticsAdapter:countOf("egg_revealed")).toBe(1)
		end)

		it("reveal triggers from a real collection hit on the last cover cell", function()
			local h = harness()
			h.join(1)
			local _, runtime = h.startRound({ 1 })
			h.clearGridExcept(runtime, runtime.eggNode.coverIndexes)
			for _, index in ipairs(runtime.eggNode.coverIndexes) do
				local cell = runtime.grid.cells[index]
				PileGrid.remove(runtime.grid, cell, cell.remaining - 1)
			end
			local revealed = false
			h.egg.revealed:Connect(function(_rt, position)
				revealed = true
				expect(typeof(position)).toBe("Vector3")
			end)
			for _, index in ipairs(runtime.eggNode.coverIndexes) do
				local cell = runtime.grid.cells[index]
				local result = h.collectAt(1, runtime, cell.x, cell.z)
				expect(result.ok).toBe(true)
			end
			expect(revealed).toBe(true)
			expect(runtime.state.phase).toBe("EggRevealed")
		end)

		it("100 simultaneous claims choose one finder; range and phase are enforced", function()
			local h = harness()
			for userId = 1, 4 do
				h.join(userId)
			end
			local _, runtime = h.startRound({ 1, 2, 3, 4 })
			local early = h.egg:claim(2, h.token(2))
			expect(early.code).toBe("invalid_state")
			h.clearGridExcept(runtime, {})
			expect(h.egg:checkReveal(runtime)).toBe(true)
			local eggPosition = h.egg:position(runtime)
			h.standAt(1, eggPosition + Vector3.new(cfg.eggSpawn.claimRadiusStuds + 5, 0, 0))
			expect(h.egg:claim(1, h.token(1)).code).toBe("out_of_range")
			for userId = 1, 4 do
				h.standAt(userId, eggPosition + Vector3.new(2, 0, 0))
			end
			local winners = {}
			for i = 1, 100 do
				local userId = (i % 4) + 1
				local result = h.egg:claim(userId, h.token(userId))
				if result.ok then
					table.insert(winners, userId)
				end
			end
			expect(#winners).toBe(1)
			expect(runtime.state.victory.finderUserId).toBe(winners[1])
		end)
	end)

	describe("Victory", function()
		local function playToVictory(h, members, finder)
			local roundId, runtime = h.startRound(members)
			h.clearGridExcept(runtime, {})
			h.egg:checkReveal(runtime)
			local position = h.egg:position(runtime)
			for _, userId in ipairs(members) do
				h.standAt(userId, position)
			end
			h.clock:advance(42.5) -- elapsed time for the record
			local claim = h.egg:claim(finder, h.token(finder))
			expect(claim.ok).toBe(true)
			return roundId, runtime
		end

		it("base reward once per present member, finder bonus once, save before results, replay-safe", function()
			local h = harness()
			for userId = 1, 3 do
				h.join(userId)
			end
			local _, runtime = playToVictory(h, { 1, 2, 3 }, 2)
			expect(runtime.state.phase).toBe("Results")
			local rewards = cfg.chapters.chapter1.normalRewards
			for userId = 1, 3 do
				local data = h.profiles:get(userId).data
				local expectedGems = rewards.gems + (userId == 2 and cfg.victory.finderBonusGems or 0)
				expect(data.currencies.gems).toBe(expectedGems)
				expect(data.progression.totalWins).toBe(rewards.wins)
				expect(data.progression.chapterWins.chapter1.normal).toBe(1)
				expect(data.progression.bestTimeMs.chapter1.normal).toBe(runtime.state.victory.elapsedMs)
				expect(data.progression.unlockedDifficulties.chapter1.hard).toBe(true)
				expect(data.progression.unlockedChapters.chapter2).toBe(true)
				expect(data.stats.eggsFound).toBe(userId == 2 and 1 or 0)
				expect(data.stats.roundsCompleted).toBe(1)
				-- persisted before results
				expect(h.dataStore:peek(h.profiles:keyFor(userId)).data.currencies.gems).toBe(expectedGems)
				local result = runtime.results[userId]
				expect(result.saved).toBe(true)
				expect(result.rewards.finderBonusGems).toBe(userId == 2 and cfg.victory.finderBonusGems or 0)
				expect(result.newBest).toBe(true)
				expect(result.unlocked).toContain("chapter1:hard")
				expect(result.unlocked).toContain("chapter2:normal")
			end
			expect(runtime.state.victory.elapsedMs).toBe(42500)
			-- Replaying the commit grants nothing more.
			h.victory:commitRewards(runtime)
			h.victory:commitRewards(runtime)
			expect(h.profiles:get(2).data.currencies.gems).toBe(rewards.gems + cfg.victory.finderBonusGems)
			expect(h.analyticsAdapter:countOf("round_completed")).toBe(1)
			expect(h.sessions:get(1).phase).toBe("Results")
		end)

		it("save failure holds the round in CommittingRewards and a later retry commits once", function()
			local h = harness()
			h.join(1)
			h.setSaveFailing(true)
			local _, runtime = playToVictory(h, { 1 }, 1)
			expect(runtime.state.phase).toBe("CommittingRewards")
			expect(h.victory:pendingCount()).toBe(1)
			expect(h.dataStore:peek(h.profiles:keyFor(1)).data.currencies.gems).toBe(0)
			expect(h.victory:tick()).toBe(0)
			expect(runtime.state.phase).toBe("CommittingRewards")
			h.setSaveFailing(false)
			expect(h.victory:tick()).toBe(1)
			expect(runtime.state.phase).toBe("Results")
			local expectedGems = cfg.chapters.chapter1.normalRewards.gems + cfg.victory.finderBonusGems
			expect(h.profiles:get(1).data.currencies.gems).toBe(expectedGems)
			expect(h.dataStore:peek(h.profiles:keyFor(1)).data.currencies.gems).toBe(expectedGems)
		end)

		it("personal best only improves; second win keeps the faster time and increments wins", function()
			local h = harness()
			h.join(1)
			local roundId = playToVictory(h, { 1 }, 1)
			h.rounds:returnToLobby(roundId)
			expect(h.sessions:get(1).phase).toBe("Lobby")
			h.positions[1] = ChapterLayout.lobby.spawn
			local _, runtime2 = h.startRound({ 1 })
			h.clearGridExcept(runtime2, {})
			h.egg:checkReveal(runtime2)
			h.standAt(1, h.egg:position(runtime2))
			h.clock:advance(90)
			expect(h.egg:claim(1, h.token(1)).ok).toBe(true)
			local data = h.profiles:get(1).data
			expect(data.progression.bestTimeMs.chapter1.normal).toBe(42500)
			expect(data.progression.totalWins).toBe(2)
			expect(runtime2.results[1].newBest).toBe(false)
			expect(runtime2.results[1].previousBestMs).toBe(42500)
		end)

		it("results actions return the party once all present members choose, else auto-continue", function()
			local h = harness()
			h.join(1)
			h.join(2)
			local roundId, _runtime = playToVictory(h, { 1, 2 }, 1)
			expect(h.rounds:resultsAction(roundId, 1, "lobby")).toBe(true)
			expect(h.rounds:get(roundId).phase).toBe("Results")
			expect(h.rounds:resultsAction(roundId, 2, "replay")).toBe(true)
			expect(h.rounds:get(roundId)).toBeNil()
			expect(h.sessions:get(1).phase).toBe("Lobby")
			expect(h.sessions:get(2).phase).toBe("Lobby")
			expect(h.rounds:roundOf(1)).toBeNil()
			-- auto-continue
			h.positions[1] = ChapterLayout.lobby.spawn
			local roundId2 = playToVictory(h, { 1 }, 1)
			h.clock:advance(cfg.round.resultScreenAutoContinueSeconds)
			h.rounds:tick()
			expect(h.rounds:get(roundId2)).toBeNil()
			expect(h.sessions:get(1).phase).toBe("Lobby")
		end)

		it("a member who left before commit is not granted; teleport failure never duplicates", function()
			local h = harness()
			h.join(1)
			h.join(2)
			local roundId, runtime = h.startRound({ 1, 2 })
			h.rounds:setPresent(roundId, 2, false)
			h.clearGridExcept(runtime, {})
			h.egg:checkReveal(runtime)
			h.standAt(1, h.egg:position(runtime))
			expect(h.egg:claim(1, h.token(1)).ok).toBe(true)
			expect(h.profiles:get(1).data.currencies.gems).toBeGreaterThan(0)
			expect(h.profiles:get(2).data.currencies.gems).toBe(0)
			expect(runtime.results[2]).toBeNil()
			local gemsBefore = h.profiles:get(1).data.currencies.gems
			h.victory:commitRewards(runtime) -- simulated post-teleport-failure retry
			expect(h.profiles:get(1).data.currencies.gems).toBe(gemsBefore)
		end)
	end)

	describe("Objectives", function()
		it("advance strictly in order, persist by tutorial version, and resume", function()
			local h = harness()
			h.join(1)
			expect(h.objectives:current(1)).toBe("enter_party")
			expect(h.objectives:complete(1, "collect_25")).toBe(false)
			local ok, nextStep = h.objectives:complete(1, "enter_party")
			expect(ok).toBe(true)
			expect(nextStep).toBe("collect_25")
			expect(h.profiles:get(1).data.tutorial.completedSteps.enter_party).toBe(true)
			expect(h.objectives:complete(1, "enter_party")).toBe(false)
			for _, step in ipairs({ "collect_25", "sell_first_bag", "buy_first_upgrade", "search_for_egg", "claim_or_complete_round" }) do
				expect(h.objectives:complete(1, step)).toBe(true)
			end
			expect(h.objectives:current(1)).toBe(Objectives.COMPLETE)
			expect(h.profiles:get(1).data.tutorial.completed).toBe(true)
			expect(h.profiles:get(1).data.tutorial.version).toBe(1)
			-- Resume from persisted state after a reload.
			local profile = h.profiles:get(1)
			h.profiles:saveAsync(profile)
			h.objectives:forget(1)
			expect(h.objectives:load(1)).toBe(Objectives.COMPLETE)
			expect(h.objectives:roundObjective(1, false)).toBe("search_for_egg")
			expect(h.objectives:roundObjective(1, true)).toBe("claim_or_complete_round")
		end)

		it("a partial tutorial resumes at the first incomplete step and skip completes it", function()
			local h = harness()
			h.join(1)
			h.objectives:complete(1, "enter_party")
			h.objectives:complete(1, "collect_25")
			h.objectives:forget(1)
			expect(h.objectives:load(1)).toBe("sell_first_bag")
			expect(h.objectives:skip(1)).toBe(Objectives.COMPLETE)
			expect(h.profiles:get(1).data.tutorial.completed).toBe(true)
			expect(Objectives.COPY.collect_25.title).toBeType("string")
			expect(Objectives.next("claim_or_complete_round")).toBe(Objectives.COMPLETE)
		end)

		it("a tutorial version bump resets progress on reconcile", function()
			local ProfileSchema = require(Server.Data.ProfileSchema)
			local raw = ProfileSchema.default(1)
			raw.tutorial.version = 0
			raw.tutorial.completedSteps.enter_party = true
			raw.tutorial.completed = true
			local profile = ProfileSchema.reconcile(raw, cfg, 1)
			expect(profile.tutorial.completed).toBe(false)
			expect(profile.tutorial.completedSteps.enter_party).toBeNil()
			expect(profile.tutorial.version).toBe(ProfileSchema.TUTORIAL_VERSION)
		end)
	end)

	describe("Timer and projections", function()
		it("timer and snapshot use server milliseconds and never expose the Egg node", function()
			local h = harness()
			h.join(1)
			local roundId, runtime = h.startRound({ 1 })
			local startedAt = runtime.state.searchingStartedAtMs
			expect(startedAt).toBe(h.clock:nowMs())
			h.clock:advance(12.345)
			local projection = h.rounds:project(roundId, true)
			expect(projection.elapsedMs).toBe(12345)
			expect(projection.searchingStartedAtMs).toBe(startedAt)
			expect(projection.serverNowMs).toBe(h.clock:nowMs())
			expect(projection.eggNodeId).toBeNil()
			expect(projection.pile.width).toBe(cfg.pile.gridWidth)
			expect(#projection.pile.remaining).toBe(cfg.pile.gridWidth * cfg.pile.gridDepth)
			local player = h.rounds:projectPlayer(roundId, 1)
			expect(player.cashCents).toBe(0)
			expect(player.bagLevel).toBe(1)
		end)

		it("pile deltas batch per flush and carry only changed cells", function()
			local h = harness()
			h.join(1)
			local _, runtime = h.startRound({ 1 })
			local flushed = {}
			h.rounds.deltaFlushed:Connect(function(_, delta)
				table.insert(flushed, delta)
			end)
			h.collectAt(1, runtime, 4, 4)
			h.collectAt(1, runtime, 4, 4)
			h.collectAt(1, runtime, 8, 8)
			expect(h.rounds:flushDeltas()).toBe(1)
			expect(#flushed).toBe(1)
			expect(#flushed[1].cells).toBe(2)
			expect(flushed[1].removed).toBe(3)
			expect(h.rounds:flushDeltas()).toBe(0)
		end)
	end)
end
