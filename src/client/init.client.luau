--!strict
-- Client bootstrap. Waits for the server-published config projection and runtime folder, then
-- starts controllers in dependency order. Controllers only ever receive sanitized projections.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Trove = require(Shared.Util.Trove)
local AssetManifest = require(Shared.Design.AssetManifest)

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
local RoundController = require(Controllers.RoundController)
local PileVisualController = require(Controllers.PileVisualController)
local CrateController = require(Controllers.CrateController)
local ToolController = require(Controllers.ToolController)
local ToolVisualController = require(Controllers.ToolVisualController)
local ToolViewmodelController = require(Controllers.ToolViewmodelController)
local DialogueController = require(Controllers.DialogueController)
local InteractionController = require(Controllers.InteractionController)
local DisplayController = require(Controllers.DisplayController)
local NameplateController = require(Controllers.NameplateController)
local InspectController = require(Controllers.InspectController)
local UpgradeBookController = require(Controllers.UpgradeBookController)
local PromptController = require(Controllers.PromptController)
local ObjectiveController = require(Controllers.ObjectiveController)
local VictoryController = require(Controllers.VictoryController)
local PartyController = require(Controllers.PartyController)
local LobbyController = require(Controllers.LobbyController)

local player = Players.LocalPlayer
local bootStarted = os.clock()

local runtime = ReplicatedStorage:WaitForChild(Config.RUNTIME_FOLDER_NAME, 60)
if not runtime then
	warn("[SFE][Client] server runtime folder never appeared; aborting bootstrap")
	return
end

local config = Config.get()
local trove = Trove.new()
-- Mesh templates must carry their mesh metadata before anything clones them (AssetManifest.warm).
local repairedMeshes = AssetManifest.warm()

-- Order: net -> profile -> settings-derived (accessibility/quality) -> input/modal -> presentation
-- foundations -> HUD -> round/gameplay controllers -> scene ambience.
local net = trove:add(NetClient.new(runtime, config))
local profile = trove:add(ProfileController.new(net))
local party = trove:add(PartyController.new({ net = net, profile = profile }))
local accessibility = trove:add(AccessibilityController.new(profile, config))
local quality = trove:add(QualityController.new(profile, config))
local input = trove:add(InputController.new())
-- Tab opens the upgrade book: the core player list (which also toggles on Tab) is switched off;
-- nameplates and the lobby boards carry the same information.
pcall(function()
	game:GetService("StarterGui"):SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, false)
end)
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
	haptics = haptics,
	config = config,
}))
local round = trove:add(
	RoundController.new({ net = net, profile = profile, modals = modals, accessibility = accessibility, audio = audio, config = config })
)
local pile = trove:add(
	PileVisualController.new({ round = round, quality = quality, accessibility = accessibility, vfx = vfx, audio = audio, config = config })
)
local toolVisuals = trove:add(ToolVisualController.new({
	net = net,
	round = round,
	vfx = vfx,
	audio = audio,
	accessibility = accessibility,
	quality = quality,
	config = config,
	pile = pile,
	camera = camera,
	hud = hud,
}))
local tools = trove:add(ToolController.new({
	net = net,
	round = round,
	input = input,
	pile = pile,
	vfx = vfx,
	audio = audio,
	haptics = haptics,
	camera = camera,
	accessibility = accessibility,
	hud = hud,
	visuals = toolVisuals,
	config = config,
}))
local hand = tools -- Phase 2 automation helpers keep working through the tool controller
-- First-person tool models (no hands): the rake, dynamite and vacuum drawn under the camera.
local viewmodel = trove:add(ToolViewmodelController.new({
	tools = tools,
	round = round,
	accessibility = accessibility,
	audio = audio,
	vfx = vfx,
	pile = pile,
	config = config,
}))
toolVisuals:setProviders({
	nozzle = function(userId)
		if userId == player.UserId then
			return viewmodel:nozzlePosition()
		end
		return nil
	end,
	throwOrigin = function(userId)
		if userId == player.UserId then
			return viewmodel:muzzlePosition()
		end
		return nil
	end,
})
-- NPC dialogue frame (the Farmer's lines): camera close-up, outline, typewriter box.
local dialogue = trove:add(DialogueController.new({
	input = input,
	modals = modals,
	hud = hud,
	audio = audio,
	accessibility = accessibility,
	config = config,
}))
local interaction = trove:add(InteractionController.new({
	net = net,
	round = round,
	party = party,
	audio = audio,
	haptics = haptics,
	hud = hud,
	config = config,
	dialogue = dialogue,
}))
local objectives = trove:add(ObjectiveController.new({ net = net, hud = hud, round = round }))
local prompts = trove:add(PromptController.new({ input = input, audio = audio, accessibility = accessibility }))
local _ = prompts
local victory = trove:add(VictoryController.new({
	net = net,
	round = round,
	pile = pile,
	modals = modals,
	hud = hud,
	input = input,
	audio = audio,
	quality = quality,
	vfx = vfx,
	camera = camera,
	haptics = haptics,
	accessibility = accessibility,
	config = config,
}))
hud:bindRound(round, interaction)
-- Player nameplates: display name and record time over every character.
local nameplates = trove:add(NameplateController.new(round))
-- The upgrade book: Tab, the book button, or the supplies counter opens it during a search.
local book = trove:add(UpgradeBookController.new({
	net = net,
	round = round,
	profile = profile,
	modals = modals,
	input = input,
	audio = audio,
	haptics = haptics,
	hud = hud,
	config = config,
	accessibility = accessibility,
}))
hud:setBookOpener(function()
	book:toggle()
end)
-- Barn item inspection: camera focus, cinematic bars, options and skins for a display.
local inspect = trove:add(InspectController.new({
	net = net,
	round = round,
	profile = profile,
	modals = modals,
	input = input,
	audio = audio,
	haptics = haptics,
	hud = hud,
	vfx = vfx,
	config = config,
	accessibility = accessibility,
}))
-- Barn shop displays: price cards on the owner's item models and their inspect prompts.
local displays = trove:add(DisplayController.new({
	inspect = inspect,
	net = net,
	round = round,
	profile = profile,
	audio = audio,
	haptics = haptics,
	vfx = vfx,
	hud = hud,
	config = config,
	interaction = interaction,
}))
-- Alt frees the cursor while held (first person stays), like the reference game.
trove:add(input.actionBegan:Connect(function(action)
	if action == "Cursor" then
		modals:setExternalUnlock(true)
	end
end))
trove:add(input.actionEnded:Connect(function(action)
	if action == "Cursor" and not book:isOpen() and not inspect:isOpen() then
		modals:setExternalUnlock(false)
	end
end))
trove:add(pile.targetChanged:Connect(function(targeting)
	hud:setTargeting(targeting)
end))
local crateRun = trove:add(CrateController.new({ net = net, audio = audio, vfx = vfx, config = config }))
-- Permanent first person: locked from boot; menus unlock through the modal controller.
modals:setExternalUnlock(false)
trove:add(round.saleRefused:Connect(function(payload)
	hud.toasts:push(
		if payload.message == "nothing_to_sell"
			then "Your bag is empty"
			elseif payload.message == "crate_busy" then "The crate is on its way - wait for it to come back"
			else "Trade unavailable",
		"warning"
	)
	audio:play("ui.error")
end))
trove:add(hand.collected:Connect(function(data)
	hud:onCollected(data)
end))

local lobby = trove:add(LobbyShellController.new({
	ambient = ambient,
	vfx = vfx,
	quality = quality,
	camera = camera,
	haptics = haptics,
	audio = audio,
	config = config,
	strandsPerAnchor = 0,
}, "SFE_LobbyShell"))
local arena = trove:add(LobbyShellController.new({
	ambient = ambient,
	vfx = vfx,
	quality = quality,
	camera = camera,
	haptics = haptics,
	audio = audio,
	config = config,
	strandsPerAnchor = 0, -- no loose feathers drifting round the mound: every feather is a record
}, "SFE_Chapter1"))

-- Lobby meta layer (Phase 4): station rail, modals, prompt routing, leaderboards, silhouettes.
local lobbyMeta = trove:add(LobbyController.new({
	net = net,
	profile = profile,
	party = party,
	modals = modals,
	hud = hud,
	input = input,
	audio = audio,
	haptics = haptics,
	accessibility = accessibility,
	quality = quality,
	config = config,
	round = round,
	interaction = interaction,
	lobbyShell = lobby,
}))
hud:setGemShopOpener(function()
	if round:phase() == nil or round:phase() == "Lobby" then
		lobbyMeta:open("gems")
	else
		hud.toasts:push("The Gem Shop opens between searches", "info")
	end
end)

-- The Daily Nest shows itself once, on join, and only after the profile has actually arrived: before
-- that there is no streak to draw and the modal would open empty. One latch for the whole session,
-- dropped the moment it fires, so closing it, respawning or opening anything else never brings it
-- back - the player reopens it from the nest station like any other modal.
if config.featureFlags.dailyAutoOpenOnJoin ~= false and config.featureFlags.dailyRewardsEnabled ~= false then
	local dailyShown = false
	local dailyWatch: RBXScriptConnection? = nil
	local function showDailyOnce()
		if dailyShown then
			return
		end
		local projection = profile.projection
		if not (projection and projection.rewards and projection.rewards.daily) then
			return -- data still loading
		end
		dailyShown = true
		if dailyWatch then
			dailyWatch:Disconnect()
			dailyWatch = nil
		end
		task.defer(function()
			local phase = round:phase()
			if (phase == nil or phase == "Lobby") and modals:openCount() == 0 then
				lobbyMeta:open("daily")
			end
		end)
	end
	dailyWatch = profile.changed:Connect(showDailyOnce)
	trove:add(function()
		if dailyWatch then
			dailyWatch:Disconnect()
			dailyWatch = nil
		end
	end)
	showDailyOnce() -- in case the projection landed before this point
end

audio:setState("Lobby")
lobby:start()
arena:start()
lobbyMeta.leaderboards.request()

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
	arena = arena,
	round = round,
	pile = pile,
	hand = hand,
	tools = tools,
	toolVisuals = toolVisuals,
	interaction = interaction,
	objectives = objectives,
	victory = victory,
	party = party,
	lobbyMeta = lobbyMeta,
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
if RunService:IsStudio() then
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
			snap.detail = hud._labels.detail.Text
			snap.prompt = hud._labels.prompt.Visible
			snap.layoutClass = hud.gui:GetAttribute("SFE_LayoutClass")
			snap.viewport = tostring(workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize)
			snap.strands = lobby:strandCount() + arena:strandCount()
			snap.displays = displays:cardCount()
			snap.nameplates = nameplates:count()
			snap.inspecting = inspect:isOpen()
			snap.bookOpen = book:isOpen()
			snap.audioState = audio:state()
			snap.vfxInstances = vfx:instanceCount()
			snap.vfxStats = vfx.stats
			snap.ambientStats = ambient.stats
			snap.roundPhase = round:phase()
			snap.roundPlayer = round.player
			snap.elapsedMs = round:elapsedMs()
			snap.timerText = hud.round.timerText.Text
			snap.bagText = hud.round.bagText.Text
			snap.cashText = hud.round.cashText.Text
			snap.pileCells = pile:cellCount()
			snap.pileInstances = pile:instanceCount()
			snap.pilePooled = pile:pooledCount()
			snap.pileStats = pile.stats
			snap.handStats = hand.stats
			snap.tools = tools:status()
			snap.toolVisuals = toolVisuals:counts()
			snap.toolVisualInstances = toolVisuals:instanceCount()
			snap.hotbarOwned = hud.hotbar:ownedCount()
			snap.objective = objectives.step
			snap.victoryStats = victory.stats
			snap.cameraMode = tostring(player.CameraMode)
			snap.eggPosition = round.eggPosition and tostring(round.eggPosition) or nil
			snap.party = party.party
			snap.partyList = party.list
			snap.lobbyStats = lobbyMeta.stats
			snap.modalTop = modals:topId()
			snap.blurSize = modals:blurSize()
			snap.selected = tostring(game:GetService("GuiService").SelectedObject)
			snap.pileFeathers = pile:featherCount()
			snap.lobbyLoops = lobby:loopCount()
			snap.leaderboardBoards = lobbyMeta.leaderboards.snapshot and #lobbyMeta.leaderboards.snapshot.boards or 0
			return snap
		end,
		-- Phase 4 lobby helpers: every action goes through the real controllers/remotes.
		openStation = function(id)
			return { opened = lobbyMeta:open(tostring(id)), top = modals:topId() }
		end,
		stationPrompt = function(id)
			interaction:handle("SFE_Station_" .. tostring(id))
			return { top = modals:topId() }
		end,
		-- Fires any world prompt by name through the real prompt router (pads, portal, sell, upgrade, egg).
		prompt = function(name)
			local result = interaction:handle(tostring(name))
			return { result = result, top = modals:topId() }
		end,
		partyCreate = function(chapter, difficulty, size)
			return party:create(chapter or "chapter1", difficulty or "normal", size)
		end,
		partyJoin = function(partyId)
			return party:join(partyId)
		end,
		partyStart = function()
			return party:start()
		end,
		partyCancel = function()
			return party:cancel()
		end,
		partyLeave = function()
			return party:leave()
		end,
		partySetDestination = function(chapter, difficulty)
			return party:setDestination(chapter, difficulty)
		end,
		rollClass = function(slot)
			return net:request("ClassRoll", { slot = tonumber(slot) or 1 })
		end,
		equipClass = function(classId, slot)
			return net:request("ClassEquip", { classId = classId, slot = tonumber(slot) or 1 })
		end,
		buyPerk = function(perkId)
			local level = profile.projection and profile.projection.permanentPerks[perkId] or 0
			return net:request("PerkPurchase", { perkId = perkId, expectedLevel = level })
		end,
		claimDaily = function()
			return net:request("DailyClaim", nil)
		end,
		redeemCode = function(code)
			return net:request("CodeRedeem", { code = tostring(code) })
		end,
		claimGroup = function()
			return net:request("GroupRewardClaim", nil)
		end,
		equipSkin = function(category, itemId)
			return net:request("InventoryEquip", { category = category, itemId = itemId })
		end,
		requestLeaderboards = function()
			return net:request("LeaderboardRequest", nil)
		end,
		-- Modal read surface: visible buttons, tap sizes, and the current selection for evidence.
		modalReport = function()
			local top = modals:topId()
			local report =
				{ top = top, open = modals:openCount(), blocking = modals:isBlocking(), blurSize = modals:blurSize(), buttons = {} }
			local guiService = game:GetService("GuiService")
			report.selected = guiService.SelectedObject and guiService.SelectedObject:GetFullName() or nil
			for _, descendant in ipairs(modals.gui:GetDescendants()) do
				if descendant:IsA("GuiButton") and descendant.Visible and descendant.AbsoluteSize.X > 0 then
					table.insert(report.buttons, {
						name = descendant.Name,
						text = if descendant:IsA("TextButton") then descendant.Text else "",
						w = math.floor(descendant.AbsoluteSize.X),
						h = math.floor(descendant.AbsoluteSize.Y),
						selectable = descendant.Selectable,
					})
				end
			end
			return report
		end,
		-- Presses a modal button by name through its Activated signal (real GUI activation path).
		pressButton = function(name)
			for _, descendant in ipairs(modals.gui:GetDescendants()) do
				if descendant:IsA("GuiButton") and descendant.Name == name and descendant.Visible then
					local guiService = game:GetService("GuiService")
					guiService.SelectedObject = descendant
					return { found = true, selected = guiService.SelectedObject == descendant }
				end
			end
			return { found = false }
		end,
		modalAction = function(id, action, ...)
			return modals:debugAction(tostring(id), tostring(action), ...) or { error = "no_action" }
		end,
		classesState = function()
			local top = modals.gui:FindFirstChild("Modal_classes", true)
			local content = top and top:FindFirstChild("Content", true)
			if not content then
				return { open = false }
			end
			return {
				open = true,
				rolling = content:GetAttribute("SFE_ClassesRolling"),
				auto = content:GetAttribute("SFE_ClassesAuto"),
				reveals = content:GetAttribute("SFE_ClassesReveals"),
				lastReveal = content:GetAttribute("SFE_ClassesLastReveal"),
			}
		end,
		railReport = function()
			local out = {}
			for _, id in ipairs(LobbyController.stationIds()) do
				local button = lobbyMeta:railButton(id)
				if button then
					table.insert(
						out,
						{ id = id, w = math.floor(button.AbsoluteSize.X), h = math.floor(button.AbsoluteSize.Y), visible = button.Visible }
					)
				end
			end
			return { visible = lobbyMeta.rail.Visible, buttons = out }
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
		-- Phase 2 protocol helpers: drive the real client controllers (no server shortcuts).
		enterPortal = function()
			return interaction:handle("SFE_Portal")
		end,
		skipCutscene = function()
			local token = round:sessionToken()
			return token and net:request("RoundSkipVote", { sessionToken = token }) or { ok = false }
		end,
		collect = function(times, x, y, z)
			local results = { sent = 0, accepted = 0, rejected = 0, codes = {}, hits = {} }
			local aim = if x then Vector3.new(tonumber(x) or 0, tonumber(y) or 0, tonumber(z) or 0) else nil
			local rejectedConn = hand.rejected:Connect(function(result)
				local key = tostring(result.message or result.code)
				results.codes[key] = (results.codes[key] or 0) + 1
			end)
			local hitConn = hand.collected:Connect(function(data)
				if #results.hits < 3 then
					table.insert(
						results.hits,
						{ x = data.hitX, y = data.hitY, z = data.hitZ, cell = data.cellIndex, remaining = data.remaining }
					)
				end
			end)
			for _ = 1, tonumber(times) or 1 do
				local before = hand.stats.accepted
				results.sent += 1
				local ok = hand:tryCollect(aim)
				if ok and hand.stats.accepted > before then
					results.accepted += 1
				else
					results.rejected += 1
				end
				task.wait(config.collection.baseHandCooldownSeconds + 0.05)
			end
			rejectedConn:Disconnect()
			hitConn:Disconnect()
			return results
		end,
		-- Quality tier switch (settings path) followed by a coat rebuild, for density evidence.
		setQuality = function(mode)
			quality:setMode(tostring(mode))
			pile:rebuild()
			task.wait(1.5)
			return {
				tier = quality:tier(),
				feathers = pile:featherCount(),
				fluff = pile:fluffCount(),
				instances = pile:instanceCount(),
			}
		end,
		crateReport = function()
			local crate = crateRun:crateModel()
			return {
				running = crateRun:isRunning(),
				stats = crateRun.stats,
				pivot = crate and tostring(crate:GetPivot().Position) or "none",
				mouse = {
					behavior = tostring(game:GetService("UserInputService").MouseBehavior),
					icon = game:GetService("UserInputService").MouseIconEnabled,
					cameraMode = tostring(player.CameraMode),
					unlocked = modals.mouseUnlocked == true,
				},
			}
		end,
		-- Device emulation: shrinks every UI stage to the given size (nil restores the viewport).
		emulate = function(width, height)
			local SafeArea = require(script.UI.SafeArea)
			if width and height then
				SafeArea.setViewportOverride(Vector2.new(tonumber(width) or 812, tonumber(height) or 375))
			else
				SafeArea.setViewportOverride(nil)
			end
			return {
				override = tostring(SafeArea.viewportOverride()),
				class = SafeArea.layoutClass(SafeArea.viewport().X, SafeArea.viewport().Y),
			}
		end,
		pileReport = function()
			local report: any = table.clone(pile.stats)
			report.feathers = pile:featherCount()
			report.fluff = pile:fluffCount()
			report.instances = pile:instanceCount()
			report.pooled = pile:pooledCount()
			report.tier = quality:tier()
			local target = pile.target
			report.target = target
					and {
						x = target.position.X,
						y = target.position.Y,
						z = target.position.Z,
						cell = target.cell,
						featherId = target.featherId,
						slot = target.slot,
					}
				or nil
			-- Frame-time sample (render steps over ~2 seconds).
			local frames, total, worst = 0, 0, 0
			local conn = game:GetService("RunService").RenderStepped:Connect(function(dt)
				frames += 1
				total += dt
				worst = math.max(worst, dt)
			end)
			task.wait(2)
			conn:Disconnect()
			report.fpsAvg = frames > 0 and math.floor(frames / total) or 0
			report.frameWorstMs = math.floor(worst * 1000)
			report.memoryMb = math.floor(game:GetService("Stats"):GetTotalMemoryUsageMb())
			return report
		end,
		-- Walks the character with Humanoid:MoveTo (real locomotion, server-validated positions).
		moveTo = function(x, y, z, timeout)
			local character = player.Character
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if not humanoid or not root then
				return { error = "no_character" }
			end
			local target = Vector3.new(tonumber(x) or 0, tonumber(y) or 0, tonumber(z) or 0)
			local deadline = os.clock() + (tonumber(timeout) or 12)
			humanoid:MoveTo(target)
			while os.clock() < deadline do
				local flat = Vector3.new(target.X - (root :: BasePart).Position.X, 0, target.Z - (root :: BasePart).Position.Z)
				if flat.Magnitude < 2.5 then
					break
				end
				humanoid:MoveTo(target)
				task.wait(0.2)
			end
			local position = (root :: BasePart).Position
			return {
				x = position.X,
				y = position.Y,
				z = position.Z,
				distance = (Vector3.new(target.X, 0, target.Z) - Vector3.new(position.X, 0, position.Z)).Magnitude,
			}
		end,
		-- Automation harness for Protocol A: repeatedly walks to the nearest feathered cell, gathers
		-- through the real Hand path until the bag is full, walks to the crate and trades, buys the
		-- first upgrade when affordable, and claims the Egg once revealed. Runs in the background;
		-- poll `snapshot` / `autoStatus`. Every action goes through validated remotes.
		autoPlay = function(maxSeconds, stopAtReveal)
			if container._autoThread then
				return { error = "already_running" }
			end
			local ChapterLayout = require(Shared.Domain.ChapterLayout)
			local layout = ChapterLayout.chapter1
			local status = { state = "starting", hits = 0, sales = 0, upgrades = 0, claimed = false, log = {} }
			container._autoStatus = status
			local function say(line: string)
				table.insert(status.log, line)
				if #status.log > 40 then
					table.remove(status.log, 1)
				end
			end
			local function walk(target: Vector3)
				local character = player.Character
				local humanoid = character and character:FindFirstChildOfClass("Humanoid")
				local root = character and character:FindFirstChild("HumanoidRootPart")
				if not humanoid or not root then
					return false
				end
				local deadline = os.clock() + 15
				local lastDistance, stuckSince = math.huge, os.clock()
				while os.clock() < deadline do
					local flat = Vector3.new(target.X - (root :: BasePart).Position.X, 0, target.Z - (root :: BasePart).Position.Z)
					if flat.Magnitude < 3 then
						return true
					end
					if flat.Magnitude < lastDistance - 0.5 then
						lastDistance, stuckSince = flat.Magnitude, os.clock()
					elseif os.clock() - stuckSince > 1.5 then
						humanoid.Jump = true -- nudge past props the straight-line MoveTo bumps into
						stuckSince = os.clock()
					end
					humanoid:MoveTo(target)
					task.wait(0.2)
				end
				return false
			end
			local function nearestCell(): (Vector3?, number?)
				local snapshot = round.pile
				local character = player.Character
				local root = character and character:FindFirstChild("HumanoidRootPart")
				if not snapshot or not root then
					return nil, nil
				end
				local best, bestDistance, bestIndex = nil, math.huge, nil
				local remaining = pile:remainingByIndex()
				for index = 1, snapshot.width * snapshot.depth do
					local left = remaining[index]
					if left and left > 0 then
						local cx = (index - 1) % snapshot.width
						local cz = math.floor((index - 1) / snapshot.width)
						local position =
							ChapterLayout.cellWorldPosition(layout, snapshot.width, snapshot.depth, snapshot.cellSize, cx, cz, 0)
						local distance = (Vector3.new(position.X, 0, position.Z) - Vector3.new(
							(root :: BasePart).Position.X,
							0,
							(root :: BasePart).Position.Z
						)).Magnitude
						if distance < bestDistance then
							best, bestDistance, bestIndex = position, distance, index
						end
					end
				end
				return best, bestIndex
			end
			container._autoThread = task.spawn(function()
				local deadline = os.clock() + (tonumber(maxSeconds) or 600)
				while os.clock() < deadline do
					local phase = round:phase()
					if phase == "Results" or phase == "Victory" or phase == "CommittingRewards" then
						status.state = "finished"
						break
					end
					if phase == "EggRevealed" and stopAtReveal then
						status.state = "revealed"
						break
					end
					if phase == "EggRevealed" and round.eggPosition then
						status.state = "claiming"
						walk(round.eggPosition + Vector3.new(0, 0, -3))
						local result = interaction:handle("SFE_EggClaim")
						if result and result.ok then
							status.claimed = true
							say("claimed")
						else
							say("claim rejected: " .. tostring(result and result.code))
						end
						task.wait(0.5)
						continue
					end
					if phase ~= "Searching" then
						status.state = "waiting:" .. tostring(phase)
						task.wait(0.5)
						continue
					end
					local state = round.player
					local capacity = config.bags.levels[(state and state.bagLevel) or 1].capacity
					local carried = state and (state.carriedStandard + state.carriedRainbow) or 0
					if carried >= capacity then
						status.state = "selling"
						walk(layout.sellStation + Vector3.new(0, 0, 8))
						local result = interaction:handle("SFE_Sell")
						if result and result.ok then
							status.sales += 1
							say(string.format("sold %d for %d cents", result.data.standardCount, result.data.finalCents))
						else
							say("sell rejected: " .. tostring(result and result.code))
						end
						-- First affordable upgrade: grasp (proves the purchase path once). Approach from the nest side.
						local level, graspCost = 0, nil
						for _, preview in ipairs(round.previews or {}) do
							if preview.upgradeId == "handGrasp" then
								level, graspCost = preview.level, preview.costCents
							end
						end
						if status.upgrades == 0 and graspCost and round.player and round.player.cashCents >= graspCost then
							status.state = "upgrading"
							walk(layout.upgradeBoard + Vector3.new(0, 0, 8))
							local token = round:sessionToken()
							local bought = token
								and net:request("UpgradePurchase", { sessionToken = token, upgradeId = "handGrasp", expectedLevel = level })
							if bought and bought.ok then
								status.upgrades += 1
								say("bought handGrasp -> level " .. tostring(bought.data.level))
							else
								say("upgrade rejected: " .. tostring(bought and bought.code))
							end
						end
						task.wait(0.3)
						continue
					end
					status.state = "gathering"
					local target, index = nearestCell()
					if not target then
						say("no feathered cell found")
						task.wait(1)
						continue
					end
					local character = player.Character
					local root = character and character:FindFirstChild("HumanoidRootPart")
					if
						root
						and (Vector3.new(target.X, 0, target.Z) - Vector3.new(
								(root :: BasePart).Position.X,
								0,
								(root :: BasePart).Position.Z
							)).Magnitude
							> 8
					then
						walk(target + Vector3.new(0, 0, -4))
					end
					local aim = Vector3.new(target.X, layout.nestBaseY + config.pile.aimPlaneHeightStuds, target.Z)
					local before = hand.stats.accepted
					hand:tryCollect(aim)
					if hand.stats.accepted > before then
						status.hits += 1
					else
						say("hit rejected at cell " .. tostring(index))
						task.wait(0.2)
					end
					task.wait(config.collection.baseHandCooldownSeconds + 0.03)
				end
				if status.state ~= "finished" and status.state ~= "revealed" then
					status.state = "timeout"
				end
				container._autoThread = nil
			end)
			return { started = true }
		end,
		autoStatus = function()
			return container._autoStatus or { state = "idle" }
		end,
		autoStop = function()
			if container._autoThread then
				task.cancel(container._autoThread)
				container._autoThread = nil
			end
			return true
		end,
		lookAt = function(x, y, z)
			local cam = workspace.CurrentCamera
			local character = player.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if cam and root then
				cam.CFrame = CFrame.lookAt(
					(root :: BasePart).Position + Vector3.new(0, 1.5, 0),
					Vector3.new(tonumber(x) or 0, tonumber(y) or 0, tonumber(z) or 0)
				)
			end
			return cam and tostring(cam.CFrame.LookVector) or "no camera"
		end,
		sell = function()
			return interaction:handle("SFE_Sell")
		end,
		openUpgrades = function()
			book:open()
			return { open = book:isOpen() }
		end,
		-- Page turns without a mouse, so the page-flip sound can be counted in Studio: presses that do
		-- not actually change the spread (already at an end, or mid-flip) must stay silent.
		flipBook = function(direction, times)
			local moved = 0
			local function page(): number
				return (book :: any)._session and (book :: any)._session.page or 0
			end
			for _ = 1, math.max(1, tonumber(times) or 1) do
				local before = page()
				book:_flip(if tonumber(direction) and tonumber(direction) < 0 then -1 else 1)
				task.wait(0.45)
				if page() ~= before then
					moved += 1
				end
			end
			return { moved = moved, page = page(), flips = book.stats.flips }
		end,
		closeBook = function()
			book:close()
			return { open = book:isOpen() }
		end,
		buy = function(upgradeId)
			local token = round:sessionToken()
			local level = 0
			for _, preview in ipairs(round.previews or {}) do
				if preview.upgradeId == upgradeId then
					level = preview.level
				end
			end
			return token and net:request("UpgradePurchase", { sessionToken = token, upgradeId = upgradeId, expectedLevel = level })
				or { ok = false }
		end,
		claim = function()
			return interaction:handle("SFE_EggClaim")
		end,
		resultsAction = function(action)
			return net:request("ResultsAction", { action = action or "lobby" })
		end,
		closeModal = function(id)
			return modals:close(id)
		end,
		-- Phase 3 tool helpers: every call goes through the same controller/remotes a player uses.
		equip = function(toolId)
			return { ok = tools:equip(toolId), equipped = tools:equipped() }
		end,
		toolBegin = function(x, y, z)
			local aim = if x then Vector3.new(tonumber(x) or 0, tonumber(y) or 0, tonumber(z) or 0) else nil
			return tools:beginAction(aim)
		end,
		toolEnd = function()
			return tools:endAction()
		end,
		toolStatus = function()
			local status = tools:status()
			status.visuals = toolVisuals:counts()
			status.viewmodel = viewmodel:status()
			return status
		end,
		viewmodelStatus = function()
			return viewmodel:status()
		end,
		lightCharge = function()
			tools:_lightCharge()
			return tools:status()
		end,
		throwCharge = function()
			tools:_throwCharge()
			return tools:status()
		end,
		gather = function(bundleId)
			return tools:gather(bundleId)
		end,
		pressPrimary = function(seconds)
			input:touchBegin("Primary")
			task.wait(tonumber(seconds) or 0.2)
			input:touchEnd("Primary")
			return tools:status()
		end,
		-- Discrete-tool cadence harness: attempts a collect every `stepSeconds` for `seconds`, auto-aiming at
		-- the nearest feathered cell within range, and records accepted timestamps, yields, and server codes.
		sweepTest = function(seconds, stepSeconds)
			local ChapterLayout = require(Shared.Domain.ChapterLayout)
			local layout = ChapterLayout.chapter1
			local report = { attempts = 0, accepted = 0, awarded = 0, removed = 0, codes = {}, timestamps = {}, cells = {} }
			local function aimTarget(): Vector3?
				local character = player.Character
				local root = character and character:FindFirstChild("HumanoidRootPart")
				if not root or not round.pile then
					return nil
				end
				local origin = (root :: BasePart).Position
				local best, bestDistance = nil, math.huge
				for index, remaining in pairs(pile:remainingByIndex()) do
					if remaining > 0 then
						local x = (index - 1) % round.pile.width
						local z = math.floor((index - 1) / round.pile.width)
						local world =
							ChapterLayout.cellWorldPosition(layout, round.pile.width, round.pile.depth, round.pile.cellSize, x, z, 0)
						local flat = Vector3.new(world.X - origin.X, 0, world.Z - origin.Z).Magnitude
						if flat < bestDistance and flat <= config.interaction.defaultRangeStuds - 1 then
							best, bestDistance = world, flat
						end
					end
				end
				return best and Vector3.new(best.X, layout.nestBaseY + config.pile.aimPlaneHeightStuds, best.Z) or nil
			end
			local acceptedConn = tools.collected:Connect(function(data)
				report.accepted += 1
				report.awarded += data.awarded or 0
				report.removed += data.removed or data.awarded or 0
				report.cells[#report.cells + 1] = data.cells and #data.cells or 1
				table.insert(report.timestamps, os.clock())
			end)
			local rejectedConn = tools.rejected:Connect(function(result)
				local key = tostring(result.message or result.code)
				report.codes[key] = (report.codes[key] or 0) + 1
			end)
			local started = os.clock()
			while os.clock() - started < (tonumber(seconds) or 10) do
				local aim = aimTarget()
				if aim then
					report.attempts += 1
					tools:tryCollect(aim)
				else
					report.codes.no_target_in_range = (report.codes.no_target_in_range or 0) + 1
				end
				task.wait(tonumber(stepSeconds) or 0.05)
			end
			acceptedConn:Disconnect()
			rejectedConn:Disconnect()
			local intervals = {}
			for i = 2, #report.timestamps do
				table.insert(intervals, report.timestamps[i] - report.timestamps[i - 1])
			end
			table.sort(intervals)
			local sum = 0
			for _, v in ipairs(intervals) do
				sum += v
			end
			report.timestamps = nil
			report.minInterval = intervals[1]
			report.medianInterval = intervals[math.ceil(#intervals / 2)]
			report.meanInterval = if #intervals > 0 then sum / #intervals else nil
			report.equipped = tools:equipped()
			return report
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
		"[SFE][Client] ready in %d ms (build %s, meshesRepaired %d)",
		math.floor((os.clock() - bootStarted) * 1000),
		tostring(runtime:GetAttribute("SFE_BuildLabel")),
		repairedMeshes
	)
)
