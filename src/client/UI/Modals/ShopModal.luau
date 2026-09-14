--!strict
-- Shop modal (Perk Bench): the four permanent perks with level meters, old -> new previews, the
-- server cost in Gems, atomic purchases with a pending state, and a celebratory maxed state. Gem
-- bundles and passes arrive in Phase 5 through the same panel; until then the shop is the bench.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local Perks = require(Shared.Domain.Perks)
local Tween = require(script.Parent.Parent.Components.Tween)
local FrameKit = require(script.Parent.Parent.Components.Frame)
local Button = require(script.Parent.Parent.Components.Button)

local ShopModal = {}

export type Deps = {
	net: any,
	profile: any,
	audio: any,
	haptics: any,
	accessibility: any,
	config: { [string]: any },
	minimumTapTarget: number,
	toasts: any,
}

local COPY: { [string]: { title: string, what: string } } = {
	bagSize = { title = "Bigger Bag", what = "bag capacity" },
	handGrab = { title = "Steady Hands", what = "Hand grasp" },
	gemValue = { title = "Gem Polish", what = "Gem rewards" },
	featherValue = { title = "Feather Appraisal", what = "sale value" },
}

function ShopModal.build(container: ScrollingFrame, api: any, deps: Deps): () -> ()
	local cleanups: { any } = {}
	local cfg = deps.config
	local motion = deps.accessibility:motionSettings()
	local tap = deps.minimumTapTarget
	local z = container.ZIndex + 1

	local balance = FrameKit.text(container, "Balance", "", "heading", { zIndex = z, color = Tokens.color.goldDeep })
	balance.LayoutOrder = 1
	local note = FrameKit.text(
		container,
		"Note",
		"Permanent perks stay with you across every search. Each level adds a steady bonus; costs rise per level.",
		"caption",
		{ zIndex = z, color = Tokens.color.inkMuted }
	)
	note.LayoutOrder = 2
	note.Size = UDim2.new(1, 0, 0, Tokens.typography.caption.size * 2 + 6)

	type Row = { frame: Frame, title: TextLabel, detail: TextLabel, meterFill: Frame, buy: any, perkId: string }
	local rows: { Row } = {}
	for index, perkId in ipairs(Perks.IDS) do
		local frame = FrameKit.row(container, "Perk_" .. perkId, tap * 2 + Tokens.spacing.md, z)
		frame.LayoutOrder = 10 + index
		local title = FrameKit.text(frame, "Title", COPY[perkId].title, "heading", { zIndex = z + 1, color = Tokens.color.goldDeep })
		title.Position = UDim2.fromOffset(0, Tokens.spacing.xs)
		title.Size = UDim2.new(1, -(tap * 3), 0, Tokens.typography.heading.size + 2)
		local detail = FrameKit.text(frame, "Detail", "", "caption", { zIndex = z + 1 })
		detail.Position = UDim2.fromOffset(0, Tokens.typography.heading.size + Tokens.spacing.sm)
		detail.Size = UDim2.new(1, -(tap * 3), 0, Tokens.typography.caption.size * 2 + 4)
		local meter, fill = FrameKit.meter(frame, "Meter", 0, { height = 8, zIndex = z + 1 })
		meter.AnchorPoint = Vector2.new(0, 1)
		meter.Position = UDim2.new(0, 0, 1, -Tokens.spacing.sm)
		meter.Size = UDim2.new(1, -(tap * 3), 0, 8)
		local buy = Button.build(frame, {
			text = "Buy",
			variant = "gold",
			minimumTapTarget = tap,
			motion = motion,
			size = UDim2.fromOffset(tap * 3 - Tokens.spacing.md, tap),
			zIndex = z + 1,
		})
		buy.button.AnchorPoint = Vector2.new(1, 0.5)
		buy.button.Position = UDim2.fromScale(1, 0.5)
		buy.button.TextSize = Tokens.typography.body.size
		table.insert(cleanups, buy.destroy)
		local row: Row = { frame = frame, title = title, detail = detail, meterFill = fill, buy = buy, perkId = perkId }
		table.insert(rows, row)
		table.insert(
			cleanups,
			buy.button.Activated:Connect(function()
				local projection = deps.profile.projection
				if not projection then
					return
				end
				local level = projection.permanentPerks[perkId] or 0
				buy.setPending(true, "...")
				local result = deps.net:request("PerkPurchase", { perkId = perkId, expectedLevel = level })
				buy.setPending(false)
				if result.ok then
					deps.audio:play(Tokens.sound.upgradeChord)
					deps.haptics:pulse(0.5, 0.1)
					Tween.rotationPunch(frame, motion, 0)
					deps.toasts:push(string.format("%s reached level %d", COPY[perkId].title, result.data.level), "success")
				else
					deps.audio:play(Tokens.sound.uiError)
					local message = if result.code == "insufficient_funds"
						then "Not enough Gems"
						elseif result.code == "stale_token" then "Levels changed - try again"
						elseif result.message == "maxed" then "Already at the top"
						elseif result.message == "not_in_lobby" then "Perks change between searches"
						else "Purchase unavailable"
					deps.toasts:push(message, "warning")
				end
			end)
		)
	end
	if rows[1] then
		api.setInitialFocus(rows[1].buy.button)
	end

	local function render()
		local projection = deps.profile.projection
		if not projection then
			return
		end
		balance.Text = string.format("Gems %d", projection.currencies.gems)
		for _, row in ipairs(rows) do
			local preview = Perks.preview(cfg, row.perkId, projection.permanentPerks[row.perkId] or 0)
			local currentPct = math.floor((preview.currentMultiplier - 1) * 100 + 0.5)
			row.meterFill.Size = UDim2.fromScale(preview.level / preview.maxLevel, 1)
			if preview.maxed then
				row.detail.Text = string.format(
					"Level %d / %d  -  +%d%% %s  -  FULLY POLISHED",
					preview.level,
					preview.maxLevel,
					currentPct,
					COPY[row.perkId].what
				)
				row.detail.TextColor3 = Tokens.color.goldDeep
				row.buy.button.Visible = false
				row.meterFill.BackgroundColor3 = Tokens.color.leafBright
			else
				local nextPct = math.floor(((preview.nextMultiplier or 1) - 1) * 100 + 0.5)
				row.detail.Text = string.format(
					"Level %d / %d  -  +%d%% -> +%d%% %s",
					preview.level,
					preview.maxLevel,
					currentPct,
					nextPct,
					COPY[row.perkId].what
				)
				row.detail.TextColor3 = Tokens.color.ink
				row.buy.button.Visible = true
				row.buy.setText(string.format("%d Gems", preview.costGems or 0))
				row.buy.setEnabled(projection.currencies.gems >= (preview.costGems or 0))
				row.meterFill.BackgroundColor3 = Tokens.color.gold
			end
		end
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

return ShopModal
