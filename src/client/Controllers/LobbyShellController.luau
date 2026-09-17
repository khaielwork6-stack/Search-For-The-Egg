--!strict
-- Ambient life for a server-built scene folder (lobby shell or chapter arena). Reads SFE_Ambient
-- attributes and registers actors with the AmbientScheduler: drifting pooled feathers (the repo
-- Feather mesh), portal/sun shimmer, cloth sway, pedestal bob/spin, card/leaf sway, moonlight
-- pulse, page flips, flag waves, pecking birds, and dust motes through the VFX pool. Station audio
-- anchors get a looped hum. Party silhouettes and the ledger board are filled from projections.
-- Everything is cleaned up through one trove; the scheduler owns the only Heartbeat.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local Shared = ReplicatedStorage.Shared
local Trove = require(Shared.Util.Trove)
local PerfTrace = require(Shared.Util.PerfTrace)
local Tokens = require(Shared.Design.Tokens)
local AssetManifest = require(Shared.Design.AssetManifest)
local WorldBillboard = require(script.Parent.Parent.UI.Components.WorldBillboard)
local NpcPlate = require(script.Parent.Parent.UI.NpcPlate)

local LobbyShellController = {}
LobbyShellController.__index = LobbyShellController

export type LobbyShellController = typeof(setmetatable(
	{} :: {
		_deps: any,
		_folderName: string,
		_trove: Trove.Trove,
		_strands: { BasePart },
		_actors: { any },
		_loops: { Sound },
		_shell: Instance?,
		started: boolean,
	},
	LobbyShellController
))

local STRANDS_PER_ANCHOR_BY_TIER = { low = 6, medium = 12, high = 20 }
local FEATHER_TINTS = { Tokens.worldColor.feather, Tokens.worldColor.featherDeep, Tokens.color.straw }

local function makeStrand(parent: Instance, index: number): BasePart
	local template = AssetManifest.model("feather")
	local strand: BasePart
	if template and template:IsA("BasePart") then
		strand = template:Clone() :: BasePart
		strand.Size = template.Size * 1.3
	else
		local fallback = Instance.new("Part")
		fallback.Size = Vector3.new(0.12, 0.5, 0.9)
		fallback.Material = Enum.Material.SmoothPlastic
		fallback:SetAttribute("SFE_Placeholder", "PHASE_6_VFX")
		strand = fallback
	end
	strand.Name = "FeatherStrand"
	strand.Anchored = true
	strand.CanCollide = false
	strand.CanQuery = false
	strand.CanTouch = false
	strand.CastShadow = false
	strand.Color = FEATHER_TINTS[(index % #FEATHER_TINTS) + 1]
	strand.Parent = parent
	return strand
end

function LobbyShellController.new(deps: any, folderName: string?): LobbyShellController
	return setmetatable({
		_deps = deps,
		_folderName = folderName or "SFE_LobbyShell",
		_trove = Trove.new(),
		_strands = {},
		_actors = {},
		_loops = {},
		_shell = nil,
		started = false,
	}, LobbyShellController)
end

function LobbyShellController.start(self: LobbyShellController)
	if self.started then
		return
	end
	self.started = true
	local deps = self._deps
	local shell = workspace:WaitForChild(self._folderName, 30)
	if not shell then
		warn("[SFE][Ambient] scene folder missing: " .. self._folderName)
		return
	end
	self._shell = shell
	-- The folder replicates before its children; wait for the server-declared child count.
	local expected = tonumber(shell:GetAttribute("SFE_ChildCount")) or 0
	local deadline = os.clock() + 10
	PerfTrace.label(self._folderName .. ":wait")
	while #shell:GetChildren() < expected and os.clock() < deadline do
		task.wait(0.05)
	end
	PerfTrace.event(self._folderName .. ":children " .. #shell:GetChildren() .. "/" .. expected)
	local buildStarted = os.clock()
	PerfTrace.label(self._folderName .. ":build")
	local container = Instance.new("Folder")
	container.Name = self._folderName .. "_Ambient"
	container.Parent = workspace
	self._trove:add(container)

	local tier = deps.quality:tier()
	-- A scene can opt out of drifting strands (the lobby does: the owner wants its air clear).
	local strandsPerAnchor = if deps.strandsPerAnchor ~= nil
		then deps.strandsPerAnchor :: number
		else STRANDS_PER_ANCHOR_BY_TIER[tier] or 12
	local loopBudget = deps.quality:budgets().loopingAmbient

	local function register(actor)
		table.insert(self._actors, deps.ambient:register(actor))
	end

	for _, part in ipairs(shell:GetChildren()) do
		if not part:IsA("BasePart") then
			continue
		end
		local audioRole = part:GetAttribute("SFE_AudioRole")
		if type(audioRole) == "string" and #self._loops < loopBudget and deps.audio.loop then
			local loop = deps.audio:loop(audioRole, part)
			if loop then
				table.insert(self._loops, loop)
			end
		end
		local kind = part:GetAttribute("SFE_Ambient")
		local position = function()
			return part.Position
		end
		if kind == "featherDrift" then
			local origin = part.Position
			for i = 1, strandsPerAnchor do
				local strand = makeStrand(container, i)
				table.insert(self._strands, strand)
				local seed = i * 0.37
				register({
					id = part.Name .. ":" .. i,
					position = function()
						return origin
					end,
					interval = 1 / 20,
					update = function(_dt: number, t: number)
						local phase = t * 0.35 + seed * 7
						local radius = 4 + (seed * 10) % 6
						local x = origin.X + math.cos(phase) * radius
						local z = origin.Z + math.sin(phase * 0.8) * radius
						local y = origin.Y - ((t * 0.9 + seed * 13) % 14)
						strand.CFrame = CFrame.new(x, y, z) * CFrame.Angles(math.sin(phase * 2) * 0.6, phase, math.cos(phase * 1.3) * 0.4)
					end,
				})
			end
		elseif kind == "npc" then
			self:_presentVendor(part, register)
		elseif kind == "padBoard" then
			self:_presentPadBoard(part)
		elseif kind == "padPulse" then
			local base = part.Transparency
			register({
				id = part.Name,
				position = position,
				interval = 1 / 15,
				update = function(_dt: number, t: number)
					part.Transparency = base + math.sin(t * 2.2) * 0.12
				end,
			})
		elseif kind == "portalShimmer" or kind == "sunShimmer" then
			local base = part.Transparency
			register({
				id = part.Name,
				position = position,
				interval = 1 / 15,
				update = function(_dt: number, t: number)
					part.Transparency = base + math.sin(t * 1.6) * 0.12
				end,
			})
		elseif kind == "clothSway" then
			local baseCFrame = part.CFrame
			register({
				id = part.Name,
				position = position,
				interval = 1 / 15,
				update = function(_dt: number, t: number)
					part.CFrame = baseCFrame * CFrame.Angles(0, 0, math.sin(t * 0.7) * 0.03)
				end,
			})
		elseif kind == "sway" then
			local baseCFrame = part.CFrame
			local seed = (#self._actors % 7) * 0.9
			register({
				id = part.Name,
				position = position,
				interval = 1 / 15,
				update = function(_dt: number, t: number)
					part.CFrame = baseCFrame * CFrame.Angles(math.sin(t * 1.1 + seed) * 0.08, 0, math.cos(t * 0.9 + seed) * 0.06)
				end,
			})
		elseif kind == "bob" or kind == "spin" then
			local baseCFrame = part.CFrame
			register({
				id = part.Name,
				position = position,
				interval = 1 / 20,
				update = function(_dt: number, t: number)
					if kind == "bob" then
						part.CFrame = baseCFrame * CFrame.new(0, math.sin(t * 1.2) * 0.4, 0) * CFrame.Angles(0, t * 0.3, 0)
					else
						part.CFrame = baseCFrame * CFrame.Angles(0, t * 0.8, 0)
					end
				end,
			})
		elseif kind == "moonPulse" then
			local base = part.Transparency
			register({
				id = part.Name,
				position = position,
				interval = 1 / 12,
				update = function(_dt: number, t: number)
					part.Transparency = math.clamp(base + math.sin(t * 0.9) * 0.15, 0, 0.95)
				end,
			})
		elseif kind == "pageFlip" then
			local baseCFrame = part.CFrame
			register({
				id = part.Name,
				position = position,
				interval = 1 / 15,
				update = function(_dt: number, t: number)
					local flip = math.max(0, math.sin(t * 0.8)) ^ 3
					part.CFrame = baseCFrame * CFrame.Angles(0, flip * 1.2, 0)
				end,
			})
		elseif kind == "flagWave" then
			local baseCFrame = part.CFrame
			register({
				id = part.Name,
				position = position,
				interval = 1 / 15,
				update = function(_dt: number, t: number)
					part.CFrame = baseCFrame * CFrame.Angles(0, math.sin(t * 2.2) * 0.35, math.sin(t * 3.1) * 0.12)
				end,
			})
		elseif kind == "peck" then
			local baseCFrame = part.CFrame
			register({
				id = part.Name,
				position = position,
				interval = 1 / 12,
				update = function(_dt: number, t: number)
					local peck = math.max(0, math.sin(t * 5)) * 0.5
					local wander = math.sin(t * 0.25) * 3
					part.CFrame = baseCFrame * CFrame.new(wander, 0, 0) * CFrame.Angles(peck, math.sin(t * 0.25) * 0.4, 0)
				end,
			})
		elseif kind == "dustMote" then
			register({
				id = part.Name .. ":dust",
				position = position,
				interval = 2.5,
				update = function(_dt: number, _t: number, rng: any)
					local offset = Vector3.new((rng:next() - 0.5) * 8, 2 + rng:next() * 3, (rng:next() - 0.5) * 8)
					deps.vfx:burst("dust", part.Position + offset, 1.2)
				end,
			})
		end
	end
	PerfTrace.event(self._folderName .. string.format(":built %.0fms", (os.clock() - buildStarted) * 1000))
	PerfTrace.label(self._folderName .. ":done")
	deps.ambient:start()
	print(
		string.format(
			"[SFE][Ambient] %s actors=%d strands=%d loops=%d tier=%s",
			self._folderName,
			#self._actors,
			#self._strands,
			#self._loops,
			tier
		)
	)
end

-- Fills the portal silhouettes from the party projection (nil = empty seats).
function LobbyShellController.setPartySilhouettes(self: LobbyShellController, party: { [string]: any }?)
	local shell = self._shell
	if not shell then
		return
	end
	local count = party and #party.members or 0
	for _, child in ipairs(shell:GetChildren()) do
		local slot = child:GetAttribute("SFE_PartySlot")
		if type(slot) == "number" and child:IsA("BasePart") then
			local filled = slot <= count
			child.Transparency = if filled then 0.1 else 0.75
			child.Color = if filled
				then (if party and party.members[slot] == party.leaderUserId then Tokens.color.gold else Tokens.color.sky)
				else Tokens.worldColor.feather
		end
	end
end

-- Fills the ledger SurfaceGui with the first board's rows.
function LobbyShellController.setLeaderboard(self: LobbyShellController, snapshot: { [string]: any }?)
	local shell = self._shell
	if not shell or not snapshot then
		return
	end
	local emblem = shell:FindFirstChild("statsEmblem")
	local surface = emblem and emblem:FindFirstChild("SFE_LeaderboardSurface")
	if not surface then
		return
	end
	surface:ClearAllChildren()
	local board = snapshot.boards and snapshot.boards[1]
	if not board then
		return
	end
	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 2)
	layout.Parent = surface
	local function line(order: number, text: string, color: Color3, size: number)
		local label = Instance.new("TextLabel")
		label.LayoutOrder = order
		label.Size = UDim2.new(1, 0, 0, size + 4)
		label.BackgroundTransparency = 1
		label.Font = Tokens.typography.label.font
		label.TextSize = size
		label.TextColor3 = color
		label.TextStrokeColor3 = Tokens.color.outline
		label.TextStrokeTransparency = 0.3
		label.Text = text
		label.Parent = surface
	end
	line(0, board.label, Tokens.color.goldLight, 18)
	for index, row in ipairs(board.rows) do
		if index > 5 then
			break
		end
		line(index, string.format("%d. %s  %s", index, row.name, tostring(row.value)), Tokens.color.featherWhite, 14)
	end
	if #board.rows == 0 then
		line(1, "Be the first forager here", Tokens.color.inkMuted, 14)
	end
end

-- A vendor NPC: breathes in place, turns to face whoever walks up, wears a nameplate and greets
-- the player with a speech bubble while their prompt is showing.
-- The floating board over a nest pad: the big count on top, the line beneath, both from the
-- zone's SFE_PadText attribute ("0/4\nTouch to create a party" / "Setting off in 3").
function LobbyShellController._presentPadBoard(self: LobbyShellController, part: BasePart)
	-- A world billboard: studs-sized (it shrinks with distance), occluded by the lobby's geometry and
	-- culled past Tokens.world.padBoardMaxDistance.
	local world = Tokens.world
	local gui = WorldBillboard.create(part, "PadBoard", world.padBoardStuds, Vector3.new(0, 6.5, 0), world.padBoardMaxDistance)
	local count = WorldBillboard.text(gui, "Count", "0/4", {
		size = UDim2.fromScale(1, 0.5),
		font = Tokens.typography.display.font,
		outline = 3,
	})
	local line = WorldBillboard.text(gui, "Line", "Touch to create a party", {
		size = UDim2.fromScale(1, 0.4),
		position = UDim2.fromScale(0.5, 1),
		anchor = Vector2.new(0.5, 1),
		outline = 2.4,
		wrap = true,
	})
	local padIndex = part:GetAttribute("SFE_Pad")
	local shell = part.Parent
	local function apply()
		local text = tostring(part:GetAttribute("SFE_PadText") or "")
		local first, rest = string.match(text, "^([^\n]*)\n?(.*)$")
		count.Text = first or text
		line.Text = rest or ""
		local active = not string.find(text, "^0/")
		count.TextColor3 = if active then Tokens.color.goldLight else Tokens.color.featherWhite
		-- The floor and the light posts turn gold while the pad holds a party.
		if shell then
			for _, sibling in ipairs(shell:GetChildren()) do
				if
					sibling:IsA("BasePart")
					and sibling:GetAttribute("SFE_Pad") == padIndex
					and (sibling.Name:sub(1, 7) == "PadGlow" or sibling:GetAttribute("SFE_PadPost"))
				then
					sibling.Color = if active then Tokens.color.gold else Tokens.color.tealLight
					local light = sibling:FindFirstChildOfClass("PointLight")
					if light then
						light.Color = sibling.Color
					end
				end
			end
		end
	end
	apply()
	self._trove:add(part:GetAttributeChangedSignal("SFE_PadText"):Connect(apply))
	self._trove:add(gui)
end

function LobbyShellController._presentVendor(self: LobbyShellController, part: BasePart, register: (any) -> ())
	local modelName = part:GetAttribute("SFE_NpcModel")
	local model = if type(modelName) == "string"
		then (workspace:FindFirstChild(modelName) or (part.Parent and part.Parent:FindFirstChild(modelName)))
		else nil
	if not (model and model:IsA("Model")) then
		return
	end
	local name = tostring(part:GetAttribute("SFE_NpcName") or modelName)
	local role = tostring(part:GetAttribute("SFE_NpcRole") or "")
	local line = tostring(part:GetAttribute("SFE_NpcLine") or "")
	local _, size = model:GetBoundingBox()
	local root = model:FindFirstChild("HumanoidRootPart")
	local adornee = if root and root:IsA("BasePart") then root else part
	-- Plate just over the hat and drawn on top, so the stall roof and sign never hide the name.
	local plate = NpcPlate.build(adornee, name, role, size.Y * 0.5 + 0.9, { onTop = true })
	self._trove:add(plate.destroy)
	-- Outline while the prompt is in reach: a gold Highlight on the whole rig.
	local highlight = Instance.new("Highlight")
	highlight.Name = "SFE_VendorOutline"
	highlight.FillTransparency = 1
	highlight.OutlineColor = Tokens.color.goldLight
	highlight.OutlineTransparency = 0
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.Enabled = false
	highlight.Adornee = model
	highlight.Parent = model
	self._trove:add(highlight)

	local base = model:GetPivot()
	local baseYaw = 0
	local yaw = 0
	local reduced = false
	register({
		id = part.Name .. ":vendor",
		position = function()
			return part.Position
		end,
		interval = 1 / 20,
		update = function(dt: number, t: number)
			local character = Players.LocalPlayer and Players.LocalPlayer.Character
			local playerRoot = character and character:FindFirstChild("HumanoidRootPart")
			local targetYaw = baseYaw
			if playerRoot and playerRoot:IsA("BasePart") then
				local toPlayer = playerRoot.Position - base.Position
				local flat = Vector3.new(toPlayer.X, 0, toPlayer.Z)
				if flat.Magnitude < 22 and flat.Magnitude > 0.5 then
					-- Angle from the vendor's resting facing to the player, clamped so they never spin fully round.
					local facing = base.LookVector
					local angle = math.atan2(flat.Unit:Cross(facing).Y, facing:Dot(flat.Unit))
					targetYaw = math.clamp(-angle, -1.2, 1.2)
				end
			end
			yaw += (targetYaw - yaw) * math.min(1, dt * 6)
			local breathe = if reduced then 0 else math.sin(t * 1.6) * 0.06
			model:PivotTo(base * CFrame.Angles(0, yaw, 0) * CFrame.new(0, breathe, 0))
		end,
	})

	local myPrompt = part:FindFirstChildOfClass("ProximityPrompt")
	if myPrompt then
		self._trove:add(ProximityPromptService.PromptShown:Connect(function(prompt)
			if prompt == myPrompt then
				highlight.Enabled = true
				if line ~= "" then
					plate.say(line)
				end
			end
		end))
		self._trove:add(ProximityPromptService.PromptHidden:Connect(function(prompt)
			if prompt == myPrompt then
				highlight.Enabled = false
				plate.hush()
			end
		end))
		self._trove:add(myPrompt.Triggered:Connect(function()
			plate.say("Take a good look!", 2.4)
		end))
	end
end

function LobbyShellController.stop(self: LobbyShellController)
	for _, actor in ipairs(self._actors) do
		self._deps.ambient:unregister(actor)
	end
	table.clear(self._actors)
	for _, strand in ipairs(self._strands) do
		strand:Destroy()
	end
	table.clear(self._strands)
	for _, loop in ipairs(self._loops) do
		if self._deps.audio.stopLoop then
			self._deps.audio:stopLoop(loop)
		end
	end
	table.clear(self._loops)
	self._trove:clean()
	self.started = false
end

function LobbyShellController.strandCount(self: LobbyShellController): number
	return #self._strands
end

function LobbyShellController.actorCount(self: LobbyShellController): number
	return #self._actors
end

function LobbyShellController.loopCount(self: LobbyShellController): number
	return #self._loops
end

function LobbyShellController.destroy(self: LobbyShellController)
	self:stop()
	self._trove:destroy()
end

return LobbyShellController
