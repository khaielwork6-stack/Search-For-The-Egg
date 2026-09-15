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

	local columns, rows = 40, 16
	local holes: { [string]: number } = {}
	local sample: { string } = {}
	for row = 0, rows - 1 do
		local line = {}
		for column = 0, columns - 1 do
			local sx = (column + 0.5) / columns * viewport.X
			local sy = (0.25 + (row + 0.5) / rows * 0.75) * viewport.Y
			local ray = camera:ViewportPointToRay(sx, sy)
			local hit = workspace:Raycast(ray.Origin, ray.Direction * 400, params)
			local glyph = " "
			if hit then
				local inPile = hit.Instance:IsDescendantOf(folder)
				if inPile and hit.Instance.Name == "Feather" then
					glyph = "#"
				elseif inPile then
					glyph = "+"
				else
					glyph = "."
					local key = hit.Instance:GetFullName()
					holes[key] = (holes[key] or 0) + 1
					if #sample < 8 then
						table.insert(
							sample,
							string.format("   %s  y=%.2f  dist=%.1f", key, hit.Position.Y, (hit.Position - ray.Origin).Magnitude)
						)
					end
				end
			end
			table.insert(line, glyph)
		end
		table.insert(lines, "|" .. table.concat(line) .. "|")
	end
	table.insert(lines, "# feather  + filler  . not the pile  blank sky")
	if next(holes) == nil then
		table.insert(lines, "no holes: every ray inside the silhouette met the coat")
	else
		table.insert(lines, "holes hit:")
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
		table.insert(lines, "commands: round | stand x y z lx ly lz | probe | config")
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
