--!strict
-- Settings modal: comfort switches (reduced motion, camera shake, haptics) as proper toggle rows,
-- a quality selector as tabs, and Done. Every change round-trips through SettingsUpdate; the row
-- only settles into its new state after the server acknowledged it, and snaps back on refusal.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local Feedback = require(script.Parent.Parent.Feedback)
local Motion = require(Shared.Design.Motion)
local FrameKit = require(script.Parent.Parent.Components.Frame)
local Button = require(script.Parent.Parent.Components.Button)
local Switch = require(script.Parent.Parent.Components.Switch)
local Tabs = require(script.Parent.Parent.Components.Tabs)

local SettingsModal = {}

export type Deps = {
	net: any,
	profile: any,
	audio: any,
	accessibility: any,
	config: { [string]: any },
	minimumTapTarget: number,
	toasts: any,
}

local SWITCHES = {
	{ key = "reducedMotion", label = "Reduced motion", detail = "Shorter, calmer UI motion and effects" },
	{ key = "cameraShake", label = "Camera shake", detail = "Small camera kicks on pulls and blasts" },
	{ key = "haptics", label = "Haptics", detail = "Controller and phone vibration on rewards" },
}

local QUALITY = {
	{ id = "auto", label = "Auto" },
	{ id = "low", label = "Low" },
	{ id = "medium", label = "Medium" },
	{ id = "high", label = "High" },
}

-- A section heading with the stroke every label on the dark kit carries.
local function heading(parent: Instance, name: string, text: string, zIndex: number): Frame
	local row = FrameKit.heading(parent, name, text, zIndex)
	local label = row:FindFirstChild("Text")
	if label and label:IsA("TextLabel") then
		FrameKit.outline(label, 2.5)
	end
	return row
end

-- Dresses a kit switch row to the dark reference: slate row inside a thick keyline, stroked
-- lettering, a track that goes green when on. The Switch component still paints itself in the
-- cream kit's colours on hover, focus and toggle, so each of those is answered here a frame later
-- with the dark value; when the component is restyled this becomes a no-op.
local function dress(handle: Switch.Handle, motion: Motion.MotionSettings, cleanups: { any })
	local row = handle.row
	local stroke = row:FindFirstChildOfClass("UIStroke")
	local track = row:FindFirstChild("Track")
	local state = row:FindFirstChild("State")
	local function settle()
		row.BackgroundColor3 = Tokens.color.surface
		if stroke then
			stroke.Color = Tokens.color.outline
			stroke.Thickness = Tokens.depth.keyline
			stroke.Transparency = 0
		end
	end
	settle()
	for _, name in ipairs({ "Label", "Detail", "State" }) do
		local label = row:FindFirstChild(name)
		if label and label:IsA("TextLabel") then
			FrameKit.outline(label, if name == "Label" then 2.5 else 2)
		end
	end
	local function recolour(animate: boolean)
		if not (track and track:IsA("Frame") and state and state:IsA("TextLabel")) then
			return
		end
		local on = state.Text == "On"
		local trackColor = if on then Tokens.color.success else Tokens.color.panelDeep
		state.TextColor3 = if on then Tokens.color.success else Tokens.color.inkMuted
		if animate then
			TweenService:Create(track, TweenInfo.new(Motion.duration("quick", motion)), { BackgroundColor3 = trackColor }):Play()
		else
			track.BackgroundColor3 = trackColor
		end
	end
	recolour(false)
	if state then
		table.insert(
			cleanups,
			state:GetPropertyChangedSignal("Text"):Connect(function()
				task.defer(recolour, true)
			end)
		)
	end
	local quick = function()
		return TweenInfo.new(Motion.duration("quick", motion))
	end
	table.insert(
		cleanups,
		row.MouseEnter:Connect(function()
			TweenService:Create(row, quick(), { BackgroundColor3 = Tokens.color.surfaceAlt }):Play()
		end)
	)
	table.insert(
		cleanups,
		row.MouseLeave:Connect(function()
			TweenService:Create(row, quick(), { BackgroundColor3 = Tokens.color.surface }):Play()
		end)
	)
	table.insert(
		cleanups,
		row.SelectionGained:Connect(function()
			if stroke then
				stroke.Color = Tokens.color.gold
				stroke.Thickness = Tokens.stroke.frame
				stroke.Transparency = 0
			end
		end)
	)
	table.insert(cleanups, row.SelectionLost:Connect(settle))
end

function SettingsModal.build(container: ScrollingFrame, api: any, deps: Deps): () -> ()
	local cleanups: { any } = {}
	local settings = deps.profile:settings() or {}
	local motion = deps.accessibility:motionSettings()
	local tap = deps.minimumTapTarget
	local z = container.ZIndex + 1

	local intro = FrameKit.text(
		container,
		"Intro",
		"Comfort settings save to your profile right away.",
		"caption",
		{ zIndex = z, color = Tokens.color.inkMuted }
	)
	intro.LayoutOrder = 0
	FrameKit.outline(intro, 2)
	heading(container, "ComfortHeading", "Comfort", z).LayoutOrder = 1

	local function send(payload: { [string]: any }): boolean
		local result = deps.net:request("SettingsUpdate", payload)
		if result.ok then
			deps.audio:play(Tokens.sound.uiConfirm)
			return true
		end
		Feedback.deny("settings:" .. tostring(result.code), "Could not save setting")
		return false
	end

	local firstRow: GuiObject? = nil
	for index, spec in ipairs(SWITCHES) do
		local handle
		handle = Switch.build(container, {
			label = spec.label,
			detail = spec.detail,
			on = settings[spec.key] == true,
			minimumTapTarget = tap,
			motion = motion,
			zIndex = z + 1,
			sound = function()
				deps.audio:play(Tokens.sound.uiSwitch)
			end,
			onToggle = function(on)
				if not send({ [spec.key] = on }) then
					handle.set(not on)
				end
			end,
		})
		handle.row.LayoutOrder = 10 + index
		dress(handle, motion, cleanups)
		firstRow = firstRow or handle.row
		table.insert(cleanups, handle.destroy)
	end

	heading(container, "QualityHeading", "Graphics quality", z).LayoutOrder = 20
	local quality = Tabs.build(container, {
		items = QUALITY,
		selected = settings.qualityMode or "auto",
		minimumTapTarget = tap,
		motion = motion,
		zIndex = z + 1,
		sound = function()
			deps.audio:play(Tokens.sound.uiTab)
		end,
		hoverSound = function()
			deps.audio:play(Tokens.sound.uiHover)
		end,
		onSelect = function(id)
			if not send({ qualityMode = id }) then
				quality.select(settings.qualityMode or "auto", true)
			end
		end,
	})
	quality.frame.LayoutOrder = 21
	table.insert(cleanups, quality.destroy)
	local qualityNote = FrameKit.text(
		container,
		"QualityNote",
		"Auto picks a tier for your device. Lower tiers trim feathers, particles and effects.",
		"caption",
		{ zIndex = z, color = Tokens.color.inkMuted }
	)
	qualityNote.LayoutOrder = 22
	qualityNote.Size = UDim2.new(1, 0, 0, Tokens.typography.caption.size * 2 + Tokens.spacing.xs)
	FrameKit.outline(qualityNote, 2)

	local done = Button.build(container, {
		text = "DONE",
		variant = "success",
		minimumTapTarget = tap,
		motion = motion,
		size = UDim2.new(1, 0, 0, tap),
		zIndex = z + 1,
		sound = function()
			deps.audio:play(Tokens.sound.uiTap)
		end,
		onActivated = api.close,
	})
	done.button.LayoutOrder = 30
	table.insert(cleanups, done.destroy)
	api.setInitialFocus(firstRow or done.button)
	deps.audio:play(Tokens.sound.uiOpen)

	return function()
		for _, cleanup in ipairs(cleanups) do
			if type(cleanup) == "function" then
				cleanup()
			else
				cleanup:Disconnect()
			end
		end
		deps.audio:play(Tokens.sound.uiClose)
	end
end

return SettingsModal
