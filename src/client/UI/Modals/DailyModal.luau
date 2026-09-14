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
local Skin = require(script.Parent.Parent.Components.Skin)
local Icons = require(script.Parent.Parent.Components.Icons)
local Confetti = require(script.Parent.Parent.Components.Confetti)

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
	quality: any?,
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

	local status = FrameKit.text(container, "Status", "", "heading", { zIndex = z, color = Tokens.color.goldDeep })
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

	type Cell = {
		frame: Frame,
		day: TextLabel,
		gems: TextLabel,
		stroke: UIStroke,
		scale: UIScale,
		art: ImageLabel?,
		check: Frame,
		stopPulse: (() -> ())?,
	}
	local cells: { Cell } = {}
	for _, entry in ipairs(cfg.dailyRewards) do
		local frame = Instance.new("Frame")
		frame.Name = "Day" .. entry.day
		frame.LayoutOrder = entry.day
		frame.BackgroundColor3 = Tokens.color.featherWhite
		frame.ZIndex = z + 1
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, Tokens.radius.md)
		corner.Parent = frame
		local stroke = Instance.new("UIStroke")
		stroke.Thickness = Tokens.stroke.standard
		stroke.Color = Tokens.color.outline
		stroke.Transparency = 0.5
		stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		stroke.Parent = frame
		local scale = Instance.new("UIScale")
		scale.Parent = frame
		local art: ImageLabel? = nil
		local day = FrameKit.text(
			frame,
			"Day",
			"Day " .. entry.day,
			"caption",
			{ align = Enum.TextXAlignment.Center, zIndex = z + 3, color = Tokens.color.inkMuted }
		)
		day.Position = UDim2.fromOffset(0, Tokens.spacing.sm)
		local gemIcon = Skin.icon(frame, "hud.gem", Tokens.icon.sm, z + 3) or Icons.gem(frame, Tokens.icon.sm, { zIndex = z + 3 })
		gemIcon.AnchorPoint = Vector2.new(1, 1)
		gemIcon.Position = UDim2.new(0.5, -Tokens.spacing.xs, 1, -Tokens.spacing.sm)
		local gems = FrameKit.text(
			frame,
			"Gems",
			tostring(entry.gems),
			"heading",
			{ align = Enum.TextXAlignment.Left, zIndex = z + 3, color = Tokens.color.goldDeep }
		)
		gems.AnchorPoint = Vector2.new(0, 1)
		gems.Position = UDim2.new(0.5, Tokens.spacing.xs, 1, -Tokens.spacing.sm + 2)
		gems.Size = UDim2.new(0.5, 0, 0, Tokens.typography.heading.size + 2)
		local check = Icons.check(frame, Tokens.icon.md, { zIndex = z + 4 })
		check.AnchorPoint = Vector2.new(1, 0)
		check.Position = UDim2.new(1, -Tokens.spacing.xs, 0, Tokens.spacing.xs)
		check.Visible = false
		frame.Parent = grid
		table.insert(
			cells,
			{ frame = frame, day = day, gems = gems, stroke = stroke, scale = scale, art = art, check = check, stopPulse = nil }
		)
	end

	local grace = FrameKit.text(container, "Grace", "", "caption", { zIndex = z, color = Tokens.color.inkMuted })
	grace.LayoutOrder = 3
	grace.Size = UDim2.new(1, 0, 0, Tokens.typography.caption.size * 2 + 6)

	local claim = Button.build(container, {
		text = "Claim",
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
		local ready = daily.status == "ready" or daily.status == "reset"
		for index, cell in ipairs(cells) do
			local info = calendar[index]
			cell.stroke.Color = if info.current
				then Tokens.color.gold
				elseif info.claimed then Tokens.color.leafBright
				else Tokens.color.strawDeep
			cell.stroke.Thickness = if info.current then Tokens.stroke.frame else Tokens.stroke.standard
			cell.frame.BackgroundColor3 = if info.claimed
				then Tokens.color.tealTint
				elseif info.current then Tokens.color.creamPill
				else Tokens.color.featherWhite
			cell.day.Text = "Day " .. info.day
			cell.day.TextColor3 = if info.current then Tokens.color.inkStrong else Tokens.color.inkMuted
			cell.check.Visible = info.claimed
			cell.gems.TextColor3 = if info.claimed then Tokens.color.leafDeep else Tokens.color.goldDeep
			if cell.art then
				Skin.apply(
					cell.art,
					if info.claimed then "daily.cell.claimed" elseif info.current then "daily.cell.current" else "daily.cell.future"
				)
			end
			-- Only the claimable day breathes; everything else stays still.
			local shouldPulse = info.current and ready
			if shouldPulse and not cell.stopPulse then
				cell.stopPulse = Tween.pulseLoop(cell.scale, motion, 0.04)
			elseif not shouldPulse and cell.stopPulse then
				cell.stopPulse()
				cell.stopPulse = nil
			end
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
						if cell.stopPulse then
							cell.stopPulse()
							cell.stopPulse = nil
						end
						cell.scale.Scale = 1.12
						Tween.scale(cell.scale, "release", motion, 1)
						Confetti.burst(cell.frame, {
							origin = UDim2.fromScale(0.5, 0.5),
							count = 22,
							spread = 130,
							motion = motion,
							tier = deps.quality and deps.quality:tier() or nil,
							zIndex = z + 8,
						})
						deps.audio:play(Tokens.sound.uiConfetti)
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
		for _, cell in ipairs(cells) do
			if cell.stopPulse then
				cell.stopPulse()
			end
		end
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
