--!strict
-- Rainbow Feathers on the local player's screen:
--
--   * a Rainbow Feather that lands in the bag celebrates at the flight's end - a rainbow burst at the
--     carried bundle, the bag count flashing through the rainbow and a "+N RAINBOW" tag - with no
--     sound of its own (the landing's sounds are the pick's). Hand and rake picks report through
--     PickupFeedbackController's landing; vac ticks and blasts through their tool_award event.
--   * the Plume pill beside the bag: "7/10 FOR PLUME", READY FOR PLUME at the cost, PLUME USED once
--     this round's clue is bought. Live from the round's player projection; shown only in a chapter
--     where Plume stands, during the search.
--
-- The rare "Soryn found a Rainbow Feather!" / "Soryn can visit Plume!" banners are the server's
-- (RoundAnnouncements); nothing here announces.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Shared = ReplicatedStorage.Shared
local Trove = require(Shared.Util.Trove)
local ChapterLayout = require(Shared.Domain.ChapterLayout)
local PlumeClue = require(Shared.Domain.PlumeClue)

local RainbowFeatherController = {}
RainbowFeatherController.__index = RainbowFeatherController

export type RainbowFeatherController = typeof(setmetatable(
	{} :: {
		_deps: any,
		_trove: Trove.Trove,
		_lastLandedAt: number,
		stats: { landings: number, feathers: number },
	},
	RainbowFeatherController
))

-- Plume pill state from a round projection (pure; exported for tests).
function RainbowFeatherController.plumeState(
	config: { [string]: any },
	phase: string?,
	chapter: string?,
	player: { [string]: any }?
): { visible: boolean, carried: number, cost: number, used: boolean }
	local cost = PlumeClue.cost(config)
	local layout = chapter and (ChapterLayout :: any)[chapter]
	-- Only while Plume can still help: once the Egg is out the pill would advertise a closed stall.
	local searching = phase == "Searching"
	local visible = searching and player ~= nil and layout ~= nil and layout.clueStation ~= nil
	return {
		visible = visible,
		carried = if player then (tonumber(player.carriedRainbow) or 0) else 0,
		cost = cost,
		used = player ~= nil and player.plumeClue ~= nil,
	}
end

function RainbowFeatherController.new(deps: {
	net: any,
	round: any,
	hud: any,
	celebration: any,
	config: { [string]: any },
}): RainbowFeatherController
	local self = setmetatable({
		_deps = deps,
		_trove = Trove.new(),
		_lastLandedAt = 0,
		stats = { landings = 0, feathers = 0 },
	}, RainbowFeatherController)
	local function refresh()
		self:refreshPlume()
	end
	self._trove:add(deps.round.playerChanged:Connect(refresh))
	self._trove:add(deps.round.phaseChanged:Connect(refresh))
	-- Vac ticks and blasts award outside a request; their event carries the Rainbow count.
	self._trove:add(deps.net:on("ToolEvent", function(payload)
		if payload.kind == "tool_award" and payload.userId == Players.LocalPlayer.UserId and (tonumber(payload.rainbow) or 0) > 0 then
			self:landed(payload.rainbow)
		end
	end))
	refresh()
	return self
end

function RainbowFeatherController.refreshPlume(self: RainbowFeatherController)
	local round = self._deps.round
	local snapshot = round.round
	local state = RainbowFeatherController.plumeState(
		self._deps.config,
		if snapshot then snapshot.phase else nil,
		if snapshot then snapshot.chapter else nil,
		round.player
	)
	self._deps.hud.round:setPlume(state)
end

-- `count` Rainbow Feathers reached the bag. `worldPosition` is the flight's end (the carried bundle);
-- without one the bundle's point is looked up.
function RainbowFeatherController.landed(self: RainbowFeatherController, count: number, worldPosition: Vector3?)
	local n = math.max(1, math.floor(tonumber(count) or 1))
	local deps = self._deps
	self.stats.landings += 1
	self.stats.feathers += n
	local now = os.clock()
	-- A vac stream can land rainbows on consecutive ticks: the bag flash restarts, the burst thins.
	local recent = now - self._lastLandedAt < 0.35
	self._lastLandedAt = now
	local point = worldPosition or (deps.hud.carriedStackWorldPoint and deps.hud:carriedStackWorldPoint())
	if point and deps.celebration then
		deps.celebration:burst(point, "rainbow", if recent then 0.35 else math.min(1.2, 0.7 + 0.15 * n))
	end
	deps.hud.round:flashRainbow(n)
	self:refreshPlume()
end

function RainbowFeatherController.destroy(self: RainbowFeatherController)
	self._trove:destroy()
end

return RainbowFeatherController
