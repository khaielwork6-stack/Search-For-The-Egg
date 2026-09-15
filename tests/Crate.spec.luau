--!nocheck
-- Crate run (owner requirement): one sale starts one run, the crate is busy for the whole timeline,
-- a second sale during the run is refused with no reward, the run finishes on schedule, and the
-- terrain rewrites only at record thresholds.

return function(describe, it, expect)
	local ServerStorage = game:GetService("ServerStorage")
	local Shared = game:GetService("ReplicatedStorage").Shared
	local PileGrid = require(Shared.Domain.PileGrid)
	local Server = game:GetService("ServerScriptService").Server
	local Config = require(Shared.Config)
	local CrateService = require(Server.Services.CrateService)
	local GameplayHarness = require(ServerStorage.Tests.Helpers.GameplayHarness)
	local ChapterLayout = require(Shared.Domain.ChapterLayout)
	local cfg = Config.fromRaw(require(ServerStorage.SFE.SystemConfig))
	local layout = ChapterLayout.chapter1

	local function fakeClock()
		local now = 0
		return {
			monotonic = function()
				return now
			end,
			advance = function(seconds)
				now += seconds
			end,
		}
	end

	describe("Timeline", function()
		it("covers lift, both belts, the machine, the pit approach, the tip, the fall, and the reset", function()
			local crate = CrateService.new({ config = cfg, clock = fakeClock(), schedule = function() end })
			local names = {}
			for _, segment in ipairs(crate:timeline("chapter1")) do
				table.insert(names, segment.name)
				expect(segment.seconds).toBeGreaterThanOrEqual(0)
			end
			expect(table.concat(names, ",")).toBe("lift,frontBelt,machine,turn,sideBelt,toPit,tip,fall,reset")
			local speed = cfg.selling.crate.beltStudsPerSecond
			local front = (layout.crate.frontBeltStart - layout.crate.machineEntry).Magnitude / speed
			expect(crate:timeline("chapter1")[2].seconds).toBeCloseTo(front, 1e-9)
			expect(crate:totalSeconds("chapter1")).toBeGreaterThan(5)
		end)
	end)

	describe("Gate", function()
		it("is free until a run starts, busy for the whole run, and free again when the schedule fires", function()
			local clock = fakeClock()
			local fired = nil
			local crate = CrateService.new({
				config = cfg,
				clock = clock,
				schedule = function(seconds, callback)
					fired = { seconds = seconds, callback = callback }
				end,
			})
			expect(crate:gate()).toBeNil()
			local started = {}
			crate.runStarted:Connect(function(roundId, payload)
				table.insert(started, { roundId = roundId, payload = payload })
			end)
			local payload = crate:start("round-1", "chapter1", 25, 1)
			expect(payload.featherCount).toBe(25)
			expect(#payload.timeline).toBe(9)
			expect(#started).toBe(1)
			expect(crate:isBusy()).toBe(true)
			local refused = crate:gate()
			expect(refused.ok).toBe(false)
			expect(refused.message).toBe("crate_busy")
			expect(fired.seconds).toBeCloseTo(crate:totalSeconds("chapter1"), 1e-9)
			-- Time passes but the schedule has not fired: still busy.
			clock.advance(fired.seconds - 0.01)
			expect(crate:isBusy()).toBe(true)
			clock.advance(0.02)
			expect(crate:isBusy()).toBe(false) -- the clock guard alone frees it
			local finished = 0
			crate.runFinished:Connect(function()
				finished += 1
			end)
			fired.callback()
			expect(finished).toBe(1)
			expect(crate:gate()).toBeNil()
			expect(crate.stats.runs).toBe(1)
			expect(crate.stats.refused).toBe(1)
		end)

		it("a stale schedule callback from an older run never frees a newer run", function()
			local clock = fakeClock()
			local callbacks = {}
			local crate = CrateService.new({
				config = cfg,
				clock = clock,
				schedule = function(_, callback)
					table.insert(callbacks, callback)
				end,
			})
			crate:start("r", "chapter1", 1, 1)
			crate:reset()
			crate:start("r", "chapter1", 1, 1)
			callbacks[1]()
			expect(crate:isBusy()).toBe(true)
			callbacks[2]()
			expect(crate:isBusy()).toBe(false)
		end)
	end)

	describe("Selling through the crate", function()
		it("sells once, clears the bag, and refuses a second sale while the crate is away", function()
			local h = GameplayHarness.new(cfg)
			h.join(1)
			local _, runtime = h.startRound({ 1 })
			-- Cells inside the dome: the square grid's corners hold no records at all.
			local mx, mz = runtime.grid.width // 2 - 3, runtime.grid.depth // 2
			for i = 0, 5 do
				expect(h.collectAt(1, runtime, mx + i, mz).ok).toBe(true)
			end
			local state = runtime.players[1]
			expect(state.carriedStandard).toBe(6)
			local crate = CrateService.new({ config = cfg, clock = h.clock, schedule = function() end })
			local gate = function()
				return crate:gate()
			end
			h.standAt(1, layout.sellStation + Vector3.new(0, 3, 4))
			local sale = h.selling:sell(1, h.token(1), { gate = gate })
			expect(sale.ok).toBe(true)
			expect(sale.data.standardCount).toBe(6)
			expect(state.carriedStandard).toBe(0)
			crate:start(runtime.state.roundId, "chapter1", sale.data.standardCount, 1)
			-- Gather one more and try again mid-run: refused, nothing changes.
			expect(h.collectAt(1, runtime, mx + 8, mz).ok).toBe(true)
			h.standAt(1, layout.sellStation + Vector3.new(0, 3, 4))
			local cashBefore = state.cashCents
			local again = h.selling:sell(1, h.token(1), { gate = gate })
			expect(again.ok).toBe(false)
			expect(again.message).toBe("crate_busy")
			expect(state.carriedStandard).toBe(1)
			expect(state.cashCents).toBe(cashBefore)
			-- A trusted (click detector) sale needs no token but obeys the same gate and empty-bag rule.
			h.clock:advance(crate:totalSeconds("chapter1") + 1)
			local clicked = h.selling:sell(1, nil, { trusted = true, gate = gate })
			expect(clicked.ok).toBe(true)
			expect(state.carriedStandard).toBe(0)
			local empty = h.selling:sell(1, nil, { trusted = true, gate = gate })
			expect(empty.ok).toBe(false)
			expect(empty.message).toBe("nothing_to_sell")
		end)
	end)

	describe("Terrain thresholds", function()
		it("re-writes voxels only every N records of a cell (and when it empties)", function()
			local h = GameplayHarness.new(cfg)
			h.join(1)
			local _, runtime = h.startRound({ 1 })
			local every = cfg.pile.collision.rewriteEveryRecords
			local cell = runtime.grid.cells[PileGrid.index(runtime.grid.width, runtime.grid.width // 2, runtime.grid.depth // 2)]
			expect(cell.base).toBeGreaterThanOrEqual(every + 1)
			local writes = #h.terrainAdapter.regionWrites
			for i = 1, every - 1 do
				expect(h.collectAt(1, runtime, runtime.grid.width // 2, runtime.grid.depth // 2).ok).toBe(true)
				expect(#h.terrainAdapter.regionWrites).toBe(writes) -- no rewrite yet
				expect(h.pileTerrain.stats.carves).toBe(i) -- dents are still recorded
			end
			expect(h.collectAt(1, runtime, runtime.grid.width // 2, runtime.grid.depth // 2).ok).toBe(true)
			expect(#h.terrainAdapter.regionWrites).toBe(writes + 1)
			while cell.remaining > 0 do
				runtime.players[1].carriedStandard = 0 -- the column outlasts one bag; keep the bag open
				expect(h.collectAt(1, runtime, runtime.grid.width // 2, runtime.grid.depth // 2).ok).toBe(true)
			end
			expect(#h.terrainAdapter.regionWrites).toBeGreaterThanOrEqual(writes + 2) -- the empty cell forced one
		end)
	end)
end
