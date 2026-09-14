--!strict
-- HUD: currency chips bound to the profile projection, objective banner (title + detail), input
-- prompt chip that swaps by input mode, settings modal round trip, toast queue, and the round strip
-- (bag meter / cash / timer) that appears only during rounds. Sale and upgrade feedback land here.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local GuiService = game:GetService("GuiService")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local Trove = require(Shared.Util.Trove)
local EconomyMath = require(Shared.EconomyMath)
local SafeArea = require(script.Parent.Parent.UI.SafeArea)
local Button = require(script.Parent.Parent.UI.Components.Button)
local Toast = require(script.Parent.Parent.UI.Components.Toast)
local RoundHud = require(script.Parent.Parent.UI.RoundHud)
local CarriedStack = require(script.Parent.Parent.UI.CarriedStack)
local ToolHotbar = require(script.Parent.Parent.UI.ToolHotbar)
local UpgradeModal = require(script.Parent.Parent.UI.UpgradeModal)
local Tween = require(script.Parent.Parent.UI.Components.Tween)
local FrameKit = require(script.Parent.Parent.UI.Components.Frame)

local HUDController = {}
HUDController.__index = HUDController

export type HUDController = typeof(setmetatable(
	{} :: {
		gui: ScreenGui,
		stage: Frame,
		toasts: any,
		round: any,
		hotbar: any,
		carriedStack: any,
		_deps: any,
		_labels: { [string]: any },
		_displayed: { [string]: number },
		_chipScales: { [string]: UIScale },
		_infiniteBag: boolean?,
		_timerConnection: RBXScriptConnection?,
		_trove: Trove.Trove,
	},
	HUDController
))

local function chip(parent: Instance, name: string, order: number): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.LayoutOrder = order
	label.AutomaticSize = Enum.AutomaticSize.X
	label.Size = UDim2.fromOffset(0, Tokens.layout.minimumTapTargetPx)
	label.BackgroundColor3 = Tokens.color.surface
	label.TextColor3 = Tokens.color.inkStrong
	label.Font = Tokens.typography.numeral.font
	label.TextSize = Tokens.typography.numeral.size
	label.Text = name
	label.ZIndex = Tokens.zIndex.hud
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, Tokens.radius.pill)
	corner.Parent = label
	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, Tokens.spacing.lg)
	padding.PaddingRight = UDim.new(0, Tokens.spacing.lg)
	padding.Parent = label
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = Tokens.stroke.bold
	stroke.Color = Tokens.color.outline
	stroke.Parent = label
	local scale = Instance.new("UIScale")
	scale.Parent = label
	label.BackgroundColor3 = Tokens.color.creamPill
	label.Font = Tokens.typography.label.font
	label.TextSize = Tokens.typography.label.size
	label.TextStrokeColor3 = Tokens.color.outline
	label.TextStrokeTransparency = 0.35
	label.Parent = parent
	return label
end

function HUDController.new(deps: any): HUDController
	local gui = Instance.new("ScreenGui")
	gui.Name = "SFE_HUD"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = Tokens.zIndex.hud
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	local _, scaleCleanup, stage = SafeArea.applyScale(gui, deps.config)

	local self = setmetatable({
		gui = gui,
		stage = stage,
		toasts = nil,
		round = nil,
		hotbar = nil,
		carriedStack = nil,
		_deps = deps,
		_labels = {},
		_displayed = {},
		_chipScales = {},
		_timerConnection = nil,
		_trove = Trove.new(),
	}, HUDController)
	self._trove:add(gui)
	self._trove:add(scaleCleanup)

	-- Top-left currency row.
	local row = Instance.new("Frame")
	row.Name = "Currencies"
	row.BackgroundTransparency = 1
	row.Position = UDim2.fromOffset(Tokens.layout.safeAreaPaddingPx, Tokens.layout.safeAreaPaddingPx)
	row.Size = UDim2.fromOffset(0, Tokens.layout.minimumTapTargetPx)
	row.AutomaticSize = Enum.AutomaticSize.X
	local rowLayout = Instance.new("UIListLayout")
	rowLayout.FillDirection = Enum.FillDirection.Horizontal
	rowLayout.Padding = UDim.new(0, Tokens.spacing.sm)
	rowLayout.SortOrder = Enum.SortOrder.LayoutOrder
	rowLayout.Parent = row
	row.Parent = stage
	self._labels.gems = chip(row, "Gems", 1)
	self._labels.tokens = chip(row, "Tokens", 2)

	-- Top-center objective banner: title + detail on two lines, never covering the reticle.
	local banner = chip(stage, "Banner", 1)
	banner.AnchorPoint = Vector2.new(0.5, 0)
	banner.Position = UDim2.new(0.5, 0, 0, Tokens.layout.safeAreaPaddingPx)
	banner.Size = UDim2.fromOffset(0, Tokens.layout.minimumTapTargetPx + Tokens.typography.caption.size + Tokens.spacing.sm)
	banner.Font = Tokens.typography.heading.font
	banner.TextSize = Tokens.typography.heading.size
	banner.TextYAlignment = Enum.TextYAlignment.Top
	banner.Text = "Loading your nest..."
	local bannerPadding = banner:FindFirstChildOfClass("UIPadding") :: UIPadding
	bannerPadding.PaddingTop = UDim.new(0, Tokens.spacing.sm)
	self._labels.banner = banner
	local detail = Instance.new("TextLabel")
	detail.Name = "Detail"
	detail.AnchorPoint = Vector2.new(0.5, 1)
	detail.Position = UDim2.new(0.5, 0, 1, -Tokens.spacing.xs)
	detail.Size = UDim2.new(1, 0, 0, Tokens.typography.caption.size + 2)
	detail.BackgroundTransparency = 1
	detail.Font = Tokens.typography.caption.font
	detail.TextSize = Tokens.typography.caption.size
	detail.TextColor3 = Tokens.color.inkMuted
	detail.Text = ""
	detail.ZIndex = Tokens.zIndex.hud + 1
	detail.Parent = banner
	self._labels.detail = detail

	-- Bottom-right input prompt chip (swaps per input mode) and settings button.
	local prompt = chip(stage, "Prompt", 1)
	prompt.AnchorPoint = Vector2.new(1, 1)
	prompt.Position = UDim2.new(1, -Tokens.layout.safeAreaPaddingPx, 1, -Tokens.layout.safeAreaPaddingPx)
	prompt.Font = Tokens.typography.caption.font
	prompt.TextSize = Tokens.typography.caption.size
	self._labels.prompt = prompt

	local minimumTap = SafeArea.minimumTapTarget(gui, deps.config)
	local settingsButton, settingsCleanup = Button.create(stage, {
		text = "Settings",
		variant = "secondary",
		minimumTapTarget = minimumTap,
		motion = deps.accessibility:motionSettings(),
		onActivated = function()
			self:openSettings()
		end,
	})
	settingsButton.AnchorPoint = Vector2.new(1, 0)
	settingsButton.Position = UDim2.new(1, -Tokens.layout.safeAreaPaddingPx, 0, Tokens.layout.safeAreaPaddingPx)
	self._trove:add(settingsCleanup)

	-- Centre reticle (first-person aim aid), tiny and non-blocking.
	local reticle = Instance.new("Frame")
	reticle.Name = "Reticle"
	reticle.AnchorPoint = Vector2.new(0.5, 0.5)
	reticle.Position = UDim2.fromScale(0.5, 0.5)
	reticle.Size = UDim2.fromOffset(6, 6)
	reticle.BackgroundColor3 = Tokens.color.cream
	reticle.BackgroundTransparency = 0.2
	reticle.Visible = false
	local reticleCorner = Instance.new("UICorner")
	reticleCorner.CornerRadius = UDim.new(0, Tokens.radius.pill)
	reticleCorner.Parent = reticle
	reticle.Parent = stage
	self._labels.reticle = reticle
	-- The reticle sits on the true viewport centre (where the locked first-person mouse is and where
	-- the pick ray goes), not the centre of the inset-adjusted gui: this gui excludes the core UI
	-- inset, so its own centre would draw the dot below the aim point.
	local function placeReticle()
		local camera = workspace.CurrentCamera
		if not camera then
			return
		end
		if SafeArea.viewportOverride() then
			reticle.Position = UDim2.fromScale(0.5, 0.5)
			return
		end
		local inset = GuiService:GetGuiInset()
		local factor = SafeArea.scaleOf(stage)
		local viewport = camera.ViewportSize
		reticle.Position = UDim2.fromOffset((viewport.X * 0.5 - inset.X) / factor, (viewport.Y * 0.5 - inset.Y) / factor)
	end
	placeReticle()
	self._trove:add(stage:GetPropertyChangedSignal("AbsoluteSize"):Connect(placeReticle))
	self._trove:add(SafeArea.overrideChanged:Connect(placeReticle))
	self._trove:add(workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(placeReticle))
	if workspace.CurrentCamera then
		self._trove:add(workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(placeReticle))
	end

	self.toasts = Toast.new(stage, function()
		return deps.accessibility:motionSettings()
	end, function(tone)
		deps.audio:play(if tone == "danger" or tone == "warning" then Tokens.sound.uiError else Tokens.sound.uiToast)
	end)
	self._trove:add(self.toasts)
	self.round = RoundHud.new(stage, function()
		return deps.accessibility:motionSettings()
	end)
	self._trove:add(self.round)
	self.hotbar = ToolHotbar.new(stage, deps.config, function()
		return deps.accessibility:motionSettings()
	end, minimumTap, deps.input:mode())
	self._trove:add(self.hotbar)
	-- Carried feather stack: below the reticle, above the hotbar, hidden whenever a modal blocks.
	self.carriedStack = CarriedStack.new(stage, deps.config, function()
		return deps.accessibility:motionSettings()
	end, function()
		return Tokens.layout.safeAreaPaddingPx + Tokens.layout.minimumTapTargetPx + Tokens.spacing.md + Tokens.spacing.md
	end)
	self._trove:add(self.carriedStack)
	self._trove:add(deps.modals.changed:Connect(function()
		self.carriedStack:setHiddenByUi(deps.modals:isBlocking())
	end))
	self._trove:add(deps.input.modeChanged:Connect(function(mode)
		self.hotbar:setMode(mode)
	end))

	-- Bindings.
	-- Currency chips count up only from acknowledged projections (never from client prediction).
	local chipNames = { gems = "Gems", eventTokens = "Tokens" }
	local chipLabels = { gems = self._labels.gems, eventTokens = self._labels.tokens }
	for key, label in pairs(chipLabels) do
		self._chipScales[key] = label:FindFirstChildOfClass("UIScale") :: UIScale
	end
	local function refreshProfile(projection)
		if not projection then
			return
		end
		for key, label in pairs(chipLabels) do
			local target = projection.currencies[key] or 0
			local previous = self._displayed[key]
			if previous == nil or previous == target then
				self._displayed[key] = target
				label.Text = string.format("%s  %d", chipNames[key], target)
			else
				local motion = deps.accessibility:motionSettings()
				Tween.countUp(previous, target, motion, function(value)
					label.Text = string.format("%s  %d", chipNames[key], value)
				end)
				self._displayed[key] = target
				if target > previous then
					local scale = self._chipScales[key]
					scale.Scale = 1.12
					Tween.scale(scale, "release", motion, 1)
				end
			end
		end
	end
	refreshProfile(deps.profile.projection)
	self._trove:add(deps.profile.changed:Connect(refreshProfile))

	local function refreshPrompt(mode)
		local prompts = Tokens.prompts[mode]
		prompt.Text = string.format("%s  Gather   %s  Interact", prompts.primary, prompts.interact)
	end
	refreshPrompt(deps.input:mode())
	self._trove:add(deps.input.modeChanged:Connect(refreshPrompt))

	self._trove:add(deps.net:on("Toast", function(payload)
		self.toasts:push(payload.key, payload.tone)
	end))
	return self
end

-- Wires the round controller (called by bootstrap once it exists).
function HUDController.bindRound(self: HUDController, round: any, interaction: any)
	local deps = self._deps
	self._trove:add(round.phaseChanged:Connect(function(phase)
		local inRound = phase == "Cutscene"
			or phase == "Countdown"
			or phase == "Searching"
			or phase == "EggRevealed"
			or phase == "Victory"
			or phase == "CommittingRewards"
			or phase == "Results"
		self.round:setVisible(inRound)
		self._labels.reticle.Visible = phase == "Searching" or phase == "EggRevealed"
		self.carriedStack:setVisible(phase == "Searching" or phase == "EggRevealed")
		if inRound and not self._timerConnection then
			self._timerConnection = RunService.RenderStepped:Connect(function()
				self.round:setTimer(round:elapsedMs())
				local remaining = round:countdownRemaining()
				if remaining then
					self:setObjective(string.format("Get ready... %d", math.ceil(remaining)), "The nest opens in a moment")
				end
			end)
			self._trove:add(self._timerConnection)
		elseif not inRound and self._timerConnection then
			self._timerConnection:Disconnect()
			self._timerConnection = nil
		end
		if phase == "Cutscene" then
			self:setObjective("Sunlit Henhouse", "Story")
		end
	end))
	self._trove:add(round.playerChanged:Connect(function(player)
		-- Capacity comes from the server projection (entitlements + class + level); config level is the fallback.
		local capacity = player.bagCapacity or deps.config.bags.levels[player.bagLevel].capacity
		if player.bagInfinite ~= nil then
			self._infiniteBag = player.bagInfinite == true
		end
		self.round:setBag(player.carriedStandard + player.carriedRainbow, capacity, self._infiniteBag == true, false)
		self.carriedStack:setBag(player.carriedStandard + player.carriedRainbow, capacity, self._infiniteBag == true, false)
		self.round:setCash(player.cashCents, false)
	end))
	self._trove:add(round.sale:Connect(function(sale)
		self.round:setBag(0, deps.config.bags.levels[(round.player and round.player.bagLevel) or 1].capacity, false, true)
		self.carriedStack:clear()
		deps.audio:play(Tokens.sound.sellArc)
		self.round:setCash(sale.cashCents, true, function()
			deps.audio:play(Tokens.sound.sellTick, { pitchVariance = 0.05 })
		end)
		if sale.finalCents >= 100 then
			deps.audio:play(Tokens.sound.sellBurst)
		end
		self.toasts:push(
			string.format("Traded %d feathers for %s", sale.standardCount + sale.rainbowCount, EconomyMath.formatCents(sale.finalCents)),
			"success"
		)
	end))
	self._trove:add(round.upgrade:Connect(function(result)
		if result.paidCents then
			self.round:setCash(result.cashCents, true)
		end
	end))
	self._trove:add(interaction.openUpgrades:Connect(function()
		self:openUpgrades(round)
	end))
end

-- Reward celebration after a server-acknowledged grant (RewardGranted): rotation punch on the chip.
function HUDController.celebrateCurrency(self: HUDController, key: string, amount: number)
	local label = if key == "gems" then self._labels.gems else self._labels.tokens
	if not label or amount <= 0 then
		return
	end
	Tween.rotationPunch(label, self._deps.accessibility:motionSettings(), 0)
end

-- Called by ToolController on each accepted award for the bag squash.
function HUDController.onCollected(self: HUDController, data: { [string]: any })
	self._infiniteBag = data.infinite == true
	self.round:setBag(data.carried, data.capacity, data.infinite == true, true)
	self.carriedStack:setBag(data.carried, data.capacity, data.infinite == true, true)
	self.carriedStack:pulse()
end

-- World point a couple of studs in front of the camera at the carried stack's screen position: the
-- destination of a picked feather's flight. Nil without a camera.
function HUDController.carriedStackWorldPoint(self: HUDController): Vector3?
	local camera = workspace.CurrentCamera
	if not camera or not self.carriedStack.frame.Visible then
		return nil
	end
	local centre = self.carriedStack:screenCentre()
	local ray = camera:ViewportPointToRay(centre.X, centre.Y + self.gui.AbsolutePosition.Y, 0)
	return ray.Origin + ray.Direction.Unit * 2.2
end

function HUDController.setObjective(self: HUDController, title: string, detail: string?)
	self._labels.banner.Text = title
	self._labels.detail.Text = detail or ""
end

function HUDController.openUpgrades(self: HUDController, round: any)
	local deps = self._deps
	return deps.modals:open("upgrades", deps.modals.Priority.Shop, true, function(container, api)
		return UpgradeModal.build(container, api, {
			net = deps.net,
			round = round,
			audio = deps.audio,
			haptics = deps.haptics,
			accessibility = deps.accessibility,
			config = deps.config,
			minimumTapTarget = SafeArea.minimumTapTarget(deps.modals.gui, deps.config),
			toasts = self.toasts,
			profile = deps.profile,
		})
	end, "Workbench")
end

-- Settings modal: four toggles + quality selector, each round-tripped through SettingsUpdate.
function HUDController.openSettings(self: HUDController)
	local deps = self._deps
	local opened = deps.modals:open("settings", deps.modals.Priority.Shop, true, function(container, api)
		local cleanups: { any } = {}
		local settings = deps.profile:settings() or {}
		local minimumTap = api.minimumTapTarget or SafeArea.minimumTapTarget(deps.modals.gui, deps.config)
		local intro = FrameKit.text(container, "Intro", "Comfort settings save to your profile right away.", "caption", {
			zIndex = container.ZIndex + 1,
			color = Tokens.color.inkMuted,
		})
		intro.LayoutOrder = 0
		local function toggle(order: number, key: string, labelText: string)
			local current = settings[key] == true
			local button, cleanup = Button.create(container, {
				text = string.format("%s: %s", labelText, current and "On" or "Off"),
				variant = "ghost",
				minimumTapTarget = minimumTap,
				motion = deps.accessibility:motionSettings(),
				size = UDim2.new(1, 0, 0, minimumTap),
			})
			button.LayoutOrder = order
			table.insert(cleanups, cleanup)
			table.insert(
				cleanups,
				button.Activated:Connect(function()
					current = not current
					local result = deps.net:request("SettingsUpdate", { [key] = current })
					if result.ok then
						button.Text = string.format("%s: %s", labelText, current and "On" or "Off")
						deps.audio:play(Tokens.sound.uiConfirm)
					else
						current = not current
						self.toasts:push("Could not save setting", "warning")
						deps.audio:play(Tokens.sound.uiError)
					end
				end)
			)
		end
		toggle(1, "reducedMotion", "Reduced motion")
		toggle(2, "cameraShake", "Camera shake")
		toggle(3, "haptics", "Haptics")

		local modes = { "auto", "low", "medium", "high" }
		local modeIndex = table.find(modes, settings.qualityMode or "auto") or 1
		local qualityButton, qualityCleanup = Button.create(container, {
			text = "Quality: " .. modes[modeIndex],
			variant = "ghost",
			minimumTapTarget = minimumTap,
			motion = deps.accessibility:motionSettings(),
			size = UDim2.new(1, 0, 0, minimumTap),
		})
		qualityButton.LayoutOrder = 4
		table.insert(cleanups, qualityCleanup)
		table.insert(
			cleanups,
			qualityButton.Activated:Connect(function()
				modeIndex = modeIndex % #modes + 1
				local result = deps.net:request("SettingsUpdate", { qualityMode = modes[modeIndex] })
				if result.ok then
					qualityButton.Text = "Quality: " .. modes[modeIndex]
					deps.audio:play(Tokens.sound.uiConfirm)
				end
			end)
		)

		local doneButton, doneCleanup = Button.create(container, {
			text = "Done",
			variant = "primary",
			minimumTapTarget = minimumTap,
			motion = deps.accessibility:motionSettings(),
			size = UDim2.new(1, 0, 0, minimumTap),
			onActivated = api.close,
		})
		doneButton.LayoutOrder = 5
		table.insert(cleanups, doneCleanup)
		deps.audio:play(Tokens.sound.uiOpen)
		return function()
			for _, cleanup in ipairs(cleanups) do
				if typeof(cleanup) == "RBXScriptConnection" then
					cleanup:Disconnect()
				else
					cleanup()
				end
			end
			deps.audio:play(Tokens.sound.uiClose)
		end
	end, "Settings")
	return opened
end

function HUDController.destroy(self: HUDController)
	self._trove:destroy()
end

return HUDController
