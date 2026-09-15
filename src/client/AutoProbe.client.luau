--!strict
-- Studio-only diagnostic bridge. Studio's newer Assistant sandbox runs external command threads
-- without the capabilities needed to require game modules or invoke the debug bindables, so a
-- tool driving Studio from outside cannot inspect a live round at all. This script runs as an
-- ordinary game LocalScript, which has those capabilities, and exposes a text channel instead:
--
--   workspace:SetAttribute("SFE_ProbeCommand", "round")   -- the outside sets a command
--   workspace.SFE_ProbeOut.Value                          -- and reads the report back
--
-- Setting an attribute and reading a StringValue need no capabilities, so the outside can drive a
-- round and measure the pile without ever loading a module. Inert outside Studio and inert until a
-- command is written, so it costs a live game nothing.

local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
if not RunService:IsStudio() then
	return
end

local Players = game:GetService("Players")
local player = Players.LocalPlayer

local out = Instance.new("StringValue")
out.Name = "SFE_ProbeOut"
out.Value = "ready"
out.Parent = workspace

local COMMAND_ATTRIBUTE = "SFE_ProbeCommand"

local function bridge(): BindableFunction?
	local scripts = player:FindFirstChild("PlayerScripts")
	local found = scripts and scripts:FindFirstChild("SFE_ClientDebug")
	return if found and found:IsA("BindableFunction") then found else nil
end

local function character(): (Model?, BasePart?)
	local model = player.Character
	local root = model and model:FindFirstChild("HumanoidRootPart")
	return model, (if root and root:IsA("BasePart") then root else nil)
end

-- Rays through a grid over the lower part of the view: the picture the outside cannot screenshot.
--
-- Two refinements over a naive raycast map, both learned the hard way:
--   * invisible parts (the nest aim plane, triggers) stop a ray but not the eye, so the ray is
--     re-cast past anything at or near full transparency;
--   * a ray that misses the mound and lands on the sand in front of it is not a hole. A hole is a
--     ray that crosses the dome's own volume and still comes out the other side. The probe marches
--     each non-pile ray against the analytic dome and only calls it a tunnel if it went through.
local function probe(lines: { string })
	local camera = workspace.CurrentCamera
	local folder = workspace:FindFirstChild("SFE_PileVisual")
	if not camera then
		table.insert(lines, "no camera")
		return
	end
	table.insert(lines, string.format("camera %s", tostring(camera.CFrame.Position)))
	if not folder then
		table.insert(lines, "!! SFE_PileVisual missing (not in a round?)")
		return
	end
	local feathers, filler, minY, maxY = 0, 0, math.huge, -math.huge
	for _, descendant in ipairs(folder:GetChildren()) do
		if descendant:IsA("BasePart") then
			if descendant.Name == "Feather" then
				feathers += 1
			else
				filler += 1
			end
			minY = math.min(minY, descendant.Position.Y)
			maxY = math.max(maxY, descendant.Position.Y)
		end
	end
	table.insert(lines, string.format("coat %d feathers %d filler  y %.2f..%.2f", feathers, filler, minY, maxY))

	-- The analytic dome, so a ray can be tested against the mound's real volume.
	local inside: ((Vector3) -> boolean)? = nil
	local okDome = pcall(function()
		local Shared = game.ReplicatedStorage.Shared
		local PileSurface = require(Shared.Domain.PileSurface)
		local layout = require(Shared.Domain.ChapterLayout).chapter1
		local body = workspace:FindFirstChild("SFE_PileCollision")
		local cx, cz, baseY, radius = 0, 0, layout.nestBaseY, 0
		if body then
			local min, max = Vector3.new(math.huge, 0, math.huge), Vector3.new(-math.huge, 0, -math.huge)
			for _, part in ipairs(body:GetChildren()) do
				if part:IsA("BasePart") then
					min = Vector3.new(math.min(min.X, part.Position.X), 0, math.min(min.Z, part.Position.Z))
					max = Vector3.new(math.max(max.X, part.Position.X), 0, math.max(max.Z, part.Position.Z))
				end
			end
			cx, cz = (min.X + max.X) / 2, (min.Z + max.Z) / 2
			radius = math.min(max.X - min.X, max.Z - min.Z) / 2
		end
		local apex = require(Shared.Config).get().pile.maxVisualHeightStuds
		inside = function(point: Vector3): boolean
			local dx, dz = point.X - cx, point.Z - cz
			local r = math.sqrt(dx * dx + dz * dz)
			if radius <= 0 or r > radius * PileSurface.RIM_STRETCH then
				return false
			end
			return point.Y >= baseY - 0.5 and point.Y <= baseY + apex * PileSurface.domeProfile(r / radius)
		end
	end)
	if not okDome then
		table.insert(lines, "(dome unavailable: every non-pile hit is reported as a hole)")
	end

	-- The mound body is drawn but excluded from spatial queries, so a ray would pass through it and
	-- report whatever lies behind. Make it queryable for the length of the probe, then put it back.
	local body = workspace:FindFirstChild("SFE_PileCollision")
	local restore: { BasePart } = {}
	if body then
		for _, part in ipairs(body:GetChildren()) do
			if part:IsA("BasePart") and not part.CanQuery then
				part.CanQuery = true
				table.insert(restore, part)
			end
		end
	end

	local viewport = camera.ViewportSize
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local exclude: { Instance } = { camera }
	local model = character()
	if model then
		table.insert(exclude, model)
	end
	params.FilterDescendantsInstances = exclude
	params.IgnoreWater = true

	-- First hit the eye can actually see: anything at or near full transparency is stepped past.
	local function visibleHit(origin: Vector3, direction: Vector3): RaycastResult?
		local from, left = origin, direction
		for _ = 1, 8 do
			local hit = workspace:Raycast(from, left, params)
			if not hit then
				return nil
			end
			local part = hit.Instance
			if not part:IsA("BasePart") or part.Transparency < 0.95 then
				return hit
			end
			local travelled = (hit.Position - from).Magnitude + 0.05
			left = left.Unit * math.max(left.Magnitude - travelled, 0)
			if left.Magnitude <= 0 then
				return nil
			end
			from = hit.Position + left.Unit * 0.05
		end
		return nil
	end

	local columns, rows = 40, 16
	local holes: { [string]: number } = {}
	local sample: { string } = {}
	local counts = { feather = 0, filler = 0, body = 0, tunnel = 0, ground = 0, sky = 0 }
	for row = 0, rows - 1 do
		local line = {}
		for column = 0, columns - 1 do
			local sx = (column + 0.5) / columns * viewport.X
			local sy = (0.25 + (row + 0.5) / rows * 0.75) * viewport.Y
			local ray = camera:ViewportPointToRay(sx, sy)
			local hit = visibleHit(ray.Origin, ray.Direction * 400)
			local glyph = " "
			if not hit then
				counts.sky += 1
			else
				local inPile = hit.Instance:IsDescendantOf(folder)
				local inBody = body ~= nil and hit.Instance:IsDescendantOf(body)
				if inPile and hit.Instance.Name == "Feather" then
					glyph, counts.feather = "#", counts.feather + 1
				elseif inPile then
					glyph, counts.filler = "+", counts.filler + 1
				elseif inBody then
					glyph, counts.body = "o", counts.body + 1
				else
					-- Did this ray cross the mound's volume on its way to whatever it hit?
					local tunnelled = false
					if inside then
						local span = (hit.Position - ray.Origin).Magnitude
						local steps = math.clamp(math.floor(span / 0.35), 1, 400)
						for step = 1, steps do
							if (inside :: any)(ray.Origin + ray.Direction.Unit * (span * step / steps)) then
								tunnelled = true
								break
							end
						end
					else
						tunnelled = true
					end
					if tunnelled then
						glyph, counts.tunnel = "X", counts.tunnel + 1
						local key = hit.Instance:GetFullName()
						holes[key] = (holes[key] or 0) + 1
						if #sample < 8 then
							table.insert(
								sample,
								string.format("   %s  y=%.2f  dist=%.1f", key, hit.Position.Y, (hit.Position - ray.Origin).Magnitude)
							)
						end
					else
						glyph, counts.ground = ".", counts.ground + 1
					end
				end
			end
			table.insert(line, glyph)
		end
		table.insert(lines, "|" .. table.concat(line) .. "|")
	end
	for _, part in ipairs(restore) do
		part.CanQuery = false
	end
	local onMound = counts.feather + counts.filler + counts.body + counts.tunnel
	table.insert(lines, "# feather  + filler  o BARE BODY  X SEE-THROUGH  . ground/scenery  blank sky")
	table.insert(
		lines,
		string.format(
			"on mound %d: feathers %d (%.0f%%)  filler %d  bare body %d (%.0f%%)  see-through %d (%.0f%%)",
			onMound,
			counts.feather,
			100 * counts.feather / math.max(1, onMound),
			counts.filler,
			counts.body,
			100 * counts.body / math.max(1, onMound),
			counts.tunnel,
			100 * counts.tunnel / math.max(1, onMound)
		)
	)
	if next(holes) == nil then
		table.insert(lines, "no see-through: every ray that crossed the mound met the coat or the body")
	else
		table.insert(lines, "see-through hit:")
		for key, count in pairs(holes) do
			table.insert(lines, string.format("   %dx %s", count, key))
		end
		for _, entry in ipairs(sample) do
			table.insert(lines, entry)
		end
	end
end

local function run(command: string): string
	local lines: { string } = {}
	local words = string.split(command, " ")
	local verb = words[1]
	local debugBridge = bridge()

	if verb == "round" then
		if not debugBridge then
			return "no SFE_ClientDebug bridge"
		end
		debugBridge:Invoke("partyCreate", "chapter1", "normal", 1)
		task.wait(0.4)
		debugBridge:Invoke("partyStart")
		task.wait(7.5)
		debugBridge:Invoke("skipCutscene")
		task.wait(8)
		table.insert(lines, "round started")
		probe(lines)
	elseif verb == "stand" then
		local _, root = character()
		if root then
			root.CFrame = CFrame.new(tonumber(words[2]) or 0, tonumber(words[3]) or 56, tonumber(words[4]) or 388)
			task.wait(0.4)
		end
		if debugBridge then
			debugBridge:Invoke("lookAt", tonumber(words[5]) or 0, tonumber(words[6]) or 55, tonumber(words[7]) or 372)
		end
		task.wait(0.3)
		probe(lines)
	elseif verb == "dig" then
		-- Excavate for real before measuring: a mound that is closed at spawn and opens up once cells
		-- drop is the failure the owner kept hitting, so the probe has to see a dug pile.
		local seconds = tonumber(words[2]) or 25
		if not debugBridge then
			return "no SFE_ClientDebug bridge"
		end
		debugBridge:Invoke("autoStop")
		task.wait(0.3)
		debugBridge:Invoke("autoPlay", seconds, false)
		local deadline = os.clock() + seconds + 2
		while os.clock() < deadline do
			task.wait(1)
		end
		debugBridge:Invoke("autoStop")
		task.wait(0.4)
		local okStatus, status = pcall(function()
			return debugBridge:Invoke("autoStatus")
		end)
		if okStatus and type(status) == "table" then
			local log = status.log
			local tail = if type(log) == "table" and #log > 0 then tostring(log[#log]) else "no log"
			table.insert(lines, string.format("auto: state=%s hits=%s last=%s", tostring(status.state), tostring(status.hits), tail))
		else
			table.insert(lines, "auto: status unavailable " .. tostring(status))
		end
		local okReport, report = pcall(function()
			return debugBridge:Invoke("pileReport")
		end)
		if okReport and type(report) == "table" then
			table.insert(lines, string.format("pile: remaining %s base %s", tostring(report.remaining), tostring(report.base)))
		end
		if words[3] then
			local _, root = character()
			if root then
				root.CFrame = CFrame.new(tonumber(words[3]) or 0, tonumber(words[4]) or 56, tonumber(words[5]) or 391)
				task.wait(0.4)
			end
			debugBridge:Invoke("lookAt", tonumber(words[6]) or 0, tonumber(words[7]) or 53, tonumber(words[8]) or 380)
			task.wait(0.3)
		end
		probe(lines)
	elseif verb == "hit" then
		-- Exact reject codes for a burst of hand collections from where the player is standing.
		if not debugBridge then
			return "no SFE_ClientDebug bridge"
		end
		local times = tonumber(words[2]) or 12
		if words[3] then
			local _, root = character()
			if root then
				root.CFrame = CFrame.new(tonumber(words[3]) or 0, tonumber(words[4]) or 56, tonumber(words[5]) or 386)
				task.wait(0.4)
			end
			debugBridge:Invoke("lookAt", tonumber(words[6]) or 0, tonumber(words[7]) or 55, tonumber(words[8]) or 378)
			task.wait(0.3)
		end
		local ok, result = pcall(function()
			return debugBridge:Invoke("collect", times)
		end)
		table.insert(lines, if ok then HttpService:JSONEncode(result) else ("collect failed: " .. tostring(result)))
	elseif verb == "probe" then
		probe(lines)
	elseif verb == "config" then
		local ok, cfg = pcall(function()
			return require(game.ReplicatedStorage.Shared.Config).get()
		end)
		if ok and cfg then
			local v = cfg.pile.visual
			local layout = require(game.ReplicatedStorage.Shared.Domain.ChapterLayout).chapter1
			table.insert(
				lines,
				string.format(
					"len %.2f-%.2f  slots %d  under[%d,%d]  lump %.2f  minStep %.2f  rimCurl %d  rimMin %.2f",
					v.featherLengthRange[1],
					v.featherLengthRange[2],
					v.visibleSlotsPerCell,
					v.underlayerGridDesktop[1],
					v.underlayerGridDesktop[2],
					v.seatLumpStuds or -1,
					v.minSeatStepStuds or -1,
					v.rimCurlDegrees or -1,
					v.rimMinScale
				)
			)
			table.insert(
				lines,
				string.format(
					"nestBaseY %.2f  groundY %.2f  minRecords %d",
					layout.nestBaseY,
					layout.groundY,
					cfg.pile.minRecordsPerColumn or -1
				)
			)
		else
			table.insert(lines, "config unreadable: " .. tostring(cfg))
		end
	else
		table.insert(lines, "commands: round | stand x y z lx ly lz | dig seconds [x y z lx ly lz] | probe | config")
	end
	return table.concat(lines, "\n")
end

workspace:GetAttributeChangedSignal(COMMAND_ATTRIBUTE):Connect(function()
	local command = workspace:GetAttribute(COMMAND_ATTRIBUTE)
	if type(command) ~= "string" or command == "" then
		return
	end
	out.Value = "running: " .. command
	local ok, result = pcall(run, command)
	out.Value = if ok then result else ("error: " .. tostring(result))
end)
