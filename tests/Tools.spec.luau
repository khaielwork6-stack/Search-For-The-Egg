--!nocheck
-- Phase 3 progression + tools authority: purchase paths to max with injected funds, refusals that
-- never debit, Nest Rake sweeps, Confetti Charge fuse/radius/RNG, Feather Vac heat/overheat/cooling,
-- Scout Chick trips and cleanup, round reset vs permanent grants, overflow policy, integer cents,
-- difficulty modifiers, and a four-player stress pass. Runs against the real services.

return function(describe, it, expect)
	local ServerStorage = game:GetService("ServerStorage")
	local Shared = game:GetService("ReplicatedStorage").Shared
	local Config = require(Shared.Config)
	local ChapterLayout = require(Shared.Domain.ChapterLayout)
	local ToolSpecs = require(Shared.Domain.ToolSpecs)
	local PileGrid = require(Shared.Domain.PileGrid)
	local EconomyMath = require(Shared.EconomyMath)
	local ModifierResolver = require(Shared.ModifierResolver)
	local GameplayHarness = require(ServerStorage.Tests.Helpers.GameplayHarness)
	local cfg = Config.fromRaw(require(ServerStorage.SFE.SystemConfig))
	local layout = ChapterLayout.chapter1

	local function harness(options)
		return GameplayHarness.new(cfg, options)
	end

	local function fixedRng(value)
		return {
			next = function()
				return value
			end,
		}
	end

	-- Acquires a cash-priced tool with exactly the configured price injected (server-owned state).
	local function acquire(h, userId, toolId)
		local runtime = h.rounds:roundOf(userId)
		local state = runtime.players[userId]
		local price = ToolSpecs.acquisitionPrice(cfg, toolId)
		h.standAtBoard(userId)
		if price.cashCents then
			state.cashCents += price.cashCents
		else
			h.grantGems(userId, price.gems)
		end
		local result = h.buy(userId, "tool:" .. toolId, 0)
		assert(result.ok, "acquire " .. toolId .. ": " .. tostring(result.code) .. " " .. tostring(result.message))
		return result
	end

	local function gridSum(grid)
		local sum = 0
		for _, cell in ipairs(grid.cells) do
			sum += cell.remaining
		end
		return sum
	end

	-- Finishes the current round for `userId` (reveal -> claim -> commit -> results -> lobby).
	local function finishRound(h, roundId, userId)
		h.rounds:markEggRevealed(roundId)
		h.rounds:claim(roundId, userId, h.token(userId))
		h.rounds:commitAndFinish(roundId, function()
			return true
		end)
		h.rounds:returnToLobby(roundId)
		h.rounds:tick()
		h.tools:tick()
	end

	describe("ToolSpecs", function()
		it("exposes every configured path with level 0 defaults and JSON max levels", function()
			local levels = ToolSpecs.defaultLevels()
			for _, toolId in ipairs(ToolSpecs.TOOL_IDS) do
				for _, pathName in ipairs(ToolSpecs.PATHS[toolId]) do
					expect(levels[toolId][pathName]).toBe(0)
					expect(ToolSpecs.maxLevel(cfg, toolId, pathName)).toBe(#cfg.toolUpgrades[toolId][pathName] - 1)
				end
			end
			expect(ToolSpecs.maxLevels(cfg, "nestRake").hold).toBe(#cfg.toolUpgrades.nestRake.hold - 1)
			expect(ToolSpecs.acquisitionPrice(cfg, "nestRake").cashCents).toBe(EconomyMath.dollarsToCents(cfg.tools.nestRake.softCashPrice))
			expect(ToolSpecs.acquisitionPrice(cfg, "scoutChick").gems).toBe(cfg.tools.scoutChick.softGemPrice)
		end)

		it("resolves tool numbers from config + modifiers and applies a path discount exactly once", function()
			local identity = ModifierResolver.identity()
			local rake = ToolSpecs.nestRake(cfg, { sweep = 0, cooldown = 0, hold = 0 }, identity)
			expect(rake.amount).toBe(cfg.toolUpgrades.nestRake.sweep[1].yield)
			expect(rake.cooldownSeconds).toBe(cfg.toolUpgrades.nestRake.cooldown[1].seconds)
			expect(rake.holdEnabled).toBe(false)
			local held = ToolSpecs.nestRake(cfg, { sweep = 4, cooldown = 4, hold = 3 }, identity)
			expect(held.holdEnabled).toBe(true)
			expect(held.cooldownSeconds).toBe(cfg.toolUpgrades.nestRake.hold[4].intervalSeconds)
			local charge = ToolSpecs.confettiCharge(cfg, { luckyBlast = 1, speed = 2, power = 3 }, identity)
			expect(charge.rainbowChance).toBe(cfg.toolUpgrades.confettiCharge.luckyBlast[2].rainbowChance)
			expect(charge.fuseSeconds).toBe(cfg.toolUpgrades.confettiCharge.speed[3].fuseSeconds)
			expect(charge.radiusStuds).toBe(cfg.toolUpgrades.confettiCharge.power[4].radiusStuds)
			expect(charge.yield).toBe(cfg.toolUpgrades.confettiCharge.power[4].yield)
			expect(charge.throwDistanceStuds).toBe(cfg.tools.confettiCharge.throwDistanceStuds)
			expect(charge.miniChargeCount).toBe(0)
			local vac = ToolSpecs.featherVac(cfg, { power = 0, cooling = 0, runtime = 0 }, identity)
			expect(vac.perSecond).toBe(cfg.tools.featherVac.baseSuctionPerSecond)
			expect(vac.runtimeSeconds).toBe(cfg.tools.featherVac.baseRuntimeSeconds)
			expect(vac.coolingSeconds).toBe(cfg.tools.featherVac.baseCoolingSeconds)
			local chick = ToolSpecs.scoutChick(cfg, { speed = 0, grasp = 0, capacity = 0 }, identity)
			expect(chick.moveSpeed).toBe(cfg.tools.scoutChick.baseMoveSpeed)
			expect(chick.grasp).toBe(cfg.tools.scoutChick.baseGrasp)
			expect(chick.capacity).toBe(cfg.tools.scoutChick.baseCapacity)
			local preview = ToolSpecs.pathPreview(cfg, "nestRake", "sweep", 0, 0.75)
			expect(preview.costCents).toBe(
				EconomyMath.discountedCents(EconomyMath.dollarsToCents(cfg.toolUpgrades.nestRake.sweep[1].nextCash), 0.75)
			)
			expect(ToolSpecs.pathPreview(cfg, "nestRake", "sweep", 4).maxed).toBe(true)
		end)
	end)

	describe("Purchases", function()
		it("acquires every tool and buys every path to max with funds matching the JSON exactly", function()
			local h = harness()
			h.join(1)
			local _, runtime = h.startRound({ 1 })
			local state = runtime.players[1]
			local spent = 0
			for _, toolId in ipairs(ToolSpecs.TOOL_IDS) do
				local before = state.cashCents
				local result = acquire(h, 1, toolId)
				local price = ToolSpecs.acquisitionPrice(cfg, toolId)
				if price.cashCents then
					expect(result.data.paidCents).toBe(price.cashCents)
					expect(state.cashCents).toBe(before)
					spent += price.cashCents
				else
					expect(result.data.paidGems).toBe(price.gems)
					expect(h.profile(1).data.currencies.gems).toBe(0)
				end
				expect(state.roundTools[toolId]).toBe(true)
				for _, pathName in ipairs(ToolSpecs.PATHS[toolId]) do
					local path = cfg.toolUpgrades[toolId][pathName]
					local upgradeId = toolId .. "." .. pathName
					for level = 0, #path - 2 do
						local preview = h.previewOf(1, upgradeId)
						expect(preview.level).toBe(level)
						expect(preview.costCents).toBe(EconomyMath.dollarsToCents(path[level + 1].nextCash))
						state.cashCents = preview.costCents
						local purchase = h.buy(1, upgradeId, level)
						expect(purchase.ok).toBe(true)
						expect(purchase.data.paidCents).toBe(preview.costCents)
						expect(state.cashCents).toBe(0)
						expect(state.toolLevels[toolId][pathName]).toBe(level + 1)
						spent += preview.costCents
					end
					local maxed = h.previewOf(1, upgradeId)
					expect(maxed.maxed).toBe(true)
					expect(maxed.costCents).toBeNil()
					expect(state.toolLevels[toolId][pathName]).toBe(#path - 1)
				end
			end
			expect(spent % 1).toBe(0)
			expect(h.analyticsAdapter:countOf("tool_acquired")).toBe(#ToolSpecs.TOOL_IDS)
			expect(h.analyticsAdapter:countOf("upgrade_purchased")).toBeGreaterThan(0)
			-- Every tool path now maxed: previews report it and a further purchase is refused without debit.
			state.cashCents = 100000
			local refused = h.buy(1, "nestRake.sweep", ToolSpecs.maxLevel(cfg, "nestRake", "sweep"))
			expect(refused.ok).toBe(false)
			expect(refused.message).toBe("maxed")
			expect(state.cashCents).toBe(100000)
		end)

		it("stale level, max, insufficient funds, duplicate acquisition, invalid ids, and wrong phase never debit", function()
			local h = harness()
			h.join(1)
			local roundId, runtime = h.startRound({ 1 })
			local state = runtime.players[1]
			h.standAtBoard(1)
			state.cashCents = 5000
			local gemsBefore = h.profile(1).data.currencies.gems
			local function refused(upgradeId, level, code, message)
				local cashBefore = state.cashCents
				local result = h.buy(1, upgradeId, level)
				expect(result.ok).toBe(false)
				expect(result.code).toBe(code)
				if message then
					expect(result.message).toBe(message)
				end
				expect(state.cashCents).toBe(cashBefore)
				expect(h.profile(1).data.currencies.gems).toBe(gemsBefore)
			end
			refused("tool:nestRake", 1, "stale_token", "stale_level")
			refused("nestRake.sweep", 0, "not_found", "upgrade") -- not owned yet: no path preview
			refused("tool:bogus", 0, "not_found", "upgrade")
			refused("nestRake.bogus", 0, "not_found", "upgrade")
			refused("hand.grasp", 0, "not_found", "upgrade")
			refused("tool:scoutChick", 0, "insufficient_funds", "gems")
			state.cashCents = 10
			refused("tool:nestRake", 0, "insufficient_funds")
			state.cashCents = 5000
			expect(h.buy(1, "tool:nestRake", 0).ok).toBe(true)
			refused("tool:nestRake", 1, "invalid_state", "already_owned")
			refused("tool:nestRake", 0, "stale_token", "stale_level")
			refused("nestRake.sweep", 2, "stale_token", "stale_level")
			state.cashCents = 5
			refused("nestRake.sweep", 0, "insufficient_funds")
			state.cashCents = 5000
			-- Wrong phase: after the Egg is claimed nothing sells or upgrades.
			h.rounds:markEggRevealed(roundId)
			h.rounds:claim(roundId, 1, h.token(1))
			refused("nestRake.sweep", 0, "invalid_state", "phase")
			expect(h.upgrades.stats.purchases).toBe(0)
			expect(h.upgrades.stats.acquisitions).toBe(1)
		end)

		it("Rake Expert discounts Rake path costs once and boosts Rake yield once", function()
			local h = harness()
			h.join(1)
			h.setClasses(1, { "rakeExpert" })
			local _, runtime = h.startRound({ 1 })
			acquire(h, 1, "nestRake")
			local preview = h.previewOf(1, "nestRake.sweep")
			local discount = Config.class(cfg, "rakeExpert").effect.rakeUpgradeCostMultiplier
			expect(preview.costCents).toBe(
				EconomyMath.discountedCents(EconomyMath.dollarsToCents(cfg.toolUpgrades.nestRake.sweep[1].nextCash), discount)
			)
			expect(h.previewOf(1, "confettiCharge.power")).toBeNil()
			local state = runtime.players[1]
			state.cashCents = preview.costCents
			expect(h.buy(1, "nestRake.sweep", 0).ok).toBe(true)
			expect(state.cashCents).toBe(0)
			local spec = h.collection:spec(runtime, 1, "nestRake")
			expect(spec.amount).toBe(
				math.floor(cfg.toolUpgrades.nestRake.sweep[2].yield * Config.class(cfg, "rakeExpert").effect.rakeYieldMultiplier + 0.5)
			)
		end)
	end)

	describe("Nest Rake", function()
		it("sweeps a 3x3 neighbourhood once per action for the configured yield, then cools down", function()
			local h = harness()
			h.join(1)
			local _, runtime = h.startRound({ 1 })
			acquire(h, 1, "nestRake")
			local state = runtime.players[1]
			-- Not equipped: the Hand is still active.
			local unequipped = h.collectAt(1, runtime, 6, 6, "nestRake")
			expect(unequipped.message).toBe("not_equipped")
			expect(h.equip(1, "nestRake").ok).toBe(true)
			local wrongTool = h.collectAt(1, runtime, 6, 6, "hand")
			expect(wrongTool.message).toBe("not_equipped")
			local before = gridSum(runtime.grid)
			local sweep = h.collectAt(1, runtime, 6, 6, "nestRake")
			expect(sweep.ok).toBe(true)
			local spec = h.collection:spec(runtime, 1, "nestRake")
			expect(sweep.data.removed).toBe(spec.amount)
			expect(sweep.data.awarded).toBe(spec.amount)
			expect(before - gridSum(runtime.grid)).toBe(spec.amount)
			expect(#sweep.data.cells).toBeGreaterThan(1)
			expect(#sweep.data.cells).toBeLessThanOrEqual(9)
			local seen = {}
			for _, removal in ipairs(sweep.data.cells) do
				expect(seen[removal.index]).toBeNil()
				seen[removal.index] = true
				local cell = runtime.grid.cells[removal.index]
				expect(math.abs(cell.x - 6)).toBeLessThanOrEqual(1)
				expect(math.abs(cell.z - 6)).toBeLessThanOrEqual(1)
			end
			expect(sweep.data.cooldownMs).toBe(math.floor(cfg.toolUpgrades.nestRake.cooldown[1].seconds * 1000))
			-- Cooldown: an immediate second sweep is rate limited and removes nothing.
			local origin, direction = h.aimAt(1, runtime, 6, 6)
			local rushed =
				h.collection:collect(1, { sessionToken = h.token(1), origin = origin, direction = direction, toolId = "nestRake" })
			expect(rushed.code).toBe("rate_limited")
			expect(before - gridSum(runtime.grid)).toBe(spec.amount)
			expect(state.carriedStandard).toBe(spec.amount)
			expect(h.analyticsAdapter:countOf("tool_action")).toBe(1)
		end)

		it("overflow policy: the bag is clamped and the remainder becomes a short-lived world bundle", function()
			local h = harness()
			h.join(1)
			local _, runtime = h.startRound({ 1 })
			acquire(h, 1, "nestRake")
			h.equip(1, "nestRake")
			local state = runtime.players[1]
			local capacity = cfg.collection.startingBagCapacity
			local spec = h.collection:spec(runtime, 1, "nestRake")
			state.carriedStandard = capacity - 5
			local sweep = h.collectAt(1, runtime, 8, 8, "nestRake")
			expect(sweep.ok).toBe(true)
			expect(sweep.data.removed).toBe(spec.amount)
			expect(sweep.data.awarded).toBe(5)
			expect(sweep.data.overflow).toBe(spec.amount - 5)
			expect(sweep.data.carried).toBe(capacity)
			expect(sweep.data.bagFull).toBe(true)
			expect(state.carriedStandard).toBe(capacity)
			local bundleId = sweep.data.bundleId
			expect(bundleId).toBeTruthy()
			expect(runtime.bundles[bundleId].standard).toBe(spec.amount - 5)
			expect(#h.eventsOfKind("bundle_dropped")).toBe(1)
			-- Full bag: a further sweep is refused (no pile griefing) and the bundle cannot be gathered.
			expect(h.collectAt(1, runtime, 8, 8, "nestRake").message).toBe("bag_full")
			h.standAt(1, runtime.bundles[bundleId].position + Vector3.new(0, 2, 2))
			expect(h.collection:gatherBundle(1, { sessionToken = h.token(1), bundleId = bundleId }).message).toBe("bag_full")
			-- Sell, then gather: the exact remainder lands in the bag and the bundle disappears.
			h.standAt(1, layout.sellStation + Vector3.new(0, 3, 4))
			expect(h.selling:sell(1, h.token(1)).ok).toBe(true)
			h.standAt(1, runtime.bundles[bundleId].position + Vector3.new(0, 2, 2))
			local gathered = h.collection:gatherBundle(1, { sessionToken = h.token(1), bundleId = bundleId })
			expect(gathered.ok).toBe(true)
			expect(gathered.data.awarded).toBe(spec.amount - 5)
			expect(gathered.data.emptied).toBe(true)
			expect(runtime.bundles[bundleId]).toBeNil()
			expect(#h.eventsOfKind("bundle_removed")).toBe(1)
			expect(h.collection:gatherBundle(1, { sessionToken = h.token(1), bundleId = bundleId }).code).toBe("not_found")
			-- Expiry: a new bundle vanishes after collection.overflowBundleSeconds.
			state.carriedStandard = capacity - 1
			local second = h.collectAt(1, runtime, 9, 9, "nestRake")
			expect(runtime.bundles[second.data.bundleId]).toBeTruthy()
			h.advanceTools(cfg.collection.overflowBundleSeconds - 0.5, 0.5)
			expect(runtime.bundles[second.data.bundleId]).toBeTruthy()
			h.advanceTools(1, 0.5)
			expect(runtime.bundles[second.data.bundleId]).toBeNil()
			expect(h.tools.stats.bundlesExpired).toBe(1)
		end)
	end)

	describe("Confetti Charge", function()
		it("validates throws, honours the fuse and radius, rolls rainbow on the server, and never double-awards", function()
			local h = harness()
			h.join(1)
			local _, runtime = h.startRound({ 1 })
			acquire(h, 1, "confettiCharge")
			local state = runtime.players[1]
			local spec = h.collection:spec(runtime, 1, "confettiCharge")
			expect(h.beginAt(1, runtime, "confettiCharge", runtime.grid.width // 2, runtime.grid.depth // 2).message).toBe("not_equipped")
			expect(h.equip(1, "confettiCharge").ok).toBe(true)
			expect(h.beginAt(1, runtime, "nestRake", 8, 8).code).toBe("invalid_payload") -- discrete tools never use begin
			expect(h.beginAt(1, runtime, "featherVac", 8, 8).code).toBe("not_authorized") -- not owned
			-- Out of throw range: character far from the aim point.
			local _, direction = h.aimAt(1, runtime, 8, 8)
			h.standAt(1, h.positions[1] + Vector3.new(0, 0, -(spec.throwDistanceStuds + 10)))
			local far = h.tools:actionBegin(1, {
				sessionToken = h.token(1),
				toolId = "confettiCharge",
				origin = h.positions[1] + Vector3.new(0, 1.5, 0),
				direction = direction,
			})
			expect(far.code).toBe("out_of_range")
			local thrown = h.beginAt(1, runtime, "confettiCharge", runtime.grid.width // 2, runtime.grid.depth // 2)
			expect(thrown.ok).toBe(true)
			expect(thrown.data.fuseMs).toBe(math.floor(spec.fuseSeconds * 1000))
			expect(thrown.data.radius).toBe(spec.radiusStuds)
			local chargeId = thrown.data.chargeId
			expect(runtime.charges[chargeId]).toBeTruthy()
			-- Cooldown then one-live-charge rules.
			expect(h.beginAt(1, runtime, "confettiCharge", runtime.grid.width // 2, runtime.grid.depth // 2).message).toBe("cooldown")
			h.advanceTools(spec.cooldownSeconds + 0.05)
			expect(h.beginAt(1, runtime, "confettiCharge", runtime.grid.width // 2, runtime.grid.depth // 2).message).toBe("charge_live")
			-- Not before the fuse ends.
			local elapsed = spec.cooldownSeconds + 0.05
			h.advanceTools(spec.fuseSeconds - elapsed - 0.15)
			expect(runtime.charges[chargeId]).toBeTruthy()
			expect(h.tools.stats.explosions).toBe(0)
			local before = gridSum(runtime.grid)
			local snapshotBefore = {}
			for _, cell in ipairs(runtime.grid.cells) do
				snapshotBefore[cell.index] = cell.remaining
			end
			h.advanceTools(0.3)
			expect(runtime.charges[chargeId]).toBeNil()
			expect(h.tools.stats.explosions).toBe(1)
			local exploded = h.eventsOfKind("charge_exploded")
			expect(#exploded).toBe(1)
			-- Only what fits in the bag leaves the nest (a blast never destroys feathers it cannot carry).
			local capacity = cfg.collection.startingBagCapacity
			expect(exploded[1].removed).toBe(math.min(spec.yield, capacity))
			expect(before - gridSum(runtime.grid)).toBe(math.min(spec.yield, capacity))
			-- Radius: every touched cell centre lies within the blast radius of the landing point.
			local minCorner = ChapterLayout.gridMinCorner(layout, runtime.grid.width, runtime.grid.depth, runtime.grid.cellSize)
			for _, removal in ipairs(exploded[1].cells) do
				local cell = runtime.grid.cells[removal.index]
				local cx, cz = PileGrid.cellCenter(runtime.grid, cell)
				local distance = math.sqrt((minCorner.X + cx - exploded[1].x) ^ 2 + (minCorner.Z + cz - exploded[1].z) ^ 2)
				expect(distance).toBeLessThanOrEqual(spec.radiusStuds)
				expect(snapshotBefore[removal.index] - cell.remaining).toBe(removal.removed)
			end
			-- The bag is exactly full and nothing was bundled or wasted.
			expect(state.carriedStandard + state.carriedRainbow).toBe(capacity)
			expect(#h.eventsOfKind("bundle_dropped")).toBe(0)
			expect(exploded[1].rainbow).toBe(0) -- luckyBlast level 0: rainbowChance 0
			-- No duplicate award on later ticks.
			h.advanceTools(2)
			expect(h.tools.stats.explosions).toBe(1)
			expect(state.carriedStandard + state.carriedRainbow).toBe(capacity)
			expect(#h.eventsOfKind("charge_exploded")).toBe(1)
			-- Server RNG decides rainbow conversion: max Lucky Blast with a forced low roll converts everything.
			state.toolLevels.confettiCharge.luckyBlast = ToolSpecs.maxLevel(cfg, "confettiCharge", "luckyBlast")
			h.tools._rng = fixedRng(0.01)
			h.standAt(1, layout.sellStation + Vector3.new(0, 3, 4))
			h.selling:sell(1, h.token(1))
			local second = h.beginAt(1, runtime, "confettiCharge", 4, 12)
			expect(second.ok).toBe(true)
			h.advanceTools(spec.fuseSeconds + 0.2)
			local events = h.eventsOfKind("charge_exploded")
			expect(#events).toBe(2)
			expect(events[2].rainbow).toBe(events[2].removed)
			expect(state.carriedRainbow).toBe(math.min(events[2].removed, capacity))
			expect(h.tools.stats.miniCharges).toBe(0) -- no class: never any mini-charge even with a winning roll
		end)

		it("Blast Artist mini-charges come only from the resolved class modifier", function()
			local h = harness()
			h.join(1)
			h.setClasses(1, { "blastArtist" })
			local _, runtime = h.startRound({ 1 })
			acquire(h, 1, "confettiCharge")
			h.equip(1, "confettiCharge")
			local effects = Config.class(cfg, "blastArtist").effect
			local spec = h.collection:spec(runtime, 1, "confettiCharge")
			expect(spec.radiusStuds).toBe(cfg.toolUpgrades.confettiCharge.power[1].radiusStuds * effects.blastRadiusMultiplier)
			expect(spec.miniChargeChance).toBe(effects.miniChargeChance)
			expect(spec.miniChargeCount).toBe(effects.miniChargeCount)
			h.tools._rng = fixedRng(0.01)
			h.setEntitlement(1, "infiniteBag", true)
			expect(h.beginAt(1, runtime, "confettiCharge", runtime.grid.width // 2, runtime.grid.depth // 2).ok).toBe(true)
			h.advanceTools(spec.fuseSeconds + 0.2)
			expect(h.tools.stats.explosions).toBe(1)
			expect(h.tools.stats.miniCharges).toBe(effects.miniChargeCount)
			local minis = 0
			for _, event in ipairs(h.eventsOfKind("charge_thrown")) do
				if event.mini then
					minis += 1
					expect(event.fuseMs).toBe(math.floor(cfg.tools.confettiCharge.miniChargeFuseSeconds * 1000))
				end
			end
			expect(minis).toBe(effects.miniChargeCount)
			h.advanceTools(cfg.tools.confettiCharge.miniChargeFuseSeconds + 0.2)
			expect(h.tools.stats.explosions).toBe(1 + effects.miniChargeCount)
			-- Minis never chain into more minis.
			h.advanceTools(2)
			expect(h.tools.stats.miniCharges).toBe(effects.miniChargeCount)
			expect(runtime.players[1].carriedStandard + runtime.players[1].carriedRainbow).toBeGreaterThan(
				cfg.collection.startingBagCapacity
			)
		end)
	end)

	describe("Feather Vac", function()
		it("pulls continuously at the configured rate, overheats at runtime, and cools for coolingSeconds", function()
			local h = harness()
			h.join(1)
			h.setEntitlement(1, "infiniteBag", true)
			local _, runtime = h.startRound({ 1 })
			acquire(h, 1, "featherVac")
			local state = runtime.players[1]
			expect(h.beginAt(1, runtime, "featherVac", 8, 8).message).toBe("not_equipped")
			h.equip(1, "featherVac")
			local spec = h.collection:spec(runtime, 1, "featherVac")
			local started = h.beginAt(1, runtime, "featherVac", 8, 8)
			expect(started.ok).toBe(true)
			expect(started.data.runtimeSeconds).toBe(cfg.tools.featherVac.baseRuntimeSeconds)
			expect(started.data.coolingSeconds).toBe(cfg.tools.featherVac.baseCoolingSeconds)
			expect(h.beginAt(1, runtime, "featherVac", 8, 8).code).toBe("already_done")
			h.advanceTools(2)
			local pulled = state.carriedStandard
			expect(pulled).toBeGreaterThanOrEqual(math.floor(spec.perSecond * 2) - 1)
			expect(pulled).toBeLessThanOrEqual(math.ceil(spec.perSecond * 2))
			expect(state.toolRuntime.featherVac.running).toBe(true)
			expect(math.abs(state.toolRuntime.featherVac.heat - 2)).toBeLessThan(0.01)
			-- Release stops suction; heat persists and decays.
			local ended = h.endAction(1, "featherVac")
			expect(ended.data.wasRunning).toBe(true)
			h.advanceTools(1)
			expect(state.carriedStandard).toBe(pulled)
			expect(state.toolRuntime.featherVac.heat).toBeLessThan(2)
			-- Run to overheat.
			expect(h.beginAt(1, runtime, "featherVac", 8, 8).ok).toBe(true)
			h.advanceTools(spec.runtimeSeconds + 0.2)
			local rt = state.toolRuntime.featherVac
			expect(rt.overheated).toBe(true)
			expect(rt.running).toBe(false)
			expect(h.tools.stats.overheats).toBe(1)
			expect(h.analyticsAdapter:countOf("tool_overheated")).toBe(1)
			expect(h.beginAt(1, runtime, "featherVac", 8, 8).message).toBe("overheated")
			local afterOverheat = state.carriedStandard
			expect(afterOverheat).toBeGreaterThan(pulled)
			-- Cooling from the current heat takes heat * cooling / runtime seconds (full heat = coolingSeconds).
			local coolTime = rt.heat * spec.coolingSeconds / spec.runtimeSeconds
			expect(coolTime).toBeLessThanOrEqual(spec.coolingSeconds)
			h.advanceTools(coolTime - 0.5)
			expect(rt.overheated).toBe(true)
			expect(h.beginAt(1, runtime, "featherVac", 8, 8).message).toBe("overheated")
			h.advanceTools(1)
			expect(rt.overheated).toBe(false)
			expect(rt.heat).toBe(0)
			expect(state.carriedStandard).toBe(afterOverheat)
			expect(h.beginAt(1, runtime, "featherVac", 8, 8).ok).toBe(true)
			local readyEvents = 0
			for _, event in ipairs(h.eventsOfKind("vac_state")) do
				if event.state == "ready" then
					readyEvents += 1
				end
			end
			expect(readyEvents).toBe(1)
		end)

		it("follows the reticle while running, pulls real records under the aim, and stops when the aim leaves the nest", function()
			local h = harness()
			h.join(1)
			h.setEntitlement(1, "infiniteBag", true)
			local _, runtime = h.startRound({ 1 })
			acquire(h, 1, "featherVac")
			h.equip(1, "featherVac")
			local state = runtime.players[1]
			expect(h.beginAt(1, runtime, "featherVac", 8, 8).ok).toBe(true)
			local rt = state.toolRuntime.featherVac
			expect(math.abs(rt.aimX - 8)).toBeLessThanOrEqual(1)
			-- Re-aim at another patch: the runtime follows the new hit, not the start point.
			local origin, direction = h.aimAt(1, runtime, 12, 6)
			local aimed = h.tools:actionAim(1, { sessionToken = h.token(1), toolId = "featherVac", origin = origin, direction = direction })
			expect(aimed.ok).toBe(true)
			expect(aimed.data.running).toBe(true)
			expect(math.abs(rt.aimX - 12)).toBeLessThanOrEqual(1)
			expect(math.abs(rt.aimZ - 6)).toBeLessThanOrEqual(1)
			h.advanceTools(1)
			local pulls = h.eventsOfKind("vac_pull")
			expect(#pulls).toBeGreaterThan(0)
			local spec = h.collection:spec(runtime, 1, "featherVac")
			local total = 0
			for _, pull in ipairs(pulls) do
				expect(pull.userId).toBe(1)
				for _, removal in ipairs(pull.cells) do
					local cell = runtime.grid.cells[removal.index]
					expect(math.abs(cell.x - 12)).toBeLessThanOrEqual(spec.radiusCells + 1)
					expect(math.abs(cell.z - 6)).toBeLessThanOrEqual(spec.radiusCells + 1)
					total += #removal.slots
				end
			end
			expect(total).toBe(state.carriedStandard)
			-- An aim that misses the nest stops the suction at once.
			local far = h.tools:actionAim(
				1,
				{ sessionToken = h.token(1), toolId = "featherVac", origin = origin, direction = Vector3.new(0, 1, 0) }
			)
			expect(far.ok).toBe(true)
			expect(far.data.running).toBe(false)
			expect(rt.running).toBe(false)
			local states = h.eventsOfKind("vac_state")
			expect(states[#states].state).toBe("idle")
			expect(states[#states].reason).toBe("range")
			-- Aim updates while idle are harmless; a wrong tool is refused.
			expect(
				h.tools:actionAim(1, { sessionToken = h.token(1), toolId = "featherVac", origin = origin, direction = direction }).data.running
			).toBe(false)
			expect(h.tools:actionAim(1, { sessionToken = h.token(1), toolId = "nestRake", origin = origin, direction = direction }).code).toBe(
				"invalid_payload"
			)
		end)

		it("stops on death, on equip change, and when the bag fills; never exceeds capacity", function()
			local h = harness()
			h.join(1)
			local _, runtime = h.startRound({ 1 })
			acquire(h, 1, "featherVac")
			h.equip(1, "featherVac")
			local state = runtime.players[1]
			expect(h.beginAt(1, runtime, "featherVac", 8, 8).ok).toBe(true)
			h.advanceTools(1)
			h.tools:onDeath(1)
			expect(state.toolRuntime.featherVac.running).toBe(false)
			local carried = state.carriedStandard
			h.advanceTools(1)
			expect(state.carriedStandard).toBe(carried)
			expect(h.beginAt(1, runtime, "featherVac", 8, 8).ok).toBe(true)
			expect(h.equip(1, "hand").ok).toBe(true)
			expect(state.toolRuntime.featherVac.running).toBe(false)
			h.equip(1, "featherVac")
			expect(h.beginAt(1, runtime, "featherVac", 8, 8).ok).toBe(true)
			h.advanceTools(6)
			expect(state.carriedStandard).toBe(cfg.collection.startingBagCapacity)
			expect(state.toolRuntime.featherVac.running).toBe(false)
			expect(h.beginAt(1, runtime, "featherVac", 8, 8).message).toBe("bag_full")
			expect(state.toolRuntime.featherVac.overheated).toBe(false)
		end)
	end)

	describe("Scout Chick", function()
		it("runs server-owned trips (pile -> crate) and pays only its owner in exact cents", function()
			local h = harness()
			h.join(1)
			h.join(2)
			local _, runtime = h.startRound({ 1, 2 })
			expect(h.previewOf(1, "tool:scoutChick").costGems).toBe(cfg.tools.scoutChick.softGemPrice)
			acquire(h, 1, "scoutChick")
			expect(h.profile(1).data.currencies.gems).toBe(0)
			local owner, other = runtime.players[1], runtime.players[2]
			expect(h.beginAt(1, runtime, "scoutChick", 8, 8).message).toBe("not_equipped")
			h.equip(1, "scoutChick")
			local spec = h.collection:spec(runtime, 1, "scoutChick")
			local deployed = h.beginAt(1, runtime, "scoutChick", 8, 8)
			expect(deployed.ok).toBe(true)
			expect(deployed.data.capacity).toBe(cfg.tools.scoutChick.baseCapacity)
			expect(h.beginAt(1, runtime, "scoutChick", 8, 8).code).toBe("already_done")
			local rt = owner.toolRuntime.scoutChick
			expect(rt.active).toBe(true)
			expect(rt.units[1].state).toBe("ToPile")
			-- Walk the trip: to pile, collect capacity at the configured interval, to crate, deposit.
			local states = {}
			h.advanceTools(40, 0.1)
			for _, event in ipairs(h.eventsOfKind("chick_state")) do
				states[event.state] = (states[event.state] or 0) + 1
			end
			expect(states.Collecting).toBeGreaterThanOrEqual(1)
			expect(states.ToSeller).toBeGreaterThanOrEqual(1)
			expect(states.Depositing).toBeGreaterThanOrEqual(1)
			local trips = h.tools.stats.chickTrips
			expect(trips).toBeGreaterThanOrEqual(1)
			local perTrip = EconomyMath.computeSale({ standardCount = spec.capacity, rainbowCount = 0 }, {
				standardCents = EconomyMath.dollarsToCents(cfg.selling.cashPerStandardFeather),
				rainbowMultiplier = cfg.selling.rainbowFeatherMultiplier,
				classSellMultiplier = 1,
				perkSellMultiplier = 1,
			}).finalCents
			-- Every paid trip is a whole capacity load; a trip counted mid-walk may not have deposited yet.
			expect(owner.cashCents % perTrip).toBe(0)
			expect(owner.cashCents / perTrip).toBeLessThanOrEqual(trips)
			expect(owner.cashCents / perTrip).toBeGreaterThanOrEqual(trips - 1)
			expect(owner.cashCents).toBeGreaterThan(0)
			expect(owner.cashCents % 1).toBe(0)
			expect(other.cashCents).toBe(0)
			expect(owner.carriedStandard).toBe(0) -- the chick sells; it never fills the owner's bag
			expect(h.analyticsAdapter:countOf("chick_trip")).toBe(trips)
			expect(runtime.grid.removed).toBeGreaterThanOrEqual(trips * spec.capacity)
			-- Recall drops nothing when idle-at-pile with an empty load, and always clears units.
			local recalled = h.endAction(1, "scoutChick")
			expect(recalled.data.wasActive).toBe(true)
			expect(#rt.units).toBe(0)
			expect(rt.active).toBe(false)
			h.advanceTools(5)
			expect(h.tools.stats.chickTrips).toBe(trips)
		end)

		it("cleans up on death, disconnect, and round end; a loaded chick drops its load as a bundle", function()
			local h = harness()
			h.join(1)
			local roundId, runtime = h.startRound({ 1 })
			acquire(h, 1, "scoutChick")
			h.equip(1, "scoutChick")
			local state = runtime.players[1]
			expect(h.beginAt(1, runtime, "scoutChick", 8, 8).ok).toBe(true)
			-- Deploy directly on the nest so the first pecks land quickly.
			state.toolRuntime.scoutChick.units[1].position = layout.nestCenter + Vector3.new(0, 1, 0)
			h.advanceTools(4)
			local unit = state.toolRuntime.scoutChick.units[1]
			expect(unit).toBeTruthy()
			expect(unit.load).toBeGreaterThan(0)
			local load = unit.load
			h.tools:onDeath(1)
			expect(#state.toolRuntime.scoutChick.units).toBe(0)
			expect(state.toolRuntime.scoutChick.active).toBe(false)
			local bundles = h.eventsOfKind("bundle_dropped")
			expect(#bundles).toBe(1)
			expect(bundles[1].standard).toBe(load)
			-- Redeploy, then disconnect.
			expect(h.beginAt(1, runtime, "scoutChick", 8, 8).ok).toBe(true)
			h.tools:onLeave(1)
			expect(state.toolRuntime.scoutChick.active).toBe(false)
			-- Redeploy, then end the round: every live tool runtime and bundle is cleared.
			expect(h.beginAt(1, runtime, "scoutChick", 8, 8).ok).toBe(true)
			finishRound(h, roundId, 1)
			expect(next(state.toolRuntime)).toBeNil()
			expect(next(runtime.bundles)).toBeNil()
		end)

		it("Automation Expert grants the chick for the round and speeds it up through the resolver", function()
			local h = harness()
			h.join(1)
			h.setClasses(1, { "automationExpert" })
			local _, runtime = h.startRound({ 1 })
			local state = runtime.players[1]
			expect(state.roundTools.scoutChick).toBe(true)
			expect(state.permanentTools.scoutChick).toBeNil()
			expect(h.profile(1).data.currencies.gems).toBe(0)
			local effects = Config.class(cfg, "automationExpert").effect
			local spec = h.collection:spec(runtime, 1, "scoutChick")
			expect(spec.moveSpeed).toBe(cfg.tools.scoutChick.baseMoveSpeed * effects.droneSpeedMultiplier)
			expect(spec.capacity).toBe(math.floor(cfg.tools.scoutChick.baseCapacity * effects.droneCapacityMultiplier + 0.5))
			expect(spec.swarmChance).toBe(effects.swarmChancePerTrip)
			expect(spec.swarmCount).toBe(effects.swarmCount)
			expect(h.previewOf(1, "tool:scoutChick").maxed).toBe(true)
			expect(h.analyticsAdapter:countOf("tool_acquired")).toBe(1)
			-- Swarm proc with a forced roll: helpers spawn after a deposit and each finishes one trip.
			h.tools._rng = fixedRng(0.01)
			h.equip(1, "scoutChick")
			expect(h.beginAt(1, runtime, "scoutChick", 8, 8).ok).toBe(true)
			h.advanceTools(45, 0.1)
			expect(h.tools.stats.chickTrips).toBeGreaterThanOrEqual(2)
			expect(h.tools.stats.swarms).toBeGreaterThanOrEqual(1)
			expect(#state.toolRuntime.scoutChick.units).toBeLessThanOrEqual(1 + effects.swarmCount)
		end)
	end)

	describe("Grants and round reset", function()
		it("one-round grants vanish next round; mock permanent entitlements grant max upgrades every round", function()
			local h = harness()
			h.join(1)
			local roundId, runtime = h.startRound({ 1 })
			expect(h.tools:grantOneRound(1, "featherVac", "receipt")).toBe(true)
			expect(h.tools:grantOneRound(1, "featherVac", "receipt")).toBe(false)
			expect(h.tools:grantOneRound(1, "bogus", "receipt")).toBe(false)
			local state = runtime.players[1]
			expect(state.roundTools.featherVac).toBe(true)
			expect(state.toolLevels.featherVac.power).toBe(0)
			expect(h.previewOf(1, "featherVac.power").costCents).toBe(
				EconomyMath.dollarsToCents(cfg.toolUpgrades.featherVac.power[1].nextCash)
			)
			finishRound(h, roundId, 1)
			-- Next round: the one-round tool is gone; a permanent Rake (mock entitlement) arrives maxed.
			h.setEntitlement(1, "nestRakePermanent", true)
			local _, second = h.startRound({ 1 })
			local next = second.players[1]
			expect(next.roundTools.featherVac).toBeNil()
			expect(next.roundTools.nestRake).toBe(true)
			expect(next.permanentTools.nestRake).toBe(true)
			expect(next.equippedTool).toBe("hand")
			for _, pathName in ipairs(ToolSpecs.PATHS.nestRake) do
				expect(next.toolLevels.nestRake[pathName]).toBe(ToolSpecs.maxLevel(cfg, "nestRake", pathName))
				expect(h.previewOf(1, "nestRake." .. pathName).maxed).toBe(true)
				expect(h.previewOf(1, "nestRake." .. pathName).permanent).toBe(true)
			end
			local acquireRow = h.previewOf(1, "tool:nestRake")
			expect(acquireRow.maxed).toBe(true)
			expect(acquireRow.permanent).toBe(true)
			-- No cash was debited for the grant and the purchase path refuses cleanly.
			h.standAtBoard(1)
			next.cashCents = 1000
			expect(h.buy(1, "tool:nestRake", 0).message).toBe("stale_level")
			expect(h.buy(1, "nestRake.sweep", ToolSpecs.maxLevel(cfg, "nestRake", "sweep")).message).toBe("maxed")
			expect(next.cashCents).toBe(1000)
			local granted = h.eventsOfKind("tools_granted")
			expect(#granted).toBe(2)
			-- Infinite Bag entitlement flows through the same resolver into bag capacity.
			h.setEntitlement(1, "infiniteBag", true)
			expect(h.collection:bagCapacity(second, 1).infinite).toBe(true)
			h.setEntitlement(1, "infiniteBag", false)
			expect(h.collection:bagCapacity(second, 1).capacity).toBe(cfg.collection.startingBagCapacity)
		end)

		it("Hard difficulty modifiers flow from config through the resolver into the pile and tool yields", function()
			local normal = harness({ seed = 5 })
			normal.join(1)
			local _, normalRuntime = normal.startRound({ 1 })
			local hard = harness({ seed = 5 })
			hard.join(1)
			hard.profile(1):update(function(data)
				data.progression.totalWins = 1
				data.progression.chapterWins.chapter1.normal = 1
			end)
			local _, hardRuntime = hard.startRound({ 1 }, "hard")
			expect(hardRuntime.state.difficulty).toBe("hard")
			local ratio = hardRuntime.grid.total / normalRuntime.grid.total
			-- Most columns saturate at the 32-record mask (records every 0.15 studs since 14 Sep 2026),
			-- so Hard's extra depth shows only at the rim; it is still strictly deeper.
			expect(ratio).toBeGreaterThan(1.0)
			expect(ratio).toBeLessThan(cfg.difficulty.hard.pileHealthMultiplier + 0.15)
			expect(hardRuntime.eggDepthFraction).toBeGreaterThanOrEqual(cfg.difficulty.hard.eggDepthMinimum)
			acquire(hard, 1, "nestRake")
			local spec = hard.collection:spec(hardRuntime, 1, "nestRake")
			expect(spec.amount).toBe(math.floor(cfg.toolUpgrades.nestRake.sweep[1].yield * cfg.difficulty.hard.toolYieldMultiplier + 0.5))
			local charge =
				ToolSpecs.confettiCharge(cfg, ToolSpecs.defaultLevels().confettiCharge, hard.collection:modifiers(hardRuntime, 1))
			expect(charge.yield).toBe(
				math.floor(cfg.toolUpgrades.confettiCharge.power[1].yield * cfg.difficulty.hard.toolYieldMultiplier + 0.5)
			)
		end)
	end)

	describe("Stress", function()
		it("four players running every tool for a simulated minute stay bounded, consistent, and cheap", function()
			local h = harness({ seed = 9 })
			for userId = 1, 4 do
				h.join(userId)
			end
			local _, runtime = h.startRound({ 1, 2, 3, 4 })
			for userId = 1, 4 do
				h.setEntitlement(userId, "infiniteBag", true)
				for _, toolId in ipairs(ToolSpecs.TOOL_IDS) do
					acquire(h, userId, toolId)
				end
			end
			h.equip(1, "confettiCharge")
			h.equip(2, "featherVac")
			h.equip(3, "scoutChick")
			h.equip(4, "nestRake")
			expect(h.beginAt(3, runtime, "scoutChick", runtime.grid.width // 2, runtime.grid.depth // 2).ok).toBe(true)
			local started = os.clock()
			local ticks = 0
			for second = 1, 60 do
				if second % 3 == 1 then
					h.beginAt(1, runtime, "confettiCharge", 2 * (4 + second % 8), 2 * (4 + (second * 3) % 8))
				end
				if runtime.players[2].toolRuntime.featherVac == nil or not runtime.players[2].toolRuntime.featherVac.running then
					h.beginAt(2, runtime, "featherVac", 20, 2 * (6 + second % 5))
				end
				local sweep = h.collectAt(4, runtime, 2 * (2 + (second * 5) % 12), 2 * (2 + (second * 7) % 12), "nestRake")
				if not sweep.ok and runtime.state.phase == "Searching" then
					-- The only legitimate refusal under load is an already-cleared neighbourhood (once
					-- the area tools dig out the Egg the round leaves Searching and refuses by phase).
					expect(sweep.message).toBe("no_feathers")
				end
				for _ = 1, 10 do
					h.clock:advance(0.1)
					h.tools:tick()
					ticks += 1
				end
				-- Bounded live state every simulated second.
				local charges = 0
				for _ in pairs(runtime.charges) do
					charges += 1
				end
				expect(charges).toBeLessThanOrEqual(4 * (1 + Config.class(cfg, "blastArtist").effect.miniChargeCount))
				-- Area tools can dig out the Egg's column mid-run; the round then leaves Searching and
				-- the chick is recalled, so only check the bound while it is still fielded.
				local chick = runtime.players[3].toolRuntime.scoutChick
				if chick then
					expect(#chick.units).toBeLessThanOrEqual(1 + Config.class(cfg, "automationExpert").effect.swarmCount)
				end
			end
			local wall = os.clock() - started
			expect(ticks).toBe(600)
			expect(wall).toBeLessThan(3)
			-- Pile bookkeeping stays exact and cash stays integer.
			expect(runtime.grid.total - gridSum(runtime.grid)).toBe(runtime.grid.removed)
			for userId = 1, 4 do
				local state = runtime.players[userId]
				expect(state.cashCents % 1).toBe(0)
				expect(state.carriedStandard % 1).toBe(0)
				expect(state.carriedRainbow % 1).toBe(0)
			end
			-- Charges only fire while Searching; the area tools can end the search early on the finer grid.
			expect(h.tools.stats.explosions).toBeGreaterThanOrEqual(if runtime.state.phase == "Searching" then 15 else 5)
			expect(h.tools.stats.vacFeathers).toBeGreaterThan(0)
			expect(h.tools.stats.chickTrips).toBeGreaterThanOrEqual(1)
			expect(h.collection.stats.accepted).toBeGreaterThanOrEqual(20)
			-- Refusals under load are legitimate (overheated vac restarts, live-charge rule); never handler errors.
			expect(h.tools.stats.overheats).toBeGreaterThanOrEqual(1)
		end)
	end)
end
