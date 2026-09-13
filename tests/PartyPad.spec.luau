--!nocheck
-- Party nest pads (A-LOBBY-06): zone membership drives party membership through the real
-- PartyService; signs mirror the party; a full pad sets off by itself; modal parties are untouched.

return function(describe, it, expect)
	local ServerStorage = game:GetService("ServerStorage")
	local Shared = game:GetService("ReplicatedStorage").Shared
	local Config = require(Shared.Config)
	local ChapterLayout = require(Shared.Domain.ChapterLayout)
	local PartyPadService = require(game:GetService("ServerScriptService").Server.Services.PartyPadService)
	local GameplayHarness = require(ServerStorage.Tests.Helpers.GameplayHarness)
	local cfg = Config.fromRaw(require(ServerStorage.SFE.SystemConfig))
	local pads = ChapterLayout.lobby.pads

	local function harness(count)
		local h = GameplayHarness.new(cfg)
		local ids = {}
		for userId = 1, count do
			h.join(userId)
			table.insert(ids, userId)
			h.standAt(userId, Vector3.new(0, 3, -100)) -- lobby path, on no pad
		end
		local signs = {}
		local service = PartyPadService.new({
			config = cfg,
			parties = h.parties,
			sessions = h.sessions,
			clock = h.clock,
			getCharacterPosition = function(userId)
				return h.positions[userId]
			end,
			players = function()
				return table.clone(ids)
			end,
			setSign = function(index, text)
				signs[index] = text
			end,
		})
		return h, service, signs
	end

	local function onPad(h, userId, index)
		h.standAt(userId, pads[index].center - Vector3.new(0, 2, 0))
	end

	describe("Zones", function()
		it("standing on a pad founds its party, a second player joins it, stepping off leaves it", function()
			local h, service, signs = harness(2)
			expect(service:tick()).toBe(0)
			expect(signs[1]).toBe("Join Match\n0/4")
			onPad(h, 1, 1)
			expect(service:tick()).toBe(1)
			local party = h.parties:partyOf(1)
			expect(party).toBeTruthy()
			expect(party.leaderUserId).toBe(1)
			expect(service:padOf(party.partyId)).toBe(1)
			expect(signs[1]).toBe("Join Match\n1/4  Henhouse")
			onPad(h, 2, 1)
			expect(service:tick()).toBe(1)
			expect(#h.parties:partyOf(2).members).toBe(2)
			expect(signs[1]).toBe("Join Match\n2/4  Henhouse")
			h.standAt(2, Vector3.new(0, 3, -100))
			expect(service:tick()).toBe(1)
			expect(h.parties:partyOf(2)).toBeNil()
			expect(#h.parties:partyOf(1).members).toBe(1)
			-- The founder leaves too: the pad party closes and the sign resets.
			h.standAt(1, Vector3.new(0, 3, -100))
			service:tick()
			expect(h.parties:partyOf(1)).toBeNil()
			expect(service:partyAt(1)).toBeNil()
			expect(signs[1]).toBe("Join Match\n0/4")
			expect(service.stats.creates).toBe(1)
			expect(service.stats.joins).toBe(1)
		end)

		it("pads are independent and a fifth player cannot join a full pad", function()
			local h, service = harness(5)
			for userId = 1, 4 do
				onPad(h, userId, 2)
			end
			onPad(h, 5, 3)
			service:tick()
			expect(#h.parties:partyOf(1).members).toBe(4)
			expect(service:padOf(h.parties:partyOf(5).partyId)).toBe(3)
			h.standAt(5, pads[2].center)
			service:tick() -- leaves pad 3's party (stepped off) ...
			service:tick() -- ... and cannot join pad 2 (full)
			expect(h.parties:partyOf(5)).toBeNil()
			expect(#h.parties:partyOf(1).members).toBe(4)
		end)

		it("a full pad sets off after the configured delay and the sign counts down", function()
			local h, service, signs = harness(4)
			for userId = 1, 4 do
				onPad(h, userId, 4)
			end
			service:tick()
			local party = h.parties:partyOf(1)
			expect(party.phase).toBe("Ready")
			h.clock:advance(cfg.lobby.padFullAutoStartSeconds - 0.5)
			service:tick()
			expect(h.parties:partyOf(1).phase).toBe("Ready")
			h.clock:advance(1)
			service:tick()
			expect(h.parties:partyOf(1).phase).toBe("Countdown")
			expect(string.find(signs[4], "Setting off", 1, true)).toBeTruthy()
			expect(service.stats.autoStarts).toBe(1)
			-- Everyone stays on the pad; the countdown completes into a round through PartyService.
			h.clock:advance(cfg.round.countdownSeconds)
			h.parties:tick()
			expect(h.sessions:get(1).phase).toBe("Round")
			service:tick()
			expect(signs[4]).toBe("Join Match\n0/4")
		end)

		it("modal-formed parties keep their members even when they stand on a pad", function()
			local h, service = harness(2)
			local party = h.parties:create(1, "chapter1", "normal")
			onPad(h, 1, 1)
			service:tick()
			expect(h.parties:partyOf(1).partyId).toBe(party.partyId)
			expect(service:padOf(party.partyId)).toBeNil()
			h.standAt(1, Vector3.new(0, 3, -100))
			service:tick()
			expect(h.parties:partyOf(1).partyId).toBe(party.partyId)
		end)
	end)
end
