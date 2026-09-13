--!strict
-- Daily Nest modal: the eight-day calendar (verified Gem amounts from config), the current day
-- highlighted, claimed days marked, the grace note, and one Claim button that is enabled only when
-- the server says the reward is ready. The countdown ticks from the projection; the reward toast
-- and the Gem count-up run only after the server acknowledged the claim.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local DailyRewards = require(Shared.Domain.DailyRewards)
local Tween = require(script.Parent.Parent.Components.Tween)
local FrameKit = require(script.Parent.Parent.Components.Frame)
local Button = require(script.Parent.Parent.Components.Button)

local DailyModal = {}

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

local function clock(seconds: number): string
	local s = math.max(0, math.floor(seconds))
	return string.format("%02d:%02d:%02d", math.floor(s / 3600), math.floor(s % 3600 / 60), s % 60)
end

function DailyModal.build(container: ScrollingFrame, api: any, deps: Deps): () -> ()
	local cleanups: { any } = {}
	local cfg = deps.config
	local motion = deps.accessibility:motionSettings()
	local tap = deps.minimumTapTarget
	local z = container.ZIndex + 1
	local receivedAt = os.clock()

	local status = FrameKit.text(container, "Status", "", "heading", { zIndex = z, color = Tokens.color.goldLight })
	status.LayoutOrder = 1
	local grid = Instance.new("Frame")
	grid.Name = "Calendar"
	grid.BackgroundTransparency = 1
	grid.Size = UDim2.fromScale(1, 0)
	grid.AutomaticSize = Enum.AutomaticSize.Y
	grid.LayoutOrder = 2
	grid.ZIndex = z
	local layout = Instance.new("UIGridLayout")
	layout.CellSize = UDim2.new(0.25, -Tokens.spacing.xs, 0, tap + Tokens.spacing.lg)
	layout.CellPadding = UDim2.fromOffset(Tokens.spacing.xs, Tokens.spacing.xs)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = grid
	grid.Parent = container

	type Cell = { frame: Frame, day: TextLabel, gems: TextLabel, stroke: UIStroke, scale: UIScale }
	local cells: { Cell } = {}
	for _, entry in ipairs(cfg.dailyRewards) do
		local frame = Instance.new("Frame")
		frame.Name = "Day" .. entry.day
		frame.LayoutOrder = entry.day
		frame.BackgroundColor3 = Tokens.color.tealLight
		frame.ZIndex = z + 1
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, Tokens.radius.md)
		corner.Parent = frame
		local stroke = Instance.new("UIStroke")
		stroke.Thickness = Tokens.stroke.standard
		stroke.Color = Tokens.color.tealDeep
		stroke.Parent = frame
		local scale = Instance.new("UIScale")
		scale.Parent = frame
		local day = FrameKit.text(frame, "Day", "Day " .. entry.day, "caption", { align = Enum.TextXAlignment.Center, zIndex = z + 2 })
		day.Position = UDim2.fromOffset(0, Tokens.spacing.xs)
		local gems = FrameKit.text(
			frame,
			"Gems",
			string.format("%d Gems", entry.gems),
			"heading",
			{ align = Enum.TextXAlignment.Center, zIndex = z + 2, color = Tokens.color.goldLight }
		)
		gems.AnchorPoint = Vector2.new(0, 1)
		gems.Position = UDim2.new(0, 0, 1, -Tokens.spacing.xs)
		frame.Parent = grid
		table.insert(cells, { frame = frame, day = day, gems = gems, stroke = stroke, scale = scale })
	end

	local grace = FrameKit.text(container, "Grace", "", "caption", { zIndex = z, color = Tokens.color.creamDeep })
	grace.LayoutOrder = 3
	grace.Size = UDim2.new(1, 0, 0, Tokens.typography.caption.size * 2 + 6)

	local claim = Button.build(container, {
		text = "Claim",
		variant = "gold",
		minimumTapTarget = tap,
		motion = motion,
		size = UDim2.new(1, 0, 0, tap),
		zIndex = z + 1,
	})
	claim.button.LayoutOrder = 4
	claim.button.Name = "ClaimButton"
	table.insert(cleanups, claim.destroy)
	api.setInitialFocus(claim.button)

	local function evaluation(): any?
		local projection = deps.profile.projection
		return projection and projection.rewards.daily or nil
	end

	local function render()
		local daily = evaluation()
		if not daily then
			return
		end
		receivedAt = os.clock()
		local fake = { dayIndex = daily.dayIndex }
		local calendar = DailyRewards.calendar(cfg, fake :: any)
		for index, cell in ipairs(cells) do
			local info = calendar[index]
			cell.stroke.Color = if info.current
				then Tokens.color.goldLight
				elseif info.claimed then Tokens.color.leafBright
				else Tokens.color.tealDeep
			cell.stroke.Thickness = if info.current then Tokens.stroke.frame else Tokens.stroke.standard
			cell.frame.BackgroundColor3 = if info.claimed
				then Tokens.color.leafDeep
				elseif info.current then Tokens.color.tealLight
				else Tokens.color.tealPanel
			cell.day.Text = if info.claimed then "Day " .. info.day .. "  -  done" else "Day " .. info.day
		end
		if daily.status == "ready" or daily.status == "reset" then
			status.Text = if daily.status == "reset"
				then string.format("Your streak rested - the nest restarts on Day 1 with %d Gems", daily.gems)
				else string.format("Day %d is ready: %d Gems", daily.dayIndex, daily.gems)
			claim.setEnabled(true)
			claim.setText(string.format("Claim %d Gems", daily.gems))
		else
			claim.setEnabled(false)
			claim.setText("Come back soon")
		end
		if daily.graceRemainingSeconds and daily.graceRemainingSeconds > 0 and daily.status == "early" then
			grace.Text = string.format(
				"Claim within %s of the next day to keep your streak. After Day %d the nest loops back to Day 1.",
				clock(cfg.dailyRewardRules.gracePeriodSeconds - cfg.dailyRewardRules.claimCooldownSeconds),
				#cfg.dailyRewards
			)
		else
			grace.Text = string.format(
				"Claim once a day to walk the nest from Day 1 to Day %d. Miss two days and it rests back to Day 1.",
				#cfg.dailyRewards
			)
		end
	end

	table.insert(
		cleanups,
		claim.button.Activated:Connect(function()
			claim.setPending(true, "Opening...")
			local result = deps.net:request("DailyClaim", nil)
			claim.setPending(false)
			if result.ok then
				local data = result.data
				if data.replayed then
					deps.toasts:push("Today's Gems are already in your pouch", "info")
				else
					deps.audio:play(Tokens.sound.rewardLand)
					deps.haptics:pulse(0.6, 0.1)
					local cell = cells[data.dayIndex]
					if cell then
						cell.scale.Scale = 1.12
						Tween.scale(cell.scale, "release", motion, 1)
					end
					deps.toasts:reward(string.format("Day %d nest opened", data.dayIndex), data.gems)
				end
			else
				deps.audio:play(Tokens.sound.uiError)
				deps.toasts:push(
					if result.message == "not_ready" then "The nest is still resting" else "Could not claim right now",
					"warning"
				)
			end
		end)
	)

	render()
	table.insert(cleanups, deps.profile.changed:Connect(render))
	table.insert(
		cleanups,
		RunService.RenderStepped:Connect(function()
			local daily = evaluation()
			if daily and daily.status == "early" then
				local remaining = daily.nextClaimInSeconds - (os.clock() - receivedAt)
				status.Text = string.format("Day %d opens in %s", daily.dayIndex, clock(remaining))
			end
		end)
	)
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

return DailyModal
