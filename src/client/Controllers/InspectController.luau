--!strict
-- Barn item inspection: the camera eases onto the display model, cinematic bars slide in, an
-- info panel names the item with its level and next step, and the bottom row offers the cash
-- and Robux options that exist for it. Skins for tools sit on the right. Click anywhere (or
-- Cancel) to leave; the camera and mouse come back exactly as they were. Purchases go through the
-- same server requests as the workbench; the server stays the authority on every price.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local Feedback = require(script.Parent.Parent.UI.Feedback)
local EconomyMath = require(Shared.EconomyMath)
local SkinCatalog = require(Shared.Domain.SkinCatalog)
local Trove = require(Shared.Util.Trove)
local FrameKit = require(script.Parent.Parent.UI.Components.Frame)
local Button = require(script.Parent.Parent.UI.Components.Button)
local Skin = require(script.Parent.Parent.UI.Components.Skin)
local UpgradeActions = require(script.Parent.Parent.UI.UpgradeActions)
local Depth = require(script.Parent.Parent.UI.Components.Depth)

local InspectController = {}
InspectController.__index = InspectController

export type InspectController = typeof(setmetatable(
	{} :: {
		_deps: any,
		_trove: any,
		_session: any?,
		stats: { opens: number, purchases: number },
	},
	InspectController
))

-- Copy per display: name, story, tag line.
local COPY: { [string]: { name: string, story: string, tag: string, toolId: string?, upgradeId: string?, pass: string? } } = {
	bag = {
		name = "Bag Upgrade",
		story = "Carry more feathers before you have to walk back and sell.\n\nEvery level means fewer trips to the crate and more time working the nest.",
		tag = "",
		upgradeId = "bag",
	},
	infiniteBag = {
		name = "Infinite Bag",
		story = "Your bag never fills up again.\n\nCollect forever without a single walk back to the crate. Keep it for good.",
		tag = "KEEP FOREVER",
		pass = "infiniteBag",
	},
	nestRake = {
		name = "Nest Rake",
		story = "Rake the nest and haul out a whole sweep at once.\n\nSlower between swings than your bare hands, but every sweep carves a real dent and lifts far more than a single pull.",
		tag = "DIGS DEEPER",
		toolId = "nestRake",
		upgradeId = "tool:nestRake",
	},
	confettiCharge = {
		name = "Confetti Charge",
		story = "Blast a crater straight through the nest.\n\nOne charge clears more feathers than a dozen pulls, and whatever was buried in the blast comes up with it. Light it, throw it, stand back.",
		tag = "BIGGEST DIG",
		toolId = "confettiCharge",
		upgradeId = "tool:confettiCharge",
	},
	featherVac = {
		name = "Feather Vac",
		story = "Hold it on the nest and it pulls feathers straight out of the pile.\n\nNo swinging and no waiting between pulls: a steady stream for as long as you keep it running, until the motor needs a moment to cool.",
		tag = "NEVER STOPS",
		toolId = "featherVac",
		upgradeId = "tool:featherVac",
	},
	scoutChick = {
		name = "Scout Chick",
		story = "A little forager that works the nest while you do.\n\nSend it out and it pecks feathers, hops them to the crate and trades them for cash on its own, trip after trip.",
		tag = "WORKS FOR YOU",
		toolId = "scoutChick",
		upgradeId = "tool:scoutChick",
	},
}

function InspectController.new(deps: any): InspectController
	local self =
		setmetatable({ _deps = deps, _trove = Trove.new(), _session = nil, stats = { opens = 0, purchases = 0 } }, InspectController)
	self._trove:add(deps.input.actionBegan:Connect(function(action)
		if (action == "Cancel" or action == "Back") and self._session then
			self:close()
		end
	end))
	self._trove:add(deps.round.phaseChanged:Connect(function(phase)
		if phase ~= "Searching" and self._session then
			self:close()
		end
	end))
	return self
end

function InspectController.isOpen(self: InspectController): boolean
	return self._session ~= nil
end

-- Builds the options row for a display from live previews, entitlements and config.
function InspectController._options(
	self: InspectController,
	key: string
): { { caption: string, text: string, variant: string, enabled: boolean, run: () -> () } }
	local deps = self._deps
	local cfg = deps.config
	local copy = COPY[key]
	local projection = deps.profile.projection
	local entitlements = projection and projection.entitlements or {}
	local options = {}
	local actionDeps =
		{ net = deps.net, round = deps.round, audio = deps.audio, haptics = deps.haptics, toasts = deps.hud.toasts, config = cfg }
	local promptDeps = { net = deps.net, audio = deps.audio, toasts = deps.hud.toasts }
	if key == "bag" then
		local preview = UpgradeActions.previewFor(deps.round, "bag")
		local level = preview and preview.level or 1
		local levels = cfg.bags.levels
		local entry = levels[level]
		if preview and not preview.maxed then
			table.insert(options, {
				caption = "UPGRADE",
				text = EconomyMath.formatCents(preview.costCents or 0),
				variant = "primary",
				enabled = true,
				run = function()
					local result = UpgradeActions.purchase(actionDeps, "bag", "Bag")
					if result and result.ok then
						self.stats.purchases += 1
					end
				end,
			})
			local skipRobux = entry and entry.skipRobux
			if skipRobux then
				table.insert(options, {
					caption = "SKIP UPGRADE",
					text = string.format("R$ %d", skipRobux),
					variant = "teal",
					enabled = true,
					run = function()
						UpgradeActions.promptPurchase(promptDeps, "skipBagUpgrade", "Skip Bag Upgrade")
					end,
				})
			end
		else
			table.insert(options, { caption = "BAG", text = "MAX LEVEL", variant = "secondary", enabled = false, run = function() end })
		end
	elseif key == "infiniteBag" then
		local owned = entitlements.infiniteBag == true
		local robux = cfg.monetization.passes.infiniteBag and cfg.monetization.passes.infiniteBag.robux
		table.insert(options, {
			caption = "PERMANENT",
			text = if owned then "OWNED" else string.format("R$ %d", robux or 0),
			variant = if owned then "success" else "teal",
			enabled = not owned,
			run = function()
				UpgradeActions.promptPurchase(promptDeps, "infiniteBag", "Infinite Bag")
			end,
		})
	elseif copy.toolId then
		local tool = cfg.tools[copy.toolId]
		local preview = UpgradeActions.previewFor(deps.round, copy.upgradeId :: string)
		local ownedRound = preview ~= nil and preview.maxed
		local permanentKey = copy.toolId .. "Permanent"
		local ownsPermanent = entitlements[permanentKey] == true
			or (projection and projection.permanentTools and projection.permanentTools[copy.toolId]) == true
		table.insert(options, {
			caption = "ONE ROUND",
			text = string.format("R$ %d", tool.oneRoundRobux or 0),
			variant = "teal",
			enabled = not ownedRound,
			run = function()
				UpgradeActions.promptPurchase(promptDeps, copy.toolId .. "OneRound", tool.displayName)
			end,
		})
		local gemPriced = tool.softGemPrice ~= nil and tool.softCashPrice == nil
		table.insert(options, {
			caption = if gemPriced then "GEMS" else "CASH",
			text = if ownedRound
				then "OWNED"
				elseif gemPriced then string.format("%d Gems", (preview and preview.costGems) or tool.softGemPrice or 0)
				else EconomyMath.formatCents((preview and preview.costCents) or math.floor((tool.softCashPrice or 0) * 100 + 0.5)),
			variant = if ownedRound then "success" elseif gemPriced then "gem" else "primary",
			enabled = not ownedRound and preview ~= nil,
			run = function()
				local result = UpgradeActions.purchase(actionDeps, copy.upgradeId :: string, tool.displayName)
				if result and result.ok then
					self.stats.purchases += 1
				end
			end,
		})
		table.insert(options, {
			caption = "PERMANENT",
			text = if ownsPermanent then "OWNED" else string.format("R$ %d", tool.permanentRobux or 0),
			variant = if ownsPermanent then "success" else "teal",
			enabled = not ownsPermanent,
			run = function()
				UpgradeActions.promptPurchase(promptDeps, permanentKey, tool.displayName .. " (Permanent)")
			end,
		})
	end
	return options
end

-- Headline over the model: "25 -> 50" for the bag, the tool's yield for tools.
function InspectController._headline(self: InspectController, key: string): string
	local deps = self._deps
	local cfg = deps.config
	if key == "bag" then
		local preview = UpgradeActions.previewFor(deps.round, "bag")
		if preview and preview.current then
			local nextCapacity = preview.next and preview.next.capacity
			return if nextCapacity
				then string.format("%d  →  %d", preview.current.capacity, nextCapacity)
				else string.format("%d  MAX", preview.current.capacity)
		end
		return string.format(
			"%d  →  %d",
			cfg.bags.levels[1].capacity,
			cfg.bags.levels[2] and cfg.bags.levels[2].capacity or cfg.bags.levels[1].capacity
		)
	elseif key == "infiniteBag" then
		return "∞"
	elseif key == "nestRake" then
		return string.format("%d per sweep", cfg.tools.nestRake.baseYield or 0)
	elseif key == "confettiCharge" then
		return string.format("%d per blast", cfg.tools.confettiCharge.baseYield or 0)
	elseif key == "scoutChick" then
		return string.format("%d per trip", cfg.tools.scoutChick.baseCapacity or 0)
	end
	return ""
end

function InspectController.open(self: InspectController, key: string, model: Model)
	local copy = COPY[key]
	if not copy or self._session then
		return
	end
	local deps = self._deps
	local player = Players.LocalPlayer
	local camera = workspace.CurrentCamera
	if not (player and camera) then
		return
	end
	self.stats.opens += 1
	local motion = deps.accessibility:motionSettings()
	local session = { trove = Trove.new(), key = key, model = model }
	self._session = session
	deps.audio:play(Tokens.sound.uiOpen)

	-- Input and mouse: gameplay pauses, the cursor is free, the HUD steps aside.
	deps.input:setSuspended(true)
	deps.modals:setExternalUnlock(true)
	local hudGui = deps.hud.gui
	local hudWasEnabled = hudGui.Enabled
	hudGui.Enabled = false
	-- The lobby's side menu and the 2x Gems tile live on their own gui and collided with the skins
	-- picker; they step aside with the HUD.
	local lobbyGui = hudGui.Parent and hudGui.Parent:FindFirstChild("SFE_Lobby")
	local lobbyWasEnabled = lobbyGui and lobbyGui:IsA("ScreenGui") and lobbyGui.Enabled
	if lobbyGui and lobbyGui:IsA("ScreenGui") then
		lobbyGui.Enabled = false
	end
	session.trove:add(function()
		if lobbyGui and lobbyGui:IsA("ScreenGui") and lobbyGui.Parent then
			lobbyGui.Enabled = lobbyWasEnabled == true
		end
		hudGui.Enabled = hudWasEnabled
		deps.modals:setExternalUnlock(false)
		deps.input:setSuspended(false)
	end)

	-- Camera: ease to a spot in front of the model, looking slightly down at it.
	local pivot, size = model:GetBoundingBox()
	local distance = math.max(size.X, size.Y) * 1.7 + 2.5
	local target =
		CFrame.lookAt(pivot.Position + Vector3.new(0, size.Y * 0.25, distance), pivot.Position + Vector3.new(0, size.Y * 0.05, 0))
	local previousType = camera.CameraType
	local previousCFrame = camera.CFrame
	camera.CameraType = Enum.CameraType.Scriptable
	local seconds = if motion.reducedMotion then 0.05 else 0.45
	TweenService:Create(camera, TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { CFrame = target }):Play()
	session.trove:add(function()
		local back = TweenService:Create(
			camera,
			TweenInfo.new(if motion.reducedMotion then 0.05 else 0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut),
			{ CFrame = previousCFrame }
		)
		back:Play()
		back.Completed:Once(function()
			camera.CameraType = previousType
		end)
	end)

	-- Overlay --------------------------------------------------------------------------------
	local gui = Instance.new("ScreenGui")
	gui.Name = "SFE_Inspect"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = Tokens.zIndex.modal - 1
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = player:WaitForChild("PlayerGui")
	session.trove:add(gui)
	local tap = Tokens.layout.minimumTapTargetPx

	local catcher = Instance.new("TextButton")
	catcher.Name = "Catcher"
	catcher.Text = ""
	catcher.BackgroundTransparency = 1
	catcher.Size = UDim2.fromScale(1, 1)
	catcher.ZIndex = 1
	catcher.Parent = gui
	session.trove:add(catcher.Activated:Connect(function()
		self:close()
	end))

	local function bar(name: string, anchorY: number)
		local frame = Instance.new("Frame")
		frame.Name = name
		frame.AnchorPoint = Vector2.new(0, anchorY)
		frame.Position = UDim2.fromScale(0, anchorY)
		frame.Size = UDim2.fromScale(1, 0)
		frame.BackgroundColor3 = Color3.new(0, 0, 0)
		frame.BorderSizePixel = 0
		frame.ZIndex = 2
		frame.Parent = gui
		TweenService
			:Create(frame, TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = UDim2.fromScale(1, 0.11) })
			:Play()
		return frame
	end
	bar("TopBar", 0)
	bar("BottomBar", 1)

	-- Info panel (left).
	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0, 0.5)
	panel.Position = UDim2.new(0, Tokens.spacing.xl * 2, 0.5, -Tokens.spacing.lg)
	panel.Size = UDim2.fromScale(0.27, 0.56)
	-- Dark kit card (owner, 17 Sep 2026: the old brown panel with the retired "cream" token, now a
	-- charcoal, put dark copy on a dark panel). Opaque charcoal, near-black keyline, white stroked
	-- title, light ink copy with a soft stroke, gold tag: every text sits at high contrast.
	panel.BorderSizePixel = 0
	panel.ZIndex = 3
	Depth.panel(panel, Tokens.color.panel, { radius = Tokens.radius.lg })
	local panelPadding = Instance.new("UIPadding")
	panelPadding.PaddingLeft = UDim.new(0, Tokens.spacing.lg)
	panelPadding.PaddingRight = UDim.new(0, Tokens.spacing.lg)
	panelPadding.PaddingTop = UDim.new(0, Tokens.spacing.lg)
	panelPadding.PaddingBottom = UDim.new(0, Tokens.spacing.lg)
	panelPadding.Parent = panel
	local panelScale = Instance.new("UIScale")
	panelScale.Scale = 0.92
	panelScale.Parent = panel
	panel.Parent = gui
	TweenService:Create(panelScale, TweenInfo.new(seconds, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
	local title = FrameKit.text(panel, "Title", copy.name, "display", { zIndex = 4, color = Tokens.color.featherWhite })
	title.Size = UDim2.new(1, 0, 0, Tokens.typography.display.size + 6)
	title.TextSize = Tokens.typography.display.size - 4
	title.TextTruncate = Enum.TextTruncate.AtEnd
	FrameKit.outline(title, 3)
	local rule = FrameKit.divider(panel, "Rule", 4)
	rule.Position = UDim2.fromOffset(0, Tokens.typography.display.size + Tokens.spacing.md)
	rule.BackgroundColor3 = Tokens.color.gold
	rule.BackgroundTransparency = 0.35
	local story = FrameKit.text(panel, "Story", copy.story, "body", { zIndex = 4, color = Tokens.color.ink, wrap = true })
	story.Position = UDim2.fromOffset(0, Tokens.typography.display.size + Tokens.spacing.xl)
	story.Size = UDim2.new(1, 0, 1, -(Tokens.typography.display.size + Tokens.spacing.xl + tap))
	story.TextYAlignment = Enum.TextYAlignment.Top
	local storyStroke = FrameKit.outline(story, 1.2)
	storyStroke.Transparency = 0.45
	local tag = FrameKit.text(panel, "Tag", "", "label", { zIndex = 4, color = Tokens.color.gold })
	tag.AnchorPoint = Vector2.new(0, 1)
	tag.Position = UDim2.fromScale(0, 1)
	tag.Size = UDim2.new(1, 0, 0, Tokens.typography.label.size + 6)
	FrameKit.outline(tag, 2)
	session.tag = tag

	-- Headline over the model.
	local headline = FrameKit.text(gui, "Headline", "", "display", {
		zIndex = 3,
		color = Tokens.color.featherWhite,
		align = Enum.TextXAlignment.Center,
	})
	headline.AnchorPoint = Vector2.new(0.5, 0)
	headline.Position = UDim2.fromScale(0.5, 0.13)
	headline.Size = UDim2.new(0.5, 0, 0, Tokens.typography.display.size * 2)
	headline.TextSize = Tokens.typography.display.size * 1.8
	FrameKit.outline(headline, 4)
	session.headline = headline

	-- Options row along the bottom.
	local row = Instance.new("Frame")
	row.Name = "Options"
	row.AnchorPoint = Vector2.new(0.5, 1)
	row.Position = UDim2.new(0.5, 0, 0.89, -Tokens.spacing.sm)
	row.Size = UDim2.new(0.7, 0, 0, tap + Tokens.spacing.xl + Tokens.spacing.md)
	row.BackgroundTransparency = 1
	row.ZIndex = 3
	row.Parent = gui
	local rowLayout = Instance.new("UIListLayout")
	rowLayout.FillDirection = Enum.FillDirection.Horizontal
	rowLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	rowLayout.VerticalAlignment = Enum.VerticalAlignment.Bottom
	rowLayout.Padding = UDim.new(0, Tokens.spacing.xl)
	rowLayout.SortOrder = Enum.SortOrder.LayoutOrder
	rowLayout.Parent = row
	session.row = row

	local leave = FrameKit.text(gui, "Leave", "Click anywhere to leave", "caption", {
		zIndex = 3,
		color = Tokens.color.featherWhite,
		align = Enum.TextXAlignment.Center,
	})
	leave.AnchorPoint = Vector2.new(0.5, 1)
	leave.Position = UDim2.new(0.5, 0, 1, -Tokens.spacing.md)
	leave.Size = UDim2.new(1, 0, 0, Tokens.typography.caption.size + 4)
	leave.TextTransparency = 0.25

	-- Skins (tools only), right side.
	if copy.toolId then
		local skinsFrame = Instance.new("Frame")
		skinsFrame.Name = "Skins"
		skinsFrame.AnchorPoint = Vector2.new(1, 0.5)
		skinsFrame.Position = UDim2.new(1, -Tokens.spacing.xl * 2, 0.5, 0)
		skinsFrame.Size = UDim2.fromOffset(tap * 2 + Tokens.spacing.xl * 2 + Tokens.spacing.md, tap * 2 + Tokens.spacing.xl * 2)
		skinsFrame.BackgroundTransparency = 1
		skinsFrame.ZIndex = 3
		skinsFrame.Parent = gui
		local skinsTitle = FrameKit.text(
			skinsFrame,
			"Title",
			"Skins",
			"display",
			{ zIndex = 4, color = Tokens.color.featherWhite, align = Enum.TextXAlignment.Center }
		)
		skinsTitle.Size = UDim2.new(1, 0, 0, Tokens.typography.display.size + 4)
		FrameKit.outline(skinsTitle, 3)
		local chips = Instance.new("Frame")
		chips.Name = "Chips"
		chips.AnchorPoint = Vector2.new(0.5, 1)
		chips.Position = UDim2.fromScale(0.5, 1)
		chips.Size = UDim2.new(1, 0, 0, tap * 2)
		chips.BackgroundTransparency = 1
		chips.ZIndex = 4
		chips.Parent = skinsFrame
		local chipsLayout = Instance.new("UIListLayout")
		chipsLayout.FillDirection = Enum.FillDirection.Horizontal
		chipsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
		chipsLayout.Padding = UDim.new(0, Tokens.spacing.sm)
		chipsLayout.Parent = chips
		session.chips = chips
	end

	self:_render()
	session.trove:add(deps.round.upgrade:Connect(function()
		self:_render()
	end))
	session.trove:add(deps.round.playerChanged:Connect(function()
		self:_render()
	end))
	session.trove:add(deps.profile.changed:Connect(function()
		self:_render()
	end))
end

function InspectController._render(self: InspectController)
	local session = self._session
	if not session then
		return
	end
	local deps = self._deps
	local cfg = deps.config
	local copy = COPY[session.key]
	local motion = deps.accessibility:motionSettings()
	local tap = Tokens.layout.minimumTapTargetPx
	session.headline.Text = self:_headline(session.key)
	if session.key == "bag" then
		local preview = UpgradeActions.previewFor(deps.round, "bag")
		session.tag.Text = string.format("★  LEVEL %d / %d  ★", preview and preview.level or 1, #cfg.bags.levels)
	else
		session.tag.Text = "★  " .. copy.tag .. "  ★"
	end
	-- Options
	for _, child in ipairs(session.row:GetChildren()) do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	for index, option in ipairs(self:_options(session.key)) do
		local slot = Instance.new("Frame")
		slot.Name = "Option" .. index
		slot.BackgroundTransparency = 1
		slot.Size = UDim2.fromOffset(tap * 4, tap + Tokens.spacing.xl + Tokens.spacing.sm)
		slot.LayoutOrder = index
		slot.ZIndex = 3
		slot.Parent = session.row
		local caption = FrameKit.text(slot, "Caption", option.caption, "label", {
			zIndex = 4,
			color = Tokens.color.featherWhite,
			align = Enum.TextXAlignment.Center,
		})
		caption.Size = UDim2.new(1, 0, 0, Tokens.typography.label.size + 4)
		FrameKit.outline(caption, 2)
		local handle = Button.build(slot, {
			text = option.text,
			variant = option.variant,
			minimumTapTarget = tap,
			motion = motion,
			size = UDim2.new(1, 0, 0, tap + Tokens.spacing.xs),
			zIndex = 4,
			textSize = Tokens.typography.title.size,
			sound = function()
				deps.audio:play(Tokens.sound.uiTap)
			end,
			hoverSound = function()
				deps.audio:play(Tokens.sound.uiHover)
			end,
			onActivated = option.run,
		})
		handle.button.AnchorPoint = Vector2.new(0.5, 1)
		handle.button.Position = UDim2.fromScale(0.5, 1)
		handle.setEnabled(option.enabled)
		session.trove:add(handle.destroy)
	end
	-- Skins
	if session.chips and copy.toolId then
		for _, child in ipairs(session.chips:GetChildren()) do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
		local projection = deps.profile.projection
		local inventory = projection and projection.inventory or { toolSkins = {}, equippedSkins = {} }
		for _, skin in ipairs(SkinCatalog.all(cfg)) do
			if skin.category ~= copy.toolId then
				continue
			end
			local owned = skin.source == "default" or inventory.toolSkins[skin.id] == true
			local equipped = inventory.equippedSkins[skin.category] == skin.id
			local tile, face = FrameKit.tile(session.chips, "Skin_" .. skin.id, {
				fill = if equipped then Tokens.color.leafBright elseif owned then Tokens.color.creamPill else Tokens.color.cocoa,
				deep = if equipped then Tokens.color.leafDeep elseif owned then Tokens.color.strawDeep else Tokens.color.outline,
				zIndex = 4,
				radius = Tokens.radius.md,
				lip = 4,
				size = UDim2.fromOffset(tap * 2, tap * 2),
			})
			local art = Skin.icon(face, "tool." .. skin.category .. ".normal", tap + Tokens.spacing.sm, 6)
			if art then
				art.AnchorPoint = Vector2.new(0.5, 0)
				art.Position = UDim2.new(0.5, 0, 0, Tokens.spacing.xs)
				if skin.source ~= "default" then
					art.ImageColor3 = Color3.fromRGB(150, 230, 130)
				end
				art.ImageTransparency = if owned then 0 else 0.5
			end
			local name = FrameKit.text(
				face,
				"Name",
				if skin.source == "default" then "DEFAULT" else string.upper(string.match(skin.displayName, "^(%a+)") or skin.displayName),
				"caption",
				{
					zIndex = 6,
					color = Tokens.color.featherWhite,
					align = Enum.TextXAlignment.Center,
				}
			)
			name.Font = Tokens.typography.label.font
			name.AnchorPoint = Vector2.new(0.5, 1)
			name.Position = UDim2.new(0.5, 0, 1, -2)
			name.Size = UDim2.new(1, 0, 0, Tokens.typography.caption.size + 4)
			FrameKit.outline(name, 1.8)
			local hit = Instance.new("TextButton")
			hit.Text = ""
			hit.BackgroundTransparency = 1
			hit.Size = UDim2.fromScale(1, 1)
			hit.ZIndex = 7
			hit.Parent = tile
			session.trove:add(hit.Activated:Connect(function()
				if not owned then
					Feedback.deny("skin_locked", "Drops from the Moonlit Chest", { tone = "info" })
					return
				end
				local result = deps.net:request("InventoryEquip", { category = skin.category, itemId = skin.id })
				if result.ok then
					deps.audio:play(Tokens.sound.uiConfirm)
				else
					Feedback.deny("equip_refused")
				end
			end))
		end
	end
end

function InspectController.close(self: InspectController)
	local session = self._session
	if not session then
		return
	end
	self._session = nil
	self._deps.audio:play(Tokens.sound.uiClose)
	session.trove:destroy()
end

function InspectController.destroy(self: InspectController)
	self:close()
	self._trove:destroy()
end

return InspectController
