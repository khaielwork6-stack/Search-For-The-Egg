--!nocheck
-- Professor Plume's Egg Sense arithmetic: configured loan costs, quantised heat from distance,
-- the tick rate that follows it, the crystal colour, Plume's lines, and a projection that carries
-- no coordinates.

return function(describe, it, expect)
	local ServerStorage = game:GetService("ServerStorage")
	local Shared = game:GetService("ReplicatedStorage").Shared
	local Config = require(Shared.Config)
	local EggSense = require(Shared.Domain.EggSense)
	local cfg = Config.fromRaw(require(ServerStorage.SFE.SystemConfig))
	local rod = cfg.plume.rod
	local costs = cfg.plume.costsStandard
	local egg = { x = 3, y = 55, z = 370 }

	local function at(distance, direction)
		direction = direction or { 1, 0, 0 }
		return { x = egg.x + direction[1] * distance, y = egg.y + direction[2] * distance, z = egg.z + direction[3] * distance }
	end

	describe("costs", function()
		it("charges 100, 200 then 400 normal feathers in order and stops at three loans", function()
			expect(costs[1]).toBe(100)
			expect(costs[2]).toBe(200)
			expect(costs[3]).toBe(400)
			expect(EggSense.nextCost(cfg, 0)).toBe(costs[1])
			expect(EggSense.nextCost(cfg, 1)).toBe(costs[2])
			expect(EggSense.nextCost(cfg, 2)).toBe(costs[3])
			expect(EggSense.nextCost(cfg, 3)).toBe(nil)
			expect(EggSense.maxUses(cfg)).toBe(3)
			expect(EggSense.maxUses(cfg)).toBe(cfg.plume.maxPerRound)
		end)
	end)

	describe("heat", function()
		it("is 1 on the Egg, 0 at the radius and beyond, and falls linearly between", function()
			expect(EggSense.heatFor(cfg, egg, egg)).toBe(1)
			expect(EggSense.heatFor(cfg, at(rod.radiusStuds), egg)).toBe(0)
			expect(EggSense.heatFor(cfg, at(rod.radiusStuds * 3), egg)).toBe(0)
			expect(EggSense.heatFor(cfg, at(rod.radiusStuds / 2), egg)).toBe(0.5)
			expect(EggSense.heatFor(cfg, at(rod.radiusStuds / 4), egg)).toBe(0.75)
		end)

		it("uses the full 3D distance, so a buried Egg reads warmer as the nest above it goes", function()
			local above = EggSense.heatFor(cfg, at(4, { 0, 1, 0 }), egg)
			local beside = EggSense.heatFor(cfg, at(4, { 1, 0, 0 }), egg)
			local diagonal = EggSense.heatFor(cfg, at(4, { 0.6, 0.8, 0 }), egg)
			expect(above).toBe(beside)
			expect(diagonal).toBe(above)
			expect(EggSense.heatFor(cfg, at(2, { 0, 1, 0 }), egg)).toBeGreaterThan(above)
		end)

		it("is quantised to 0.05 so two readings a hair apart come back identical", function()
			expect(EggSense.HEAT_STEP).toBe(0.05)
			local a = EggSense.heatFor(cfg, at(3.30), egg)
			local b = EggSense.heatFor(cfg, at(3.34), egg)
			expect(a).toBe(b)
			expect(math.abs(a - 0.75)).toBeLessThan(1e-9)
			for step = 0, 40 do
				local heat = EggSense.heatFor(cfg, at(step * rod.radiusStuds / 40), egg)
				local units = heat / EggSense.HEAT_STEP
				expect(math.abs(units - math.floor(units + 0.5))).toBeLessThan(1e-9)
				expect(heat).toBeGreaterThanOrEqual(0)
				expect(heat).toBeLessThanOrEqual(1)
			end
			expect(EggSense.quantise(0.974)).toBe(0.95)
			expect(EggSense.quantise(0.976)).toBe(1)
			expect(EggSense.quantise(-3)).toBe(0)
			expect(EggSense.quantise(9)).toBe(1)
		end)

		it("never reads warmer further away", function()
			local last = 2
			for step = 0, 60 do
				local heat = EggSense.heatFor(cfg, at(step * 0.3), egg)
				expect(heat).toBeLessThanOrEqual(last)
				last = heat
			end
		end)

		it("locks at 0.95 and above", function()
			expect(EggSense.isLocked(0.95)).toBe(true)
			expect(EggSense.isLocked(1)).toBe(true)
			expect(EggSense.isLocked(0.9)).toBe(false)
		end)
	end)

	describe("tick rate", function()
		it("runs from the cold rate to the hot rate with heat", function()
			expect(EggSense.tickHzFor(cfg, 0)).toBe(rod.minTickHz)
			expect(EggSense.tickHzFor(cfg, 1)).toBe(rod.maxTickHz)
			expect(math.abs(EggSense.tickHzFor(cfg, 0.5) - (rod.minTickHz + rod.maxTickHz) / 2)).toBeLessThan(1e-9)
			expect(EggSense.tickHzFor(cfg, -1)).toBe(rod.minTickHz)
			expect(EggSense.tickHzFor(cfg, 2)).toBe(rod.maxTickHz)
			expect(math.abs(EggSense.tickIntervalFor(cfg, 1) - 1 / rod.maxTickHz)).toBeLessThan(1e-9)
			expect(rod.minTickHz).toBe(1.2)
			expect(rod.maxTickHz).toBe(9)
		end)

		it("only ever quickens as heat rises", function()
			local last = 0
			for step = 0, 20 do
				local hz = EggSense.tickHzFor(cfg, step / 20)
				expect(hz).toBeGreaterThanOrEqual(last)
				last = hz
			end
		end)
	end)

	describe("colour", function()
		it("runs from the cold colour to the warm colour", function()
			local r, g, b = EggSense.colorFor(cfg, 0)
			expect(r).toBe(rod.coldColor[1])
			expect(g).toBe(rod.coldColor[2])
			expect(b).toBe(rod.coldColor[3])
			r, g, b = EggSense.colorFor(cfg, 1)
			expect(r).toBe(rod.warmColor[1])
			expect(g).toBe(rod.warmColor[2])
			expect(b).toBe(rod.warmColor[3])
			local mr = EggSense.colorFor(cfg, 0.5)
			expect(mr).toBe((rod.coldColor[1] + rod.warmColor[1]) / 2)
		end)
	end)

	describe("state and projection", function()
		it("projects counters, prices and live loans as seconds left - never a position or a timestamp", function()
			local state = EggSense.newState()
			expect(state.count).toBe(0)
			state.count = 2
			state.activeUntilByUserId[7] = 1010
			state.activeUntilByUserId[9] = 990 -- already over
			local projection = EggSense.project(cfg, state, 1000)
			expect(projection.count).toBe(2)
			expect(projection.usesLeft).toBe(1)
			expect(projection.max).toBe(3)
			expect(projection.nextCost).toBe(costs[3])
			expect(projection.activeSeconds).toBe(rod.activeSeconds)
			expect(#projection.costs).toBe(#costs)
			expect(#projection.active).toBe(1)
			expect(projection.active[1].userId).toBe(7)
			expect(projection.active[1].remainingMs).toBe(10000)
			local encoded = game:GetService("HttpService"):JSONEncode(projection)
			expect(string.find(encoded, "activeUntil")).toBe(nil)
			expect(string.find(encoded, "heat")).toBe(nil)
			expect(string.find(encoded, "egg")).toBe(nil)
			local empty = EggSense.project(cfg, nil, 0)
			expect(empty.count).toBe(0)
			expect(empty.usesLeft).toBe(3)
			expect(empty.nextCost).toBe(costs[1])
			expect(#empty.active).toBe(0)
		end)

		it("picks Plume's line from progress, the bag, the rod and the Egg", function()
			expect(EggSense.lineFor(cfg, 0, 0, false, false)).toBe(EggSense.LINES.none)
			expect(EggSense.lineFor(cfg, 0, costs[1], false, false)).toBe(EggSense.LINES.none)
			expect(EggSense.lineFor(cfg, 1, costs[2] - 1, false, false)).toBe(EggSense.LINES.insufficient)
			expect(EggSense.lineFor(cfg, 1, costs[2], false, false)).toBe(EggSense.LINES.none)
			expect(EggSense.lineFor(cfg, 3, 9999, false, false)).toBe(EggSense.LINES.limit)
			expect(EggSense.lineFor(cfg, 1, 9999, false, true)).toBe(EggSense.LINES.active)
			expect(EggSense.lineFor(cfg, 0, 9999, true, true)).toBe(EggSense.LINES.found)
			for _, key in ipairs({ "none", "insufficient", "lend", "active", "expired", "limit", "found" }) do
				expect(type(EggSense.LINES[key])).toBe("string")
				expect(#EggSense.LINES[key]).toBeGreaterThan(0)
			end
		end)

		it("carries no band words anywhere", function()
			local encoded = game:GetService("HttpService"):JSONEncode(EggSense.LINES)
			for _, band in ipairs({ "BARN SIDE", "FENCE SIDE", "NEST CORE", "PACKED MIDDLE", "OUTER LAYER" }) do
				expect(string.find(encoded, band, 1, true)).toBe(nil)
			end
		end)
	end)
end
