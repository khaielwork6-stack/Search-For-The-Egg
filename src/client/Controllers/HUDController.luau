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
		_currencyHolds: { [string]: number },
		_pendingCurrency: { [string]: number },
		_promptWanted: boolean,
		_bookOpener: (() -> ())?,
		_infiniteBag: boolean?,
		_timerConnection: RBXScriptConnection?,
		_bannerScale: UIScale?,
		_reticleArt: ImageLabel?,
		_reticleScale: UIScale,
		_bagHolds: number,
		_pendingBag: { standard: number, rainbow: number, capacity: number }?,
		_heatFill: Frame?,
		_heatFlame: UIScale?,
		_heatGradient: UIGradient?,
		_rodHeat: number?,
		_heatLabel: TextLabel?,
		_heatState: string?,
		_gemShopOpener: (() -> ())?,
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
		_currencyHolds = {},
		_pendingCurrency = {},
		_promptWanted = false,
		_bookOpener = nil,
		_timerConnection = nil,
		_bannerScale = nil,
		_reticleArt = nil,
		_reticleScale = nil :: any,
		_bagHolds = 0,
		_pendingBag = nil,
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
		label.Font = Tokens.typography.label.font
		label.TextSize = Tokens.typography.label.size + 1
		FrameKit.outline(label, 1.4, Tokens.color.featherWhite)
		return label
	end
	self._labels.gems = currencyChip("Gems", 1, "hud.gem", "gem")
	-- "+" beside the Gems chip opens the Gem Shop (the lobby registers the opener).
	local plusHandle = Button.build(row, {
		text = "+",
		variant = "success",
		round = true,
		minimumTapTarget = SafeArea.minimumTapTarget(gui, deps.config),
		motion = deps.accessibility:motionSettings(),
		size = UDim2.fromOffset(Tokens.layout.minimumTapTargetPx - 10, Tokens.layout.minimumTapTargetPx - 10),
		zIndex = Tokens.zIndex.hud + 1,
		textSize = Tokens.typography.title.size,
		sound = function()
			deps.audio:play(Tokens.sound.uiTap)
		end,
		hoverSound = function()
			deps.audio:play(Tokens.sound.uiHover)
		end,
		onActivated = function()
			if self._gemShopOpener then
				self._gemShopOpener()
			end
		end,
	})
	plusHandle.button.Name = "GemPlus"
	plusHandle.button.LayoutOrder = 2
	plusHandle.button.Visible = false
	self._labels.gemPlus = plusHandle.button
	self._trove:add(plusHandle.destroy)
	self._labels.tokens = currencyChip("Tokens", 3, "hud.token", "coin")

	-- Top-center objective ribbon: gold band with the outlined objective, cream tail with the detail.
	local bannerHeight = Tokens.layout.minimumTapTargetPx + Tokens.typography.caption.size + Tokens.spacing.lg
	local banner = Instance.new("Frame")
	banner.Name = "Banner"
	banner.AnchorPoint = Vector2.new(0.5, 0)
	banner.Position = UDim2.new(0.5, 0, 0, Tokens.layout.safeAreaPaddingPx)
	banner.Size = UDim2.fromOffset(280, bannerHeight)
	banner.BackgroundColor3 = Tokens.color.goldDeep
	banner.ZIndex = Tokens.zIndex.hud
	local bannerCorner = Instance.new("UICorner")
	bannerCorner.CornerRadius = UDim.new(0, Tokens.radius.lg)
	bannerCorner.Parent = banner
	local bannerStroke = Instance.new("UIStroke")
	bannerStroke.Thickness = Tokens.stroke.bold
	bannerStroke.Color = Tokens.color.outline
	bannerStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	bannerStroke.Parent = banner
	local bannerScale = Instance.new("UIScale")
	bannerScale.Parent = banner
	banner.Parent = stage
	local bannerFace = Instance.new("Frame")
	bannerFace.Name = "Face"
	bannerFace.Size = UDim2.new(1, 0, 1, -4)
	bannerFace.BackgroundColor3 = Tokens.color.panel
	bannerFace.BorderSizePixel = 0
	bannerFace.ZIndex = banner.ZIndex + 1
	local bannerFaceCorner = Instance.new("UICorner")
	bannerFaceCorner.CornerRadius = UDim.new(0, Tokens.radius.lg)
	bannerFaceCorner.Parent = bannerFace
	bannerFace.Parent = banner
	local bannerBand, bannerTitle = FrameKit.headerBand(
		bannerFace,
		"Band",
		"Loading your nest...",
		{ height = Tokens.layout.minimumTapTargetPx, zIndex = banner.ZIndex + 2, radius = Tokens.radius.lg }
	)
	bannerTitle.TextSize = Tokens.typography.label.size + 2
	local _ = bannerBand
	local bannerContent = Instance.new("Frame")
	bannerContent.Name = "Content"
	bannerContent.Size = UDim2.fromScale(1, 1)
	bannerContent.BackgroundTransparency = 1
	bannerContent.ZIndex = banner.ZIndex + 2
	bannerContent.Parent = bannerFace
	local bannerPadding = Instance.new("UIPadding")
	bannerPadding.PaddingLeft = UDim.new(0, Tokens.spacing.lg)
	bannerPadding.PaddingRight = UDim.new(0, Tokens.spacing.lg)
	bannerPadding.PaddingBottom = UDim.new(0, Tokens.spacing.xs + 1)
	bannerPadding.Parent = bannerContent
	self._labels.banner = bannerTitle
	local detail = Instance.new("TextLabel")
	detail.Name = "Detail"
	detail.AnchorPoint = Vector2.new(0.5, 1)
	detail.Position = UDim2.fromScale(0.5, 1)
	detail.Size = UDim2.new(1, 0, 0, Tokens.typography.caption.size + 4)
	detail.BackgroundTransparency = 1
	detail.Font = Tokens.typography.body.font
	detail.TextSize = Tokens.typography.caption.size
	detail.TextColor3 = Tokens.color.ink
	detail.Text = ""
	detail.ZIndex = banner.ZIndex + 3
	detail.Parent = bannerContent
	self._labels.detail = detail
	self._bannerScale = bannerScale
	local function fitBanner()
		local widest = math.max(bannerTitle.TextBounds.X + Tokens.spacing.xxl * 2, detail.TextBounds.X + Tokens.spacing.lg * 2)
		banner.Size = UDim2.fromOffset(math.max(280, math.ceil(widest)), bannerHeight)
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
	prompt.BackgroundColor3 = Tokens.color.creamPill
	prompt.BackgroundTransparency = 0.05
	prompt.ZIndex = Tokens.zIndex.hud
	local promptCorner = Instance.new("UICorner")
	promptCorner.CornerRadius = UDim.new(0, Tokens.radius.pill)
	promptCorner.Parent = prompt
	local promptStroke = Instance.new("UIStroke")
	promptStroke.Thickness = Tokens.stroke.bold
	promptStroke.Color = Tokens.color.outline
	promptStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
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
		promptItem(5, prompts.menu, "Upgrades")
		-- Only shown while gathering: the lobby explains itself through its world prompts.
		prompt.Visible = mode ~= "touch" and self._promptWanted == true
	end

	-- Upgrade book button (round only): sits under the gear, shows the Tab keycap on keyboard.
	local bookHandle = Button.build(stage, {
		text = "",
		variant = "secondary",
		art = false,
		round = true,
		minimumTapTarget = SafeArea.minimumTapTarget(gui, deps.config),
		motion = deps.accessibility:motionSettings(),
		size = UDim2.fromOffset(SafeArea.minimumTapTarget(gui, deps.config), SafeArea.minimumTapTarget(gui, deps.config)),
		zIndex = Tokens.zIndex.hud,
		sound = function()
			deps.audio:play(Tokens.sound.uiTap)
		end,
		hoverSound = function()
			deps.audio:play(Tokens.sound.uiHover)
		end,
		onActivated = function()
			if self._bookOpener then
				self._bookOpener()
			end
		end,
	})
	bookHandle.button.Name = "BookButton"
	bookHandle.button.AnchorPoint = Vector2.new(1, 0)
	bookHandle.button.Position = UDim2.new(
		1,
		-Tokens.layout.safeAreaPaddingPx,
		0,
		Tokens.layout.safeAreaPaddingPx + Tokens.layout.minimumTapTargetPx + Tokens.spacing.md
	)
	bookHandle.button.Visible = false
	local bookArt =
		Skin.icon(bookHandle.button:FindFirstChild("Face") :: Frame, "station.stats.normal", Tokens.icon.lg + 4, Tokens.zIndex.hud + 3)
	if bookArt then
		bookArt.AnchorPoint = Vector2.new(0.5, 0.5)
		bookArt.Position = UDim2.fromScale(0.5, 0.5)
	end
	-- Keycap and caption: the book opens with Tab (or backtick); the cap swaps to Y on a gamepad.
	local bookCap = Icons.keycap(bookHandle.button, "Tab", Tokens.icon.md, { zIndex = Tokens.zIndex.hud + 5 })
	bookCap.Name = "Keycap"
	bookCap.AnchorPoint = Vector2.new(0.5, 0)
	bookCap.Position = UDim2.new(0.5, 0, 0, -Tokens.spacing.sm)
	local bookCapText = bookCap:FindFirstChild("Glyph") :: TextLabel?
	local bookLabel = FrameKit.pill(bookHandle.button, "Caption", "Upgrades", {
		size = UDim2.fromOffset(0, Tokens.typography.caption.size + Tokens.spacing.sm),
		textSize = Tokens.typography.caption.size,
		zIndex = Tokens.zIndex.hud + 4,
		fill = Tokens.color.creamPill,
		textColor = Tokens.color.inkStrong,
		fitText = true,
		outline = true,
	})
	bookLabel.AnchorPoint = Vector2.new(1, 0)
	bookLabel.Position = UDim2.new(1, 0, 1, Tokens.spacing.xs)
	local function refreshBookCap(mode: string)
		if bookCapText then
			bookCapText.Text = if mode == "gamepad" then "Y" elseif mode == "touch" then "Tap" else "Tab"
		end
	end
	refreshBookCap(deps.input:mode())
	self._trove:add(deps.input.modeChanged:Connect(refreshBookCap))
	self._labels.bookButton = bookHandle.button
	self._trove:add(bookHandle.destroy)

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
	settingsHandle.setText("")
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

	-- Feather Vac heat: a vertical meter with a flame that swells as the motor heats; red and
	-- flashing while it cools down. Shown only while the vac is equipped in a search.
	local heat = Instance.new("Frame")
	heat.Name = "HeatMeter"
	heat.AnchorPoint = Vector2.new(1, 0.5)
	heat.Position = UDim2.new(1, -(Tokens.layout.safeAreaPaddingPx + 10), 0.5, 0)
	heat.Size = UDim2.fromOffset(30, 190)
	heat.BackgroundTransparency = 1
	heat.Visible = false
	heat.ZIndex = Tokens.zIndex.hud
	heat.Parent = stage
	local heatFlame = Icons.flame(heat, 30, { zIndex = Tokens.zIndex.hud + 3, outline = true })
	heatFlame.AnchorPoint = Vector2.new(0.5, 0)
	heatFlame.Position = UDim2.fromScale(0.5, 0)
	local heatFlameScale = Instance.new("UIScale")
	heatFlameScale.Parent = heatFlame
	local heatTrack = Instance.new("Frame")
	heatTrack.Name = "Track"
	heatTrack.AnchorPoint = Vector2.new(0.5, 1)
	heatTrack.Position = UDim2.new(0.5, 0, 1, -(Tokens.typography.caption.size + 6))
	heatTrack.Size = UDim2.fromOffset(16, 190 - 30 - Tokens.typography.caption.size - 12)
	heatTrack.BackgroundColor3 = Tokens.color.creamDeep
	heatTrack.BorderSizePixel = 0
	heatTrack.ClipsDescendants = true
	heatTrack.ZIndex = Tokens.zIndex.hud + 1
	local heatCorner = Instance.new("UICorner")
	heatCorner.CornerRadius = UDim.new(0, Tokens.radius.pill)
	heatCorner.Parent = heatTrack
	local heatStroke = Instance.new("UIStroke")
	heatStroke.Thickness = Tokens.stroke.bold
	heatStroke.Color = Tokens.color.outline
	heatStroke.Parent = heatTrack
	heatTrack.Parent = heat
	local heatFill = Instance.new("Frame")
	heatFill.Name = "Fill"
	heatFill.AnchorPoint = Vector2.new(0.5, 1)
	heatFill.Position = UDim2.fromScale(0.5, 1)
	heatFill.Size = UDim2.fromScale(1, 0)
	heatFill.BackgroundColor3 = Tokens.color.gold
	heatFill.BorderSizePixel = 0
	heatFill.ZIndex = Tokens.zIndex.hud + 2
	local heatFillCorner = Instance.new("UICorner")
	heatFillCorner.CornerRadius = UDim.new(0, Tokens.radius.pill)
	heatFillCorner.Parent = heatFill
	local heatGradient = Instance.new("UIGradient")
	heatGradient.Rotation = 90
	heatGradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Tokens.color.danger),
		ColorSequenceKeypoint.new(0.45, Tokens.color.ember),
		ColorSequenceKeypoint.new(1, Tokens.color.goldLight),
	})
	heatGradient.Parent = heatFill
	heatFill.Parent = heatTrack
	local heatLabel = FrameKit.text(heat, "Label", "HEAT", "caption", {
		zIndex = Tokens.zIndex.hud + 3,
		color = Tokens.color.featherWhite,
		align = Enum.TextXAlignment.Center,
	})
	heatLabel.AnchorPoint = Vector2.new(0.5, 1)
	heatLabel.Position = UDim2.fromScale(0.5, 1)
	heatLabel.Size = UDim2.new(2.4, 0, 0, Tokens.typography.caption.size + 4)
	heatLabel.TextSize = FrameKit.textSize(Tokens.typography.caption.size)
	FrameKit.outline(heatLabel, 1.6)
	self._labels.heat = heat
	self._heatFill = heatFill
	self._heatFlame = heatFlameScale
	self._heatGradient = heatGradient
	self._heatLabel = heatLabel
	self._heatState = "hidden"

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
		size = UDim2.fromOffset(0, Tokens.layout.minimumTapTargetPx + Tokens.spacing.lg),
		textSize = Tokens.typography.display.size,
		zIndex = veil.ZIndex + 1,
		fitText = true,
		fill = Tokens.color.gold,
		textColor = Tokens.color.featherWhite,
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
	-- Bottom band: the strip and hotbar shrink together on narrow viewports so they never run off
	-- the edges or under the prompt chip / carried bundle.
	local bandScales = {}
	for _, root in ipairs({ self.round.root, self.hotbar.root }) do
		local bandScale = Instance.new("UIScale")
		bandScale.Name = "BandScale"
		bandScale.Parent = root
		table.insert(bandScales, bandScale)
	end
	local function fitBand()
		local width = stage.AbsoluteSize.X / SafeArea.scaleOf(stage)
		local reserved = (Tokens.layout.safeAreaPaddingPx + 200) * 2
		local natural = 500
		local factor = math.clamp((width - reserved) / natural, 0.6, 1)
		for _, bandScale in ipairs(bandScales) do
			bandScale.Scale = factor
		end
	end
	fitBand()
	self._trove:add(stage:GetPropertyChangedSignal("AbsoluteSize"):Connect(fitBand))
	self._trove:add(SafeArea.overrideChanged:Connect(fitBand))
	self._trove:add(deps.input.modeChanged:Connect(function(mode)
		self.hotbar:setMode(mode)
	end))

	-- Bindings.
	-- Currency chips count up only from acknowledged projections (never from client prediction).
	local chipLabels = { gems = self._labels.gems, eventTokens = self._labels.tokens }
	for key, label in pairs(chipLabels) do
		-- The chip's UIScale sits on the chip frame (label -> Content -> chip).
		local chipFrame = label.Parent and label.Parent.Parent
		self._chipScales[key] = (chipFrame and chipFrame:FindFirstChildOfClass("UIScale")) :: UIScale
	end
	local function applyCurrency(key: string, target: number)
		local label = chipLabels[key]
		if not label then
			return
		end
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
			local scale = self._chipScales[key]
			if target > previous and scale then
				scale.Scale = 1.12
				Tween.scale(scale, "release", motion, 1)
			end
		end
	end
	self._applyCurrency = applyCurrency
	local function refreshProfile(projection)
		if not projection then
			return
		end
		for key in pairs(chipLabels) do
			local target = projection.currencies[key] or 0
			-- A reward animation in flight parks the chip: the count-up runs when the gems land.
			if (self._currencyHolds[key] or 0) > 0 then
				self._pendingCurrency[key] = target
			else
				applyCurrency(key, target)
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
		self._promptWanted = phase == "Searching" or phase == "EggRevealed"
		self._labels.prompt.Visible = self._promptWanted and deps.input:mode() ~= "touch"
		if self._labels.bookButton then
			self._labels.bookButton.Visible = phase == "Searching"
		end
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
		self.round:setCash(player.cashCents, false)
		-- While a picked feather is still flying to the bundle, the projection's new count waits:
		-- the number and the bundle change when the feather lands (onCollected), not when the
		-- server's reply arrives a fifth of a second earlier.
		local bag = { standard = player.carriedStandard, rainbow = player.carriedRainbow, capacity = capacity }
		if self._bagHolds > 0 then
			self._pendingBag = bag
			return
		end
		self:_applyBag(bag)
	end))
	-- The sale's bag count-down, cash count-up, crate stream, sounds and popup are one choreography in
	-- PickupFeedbackController; the HUD only names a Rainbow sale here.
	self._trove:add(round.sale:Connect(function(sale)
		if (sale.rainbowCount or 0) > 0 then
			self.toasts:reward(
				string.format("%d Rainbow Feather%s sold at 10x", sale.rainbowCount, if sale.rainbowCount == 1 then "" else "s"),
				sale.rainbowCents or 0
			)
		end
	end))
	self._trove:add(round.upgrade:Connect(function(result)
		if result.paidCents then
			self.round:setCash(result.cashCents, true)
		end
	end))
	self._trove:add(interaction.openUpgrades:Connect(function()
		if self._bookOpener then
			self._bookOpener()
		else
			self:openUpgrades(round)
		end
	end))
end

-- Parks a currency chip while a reward animation flies towards it; `releaseCurrency` then applies
-- the newest acknowledged balance with the usual count-up. Holds nest, and are never predicted:
-- the value shown is always one the server sent.
function HUDController.holdCurrency(self: HUDController, key: string)
	self._currencyHolds[key] = (self._currencyHolds[key] or 0) + 1
end

function HUDController.releaseCurrency(self: HUDController, key: string)
	local holds = (self._currencyHolds[key] or 0) - 1
	self._currencyHolds[key] = math.max(0, holds)
	if holds <= 0 then
		local pending = self._pendingCurrency[key]
		self._pendingCurrency[key] = nil
		if pending ~= nil and self._applyCurrency then
			self._applyCurrency(key, pending)
		end
	end
end

-- Screen-space centre of a currency chip (absolute pixels), for animations that fly to it.
function HUDController.currencyChipPoint(self: HUDController, key: string): Vector2?
	local label = if key == "gems" then self._labels.gems else self._labels.tokens
	local chipFrame = label and label.Parent and label.Parent.Parent
	if not chipFrame or not chipFrame:IsA("GuiObject") or not self.gui.Enabled then
		return nil
	end
	return chipFrame.AbsolutePosition + chipFrame.AbsoluteSize * 0.5
end

-- Reward celebration after a server-acknowledged grant (RewardGranted): rotation punch on the chip.
function HUDController.celebrateCurrency(self: HUDController, key: string, amount: number)
	local label = if key == "gems" then self._labels.gems else self._labels.tokens
	if not label or amount <= 0 then
		return
	end
	local chipFrame = label.Parent and label.Parent.Parent
	Tween.rotationPunch(
		(if chipFrame and chipFrame:IsA("GuiObject") then chipFrame else label) :: GuiObject,
		self._deps.accessibility:motionSettings(),
		0
	)
end

function HUDController._applyBag(self: HUDController, bag: { standard: number, rainbow: number, capacity: number })
	self.round:setBag(bag.standard + bag.rainbow, bag.capacity, self._infiniteBag == true, false)
	self.carriedStack:setBag(bag.standard, bag.rainbow, bag.capacity, self._infiniteBag == true, false)
end

-- A pick is in the air: the projection's bag value is parked until the landing applies it.
function HUDController.holdBag(self: HUDController)
	self._bagHolds += 1
end

function HUDController.releaseBag(self: HUDController)
	self._bagHolds = math.max(0, self._bagHolds - 1)
	if self._bagHolds == 0 and self._pendingBag then
		local bag = self._pendingBag
		self._pendingBag = nil
		self:_applyBag(bag)
	end
end

function HUDController.releaseAllBagHolds(self: HUDController)
	self._bagHolds = 0
	self:releaseBag()
end

-- Called at the landing of a pick for the bag squash and the bundle.
function HUDController.onCollected(self: HUDController, data: { [string]: any })
	self._pendingBag = nil
	self._infiniteBag = data.infinite == true
	local awarded = (data.awarded or 0) + (data.rainbow or 0)
	local seconds = data.streamSeconds or 0
	if seconds > 0.05 and awarded > 1 and data.carried then
		-- A streamed sweep: the counter climbs feather by feather with the animation.
		local from = math.max(0, data.carried - awarded)
		local started = os.clock()
		local connection
		connection = RunService.RenderStepped:Connect(function()
			local t = math.clamp((os.clock() - started) / seconds, 0, 1)
			local shown = math.floor(from + (data.carried - from) * t + 0.5)
			self.round:setBag(shown, data.capacity, data.infinite == true, false)
			if t >= 1 then
				connection:Disconnect()
				self.round:setBag(data.carried, data.capacity, data.infinite == true, true)
			end
		end)
		self._trove:add(connection)
	else
		self.round:setBag(data.carried, data.capacity, data.infinite == true, true)
	end
	-- The award carries the bag's composition, not just its size, so a Rainbow Feather shows up in the
	-- bundle on the pick that earned it rather than waiting for the next projection push.
	local carriedRainbow = data.carriedRainbow or 0
	self.carriedStack:setBag(math.max(0, (data.carried or 0) - carriedRainbow), carriedRainbow, data.capacity, data.infinite == true, true)
	local pickup = self._deps.config.pile.visual.pickup
	self.carriedStack:land(pickup.landSquashScale, pickup.landTiltDegrees)
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
-- The reticle answers a press the instant it happens: a small dip and spring back.
function HUDController.reticlePunch(self: HUDController)
	local motion = self._deps.accessibility:motionSettings()
	if motion.reducedMotion then
		return
	end
	self._reticleScale.Scale = 0.82
	TweenService:Create(self._reticleScale, TweenInfo.new(0.16, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
end

function HUDController.setTargeting(self: HUDController, targeting: boolean)
	if self._targeting == targeting then
		return
	end
	self._targeting = targeting
	if self._reticleArt then
		Skin.apply(self._reticleArt, if targeting then "hud.reticle.locked" else "hud.reticle")
	elseif self._rodHeat == nil then
		self._labels.reticle.BackgroundColor3 = if targeting then Tokens.color.gold else Tokens.color.cream
	end
	local motion = self._deps.accessibility:motionSettings()
	TweenService:Create(
		self._reticleScale,
		TweenInfo.new(Motion.duration("quick", motion), Tokens.motion.easeBack),
		{ Scale = if targeting then 1.35 else 1 }
	):Play()
end

-- Feather Vac heat meter: `fraction` 0..1 of the runtime, `state` hidden | idle | running | overheated.
function HUDController.setHeat(self: HUDController, fraction: number, state: string)
	local frame = self._labels.heat
	local fill = self._heatFill
	if not frame or not fill then
		return
	end
	local visible = state ~= "hidden"
	if frame.Visible ~= visible then
		frame.Visible = visible
	end
	if not visible then
		self._heatState = state
		return
	end
	local f = math.clamp(fraction, 0, 1)
	fill.Size = UDim2.fromScale(1, f)
	local flame = self._heatFlame
	if flame then
		flame.Scale = 0.8 + 0.5 * f + (if state == "running" then math.abs(math.sin(os.clock() * 14)) * 0.08 else 0)
	end
	if state ~= self._heatState then
		self._heatState = state
		local label = self._heatLabel
		if label then
			label.Text = if state == "overheated" then "COOLING" elseif state == "running" then "PULLING" else "HEAT"
			label.TextColor3 = if state == "overheated" then Tokens.color.danger else Tokens.color.featherWhite
		end
	end
	if state == "overheated" then
		fill.BackgroundColor3 = if math.sin(os.clock() * 10) > 0 then Tokens.color.danger else Tokens.color.ember
	else
		fill.BackgroundColor3 = Tokens.color.gold
	end
end

-- Egg Sense rod: `heat` 0..1 tints the reticle from cold to warm and fills the heat meter, whose
-- label counts the loan down; nil hides the meter and restores the reticle. Never touches the
-- targeting state (a feather under the crosshair still swaps the art).
function HUDController.setRodHeat(self: HUDController, heat: number?, remainingSeconds: number?)
	local reticle = self._labels.reticle
	local frame = self._labels.heat
	local fill = self._heatFill
	if not reticle or not frame or not fill then
		return
	end
	local rod = self._deps.config.plume and self._deps.config.plume.rod
	if heat == nil or not rod then
		if self._rodHeat ~= nil then
			self._rodHeat = nil
			if self._reticleArt then
				self._reticleArt.ImageColor3 = Color3.new(1, 1, 1)
			else
				reticle.BackgroundColor3 = if self._targeting then Tokens.color.gold else Tokens.color.cream
			end
			if self._heatGradient then
				self._heatGradient.Color = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Tokens.color.danger),
					ColorSequenceKeypoint.new(0.45, Tokens.color.ember),
					ColorSequenceKeypoint.new(1, Tokens.color.goldLight),
				})
			end
			self:setHeat(0, "hidden")
		end
		return
	end
	local h = math.clamp(heat, 0, 1)
	local cold = Color3.fromRGB(rod.coldColor[1], rod.coldColor[2], rod.coldColor[3])
	local warm = Color3.fromRGB(rod.warmColor[1], rod.warmColor[2], rod.warmColor[3])
	local tint = cold:Lerp(warm, h)
	local first = self._rodHeat == nil
	self._rodHeat = h
	if self._reticleArt then
		self._reticleArt.ImageColor3 = tint
	else
		reticle.BackgroundColor3 = tint
	end
	if first and self._heatGradient then
		self._heatGradient.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, warm),
			ColorSequenceKeypoint.new(1, cold),
		})
	end
	if not frame.Visible then
		frame.Visible = true
	end
	fill.Size = UDim2.fromScale(1, h)
	fill.BackgroundColor3 = tint
	local flame = self._heatFlame
	if flame then
		flame.Scale = 0.8 + 0.6 * h + math.abs(math.sin(os.clock() * (4 + 20 * h))) * 0.1 * h
	end
	self._heatState = "rod"
	local label = self._heatLabel
	if label then
		local seconds = math.max(0, math.ceil(remainingSeconds or 0))
		label.Text = string.format("SENSE %ds", seconds)
		label.TextColor3 = if h >= 0.95 then warm else Tokens.color.featherWhite
	end
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

-- The lobby registers the Gem Shop opener; the "+" only shows once something can open it.
function HUDController.setGemShopOpener(self: HUDController, opener: (() -> ())?)
	self._gemShopOpener = opener
	if self._labels.gemPlus then
		self._labels.gemPlus.Visible = opener ~= nil
	end
end

-- The upgrade book (UpgradeBookController) registers itself here; without it the workbench modal opens.
function HUDController.setBookOpener(self: HUDController, opener: (() -> ())?)
	self._bookOpener = opener
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
