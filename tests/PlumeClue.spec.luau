--!nocheck
-- Professor Plume's clue rules: one vague clue, a half of the nest or a depth band, chosen by the
-- server's rolls; never both, never finer than a half.

return function(describe, it, expect)
	local ServerStorage = game:GetService("ServerStorage")
	local Shared = game:GetService("ReplicatedStorage").Shared
	local Config = require(Shared.Config)
	local PlumeClue = require(Shared.Domain.PlumeClue)
	local cfg = Config.fromRaw(require(ServerStorage.SFE.SystemConfig))

	describe("config", function()
		it("costs ten Rainbow Feathers by default with sane bands", function()
			expect(PlumeClue.cost(cfg)).toBe(10)
			expect(cfg.plume.depthBands.shallowBelow < cfg.plume.depthBands.deepFrom).toBe(true)
			expect(cfg.plume.directionChance >= 0 and cfg.plume.directionChance <= 1).toBe(true)
			expect(cfg.plume.requestCooldownSeconds).toBeGreaterThan(0)
			expect(cfg.plume.rod).toBe(nil)
			expect(cfg.plume.costsStandard).toBe(nil)
		end)
	end)

	describe("direction", function()
		it("names the half of the nest along the rolled axis", function()
			local w, d = 54, 54
			expect(PlumeClue.directionOf(w, d, 0, 40, 0.1)).toBe("barn")
			expect(PlumeClue.directionOf(w, d, 53, 40, 0.1)).toBe("fence")
			expect(PlumeClue.directionOf(w, d, 40, 0, 0.9)).toBe("back")
			expect(PlumeClue.directionOf(w, d, 40, 53, 0.9)).toBe("front")
			expect(PlumeClue.directionOf(w, d, 26, 26, 0.2)).toBe("barn")
			expect(PlumeClue.directionOf(w, d, 27, 27, 0.7)).toBe("front")
		end)
	end)

	describe("depth", function()
		it("bands the covering fraction", function()
			local bands = cfg.plume.depthBands
			expect(PlumeClue.depthOf(cfg, 0)).toBe("shallow")
			expect(PlumeClue.depthOf(cfg, bands.shallowBelow - 0.01)).toBe("shallow")
			expect(PlumeClue.depthOf(cfg, bands.shallowBelow)).toBe("middling")
			expect(PlumeClue.depthOf(cfg, bands.deepFrom - 0.01)).toBe("middling")
			expect(PlumeClue.depthOf(cfg, bands.deepFrom)).toBe("deep")
			expect(PlumeClue.depthOf(cfg, 1)).toBe("deep")
		end)
	end)

	describe("compose", function()
		local egg = { width = 54, depth = 54, cellX = 10, cellZ = 44, depthFraction = 0.7 }

		it("gives a direction below the chance and a depth at or above it, never both", function()
			local chance = cfg.plume.directionChance
			local direction = PlumeClue.compose(cfg, egg, chance / 2, 0.1)
			expect(direction.kind).toBe("direction")
			expect(direction.key).toBe("barn")
			expect(direction.text).toBe(PlumeClue.DIRECTIONS.barn.text)
			local other = PlumeClue.compose(cfg, egg, chance / 2, 0.9)
			expect(other.key).toBe("front")
			local depth = PlumeClue.compose(cfg, egg, math.min(0.999, chance + 0.01), 0.1)
			expect(depth.kind).toBe("depth")
			expect(depth.key).toBe("deep")
			expect(depth.title).toBe(PlumeClue.DEPTHS.deep.title)
			-- One clue: a direction never mentions depth and a depth never names a side.
			for _, key in ipairs({ "barn", "fence", "back", "front" }) do
				local text = string.lower(PlumeClue.DIRECTIONS[key].text)
				expect(string.find(text, "deep")).toBe(nil)
				expect(string.find(text, "surface")).toBe(nil)
			end
			for _, key in ipairs({ "shallow", "middling", "deep" }) do
				local text = string.lower(PlumeClue.DEPTHS[key].text)
				for _, side in ipairs({ "barn", "fence", "back", "front" }) do
					expect(string.find(text, side)).toBe(nil)
				end
			end
		end)

		it("carries only words: no cell, no position, no numbers", function()
			local clue = PlumeClue.compose(cfg, egg, 0, 0)
			local encoded = game:GetService("HttpService"):JSONEncode(clue)
			expect(string.find(encoded, "%d")).toBe(nil)
			for _, word in ipairs({ "cell", "position", "x", "z" }) do
				expect(clue[word]).toBe(nil)
			end
		end)
	end)

	describe("refusal", function()
		it("orders the reasons: egg out, phase, used, feathers", function()
			local base = { searching = true, eggOut = false, used = false, carriedRainbow = 10 }
			expect(PlumeClue.refusal(cfg, base)).toBe(nil)
			expect(PlumeClue.refusal(cfg, { searching = true, eggOut = false, used = false, carriedRainbow = 9 })).toBe("insufficient")
			expect(PlumeClue.refusal(cfg, { searching = true, eggOut = false, used = true, carriedRainbow = 9 })).toBe("used")
			expect(PlumeClue.refusal(cfg, { searching = false, eggOut = false, used = true, carriedRainbow = 99 })).toBe("phase")
			expect(PlumeClue.refusal(cfg, { searching = false, eggOut = true, used = true, carriedRainbow = 99 })).toBe("egg_found")
			expect(PlumeClue.lineFor(cfg, "insufficient")).toBe(string.format(PlumeClue.LINES.insufficient, 10))
			expect(PlumeClue.lineFor(cfg, nil)).toBe(PlumeClue.LINES.ready)
		end)
	end)
end
