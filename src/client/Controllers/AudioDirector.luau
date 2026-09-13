--!strict
-- Audio buses (Music / Ambience / SFX / UI as SoundGroups), a state-driven music layer with
-- cross-fades, one-shot concurrency limits, and settings that apply immediately.
-- PLACEHOLDER: the manifest maps semantic sound roles to stand-in asset ids (owner: Phase 6 audio
-- pass). Sounds with no asset resolve to a silent stub so the pipeline still exercises pooling.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local Shared = ReplicatedStorage.Shared
local Trove = require(Shared.Util.Trove)
local Tokens = require(Shared.Design.Tokens)

local AudioDirector = {}
AudioDirector.__index = AudioDirector

export type MusicState = "Lobby" | "Search" | "Discovery" | "Victory" | "Results" | "Silent"

export type AudioDirector = typeof(setmetatable(
	{} :: {
		_config: { [string]: any },
		_buses: { [string]: SoundGroup },
		_music: { [string]: Sound },
		_state: MusicState,
		_oneShots: { Sound },
		_pool: { Sound },
		_manifest: { [string]: string },
		_volumes: { music: number, sfx: number },
		_trove: Trove.Trove,
	},
	AudioDirector
))

-- Semantic role -> asset id. Empty string = silent stub. PLACEHOLDER (Phase 6).
local MANIFEST: { [string]: string } = {
	[Tokens.sound.uiTap] = "",
	[Tokens.sound.uiConfirm] = "",
	[Tokens.sound.uiCancel] = "",
	[Tokens.sound.uiOpen] = "",
	[Tokens.sound.uiClose] = "",
	[Tokens.sound.uiToast] = "",
	[Tokens.sound.uiError] = "",
	[Tokens.sound.rewardTick] = "",
	[Tokens.sound.collectTug] = "",
	[Tokens.sound.collectRelease] = "",
	[Tokens.sound.bagFull] = "",
	[Tokens.sound.sellArc] = "",
	[Tokens.sound.sellTick] = "",
	[Tokens.sound.sellBurst] = "",
	[Tokens.sound.upgradeChord] = "",
	[Tokens.sound.eggChime] = "",
	[Tokens.sound.eggClaimHold] = "",
	[Tokens.sound.victoryStem] = "",
	[Tokens.sound.countdownTick] = "",
	[Tokens.sound.countdownGo] = "",
	[Tokens.sound.rewardLand] = "",
	[Tokens.sound.rollSpin] = "",
	[Tokens.sound.rollLand] = "",
	[Tokens.sound.stationHum] = "",
	[Tokens.sound.stationChime] = "",
	[Tokens.sound.partyReady] = "",
	["music.lobby"] = "",
	["music.search"] = "",
	["music.discovery"] = "",
	["music.victory"] = "",
	["music.results"] = "",
	["ambience.henhouse"] = "",
}

local MUSIC_STATES: { [string]: string } =
	{ Lobby = "music.lobby", Search = "music.search", Discovery = "music.discovery", Victory = "music.victory", Results = "music.results" }

local function makeBus(name: string, parent: Instance): SoundGroup
	local group = Instance.new("SoundGroup")
	group.Name = "SFE_" .. name
	group.Volume = 1
	group.Parent = parent
	return group
end

function AudioDirector.new(profile: any, config: { [string]: any }): AudioDirector
	local self = setmetatable({
		_config = config,
		_buses = {},
		_music = {},
		_state = "Silent" :: MusicState,
		_oneShots = {},
		_pool = {},
		_manifest = MANIFEST,
		_volumes = { music = 0.7, sfx = 0.85 },
		_trove = Trove.new(),
	}, AudioDirector)

	for _, name in ipairs({ "Music", "Ambience", "SFX", "UI" }) do
		self._buses[name] = self._trove:add(makeBus(name, SoundService))
	end
	for state, role in pairs(MUSIC_STATES) do
		local sound = Instance.new("Sound")
		sound.Name = "Music_" .. state
		sound.SoundId = if self._manifest[role] ~= "" then self._manifest[role] else ""
		sound.Looped = true
		sound.Volume = 0
		sound.SoundGroup = self._buses.Music
		sound.Parent = self._buses.Music
		self._music[state] = self._trove:add(sound)
	end

	local function applySettings(projection)
		local settings = projection and projection.settings
		if settings then
			self:setVolumes(settings.musicVolume, settings.sfxVolume)
		end
	end
	applySettings(profile.projection)
	self._trove:add(profile.changed:Connect(applySettings))
	return self
end

function AudioDirector.setVolumes(self: AudioDirector, music: number, sfx: number)
	self._volumes = { music = math.clamp(music, 0, 1), sfx = math.clamp(sfx, 0, 1) }
	self._buses.Music.Volume = self._volumes.music
	self._buses.Ambience.Volume = self._volumes.sfx
	self._buses.SFX.Volume = self._volumes.sfx
	self._buses.UI.Volume = self._volumes.sfx
end

-- Cross-fades music layers; never restarts abruptly.
function AudioDirector.setState(self: AudioDirector, state: MusicState)
	if state == self._state then
		return
	end
	local fade = TweenInfo.new(Tokens.motion.slow * 3, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
	for name, sound in pairs(self._music) do
		local target = if name == state then 1 else 0
		if target == 1 and not sound.IsPlaying and sound.SoundId ~= "" then
			sound:Play()
		end
		local tween = TweenService:Create(sound, fade, { Volume = target })
		tween:Play()
		if target == 0 then
			tween.Completed:Once(function()
				if sound.Volume == 0 and sound.IsPlaying then
					sound:Stop()
				end
			end)
		end
	end
	self._state = state
end

function AudioDirector.state(self: AudioDirector): MusicState
	return self._state
end

local function acquire(self: AudioDirector): Sound
	local sound = table.remove(self._pool)
	if not sound then
		sound = Instance.new("Sound")
		sound.Name = "OneShot"
		self._trove:add(sound)
	end
	return sound :: Sound
end

-- Plays a semantic sound role. UI roles are non-positional (bus UI); world roles are positional
-- when `at` is provided. Respects the configured concurrency cap by dropping the oldest.
function AudioDirector.play(self: AudioDirector, role: string, options: { at: BasePart?, pitchVariance: number?, bus: string? }?): Sound?
	local opts = (options or {}) :: any
	local assetId = self._manifest[role]
	if assetId == nil then
		warn("[SFE][Audio] unknown sound role " .. tostring(role))
		return nil
	end
	local limit = self._config.polishBudgets.maximumConcurrentOneShotSounds
	while #self._oneShots >= limit do
		local oldest = table.remove(self._oneShots, 1) :: Sound
		oldest:Stop()
		table.insert(self._pool, oldest)
	end
	local sound = acquire(self)
	sound.SoundId = assetId
	sound.Volume = 1
	sound.PlaybackSpeed = 1 + (opts.pitchVariance or 0) * (math.random() * 2 - 1)
	local busName = opts.bus or (if string.sub(role, 1, 3) == "ui." then "UI" else "SFX")
	sound.SoundGroup = self._buses[busName]
	sound.Parent = opts.at or self._buses[busName]
	table.insert(self._oneShots, sound)
	local function release()
		local index = table.find(self._oneShots, sound)
		if index then
			table.remove(self._oneShots, index)
		end
		sound.Parent = nil
		table.insert(self._pool, sound)
	end
	if assetId == "" then
		-- Silent stub: exercise the pool without playing.
		task.defer(release)
	else
		sound:Play()
		sound.Ended:Once(release)
	end
	return sound
end

-- Looped positional ambience (station hums). Bounded by the caller through the quality budget;
-- silent stubs still create the Sound so the loop pipeline is exercised. Returns the Sound.
function AudioDirector.loop(self: AudioDirector, role: string, at: BasePart): Sound?
	local assetId = self._manifest[role]
	if assetId == nil then
		warn("[SFE][Audio] unknown loop role " .. tostring(role))
		return nil
	end
	local sound = Instance.new("Sound")
	sound.Name = "Loop_" .. role
	sound.SoundId = assetId
	sound.Looped = true
	sound.Volume = 0.35
	sound.RollOffMaxDistance = 40
	sound.SoundGroup = self._buses.Ambience
	sound.Parent = at
	if assetId ~= "" then
		sound:Play()
	end
	self._trove:add(sound)
	return sound
end

function AudioDirector.stopLoop(_self: AudioDirector, sound: Sound)
	sound:Stop()
	sound:Destroy()
end

function AudioDirector.activeOneShotCount(self: AudioDirector): number
	return #self._oneShots
end

function AudioDirector.pooledCount(self: AudioDirector): number
	return #self._pool
end

function AudioDirector.destroy(self: AudioDirector)
	self._trove:destroy()
end

return AudioDirector
