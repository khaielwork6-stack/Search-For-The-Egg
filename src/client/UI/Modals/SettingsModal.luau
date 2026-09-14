--!strict
-- Settings modal: comfort switches (reduced motion, camera shake, haptics) as proper toggle rows,
-- a quality selector as tabs, and Done. Every change round-trips through SettingsUpdate; the row
-- only settles into its new state after the server acknowledged it, and snaps back on refusal.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
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
	FrameKit.heading(container, "ComfortHeading", "Comfort", z).LayoutOrder = 1

	local function send(payload: { [string]: any }): boolean
		local result = deps.net:request("SettingsUpdate", payload)
		if result.ok then
			deps.audio:play(Tokens.sound.uiConfirm)
			return true
		end
		deps.toasts:push("Could not save setting", "warning")
		deps.audio:play(Tokens.sound.uiError)
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
		firstRow = firstRow or handle.row
		table.insert(cleanups, handle.destroy)
	end

	FrameKit.heading(container, "QualityHeading", "Graphics quality", z).LayoutOrder = 20
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

	local done = Button.build(container, {
		text = "Done",
		variant = "primary",
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
			cleanup()
		end
		deps.audio:play(Tokens.sound.uiClose)
	end
end

return SettingsModal
