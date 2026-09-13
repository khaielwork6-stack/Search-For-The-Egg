--!strict
-- Egg reveal and claim authority (STATE_MACHINES.md section 7). The Egg is concealed until its
-- cover cells are cleared AND the round's removed fraction reaches the node's depth (ASSUMED
-- A-EGG-03/07). Reveal happens once; claim requires proximity and the first valid claim wins.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local RoundReducer = require(Shared.Reducers.RoundReducer)
local PileGrid = require(Shared.Domain.PileGrid)
local ChapterLayout = require(Shared.Domain.ChapterLayout)
local Envelope = require(Shared.Net.Envelope)
local Signal = require(Shared.Util.Signal)

local EggService = {}
EggService.__index = EggService

export type EggService = typeof(setmetatable(
	{} :: {
		_config: { [string]: any },
		_rounds: any,
		_getCharacterPosition: (userId: number) -> Vector3?,
		_clock: any,
		_analytics: any?,
		revealed: any, -- (runtime, position)
		claimed: any, -- (runtime, userId)
		stats: { reveals: number, claims: number, rejected: number },
	},
	EggService
))

function EggService.new(options: {
	config: { [string]: any },
	rounds: any,
	clock: any,
	getCharacterPosition: (userId: number) -> Vector3?,
	analytics: any?,
}): EggService
	return setmetatable({
		_config = options.config,
		_rounds = options.rounds,
		_clock = options.clock,
		_getCharacterPosition = options.getCharacterPosition,
		_analytics = options.analytics,
		revealed = Signal.new(),
		claimed = Signal.new(),
		stats = { reveals = 0, claims = 0, rejected = 0 },
	}, EggService)
end

-- World position of the Egg for a runtime (server-only; never projected before reveal). In a
-- chapter whose layout places the Egg at the exit (Moonlit Cellar), the mound hides the key instead
-- and the Egg waits at the ladder.
function EggService.position(_self: EggService, runtime: any): Vector3
	local layout = ChapterLayout[runtime.state.chapter]
	if layout.eggAtExit then
		return layout.eggExit
	end
	local grid = runtime.grid
	return ChapterLayout.cellWorldPosition(layout, grid.width, grid.depth, grid.cellSize, runtime.eggNode.x, runtime.eggNode.z, 1)
end

-- World position of whatever the mound hides (the Egg in Chapter 1, the key in Chapter 2).
function EggService.buriedPosition(_self: EggService, runtime: any): Vector3
	local layout = ChapterLayout[runtime.state.chapter]
	local grid = runtime.grid
	return ChapterLayout.cellWorldPosition(layout, grid.width, grid.depth, grid.cellSize, runtime.eggNode.x, runtime.eggNode.z, 1)
end

-- Optional hook: when set and it returns true for a runtime, uncovering the buried node hands
-- control to the hook (Chapter 2 reveals the key) instead of revealing the Egg.
function EggService.setUncoverHook(self: EggService, hook: ((runtime: any, position: Vector3) -> boolean)?)
	(self :: any)._uncoverHook = hook
end

-- Marks the Egg revealed now (puzzle chapters call this when their last stage opens). Returns
-- true when the reveal happened on this call.
function EggService.revealNow(self: EggService, runtime: any): boolean
	if runtime.state.phase ~= "Searching" then
		return false
	end
	local next = self._rounds:markEggRevealed(runtime.state.roundId)
	if not next then
		return false
	end
	self.stats.reveals += 1
	local position = self:position(runtime)
	if self._analytics then
		self._analytics:track("egg_revealed", {
			chapter = runtime.state.chapter,
			difficulty = runtime.state.difficulty,
			removedFraction = PileGrid.removedFraction(runtime.grid),
			elapsedMs = RoundReducer.elapsedMs(next, self._clock:nowMs()),
		})
	end
	self.revealed:Fire(runtime, position)
	return true
end

-- Evaluates the reveal condition after a pile change. Returns true when the Egg was revealed now.
function EggService.checkReveal(self: EggService, runtime: any): boolean
	if runtime.state.phase ~= "Searching" then
		return false
	end
	local coverCleared = PileGrid.allCleared(runtime.grid, runtime.eggNode.coverIndexes)
	runtime.eggCoverCleared = coverCleared
	if not coverCleared then
		return false
	end
	if PileGrid.removedFraction(runtime.grid) < runtime.eggDepthFraction then
		return false -- exposed pending depth: keep clearing the nest
	end
	local hook = (self :: any)._uncoverHook
	if hook and hook(runtime, self:buriedPosition(runtime)) then
		return false -- the chapter took the uncover (key found); the Egg comes later
	end
	local next = self._rounds:markEggRevealed(runtime.state.roundId)
	if not next then
		return false
	end
	self.stats.reveals += 1
	local position = self:position(runtime)
	if self._analytics then
		self._analytics:track("egg_revealed", {
			chapter = runtime.state.chapter,
			difficulty = runtime.state.difficulty,
			removedFraction = PileGrid.removedFraction(runtime.grid),
			elapsedMs = RoundReducer.elapsedMs(next, self._clock:nowMs()),
		})
	end
	self.revealed:Fire(runtime, position)
	return true
end

function EggService.claim(self: EggService, userId: number, token: any): Envelope.Envelope<any>
	local runtime = self._rounds:roundOf(userId)
	if not runtime then
		self.stats.rejected += 1
		return Envelope.fail(Envelope.Codes.INVALID_STATE, "no_round")
	end
	if not RoundReducer.acceptsClaim(runtime.state) then
		self.stats.rejected += 1
		return Envelope.fail(Envelope.Codes.INVALID_STATE, if runtime.state.victory then "already_won" else "not_revealed")
	end
	local characterPosition = self._getCharacterPosition(userId)
	if not characterPosition then
		self.stats.rejected += 1
		return Envelope.fail(Envelope.Codes.INVALID_STATE, "no_character")
	end
	local position = self:position(runtime)
	if (characterPosition - position).Magnitude > self._config.eggSpawn.claimRadiusStuds then
		self.stats.rejected += 1
		return Envelope.fail(Envelope.Codes.OUT_OF_RANGE, "egg")
	end
	local next, err = self._rounds:claim(runtime.state.roundId, userId, token)
	if not next then
		self.stats.rejected += 1
		local code = if err == "stale_token"
			then Envelope.Codes.STALE_TOKEN
			elseif err == "already_won" then Envelope.Codes.ALREADY_DONE
			else Envelope.Codes.INVALID_STATE
		return Envelope.fail(code, err)
	end
	self.stats.claims += 1
	self.claimed:Fire(runtime, userId)
	return Envelope.ok({ finderUserId = userId, elapsedMs = next.victory and next.victory.elapsedMs or 0 })
end

return EggService
