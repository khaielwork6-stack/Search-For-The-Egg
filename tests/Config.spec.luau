--!nocheck
-- Configuration validation, immutability, and client projection.

return function(describe, it, expect)
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local ServerStorage = game:GetService("ServerStorage")
	local Shared = ReplicatedStorage.Shared
	local Config = require(Shared.Config)
	local Validator = require(Shared.Config.Validator)
	local Projection = require(Shared.Config.Projection)
	local DeepFreeze = require(Shared.Util.DeepFreeze)
	local TableUtil = require(Shared.Util.TableUtil)

	local function rawConfig()
		return TableUtil.deepCopy(require(ServerStorage.SFE.SystemConfig))
	end

	describe("SYSTEM_CONFIG", function()
		it("parses and validates with zero errors", function()
			local report = Validator.validate(rawConfig())
			expect(report.errors).toEqual({})
			expect(report.ok).toBe(true)
			expect(report.checks).toBeGreaterThan(100)
		end)

		it("has a positive configVersion", function()
			expect(rawConfig().configVersion).toBeGreaterThan(0)
		end)

		it("class weights total exactly 100", function()
			local total = 0
			for _, entry in ipairs(rawConfig().classes.weights) do
				total += entry.weight
			end
			expect(total).toBeCloseTo(100, 1e-9)
			expect(#rawConfig().classes.weights).toBe(8)
		end)

		it("event chest weights total exactly 100", function()
			local total = 0
			for _, entry in ipairs(rawConfig().monetization.eventChest.rewards) do
				total += entry.weight
			end
			expect(total).toBeCloseTo(100, 1e-9)
		end)

		it("terminal levels carry null costs (JSON null becomes nil)", function()
			local raw = rawConfig()
			local bags = raw.bags.levels
			expect(bags[#bags].upgradeCash).toBeNil()
			expect(bags[1].upgradeCash).toBe(1)
			local sweep = raw.toolUpgrades.nestRake.sweep
			expect(sweep[#sweep].nextCash).toBeNil()
			expect(sweep[1].nextCash).toBe(1)
		end)

		it("references only existing chapters in unlock policies", function()
			local raw = rawConfig()
			expect(raw.chapters[raw.chapters.chapter2.normalUnlock.chapter]).toBeTruthy()
			expect(raw.chapters[raw.chapters.chapter1.hardUnlock.chapter]).toBeTruthy()
		end)
	end)

	describe("Validator", function()
		it("rejects class weights that do not total 100", function()
			local raw = rawConfig()
			raw.classes.weights[1].weight += 1
			local report = Validator.validate(raw)
			expect(report.ok).toBe(false)
			expect(report.errors[1]).toContain("class weights")
		end)

		it("rejects a non-null cost on the final level", function()
			local raw = rawConfig()
			raw.bags.levels[#raw.bags.levels].upgradeCash = 99
			expect(Validator.validate(raw).ok).toBe(false)
		end)

		it("rejects non-monotonic benefit curves", function()
			local raw = rawConfig()
			raw.handUpgrades.grasp[2].amount = 0
			expect(Validator.validate(raw).ok).toBe(false)
		end)

		it("rejects non-contiguous levels", function()
			local raw = rawConfig()
			raw.toolUpgrades.featherVac.cooling[3].level = 7
			expect(Validator.validate(raw).ok).toBe(false)
		end)

		it("rejects unknown unlock policy references", function()
			local raw = rawConfig()
			raw.chapters.chapter2.normalUnlock.chapter = "chapter9"
			expect(Validator.validate(raw).ok).toBe(false)
		end)

		it("rejects duplicate class ids", function()
			local raw = rawConfig()
			raw.classes.weights[2].id = raw.classes.weights[1].id
			expect(Validator.validate(raw).ok).toBe(false)
		end)

		it("rejects lowercase or untrimmed code keys", function()
			local raw = rawConfig()
			raw.codes["alien "] = raw.codes.ALIEN
			expect(Validator.validate(raw).ok).toBe(false)
		end)

		it("rejects a non-table root", function()
			expect(Validator.validate("nope").ok).toBe(false)
		end)
	end)

	describe("Config.fromRaw", function()
		it("returns a deep-frozen table", function()
			local cfg = Config.fromRaw(rawConfig())
			expect(DeepFreeze.isDeepFrozen(cfg)).toBe(true)
			expect(function()
				cfg.bags.levels[1].capacity = 9999
			end).toThrow()
		end)

		it("throws on invalid config", function()
			local raw = rawConfig()
			raw.configVersion = 0
			expect(function()
				Config.fromRaw(raw)
			end).toThrow("configVersion")
		end)

		it("exposes typed accessors", function()
			local cfg = Config.fromRaw(rawConfig())
			expect(Config.bagLevel(cfg, 1).capacity).toBe(cfg.collection.startingBagCapacity)
			expect(Config.class(cfg, "masterForager").weight).toBe(0.1)
			expect(Config.class(cfg, "missing")).toBeNil()
			expect(Config.toolPath(cfg, "nestRake", "sweep")[1].yield).toBe(cfg.tools.nestRake.baseYield)
			expect(Config.difficulty(cfg, "hard").rewardMultiplier).toBeGreaterThan(1)
			expect(Config.featureEnabled(cfg, "petsEnabled")).toBe(false)
		end)
	end)

	describe("client projection", function()
		it("strips server-only keys and keeps tunables", function()
			local raw = rawConfig()
			local projection = Projection.toClient(raw)
			expect(projection.codes).toBeNil()
			expect(projection.analytics).toBeNil()
			expect(projection["$schema"]).toBeNil()
			expect(Projection.leaksServerData(projection)).toBe(false)
			expect(projection.bags.levels[2].capacity).toBe(raw.bags.levels[2].capacity)
			expect(projection.classes.weights[1].weight).toBe(raw.classes.weights[1].weight)
			expect(projection.projection).toBe("client")
		end)

		it("does not mutate the source table", function()
			local raw = rawConfig()
			Projection.toClient(raw)
			expect(raw.codes.ALIEN).toBeTruthy()
		end)

		it("contains no product or pass ids", function()
			local encoded = game:GetService("HttpService"):JSONEncode(Projection.toClient(rawConfig()))
			expect(string.find(encoded, "productId", 1, true)).toBeNil()
			expect(string.find(encoded, "gamePassId", 1, true)).toBeNil()
			expect(string.find(encoded, "TODO_DEPLOYMENT_IDS", 1, true)).toBeNil()
		end)

		it("server and client views agree on every shared tunable", function()
			local raw = rawConfig()
			local projection = Projection.toClient(raw)
			for key, value in pairs(projection) do
				if key ~= "projection" then
					expect(TableUtil.deepEqual(value, raw[key])).toBe(true)
				end
			end
		end)
	end)
end
