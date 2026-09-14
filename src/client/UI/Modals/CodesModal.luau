--!strict
-- Nest Mailbox modal: one text field (tap-height), a Redeem button, and a feedback line. Codes are
-- normalized and validated on the server; the client never sees the code list. Rate limits and
-- refusals read as friendly copy; rewards animate only after the server grant.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local FrameKit = require(script.Parent.Parent.Components.Frame)
local Button = require(script.Parent.Parent.Components.Button)
local Skin = require(script.Parent.Parent.Components.Skin)
local Tween = require(script.Parent.Parent.Components.Tween)
local Confetti = require(script.Parent.Parent.Components.Confetti)

local CodesModal = {}

export type Deps = {
	net: any,
	profile: any,
	audio: any,
	haptics: any,
	accessibility: any,
	config: { [string]: any },
	minimumTapTarget: number,
	toasts: any,
	quality: any?,
}

function CodesModal.build(container: ScrollingFrame, api: any, deps: Deps): () -> ()
	local cleanups: { any } = {}
	local cfg = deps.config
	local motion = deps.accessibility:motionSettings()
	local tap = deps.minimumTapTarget
	local z = container.ZIndex + 1

	local intro =
		FrameKit.text(container, "Intro", "Found a code from the community? Post it here for a nest gift.", "body", { zIndex = z })
	intro.LayoutOrder = 1
	intro.Size = UDim2.new(1, 0, 0, Tokens.typography.body.size * 2 + 6)

	local box = Instance.new("TextBox")
	box.Name = "CodeBox"
	box.LayoutOrder = 2
	box.Size = UDim2.new(1, 0, 0, tap)
	box.BackgroundColor3 = Tokens.color.creamPill
	box.TextColor3 = Tokens.color.inkStrong
	box.PlaceholderText = "Enter a code"
	box.PlaceholderColor3 = Tokens.color.inkMuted
	box.Font = Tokens.typography.label.font
	box.TextSize = Tokens.typography.label.size
	box.ClearTextOnFocus = false
	box.Text = ""
	box.ZIndex = z + 1
	box.Selectable = true
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, Tokens.radius.pill)
	corner.Parent = box
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = Tokens.stroke.bold
	stroke.Color = Tokens.color.outline
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = box
	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, Tokens.spacing.xl)
	padding.PaddingRight = UDim.new(0, Tokens.spacing.xl)
	padding.Parent = box
	local boxArt = Skin.label(box, "textbox.idle", { zIndex = z + 2, inset = 2, name = "ArtFrame" })
	if boxArt then
		stroke.Enabled = false
		box.BackgroundColor3 = Tokens.color.featherWhite
		box.ZIndex = z + 1
	end
	local function boxState(state: string)
		if boxArt then
			Skin.apply(boxArt, "textbox." .. state)
		else
			stroke.Color = if state == "error"
				then Tokens.color.danger
				elseif state == "focused" then Tokens.color.tealAccent
				else Tokens.color.outline
		end
	end
	box.Focused:Connect(function()
		boxState("focused")
	end)
	box.Parent = container
	table.insert(
		cleanups,
		box:GetPropertyChangedSignal("Text"):Connect(function()
			local limit = cfg.codePolicy.maxLength + 8
			if #box.Text > limit then
				box.Text = string.sub(box.Text, 1, limit)
			end
		end)
	)

	local feedback = FrameKit.text(container, "Feedback", "", "body", { zIndex = z, color = Tokens.color.goldDeep })
	feedback.LayoutOrder = 3

	local function fail(text: string)
		feedback.Text = text
		feedback.TextColor3 = Tokens.color.danger
		boxState("error")
		Tween.shake(box, motion)
	end
	local function redeem()
		local raw = box.Text
		if #raw == 0 then
			fail("Type a code first")
			return
		end
		local result = deps.net:request("CodeRedeem", { code = string.sub(raw, 1, cfg.codePolicy.maxLength + 8) })
		if result.ok then
			deps.audio:play(Tokens.sound.rewardLand)
			deps.haptics:pulse(0.6, 0.1)
			local data = result.data
			feedback.Text = string.format("Gift received: %d Gems, %d Event Tokens", data.gems, data.eventTokens or 0)
			feedback.TextColor3 = Tokens.color.leafDeep
			boxState("idle")
			Confetti.burst(box, {
				origin = UDim2.fromScale(0.5, 0.5),
				count = 24,
				spread = 160,
				motion = motion,
				tier = deps.quality and deps.quality:tier() or nil,
				zIndex = z + 8,
			})
			deps.audio:play(Tokens.sound.uiConfetti)
			deps.toasts:reward("Code accepted", data.gems)
			box.Text = ""
		else
			deps.audio:play(Tokens.sound.uiError)
			if result.code == "rate_limited" then
				fail("Slow down - the mailbox needs a moment")
			elseif result.code == "already_done" then
				fail("That code was already opened on this account")
			elseif result.message == "expired_code" then
				fail("That code has expired")
			elseif result.code == "invalid_payload" then
				fail("Codes use letters and numbers only")
			else
				fail("No gift under that code")
			end
		end
	end

	local redeemHandle = Button.build(container, {
		text = "Redeem",
		variant = "primary",
		sound = function()
			deps.audio:play(Tokens.sound.uiTap)
		end,
		hoverSound = function()
			deps.audio:play(Tokens.sound.uiHover)
		end,
		minimumTapTarget = tap,
		motion = motion,
		size = UDim2.new(1, 0, 0, tap),
		zIndex = z + 1,
		onActivated = redeem,
	})
	redeemHandle.button.LayoutOrder = 4
	redeemHandle.button.Name = "RedeemButton"
	table.insert(cleanups, redeemHandle.destroy)
	table.insert(
		cleanups,
		box.FocusLost:Connect(function(enterPressed)
			if enterPressed then
				redeem()
			end
		end)
	)
	api.setInitialFocus(box)
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

return CodesModal
