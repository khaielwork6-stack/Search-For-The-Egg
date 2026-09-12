--!strict
-- Workbench modal: one row per configured round upgrade (Bag, Grasp, Speed, Hold) showing
-- old -> new and the cost from the server preview; Buy sends UpgradePurchase with the expected
-- level and re-renders from the authoritative result. Maxed rows celebrate instead of greying out.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local EconomyMath = require(Shared.EconomyMath)
local Button = require(script.Parent.Components.Button)

local UpgradeModal = {}

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
			return string.format("every %.2fs", entry.intervalSeconds)
		end,
	},
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
}

-- Builds the modal body inside `container`; returns a cleanup function.
function UpgradeModal.build(container: Frame, api: { close: () -> () }, deps: Deps): () -> ()
	local cleanups: { any } = {}
	local rows: { [string]: { label: TextLabel, button: TextButton?, cost: TextLabel } } = {}

	local cashLabel = Instance.new("TextLabel")
	cashLabel.Name = "Cash"
	cashLabel.Size = UDim2.new(1, 0, 0, Tokens.typography.heading.size + Tokens.spacing.sm)
	cashLabel.BackgroundTransparency = 1
	cashLabel.Font = Tokens.typography.heading.font
	cashLabel.TextSize = Tokens.typography.heading.size
	cashLabel.TextColor3 = Tokens.color.leafDeep
	cashLabel.TextXAlignment = Enum.TextXAlignment.Left
	cashLabel.LayoutOrder = 0
	cashLabel.Parent = container

	local function render()
		local previews = deps.round.previews or {}
		local player = deps.round.player
		cashLabel.Text = "Round cash: " .. EconomyMath.formatCents(player and player.cashCents or 0)
		for index, preview in ipairs(previews) do
			local meta = LABELS[preview.upgradeId]
			if not meta then
				continue
			end
			local row = rows[preview.upgradeId]
			if not row then
				local frame = Instance.new("Frame")
				frame.Name = "Row_" .. preview.upgradeId
				frame.LayoutOrder = index
				frame.Size = UDim2.new(1, 0, 0, deps.minimumTapTarget + Tokens.spacing.md)
				frame.BackgroundColor3 = Tokens.color.surfaceAlt
				local corner = Instance.new("UICorner")
				corner.CornerRadius = UDim.new(0, Tokens.radius.md)
				corner.Parent = frame
				local label = Instance.new("TextLabel")
				label.Name = "Label"
				label.Position = UDim2.fromOffset(Tokens.spacing.md, 0)
				label.Size = UDim2.new(0.62, -Tokens.spacing.md, 1, 0)
				label.BackgroundTransparency = 1
				label.Font = Tokens.typography.body.font
				label.TextSize = Tokens.typography.body.size
				label.TextColor3 = Tokens.color.inkStrong
				label.TextXAlignment = Enum.TextXAlignment.Left
				label.TextWrapped = true
				label.Parent = frame
				local cost = Instance.new("TextLabel")
				cost.Name = "Cost"
				cost.AnchorPoint = Vector2.new(1, 0.5)
				cost.Position = UDim2.new(1, -Tokens.spacing.md, 0.5, 0)
				cost.Size = UDim2.new(0.38, -Tokens.spacing.md, 1, 0)
				cost.BackgroundTransparency = 1
				cost.Font = Tokens.typography.caption.font
				cost.TextSize = Tokens.typography.caption.size
				cost.TextColor3 = Tokens.color.inkMuted
				cost.TextXAlignment = Enum.TextXAlignment.Right
				cost.Visible = false
				cost.Parent = frame
				frame.Parent = container
				row = { label = label, button = nil, cost = cost }
				rows[preview.upgradeId] = row
				local button, buttonCleanup = Button.create(frame, {
					text = "Buy",
					variant = "primary",
					minimumTapTarget = deps.minimumTapTarget,
					motion = deps.accessibility:motionSettings(),
					size = UDim2.fromOffset(math.max(deps.minimumTapTarget, 120), deps.minimumTapTarget),
				})
				button.AnchorPoint = Vector2.new(1, 0.5)
				button.Position = UDim2.new(1, -Tokens.spacing.sm, 0.5, 0)
				table.insert(cleanups, buttonCleanup)
				row.button = button
				table.insert(
					cleanups,
					button.Activated:Connect(function()
						local latest = nil
						for _, p in ipairs(deps.round.previews or {}) do
							if p.upgradeId == preview.upgradeId then
								latest = p
							end
						end
						local token = deps.round:sessionToken()
						if not latest or latest.maxed or not token then
							return
						end
						local result = deps.net:request(
							"UpgradePurchase",
							{ sessionToken = token, upgradeId = preview.upgradeId, expectedLevel = latest.level }
						)
						if result.ok then
							deps.audio:play(Tokens.sound.upgradeChord)
							deps.haptics:pulse(0.5, 0.1)
							deps.toasts:push(meta.title .. " improved", "success")
						else
							deps.audio:play(Tokens.sound.uiError)
							local message = if result.code == "insufficient_funds"
								then "Not enough round cash"
								elseif result.code == "out_of_range" then "Stand at the workbench"
								else "Upgrade unavailable"
							deps.toasts:push(message, "warning")
						end
					end)
				)
			end
			local current = meta.describe(preview.current)
			if preview.maxed then
				row.label.Text = string.format("%s\n%s  -  MAXED", meta.title, current)
				row.label.TextColor3 = Tokens.color.leafDeep
				if row.button then
					row.button.Text = "Max"
					row.button.Visible = false
				end
				row.cost.Visible = true
				row.cost.Text = "Fully upgraded"
				row.cost.TextColor3 = Tokens.color.leafDeep
			else
				row.label.Text = string.format("%s\n%s  ->  %s", meta.title, current, meta.describe(preview.next))
				row.label.TextColor3 = Tokens.color.inkStrong
				if row.button then
					row.button.Visible = true
					row.button.Text = "Buy " .. EconomyMath.formatCents(preview.costCents or 0)
				end
				row.cost.Visible = false
			end
		end
	end

	render()
	table.insert(cleanups, deps.round.upgrade:Connect(render))
	table.insert(cleanups, deps.round.playerChanged:Connect(render))

	local done, doneCleanup = Button.create(container, {
		text = "Done",
		variant = "secondary",
		minimumTapTarget = deps.minimumTapTarget,
		motion = deps.accessibility:motionSettings(),
		size = UDim2.new(1, 0, 0, deps.minimumTapTarget),
		onActivated = api.close,
	})
	done.LayoutOrder = 99
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
