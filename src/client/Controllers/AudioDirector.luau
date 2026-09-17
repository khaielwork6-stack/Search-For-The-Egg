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
		_lastPlayed: { [string]: number },
		_lastVariant: { [string]: number },
		_pool: { Sound },
		_manifest: { [string]: string },
		_tuning: { [string]: RoleTuning },
		_volumes: { music: number, sfx: number },
		_trove: Trove.Trove,
	},
	AudioDirector
))

-- Every role's asset id, volume, playback speed, pitch variance, loop flag and cooldown comes from
-- `config.audio`. Nothing about a sound is written in this file any more: adding an owner id, muting
-- a placeholder or retuning a mix is a config edit.
--
-- Two behaviours the config drives that are worth naming:
--   * `group`: roles that share a group share one cooldown. Every ordinary click role shares
--     `uiClick`, so a press that trips two callers is still one click. (Refusals no longer need a
--     group: they all play `ui.error` through UI/Feedback.deny, which holds each reason quiet for
--     five seconds.)
--   * `looped`: a role meant to run while something is happening (the vac motor) rather than fire
--     once. `loop` fades those in, refuses to start a second copy on the same part, and fades out.

type RoleTuning = {
	id: string,
	volume: number,
	speed: number,
	variance: number,
	minGap: number,
	group: string?,
	looped: boolean?,
}

local function audioConfig(config: { [string]: any }): { [string]: any }
	return config.audio
end

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
		_lastPlayed = {},
		_lastVariant = {},
		_pool = {},
		_manifest = {},
		_tuning = {},
		_volumes = { music = 0.7, sfx = 0.85 },
		_trove = Trove.new(),
	}, AudioDirector)

	for _, name in ipairs({ "Music", "Ambience", "SFX", "UI" }) do
		self._buses[name] = self._trove:add(makeBus(name, SoundService))
	end
	local audio = audioConfig(config)
	for role, tuning in pairs(audio.roles) do
		self._manifest[role] = tuning.id
		self._tuning[role] = tuning
	end
	for state, role in pairs(audio.music) do
		local sound = Instance.new("Sound")
		sound.Name = "Music_" .. state
		sound.SoundId = self._manifest[role] or ""
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
	local this = self :: any
	-- A duck in progress keeps its depth against the new setting; its release restores the new value.
	self._buses.Music.Volume = self._volumes.music * (if this._duckDepth then 1 - this._duckDepth else 1)
	self._buses.Ambience.Volume = self._volumes.sfx
	self._buses.SFX.Volume = self._volumes.sfx
	self._buses.UI.Volume = self._volumes.sfx
end

-- Ducks the Music bus for a big moment: down by `depth` (0..1) quickly, held for `seconds`, then back
-- to the player's music volume. Only the Music bus moves; SFX, UI and ambience are untouched, and the
-- player's setting is never rewritten. A duck asked for while one is running extends it (the deeper
-- depth wins) rather than stacking.
function AudioDirector.duck(self: AudioDirector, seconds: number, depth: number?)
	local this = self :: any
	local amount = math.clamp(depth or 0.6, 0, 1)
	local hold = math.max(0, seconds)
	local now = os.clock()
	if this._duckDepth and this._duckUntil and now < this._duckUntil then
		amount = math.max(amount, this._duckDepth)
	end
	this._duckDepth = amount
	this._duckUntil = math.max(this._duckUntil or 0, now + hold)
	this._duckToken = (this._duckToken or 0) + 1
	local token = this._duckToken
	local bus = self._buses.Music
	if this._duckTween then
		this._duckTween:Cancel()
	end
	local down = TweenService:Create(
		bus,
		TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Volume = self._volumes.music * (1 - amount) }
	)
	this._duckTween = down
	down:Play()
	task.delay(this._duckUntil - now, function()
		if this._duckToken ~= token then
			return
		end
		this._duckDepth = nil
		this._duckUntil = nil
		local up = TweenService:Create(
			bus,
			TweenInfo.new(0.7, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
			{ Volume = self._volumes.music }
		)
		this._duckTween = up
		up:Play()
	end)
end

function AudioDirector.isDucked(self: AudioDirector): boolean
	return (self :: any)._duckDepth ~= nil
end

-- Cross-fades music layers; never restarts abruptly.
function AudioDirector.setState(self: AudioDirector, state: MusicState)
	if state == self._state then
		return
	end
	local audio = audioConfig(self._config)
	local fade = TweenInfo.new(audio.musicFadeSeconds, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
	local previous = self._music[self._state]
	for name, sound in pairs(self._music) do
		-- A state whose role has no id (the lobby) fades to silence: music plays in a round only.
		local target = if name == state and sound.SoundId ~= "" then audio.musicVolume else 0
		if target > 0 and not sound.IsPlaying and sound.SoundId ~= "" then
			-- The same loop carries across states: pick it up where the last stem left off.
			if previous and previous ~= sound and previous.IsPlaying and previous.SoundId == sound.SoundId then
				sound.TimePosition = previous.TimePosition
			end
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
	local tuning = self._tuning[role]
	local now = os.clock()
	-- Roles in a group share one cooldown, so a press that trips two click roles still makes exactly
	-- one sound.
	local gate = (tuning and tuning.group) or role
	if tuning and tuning.minGap and tuning.minGap > 0 then
		local last = self._lastPlayed[gate]
		if last and now - last < tuning.minGap then
			return nil
		end
	end
	self._lastPlayed[gate] = now
	local limit = self._config.polishBudgets.maximumConcurrentOneShotSounds
	while #self._oneShots >= limit do
		local oldest = table.remove(self._oneShots, 1) :: Sound
		oldest:Stop()
		table.insert(self._pool, oldest)
	end
	local sound = acquire(self)
	-- A role with variants rotates through them and never plays the same one twice in a row, so a
	-- burst of picks is a handful of similar plucks rather than one sample on repeat.
	local variants = tuning and tuning.variants
	if type(variants) == "table" and #variants > 1 then
		local last = self._lastVariant[role]
		local index = math.random(1, #variants - 1)
		if last and index >= last then
			index += 1
		end
		self._lastVariant[role] = index
		assetId = variants[index]
	end
	sound.SoundId = assetId
	sound.Volume = if tuning and tuning.volume then tuning.volume else 1
	local variance = opts.pitchVariance or (tuning and tuning.variance) or 0
	sound.PlaybackSpeed = ((tuning and tuning.speed) or 1) + variance * (math.random() * 2 - 1)
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

-- A role that runs while something is happening (the vac motor, a station hum) rather than firing
-- once. One sound per role and part: asking twice returns the sound already running instead of
-- stacking a second copy over it. Fades in, and `stopLoop` fades out, so neither end is a click.
function AudioDirector.loop(self: AudioDirector, role: string, at: BasePart): Sound?
	local assetId = self._manifest[role]
	if assetId == nil then
		warn("[SFE][Audio] unknown loop role " .. tostring(role))
		return nil
	end
	local tuning = self._tuning[role]
	-- The running loop is its own registry: one child named for the role under the part it belongs
	-- to. Asking twice finds it and returns it rather than stacking a second copy over it.
	local name = "Loop_" .. role
	local existing = at:FindFirstChild(name)
	if existing and existing:IsA("Sound") then
		return existing
	end
	local audio = audioConfig(self._config)
	local volume = if tuning and tuning.volume then tuning.volume else 0.35
	local sound = Instance.new("Sound")
	sound.Name = name
	sound.SoundId = assetId
	sound.Looped = true
	sound.Volume = 0
	sound.PlaybackSpeed = (tuning and tuning.speed) or 1
	sound.RollOffMaxDistance = 40
	sound.SoundGroup = self._buses.Ambience
	sound.Parent = at
	if assetId ~= "" then
		sound:Play()
		TweenService:Create(sound, TweenInfo.new(audio.loopFadeSeconds, Enum.EasingStyle.Sine), { Volume = volume }):Play()
	end
	self._trove:add(sound)
	return sound
end

function AudioDirector.stopLoop(self: AudioDirector, sound: Sound)
	if not sound.Parent then
		return
	end
	-- Renamed first, so a loop asked for again while this one is fading out starts a fresh sound
	-- instead of finding the dying one.
	sound.Name = "LoopStopping"
	local seconds = audioConfig(self._config).loopFadeSeconds
	if not sound.IsPlaying or sound.Volume <= 0.001 or seconds <= 0 then
		sound:Stop()
		sound:Destroy()
		return
	end
	TweenService:Create(sound, TweenInfo.new(seconds, Enum.EasingStyle.Sine), { Volume = 0 }):Play()
	-- A timer, not the tween's Completed event: a tween that is cancelled or collected before it
	-- finishes never fires it, and the sound would then sit under the tool for the rest of the round.
	-- A silent orphan there is exactly the overlapping copy this is supposed to prevent.
	task.delay(seconds + 0.05, function()
		if sound.Parent then
			sound:Stop()
			sound:Destroy()
		end
	end)
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
