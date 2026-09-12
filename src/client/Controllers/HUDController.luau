--!strict
-- Phase 1 HUD shell: currency chips bound to the profile projection, a session/objective banner,
-- a settings button that opens a real modal (reduced motion / camera shake / haptics / quality
-- toggles round-tripped through SettingsUpdate), an input-prompt chip that swaps by input mode,
-- and the toast queue. Copy is original placeholder text; owner Phase 2 objective system.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local Trove = require(Shared.Util.Trove)
local SafeArea = require(script.Parent.Parent.UI.SafeArea)
local Button = require(script.Parent.Parent.UI.Components.Button)
local Toast = require(script.Parent.Parent.UI.Components.Toast)

local HUDController = {}
HUDController.__index = HUDController

export type HUDController = typeof(setmetatable(
	{} :: {
		gui: ScreenGui,
		toasts: any,
		_deps: any,
		_labels: { [string]: TextLabel },
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
	stroke.Thickness = Tokens.stroke.standard
	stroke.Color = Tokens.color.creamDeep
	stroke.Parent = label
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
	local _, scaleCleanup = SafeArea.applyScale(gui, deps.config)

	local self = setmetatable({ gui = gui, toasts = nil, _deps = deps, _labels = {}, _trove = Trove.new() }, HUDController)
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
	row.Parent = gui
	self._labels.gems = chip(row, "Gems", 1)
	self._labels.tokens = chip(row, "Tokens", 2)

	-- Top-center session/objective banner.
	local banner = chip(gui, "Banner", 1)
	banner.AnchorPoint = Vector2.new(0.5, 0)
	banner.Position = UDim2.new(0.5, 0, 0, Tokens.layout.safeAreaPaddingPx + Tokens.layout.minimumTapTargetPx + Tokens.spacing.md)
	banner.Font = Tokens.typography.body.font
	banner.TextSize = Tokens.typography.body.size
	banner.Text = "Loading your nest..."
	self._labels.banner = banner

	-- Bottom-right input prompt chip (swaps per input mode) and settings button.
	local prompt = chip(gui, "Prompt", 1)
	prompt.AnchorPoint = Vector2.new(1, 1)
	prompt.Position = UDim2.new(1, -Tokens.layout.safeAreaPaddingPx, 1, -Tokens.layout.safeAreaPaddingPx)
	prompt.Font = Tokens.typography.caption.font
	prompt.TextSize = Tokens.typography.caption.size
	self._labels.prompt = prompt

	local minimumTap = SafeArea.minimumTapTarget(gui, deps.config)
	local settingsButton, settingsCleanup = Button.create(gui, {
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

	self.toasts = Toast.new(gui, function()
		return deps.accessibility:motionSettings()
	end)
	self._trove:add(self.toasts)

	-- Bindings.
	local function refreshProfile(projection)
		if not projection then
			return
		end
		self._labels.gems.Text = string.format("Gems  %d", projection.currencies.gems)
		self._labels.tokens.Text = string.format("Tokens  %d", projection.currencies.eventTokens)
	end
	refreshProfile(deps.profile.projection)
	self._trove:add(deps.profile.changed:Connect(refreshProfile))

	local function refreshSession(session)
		if not session then
			return
		end
		local phase = session.phase
		if phase == "Lobby" then
			banner.Text = "Lobby ready - Phase 1 architecture shell"
		elseif phase == "LoadRetry" then
			banner.Text = "Reconnecting to your nest..."
		elseif phase == "Party" then
			banner.Text = "Party forming"
		elseif phase == "Round" then
			banner.Text = "Round (skeleton)"
		else
			banner.Text = phase
		end
	end
	refreshSession(deps.profile.session)
	self._trove:add(deps.profile.sessionChanged:Connect(refreshSession))

	local function refreshPrompt(mode)
		local prompts = Tokens.prompts[mode]
		prompt.Text = string.format("%s  Look around   %s  Interact", prompts.primary, prompts.interact)
	end
	refreshPrompt(deps.input:mode())
	self._trove:add(deps.input.modeChanged:Connect(refreshPrompt))

	self._trove:add(deps.net:on("Toast", function(payload)
		self.toasts:push(payload.key, payload.tone)
	end))
	return self
end

-- Settings modal: four toggles + quality selector, each round-tripped through SettingsUpdate.
function HUDController.openSettings(self: HUDController)
	local deps = self._deps
	local opened = deps.modals:open("settings", deps.modals.Priority.Shop, true, function(container, api)
		local cleanups: { any } = {}
		local settings = deps.profile:settings() or {}
		local minimumTap = SafeArea.minimumTapTarget(deps.modals.gui, deps.config)
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
