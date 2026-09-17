--!strict
-- Moonlit Chest modal: shows exactly what the event chest holds (configured odds and token cost) so
-- the station has an honest purpose now; opening and the token/Robux bundles activate with the
-- event in Phase 5 through the same panel. No purchase prompt exists here.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local FrameKit = require(script.Parent.Parent.Components.Frame)
local Button = require(script.Parent.Parent.Components.Button)

local EventModal = {}

export type Deps = {
	profile: any,
	audio: any,
	accessibility: any,
	config: { [string]: any },
	minimumTapTarget: number,
}

local function prettify(id: string): string
	local spaced = string.gsub(id, "(%l)(%u)", "%1 %2")
	return string.upper(string.sub(spaced, 1, 1)) .. string.sub(spaced, 2)
end

-- Every list row carries the reference's thick near-black keyline.
local function thicken(row: Frame)
	local stroke = row:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Thickness = Tokens.depth.keyline
		stroke.Transparency = 0
	end
end

function EventModal.build(container: ScrollingFrame, api: any, deps: Deps): () -> ()
	local cleanups: { any } = {}
	local cfg = deps.config
	local motion = deps.accessibility:motionSettings()
	local tap = deps.minimumTapTarget
	local z = container.ZIndex + 1
	local chest = cfg.monetization.eventChest

	-- The balance sits in a dark band at the top; the odds are slate rows beneath it.
	local balanceRow = FrameKit.row(container, "BalanceRow", tap, z, { muted = true })
	balanceRow.LayoutOrder = 1
	thicken(balanceRow)
	local balance = FrameKit.text(balanceRow, "Balance", "", "heading", { zIndex = z + 1, color = Tokens.color.sky })
	balance.Size = UDim2.fromScale(1, 1)
	balance.TextYAlignment = Enum.TextYAlignment.Center
	FrameKit.outline(balance, 2.5)
	local intro = FrameKit.text(
		container,
		"Intro",
		string.format("A sealed chest from the moonlit cellar. Each opening costs %d Event Tokens and holds one of these:", chest.tokenCost),
		"body",
		{ zIndex = z, color = Tokens.color.featherWhite }
	)
	intro.LayoutOrder = 2
	intro.Size = UDim2.new(1, 0, 0, Tokens.typography.body.size * 3 + 6)
	FrameKit.outline(intro, 2)
	for index, reward in ipairs(chest.rewards) do
		local row = FrameKit.row(container, "Reward_" .. reward.id, tap + Tokens.spacing.sm, z)
		row.LayoutOrder = 10 + index
		thicken(row)
		local text = if reward.min
			then string.format("%s  -  %d to %d Gems", prettify(reward.id), reward.min, reward.max)
			else string.format("%s  -  tool skin", prettify(reward.id))
		local label = FrameKit.text(row, "Text", text, "label", { zIndex = z + 1, color = Tokens.color.featherWhite })
		label.Size = UDim2.fromScale(0.75, 1)
		label.TextYAlignment = Enum.TextYAlignment.Center
		label.TextTruncate = Enum.TextTruncate.AtEnd
		FrameKit.outline(label, 2.5)
		local odds = FrameKit.text(
			row,
			"Odds",
			string.format("%.1f%%", reward.weight),
			"label",
			{ align = Enum.TextXAlignment.Right, zIndex = z + 1, color = Tokens.color.gold }
		)
		odds.AnchorPoint = Vector2.new(1, 0)
		odds.Position = UDim2.fromScale(1, 0)
		odds.Size = UDim2.fromScale(0.25, 1)
		odds.TextYAlignment = Enum.TextYAlignment.Center
		FrameKit.outline(odds, 2.5)
	end
	local note = FrameKit.text(
		container,
		"Note",
		"Duplicate skins turn into Event Tokens. The chest unseals when the Moonlit event begins.",
		"caption",
		{ zIndex = z, color = Tokens.color.inkMuted }
	)
	note.LayoutOrder = 30
	note.Size = UDim2.new(1, 0, 0, Tokens.typography.caption.size * 2 + 6)
	FrameKit.outline(note, 2)
	local sealed = Button.build(container, {
		text = "SEALED FOR NOW",
		variant = "secondary",
		minimumTapTarget = tap,
		motion = motion,
		size = UDim2.new(1, 0, 0, tap),
		zIndex = z + 1,
	})
	sealed.button.LayoutOrder = 31
	sealed.setEnabled(false)
	table.insert(cleanups, sealed.destroy)
	api.setInitialFocus(api.shell.closeButton)

	local function render()
		local projection = deps.profile.projection
		balance.Text = string.format("Event Tokens %d", projection and projection.currencies.eventTokens or 0)
	end
	render()
	table.insert(cleanups, deps.profile.changed:Connect(render))
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

return EventModal
