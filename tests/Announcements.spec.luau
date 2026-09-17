--!nocheck
-- Big announcements: AnnouncementService's sanitising, dedupe window and recipients; the once-per-
-- round Rainbow Feather milestones; the Egg's announcements through the real services; and a guard
-- that announcing the reveal, the pickup and the hand-over never moves the Egg or touches a record.

return function(describe, it, expect)
	local ServerStorage = game:GetService("ServerStorage")
	local Shared = game:GetService("ReplicatedStorage").Shared
	local Server = game:GetService("ServerScriptService").Server
	local Config = require(Shared.Config)
	local Clock = require(Shared.Clock)
	local Schema = require(Shared.Net.Schema)
	local NetSchema = require(Shared.Net.NetSchema)
	local PileGrid = require(Shared.Domain.PileGrid)
	local ChapterLayout = require(Shared.Domain.ChapterLayout)
	local AnnouncementService = require(Server.Services.AnnouncementService)
	local RoundAnnouncements = require(Server.Services.RoundAnnouncements)
	local GameplayHarness = require(ServerStorage.Tests.Helpers.GameplayHarness)
	local cfg = Config.fromRaw(require(ServerStorage.SFE.SystemConfig))
	local layout = ChapterLayout.chapter1
	local cost = cfg.plume.rainbowCost
	local schema = NetSchema.build(cfg).byName.Announcement

	local function player(userId)
		return { UserId = userId, Name = "P" .. userId }
	end

	local function service(everyone)
		local clock = Clock.fake(1000)
		local sent = {}
		local announcements = AnnouncementService.new({
			send = function(target, remoteName, payload)
				expect(remoteName).toBe("Announcement")
				expect(Schema.validate(schema.payload, payload).ok).toBe(true)
				table.insert(sent, { userId = target.UserId, payload = payload })
			end,
			getPlayers = function()
				return everyone or {}
			end,
			clock = clock,
		})
		return announcements, sent, clock
	end

	describe("AnnouncementService", function()
		it("the schema is registered as a server event", function()
			expect(schema ~= nil).toBe(true)
			expect(schema.direction).toBe("serverToClient")
			expect(schema.kind).toBe("event")
		end)

		it("sends to the given recipients, or everyone when none are given", function()
			local everyone = { player(1), player(2), player(3) }
			local announcements, sent = service(everyone)
			expect(announcements:announce({ everyone[2] }, { kind = "egg_carried", text = "P2 has the Egg!", tone = "gold" })).toBe(1)
			expect(#sent).toBe(1)
			expect(sent[1].userId).toBe(2)
			expect(announcements:announce(nil, { kind = "egg_uncovered", text = "THE EGG IS UNCOVERED!", tone = "gold" })).toBe(3)
			expect(#sent).toBe(4)
			-- A player listed twice still hears it once.
			expect(announcements:announce({ everyone[1], everyone[1] }, { kind = "x", text = "once" })).toBe(1)
		end)

		it("holds an identical kind + text quiet for two seconds, but not a different one", function()
			local announcements, sent, clock = service({ player(1) })
			local payload = { kind = "rainbow_first", text = "P1 found a Rainbow Feather!", tone = "rainbow" }
			expect(announcements:announce(nil, payload)).toBe(1)
			expect(announcements:announce(nil, payload)).toBe(0)
			clock:advance(1.9)
			expect(announcements:announce(nil, payload)).toBe(0)
			-- Same kind, different text; same text, different kind: both are their own announcement.
			expect(announcements:announce(nil, { kind = "rainbow_first", text = "P2 found a Rainbow Feather!" })).toBe(1)
			expect(announcements:announce(nil, { kind = "other", text = payload.text })).toBe(1)
			clock:advance(0.2)
			expect(announcements:announce(nil, payload)).toBe(1)
			expect(#sent).toBe(4)
			expect(announcements.stats.suppressed).toBe(2)
		end)

		it("sanitises tone, length and position into the schema, and refuses an empty announcement", function()
			local announcements, sent = service({ player(1) })
			expect(announcements:announce(nil, { kind = "x", text = "" })).toBe(0)
			expect(announcements:announce(nil, { kind = "bad kind", text = "hi" })).toBe(0)
			expect(announcements:announce(nil, { text = "no kind" })).toBe(0)
			expect(announcements:announce(nil, {
				kind = "long",
				text = string.rep("A", 200),
				sub = string.rep("b", 300),
				tone = "neon",
				userId = 12.7,
				position = Vector3.new(1, 2, 3),
			})).toBe(1)
			local wire = sent[1].payload
			expect(wire.tone).toBe("info")
			expect(#wire.text <= 80).toBe(true)
			expect(#wire.sub <= 120).toBe(true)
			expect(wire.userId).toBe(12)
			expect(wire.position).toBe(Vector3.new(1, 2, 3))
		end)
	end)

	-- Real services, plus an AnnouncementService whose sends are captured.
	local function setup(members)
		local h = GameplayHarness.new(cfg)
		for _, userId in ipairs(members) do
			h.join(userId)
		end
		local roundId, runtime = h.startRound(members)
		local sent = {}
		local announcements = AnnouncementService.new({
			send = function(target, _name, payload)
				table.insert(sent, { userId = target.UserId, payload = payload })
			end,
			getPlayers = function()
				return {}
			end,
			clock = h.clock,
		})
		local round = RoundAnnouncements.new({
			config = cfg,
			announcements = announcements,
			playerOf = function(userId)
				return h.playerData:playerOf(userId)
			end,
			nameOf = function(userId)
				return "P" .. userId
			end,
		})
		round:bindEgg(h.egg)
		h.collection.collected:Connect(function(userId, rt, result)
			round:onAwarded(userId, rt, result)
		end)
		h.tools.awarded:Connect(function(userId, rt, result)
			round:onAwarded(userId, rt, result)
		end)
		local function kinds()
			local out = {}
			for _, entry in ipairs(sent) do
				out[entry.payload.kind] = (out[entry.payload.kind] or 0) + 1
			end
			return out
		end
		return h, roundId, runtime, round, sent, kinds
	end

	-- An award as the services report it, after the bag already took the feathers.
	local function award(runtime, userId, rainbow)
		runtime.players[userId].carriedRainbow += rainbow
		return { rainbow = rainbow, awarded = 0 }
	end

	describe("Rainbow Feather milestones", function()
		it("announces a player's first Rainbow Feather once per round, to the whole round", function()
			local h, _, runtime, round, sent, kinds = setup({ 1, 2 })
			expect(round:onAwarded(1, runtime, { rainbow = 0, awarded = 3 })).toBe(0)
			expect(round:onAwarded(1, runtime, award(runtime, 1, 1))).toBe(1)
			expect(#sent).toBe(2)
			expect(sent[1].payload.text).toBe("P1 found a Rainbow Feather!")
			expect(sent[1].payload.tone).toBe("rainbow")
			-- Past the dedupe window it is still once: the rule is per round, not per two seconds.
			h.clock:advance(10)
			expect(round:onAwarded(1, runtime, award(runtime, 1, 1))).toBe(0)
			-- Another player's first is their own.
			expect(round:onAwarded(2, runtime, award(runtime, 2, 1))).toBe(1)
			expect(kinds().rainbow_first).toBe(4)
		end)

		it("announces reaching the Plume cost once, never after Plume was used or the Egg is out", function()
			local h, _, runtime, round, _sent, kinds = setup({ 1, 2, 3 })
			runtime.players[1].carriedRainbow = cost - 2
			expect(#round:rainbowMilestones(1, runtime, award(runtime, 1, 1))).toBe(1) -- first only
			local milestones = round:rainbowMilestones(1, runtime, award(runtime, 1, 1))
			expect(#milestones).toBe(1)
			expect(milestones[1].kind).toBe("plume_ready")
			expect(milestones[1].text).toBe("P1 can visit Plume!")
			-- Dropping under the cost and climbing back is not a second announcement.
			runtime.players[1].carriedRainbow = 0
			expect(#round:rainbowMilestones(1, runtime, award(runtime, 1, cost))).toBe(0)
			-- A player who already has Plume's clue is not told to visit him.
			runtime.players[2].plumeClue = { kind = "depth", key = "deep", title = "", text = "" }
			runtime.players[2].carriedRainbow = cost
			local used = round:rainbowMilestones(2, runtime, { rainbow = 1 })
			expect(#used).toBe(1)
			expect(used[1].kind).toBe("rainbow_first")
			-- Once the Egg is out, Plume is closed.
			expect(h.egg:revealNow(runtime)).toBe(true)
			runtime.players[3].carriedRainbow = cost
			local out = round:rainbowMilestones(3, runtime, { rainbow = 1 })
			expect(#out).toBe(1)
			expect(out[1].kind).toBe("rainbow_first")
			expect(kinds().plume_ready).toBe(nil) -- rainbowMilestones itself never sends
		end)

		it("resets with the next round", function()
			local h, _, runtime, round = setup({ 1 })
			expect(round:onAwarded(1, runtime, award(runtime, 1, 1))).toBe(1)
			expect(h.egg:revealNow(runtime)).toBe(true)
			h.standAt(1, h.egg:position(runtime))
			expect(h.egg:claim(1, h.token(1)).ok).toBe(true)
			h.standAt(1, layout.farmer)
			expect(h.egg:deliver(1, h.token(1)).ok).toBe(true)
			h.clock:advance(cfg.round.resultScreenAutoContinueSeconds + 5)
			h.rounds:tick()
			local _, runtime2 = h.startRound({ 1 })
			expect(runtime2 ~= runtime).toBe(true)
			expect(round:onAwarded(1, runtime2, award(runtime2, 1, 1))).toBe(1)
		end)

		it("stays quiet outside the search", function()
			local _, _, runtime, round = setup({ 1 })
			runtime.state = table.clone(runtime.state)
			runtime.state.phase = "Victory"
			expect(#round:rainbowMilestones(1, runtime, { rainbow = 1 })).toBe(0)
		end)
	end)

	describe("the Egg", function()
		local function pileRecords(runtime)
			local total = 0
			for _, cell in ipairs(runtime.grid.cells) do
				total += cell.remaining
			end
			return total
		end

		it("announces uncovered, carried and returned without moving the Egg or touching a record", function()
			local h, _, runtime, round, sent, kinds = setup({ 1, 2 })
			local buried = h.egg:position(runtime)
			local node = { x = runtime.eggNode.x, z = runtime.eggNode.z, slot = runtime.eggSlot }
			-- The same round without announcements: the reveal's own hollow is the only pile change.
			local bare = GameplayHarness.new(cfg)
			bare.join(1)
			bare.join(2)
			local _, bareRuntime = bare.startRound({ 1, 2 })
			expect(pileRecords(bareRuntime)).toBe(pileRecords(runtime))
			expect(bare.egg:revealNow(bareRuntime)).toBe(true)

			expect(h.egg:revealNow(runtime)).toBe(true)
			local records = pileRecords(runtime)
			expect(records).toBe(pileRecords(bareRuntime))
			-- Announcing again (a retried path) changes nothing either.
			round:onEggRevealed(runtime, buried)
			expect(kinds().egg_uncovered).toBe(2)
			local uncovered = sent[#sent].payload
			expect(uncovered.text).toBe("THE EGG IS UNCOVERED!")
			expect(uncovered.tone).toBe("gold")
			expect(uncovered.position).toBe(buried)
			-- Announcing is not revealing twice, and not a move.
			expect(h.egg:revealNow(runtime)).toBe(false)
			expect(kinds().egg_uncovered).toBe(2)
			expect(h.egg:position(runtime)).toBe(buried)
			expect(pileRecords(runtime)).toBe(records)

			h.standAt(1, buried)
			expect(h.egg:claim(1, h.token(1)).ok).toBe(true)
			expect(kinds().egg_carried).toBe(2)
			expect(sent[#sent].payload.text).toBe("P1 has the Egg!")
			expect(sent[#sent].payload.userId).toBe(1)
			expect(h.egg:position(runtime)).toBe(buried)
			expect(pileRecords(runtime)).toBe(records)
			expect(runtime.state.victory).toBe(nil) -- the pickup never wins on its own

			h.standAt(1, layout.farmer)
			expect(h.egg:deliver(1, h.token(1)).ok).toBe(true)
			expect(kinds().egg_returned).toBe(2)
			expect(sent[#sent].payload.text).toBe("EGG RETURNED!")
			expect(sent[#sent].payload.position).toBe(layout.farmer)
			expect(h.egg:position(runtime)).toBe(buried)
			expect(pileRecords(runtime)).toBe(records)
			expect(runtime.eggNode.x).toBe(node.x)
			expect(runtime.eggNode.z).toBe(node.z)
			expect(runtime.eggSlot).toBe(node.slot)
			expect(PileGrid.removedFraction(runtime.grid) >= 0).toBe(true)
		end)

		it("reaches only the round's present members", function()
			local h, _, runtime, _round, sent = setup({ 1, 2 })
			h.join(3) -- in the server, not in the round
			runtime.state.present[2] = false
			h.egg:revealNow(runtime)
			expect(#sent).toBe(1)
			expect(sent[1].userId).toBe(1)
		end)
	end)

	describe("client presentation rules", function()
		local Client = game:GetService("StarterPlayer").StarterPlayerScripts.Client

		it("the banner shows one at a time, queues the rest and merges identical words", function()
			local AnnouncementBanner = require(Client.UI.AnnouncementBanner)
			local spaces = {}
			local banner = AnnouncementBanner.new(Instance.new("Frame"), {
				motion = function()
					return {}
				end,
				headless = true,
				onSpace = function(px)
					table.insert(spaces, px)
				end,
			})
			expect(banner:show({ kind = "egg_uncovered", text = "THE EGG IS UNCOVERED!", tone = "gold" })).toBe(true)
			expect(banner:current().text).toBe("THE EGG IS UNCOVERED!")
			expect(banner:show({ kind = "egg_uncovered", text = "THE EGG IS UNCOVERED!", tone = "gold" })).toBe(false)
			expect(banner:show({ kind = "egg_carried", text = "P1 has the Egg!", tone = "gold" })).toBe(true)
			expect(banner:show({ kind = "egg_carried", text = "P1 has the Egg!", tone = "gold" })).toBe(false)
			expect(banner:queueLength()).toBe(1)
			expect(banner.merged).toBe(2)
			expect(banner:show({ text = "" })).toBe(false)
			banner:advance()
			expect(banner:current().text).toBe("P1 has the Egg!")
			expect(banner:queueLength()).toBe(0)
			banner:advance()
			expect(banner:isShowing()).toBe(false)
			expect(spaces[#spaces]).toBe(0)
			for index = 1, AnnouncementBanner.MAX_QUEUE + 3 do
				banner:show({ text = "note " .. index })
			end
			expect(banner:queueLength()).toBe(AnnouncementBanner.MAX_QUEUE)
			banner:clear()
			expect(banner:isShowing()).toBe(false)
			expect(banner:queueLength()).toBe(0)
		end)

		it("the Plume pill follows the projection: progress, ready, used, hidden outside the search", function()
			local RainbowFeatherController = require(Client.Controllers.RainbowFeatherController)
			local state = RainbowFeatherController.plumeState(cfg, "Searching", "chapter1", { carriedRainbow = 7 })
			expect(state.visible).toBe(true)
			expect(state.carried).toBe(7)
			expect(state.cost).toBe(cost)
			expect(state.used).toBe(false)
			expect(RainbowFeatherController.plumeState(cfg, "Searching", "chapter1", { carriedRainbow = 3, plumeClue = {} }).used).toBe(
				true
			)
			expect(RainbowFeatherController.plumeState(cfg, "Lobby", "chapter1", { carriedRainbow = 3 }).visible).toBe(false)
			expect(RainbowFeatherController.plumeState(cfg, "Searching", "chapter1", nil).visible).toBe(false)
		end)

		it("celebration effects thin out on the low tier and under reduced motion", function()
			local CelebrationController = require(Client.Controllers.CelebrationController)
			expect(CelebrationController.scaleFor("high", false)).toBe(1)
			expect(CelebrationController.scaleFor("low", false) < CelebrationController.scaleFor("medium", false)).toBe(true)
			expect(CelebrationController.scaleFor("high", true) < 1).toBe(true)
			expect(CelebrationController.scaleFor("low", true) < CelebrationController.scaleFor("low", false)).toBe(true)
		end)
	end)
end
