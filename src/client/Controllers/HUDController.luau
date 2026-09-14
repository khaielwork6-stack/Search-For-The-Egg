--!strict
-- HUD: currency chips bound to the profile projection, objective banner (title + detail), input
-- prompt chip that swaps by input mode, settings modal round trip, toast queue, and the round strip
-- (bag meter / cash / timer) that appears only during rounds. Sale and upgrade feedback land here.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")
local GuiService = game:GetService("GuiService")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local Motion = require(Shared.Design.Motion)
local Trove = require(Shared.Util.Trove)
local SafeArea = require(script.Parent.Parent.UI.SafeArea)
local Button = require(script.Parent.Parent.UI.Components.Button)
local Toast = require(script.Parent.Parent.UI.Components.Toast)
local RoundHud = require(script.Parent.Parent.UI.RoundHud)
local CarriedStack = require(script.Parent.Parent.UI.CarriedStack)
local ToolHotbar = require(script.Parent.Parent.UI.ToolHotbar)
local UpgradeModal = require(script.Parent.Parent.UI.UpgradeModal)
local Tween = require(script.Parent.Parent.UI.Components.Tween)
local FrameKit = require(script.Parent.Parent.UI.Components.Frame)
local Icons = require(script.Parent.Parent.UI.Components.Icons)
local Skin = require(script.Parent.Parent.UI.Components.Skin)
local SalePopup = require(script.Parent.Parent.UI.SalePopup)
local SettingsModal = require(script.Parent.Parent.UI.Modals.SettingsModal)

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
		_bannerScale: UIScale?,
		_reticleArt: ImageLabel?,
		_reticleScale: UIScale,
		_holdRing: GuiObject?,
		_targeting: boolean?,
		_veil: Frame?,
		_dropVeil: (() -> ())?,
		_trove: Trove.Trove,
	},
	HUDController
))

function HUDController.new(deps: any): HUDController
	local gui = Instance.new("ScreenGui")
	gui.Name = "SFE_HUD"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = Tokens.zIndex.hud
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = deps.parent or Players.LocalPlayer:WaitForChild("PlayerGui")
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
		_bannerScale = nil,
		_reticleArt = nil,
		_reticleScale = nil :: any,
		_holdRing = nil,
		_targeting = false,
		_veil = nil,
		_dropVeil = nil,
		_trove = Trove.new(),
	}, HUDController)
	self._trove:add(gui)
	self._trove:add(scaleCleanup)

	-- Top-left currency row: art chips with a gem / token glyph and a live count.
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
	local function currencyChip(name: string, order: number, iconRole: string, fallback: string): TextLabel
		local frame, label, iconSlot = FrameKit.chip(row, name, { zIndex = Tokens.zIndex.hud })
		frame.LayoutOrder = order
		iconSlot.Visible = true
		local art = Skin.icon(iconSlot, iconRole, Tokens.icon.md, frame.ZIndex + 2)
		if not art then
			Icons.build(fallback, iconSlot, Tokens.icon.md, { zIndex = frame.ZIndex + 2 })
		end
		label.Text = "0"
		label.Font = Tokens.typography.numeral.font
		label.TextSize = Tokens.typography.numeral.size - 2
		return label
	end
	self._labels.gems = currencyChip("Gems", 1, "hud.gem", "gem")
	self._labels.tokens = currencyChip("Tokens", 2, "hud.token", "coin")

	-- Top-center objective banner: art frame, title + detail on two lines, never over the reticle.
	local banner = Instance.new("Frame")
	banner.Name = "Banner"
	banner.AnchorPoint = Vector2.new(0.5, 0)
	banner.Position = UDim2.new(0.5, 0, 0, Tokens.layout.safeAreaPaddingPx)
	local bannerHeight = Tokens.layout.minimumTapTargetPx + Tokens.typography.caption.size + Tokens.spacing.xl
	banner.Size = UDim2.fromOffset(240, bannerHeight)
	banner.BackgroundColor3 = Tokens.color.featherWhite
	banner.ZIndex = Tokens.zIndex.hud
	local bannerCorner = Instance.new("UICorner")
	bannerCorner.CornerRadius = UDim.new(0, Tokens.radius.lg)
	bannerCorner.Parent = banner
	local bannerStroke = Instance.new("UIStroke")
	bannerStroke.Thickness = Tokens.stroke.bold
	bannerStroke.Color = Tokens.color.outline
	bannerStroke.Parent = banner
	local bannerScale = Instance.new("UIScale")
	bannerScale.Parent = banner
	FrameKit.shadow(banner, { radius = Tokens.radius.lg })
	banner.Parent = stage
	if Skin.label(banner, "hud.banner", { zIndex = banner.ZIndex + 1, inset = 3, name = "ArtFrame" }) then
		bannerStroke.Enabled = false
		banner.BackgroundTransparency = 1
		local shadowFrame = banner:FindFirstChild("Shadow")
		local halo = banner:FindFirstChild("Halo")
		if shadowFrame then
			shadowFrame.Visible = false
		end
		if halo then
			halo.Visible = false
		end
	end
	-- Text lives in a padded content child so the art frame keeps the banner's full size.
	local bannerContent = Instance.new("Frame")
	bannerContent.Name = "Content"
	bannerContent.Size = UDim2.fromScale(1, 1)
	bannerContent.BackgroundTransparency = 1
	bannerContent.ZIndex = banner.ZIndex + 2
	bannerContent.Parent = banner
	local bannerPadding = Instance.new("UIPadding")
	bannerPadding.PaddingLeft = UDim.new(0, Tokens.spacing.xxl)
	bannerPadding.PaddingRight = UDim.new(0, Tokens.spacing.xxl)
	bannerPadding.PaddingTop = UDim.new(0, Tokens.spacing.md)
	bannerPadding.PaddingBottom = UDim.new(0, Tokens.spacing.md)
	bannerPadding.Parent = bannerContent
	local bannerTitle = Instance.new("TextLabel")
	bannerTitle.Name = "Text"
	bannerTitle.Size = UDim2.new(1, 0, 0, Tokens.typography.heading.size + Tokens.spacing.xs)
	bannerTitle.BackgroundTransparency = 1
	bannerTitle.Font = Tokens.typography.label.font
	bannerTitle.TextSize = Tokens.typography.label.size + 1
	bannerTitle.TextColor3 = Tokens.color.inkStrong
	bannerTitle.Text = "Loading your nest..."
	bannerTitle.ZIndex = banner.ZIndex + 3
	bannerTitle.Parent = bannerContent
	self._labels.banner = bannerTitle
	local detail = Instance.new("TextLabel")
	detail.Name = "Detail"
	detail.AnchorPoint = Vector2.new(0.5, 1)
	detail.Position = UDim2.fromScale(0.5, 1)
	detail.Size = UDim2.new(1, 0, 0, Tokens.typography.caption.size + 2)
	detail.BackgroundTransparency = 1
	detail.Font = Tokens.typography.caption.font
	detail.TextSize = Tokens.typography.caption.size
	detail.TextColor3 = Tokens.color.inkMuted
	detail.Text = ""
	detail.ZIndex = banner.ZIndex + 3
	detail.Parent = bannerContent
	self._labels.detail = detail
	self._bannerScale = bannerScale
	-- Banner width follows the longer of its two lines (never AutomaticSize: the art and shadow
	-- children are scale-sized and would feed back into it).
	local function fitBanner()
		local widest = math.max(bannerTitle.TextBounds.X, detail.TextBounds.X)
		local pad = bannerPadding.PaddingLeft.Offset + bannerPadding.PaddingRight.Offset
		banner.Size = UDim2.fromOffset(math.max(240, math.ceil(widest) + pad), bannerHeight)
	end
	bannerTitle:GetPropertyChangedSignal("TextBounds"):Connect(fitBanner)
	detail:GetPropertyChangedSignal("TextBounds"):Connect(fitBanner)
	fitBanner()

	-- Bottom-right input prompt: keycaps + verbs, swapped per input mode.
	local prompt = Instance.new("Frame")
	prompt.Name = "Prompt"
	prompt.AnchorPoint = Vector2.new(1, 1)
	prompt.Position = UDim2.new(1, -Tokens.layout.safeAreaPaddingPx, 1, -Tokens.layout.safeAreaPaddingPx)
	prompt.Size = UDim2.fromOffset(0, Tokens.layout.minimumTapTargetPx - Tokens.spacing.sm)
	prompt.AutomaticSize = Enum.AutomaticSize.X
	prompt.BackgroundColor3 = Tokens.color.featherWhite
	prompt.BackgroundTransparency = 0.15
	prompt.ZIndex = Tokens.zIndex.hud
	local promptCorner = Instance.new("UICorner")
	promptCorner.CornerRadius = UDim.new(0, Tokens.radius.pill)
	promptCorner.Parent = prompt
	local promptStroke = Instance.new("UIStroke")
	promptStroke.Thickness = Tokens.stroke.standard
	promptStroke.Color = Tokens.color.outline
	promptStroke.Transparency = 0.2
	promptStroke.Parent = prompt
	local promptLayout = Instance.new("UIListLayout")
	promptLayout.FillDirection = Enum.FillDirection.Horizontal
	promptLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	promptLayout.SortOrder = Enum.SortOrder.LayoutOrder
	promptLayout.Padding = UDim.new(0, Tokens.spacing.sm)
	promptLayout.Parent = prompt
	local promptPadding = Instance.new("UIPadding")
	promptPadding.PaddingLeft = UDim.new(0, Tokens.spacing.md)
	promptPadding.PaddingRight = UDim.new(0, Tokens.spacing.md)
	promptPadding.Parent = prompt
	prompt.Parent = stage
	self._labels.prompt = prompt
	local function promptItem(order: number, key: string, verb: string)
		local cap = Icons.keycap(prompt, key, Tokens.icon.md, { zIndex = prompt.ZIndex + 1 })
		cap.LayoutOrder = order
		local label = Instance.new("TextLabel")
		label.Name = "Verb_" .. verb
		label.LayoutOrder = order + 1
		label.AutomaticSize = Enum.AutomaticSize.X
		label.Size = UDim2.fromOffset(0, Tokens.icon.md)
		label.BackgroundTransparency = 1
		label.Font = Tokens.typography.heading.font
		label.TextSize = Tokens.typography.caption.size
		label.TextColor3 = Tokens.color.inkStrong
		label.Text = verb
		label.ZIndex = prompt.ZIndex + 1
		label.Parent = prompt
	end
	local function refreshPrompt(mode)
		for _, child in ipairs(prompt:GetChildren()) do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
		local prompts = Tokens.prompts[mode]
		promptItem(1, prompts.primary, "Gather")
		promptItem(3, prompts.interact, "Interact")
		prompt.Visible = mode ~= "touch"
	end

	-- Settings: round gear button, top-right.
	local minimumTap = SafeArea.minimumTapTarget(gui, deps.config)
	local settingsHandle = Button.build(stage, {
		text = "Settings",
		variant = "secondary",
		art = false,
		round = true,
		minimumTapTarget = minimumTap,
		motion = deps.accessibility:motionSettings(),
		size = UDim2.fromOffset(minimumTap, minimumTap),
		zIndex = Tokens.zIndex.hud,
		sound = function()
			deps.audio:play(Tokens.sound.uiTap)
		end,
		hoverSound = function()
			deps.audio:play(Tokens.sound.uiHover)
		end,
		onActivated = function()
			self:openSettings()
		end,
	})
	local settingsButton = settingsHandle.button
	settingsButton.Name = "Button_Settings"
	settingsButton.Text = ""
	settingsButton.AnchorPoint = Vector2.new(1, 0)
	settingsButton.Position = UDim2.new(1, -Tokens.layout.safeAreaPaddingPx, 0, Tokens.layout.safeAreaPaddingPx)
	local gear = Skin.icon(settingsButton, "hud.gear", Tokens.icon.md + 2, settingsButton.ZIndex + 3)
		or Icons.gear(settingsButton, Tokens.icon.md + 2, { zIndex = settingsButton.ZIndex + 3 })
	gear.AnchorPoint = Vector2.new(0.5, 0.5)
	gear.Position = UDim2.fromScale(0.5, 0.5)
	self._trove:add(settingsHandle.destroy)

	-- Centre reticle: art dot, a locked variant while a feather is targeted, and a hold ring.
	local reticle = Instance.new("Frame")
	reticle.Name = "Reticle"
	reticle.AnchorPoint = Vector2.new(0.5, 0.5)
	reticle.Position = UDim2.fromScale(0.5, 0.5)
	reticle.Size = UDim2.fromOffset(12, 12)
	reticle.BackgroundColor3 = Tokens.color.cream
	reticle.BackgroundTransparency = 0.2
	reticle.Visible = false
	reticle.ZIndex = Tokens.zIndex.hud
	local reticleCorner = Instance.new("UICorner")
	reticleCorner.CornerRadius = UDim.new(0, Tokens.radius.pill)
	reticleCorner.Parent = reticle
	local reticleScale = Instance.new("UIScale")
	reticleScale.Parent = reticle
	local reticleArt = Skin.label(reticle, "hud.reticle", { zIndex = reticle.ZIndex + 1, name = "Art" })
	if reticleArt then
		reticle.BackgroundTransparency = 1
	end
	local holdRing = Skin.icon(reticle, "prompt.holdRing", 34, reticle.ZIndex + 2)
	if not holdRing then
		local ring = Instance.new("Frame")
		ring.Name = "HoldRing"
		ring.BackgroundTransparency = 1
		ring.Size = UDim2.fromOffset(34, 34)
		local ringStroke = Instance.new("UIStroke")
		ringStroke.Thickness = 3
		ringStroke.Color = Tokens.color.gold
		ringStroke.Parent = ring
		local ringCorner = Instance.new("UICorner")
		ringCorner.CornerRadius = UDim.new(1, 0)
		ringCorner.Parent = ring
		ring.ZIndex = reticle.ZIndex + 2
		ring.Parent = reticle
		holdRing = ring :: any
	end
	local ring = holdRing :: GuiObject
	ring.Name = "HoldRing"
	ring.AnchorPoint = Vector2.new(0.5, 0.5)
	ring.Position = UDim2.fromScale(0.5, 0.5)
	ring.Visible = false
	reticle.Parent = stage
	self._labels.reticle = reticle
	self._reticleArt = reticleArt
	self._reticleScale = reticleScale
	self._holdRing = ring
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

	-- Loading veil: cream curtain with the game name and three bobbing eggs until the profile lands.
	local veil = Instance.new("Frame")
	veil.Name = "LoadingVeil"
	veil.Size = UDim2.fromScale(1, 1)
	veil.Position = UDim2.fromOffset(-64, -64)
	veil.Size = UDim2.new(1, 128, 1, 128)
	veil.BackgroundColor3 = Tokens.color.cream
	veil.ZIndex = Tokens.zIndex.veil
	local veilGradient = Instance.new("UIGradient")
	veilGradient.Rotation = 90
	veilGradient.Color =
		ColorSequence.new({ ColorSequenceKeypoint.new(0, Tokens.color.featherWhite), ColorSequenceKeypoint.new(1, Tokens.color.creamDeep) })
	veilGradient.Parent = veil
	local veilTitle = FrameKit.pill(veil, "Title", "Search for the Egg", {
		size = UDim2.fromOffset(0, Tokens.layout.minimumTapTargetPx + Tokens.spacing.md),
		textSize = Tokens.typography.display.size,
		zIndex = veil.ZIndex + 1,
		fitText = true,
	})
	veilTitle.AnchorPoint = Vector2.new(0.5, 0.5)
	veilTitle.Position = UDim2.fromScale(0.5, 0.44)
	veilTitle.TextXAlignment = Enum.TextXAlignment.Center
	local veilNote = FrameKit.text(
		veil,
		"Note",
		"Loading your nest...",
		"heading",
		{ zIndex = veil.ZIndex + 1, align = Enum.TextXAlignment.Center, color = Tokens.color.inkMuted }
	)
	veilNote.AnchorPoint = Vector2.new(0.5, 0)
	veilNote.Position = UDim2.fromScale(0.5, 0.52)
	veilNote.Size = UDim2.new(0.6, 0, 0, Tokens.typography.heading.size + Tokens.spacing.sm)
	local eggs = {}
	for index = 1, 3 do
		local egg = Skin.icon(veil, "icon.egg", Tokens.icon.lg, veil.ZIndex + 1)
			or Icons.egg(veil, Tokens.icon.lg, { zIndex = veil.ZIndex + 1 })
		egg.AnchorPoint = Vector2.new(0.5, 0.5)
		egg.Position = UDim2.new(0.5, (index - 2) * (Tokens.icon.lg + Tokens.spacing.md), 0.6, 0)
		table.insert(eggs, egg)
	end
	veil.Parent = stage
	self._veil = veil
	local veilAlive = true
	task.spawn(function()
		local phase = 0
		while veilAlive and veil.Parent do
			phase += RunService.RenderStepped:Wait() * 4
			for index, egg in ipairs(eggs) do
				egg.Position =
					UDim2.new(0.5, (index - 2) * (Tokens.icon.lg + Tokens.spacing.md), 0.6, -math.abs(math.sin(phase + index * 0.9)) * 10)
			end
		end
	end)
	local function dropVeil()
		if not veilAlive then
			return
		end
		veilAlive = false
		local motion = deps.accessibility:motionSettings()
		local fade = TweenService:Create(
			veil,
			TweenInfo.new(Motion.duration("slow", motion), Tokens.motion.easeInOut),
			{ BackgroundTransparency = 1 }
		)
		for _, child in ipairs(veil:GetDescendants()) do
			if child:IsA("TextLabel") then
				TweenService:Create(
					child,
					TweenInfo.new(Motion.duration("quick", motion)),
					{ TextTransparency = 1, TextStrokeTransparency = 1, BackgroundTransparency = 1 }
				):Play()
			elseif child:IsA("ImageLabel") then
				TweenService:Create(child, TweenInfo.new(Motion.duration("quick", motion)), { ImageTransparency = 1 }):Play()
			elseif child:IsA("Frame") and child.Name ~= "Shadow" and child.Name ~= "Halo" then
				TweenService:Create(child, TweenInfo.new(Motion.duration("quick", motion)), { BackgroundTransparency = 1 }):Play()
			elseif child:IsA("UIStroke") then
				TweenService:Create(child, TweenInfo.new(Motion.duration("quick", motion)), { Transparency = 1 }):Play()
			end
		end
		fade:Play()
		fade.Completed:Once(function()
			veil:Destroy()
		end)
	end
	self._dropVeil = dropVeil
	if deps.profile.projection then
		task.delay(0.6, dropVeil)
	else
		local once
		once = deps.profile.changed:Connect(function()
			once:Disconnect()
			task.delay(0.4, dropVeil)
		end)
		self._trove:add(once)
	end
	task.delay(12, dropVeil)

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
	self.hotbar = ToolHotbar.new(
		stage,
		deps.config,
		function()
			return deps.accessibility:motionSettings()
		end,
		minimumTap,
		deps.input:mode(),
		function(role)
			deps.audio:play(role)
		end
	)
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
				label.Text = tostring(target)
			else
				local motion = deps.accessibility:motionSettings()
				Tween.countUp(previous, target, motion, function(value)
					label.Text = tostring(value)
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
		self.hotbar:setVisible(phase == "Cutscene" or phase == "Countdown" or phase == "Searching" or phase == "EggRevealed")
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
		SalePopup.show(self.stage, {
			feathers = sale.standardCount + sale.rainbowCount,
			cents = sale.finalCents,
			motion = deps.accessibility:motionSettings(),
			tier = if deps.quality then deps.quality:tier() else nil,
		})
		deps.audio:play(Tokens.sound.uiConfetti)
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
	local changed = self._labels.banner.Text ~= title
	self._labels.banner.Text = title
	self._labels.detail.Text = detail or ""
	if changed and self._bannerScale and not string.find(title, "^Get ready") then
		self._bannerScale.Scale = 1 + Motion.amplitude(0.06, self._deps.accessibility:motionSettings())
		TweenService:Create(
			self._bannerScale,
			TweenInfo.new(Motion.duration("standard", self._deps.accessibility:motionSettings()), Tokens.motion.easeBack),
			{ Scale = 1 }
		):Play()
	end
end

-- Targeting state from the pile: the reticle swaps to its locked art and grows a touch while a
-- feather is under the crosshair.
function HUDController.setTargeting(self: HUDController, targeting: boolean)
	if self._targeting == targeting then
		return
	end
	self._targeting = targeting
	if self._reticleArt then
		Skin.apply(self._reticleArt, if targeting then "hud.reticle.locked" else "hud.reticle")
	else
		self._labels.reticle.BackgroundColor3 = if targeting then Tokens.color.gold else Tokens.color.cream
	end
	local motion = self._deps.accessibility:motionSettings()
	TweenService:Create(
		self._reticleScale,
		TweenInfo.new(Motion.duration("quick", motion), Tokens.motion.easeBack),
		{ Scale = if targeting then 1.35 else 1 }
	):Play()
end

-- Hold-to-gather progress around the reticle: the ring closes in as the next pull readies.
function HUDController.setHold(self: HUDController, active: boolean, fraction: number?)
	local ring = self._holdRing
	if not ring then
		return
	end
	ring.Visible = active
	if active then
		local f = math.clamp(fraction or 0, 0, 1)
		local size = math.floor(34 + (1 - f) * 22)
		ring.Size = UDim2.fromOffset(size, size)
		if ring:IsA("ImageLabel") then
			ring.ImageTransparency = 0.6 - f * 0.5
		end
	end
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
	end, "Workbench", { icon = "header.workbench" })
end

-- Settings modal (UI/Modals/SettingsModal): switches, quality tabs, Done.
function HUDController.openSettings(self: HUDController)
	local deps = self._deps
	return deps.modals:open("settings", deps.modals.Priority.Shop, true, function(container, api)
		return SettingsModal.build(container, api, {
			net = deps.net,
			profile = deps.profile,
			audio = deps.audio,
			accessibility = deps.accessibility,
			config = deps.config,
			minimumTapTarget = api.minimumTapTarget or SafeArea.minimumTapTarget(deps.modals.gui, deps.config),
			toasts = self.toasts,
		})
	end, "Settings", { icon = "header.settings" })
end

function HUDController.destroy(self: HUDController)
	self._trove:destroy()
end

return HUDController
