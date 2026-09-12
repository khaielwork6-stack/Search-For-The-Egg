--!nocheck
-- Modifier composition: named sources, no double application, config-driven class effects.

return function(describe, it, expect)
	local Shared = game:GetService("ReplicatedStorage").Shared
	local ModifierResolver = require(Shared.ModifierResolver)
	local Config = require(Shared.Config)
	local cfg = Config.fromRaw(require(game:GetService("ServerStorage").SFE.SystemConfig))

	describe("resolve", function()
		it("identity has neutral multipliers", function()
			local id = ModifierResolver.identity()
			for _, key in ipairs(ModifierResolver.MULTIPLIER_KEYS) do
				expect(id[key]).toBe(1)
			end
			expect(id.infiniteBag).toBe(false)
		end)

		it("composes distinct sources multiplicatively", function()
			local resolved = ModifierResolver.resolve({
				{ id = "a", kind = "class", sellMultiplier = 1.2 },
				{ id = "b", kind = "perk", sellMultiplier = 1.5 },
			})
			expect(resolved.sellMultiplier).toBeCloseTo(1.8, 1e-9)
			expect(resolved.appliedSources).toEqual({ "a", "b" })
		end)

		it("never double-applies the same source id", function()
			local source = ModifierResolver.sourceFromClass(Config.class(cfg, "nestCarrier"))
			local resolved = ModifierResolver.resolve({ source, source, source })
			expect(resolved.bagCapacityMultiplier).toBe(Config.class(cfg, "nestCarrier").effect.bagCapacityMultiplier)
			expect(#resolved.appliedSources).toBe(1)
		end)

		it("class equipped in two slots applies once", function()
			local trader = ModifierResolver.sourceFromClass(Config.class(cfg, "eggTrader"))
			local again = ModifierResolver.sourceFromClass(Config.class(cfg, "eggTrader"))
			local resolved = ModifierResolver.resolve({ trader, again })
			expect(resolved.sellMultiplier).toBe(Config.class(cfg, "eggTrader").effect.sellMultiplier)
		end)

		it("maps every configured class effect to a resolver field", function()
			for _, classEntry in ipairs(cfg.classes.weights) do
				local source = ModifierResolver.sourceFromClass(classEntry)
				local resolved = ModifierResolver.resolve({ source })
				for key, value in pairs(classEntry.effect) do
					if table.find(ModifierResolver.MULTIPLIER_KEYS, key) then
						expect(resolved[key]).toBe(value)
					elseif
						type(value) == "number"
						and (string.find(key, "Count$") or string.find(key, "Seconds$") or string.find(key, "Multiplier$"))
					then
						expect(resolved.params[key]).toBe(value)
					elseif type(value) == "number" then
						expect(resolved.procs[key]).toBe(value)
					elseif value == true then
						local mapped = if key == "grantsScoutChick"
							then "scoutChickRoundGrant"
							elseif key == "grantsAllPassiveBonuses" then "allPassiveBonuses"
							else key
						expect(resolved.entitlements[mapped]).toBe(true)
					end
				end
			end
		end)

		it("difficulty source carries the configured hard multipliers", function()
			local hard = ModifierResolver.sourceFromDifficulty("hard", Config.difficulty(cfg, "hard"))
			local resolved = ModifierResolver.resolve({ hard })
			expect(resolved.pileHealthMultiplier).toBe(cfg.difficulty.hard.pileHealthMultiplier)
			expect(resolved.toolYieldMultiplier).toBe(cfg.difficulty.hard.toolYieldMultiplier)
			expect(resolved.sellMultiplier).toBe(cfg.difficulty.hard.sellMultiplier)
			expect(resolved.rewardMultiplier).toBe(cfg.difficulty.hard.rewardMultiplier)
		end)

		it("perk sources are linear per configured valuePerLevel", function()
			local perk = cfg.permanentPerks.featherValue
			local source = ModifierResolver.sourceFromPerk("featherValue", 3, perk.valuePerLevel)
			expect(ModifierResolver.resolve({ source }).sellMultiplier).toBeCloseTo(1 + 3 * perk.valuePerLevel, 1e-9)
			expect(function()
				ModifierResolver.sourceFromPerk("unknownPerk", 1, 0.1)
			end).toThrow()
		end)

		it("entitlement source sets infiniteBag explicitly", function()
			local source = ModifierResolver.sourceFromEntitlements({ infiniteBag = true, doubleGems = false })
			local resolved = ModifierResolver.resolve({ source })
			expect(resolved.infiniteBag).toBe(true)
			expect(resolved.entitlements.infiniteBag).toBe(true)
			expect(resolved.entitlements.doubleGems).toBeNil()
		end)

		it("procs are additive and clamped to [0,1]", function()
			local resolved = ModifierResolver.resolve({
				{ id = "x", kind = "class", procs = { gemFindChance = 0.7 } },
				{ id = "y", kind = "tool", procs = { gemFindChance = 0.6 } },
			})
			expect(resolved.procs.gemFindChance).toBe(1)
		end)

		it("rejects invalid multipliers", function()
			expect(function()
				ModifierResolver.resolve({ { id = "bad", kind = "debug", sellMultiplier = -1 } })
			end).toThrow()
			expect(function()
				ModifierResolver.resolve({ { id = "bad", kind = "debug", sellMultiplier = 0 / 0 } })
			end).toThrow()
		end)

		it("does not mutate input sources", function()
			local source = { id = "s", kind = "class", procs = { p = 0.1 }, entitlements = {} }
			ModifierResolver.resolve({ source })
			expect(source.procs.p).toBe(0.1)
			expect(source.sellMultiplier).toBeNil()
		end)
	end)
end
