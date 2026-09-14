--!strict
-- Workbench modal: rows from the server's previews grouped by tool. Hand & Bag first, then each
-- configured tool either as an acquisition row (round cash or Gems) or as its upgrade paths. Every
-- row shows old -> new and the authoritative cost; Buy sends UpgradePurchase with the expected
-- level and re-renders from the result. Maxed rows celebrate; permanent grants say so.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local EconomyMath = require(Shared.EconomyMath)
local ToolSpecs = require(Shared.Domain.ToolSpecs)
local Button = require(script.Parent.Components.Button)
local FrameKit = require(script.Parent.Components.Frame)
local Skin = require(script.Parent.Components.Skin)

local UpgradeModal = {}

local function seconds(value: number?): string
	return if value then string.format("%.2fs", value) else "-"
end

local LABELS: { [string]: { title: string, describe: (any) -> string } } = {
	bag = {
		title = "Bag capacity",
		describe = function(entry)
			return entry and (tostring(entry.capacity) .. " feathers") or "-"
		end,
	},
	handGrasp = {
		title = "Grasp",
		describe = function(entry)
			return entry and (tostring(entry.amount) .. " per pull") or "-"
		end,
	},
	handSpeed = {
		title = "Speed",
		describe = function(entry)
			return entry and (tostring(entry.walkSpeed) .. " walk") or "-"
		end,
	},
	handHold = {
		title = "Hold to gather",
		describe = function(entry)
			if not entry or not entry.enabled then
				return "off"
			end
			return "every " .. seconds(entry.intervalSeconds)
		end,
	},
	["nestRake.sweep"] = {
		title = "Sweep",
		describe = function(entry)
			return entry and (tostring(entry.yield) .. " per sweep") or "-"
		end,
	},
	["nestRake.cooldown"] = {
		title = "Cooldown",
		describe = function(entry)
			return entry and seconds(entry.seconds) or "-"
		end,
	},
	["nestRake.hold"] = {
		title = "Hold to rake",
		describe = function(entry)
			if not entry or not entry.enabled then
				return "off"
			end
			return "every " .. seconds(entry.intervalSeconds)
		end,
	},
	["confettiCharge.luckyBlast"] = {
		title = "Lucky Blast",
		describe = function(entry)
			return entry and string.format("%d%% rainbow", math.floor(entry.rainbowChance * 100 + 0.5)) or "-"
		end,
	},
	["confettiCharge.speed"] = {
		title = "Speed",
		describe = function(entry)
			return entry and (seconds(entry.fuseSeconds) .. " fuse") or "-"
		end,
	},
	["confettiCharge.power"] = {
		title = "Power",
		describe = function(entry)
			return entry and string.format("%d studs, %d feathers", entry.radiusStuds, entry.yield) or "-"
		end,
	},
	["featherVac.power"] = {
		title = "Power",
		describe = function(entry)
			return entry and (tostring(entry.perSecond) .. " per second") or "-"
		end,
	},
	["featherVac.cooling"] = {
		title = "Cooling",
		describe = function(entry)
			return entry and seconds(entry.seconds) or "-"
		end,
	},
	["featherVac.runtime"] = {
		title = "Runtime",
		describe = function(entry)
			return entry and seconds(entry.seconds) or "-"
		end,
	},
	["scoutChick.speed"] = {
		title = "Speed",
		describe = function(entry)
			return entry and (tostring(entry.value) .. " studs/s") or "-"
		end,
	},
	["scoutChick.grasp"] = {
		title = "Grasp",
		describe = function(entry)
			return entry and (tostring(entry.value) .. " per peck") or "-"
		end,
	},
	["scoutChick.capacity"] = {
		title = "Capacity",
		describe = function(entry)
			return entry and (tostring(entry.value) .. " feathers") or "-"
		end,
	},
}

-- One line per tool for the acquisition row; the paths describe themselves once the tool is owned.
local TOOL_TAGLINES: { [string]: string } = {
	nestRake = "Sweeps several feathers in one pull",
	confettiCharge = "Blasts a patch of the nest loose",
	featherVac = "Hoovers feathers while it runs",
	scoutChick = "A chick that pecks feathers for you",
}

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
	cashLabel.TextColor3 = Tokens.color.goldDeep
	cashLabel.TextXAlignment = Enum.TextXAlignment.Left
	cashLabel.LayoutOrder = 0
	cashLabel.ZIndex = container.ZIndex + 1
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
		local latest = nil
		for _, p in ipairs(deps.round.previews or {}) do
			if p.upgradeId == upgradeId then
				latest = p
			end
		end
		local token = deps.round:sessionToken()
		if not latest or latest.maxed or not token then
			return
		end
		local result = deps.net:request("UpgradePurchase", { sessionToken = token, upgradeId = upgradeId, expectedLevel = latest.level })
		if result.ok then
			deps.audio:play(Tokens.sound.upgradeChord)
			deps.haptics:pulse(0.5, 0.1)
			local title = titleFor(latest)
			deps.toasts:push(if latest.kind == "acquire" then title .. " acquired" else title .. " improved", "success")
		else
			deps.audio:play(Tokens.sound.uiError)
			local message = if result.code == "insufficient_funds"
				then (if result.message == "gems" then "Not enough Gems" else "Not enough round cash")
				elseif result.code == "out_of_range" then "Stand at the workbench"
				elseif result.code == "stale_token" then "Prices changed - try again"
				else "Upgrade unavailable"
			deps.toasts:push(message, "warning")
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
				local textWidth = -(buttonWidth + Tokens.spacing.md)
				local title = FrameKit.text(frame, "Title", "", "label", { zIndex = z + 1, color = Tokens.color.inkStrong })
				title.Position = UDim2.new(0, 0, 0.5, -(Tokens.typography.label.size + Tokens.spacing.xs) + 2)
				title.Size = UDim2.new(1, textWidth, 0, Tokens.typography.label.size + Tokens.spacing.xs)
				local detail = FrameKit.text(frame, "Detail", "", "caption", { zIndex = z + 1, color = Tokens.color.inkMuted })
				detail.Position = UDim2.new(0, 0, 0.5, 2)
				detail.Size = UDim2.new(1, textWidth, 0, Tokens.typography.caption.size + Tokens.spacing.xs)
				detail.RichText = true
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
				pipLayout.Parent = pips
				local pipDots: { Frame } = {}
				for index = 1, math.clamp(preview.maxLevel or 0, 0, 8) do
					local dot = Instance.new("Frame")
					dot.Name = "Pip" .. index
					dot.Size = UDim2.fromOffset(9, 9)
					dot.BackgroundColor3 = Tokens.color.creamDeep
					dot.BorderSizePixel = 0
					dot.ZIndex = z + 1
					dot.LayoutOrder = index
					local dotCorner = Instance.new("UICorner")
					dotCorner.CornerRadius = UDim.new(1, 0)
					dotCorner.Parent = dot
					local dotStroke = Instance.new("UIStroke")
					dotStroke.Thickness = 1.5
					dotStroke.Color = Tokens.color.strawDeep
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
			row.pips.Position = UDim2.new(0, math.ceil(row.title.TextBounds.X) + Tokens.spacing.md, 0.5, -(Tokens.spacing.xs + 4))
			row.pips.Visible = #row.pipDots > 1
			for index, dot in ipairs(row.pipDots) do
				local lit = index <= (preview.level or 0)
				dot.BackgroundColor3 = if lit then Tokens.color.gold else Tokens.color.creamDeep
				local dotStroke = dot:FindFirstChildOfClass("UIStroke")
				if dotStroke then
					dotStroke.Color = if lit then Tokens.color.goldDeep else Tokens.color.strawDeep
				end
			end
			local current = describe(preview, preview.current)
			if preview.maxed then
				local suffix = if preview.kind == "acquire"
					then (if preview.permanent then "Yours for keeps" else "Ready in your hotbar")
					elseif preview.permanent then "Fully upgraded, for keeps"
					else "Fully upgraded"
				row.detail.Text = string.format('%s  <font color="#%s">%s</font>', current, Tokens.color.leafDeep:ToHex(), suffix)
				row.handle.button.Visible = false
				row.maxBadge.Visible = true
				row.maxBadge.Text = if preview.kind == "acquire" then "OWNED" else "MAX"
			else
				local nextText = describe(preview, preview.next)
				row.detail.Text = if preview.kind == "acquire"
					then (TOOL_TAGLINES[preview.toolId or ""] or nextText)
					else string.format('%s  <font color="#%s">→  %s</font>', current, Tokens.color.goldDeep:ToHex(), nextText)
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
