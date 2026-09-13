--!nocheck
-- Phase 4 party scenarios: 1-4 members, serialized start, leader transfer, countdown cancel,
-- destination availability versus unlock policy, locked-member reporting, and the open party list.

return function(describe, it, expect)
	local ServerStorage = game:GetService("ServerStorage")
	local Shared = game:GetService("ReplicatedStorage").Shared
	local Server = game:GetService("ServerScriptService").Server
	local Config = require(Shared.Config)
	local PartyService = require(Server.Services.PartyService)
	local GameplayHarness = require(ServerStorage.Tests.Helpers.GameplayHarness)
	local cfg = Config.fromRaw(require(ServerStorage.SFE.SystemConfig))

	local function fresh(count)
		local h = GameplayHarness.new(cfg)
		for userId = 1, count or 1 do
			h.join(userId)
		end
		return h
	end

	describe("Membership", function()
		it("a full four-member party starts once, a fifth member is refused, and duplicate starts fail", function()
			local h = fresh(5)
			local party = h.parties:create(1, "chapter1", "normal")
			for userId = 2, 4 do
				local joined, err = h.parties:join(userId, party.partyId)
				expect(err).toBeNil()
				expect(#joined.members).toBe(userId)
			end
			local _, full = h.parties:join(5, party.partyId)
			expect(full).toBe("party_full")
			local started = h.parties:start(1, party.partyId)
			expect(started.phase).toBe("Countdown")
			local _, again = h.parties:start(1, party.partyId)
			expect(again).toBe("already_started")
			local _, notLeader = h.parties:start(2, party.partyId)
			expect(notLeader).toBe("not_leader")
			h.clock:advance(cfg.round.countdownSeconds)
			h.parties:tick()
			local roundId = h.sessions:get(1).roundId
			expect(roundId).toBeTruthy()
			expect(#h.rounds:get(roundId).members).toBe(4)
			for userId = 1, 4 do
				expect(h.sessions:get(userId).roundId).toBe(roundId)
			end
			expect(h.sessions:get(5).phase).toBe("Lobby")
			expect(h.analyticsAdapter:countOf("party_joined")).toBe(3)
		end)

		it("the leader can cancel the countdown; members cannot; leaving mid-countdown transfers leadership", function()
			local h = fresh(3)
			local party = h.parties:create(1, "chapter1", "normal")
			h.parties:join(2, party.partyId)
			h.parties:join(3, party.partyId)
			h.parties:start(1, party.partyId)
			local _, notLeader = h.parties:cancel(2, party.partyId)
			expect(notLeader).toBe("not_leader")
			local cancelled = h.parties:cancel(1, party.partyId)
			expect(cancelled.phase).toBe("Ready")
			expect(cancelled.countdownDeadline).toBeNil()
			local _, notCounting = h.parties:cancel(1, party.partyId)
			expect(notCounting).toBe("invalid_phase")
			h.parties:start(1, party.partyId)
			local after = h.parties:leave(1)
			expect(after.leaderUserId).toBe(2)
			expect(after.phase).toBe("Ready")
			expect(after.members).toEqual({ 2, 3 })
			expect(h.sessions:get(1).phase).toBe("Lobby")
			-- The new leader owns the start.
			expect(h.parties:start(2, after.partyId).phase).toBe("Countdown")
			h.clock:advance(cfg.round.countdownSeconds)
			h.parties:tick()
			expect(h.sessions:get(2).phase).toBe("Round")
			expect(h.sessions:get(3).phase).toBe("Round")
			expect(h.sessions:get(1).phase).toBe("Lobby")
		end)

		it("a member leaving during the countdown re-validates and the last member leaving closes the party", function()
			local h = fresh(2)
			local party = h.parties:create(1, "chapter1", "normal")
			h.parties:join(2, party.partyId)
			h.parties:start(1, party.partyId)
			local afterLeave = h.parties:leave(2)
			expect(afterLeave.phase).toBe("Ready")
			expect(afterLeave.members).toEqual({ 1 })
			local closed = h.parties:leave(1)
			expect(closed.phase).toBe("Closed")
			expect(h.parties:count()).toBe(0)
			expect(h.parties:partyOf(1)).toBeNil()
		end)
	end)

	describe("Destinations", function()
		it("unavailable chapters are refused at create and set-destination; unlock policy reports locked members", function()
			local h = fresh(2)
			-- Content availability is config: mark Chapter 2 unshipped for this harness only.
			local sealed = table.clone(cfg.chapters.chapter2)
			sealed.availableDifficulties = { normal = false, hard = false }
			local chapters = table.clone(cfg.chapters)
			chapters.chapter2 = sealed
			local sealedConfig = table.clone(cfg)
			sealedConfig.chapters = chapters
			h.parties._config = sealedConfig
			local _, unavailable = h.parties:create(1, "chapter2", "normal")
			expect(unavailable).toBe(PartyService.Errors.UNAVAILABLE)
			local _, badDifficulty = h.parties:create(1, "chapter1", "nightmare")
			expect(badDifficulty).toBe(PartyService.Errors.INVALID_DIFFICULTY)
			expect(h.parties:count()).toBe(0)
			local party = h.parties:create(1, "chapter1", "normal")
			h.parties:join(2, party.partyId)
			local _, blocked = h.parties:setDestination(1, "chapter2", "normal")
			expect(blocked).toBe(PartyService.Errors.UNAVAILABLE)
			expect(h.parties:get(party.partyId).chapter).toBe("chapter1")
			-- Hard is available content but locked by policy until a Normal win: the projection says who.
			local hard = h.parties:setDestination(1, "chapter1", "hard")
			expect(hard.phase).toBe("Forming")
			local projection = h.parties:project(hard)
			expect(projection.valid).toBe(false)
			expect(projection.invalidReason).toBe("destination_locked")
			expect(projection.lockedUserIds).toEqual({ 1, 2 })
			h.profile(1):update(function(data)
				data.progression.chapterWins.chapter1.normal = cfg.chapters.chapter1.hardUnlock.count
			end)
			local partial = h.parties:project(h.parties:setDestination(1, "chapter1", "hard"))
			expect(partial.valid).toBe(false)
			expect(partial.lockedUserIds).toEqual({ 2 })
			h.profile(2):update(function(data)
				data.progression.chapterWins.chapter1.normal = cfg.chapters.chapter1.hardUnlock.count
			end)
			local ready = h.parties:setDestination(1, "chapter1", "hard")
			expect(ready.phase).toBe("Ready")
			expect(h.parties:project(ready).valid).toBe(true)
			expect(h.parties:project(ready).lockedUserIds).toEqual({})
		end)

		it("availability is config-driven and separate from the unlock policy", function()
			expect(PartyService.isDestinationAvailable(cfg, "chapter1", "normal")).toBe(true)
			expect(PartyService.isDestinationAvailable(cfg, "chapter1", "hard")).toBe(true)
			local sealed = table.clone(cfg.chapters.chapter2)
			sealed.availableDifficulties = { normal = false, hard = false }
			local chapters = table.clone(cfg.chapters)
			chapters.chapter2 = sealed
			local sealedConfig = table.clone(cfg)
			sealedConfig.chapters = chapters
			local ok, reason = PartyService.isDestinationAvailable(sealedConfig, "chapter2", "normal")
			expect(ok).toBe(false)
			expect(reason).toBe(PartyService.Errors.UNAVAILABLE)
			local flags = table.clone(cfg.featureFlags)
			flags.chapter2Enabled = false
			local flagged = table.clone(cfg)
			flagged.featureFlags = flags
			expect(PartyService.isDestinationAvailable(flagged, "chapter2", "normal")).toBe(false)
			local _, unknown = PartyService.isDestinationAvailable(cfg, "chapter9", "normal")
			expect(unknown).toBe(PartyService.Errors.NOT_FOUND)
		end)
	end)

	describe("Party list", function()
		it("lists only joinable parties and hides parties that are full or counting down", function()
			local h = fresh(6)
			local open = h.parties:create(1, "chapter1", "normal")
			local counting = h.parties:create(2, "chapter1", "normal")
			h.parties:start(2, counting.partyId)
			local full = h.parties:create(3, "chapter1", "normal")
			h.parties:join(4, full.partyId)
			h.parties:join(5, full.partyId)
			h.parties:join(6, full.partyId)
			local list = h.parties:openParties()
			expect(#list).toBe(1)
			expect(list[1].partyId).toBe(open.partyId)
			expect(list[1].leaderUserId).toBe(1)
			expect(list[1].maxMembers).toBe(cfg.project.maxPartyPlayers)
			expect(list[1].reservation).toBeNil()
		end)
	end)
end
