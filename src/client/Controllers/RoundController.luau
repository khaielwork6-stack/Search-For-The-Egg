--!strict
-- Client round state: receives RoundSnapshot / RoundDelta / SaleResult / UpgradeResult / EggRevealed /
-- VictoryStarted / ResultsProjection, keeps the latest sanitized projection, derives the display
-- timer from the server start timestamp, owns the cutscene/countdown overlay, and toggles the
-- first-person camera for rounds. Other controllers subscribe to its signals.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local Signal = require(Shared.Util.Signal)
local Trove = require(Shared.Util.Trove)
local Tokens = require(Shared.Design.Tokens)
local Motion = require(Shared.Design.Motion)

local RoundController = {}
RoundController.__index = RoundController

export type RoundController = typeof(setmetatable(
	{} :: {
		_net: any,
		_profile: any,
		_modals: any,
		_accessibility: any,
		_audio: any,
		_config: { [string]: any },
		round: { [string]: any }?,
		player: { [string]: any }?,
		pile: { [string]: any }?,
		previews: { any }?,
		eggPosition: Vector3?,
		_receivedAt: number,
		phaseChanged: any,
		snapshot: any,
		delta: any,
		playerChanged: any,
		sale: any,
		saleRefused: any,
		upgrade: any,
		eggRevealed: any,
		victory: any,
		results: any,
		_trove: Trove.Trove,
	},
	RoundController
))

function RoundController.new(
	deps: { net: any, profile: any, modals: any, accessibility: any, audio: any, config: { [string]: any } }
): RoundController
	local self = setmetatable({
		_net = deps.net,
		_profile = deps.profile,
		_modals = deps.modals,
		_accessibility = deps.accessibility,
		_audio = deps.audio,
		_config = deps.config,
		round = nil,
		player = nil,
		pile = nil,
		previews = nil,
		eggPosition = nil,
		_receivedAt = 0,
		phaseChanged = Signal.new(),
		snapshot = Signal.new(),
		delta = Signal.new(),
		playerChanged = Signal.new(),
		sale = Signal.new(),
		saleRefused = Signal.new(),
		upgrade = Signal.new(),
		eggRevealed = Signal.new(),
		victory = Signal.new(),
		results = Signal.new(),
		_trove = Trove.new(),
	}, RoundController)

	self._trove:add(deps.net:on("RoundSnapshot", function(payload)
		self:_onSnapshot(payload)
	end))
	self._trove:add(deps.net:on("RoundDelta", function(payload)
		if payload.player then
			self.player = payload.player
			self.playerChanged:Fire(payload.player)
		end
		if payload.cells and #payload.cells > 0 then
			self.delta:Fire(payload)
		end
	end))
	self._trove:add(deps.net:on("SaleResult", function(payload)
		if payload.ok == false then
			self.saleRefused:Fire(payload)
			return
		end
		if payload.player then
			self.player = payload.player
			self.playerChanged:Fire(payload.player)
		end
		self.sale:Fire(payload)
	end))
	self._trove:add(deps.net:on("UpgradeResult", function(payload)
		if payload.previews then
			self.previews = payload.previews
		end
		if payload.player then
			self.player = payload.player
			self.playerChanged:Fire(payload.player)
		end
		self.upgrade:Fire(payload)
	end))
	self._trove:add(deps.net:on("EggRevealed", function(payload)
		self.eggPosition = Vector3.new(payload.x, payload.y, payload.z)
		self.eggRevealed:Fire(payload)
	end))
	self._trove:add(deps.net:on("VictoryStarted", function(payload)
		self.victory:Fire(payload)
	end))
	self._trove:add(deps.net:on("ResultsProjection", function(payload)
		self.results:Fire(payload)
	end))
	return self
end

function RoundController._onSnapshot(self: RoundController, payload: { [string]: any })
	local previousPhase = self.round and self.round.phase or nil
	self.round = payload
	self._receivedAt = os.clock()
	if payload.pile then
		self.pile = payload.pile
	end
	if payload.player then
		self.player = payload.player
		self.playerChanged:Fire(payload.player)
	end
	self.snapshot:Fire(payload)
	if payload.phase ~= previousPhase then
		self:_applyPhase(payload.phase, previousPhase)
		self.phaseChanged:Fire(payload.phase, previousPhase)
	end
end

function RoundController._applyPhase(self: RoundController, phase: string, previous: string?)
	-- First person only while the search itself runs; the lobby, cutscene and post-round screens
	-- keep a free camera and cursor (owner requirement, 13 Sep 2026).
	self._modals:setFirstPerson(phase == "Countdown" or phase == "Searching" or phase == "EggRevealed")
	if phase == "Cutscene" then
		-- The round intro owns this phase: it takes the camera, the HUD and the cursor itself, and it
		-- starts the round music when it hands back. Starting the music here would put it under the
		-- cinematic instead of behind the round.
		self.eggPosition = nil
	elseif phase == "Countdown" then
		self._modals:setExternalUnlock(false)
		-- The intro normally restores this itself; setting it again here covers a round that left the
		-- intro phase while a client was still mid-shot.
		self._audio:setState("Search")
	elseif phase == "Searching" then
		self._modals:setExternalUnlock(false)
		if previous == "Countdown" then
			self._audio:play(Tokens.sound.countdownGo)
		end
	elseif phase == "EggRevealed" then
		self._audio:setState("Discovery")
	elseif phase == "Victory" then
		self._audio:setState("Victory")
	elseif phase == "Results" then
		self._audio:setState("Results")
	elseif phase == "Returning" or phase == "Abandoned" then
		self._modals:setExternalUnlock(false)
		self._audio:setState("Lobby")
		self.round = nil
		self.pile = nil
		self.player = nil
		self.previews = nil
		self.eggPosition = nil
	end
end

function RoundController.inRound(self: RoundController): boolean
	local round = self.round
	return round ~= nil and round.phase ~= "Returning" and round.phase ~= "Abandoned"
end

function RoundController.phase(self: RoundController): string?
	return self.round and self.round.phase or nil
end

-- Authoritative elapsed milliseconds, extrapolated locally from the server timestamps.
function RoundController.elapsedMs(self: RoundController): number
	local round = self.round
	if not round or not round.searchingStartedAtMs then
		return 0
	end
	local base = (round.serverNowMs or round.searchingStartedAtMs) - round.searchingStartedAtMs
	if round.phase == "Searching" or round.phase == "EggRevealed" then
		return base + math.floor((os.clock() - self._receivedAt) * 1000)
	end
	return round.elapsedMs or base
end

-- Countdown seconds remaining (Countdown phase), derived from the server deadline projection.
function RoundController.countdownRemaining(self: RoundController): number?
	local round = self.round
	if not round or round.phase ~= "Countdown" then
		return nil
	end
	-- A read, not an event: no per-second tick sound (owner 17 Sep 2026). The Searching phase still
	-- opens on the round-start sound in _applyPhase.
	local remaining = (round.countdownSeconds or 0) - (os.clock() - self._receivedAt)
	return math.max(0, remaining)
end

function RoundController.sessionToken(self: RoundController): string?
	local session = self._profile.session
	return session and session.sessionToken or nil
end

function RoundController.destroy(self: RoundController)
	self._trove:destroy()
	for _, signal in ipairs({
		self.phaseChanged,
		self.snapshot,
		self.delta,
		self.playerChanged,
		self.sale,
		self.upgrade,
		self.eggRevealed,
		self.victory,
		self.results,
	}) do
		signal:Destroy()
	end
end

RoundController.formatTime = function(ms: number): string
	local totalSeconds = math.floor(ms / 1000)
	local minutes = math.floor(totalSeconds / 60)
	local seconds = totalSeconds % 60
	local hundredths = math.floor((ms % 1000) / 10)
	return string.format("%02d:%02d.%02d", minutes, seconds, hundredths)
end

RoundController.Motion = Motion

return RoundController
