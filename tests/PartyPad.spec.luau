--!nocheck
-- Party nest pads (A-LOBBY-06): stepping onto an empty pad offers the party screen (no party is
-- founded by itself); a party founded while standing on that pad binds to it; other players who
-- step on join it, stepping off leaves it; a full pad sets off by itself; signs mirror the party.

return function(describe, it, expect)
	local ServerStorage = game:GetService("ServerStorage")
	local Shared = game:GetService("ReplicatedStorage").Shared
	local Config = require(Shared.Config)
	local ChapterLayout = require(Shared.Domain.ChapterLayout)
	local PartyPadService = require(game:GetService("ServerScriptService").Server.Services.PartyPadService)
	local GameplayHarness = require(ServerStorage.Tests.Helpers.GameplayHarness)
	local cfg = Config.fromRaw(require(ServerStorage.SFE.SystemConfig))
	local pads = ChapterLayout.lobby.pads
	local maxPlayers = cfg.project.maxPartyPlayers
	local emptySign = string.format("0/%d\nTouch to create a party", maxPlayers)

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
		local prompts = {}
		service.padPrompt:Connect(function(userId, index)
			table.insert(prompts, { userId = userId, pad = index })
		end)
		return h, service, signs, prompts
	end

	local function onPad(h, userId, index)
		h.standAt(userId, pads[index].center - Vector3.new(0, 2, 0))
	end

	describe("Zones", function()
		it("an empty pad offers the party screen once; a party founded there binds to the pad", function()
			local h, service, signs, prompts = harness(2)
			expect(service:tick()).toBe(0)
			expect(signs[1]).toBe(emptySign)
			onPad(h, 1, 1)
			service:tick()
			service:tick()
			expect(#prompts).toBe(1)
			expect(prompts[1].userId).toBe(1)
			expect(prompts[1].pad).toBe(1)
			expect(h.parties:partyOf(1)).toBeNil()
			-- The player presses Create on the screen while standing there.
			local party = h.parties:create(1, "chapter1", "normal", 4)
			expect(party.maxMembers).toBe(4)
			expect(service:tick()).toBe(1)
			expect(service:padOf(party.partyId)).toBe(1)
			expect(signs[1]).toBe("1/4\nHenhouse  -  waiting for 3 more")
			onPad(h, 2, 1)
			expect(service:tick()).toBe(1)
			expect(#h.parties:partyOf(2).members).toBe(2)
			expect(signs[1]).toBe("2/4\nHenhouse  -  waiting for 2 more")
			h.standAt(2, Vector3.new(0, 3, -100))
			expect(service:tick()).toBe(1)
			expect(h.parties:partyOf(2)).toBeNil()
			expect(#h.parties:partyOf(1).members).toBe(1)
			-- The founder leaves too: the pad party closes and the sign resets.
			h.standAt(1, Vector3.new(0, 3, -100))
			service:tick()
			expect(h.parties:partyOf(1)).toBeNil()
			expect(service:partyAt(1)).toBeNil()
			expect(signs[1]).toBe(emptySign)
			expect(service.stats.creates).toBe(1)
			expect(service.stats.joins).toBe(1)
			expect(service.stats.prompts).toBe(1)
		end)

		it("a solo party (size 1) is full at once and sets off after the short auto-start delay", function()
			local h, service, signs = harness(1)
			onPad(h, 1, 1)
			service:tick()
			local party = h.parties:create(1, "chapter1", "normal", 1)
			expect(party.maxMembers).toBe(1)
			service:tick()
			h.clock:advance(cfg.lobby.padFullAutoStartSeconds + 0.1)
			service:tick()
			expect(h.parties:partyOf(1).phase).toBe("Countdown")
			expect(string.find(signs[1], "Setting off", 1, true)).toBeTruthy()
		end)

		it("pads are independent and a fifth player cannot join a full pad", function()
			local h, service = harness(5)
			onPad(h, 1, 2)
			service:tick()
			h.parties:create(1, "chapter1", "normal", 4)
			service:tick()
			for userId = 2, 4 do
				onPad(h, userId, 2)
			end
			onPad(h, 5, 3)
			service:tick()
			h.parties:create(5, "chapter1", "normal", 4)
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
			onPad(h, 1, 4)
			service:tick()
			h.parties:create(1, "chapter1", "normal", 4)
			service:tick()
			for userId = 2, 4 do
				onPad(h, userId, 4)
			end
			service:tick()
			local party = h.parties:partyOf(1)
			expect(party.phase).toBe("Ready")
			h.clock:advance(cfg.lobby.padFullAutoStartSeconds - 0.25)
			service:tick()
			expect(h.parties:partyOf(1).phase).toBe("Ready")
			h.clock:advance(0.5)
			service:tick()
			expect(h.parties:partyOf(1).phase).toBe("Countdown")
			expect(string.find(signs[4], "Setting off", 1, true)).toBeTruthy()
			expect(service.stats.autoStarts).toBe(1)
			-- Everyone stays on the pad; the countdown completes into a round through PartyService.
			h.clock:advance(cfg.round.countdownSeconds)
			h.parties:tick()
			expect(h.sessions:get(1).phase).toBe("Round")
			service:tick()
			expect(signs[4]).toBe(emptySign)
		end)

		it("a party founded away from the pads binds to the first empty pad its leader steps on", function()
			local h, service = harness(2)
			local party = h.parties:create(1, "chapter1", "normal")
			service:tick()
			expect(service:padOf(party.partyId)).toBeNil()
			onPad(h, 1, 1)
			service:tick()
			expect(service:padOf(party.partyId)).toBe(1)
			-- A non-leader member on an empty pad does not claim it.
			h.parties:join(2, party.partyId)
			onPad(h, 2, 2)
			service:tick()
			expect(service:partyAt(2)).toBeNil()
		end)
	end)
end
