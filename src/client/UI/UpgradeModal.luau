--!strict
-- Workbench modal: rows from the server's previews grouped by tool. Hand & Bag first, then each
-- configured tool either as an acquisition row (round cash or Gems) or as its upgrade paths. Every
-- row shows old -> new and the authoritative cost; Buy sends UpgradePurchase with the expected
-- level and re-renders from the result. Maxed rows celebrate; permanent grants say so.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local EconomyMath = require(Shared.EconomyMath)
local ToolSpecs = require(Shared.Domain.ToolSpecs)
local Button = require(script.Parent.Components.Button)
local Confetti = require(script.Parent.Components.Confetti)
local UpgradeActions = require(script.Parent.UpgradeActions)
local FrameKit = require(script.Parent.Components.Frame)
local Depth = require(script.Parent.Components.Depth)
local Skin = require(script.Parent.Components.Skin)

local UpgradeModal = {}

local UpgradeCopy = require(script.Parent.UpgradeCopy)
local LABELS = UpgradeCopy.LABELS
local TOOL_TAGLINES = UpgradeCopy.TOOL_TAGLINES

export type Deps = {
	net: any,
	round: any,
	audio: any,
	haptics: any,
	accessibility: any,
	config: { [string]: any },
	minimumTapTarget: number,
	toasts: any,
	profile: any?,
}

local function orderOf(preview: any): number
	if preview.kind == "bag" then
		return 1
	elseif preview.kind == "hand" then
		return ({ grasp = 2, speed = 3, hold = 4 })[preview.pathName] or 5
	end
	local toolIndex = table.find(ToolSpecs.TOOL_IDS, preview.toolId) or 0
	local base = 10 + toolIndex * 10
	if preview.kind == "acquire" then
		return base
	end
	return base + (table.find(ToolSpecs.PATHS[preview.toolId], preview.pathName) or 0)
end

local function costText(preview: any): string
	if preview.costGems then
		return string.format("%d Gems", preview.costGems)
	end
	return EconomyMath.formatCents(preview.costCents or 0)
end

-- Builds the modal body inside `container`; returns a cleanup function.
function UpgradeModal.build(container: Frame, api: { close: () -> () }, deps: Deps): () -> ()
	local cleanups: { any } = {}
	local rows: { [string]: any } = {}
	local headers: { [string]: TextLabel } = {}

	local cashLabel = Instance.new("TextLabel")
	cashLabel.Name = "Cash"
	cashLabel.Size = UDim2.new(1, 0, 0, Tokens.typography.heading.size + Tokens.spacing.sm)
	cashLabel.BackgroundTransparency = 1
	cashLabel.Font = Tokens.typography.label.font
	cashLabel.TextSize = Tokens.typography.label.size
	cashLabel.TextColor3 = Tokens.color.gold
	cashLabel.TextXAlignment = Enum.TextXAlignment.Left
	cashLabel.LayoutOrder = 0
	cashLabel.ZIndex = container.ZIndex + 1
	FrameKit.outline(cashLabel, 2)
	cashLabel.Parent = container

	local function header(key: string, text: string, order: number)
		if headers[key] then
			return
		end
		local row = FrameKit.heading(container, "Header_" .. key, text, container.ZIndex + 1)
		row.LayoutOrder = order
		local toolIcon = if key ~= "hand" then Skin.icon(row, "tool." .. key .. ".normal", Tokens.icon.md, container.ZIndex + 2) else nil
		if toolIcon then
			toolIcon.AnchorPoint = Vector2.new(1, 0.5)
			toolIcon.Position = UDim2.fromScale(1, 0.5)
		end
		headers[key] = row:FindFirstChild("Text") :: TextLabel
	end

	local function titleFor(preview: any): string
		local meta = LABELS[preview.upgradeId]
		if meta then
			return meta.title
		end
		if preview.kind == "acquire" then
			return deps.config.tools[preview.toolId].displayName
		end
		return preview.upgradeId
	end

	local function describe(preview: any, entry: any): string
		local meta = LABELS[preview.upgradeId]
		if meta then
			return meta.describe(entry)
		end
		if preview.kind == "acquire" then
			return if entry and entry.owned then "owned this round" else "not owned"
		end
		return "-"
	end

	local function purchase(upgradeId: string)
		local latest = UpgradeActions.previewFor(deps.round, upgradeId)
		local result = UpgradeActions.purchase(deps, upgradeId, latest and titleFor(latest) or nil)
		if result and result.ok then
			local row = rows[upgradeId]
			if row then
				-- The bought row flashes and its button hops so the purchase lands with weight.
				local face = row.frame
				local stroke = face:FindFirstChildOfClass("UIStroke")
				if stroke then
					local before = stroke.Color
					stroke.Color = Tokens.color.gold
					stroke.Thickness = Tokens.stroke.standard + 1.5
					TweenService:Create(stroke, TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
						Color = before,
						Thickness = Tokens.stroke.standard,
					}):Play()
				end
				row.handle.punch()
				Confetti.burst(row.frame, { origin = UDim2.fromScale(0.85, 0.5), count = 14, spread = 110 })
			end
		end
	end

	local function render()
		local previews = deps.round.previews or {}
		local player = deps.round.player
		local gems = deps.profile and deps.profile.projection and deps.profile.projection.currencies.gems or nil
		cashLabel.Text = "Round cash: "
			.. EconomyMath.formatCents(player and player.cashCents or 0)
			.. (if gems then string.format("    Gems: %d", gems) else "")
		header("hand", "Hand & Bag", 1)
		for _, preview in ipairs(previews) do
			local order = orderOf(preview)
			if preview.toolId then
				header(
					preview.toolId,
					deps.config.tools[preview.toolId].displayName,
					10 + (table.find(ToolSpecs.TOOL_IDS, preview.toolId) or 0) * 10 - 1
				)
			end
			local row = rows[preview.upgradeId]
			if not row then
				local z = container.ZIndex + 1
				local frame = FrameKit.row(container, "Row_" .. preview.upgradeId, deps.minimumTapTarget + Tokens.spacing.lg, z)
				local buttonWidth = math.max(deps.minimumTapTarget * 2, 128)
				-- Large item art on the left: the tool for tool rows, the hand or the bag otherwise.
				local artRole = if preview.toolId
					then "tool." .. preview.toolId .. ".normal"
					elseif preview.kind == "bag" then "icon.feather"
					else "tool.hand.normal"
				local artSize = deps.minimumTapTarget + Tokens.spacing.xs
				local artHolder = Instance.new("Frame")
				artHolder.Name = "Art"
				artHolder.AnchorPoint = Vector2.new(0, 0.5)
				artHolder.Position = UDim2.new(0, -Tokens.spacing.xs, 0.5, 0)
				artHolder.Size = UDim2.fromOffset(artSize, artSize)
				artHolder.BackgroundColor3 = Tokens.color.panelDeep
				artHolder.ZIndex = z + 1
				local artCorner = Instance.new("UICorner")
				artCorner.CornerRadius = UDim.new(1, 0)
				artCorner.Parent = artHolder
				Depth.keyline(artHolder, Tokens.depth.keylineThin)
				artHolder.Parent = frame
				local art = Skin.icon(artHolder, artRole, artSize - Tokens.spacing.sm, z + 2)
				if art then
					art.AnchorPoint = Vector2.new(0.5, 0.5)
					art.Position = UDim2.fromScale(0.5, 0.5)
				end
				local textLeft = artSize + Tokens.spacing.sm
				local textWidth = -(buttonWidth + Tokens.spacing.md + textLeft)
				local title = FrameKit.text(frame, "Title", "", "label", { zIndex = z + 1, color = Tokens.color.featherWhite })
				title.Position = UDim2.new(0, textLeft, 0.5, -(Tokens.typography.label.size + Tokens.spacing.xs) + 2)
				title.Size = UDim2.new(1, textWidth, 0, Tokens.typography.label.size + Tokens.spacing.xs)
				FrameKit.outline(title, 2)
				local detail = FrameKit.text(frame, "Detail", "", "caption", { zIndex = z + 1, color = Tokens.color.inkMuted })
				detail.Position = UDim2.new(0, textLeft, 0.5, 2)
				detail.Size = UDim2.new(1, textWidth, 0, Tokens.typography.caption.size + Tokens.spacing.xs)
				detail.RichText = true
				FrameKit.outline(detail, 2)
				-- Level pips sit after the title: one dot per level, filled up to the current one.
				local pips = Instance.new("Frame")
				pips.Name = "Pips"
				pips.BackgroundTransparency = 1
				pips.AnchorPoint = Vector2.new(0, 0.5)
				pips.Size = UDim2.fromOffset(0, 10)
				pips.AutomaticSize = Enum.AutomaticSize.X
				pips.ZIndex = z + 1
				local pipLayout = Instance.new("UIListLayout")
				pipLayout.FillDirection = Enum.FillDirection.Horizontal
				pipLayout.Padding = UDim.new(0, 3)
				pipLayout.VerticalAlignment = Enum.VerticalAlignment.Center
				pipLayout.SortOrder = Enum.SortOrder.LayoutOrder
				pipLayout.Parent = pips
				local pipDots: { Frame } = {}
				for index = 1, math.clamp(preview.maxLevel or 0, 0, 8) do
					local dot = Instance.new("Frame")
					dot.Name = "Pip" .. index
					dot.Size = UDim2.fromOffset(9, 9)
					dot.BackgroundColor3 = Tokens.color.panelDeep
					dot.BorderSizePixel = 0
					dot.ZIndex = z + 1
					dot.LayoutOrder = index
					local dotCorner = Instance.new("UICorner")
					dotCorner.CornerRadius = UDim.new(1, 0)
					dotCorner.Parent = dot
					local dotStroke = Instance.new("UIStroke")
					dotStroke.Thickness = 1.5
					dotStroke.Color = Tokens.color.outline
					dotStroke.Parent = dot
					dot.Parent = pips
					table.insert(pipDots, dot)
				end
				pips.Parent = frame
				local maxBadge = FrameKit.badge(frame, "MaxBadge", "MAX", Tokens.color.gold, z + 1)
				maxBadge.AnchorPoint = Vector2.new(1, 0.5)
				maxBadge.Position = UDim2.fromScale(1, 0.5)
				maxBadge.Visible = false
				local handle = Button.build(frame, {
					text = "Buy",
					variant = "primary",
					minimumTapTarget = deps.minimumTapTarget,
					motion = deps.accessibility:motionSettings(),
					size = UDim2.fromOffset(buttonWidth, deps.minimumTapTarget - Tokens.spacing.xs),
					zIndex = z + 2,
					textSize = Tokens.typography.body.size + 1,
					sound = function()
						deps.audio:play(Tokens.sound.uiTap)
					end,
					hoverSound = function()
						deps.audio:play(Tokens.sound.uiHover)
					end,
					onActivated = function()
						purchase(preview.upgradeId)
					end,
				})
				handle.button.AnchorPoint = Vector2.new(1, 0.5)
				handle.button.Position = UDim2.fromScale(1, 0.5)
				table.insert(cleanups, handle.destroy)
				row = {
					frame = frame,
					title = title,
					detail = detail,
					pips = pips,
					pipDots = pipDots,
					maxBadge = maxBadge,
					handle = handle,
				}
				rows[preview.upgradeId] = row
			end
			row.frame.LayoutOrder = order
			row.title.Text = titleFor(preview)
			-- Pips follow the title text so they never collide with it.
			row.pips.Position = UDim2.new(
				0,
				row.title.Position.X.Offset + math.ceil(row.title.TextBounds.X) + Tokens.spacing.md,
				0.5,
				-(Tokens.spacing.xs + 4)
			)
			row.pips.Visible = #row.pipDots > 1
			for index, dot in ipairs(row.pipDots) do
				local lit = index <= (preview.level or 0)
				dot.BackgroundColor3 = if lit then Tokens.color.gold else Tokens.color.panelDeep
			end
			local current = describe(preview, preview.current)
			if preview.maxed then
				local suffix = if preview.kind == "acquire"
					then (if preview.permanent then "Yours for keeps" else "Ready in your hotbar")
					elseif preview.permanent then "Fully upgraded, for keeps"
					else "Fully upgraded"
				row.detail.Text = string.format('%s  <font color="#%s">%s</font>', current, Tokens.color.success:ToHex(), suffix)
				row.handle.button.Visible = false
				row.maxBadge.Visible = true
				row.maxBadge.Text = if preview.kind == "acquire" then "OWNED" else "MAX"
			else
				local nextText = describe(preview, preview.next)
				row.detail.Text = if preview.kind == "acquire"
					then (TOOL_TAGLINES[preview.toolId or ""] or nextText)
					else string.format('%s  <font color="#%s">→  %s</font>', current, Tokens.color.gold:ToHex(), nextText)
				local cash = player and player.cashCents or 0
				local affordable = if preview.costGems then (gems or 0) >= preview.costGems else cash >= (preview.costCents or 0)
				row.handle.button.Visible = true
				row.handle.setText(costText(preview))
				row.handle.setVariant(if affordable then "primary" else "secondary")
				row.maxBadge.Visible = false
			end
		end
	end

	render()
	table.insert(cleanups, deps.round.upgrade:Connect(render))
	table.insert(cleanups, deps.round.playerChanged:Connect(render))
	if deps.profile then
		table.insert(cleanups, deps.profile.changed:Connect(render))
	end

	local done, doneCleanup = Button.create(container, {
		text = "Done",
		variant = "secondary",
		zIndex = container.ZIndex + 2,
		sound = function()
			deps.audio:play(Tokens.sound.uiTap)
		end,
		minimumTapTarget = deps.minimumTapTarget,
		motion = deps.accessibility:motionSettings(),
		size = UDim2.new(1, 0, 0, deps.minimumTapTarget),
		onActivated = api.close,
	})
	done.LayoutOrder = 999
	table.insert(cleanups, doneCleanup)

	return function()
		for _, cleanup in ipairs(cleanups) do
			if type(cleanup) == "function" then
				cleanup()
			else
				cleanup:Disconnect()
			end
		end
	end
end

return UpgradeModal
