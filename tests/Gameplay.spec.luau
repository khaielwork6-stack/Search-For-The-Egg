--!nocheck
-- Phase 2 vertical-slice authority: pile grid, collection, selling, upgrades, Egg reveal/claim,
-- victory rewards, results, objectives. Runs against the real services with injected adapters.

return function(describe, it, expect)
	local ServerStorage = game:GetService("ServerStorage")
	local Shared = game:GetService("ReplicatedStorage").Shared
	local Server = game:GetService("ServerScriptService").Server
	local Config = require(Shared.Config)
	local WeightedRandom = require(Shared.WeightedRandom)
	local PileGrid = require(Shared.Domain.PileGrid)
	local EggNodes = require(Shared.Domain.EggNodes)
	local Objectives = require(Shared.Domain.Objectives)
	local ChapterLayout = require(Shared.Domain.ChapterLayout)
	local ToolSpecs = require(Shared.Domain.ToolSpecs)
	local EconomyMath = require(Shared.EconomyMath)
	local cfg = Config.fromRaw(require(ServerStorage.SFE.SystemConfig))
	local layout = ChapterLayout.chapter1

	local GameplayHarness = require(ServerStorage.Tests.Helpers.GameplayHarness)

	-- Full gameplay harness (tests/Helpers/GameplayHarness): joins players, creates a solo/party round,
	-- and fast-forwards to Searching.
	local function harness(options)
		return GameplayHarness.new(cfg, options)
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
			-- Lucky rounds open a shallow floor; ordinary rounds keep the deep one.
			local lucky = EggNodes.rollDepth(cfg.eggSpawn, cfg.difficulty.normal, 0, true)
			expect(lucky).toBe(cfg.eggSpawn.luckyMinimumRemovalFraction)
			expect(EggNodes.rollDepth(cfg.eggSpawn, cfg.difficulty.normal, 0, false)).toBe(cfg.eggSpawn.minimumRemovalFraction)
			expect(EggNodes.rollLucky(cfg.eggSpawn, cfg.eggSpawn.luckyRoundChance - 0.001)).toBe(true)
			expect(EggNodes.rollLucky(cfg.eggSpawn, cfg.eggSpawn.luckyRoundChance)).toBe(false)
			-- Core nodes outweigh edge nodes.
			local heaviest, lightest = -math.huge, math.huge
			for _, node in ipairs(nodes) do
				heaviest = math.max(heaviest, node.weight)
				lightest = math.min(lightest, node.weight)
			end
			expect(heaviest).toBeGreaterThan(lightest)
			expect(heaviest).toBeLessThanOrEqual(cfg.eggSpawn.coreNodeWeight)
			expect(lightest).toBeGreaterThanOrEqual(cfg.eggSpawn.edgeNodeWeight)
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
			-- Interior block: rim columns hold only a record or two, the crown holds dozens.
			local bx, bz = runtime.grid.width // 2 - 2, runtime.grid.depth // 2 - 2
			while carried < capacity and hits < 200 do
				-- Every hand click collects exactly one feather (owner requirement); walk a 4x4 block.
				local result = h.collectAt(1, runtime, bx + (hits % 4), bz + math.floor(hits / 4) % 4)
				expect(result.ok).toBe(true)
				-- Exactly one record per click: a standard feather, or a Rainbow Feather from the seed.
				expect(result.data.awarded + (result.data.rainbow or 0)).toBe(1)
				carried = result.data.carried
				hits += 1
			end
			expect(carried).toBe(capacity)
			expect(runtime.grid.removed).toBe(capacity)
			local full = h.collectAt(1, runtime, runtime.grid.width // 2, runtime.grid.depth // 2)
			expect(full.ok).toBe(false)
			expect(full.message).toBe("bag_full")
			expect(runtime.players[1].carriedStandard + runtime.players[1].carriedRainbow).toBe(capacity)
			expect(runtime.players[1].contribution.feathersCollected).toBe(capacity)
			expect(h.analyticsAdapter:countOf("bag_full")).toBe(1)
		end)

		it("two players targeting the same feather: the first wins, the second is refused without an award", function()
			local h = harness()
			h.join(1)
			h.join(2)
			local _, runtime = h.startRound({ 1, 2 })
			local cell = PileGrid.get(runtime.grid, 6, 6)
			local origin2, direction2, featherId = h.aimAt(2, runtime, 6, 6)
			local first = h.collectAt(1, runtime, 6, 6)
			expect(first.ok).toBe(true)
			expect(first.data.awarded).toBe(1)
			expect(first.data.featherId).toBe(featherId)
			h.clock:advance(1)
			local second = h.collection:collect(
				2,
				{ sessionToken = h.token(2), origin = origin2, direction = direction2, toolId = "hand", featherId = featherId }
			)
			expect(second.ok).toBe(false)
			expect(second.code).toBe("already_done")
			expect(second.message).toBe("already_collected")
			expect(runtime.players[2].carriedStandard).toBe(0)
			expect(cell.remaining).toBe(cell.base - 1)
			-- The cell did not disappear because one feather left it; the next feather is now exposed.
			local next = h.collectAt(2, runtime, 6, 6)
			expect(next.ok).toBe(true)
			expect(next.data.featherId).never.toBe(featherId)
			expect(cell.remaining).toBe(cell.base - 2)
		end)

		it("rejects invalid phase, stale token, cooldown, out-of-range origin/aim, and wrong tool", function()
			local h = harness()
			h.join(1)
			local roundId, runtime = h.startRound({ 1 })
			local origin, direction, featherId = h.aimAt(1, runtime, 4, 4)
			local token = h.token(1)
			local function attempt(overrides)
				local payload = { sessionToken = token, origin = origin, direction = direction, toolId = "hand", featherId = featherId }
				for key, value in pairs(overrides) do
					payload[key] = value
				end
				return h.collection:collect(1, payload)
			end
			local stale = attempt({ sessionToken = "stale-token" })
			expect(stale.code).toBe("stale_token")
			local wrongTool = attempt({ toolId = "nestRake" })
			expect(wrongTool.code).toBe("not_authorized")
			local farOrigin = attempt({ origin = origin + Vector3.new(0, 0, 40) })
			expect(farOrigin.code).toBe("out_of_range")
			expect(farOrigin.message).toBe("origin")
			local up = attempt({ direction = Vector3.new(0, 1, 0) })
			expect(up.code).toBe("out_of_range")
			expect(up.message).toBe("aim")
			local noFeather = h.collection:collect(1, { sessionToken = token, origin = origin, direction = direction, toolId = "hand" })
			expect(noFeather.code).toBe("invalid_payload")
			local bogus = attempt({ featherId = 64 * 100000 + 1 })
			expect(bogus.code).toBe("not_found")
			h.standAt(1, layout.spawn)
			local tooFar = attempt({ origin = layout.spawn + Vector3.new(0, 1.5, 0), direction = Vector3.new(0, -0.3, 1).Unit })
			expect(tooFar.code).toBe("out_of_range")
			local first = h.collectAt(1, runtime, 4, 4)
			expect(first.ok).toBe(true)
			local origin2, direction2, featherId2 = h.aimAt(1, runtime, 4, 4)
			local cooldown = h.collection:collect(
				1,
				{ sessionToken = token, origin = origin2, direction = direction2, toolId = "hand", featherId = featherId2 }
			)
			expect(cooldown.code).toBe("rate_limited")
			expect(cooldown.message).toBe("cooldown")
			h.egg:checkReveal(runtime)
			h.rounds:markEggRevealed(roundId)
			local revealedPhase = h.collectAt(1, runtime, 4, 4)
			expect(revealedPhase.code).toBe("invalid_state")
		end)

		it("cooldown deadline comes from config and a hand click awards exactly one feather at any grasp level", function()
			local h = harness()
			h.join(1)
			local _, runtime = h.startRound({ 1 })
			local result = h.collectAt(1, runtime, 5, 5)
			expect(result.data.cooldownMs).toBe(math.floor(cfg.collection.baseHandCooldownSeconds * 1000))
			expect(result.data.awarded).toBe(1)
			-- Owner requirement (single-feather pickup): grasp levels no longer multiply the click yield.
			runtime.players[1].handLevels.grasp = 1
			local upgraded = h.collectAt(1, runtime, 5, 6)
			expect(upgraded.data.awarded).toBe(1)
			expect(upgraded.data.removed).toBe(1)
		end)
	end)

	describe("Selling", function()
		it("25 standard feathers sell for exactly 25 cents at the station and a duplicate pays once", function()
			local h = harness()
			h.join(1)
			local _, runtime = h.startRound({ 1 })
			local carried = 0
			local i = 0
			local bx, bz = runtime.grid.width // 2 - 2, runtime.grid.depth // 2 - 2
			while carried < cfg.collection.startingBagCapacity do
				carried = h.collectAt(1, runtime, bx + (i % 4), bz + math.floor(i / 4) % 4).data.carried
				i += 1
			end
			h.standAt(1, layout.spawn)
			local far = h.selling:sell(1, h.token(1))
			expect(far.code).toBe("out_of_range")
			h.standAt(1, layout.sellStation + Vector3.new(0, 3, 6))
			local sale = h.selling:sell(1, h.token(1))
			expect(sale.ok).toBe(true)
			-- One cent per standard feather; a Rainbow Feather the seed put in the block pays 10x.
			local rainbowCount = sale.data.rainbowCount or 0
			expect(sale.data.standardCount + rainbowCount).toBe(25)
			local expectedCents = sale.data.standardCount + rainbowCount * cfg.selling.rainbowFeatherMultiplier
			expect(sale.data.finalCents).toBe(expectedCents)
			expect(sale.data.cashCents).toBe(expectedCents)
			expect(EconomyMath.formatCents(sale.data.cashCents)).toBe(EconomyMath.formatCents(expectedCents))
			local duplicate = h.selling:sell(1, h.token(1))
			expect(duplicate.ok).toBe(false)
			expect(duplicate.code).toBe("already_done")
			expect(runtime.players[1].cashCents).toBe(expectedCents)
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
			-- Four base rows plus one acquisition row per configured tool (none owned yet).
			expect(#previews).toBe(4 + #ToolSpecs.TOOL_IDS)
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
		it("selected node is valid, stays concealed until its covering records are gone, reveals once", function()
			local h = harness()
			h.join(1)
			local roundId, runtime = h.startRound({ 1 })
			expect(EggNodes.byId(runtime.nodes, runtime.eggNode.id)).toBeTruthy()
			local floor = if runtime.eggLucky then cfg.eggSpawn.luckyMinimumRemovalFraction else cfg.eggSpawn.minimumRemovalFraction
			expect(runtime.eggDepthFraction).toBeGreaterThanOrEqual(floor)
			expect(runtime.eggDepthFraction).toBeLessThanOrEqual(cfg.eggSpawn.maximumRemovalFraction)
			expect(h.rounds:project(roundId, true).eggNodeId).toBeNil()
			local eggCell = runtime.grid.cells[PileGrid.index(runtime.grid.width, runtime.eggNode.x, runtime.eggNode.z)]
			expect(runtime.eggSlot).toBeGreaterThanOrEqual(2)
			expect(runtime.eggSlot).toBeLessThanOrEqual(eggCell.base)
			-- The Egg sits deep inside its column, below the surface and above the floor.
			local height = h.egg:buriedHeight(runtime)
			expect(height).toBeGreaterThan(0.5)
			expect(height).toBeLessThan(cfg.pile.maxVisualHeightStuds)
			-- Everything around the Egg gone, its own cover intact: still concealed.
			for _, index in ipairs(runtime.eggNode.coverIndexes) do
				if index ~= eggCell.index then
					local cell = runtime.grid.cells[index]
					PileGrid.remove(runtime.grid, cell, cell.remaining)
				end
			end
			expect(h.egg:checkReveal(runtime)).toBe(false)
			expect(runtime.eggCoverCleared).toBe(false)
			expect(runtime.state.phase).toBe("Searching")
			-- All but the last covering record: still concealed.
			PileGrid.remove(runtime.grid, eggCell, eggCell.remaining - runtime.eggSlot)
			expect(h.egg:checkReveal(runtime)).toBe(false)
			-- The last covering record reveals it, exactly once.
			PileGrid.remove(runtime.grid, eggCell, 1)
			expect(h.egg:checkReveal(runtime)).toBe(true)
			expect(runtime.eggCoverCleared).toBe(true)
			expect(runtime.state.phase).toBe("EggRevealed")
			expect(runtime.state.joinClosed).toBe(true)
			expect(h.egg:checkReveal(runtime)).toBe(false)
			expect(h.egg.stats.reveals).toBe(1)
			expect(h.analyticsAdapter:countOf("egg_revealed")).toBe(1)
		end)

		it("reveal triggers from a real collection hit on the last covering record", function()
			local h = harness()
			h.join(1)
			local _, runtime = h.startRound({ 1 })
			local eggCell = runtime.grid.cells[PileGrid.index(runtime.grid.width, runtime.eggNode.x, runtime.eggNode.z)]
			PileGrid.remove(runtime.grid, eggCell, eggCell.remaining - runtime.eggSlot)
			local revealed = false
			h.egg.revealed:Connect(function(_rt, position)
				revealed = true
				expect(typeof(position)).toBe("Vector3")
			end)
			runtime.players[1].carriedStandard = 0
			local result = h.collectAt(1, runtime, eggCell.x, eggCell.z)
			expect(result.ok).toBe(true)
			expect(revealed).toBe(true)
			expect(runtime.state.phase).toBe("EggRevealed")
		end)

		it("100 simultaneous claims choose one carrier; range and phase are enforced; the Farmer decides the win", function()
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
			expect(h.egg:carrier(runtime)).toBe(winners[1])
			expect(runtime.state.phase).toBe("EggRevealed")
			-- Only the carrier can hand it over, and only next to the Farmer.
			local other = (winners[1] % 4) + 1
			expect(h.egg:deliver(other, h.token(other)).message).toBe("not_carrier")
			expect(h.egg:deliver(winners[1], h.token(winners[1])).code).toBe("out_of_range")
			h.standAt(winners[1], ChapterLayout.chapter1.farmer)
			expect(h.egg:deliver(winners[1], h.token(winners[1])).ok).toBe(true)
			expect(runtime.state.victory.finderUserId).toBe(winners[1])
			expect(h.egg:drop(winners[1])).toBe(false)
		end)
	end)

	-- Picks the Egg up at its resting place, walks it to the Farmer and hands it over.
	local function winEgg(h, runtime, userId)
		local claim = h.egg:claim(userId, h.token(userId))
		expect(claim.ok).toBe(true)
		expect(claim.data.carrying).toBe(true)
		expect(runtime.state.phase).toBe("EggRevealed")
		h.standAt(userId, ChapterLayout.chapter1.farmer)
		return h.egg:deliver(userId, h.token(userId))
	end

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
			local delivered = winEgg(h, runtime, finder)
			expect(delivered.ok).toBe(true)
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
			expect(winEgg(h, runtime2, 1).ok).toBe(true)
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
			expect(winEgg(h, runtime, 1).ok).toBe(true)
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
			local ix, iz = runtime.grid.width // 2 - 4, runtime.grid.depth // 2 - 4
			h.collectAt(1, runtime, ix, iz)
			h.collectAt(1, runtime, ix, iz)
			h.collectAt(1, runtime, runtime.grid.width // 2, runtime.grid.depth // 2)
			expect(h.rounds:flushDeltas()).toBe(1)
			expect(#flushed).toBe(1)
			expect(#flushed[1].cells).toBe(2)
			expect(flushed[1].removed).toBe(3)
			expect(h.rounds:flushDeltas()).toBe(0)
		end)
	end)
end
