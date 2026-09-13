--!strict
-- Moonlit Cellar (Chapter 2) round authority: owns one shared puzzle machine per Chapter 2 round
-- (STATE_MACHINES 11). The solution is generated on the server from the validated sets, never
-- projected, and lives only in the round runtime. Any party member may act; every input is
-- validated (round, token, phase, range to the interactable) and applied atomically through the
-- pure CellarPuzzles machine, so concurrent inputs can never corrupt or duplicate progress. When the
-- last stage opens the Egg is revealed at the ladder and the common victory pipeline takes over.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local CellarPuzzles = require(Shared.Domain.CellarPuzzles)
local ChapterLayout = require(Shared.Domain.ChapterLayout)
local RoundReducer = require(Shared.Reducers.RoundReducer)
local Envelope = require(Shared.Net.Envelope)
local Signal = require(Shared.Util.Signal)

local CellarService = {}
CellarService.__index = CellarService

export type CellarService = typeof(setmetatable(
	{} :: {
		_config: { [string]: any },
		_rounds: any,
		_sessions: any,
		_clock: any,
		_rng: any,
		_egg: any,
		_getCharacterPosition: (userId: number) -> Vector3?,
		_getProfile: ((userId: number) -> any?)?,
		_analytics: any,
		_log: any,
		created: any, -- (runtime, worldSpec)
		changed: any, -- (runtime, projection, event)
		stats: { rounds: number, inputs: number, rejected: number, stagesSolved: number, resets: number },
	},
	CellarService
))

CellarService.CHAPTER = "chapter2"

function CellarService.new(options: {
	config: { [string]: any },
	rounds: any,
	sessions: any,
	clock: any,
	rng: any,
	egg: any,
	getCharacterPosition: (userId: number) -> Vector3?,
	getProfile: ((userId: number) -> any?)?,
	analytics: any?,
	log: any?,
}): CellarService
	local self = setmetatable({
		_config = options.config,
		_rounds = options.rounds,
		_sessions = options.sessions,
		_clock = options.clock,
		_rng = options.rng,
		_egg = options.egg,
		_getCharacterPosition = options.getCharacterPosition,
		_getProfile = options.getProfile,
		_analytics = options.analytics,
		_log = options.log,
		created = Signal.new(),
		changed = Signal.new(),
		stats = { rounds = 0, inputs = 0, rejected = 0, stagesSolved = 0, resets = 0 },
	}, CellarService)
	-- The mound hides the key in this chapter: uncovering it reveals the key, not the Egg.
	options.egg:setUncoverHook(function(runtime, position)
		return self:_onUncovered(runtime, position)
	end)
	return self
end

local function reject(self: CellarService, code: string, message: string?): Envelope.Envelope<any>
	self.stats.rejected += 1
	return Envelope.fail(code, message)
end

function CellarService.isCellarRound(runtime: any): boolean
	return runtime ~= nil and runtime.state.chapter == CellarService.CHAPTER and runtime.cellar ~= nil
end

-- Attaches a fresh puzzle machine to a Chapter 2 round (called from the round-created path).
function CellarService.attach(self: CellarService, runtime: any): { [string]: any }?
	if runtime.state.chapter ~= CellarService.CHAPTER or runtime.cellar then
		return nil
	end
	local solution = CellarPuzzles.generate(self._config, self._rng)
	runtime.cellar = {
		solution = solution,
		state = CellarPuzzles.newState(self._config, solution),
		keyPosition = nil,
		spec = CellarPuzzles.worldSpec(self._config, solution),
	}
	self.stats.rounds += 1
	self.created:Fire(runtime, runtime.cellar.spec)
	return runtime.cellar.spec
end

function CellarService.project(self: CellarService, runtime: any): { [string]: any }?
	if not CellarService.isCellarRound(runtime) then
		return nil
	end
	local projection = CellarPuzzles.project(self._config, runtime.cellar.state)
	local keyPosition = runtime.cellar.keyPosition
	if keyPosition and projection.key.revealed and not projection.key.held then
		projection.key.x, projection.key.y, projection.key.z = keyPosition.X, keyPosition.Y, keyPosition.Z
	end
	return projection
end

function CellarService.stage(self: CellarService, runtime: any): string?
	if not CellarService.isCellarRound(runtime) then
		return nil
	end
	return CellarPuzzles.currentStage(self._config, runtime.cellar.state)
end

-- Server-only (debug/evidence): the round's solution. Never reachable from a remote.
function CellarService.solution(_self: CellarService, runtime: any): CellarPuzzles.Solution?
	return if CellarService.isCellarRound(runtime) then runtime.cellar.solution else nil
end

function CellarService._onUncovered(self: CellarService, runtime: any, position: Vector3): boolean
	if not CellarService.isCellarRound(runtime) then
		return false
	end
	local cellar = runtime.cellar
	if CellarPuzzles.currentStage(self._config, cellar.state) ~= "findKey" or cellar.state.key.revealed then
		return true -- already handled; the mound never reveals the Egg in this chapter
	end
	cellar.state = CellarPuzzles.revealKey(cellar.state)
	cellar.keyPosition = position
	self:_track(runtime, "puzzle_step", { stage = "findKey", event = "key_revealed" })
	self.changed:Fire(runtime, self:project(runtime), { kind = "key_revealed", x = position.X, y = position.Y, z = position.Z })
	return true
end

-- World anchor a given action must be performed near (range check), or nil for actions without one.
function CellarService.anchorFor(_self: CellarService, layout: any, runtime: any, action: { [string]: any }): Vector3?
	local kind = action.kind
	if kind == "pickupKey" then
		return runtime.cellar.keyPosition
	elseif kind == "lever" then
		local index = action.index
		return if type(index) == "number" then layout.levers[index] else nil
	elseif kind == "crystals" then
		return layout.crystalDial
	elseif kind == "code" then
		return layout.codeDoor
	elseif kind == "tile" then
		return layout.tileWall
	elseif kind == "release" then
		return layout.cage
	elseif kind == "reset" then
		return nil
	end
	return nil
end

function CellarService._track(self: CellarService, runtime: any, event: string, props: { [string]: any }, userId: number?)
	if self._analytics then
		local payload = table.clone(props)
		payload.chapter = runtime.state.chapter
		payload.difficulty = runtime.state.difficulty
		self._analytics:track(event, payload, userId)
	end
end

-- Handles a PuzzleAction request. Returns the envelope with the machine result and projection.
function CellarService.action(self: CellarService, userId: number, payload: { [string]: any }): Envelope.Envelope<any>
	self.stats.inputs += 1
	local runtime = self._rounds:roundOf(userId)
	if not runtime then
		return reject(self, Envelope.Codes.INVALID_STATE, "no_round")
	end
	if not CellarService.isCellarRound(runtime) then
		return reject(self, Envelope.Codes.INVALID_STATE, "not_cellar")
	end
	local okToken, tokenErr = self._sessions:validate(userId, payload.sessionToken, "Round")
	if not okToken then
		return reject(self, Envelope.Codes.STALE_TOKEN, tokenErr)
	end
	if not RoundReducer.acceptsGameplay(runtime.state) then
		return reject(self, Envelope.Codes.INVALID_STATE, "phase")
	end
	local playerState = runtime.players[userId]
	if not playerState or not playerState.alive then
		return reject(self, Envelope.Codes.INVALID_STATE, "not_alive")
	end
	local layout = ChapterLayout[runtime.state.chapter]
	local anchor = self:anchorFor(layout, runtime, payload)
	if anchor then
		local characterPosition = self._getCharacterPosition(userId)
		if not characterPosition then
			return reject(self, Envelope.Codes.INVALID_STATE, "no_character")
		end
		local flat = Vector3.new(characterPosition.X - anchor.X, 0, characterPosition.Z - anchor.Z)
		if flat.Magnitude > self._config.lobby.stationPromptRangeStuds + self._config.interaction.serverPositionToleranceStuds then
			return reject(self, Envelope.Codes.OUT_OF_RANGE, "puzzle")
		end
	end

	local cellar = runtime.cellar
	local nowMs = self._clock:nowMs()
	local nextState, res = CellarPuzzles.apply(self._config, cellar.state, cellar.solution, payload, userId, nowMs)
	local changed = nextState ~= cellar.state
	cellar.state = nextState
	if res.code == "reset" then
		self.stats.resets += 1
	end
	self:_track(runtime, "puzzle_input", { stage = res.stage, kind = payload.kind, ok = res.ok, code = res.code }, userId)
	if res.solvedStage then
		self.stats.stagesSolved += 1
		self:_track(runtime, "puzzle_step", { stage = res.solvedStage, event = "solved", next = res.stage }, userId)
		local profile = if self._getProfile then self._getProfile(userId) else nil
		if profile then
			profile:update(function(data)
				data.stats.puzzlesSolved += 1
			end)
		end
	end
	local projection = self:project(runtime)
	if changed then
		self.changed:Fire(runtime, projection, {
			kind = if res.solvedStage then "stage_solved" else "progress",
			stage = res.stage,
			solvedStage = res.solvedStage,
			feedback = res.feedback,
			userId = userId,
		})
	end
	if res.advanced and res.stage == "exit" then
		-- The barrier is down: the Egg appears at the ladder and the shared victory pipeline runs.
		self._egg:revealNow(runtime)
	end
	local data = {
		ok = res.ok,
		code = res.code,
		message = res.message,
		feedback = res.feedback,
		stage = res.stage,
		advanced = res.advanced,
		solvedStage = res.solvedStage,
		extra = res.extra,
		projection = projection,
	}
	if res.ok then
		return Envelope.ok(data)
	end
	local code = if res.code == "not_yet" or res.code == "already_done"
		then Envelope.Codes.INVALID_STATE
		elseif res.code == "invalid" then Envelope.Codes.INVALID_PAYLOAD
		else Envelope.Codes.OK
	-- A wrong answer is a valid, acknowledged input (feedback travels in data), not a protocol error.
	if res.code == "wrong" then
		self.stats.rejected -= 0
		return Envelope.ok(data)
	end
	return reject(self, code, res.code)
end

return CellarService
