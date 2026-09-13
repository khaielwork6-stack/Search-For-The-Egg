--!nocheck
-- Feather-pile collection authority (owner requirement): duplicate requests, line of sight, invalid
-- targets, death/leave/rejoin, cleanup between rounds, the terrain core's carve/hollow/clear calls,
-- Egg concealment, and configuration of the collision/visual blocks. Runs against the real services
-- through the gameplay harness with the mock terrain adapter.

return function(describe, it, expect)
	local ServerStorage = game:GetService("ServerStorage")
	local Shared = game:GetService("ReplicatedStorage").Shared
	local Config = require(Shared.Config)
	local PileGrid = require(Shared.Domain.PileGrid)
	local FeatherLayout = require(Shared.Domain.FeatherLayout)
	local ChapterLayout = require(Shared.Domain.ChapterLayout)
	local GameplayHarness = require(ServerStorage.Tests.Helpers.GameplayHarness)
	local cfg = Config.fromRaw(require(ServerStorage.SFE.SystemConfig))
	local layout = ChapterLayout.chapter1

	describe("Requests", function()
		it("a repeated request id is refused as a duplicate without a second award", function()
			local h = GameplayHarness.new(cfg)
			h.join(1)
			local _, runtime = h.startRound({ 1 })
			local origin, direction, featherId = h.aimAt(1, runtime, 8, 8)
			h.clock:advance(1)
			local payload =
				{ sessionToken = h.token(1), origin = origin, direction = direction, toolId = "hand", requestId = 7, featherId = featherId }
			local first = h.collection:collect(1, payload)
			expect(first.ok).toBe(true)
			h.clock:advance(1)
			local again = h.collection:collect(1, payload)
			expect(again.ok).toBe(false)
			expect(again.message).toBe("duplicate")
			expect(runtime.players[1].carriedStandard).toBe(1)
			payload.requestId = 8
			local _, _, nextFeather = h.aimAt(1, runtime, 8, 8)
			payload.featherId = nextFeather
			expect(h.collection:collect(1, payload).ok).toBe(true)
		end)

		it("a blocked line of sight is refused before any removal", function()
			local h = GameplayHarness.new(cfg)
			h.join(1)
			local _, runtime = h.startRound({ 1 })
			local before = runtime.grid.removed
			h.setLineOfSightBlocked(true)
			local result = h.collectAt(1, runtime, 8, 8)
			expect(result.ok).toBe(false)
			expect(result.message).toBe("line_of_sight")
			expect(runtime.grid.removed).toBe(before)
			h.setLineOfSightBlocked(false)
			expect(h.collectAt(1, runtime, 8, 8).ok).toBe(true)
		end)

		it("a feather out of range or off the aim direction is refused before any removal", function()
			local h = GameplayHarness.new(cfg)
			h.join(1)
			local _, runtime = h.startRound({ 1 })
			local origin, direction, featherId = h.aimAt(1, runtime, 8, 8)
			local centre = layout.nestCenter
			local far = Vector3.new(centre.X + 30, layout.nestBaseY + 2, centre.Z)
			h.standAt(1, far)
			h.clock:advance(1)
			local removed = runtime.grid.removed
			local result = h.collection:collect(1, {
				sessionToken = h.token(1),
				origin = far + Vector3.new(0, 1.5, 0),
				direction = (Vector3.new(origin.X, origin.Y, origin.Z) - far).Unit,
				toolId = "hand",
				featherId = featherId,
			})
			expect(result.ok).toBe(false)
			expect(result.code).toBe("out_of_range")
			expect(result.message).toBe("range")
			h.standAt(1, origin - Vector3.new(0, 1.5, 0))
			local sideways = h.collection:collect(
				1,
				{ sessionToken = h.token(1), origin = origin, direction = Vector3.new(1, 0, 0), toolId = "hand", featherId = featherId }
			)
			expect(sideways.ok).toBe(false)
			expect(sideways.message).toBe("aim")
			expect(runtime.grid.removed).toBe(removed)
			expect(
				h.collection:collect(
					1,
					{ sessionToken = h.token(1), origin = origin, direction = direction, toolId = "hand", featherId = featherId }
				).ok
			).toBe(true)
		end)

		it("a full bag removes nothing, awards nothing, and keeps the cell intact", function()
			local h = GameplayHarness.new(cfg)
			h.join(1)
			local _, runtime = h.startRound({ 1 })
			local player = runtime.players[1]
			local capacity = cfg.bags.levels[player.bagLevel].capacity
			player.carriedStandard = capacity
			local cell = runtime.grid.cells[8 * 16 + 8 + 1]
			local remaining, removed, carves = cell.remaining, runtime.grid.removed, h.pileTerrain.stats.carves
			for _ = 1, 3 do
				local result = h.collectAt(1, runtime, 8, 8)
				expect(result.ok).toBe(false)
				expect(result.message).toBe("bag_full")
			end
			expect(cell.remaining).toBe(remaining)
			expect(runtime.grid.removed).toBe(removed)
			expect(h.pileTerrain.stats.carves).toBe(carves)
			expect(player.carriedStandard).toBe(capacity)
		end)

		it("reports the strike point inside the awarded cell with the surface height", function()
			local h = GameplayHarness.new(cfg)
			h.join(1)
			local _, runtime = h.startRound({ 1 })
			local result = h.collectAt(1, runtime, 5, 9)
			expect(result.ok).toBe(true)
			local cell = runtime.grid.cells[result.data.cellIndex]
			local grid = runtime.grid
			local minCorner = ChapterLayout.gridMinCorner(layout, grid.width, grid.depth, grid.cellSize)
			local lx, lz = PileGrid.cellCenter(grid, cell)
			expect(math.abs(result.data.hitX - (minCorner.X + lx))).toBeLessThanOrEqual(grid.cellSize / 2 + 1e-6)
			expect(math.abs(result.data.hitZ - (minCorner.Z + lz))).toBeLessThanOrEqual(grid.cellSize / 2 + 1e-6)
			expect(result.data.hitY).toBeGreaterThan(layout.nestBaseY)
		end)
	end)

	describe("Single feather", function()
		it("a click removes exactly the targeted record, awards one, and leaves every other feather untouched", function()
			local h = GameplayHarness.new(cfg)
			h.join(1)
			local _, runtime = h.startRound({ 1 })
			local before = PileGrid.snapshot(runtime.grid)
			local cell = runtime.grid.cells[7 * 16 + 9 + 1]
			local _, _, featherId = h.aimAt(1, runtime, 9, 7)
			local _, slot = FeatherLayout.decode(featherId)
			expect(slot).toBe(cell.base) -- the exposed top of the stack
			local result = h.collectAt(1, runtime, 9, 7)
			expect(result.ok).toBe(true)
			expect(result.data.awarded).toBe(1)
			expect(result.data.removed).toBe(1)
			expect(result.data.featherId).toBe(featherId)
			expect(runtime.players[1].carriedStandard).toBe(1)
			expect(cell.remaining).toBe(cell.base - 1)
			expect(PileGrid.isTaken(cell, slot)).toBe(true)
			local after = PileGrid.snapshot(runtime.grid)
			for index = 1, #before.remaining do
				if index ~= cell.index then
					expect(after.remaining[index]).toBe(before.remaining[index])
					expect(after.masks[index]).toBe(before.masks[index])
				end
			end
			expect(after.masks[cell.index]).toBe(bit32.lshift(1, slot - 1))
		end)

		it("only exposed records are collectible: a buried slot is refused, the next slot opens as the stack recedes", function()
			local h = GameplayHarness.new(cfg)
			h.join(1)
			local _, runtime = h.startRound({ 1 })
			local cell = runtime.grid.cells[7 * 16 + 9 + 1]
			expect(cell.base).toBeGreaterThanOrEqual(4)
			local origin, direction = h.aimAt(1, runtime, 9, 7)
			local visible = cfg.pile.visual.visibleSlotsPerCell
			local function collectSlot(slot)
				h.clock:advance(1)
				return h.collection:collect(1, {
					sessionToken = h.token(1),
					origin = origin,
					direction = direction,
					toolId = "hand",
					featherId = FeatherLayout.featherId(cell.index, slot),
				})
			end
			local buried = collectSlot(1)
			expect(buried.ok).toBe(false)
			expect(buried.message).toBe("not_exposed")
			-- The second exposed slot (partly visible under the top) is collectible without taking the top.
			local second = collectSlot(cell.base - visible + 1)
			expect(second.ok).toBe(true)
			expect(cell.remaining).toBe(cell.base - 1)
			expect(PileGrid.isTaken(cell, cell.base)).toBe(false)
			-- Taking the top exposes the slot below it.
			expect(collectSlot(cell.base).ok).toBe(true)
			local exposed = FeatherLayout.exposedSlots(cell.base, cell.taken, visible)
			expect(#exposed).toBe(math.min(visible, cell.remaining))
			expect(exposed[1]).toBe(cell.base - visible)
			expect(collectSlot(exposed[1]).ok).toBe(true)
			expect(collectSlot(exposed[1]).message).toBe("already_collected")
			-- The cell persists until its last record is gone.
			while cell.remaining > 0 do
				local top = PileGrid.topSlot(cell)
				expect(collectSlot(top).ok).toBe(true)
			end
			expect(cell.remaining).toBe(0)
			expect(collectSlot(1).message).toBe("already_collected")
		end)

		it("feather ids and placements are deterministic and malformed ids are rejected", function()
			local id = FeatherLayout.featherId(137, 5)
			local index, slot = FeatherLayout.decode(id)
			expect(index).toBe(137)
			expect(slot).toBe(5)
			expect(FeatherLayout.decode(0)).toBeNil()
			expect(FeatherLayout.decode(64)).toBeNil() -- slot 0
			expect(FeatherLayout.decode(1.5)).toBeNil()
			expect(FeatherLayout.decode("x")).toBeNil()
			local a = FeatherLayout.placement(cfg.pile.visual, 137, 5, cfg.pile.cellSizeStuds)
			local b = FeatherLayout.placement(cfg.pile.visual, 137, 5, cfg.pile.cellSizeStuds)
			expect(a.ox).toBe(b.ox)
			expect(a.yaw).toBe(b.yaw)
			expect(a.length).toBe(b.length)
			expect(math.abs(a.ox)).toBeLessThanOrEqual(cfg.pile.cellSizeStuds * cfg.pile.visual.featherSpreadFraction / 2)
			expect(a.length).toBeGreaterThanOrEqual(cfg.pile.visual.featherLengthRange[1])
			expect(a.length).toBeLessThanOrEqual(cfg.pile.visual.featherLengthRange[2])
			local c = FeatherLayout.placement(cfg.pile.visual, 137, 6, cfg.pile.cellSizeStuds)
			expect(c.ox == a.ox and c.yaw == a.yaw).toBe(false)
			expect(FeatherLayout.exposedSlots(6, 0, 2)[1]).toBe(6)
			expect(FeatherLayout.exposedSlots(6, 0, 2)[2]).toBe(5)
			expect(FeatherLayout.exposedSlots(6, bit32.lshift(1, 5), 2)[1]).toBe(5)
			expect(#FeatherLayout.exposedSlots(6, 63, 2)).toBe(0)
		end)

		it("replicated deltas carry the remaining count and the taken mask of the touched cell", function()
			local h = GameplayHarness.new(cfg)
			h.join(1)
			local _, runtime = h.startRound({ 1 })
			local result = h.collectAt(1, runtime, 8, 8)
			expect(result.ok).toBe(true)
			expect(result.data.mask).toBe(bit32.lshift(1, result.data.slot - 1))
			local pending = runtime.pendingDelta[result.data.cellIndex]
			expect(pending.r).toBe(result.data.remaining)
			expect(pending.m).toBe(result.data.mask)
			h.rounds:flushDeltas()
			expect(runtime.pendingDelta[result.data.cellIndex]).toBeNil()
		end)
	end)

	describe("Player state", function()
		it("a dead player cannot collect and a player who left has no round", function()
			local h = GameplayHarness.new(cfg)
			h.join(1)
			h.join(2)
			local _, runtime = h.startRound({ 1, 2 })
			runtime.players[1].alive = false
			local dead = h.collectAt(1, runtime, 8, 8)
			expect(dead.ok).toBe(false)
			expect(dead.message).toBe("not_alive")
			runtime.players[1].alive = true
			local staleToken = h.token(2)
			local origin, direction = h.aimAt(2, runtime, 8, 8)
			h.sessions:close(2)
			local removedBefore = runtime.grid.removed
			local gone = h.collection:collect(2, { sessionToken = staleToken, origin = origin, direction = direction, toolId = "hand" })
			expect(gone.ok).toBe(false)
			expect(runtime.grid.removed).toBe(removedBefore)
		end)

		it("a rejoining player receives the current pile without the Egg position", function()
			local h = GameplayHarness.new(cfg)
			h.join(1)
			local _, runtime = h.startRound({ 1 })
			h.collectAt(1, runtime, 8, 8)
			h.collectAt(1, runtime, 8, 8)
			local snapshot = h.rounds:project(runtime.state.roundId, true)
			expect(snapshot.pile).toBeTruthy()
			expect(#snapshot.pile.remaining).toBe(runtime.grid.width * runtime.grid.depth)
			expect(snapshot.pile.remaining[runtime.grid.cells[8 * 16 + 8 + 1].index]).toBe(runtime.grid.cells[8 * 16 + 8 + 1].remaining)
			local encoded = game:GetService("HttpService"):JSONEncode(snapshot)
			expect(string.find(encoded, "eggNode", 1, true)).toBeNil()
			expect(string.find(encoded, "coverIndexes", 1, true)).toBeNil()
			expect(snapshot.eggPosition).toBeNil()
		end)
	end)

	describe("Terrain core", function()
		it("builds on round start, dents and re-writes at every accepted strike, hollows at reveal, and clears on return", function()
			local h = GameplayHarness.new(cfg)
			h.join(1)
			local roundId, runtime = h.startRound({ 1 })
			expect(h.terrainAdapter.writes).toBe(1)
			expect(h.terrainAdapter.field.apex).toBe(cfg.pile.maxVisualHeightStuds)
			local result = h.collectAt(1, runtime, 8, 8)
			expect(result.ok).toBe(true)
			expect(h.pileTerrain.stats.carves).toBe(1)
			expect(#h.terrainAdapter.regionWrites).toBe(1)
			-- The re-written region covers the strike plus the configured margin.
			local region = h.terrainAdapter.regionWrites[1]
			local margin = cfg.pile.collision.rewriteMarginCells * runtime.grid.cellSize
			expect(region.minX).toBeLessThanOrEqual(result.data.hitX - margin + 1e-6)
			expect(region.maxX).toBeGreaterThanOrEqual(result.data.hitX + margin - 1e-6)
			-- Cell health became geometry: the field the adapter received is depleted at the struck cell.
			expect(h.terrainAdapter.field.fractions[result.data.cellIndex]).toBeLessThan(1)
			-- The intended surface at the strike is the analytic surface minus one strike dent.
			local depthOne = h.pileTerrain:dentDepthAt(runtime, result.data.hitX, result.data.hitZ)
			expect(depthOne).toBeCloseTo(cfg.pile.collision.strikeDentDepthStuds, 1e-9)
			local surfaceOne = h.pileTerrain:intendedSurfaceY(runtime, result.data.hitX, result.data.hitZ)
			expect(surfaceOne).toBeLessThan(result.data.hitY)
			-- Repeated strikes at one spot deepen the pit (every feather of the cell, then its neighbours).
			local strikes = 1
			for _, offset in ipairs({ { 0, 0 }, { 1, 0 }, { 0, 1 }, { 1, 1 } }) do
				local cell = runtime.grid.cells[(8 + offset[2]) * 16 + (8 + offset[1]) + 1]
				while cell.remaining > 0 and strikes < 10 do
					expect(h.collectAt(1, runtime, 8 + offset[1], 8 + offset[2]).ok).toBe(true)
					strikes += 1
				end
			end
			expect(h.pileTerrain.stats.carves).toBe(10)
			expect(h.pileTerrain:intendedSurfaceY(runtime, result.data.hitX, result.data.hitZ)).toBeLessThan(surfaceOne - 1)
			-- Away from every strike there is no dent.
			expect(h.pileTerrain:dentDepthAt(runtime, result.data.hitX + 12, result.data.hitZ)).toBe(0)
			-- Rejected strikes never dent or re-write.
			runtime.players[1].alive = false
			local carves, writes = h.pileTerrain.stats.carves, #h.terrainAdapter.regionWrites
			h.collectAt(1, runtime, 8, 8)
			expect(h.pileTerrain.stats.carves).toBe(carves)
			expect(#h.terrainAdapter.regionWrites).toBe(writes)
			runtime.players[1].alive = true
			-- Reveal opens a hollow; returning clears the mound and the dent map.
			h.rounds:markEggRevealed(roundId)
			local hollows = h.pileTerrain.stats.hollows
			local eggPosition = h.egg:position(runtime)
			h.egg.revealed:Fire(runtime, eggPosition)
			expect(h.pileTerrain.stats.hollows).toBe(hollows + 1)
			expect(h.pileTerrain:dentDepthAt(runtime, eggPosition.X, eggPosition.Z)).toBeGreaterThanOrEqual(
				cfg.pile.collision.eggHollowDepthStuds
			)
			h.rounds:claim(roundId, 1, h.token(1))
			h.rounds:commitAndFinish(roundId, function()
				return true
			end)
			h.rounds:returnToLobby(roundId)
			expect(h.terrainAdapter.clears).toBe(1)
			expect(#h.terrainAdapter.regionWrites).toBe(0)
			expect(h.pileTerrain:dentDepthAt(runtime, result.data.hitX, result.data.hitZ)).toBe(0)
		end)

		it("a fresh round starts with a full grid and a new mound", function()
			local h = GameplayHarness.new(cfg)
			h.join(1)
			local roundId, runtime = h.startRound({ 1 })
			h.collectAt(1, runtime, 8, 8)
			h.rounds:markEggRevealed(roundId)
			h.rounds:claim(roundId, 1, h.token(1))
			h.rounds:commitAndFinish(roundId, function()
				return true
			end)
			h.rounds:returnToLobby(roundId)
			local _, second = h.startRound({ 1 })
			expect(second.grid.removed).toBe(0)
			expect(h.terrainAdapter.writes).toBe(2)
			for _, cell in ipairs(second.grid.cells) do
				expect(cell.remaining).toBe(cell.base)
			end
		end)
	end)

	describe("Egg concealment", function()
		it("the Egg is never projected or revealed before its cover clears and the depth is reached", function()
			local h = GameplayHarness.new(cfg)
			h.join(1)
			local _, runtime = h.startRound({ 1 })
			expect(runtime.state.phase).toBe("Searching")
			local revealed = false
			h.egg.revealed:Connect(function()
				revealed = true
			end)
			-- Clear everything except the cover: still concealed.
			h.clearGridExcept(runtime, runtime.eggNode.coverIndexes)
			expect(h.egg.stats.reveals).toBe(0)
			expect(revealed).toBe(false)
			expect(runtime.state.phase).toBe("Searching")
			-- Cover strikes reveal it exactly once.
			for _, index in ipairs(runtime.eggNode.coverIndexes) do
				local cell = runtime.grid.cells[index]
				while cell.remaining > 0 do
					runtime.players[1].carriedStandard = 0 -- keep the bag open; the full-bag rule has its own test
					local result = h.collectAt(1, runtime, cell.x, cell.z)
					expect(result.ok).toBe(true)
				end
			end
			expect(revealed).toBe(true)
			expect(runtime.state.phase).toBe("EggRevealed")
			expect(h.pileTerrain.stats.hollows).toBe(1)
		end)
	end)

	describe("Configuration", function()
		it("validates the collision and visual blocks", function()
			local raw = require(ServerStorage.SFE.SystemConfig)
			expect(Config.validate(raw).ok).toBe(true)
			local function withPile(mutate)
				local copy = table.clone(raw)
				copy.pile = table.clone(raw.pile)
				copy.pile.collision = table.clone(raw.pile.collision)
				copy.pile.visual = table.clone(raw.pile.visual)
				mutate(copy.pile)
				return Config.validate(copy)
			end
			expect(withPile(function(p)
				p.collision.kind = "parts"
			end).ok).toBe(false)
			expect(withPile(function(p)
				p.visual.partBudgetMobile = p.visual.partBudgetDesktop + 1
			end).ok).toBe(false)
			expect(withPile(function(p)
				p.visual.featherLengthRange = { 3, 1 }
			end).ok).toBe(false)
			expect(withPile(function(p)
				p.visual.visibleSlotsPerCell = 9
			end).ok).toBe(false)
			expect(withPile(function(p)
				p.baseFeathersPerCell = 40 -- densest cover cell would exceed the 63-slot feather id
			end).ok).toBe(false)
		end)
	end)
end
