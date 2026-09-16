--!strict
-- Molly the Mole's survey authority. One crate of normal feathers from the paying member buys the
-- party its single reading of the round; the result is shared, lives on the round runtime, and
-- reaches a late joiner in the same snapshot as everything else.
--
-- The deduction and the commit happen in one step with no yield between the last check and the
-- write, so two members pressing at once resolve to one paid scan and one refusal that costs
-- nothing. Rainbow Feathers are never touched.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local RoundReducer = require(Shared.Reducers.RoundReducer)
local ChapterLayout = require(Shared.Domain.ChapterLayout)
local NestSurvey = require(Shared.Domain.NestSurvey)
local Envelope = require(Shared.Net.Envelope)
local Signal = require(Shared.Util.Signal)

local SurveyService = {}
SurveyService.__index = SurveyService

export type SurveyService = typeof(setmetatable(
	{} :: {
		_config: { [string]: any },
		_rounds: any,
		_sessions: any,
		_getCharacterPosition: (userId: number) -> Vector3?,
		_analytics: any?,
		completed: any, -- (runtime, userId, state, projection)
		selected: any, -- (runtime, userId, region?)
		stats: { surveys: number, rejected: number, selections: number },
	},
	SurveyService
))

function SurveyService.new(options: {
	config: { [string]: any },
	rounds: any,
	sessions: any,
	getCharacterPosition: (userId: number) -> Vector3?,
	analytics: any?,
}): SurveyService
	return setmetatable({
		_config = options.config,
		_rounds = options.rounds,
		_sessions = options.sessions,
		_getCharacterPosition = options.getCharacterPosition,
		_analytics = options.analytics,
		completed = Signal.new(),
		selected = Signal.new(),
		stats = { surveys = 0, rejected = 0, selections = 0 },
	}, SurveyService)
end

local function reject(self: SurveyService, code: string, message: string?): Envelope.Envelope<any>
	self.stats.rejected += 1
	return Envelope.fail(code, message)
end

-- The Egg's true region. Server-only: the one place that reads the exact cell.
function SurveyService.eggRegion(_self: SurveyService, runtime: any): string
	local grid = runtime.grid
	return NestSurvey.regionOfCell(grid.width, grid.depth, runtime.eggNode.x, runtime.eggNode.z)
end

function SurveyService.project(_self: SurveyService, runtime: any): { [string]: any }?
	return NestSurvey.project(runtime.survey)
end

-- Everything short of the money: shared by the trade and the live selection relay.
function SurveyService._gate(
	self: SurveyService,
	userId: number,
	token: any,
	options: { trusted: boolean? }?
): (any?, Envelope.Envelope<any>?)
	local runtime = self._rounds:roundOf(userId)
	if not runtime then
		return nil, reject(self, Envelope.Codes.INVALID_STATE, "no_round")
	end
	if not (options and options.trusted) then
		local okToken, tokenErr = self._sessions:validate(userId, token, "Round")
		if not okToken then
			return nil, reject(self, Envelope.Codes.STALE_TOKEN, tokenErr)
		end
	end
	if not table.find(runtime.state.members, userId) then
		return nil, reject(self, Envelope.Codes.NOT_AUTHORIZED, "not_member")
	end
	if runtime.state.phase == "EggRevealed" or runtime.eggCarrier ~= nil then
		return nil, reject(self, Envelope.Codes.INVALID_STATE, "egg_found")
	end
	if not RoundReducer.acceptsGameplay(runtime.state) then
		return nil, reject(self, Envelope.Codes.INVALID_STATE, "phase")
	end
	local state = runtime.players[userId]
	if not state or not state.alive then
		return nil, reject(self, Envelope.Codes.INVALID_STATE, "not_alive")
	end
	return runtime, nil
end

-- The live pick, relayed to the party so members at the station see the tile and the drill move.
-- `payload` = { sessionToken, region? } (nil region = cleared).
function SurveyService.select(self: SurveyService, userId: number, payload: { [string]: any }): Envelope.Envelope<any>
	local runtime, refused = self:_gate(userId, payload.sessionToken)
	if not runtime then
		return refused :: Envelope.Envelope<any>
	end
	if payload.region ~= nil and not NestSurvey.isRegion(payload.region) then
		return reject(self, Envelope.Codes.INVALID_PAYLOAD, "region")
	end
	if runtime.survey then
		return reject(self, Envelope.Codes.ALREADY_DONE, "already_surveyed")
	end
	self.stats.selections += 1
	self.selected:Fire(runtime, userId, payload.region)
	return Envelope.ok({ region = payload.region })
end

-- The scan. `payload` = { sessionToken, region }. `options.trusted` / `characterPosition` are the
-- same server-caller seams ClueService has; remote requests never set them.
function SurveyService.survey(
	self: SurveyService,
	userId: number,
	payload: { [string]: any },
	options: { trusted: boolean?, characterPosition: Vector3? }?
): Envelope.Envelope<any>
	local runtime, refused = self:_gate(userId, payload.sessionToken, options)
	if not runtime then
		return refused :: Envelope.Envelope<any>
	end
	local region = payload.region
	if not NestSurvey.isRegion(region) then
		return reject(self, Envelope.Codes.INVALID_PAYLOAD, "region")
	end
	if runtime.survey then
		return reject(self, Envelope.Codes.ALREADY_DONE, "already_surveyed")
	end
	local cost = NestSurvey.crateCost(self._config)
	local state = runtime.players[userId]
	if state.carriedStandard < cost then
		return reject(self, Envelope.Codes.INSUFFICIENT_FUNDS, "insufficient")
	end
	local characterPosition = (options and options.characterPosition) or self._getCharacterPosition(userId)
	if not characterPosition then
		return reject(self, Envelope.Codes.INVALID_STATE, "no_character")
	end
	local layout = ChapterLayout[runtime.state.chapter]
	local station = layout.surveyStation
	local flat = Vector3.new(characterPosition.X - station.X, 0, characterPosition.Z - station.Z)
	if flat.Magnitude > self._config.survey.stationRangeStuds then
		return reject(self, Envelope.Codes.OUT_OF_RANGE, "station")
	end
	-- One transaction: the crate leaves the bag and the reading is committed together. Normal
	-- feathers only; the rainbow count is not read.
	local signal = NestSurvey.signal(self._config, region, self:eggRegion(runtime))
	state.carriedStandard -= cost
	runtime.survey = { region = region, signal = signal, byUserId = userId }
	self.stats.surveys += 1
	if self._analytics then
		self._analytics:track("survey_completed", {
			chapter = runtime.state.chapter,
			difficulty = runtime.state.difficulty,
			region = region,
			signal = signal,
			cost = cost,
		})
	end
	local projection = self:project(runtime)
	self.completed:Fire(runtime, userId, runtime.survey, projection)
	return Envelope.ok({
		region = region,
		signal = signal,
		title = (projection :: any).title,
		text = (projection :: any).text,
		cost = cost,
		carriedStandard = state.carriedStandard,
		survey = projection,
	})
end

return SurveyService
