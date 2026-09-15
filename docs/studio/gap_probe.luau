-- PILE GAP PROBE
-- 1. Press Play in Studio and walk to where you can see the gap.
-- 2. Open the Command Bar (View > Command Bar). Make sure the context dropdown says Client.
-- 3. Paste this whole file in, press Enter, then copy everything it prints back to Claude.
-- It only reads the scene. It changes nothing.

local cam = workspace.CurrentCamera
local folder = workspace:FindFirstChild("SFE_PileVisual")
local out = {}
local function say(s)
	table.insert(out, s)
end

say("=== PILE GAP PROBE ===")
say(("camera %s  look %s"):format(tostring(cam.CFrame.Position), tostring(cam.CFrame.LookVector)))

-- What the coat is made of right now
if not folder then
	say("!! SFE_PileVisual not found - are you in a round?")
else
	local feathers, fluff, minY, maxY = 0, 0, math.huge, -math.huge
	for _, d in ipairs(folder:GetChildren()) do
		if d:IsA("BasePart") then
			if d.Name == "Feather" then
				feathers += 1
			else
				fluff += 1
			end
			minY = math.min(minY, d.Position.Y)
			maxY = math.max(maxY, d.Position.Y)
		end
	end
	say(("coat: %d feathers, %d filler, y %.2f .. %.2f"):format(feathers, fluff, minY, maxY))
end

-- Config actually loaded on this client (confirms the sync reached Studio)
local ok, cfg = pcall(function()
	return require(game.ReplicatedStorage.Shared.Config).get()
end)
if ok and cfg then
	local v = cfg.pile.visual
	say(
		("cfg: len %.2f-%.2f  visibleSlots %d  under [%d,%d]  lump %.2f  minStep %.2f  rimCurl %d  rimMin %.2f"):format(
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
	say(
		("cfg: nestBaseY %.2f  groundY %.2f  minRecords %d"):format(
			require(game.ReplicatedStorage.Shared.Domain.ChapterLayout).chapter1.nestBaseY,
			require(game.ReplicatedStorage.Shared.Domain.ChapterLayout).chapter1.groundY,
			cfg.pile.minRecordsPerColumn or -1
		)
	)
else
	say("cfg: could not read (" .. tostring(cfg) .. ")")
end

-- Fire rays through a grid of screen points and record what each one meets.
local vp = cam.ViewportSize
local COLS, ROWS = 24, 12
local params = RaycastParams.new()
params.FilterType = Enum.RaycastFilterType.Exclude
local exclude = { cam }
local char = game:GetService("Players").LocalPlayer and game:GetService("Players").LocalPlayer.Character
if char then
	table.insert(exclude, char)
end
params.FilterDescendantsInstances = exclude
params.IgnoreWater = true

local rows, throughs = {}, {}
for r = 0, ROWS - 1 do
	local line = {}
	for c = 0, COLS - 1 do
		local sx = (c + 0.5) / COLS * vp.X
		local sy = (0.30 + (r + 0.5) / ROWS * 0.70) * vp.Y -- lower 70% of the screen
		local ray = cam:ViewportPointToRay(sx, sy)
		local hit = workspace:Raycast(ray.Origin, ray.Direction * 400, params)
		local ch = " "
		if hit then
			local n = hit.Instance.Name
			local inPile = folder and hit.Instance:IsDescendantOf(folder)
			if inPile and n == "Feather" then
				ch = "#"
			elseif inPile then
				ch = "+"
			else
				ch = "."
				if #throughs < 12 then
					table.insert(
						throughs,
						("  hole at screen %d,%d -> %s (%s) y=%.2f dist=%.1f"):format(
							math.floor(sx),
							math.floor(sy),
							n,
							hit.Instance:GetFullName(),
							hit.Position.Y,
							(hit.Position - ray.Origin).Magnitude
						)
					)
				end
			end
		end
		table.insert(line, ch)
	end
	table.insert(rows, table.concat(line))
end
say("screen map (lower 70%): # feather  + filler  . something else  (blank) sky")
for _, line in ipairs(rows) do
	say("|" .. line .. "|")
end
if #throughs > 0 then
	say("what the holes actually hit:")
	for _, t in ipairs(throughs) do
		say(t)
	end
else
	say("no holes: every ray met the coat")
end
print(table.concat(out, "\n"))
