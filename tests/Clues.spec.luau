--!nocheck
-- Professor Plume's loan through the real services: validation, the atomic deduction in normal
-- feathers, the party-wide limit, the timed grant and its revoke, the rod's readings (heat only,
-- never a position), and the reset between rounds.

return function(describe, it, expect)
	local ServerStorage = game:GetService("ServerStorage")
	local Shared = game:GetService("ReplicatedStorage").Shared
	local Config = require(Shared.Config)
	local EggSense = require(Shared.Domain.EggSense)
	local ChapterLayout = require(Shared.Domain.ChapterLayout)
	local GameplayHarness = require(ServerStorage.Tests.Helpers.GameplayHarness)
	local cfg = Config.fromRaw(require(ServerStorage.SFE.SystemConfig))
	local layout = ChapterLayout.chapter1
	local costs = cfg.plume.costsStandard
	local activeSeconds = cfg.plume.rod.activeSeconds
	local radius = cfg.plume.rod.radiusStuds

	local function setup(members, options)
		local h = GameplayHarness.new(cfg, options)
		for _, userId in ipairs(members) do
			h.join(userId)
		end
		local roundId, runtime = h.startRound(members)
		for _, userId in ipairs(members) do
			h.standAt(userId, layout.clueStation + Vector3.new(0, 0, 3))
		end
		return h, roundId, runtime
	end

	local function eventsOfKind(h, kind)
		local out = {}
		for _, entry in ipairs(h.toolEvents) do
			if entry.payload.kind == kind then
				table.insert(out, entry.payload)
			end
		end
		return out
	end

	describe("validation", function()
		it("refuses without enough normal feathers and consumes nothing", function()
			local h, _, runtime = setup({ 1 })
			local state = runtime.players[1]
			state.carriedStandard, state.carriedRainbow = costs[1] - 1, 9
			local result = h.lend(1)
			expect(result.ok).toBe(false)
			expect(result.code).toBe("insufficient_funds")
			expect(state.carriedStandard).toBe(costs[1] - 1)
			expect(state.carriedRainbow).toBe(9)
			expect(state.roundTools.eggSense).toBe(nil)
			expect(h.clues:project(runtime).count).toBe(0)
		end)

		it("never takes Rainbow Feathers, however many are carried", function()
			local h, _, runtime = setup({ 1 })
			local state = runtime.players[1]
			state.carriedStandard, state.carriedRainbow = 0, 500
			expect(h.lend(1).code).toBe("insufficient_funds")
			expect(state.carriedRainbow).toBe(500)
		end)

		it("refuses a stale token and a stranger to the round", function()
			local h, _, runtime = setup({ 1 })
			runtime.players[1].carriedStandard = 1000
			expect(h.clues:lend(1, { sessionToken = "not-the-token" }).code).toBe("stale_token")
			h.join(2)
			h.standAt(2, layout.clueStation)
			expect(h.clues:lend(2, { sessionToken = h.token(2) }).code).toBe("invalid_state")
			expect(runtime.players[1].carriedStandard).toBe(1000)
		end)

		it("refuses from across the yard", function()
			local h, _, runtime = setup({ 1 })
			runtime.players[1].carriedStandard = 1000
			h.standAt(1, layout.clueStation + Vector3.new(cfg.plume.stationRangeStuds + 1, 0, 0))
			local result = h.lend(1)
			expect(result.code).toBe("out_of_range")
			expect(runtime.players[1].carriedStandard).toBe(1000)
		end)

		it("refuses once the Egg is out", function()
			local h, _, runtime = setup({ 1 })
			runtime.players[1].carriedStandard = 1000
			expect(h.egg:revealNow(runtime)).toBe(true)
			local result = h.lend(1)
			expect(result.ok).toBe(false)
			expect(result.message).toBe("egg_found")
			expect(runtime.players[1].carriedStandard).toBe(1000)
		end)

		it("refuses outside the searching phase", function()
			local h = GameplayHarness.new(cfg)
			h.join(1)
			-- Start the party but stop before the round accepts gameplay.
			local party = h.parties:create(1, "chapter1", "normal")
			h.parties:start(1, party.partyId)
			h.clock:advance(cfg.round.countdownSeconds)
			h.parties:tick()
			local runtime = h.rounds:roundOf(1)
			expect(runtime ~= nil).toBe(true)
			runtime.players[1].carriedStandard = 1000
			h.standAt(1, layout.clueStation)
			local result = h.lend(1)
			expect(result.ok).toBe(false)
			expect(result.message).toBe("phase")
			expect(runtime.players[1].carriedStandard).toBe(1000)
		end)
	end)

	describe("the loan", function()
		it("takes 100, 200 then 400 normal feathers from the borrower and grants the rod each time", function()
			local h, _, runtime = setup({ 1 })
			local state = runtime.players[1]
			state.carriedStandard, state.carriedRainbow = costs[1] + costs[2] + costs[3] + 7, 3
			for index = 1, 3 do
				local before = state.carriedStandard
				local result = h.lend(1)
				expect(result.ok).toBe(true)
				expect(result.data.cost).toBe(costs[index])
				expect(result.data.usesLeft).toBe(3 - index)
				expect(result.data.nextCost).toBe(costs[index + 1])
				expect(result.data.activeSeconds).toBe(activeSeconds)
				expect(state.carriedStandard).toBe(before - costs[index])
				expect(state.carriedRainbow).toBe(3)
				expect(state.roundTools.eggSense).toBe(true)
				expect(state.equippedTool).toBe("eggSense")
				expect(math.abs(h.tools:timedRemaining(1, "eggSense") - activeSeconds)).toBeLessThan(1e-6)
				-- Let it run out before the next loan.
				h.clock:advance(activeSeconds + 0.01)
				h.tools:tick()
				expect(state.roundTools.eggSense).toBe(nil)
			end
			expect(state.carriedStandard).toBe(7)
			expect(h.clues.stats.loans).toBe(3)
			local granted = eventsOfKind(h, "tools_granted")
			local rodGrants = 0
			for _, payload in ipairs(granted) do
				if table.find(payload.tools, "eggSense") then
					rodGrants += 1
					expect(payload.userId).toBe(1)
					expect(payload.expiresInMs).toBe(activeSeconds * 1000)
					expect(payload.equipped).toBe(true)
				end
			end
			expect(rodGrants).toBe(3)
		end)

		it("holds the limit of three per party even with feathers to spare, across members", function()
			local h, _, runtime = setup({ 1, 2 })
			runtime.players[1].carriedStandard = 10000
			runtime.players[2].carriedStandard = 10000
			expect(h.lend(1).ok).toBe(true)
			h.clock:advance(activeSeconds + 0.01)
			h.tools:tick()
			expect(h.lend(2).ok).toBe(true)
			h.clock:advance(activeSeconds + 0.01)
			h.tools:tick()
			expect(h.lend(1).ok).toBe(true)
			h.clock:advance(activeSeconds + 0.01)
			h.tools:tick()
			local fourth = h.lend(2)
			expect(fourth.ok).toBe(false)
			expect(fourth.message).toBe("limit")
			local projection = h.clues:project(runtime)
			expect(projection.count).toBe(EggSense.maxUses(cfg))
			expect(projection.usesLeft).toBe(0)
			expect(projection.nextCost).toBe(nil)
			expect(runtime.players[1].carriedStandard).toBe(10000 - costs[1] - costs[3])
			expect(runtime.players[2].carriedStandard).toBe(10000 - costs[2])
		end)

		it("refuses a second loan while the first is live, and a spam charges once", function()
			local h, _, runtime = setup({ 1 })
			local state = runtime.players[1]
			state.carriedStandard = 10000
			expect(h.lend(1).ok).toBe(true)
			for _ = 1, 5 do
				local again = h.lend(1)
				expect(again.ok).toBe(false)
				expect(again.message).toBe("active")
			end
			expect(state.carriedStandard).toBe(10000 - costs[1])
			expect(h.clues:project(runtime).count).toBe(1)
		end)

		it("the party hears every loan with the counters, never the Egg", function()
			local h, roundId, runtime = setup({ 1, 2 })
			runtime.players[2].carriedStandard = 1000
			local heard = {}
			h.clues.lent:Connect(function(_runtime, userId, projection)
				table.insert(heard, { userId = userId, projection = projection })
			end)
			expect(h.lend(2).ok).toBe(true)
			expect(#heard).toBe(1)
			expect(heard[1].userId).toBe(2)
			expect(heard[1].projection.usesLeft).toBe(2)
			expect(heard[1].projection.nextCost).toBe(costs[2])
			expect(#heard[1].projection.active).toBe(1)
			expect(heard[1].projection.active[1].userId).toBe(2)
			local snapshot = h.rounds:project(roundId, false)
			expect(snapshot.plume.count).toBe(1)
			expect(snapshot.plume.usesLeft).toBe(2)
			expect(snapshot.plume.active[1].userId).toBe(2)
			expect(snapshot.plume.active[1].remainingMs).toBe(activeSeconds * 1000)
			local encoded = game:GetService("HttpService"):JSONEncode(snapshot.plume)
			expect(string.find(encoded, "egg")).toBe(nil)
			expect(string.find(encoded, "heat")).toBe(nil)
			expect(string.find(encoded, "worldX")).toBe(nil)
			-- Member 1 paid nothing and holds no rod.
			expect(runtime.players[1].carriedStandard).toBe(0)
			expect(runtime.players[1].roundTools.eggSense).toBe(nil)
			expect(snapshot.clues).toBe(nil)
		end)

		it("selling afterwards sells only what is left", function()
			local h, _, runtime = setup({ 1 })
			local state = runtime.players[1]
			state.carriedStandard, state.carriedRainbow = costs[1] + 5, 2
			expect(h.lend(1).ok).toBe(true)
			h.standAt(1, layout.sellStation + Vector3.new(0, 0, 4))
			local sale = h.selling:sell(1, h.token(1))
			expect(sale.ok).toBe(true)
			expect(sale.data.standardCount).toBe(5)
			expect(sale.data.rainbowCount).toBe(2)
			expect(state.carriedStandard).toBe(0)
		end)
	end)

	describe("the rod", function()
		it("expires after the active time: ownership, runtime and the hand come back, the owner hears why", function()
			local h, _, runtime = setup({ 1 })
			local state = runtime.players[1]
			state.carriedStandard = 1000
			expect(h.lend(1).ok).toBe(true)
			h.clock:advance(activeSeconds - 0.5)
			h.tools:tick()
			expect(state.roundTools.eggSense).toBe(true)
			expect(h.tools:timedRemaining(1, "eggSense")).toBeGreaterThan(0)
			expect(#eventsOfKind(h, "tools_revoked")).toBe(0)
			h.clock:advance(0.6)
			h.tools:tick()
			expect(state.roundTools.eggSense).toBe(nil)
			expect(state.toolRuntime.eggSense).toBe(nil)
			expect(state.equippedTool).toBe("hand")
			expect(h.tools:timedRemaining(1, "eggSense")).toBe(nil)
			local revoked = eventsOfKind(h, "tools_revoked")
			expect(#revoked).toBe(1)
			expect(revoked[1].userId).toBe(1)
			expect(revoked[1].reason).toBe("expired")
			expect(revoked[1].wasEquipped).toBe(true)
			expect(table.find(revoked[1].tools, "eggSense")).toBe(1)
			expect(h.tools.stats.revoked).toBe(1)
			-- A second tick does not revoke twice.
			h.tools:tick()
			expect(#eventsOfKind(h, "tools_revoked")).toBe(1)
		end)

		it("is taken back on death and on leaving", function()
			local h, _, runtime = setup({ 1, 2 })
			runtime.players[1].carriedStandard = 1000
			runtime.players[2].carriedStandard = 1000
			expect(h.lend(1).ok).toBe(true)
			expect(h.lend(2).ok).toBe(true)
			h.tools:onDeath(1)
			expect(runtime.players[1].roundTools.eggSense).toBe(nil)
			expect(runtime.players[1].equippedTool).toBe("hand")
			h.tools:onLeave(2)
			expect(runtime.players[2].roundTools.eggSense).toBe(nil)
			local revoked = eventsOfKind(h, "tools_revoked")
			expect(#revoked).toBe(2)
			expect(revoked[1].reason).toBe("death")
			expect(revoked[2].reason).toBe("left")
		end)

		it("can be swapped for the hand and back while the loan lasts, but never equipped unowned", function()
			local h, _, runtime = setup({ 1 })
			local state = runtime.players[1]
			expect(h.tools:equip(1, "eggSense").code).toBe("not_authorized")
			state.carriedStandard = 1000
			expect(h.lend(1).ok).toBe(true)
			expect(h.tools:equip(1, "hand").ok).toBe(true)
			expect(h.tools:equip(1, "eggSense").ok).toBe(true)
			expect(state.equippedTool).toBe("eggSense")
			h.clock:advance(activeSeconds + 0.01)
			h.tools:tick()
			expect(h.tools:equip(1, "eggSense").code).toBe("not_authorized")
		end)
	end)

	describe("readings", function()
		it("are refused before a loan, after it expires, with the hand equipped, and once the Egg is out", function()
			local h, _, runtime = setup({ 1 })
			local state = runtime.players[1]
			local egg = h.egg:position(runtime)
			local before = h.rodAim(1, egg.X, egg.Y, egg.Z)
			expect(before.ok).toBe(false)
			expect(before.message).toBe("inactive")
			state.carriedStandard = 1000
			expect(h.lend(1).ok).toBe(true)
			expect(h.rodAim(1, egg.X, egg.Y, egg.Z).ok).toBe(true)
			expect(h.tools:equip(1, "hand").ok).toBe(true)
			expect(h.rodAim(1, egg.X, egg.Y, egg.Z).message).toBe("not_equipped")
			expect(h.tools:equip(1, "eggSense").ok).toBe(true)
			expect(h.rodAim(1, egg.X, egg.Y, egg.Z).ok).toBe(true)
			expect(h.clues:aim(1, { sessionToken = "not-the-token", x = egg.X, y = egg.Y, z = egg.Z }).code).toBe("stale_token")
			h.clock:advance(activeSeconds + 0.01)
			h.tools:tick()
			local after = h.rodAim(1, egg.X, egg.Y, egg.Z)
			expect(after.ok).toBe(false)
			expect(after.message).toBe("inactive")
			expect(h.lend(1).ok).toBe(true)
			expect(h.egg:revealNow(runtime)).toBe(true)
			expect(h.rodAim(1, egg.X, egg.Y, egg.Z).message).toBe("egg_found")
		end)

		it("answer the quantised heat and the seconds left, and never the Egg's place", function()
			local h, _, runtime = setup({ 1 })
			runtime.players[1].carriedStandard = 1000
			expect(h.lend(1).ok).toBe(true)
			local egg = h.egg:position(runtime)
			local onEgg = h.rodAim(1, egg.X, egg.Y, egg.Z)
			expect(onEgg.ok).toBe(true)
			expect(onEgg.data.heat).toBe(1)
			expect(onEgg.data.remainingMs).toBe(activeSeconds * 1000)
			for key in pairs(onEgg.data) do
				expect(key == "heat" or key == "remainingMs").toBe(true)
			end
			local half = h.rodAim(1, egg.X + radius / 2, egg.Y, egg.Z)
			expect(half.data.heat).toBe(0.5)
			local cold = h.rodAim(1, egg.X + radius, egg.Y, egg.Z)
			expect(cold.data.heat).toBe(0)
			-- Two points a hair apart read the same: the reading cannot be differentiated.
			local a = h.rodAim(1, egg.X + 3.3, egg.Y, egg.Z).data.heat
			local b = h.rodAim(1, egg.X + 3.34, egg.Y, egg.Z).data.heat
			expect(a).toBe(b)
			expect(a).toBe(EggSense.heatFor(cfg, { x = egg.X + 3.3, y = egg.Y, z = egg.Z }, { x = egg.X, y = egg.Y, z = egg.Z }))
			expect(h.clues.stats.readings).toBe(5)
		end)

		it("refuse a point off the mound or a non-number, and the payload is validated by the schema too", function()
			local h, _, runtime = setup({ 1 })
			runtime.players[1].carriedStandard = 1000
			expect(h.lend(1).ok).toBe(true)
			local centre = layout.nestCenter
			local far = h.rodAim(1, centre.X + 500, centre.Y, centre.Z)
			expect(far.ok).toBe(false)
			expect(far.code).toBe("out_of_range")
			expect(h.rodAim(1, 0 / 0, centre.Y, centre.Z).code).toBe("invalid_payload")
			expect(h.rodAim(1, "3", centre.Y, centre.Z).code).toBe("invalid_payload")
			local NetSchema = require(Shared.Net.NetSchema)
			local Schema = require(Shared.Net.Schema)
			local registry = NetSchema.build(cfg)
			local rodAim = registry.byName.RodAim
			expect(rodAim ~= nil).toBe(true)
			expect(rodAim.rate.perSecond).toBeGreaterThanOrEqual(cfg.plume.rod.aimRateHz)
			expect(Schema.validate(rodAim.payload, { sessionToken = h.token(1), x = 1, y = 2, z = 3 }).ok).toBe(true)
			expect(Schema.validate(rodAim.payload, { sessionToken = h.token(1), x = math.huge, y = 2, z = 3 }).ok).toBe(false)
			expect(Schema.validate(rodAim.payload, { sessionToken = h.token(1), x = 1, y = 2 }).ok).toBe(false)
			expect(registry.byName.PlumeLend ~= nil).toBe(true)
			expect(registry.byName.PlumeLent ~= nil).toBe(true)
			expect(registry.byName.ClueAnalyze).toBe(nil)
			expect(registry.byName.ClueUnlocked).toBe(nil)
		end)
	end)

	describe("rounds", function()
		it("resets the loan book and takes the rod back with the next round", function()
			local h, _, runtime = setup({ 1 })
			runtime.players[1].carriedStandard = 1000
			expect(h.lend(1).ok).toBe(true)
			expect(h.clues:project(runtime).count).toBe(1)
			-- Finish the round and start another with the same player.
			expect(h.egg:revealNow(runtime)).toBe(true)
			h.standAt(1, h.egg:position(runtime))
			expect(h.egg:claim(1, h.token(1)).ok).toBe(true)
			h.standAt(1, layout.farmer)
			expect(h.egg:deliver(1, h.token(1)).ok).toBe(true)
			expect(runtime.players[1].roundTools.eggSense).toBe(nil)
			h.clock:advance(cfg.round.resultScreenAutoContinueSeconds + 5)
			h.rounds:tick()
			local roundId2, runtime2 = h.startRound({ 1 })
			expect(runtime2 ~= runtime).toBe(true)
			expect(runtime2.plume).toBe(nil)
			expect(runtime2.players[1].roundTools.eggSense).toBe(nil)
			local snapshot = h.rounds:project(roundId2, false)
			expect(snapshot.plume.count).toBe(0)
			expect(snapshot.plume.usesLeft).toBe(3)
			expect(snapshot.plume.nextCost).toBe(costs[1])
			expect(#snapshot.plume.active).toBe(0)
		end)
	end)
end
