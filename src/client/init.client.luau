--!strict
-- Client bootstrap. Waits for the server-published config projection and runtime folder, then
-- starts controllers in dependency order. Controllers only ever receive sanitized projections.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Trove = require(Shared.Util.Trove)

local Controllers = script:WaitForChild("Controllers")
local NetClient = require(Controllers.NetClient)
local ProfileController = require(Controllers.ProfileController)
local AccessibilityController = require(Controllers.AccessibilityController)
local QualityController = require(Controllers.QualityController)
local InputController = require(Controllers.InputController)
local ModalController = require(Controllers.ModalController)
local AudioDirector = require(Controllers.AudioDirector)
local VFXDirector = require(Controllers.VFXDirector)
local AmbientScheduler = require(Controllers.AmbientScheduler)
local CameraFeedback = require(Controllers.CameraFeedback)
local HapticsController = require(Controllers.HapticsController)
local HUDController = require(Controllers.HUDController)
local LobbyShellController = require(Controllers.LobbyShellController)

local player = Players.LocalPlayer
local bootStarted = os.clock()

local runtime = ReplicatedStorage:WaitForChild(Config.RUNTIME_FOLDER_NAME, 60)
if not runtime then
	warn("[SFE][Client] server runtime folder never appeared; aborting bootstrap")
	return
end

local config = Config.get()
local trove = Trove.new()

-- Order: net -> profile -> settings-derived (accessibility/quality) -> input/modal -> presentation.
local net = trove:add(NetClient.new(runtime, config))
local profile = trove:add(ProfileController.new(net))
local accessibility = trove:add(AccessibilityController.new(profile, config))
local quality = trove:add(QualityController.new(profile, config))
local input = trove:add(InputController.new())
local modals = trove:add(ModalController.new(input, accessibility, config))
local audio = trove:add(AudioDirector.new(profile, config))
local vfx = trove:add(VFXDirector.new(quality, config))
local ambient = trove:add(AmbientScheduler.new(quality, accessibility))
local camera = trove:add(CameraFeedback.new(accessibility, config))
local haptics = trove:add(HapticsController.new(accessibility))
local hud = trove:add(HUDController.new({
	net = net,
	profile = profile,
	modals = modals,
	input = input,
	accessibility = accessibility,
	quality = quality,
	audio = audio,
	config = config,
}))
local lobby = trove:add(LobbyShellController.new({
	ambient = ambient,
	vfx = vfx,
	quality = quality,
	camera = camera,
	haptics = haptics,
	audio = audio,
	config = config,
}))

audio:setState("Lobby")
lobby:start()

-- Diagnostics for Studio verification: instance/connection snapshots and an exposed container.
local container = {
	config = config,
	net = net,
	profile = profile,
	accessibility = accessibility,
	quality = quality,
	input = input,
	modals = modals,
	audio = audio,
	vfx = vfx,
	ambient = ambient,
	camera = camera,
	haptics = haptics,
	hud = hud,
	lobby = lobby,
	trove = trove,
	snapshot = function()
		return {
			ambientActors = ambient:actorCount(),
			ambientConnections = ambient:connectionCount(),
			vfxPooled = vfx:pooledCount(),
			vfxActive = vfx:activeCount(),
			audioActiveOneShots = audio:activeOneShotCount(),
			modalsOpen = modals:openCount(),
			qualityTier = quality:tier(),
			reducedMotion = accessibility:reducedMotion(),
			inputMode = input:mode(),
		}
	end,
}
if game:GetService("RunService"):IsStudio() then
	-- selene: allow(global_usage)
	shared.SFE_Client = container
	-- Bridge for the Studio MCP / command bar (separate VM): PlayerScripts.SFE_ClientDebug:Invoke(name)
	local HttpService = game:GetService("HttpService")
	local bridge = Instance.new("BindableFunction")
	bridge.Name = "SFE_ClientDebug"
	local actions: { [string]: (...any) -> any } = {
		snapshot = function()
			local snap: any = container.snapshot()
			snap.profileLoaded = profile.projection ~= nil
			snap.sessionPhase = profile.session and profile.session.phase or nil
			snap.gemsChip = hud._labels.gems.Text
			snap.banner = hud._labels.banner.Text
			snap.prompt = hud._labels.prompt.Text
			snap.layoutClass = hud.gui:GetAttribute("SFE_LayoutClass")
			snap.viewport = tostring(workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize)
			snap.strands = lobby:strandCount()
			snap.audioState = audio:state()
			snap.vfxInstances = vfx:instanceCount()
			snap.vfxStats = vfx.stats
			snap.ambientStats = ambient.stats
			return snap
		end,
		openSettings = function()
			return hud:openSettings()
		end,
		closeSettings = function()
			return modals:close("settings")
		end,
		stopLobby = function()
			lobby:stop()
			return lobby:strandCount()
		end,
		startLobby = function()
			lobby:start()
			return lobby:strandCount()
		end,
		playSound = function(role)
			audio:play(role or "ui.tap")
			return audio:activeOneShotCount()
		end,
		cameraImpulse = function(strength)
			camera:impulse(tonumber(strength) or 0.5)
			return camera:isActive()
		end,
	}
	bridge.OnInvoke = function(name: string, ...)
		local action = actions[name]
		if not action then
			return HttpService:JSONEncode({ error = "unknown_action", name = name })
		end
		local ok, result = pcall(action, ...)
		return HttpService:JSONEncode(if ok then result else { error = tostring(result) })
	end
	bridge.Parent = player:WaitForChild("PlayerScripts")
end

player:SetAttribute("SFE_ClientReady", true)
print(
	string.format(
		"[SFE][Client] ready in %d ms (build %s)",
		math.floor((os.clock() - bootStarted) * 1000),
		tostring(runtime:GetAttribute("SFE_BuildLabel"))
	)
)
