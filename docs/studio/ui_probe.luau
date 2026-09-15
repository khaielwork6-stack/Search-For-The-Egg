-- Edit-mode UI probe for Studio (paste into the Assistant / command bar while NOT in Play).
-- Builds the client HUD, station rail and modals into StarterGui against stub dependencies so the
-- UI can be screenshotted in Edit mode (Play-mode captures come back blank on some machines).
-- Usage after pasting:  _G.SFE_UIProbeBuild({ round = true })      -- gameplay HUD in a round
--                       _G.SFE_UIProbeBuild({ round = false })     -- lobby, then p.lobby:open("shop")
--                       _G.SFE_UIProbeOpen("shop")                 -- any station modal by id
--                       _G.SFE_UIProbeOpen("book")                 -- the upgrade book (needs round = true)
--                       require(_G.SFE_UIProbe.clientRoot.UI.SafeArea).setViewportOverride(Vector2.new(812, 375))
--                       _G.SFE_UIProbeTeardown()                   -- restores ReplicatedStorage.Shared
local RS = game:GetService("ReplicatedStorage")
_G.SFE_UIProbeTeardown = function()
	local old = _G.SFE_UIProbe
	if not old then
		return
	end
	pcall(function()
		old.modals:closeAll()
	end)
	pcall(function()
		old.book:close()
	end)
	pcall(function()
		old.book:destroy()
	end)
	pcall(function()
		old.lobby:destroy()
	end)
	pcall(function()
		old.hud:destroy()
	end)
	pcall(function()
		old.modals:destroy()
	end)
	pcall(function()
		old.fresh:Destroy()
	end)
	old.orig.Name = "Shared"
	pcall(function()
		old.clientRoot:Destroy()
	end)
	pcall(function()
		old.cfgModule:Destroy()
	end)
	_G.SFE_UIProbe = nil
	for _, name in ipairs({ "SFE_HUD", "SFE_Modals", "SFE_Lobby", "SFE_Book" }) do
		local g = game.StarterGui:FindFirstChild(name)
		if g then
			g:Destroy()
		end
	end
end
_G.SFE_UIProbeBuild = function(scenario)
	_G.SFE_UIProbeTeardown()
	local orig = RS:FindFirstChild("Shared")
	local fresh = orig:Clone()
	orig.Name = "Shared_orig"
	fresh.Name = "Shared"
	fresh.Parent = RS
	local Signal = require(fresh.Util.Signal)
	local Config = require(fresh.Config)
	local cfgModule = game.ServerStorage.SFE.SystemConfig:Clone()
	local cfg = Config.fromRaw(require(cfgModule))
	local clientRoot = game.StarterPlayer.StarterPlayerScripts.Client:Clone()
	clientRoot.Name = "SFE_ProbeClient"
	clientRoot.Parent = game.ServerStorage
	local HUDController = require(clientRoot.Controllers.HUDController)
	local UpgradeBookController = require(clientRoot.Controllers.UpgradeBookController)
	local ModalController = require(clientRoot.Controllers.ModalController)
	local LobbyController = require(clientRoot.Controllers.LobbyController)
	local function conn()
		return { Disconnect = function() end }
	end
	local net = {
		on = function()
			return conn()
		end,
		request = function()
			return { ok = true, code = "ok", data = { level = 1, gems = 40, dayIndex = 3 } }
		end,
	}
	local firstClass = cfg.classes.weights[1].id
	local projection = {
		currencies = { gems = 125, eventTokens = 8 },
		permanentPerks = { bagSize = 2, handGrab = 1 },
		classes = { slotCount = 1, equipped = { firstClass }, owned = { [firstClass] = true, [cfg.classes.weights[3].id] = true } },
		rewards = { daily = { status = "ready", dayIndex = 3, gems = 40, nextClaimInSeconds = 0, graceRemainingSeconds = 0 } },
		entitlements = {},
		settings = { reducedMotion = false, cameraShake = true, haptics = true, qualityMode = "auto" },
		inventory = { toolSkins = {}, equippedSkins = {} },
		progression = {
			totalWins = 2,
			bestTimeMs = { chapter1 = { normal = 95340 } },
			unlockedDifficulties = { chapter1 = { normal = true } },
		},
		stats = { playtimeSeconds = 5400, eggsFound = 2, feathersCollected = 340, roundsCompleted = 5 },
	}
	local profile = {
		projection = projection,
		changed = Signal.new(),
		sessionChanged = Signal.new(),
		settings = function()
			return projection.settings
		end,
	}
	local mode = (scenario and scenario.mode) or "mouse"
	local input = {
		modeChanged = Signal.new(),
		actionBegan = Signal.new(),
		actionEnded = Signal.new(),
		mode = function()
			return mode
		end,
		setSuspended = function() end,
		isHeld = function()
			return false
		end,
	}
	local accessibility = {
		motionSettings = function()
			return { reducedMotion = false, maximumUiTweenSeconds = 0.45, reducedMotionScale = 0.35 }
		end,
		motionScale = function()
			return 1
		end,
	}
	local quality = {
		tier = function()
			return "high"
		end,
	}
	local audio = { play = function() end }
	local haptics = { pulse = function() end }
	local parent = game:GetService("StarterGui")
	local modals = ModalController.new(input, accessibility, cfg, parent)
	local hud = HUDController.new({
		net = net,
		profile = profile,
		modals = modals,
		input = input,
		accessibility = accessibility,
		quality = quality,
		audio = audio,
		haptics = haptics,
		config = cfg,
		parent = parent,
	})
	-- Previews drive every level, price and MAX in the book, so the probe ships a realistic set:
	-- hand and bag part-levelled, the rake owned with one path maxed, the rest still locked.
	local previews = {
		{
			upgradeId = "bag",
			kind = "bag",
			level = 2,
			maxLevel = 5,
			maxed = false,
			costGems = 150,
			current = { capacity = 50 },
			next = { capacity = 75 },
		},
		{
			upgradeId = "hand.hold",
			kind = "hand",
			level = 3,
			maxLevel = 6,
			maxed = false,
			costCents = 4500,
			current = { hold = 3 },
			next = { hold = 4 },
		},
		{ upgradeId = "hand.speed", kind = "hand", level = 6, maxLevel = 6, maxed = true, current = { speed = 6 }, next = { speed = 6 } },
		{
			upgradeId = "hand.grasp",
			kind = "hand",
			level = 1,
			maxLevel = 6,
			maxed = false,
			costCents = 1200,
			current = { grasp = 1 },
			next = { grasp = 2 },
		},
		{
			upgradeId = "nestRake.sweep",
			kind = "tool",
			level = 4,
			maxLevel = 6,
			maxed = false,
			costCents = 9800,
			current = { sweep = 4 },
			next = { sweep = 5 },
		},
		{
			upgradeId = "nestRake.hold",
			kind = "tool",
			level = 2,
			maxLevel = 6,
			maxed = false,
			costCents = 5400,
			current = { hold = 2 },
			next = { hold = 3 },
		},
		{
			upgradeId = "nestRake.cooldown",
			kind = "tool",
			level = 6,
			maxLevel = 6,
			maxed = true,
			current = { cooldown = 6 },
			next = { cooldown = 6 },
		},
		{ upgradeId = "tool:nestRake", kind = "acquire", toolId = "nestRake", maxed = true },
		{ upgradeId = "tool:featherVac", kind = "acquire", toolId = "featherVac", maxed = false, costGems = 250 },
	}
	local round = {
		phaseChanged = Signal.new(),
		playerChanged = Signal.new(),
		sale = Signal.new(),
		upgrade = Signal.new(),
		eggRevealed = Signal.new(),
		player = nil,
		previews = previews,
		phase = function()
			return "Searching"
		end,
		elapsedMs = function()
			return 83450
		end,
		countdownRemaining = function()
			return nil
		end,
		sessionToken = function()
			return "probe"
		end,
	}
	local interaction = { openUpgrades = Signal.new(), stationRequested = Signal.new() }
	local party = {
		party = nil,
		list = {},
		changed = Signal.new(),
		listChanged = Signal.new(),
		isLeader = function()
			return false
		end,
		countdownRemaining = function()
			return nil
		end,
	}
	hud:bindRound(round, interaction)
	local lobby = LobbyController.new({
		net = net,
		profile = profile,
		party = party,
		modals = modals,
		hud = hud,
		input = input,
		interaction = interaction,
		audio = audio,
		haptics = haptics,
		accessibility = accessibility,
		config = cfg,
		round = round,
		parent = parent,
		quality = quality,
	})
	local book = UpgradeBookController.new({
		net = net,
		round = round,
		modals = modals,
		hud = hud,
		input = input,
		audio = audio,
		haptics = haptics,
		accessibility = accessibility,
		config = cfg,
		profile = profile,
	})
	_G.SFE_UIProbe = {
		hud = hud,
		modals = modals,
		lobby = lobby,
		book = book,
		round = round,
		profile = profile,
		orig = orig,
		fresh = fresh,
		clientRoot = clientRoot,
		cfgModule = cfgModule,
		cfg = cfg,
		input = input,
	}
	if scenario and scenario.round then
		round.phaseChanged:Fire("Searching")
		round.player = {
			bagLevel = 1,
			bagCapacity = 25,
			carriedStandard = scenario.carried or 17,
			carriedRainbow = 0,
			cashCents = 1240,
			roundTools = { nestRake = true },
		}
		round.playerChanged:Fire(round.player)
		hud.hotbar:setOwned({ nestRake = true })
		hud.hotbar:setStatus("nestRake", 0.6, "Cooling", "warning")
		hud:setObjective("Gather 25 feathers", "Click or tap the nest to pull feathers into your bag")
		hud:setTargeting(true)
		hud.round:setTimer(83450)
	else
		hud:setObjective("Step onto the henhouse path", "Walk to the glowing doorway and press Interact")
	end
	if hud._dropVeil then
		hud._dropVeil()
	end
	workspace.CurrentCamera.CFrame = CFrame.lookAt(Vector3.new(0, 58, 388), Vector3.new(0, 57, 372))
	return true
end

-- Opens one screen by id so a screenshot pass needs one short line per screen.
_G.SFE_UIProbeOpen = function(id)
	local p = _G.SFE_UIProbe
	if not p then
		return "build first: _G.SFE_UIProbeBuild({ round = true })"
	end
	pcall(function()
		p.book:close()
	end)
	pcall(function()
		p.modals:closeAll()
	end)
	if id == "book" then
		p.book:open()
		return "book open"
	end
	p.lobby:open(id)
	return id .. " open"
end
return "probe ready"
