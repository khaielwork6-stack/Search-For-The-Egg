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

function EventModal.build(container: ScrollingFrame, api: any, deps: Deps): () -> ()
	local cleanups: { any } = {}
	local cfg = deps.config
	local motion = deps.accessibility:motionSettings()
	local tap = deps.minimumTapTarget
	local z = container.ZIndex + 1
	local chest = cfg.monetization.eventChest

	local balance = FrameKit.text(container, "Balance", "", "heading", { zIndex = z, color = Tokens.color.goldDeep })
	balance.LayoutOrder = 1
	local intro = FrameKit.text(
		container,
		"Intro",
		string.format("A sealed chest from the moonlit cellar. Each opening costs %d Event Tokens and holds one of these:", chest.tokenCost),
		"body",
		{ zIndex = z }
	)
	intro.LayoutOrder = 2
	intro.Size = UDim2.new(1, 0, 0, Tokens.typography.body.size * 3 + 6)
	for index, reward in ipairs(chest.rewards) do
		local row = FrameKit.row(container, "Reward_" .. reward.id, tap, z)
		row.LayoutOrder = 10 + index
		local text = if reward.min
			then string.format("%s  -  %d to %d Gems", prettify(reward.id), reward.min, reward.max)
			else string.format("%s  -  tool skin", prettify(reward.id))
		FrameKit.text(row, "Text", text, "body", { zIndex = z + 1 }).Size = UDim2.fromScale(0.75, 1)
		local odds = FrameKit.text(
			row,
			"Odds",
			string.format("%.1f%%", reward.weight),
			"numeral",
			{ align = Enum.TextXAlignment.Right, zIndex = z + 1, color = Tokens.color.goldDeep }
		)
		odds.AnchorPoint = Vector2.new(1, 0)
		odds.Position = UDim2.fromScale(1, 0)
		odds.Size = UDim2.fromScale(0.25, 1)
		odds.TextSize = Tokens.typography.body.size
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
	local sealed = Button.build(container, {
		text = "Sealed for now",
		variant = "ghost",
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
