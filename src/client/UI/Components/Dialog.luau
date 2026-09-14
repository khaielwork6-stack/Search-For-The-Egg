--!strict
-- Confirmation / error dialog on top of the modal stack: a compact card with a tone strip, title,
-- message, and one or two buttons. Confirm is the initial controller focus; Cancel/Back closes it.
-- Built through ModalController so blur, mouse unlock, and focus rules stay uniform.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local FrameKit = require(script.Parent.Frame)
local Button = require(script.Parent.Button)
local Icons = require(script.Parent.Icons)

local Dialog = {}

export type Options = {
	id: string?,
	title: string,
	message: string,
	confirmText: string?,
	cancelText: string?, -- nil = single-button dialog
	tone: ("info" | "warning" | "danger" | "success")?,
	onConfirm: (() -> ())?,
	onCancel: (() -> ())?,
	audio: any,
	accessibility: any,
	config: { [string]: any },
}

local TONES = {
	info = { color = Tokens.color.tealAccent, icon = "feather" },
	warning = { color = Tokens.color.warning, icon = "star" },
	danger = { color = Tokens.color.danger, icon = "close" },
	success = { color = Tokens.color.success, icon = "check" },
}

function Dialog.open(modals: any, options: Options): boolean
	local id = options.id or ("dialog_" .. options.title)
	local tone = TONES[options.tone or "info"] or TONES.info
	local opened = modals:open(id, modals.Priority.Results, true, function(container, api)
		local cleanups: { any } = {}
		local z = container.ZIndex + 1
		local motion = options.accessibility:motionSettings()
		local tap = api.minimumTapTarget
		local strip = Instance.new("Frame")
		strip.Name = "ToneStrip"
		strip.Size = UDim2.new(1, 0, 0, Tokens.icon.lg + Tokens.spacing.md)
		strip.BackgroundTransparency = 1
		strip.LayoutOrder = 1
		strip.ZIndex = z
		strip.Parent = container
		local badge = Instance.new("Frame")
		badge.Name = "Badge"
		badge.AnchorPoint = Vector2.new(0.5, 0.5)
		badge.Position = UDim2.fromScale(0.5, 0.5)
		badge.Size = UDim2.fromOffset(Tokens.icon.lg + Tokens.spacing.md, Tokens.icon.lg + Tokens.spacing.md)
		badge.BackgroundColor3 = tone.color
		badge.ZIndex = z
		local badgeCorner = Instance.new("UICorner")
		badgeCorner.CornerRadius = UDim.new(1, 0)
		badgeCorner.Parent = badge
		local badgeStroke = Instance.new("UIStroke")
		badgeStroke.Thickness = Tokens.stroke.bold
		badgeStroke.Color = Tokens.color.outline
		badgeStroke.Parent = badge
		badge.Parent = strip
		local icon = Icons.build(tone.icon, badge, Tokens.icon.lg, { zIndex = z + 1, color = Tokens.color.featherWhite, outline = false })
		icon.AnchorPoint = Vector2.new(0.5, 0.5)
		icon.Position = UDim2.fromScale(0.5, 0.5)
		local message = FrameKit.text(
			container,
			"Message",
			options.message,
			"body",
			{ zIndex = z, align = Enum.TextXAlignment.Center, autoHeight = true }
		)
		message.LayoutOrder = 2
		message.Size = UDim2.new(1, 0, 0, Tokens.typography.body.size * 2 + Tokens.spacing.sm)
		local actions = Instance.new("Frame")
		actions.Name = "Actions"
		actions.BackgroundTransparency = 1
		actions.Size = UDim2.new(1, 0, 0, tap)
		actions.LayoutOrder = 3
		actions.ZIndex = z
		local layout = Instance.new("UIListLayout")
		layout.FillDirection = Enum.FillDirection.Horizontal
		layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Padding = UDim.new(0, Tokens.spacing.sm)
		layout.Parent = actions
		actions.Parent = container
		local confirm = Button.build(actions, {
			text = options.confirmText or "OK",
			variant = if options.tone == "danger" then "danger" else "primary",
			minimumTapTarget = tap,
			motion = motion,
			size = UDim2.fromOffset(160, tap),
			zIndex = z + 1,
			sound = function()
				options.audio:play(Tokens.sound.uiConfirm)
			end,
			onActivated = function()
				api.close()
				if options.onConfirm then
					options.onConfirm()
				end
			end,
		})
		confirm.button.LayoutOrder = 2
		confirm.button.Name = "ConfirmButton"
		table.insert(cleanups, confirm.destroy)
		if options.cancelText then
			local cancel = Button.build(actions, {
				text = options.cancelText,
				variant = "secondary",
				minimumTapTarget = tap,
				motion = motion,
				size = UDim2.fromOffset(140, tap),
				zIndex = z + 1,
				sound = function()
					options.audio:play(Tokens.sound.uiCancel)
				end,
				onActivated = function()
					api.close()
					if options.onCancel then
						options.onCancel()
					end
				end,
			})
			cancel.button.LayoutOrder = 1
			cancel.button.Name = "CancelButton"
			table.insert(cleanups, cancel.destroy)
		end
		api.setInitialFocus(confirm.button)
		options.audio:play(if options.tone == "danger" or options.tone == "warning" then Tokens.sound.uiError else Tokens.sound.uiOpen)
		return function()
			for _, cleanup in ipairs(cleanups) do
				cleanup()
			end
		end
	end, options.title, { compact = true })
	return opened == true
end

return Dialog
