--!strict
-- Shop modal (Perk Bench): the four permanent perks as cards with level meters, old -> new previews,
-- the server cost in Gems, atomic purchases with a pending state, and a celebratory maxed state.
-- Cards react to affordability (lit gold Buy / dimmed with a lock), pop and confetti on purchase.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local Perks = require(Shared.Domain.Perks)
local Tween = require(script.Parent.Parent.Components.Tween)
local FrameKit = require(script.Parent.Parent.Components.Frame)
local Button = require(script.Parent.Parent.Components.Button)
local Icons = require(script.Parent.Parent.Components.Icons)
local Skin = require(script.Parent.Parent.Components.Skin)
local Confetti = require(script.Parent.Parent.Components.Confetti)

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
	quality: any?,
}

local COPY: { [string]: { title: string, what: string, icon: string } } = {
	bagSize = { title = "Bigger Bag", what = "bag capacity", icon = "feather" },
	handGrab = { title = "Steady Hands", what = "Hand grasp", icon = "star" },
	gemValue = { title = "Gem Polish", what = "Gem rewards", icon = "gem" },
	featherValue = { title = "Feather Appraisal", what = "sale value", icon = "coin" },
}

function ShopModal.build(container: ScrollingFrame, api: any, deps: Deps): () -> ()
	local cleanups: { any } = {}
	local cfg = deps.config
	local motion = deps.accessibility:motionSettings()
	local tap = deps.minimumTapTarget
	local z = container.ZIndex + 1

	-- Balance chip + note.
	local balanceRow = Instance.new("Frame")
	balanceRow.Name = "BalanceRow"
	balanceRow.BackgroundTransparency = 1
	balanceRow.Size = UDim2.new(1, 0, 0, tap)
	balanceRow.LayoutOrder = 1
	balanceRow.ZIndex = z
	balanceRow.Parent = container
	local balanceChip, balanceLabel, balanceIcon = FrameKit.chip(balanceRow, "Balance", { zIndex = z + 1 })
	balanceIcon.Visible = true
	if not Skin.icon(balanceIcon, "hud.gem", Tokens.icon.md, balanceIcon.ZIndex + 1) then
		Icons.gem(balanceIcon, Tokens.icon.md, { zIndex = balanceIcon.ZIndex + 1 })
	end
	balanceLabel.Text = "0"
	balanceChip.AnchorPoint = Vector2.new(1, 0.5)
	balanceChip.Position = UDim2.fromScale(1, 0.5)
	local note = FrameKit.text(
		balanceRow,
		"Note",
		"Permanent perks stay with you across every search. Each level adds a steady bonus.",
		"caption",
		{ zIndex = z, color = Tokens.color.inkMuted }
	)
	note.Size = UDim2.new(1, -(tap * 3), 1, 0)

	type Row = {
		frame: Frame,
		title: TextLabel,
		detail: TextLabel,
		meter: FrameKit.MeterHandle,
		buy: any,
		badge: TextLabel,
		perkId: string,
		scale: UIScale,
		displayedLevel: number?,
	}
	local rows: { Row } = {}
	for index, perkId in ipairs(Perks.IDS) do
		local copy = COPY[perkId]
		local frame = FrameKit.row(container, "Perk_" .. perkId, tap * 2 + Tokens.spacing.lg, z, { padding = Tokens.spacing.md })
		frame.LayoutOrder = 10 + index
		local scale = Instance.new("UIScale")
		scale.Parent = frame
		FrameKit.shadow(frame, { radius = Tokens.radius.md })
		-- Icon badge.
		local badgeFrame = Instance.new("Frame")
		badgeFrame.Name = "IconBadge"
		badgeFrame.AnchorPoint = Vector2.new(0, 0.5)
		badgeFrame.Position = UDim2.fromScale(0, 0.5)
		badgeFrame.Size = UDim2.fromOffset(tap, tap)
		badgeFrame.BackgroundColor3 = Tokens.color.creamPill
		badgeFrame.ZIndex = z + 1
		local badgeCorner = Instance.new("UICorner")
		badgeCorner.CornerRadius = UDim.new(1, 0)
		badgeCorner.Parent = badgeFrame
		local badgeStroke = Instance.new("UIStroke")
		badgeStroke.Thickness = Tokens.stroke.standard
		badgeStroke.Color = Tokens.color.outline
		badgeStroke.Parent = badgeFrame
		local glyph = Icons.build(copy.icon, badgeFrame, Tokens.icon.lg, { zIndex = z + 2 })
		glyph.AnchorPoint = Vector2.new(0.5, 0.5)
		glyph.Position = UDim2.fromScale(0.5, 0.5)
		badgeFrame.Parent = frame
		local left = tap + Tokens.spacing.md
		local title = FrameKit.text(frame, "Title", copy.title, "heading", { zIndex = z + 1, color = Tokens.color.inkStrong })
		title.Position = UDim2.fromOffset(left, Tokens.spacing.sm)
		title.Size = UDim2.new(1, -(left + tap * 3), 0, Tokens.typography.heading.size + 2)
		local badge = FrameKit.badge(frame, "Badge", "MAX", Tokens.color.success, z + 2)
		badge.AnchorPoint = Vector2.new(0, 0)
		badge.Position = UDim2.fromOffset(left, Tokens.spacing.sm + 1)
		badge.Visible = false
		local detail = FrameKit.text(frame, "Detail", "", "caption", { zIndex = z + 1, color = Tokens.color.inkMuted })
		detail.Position = UDim2.fromOffset(left, Tokens.typography.heading.size + Tokens.spacing.md)
		detail.Size = UDim2.new(1, -(left + tap * 3), 0, Tokens.typography.caption.size * 2 + 4)
		local meterTrack, _, meter = FrameKit.meter(frame, "Meter", 0, {
			height = 10,
			zIndex = z + 1,
			motion = function()
				return deps.accessibility:motionSettings()
			end,
		})
		meterTrack.AnchorPoint = Vector2.new(0, 1)
		meterTrack.Position = UDim2.new(0, left, 1, -Tokens.spacing.md)
		meterTrack.Size = UDim2.new(1, -(left + tap * 3), 0, 10)
		local buy = Button.build(frame, {
			text = "Buy",
			variant = "primary",
			minimumTapTarget = tap,
			motion = motion,
			size = UDim2.fromOffset(tap * 3 - Tokens.spacing.lg, tap),
			zIndex = z + 2,
			textSize = Tokens.typography.body.size,
			sound = function()
				deps.audio:play(Tokens.sound.uiTap)
			end,
			hoverSound = function()
				deps.audio:play(Tokens.sound.uiHover)
			end,
		})
		buy.button.AnchorPoint = Vector2.new(1, 0.5)
		buy.button.Position = UDim2.fromScale(1, 0.5)
		table.insert(cleanups, buy.destroy)
		local row: Row = {
			frame = frame,
			title = title,
			detail = detail,
			meter = meter,
			buy = buy,
			badge = badge,
			perkId = perkId,
			scale = scale,
			displayedLevel = nil,
		}
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
					scale.Scale = 1.04
					Tween.scale(scale, "release", motion, 1)
					Confetti.burst(frame, {
						origin = UDim2.fromScale(0.5, 0.5),
						count = 18,
						spread = 120,
						motion = motion,
						tier = deps.quality and deps.quality:tier() or nil,
						zIndex = z + 6,
					})
					deps.audio:play(Tokens.sound.uiConfetti)
					deps.toasts:push(string.format("%s reached level %d", copy.title, result.data.level), "success")
				else
					deps.audio:play(Tokens.sound.uiError)
					Tween.shake(frame, motion)
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
		balanceLabel.Text = tostring(projection.currencies.gems)
		for _, row in ipairs(rows) do
			local preview = Perks.preview(cfg, row.perkId, projection.permanentPerks[row.perkId] or 0)
			local currentPct = math.floor((preview.currentMultiplier - 1) * 100 + 0.5)
			row.meter.set(preview.level / preview.maxLevel, row.displayedLevel ~= nil and row.displayedLevel ~= preview.level)
			row.displayedLevel = preview.level
			if preview.maxed then
				row.detail.Text =
					string.format("Level %d / %d  -  +%d%% %s", preview.level, preview.maxLevel, currentPct, COPY[row.perkId].what)
				row.detail.TextColor3 = Tokens.color.leafDeep
				row.buy.button.Visible = false
				row.badge.Visible = true
				row.badge.Position = UDim2.fromOffset(
					row.title.Position.X.Offset + math.ceil(row.title.TextBounds.X) + Tokens.spacing.sm,
					Tokens.spacing.sm + 1
				)
				row.meter.setColor(Tokens.color.leafBright)
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
				row.detail.TextColor3 = Tokens.color.inkMuted
				row.buy.button.Visible = true
				row.badge.Visible = false
				local affordable = projection.currencies.gems >= (preview.costGems or 0)
				row.buy.setText(string.format("%d Gems", preview.costGems or 0))
				row.buy.setEnabled(affordable)
				row.meter.setColor(Tokens.color.gold)
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
