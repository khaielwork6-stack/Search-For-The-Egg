--!nocheck
-- Repository checks: `lune run lune/check`
--   1. SYSTEM_CONFIG.json parses and validates through the shared Validator (same code as runtime).
--   2. ECONOMY_TABLES.csv agrees with the JSON for every row it mirrors (stop-and-report on conflict).
--   3. No Robux price, product ID, or gameplay literal is hard-coded in services/controllers/UI.
--   4. StyLua --check and Selene pass.
-- Exit code is non-zero on any failure.

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local Harness = require("./harness")

local PACK = "Search_For_The_Egg_Claude_Code_Build_Pack/"
local failures = {}
local function fail(message)
	table.insert(failures, message)
	print("  FAIL " .. message)
end
local function pass(message)
	print("  ok   " .. message)
end

-- 1. Config validation through the shared module ------------------------------------------------
print("[check] config")
if not Harness.build("test.project.json", "build/check.rbxl") then
	fail("rojo build failed")
else
	local ctx = Harness.load("build/check.rbxl")
	local Shared = ctx.game:GetService("ReplicatedStorage").Shared
	local Validator = ctx.require(Shared.Config.Validator)
	local raw = ctx.require(ctx.game:GetService("ServerStorage").SFE.SystemConfig)
	local report = Validator.validate(raw)
	if report.ok then
		pass(string.format("SYSTEM_CONFIG valid (%d checks, %d warnings)", report.checks, #report.warnings))
	else
		for _, err in ipairs(report.errors) do
			fail("config: " .. err)
		end
	end
end

-- 2. CSV <-> JSON consistency --------------------------------------------------------------------
print("[check] economy csv vs json")
local cfg = serde.decode("json", fs.readFile(PACK .. "SYSTEM_CONFIG.json"))
local csv = fs.readFile(PACK .. "ECONOMY_TABLES.csv")
local rows = {}
local header
for line in string.gmatch(csv, "[^\r\n]+") do
	local cells = {}
	for cell in string.gmatch(line .. ",", "([^,]*),") do
		table.insert(cells, cell)
	end
	if not header then
		header = cells
	else
		local row = {}
		for i, name in ipairs(header) do
			row[name] = cells[i]
		end
		table.insert(rows, row)
	end
end

local function num(value)
	return tonumber(value)
end
local function near(a, b)
	return a ~= nil and b ~= nil and math.abs(a - b) < 1e-9
end
local mismatches = 0
local compared = 0
for _, row in ipairs(rows) do
	local table_, system, id, level = row.table, row.system, row.id, tonumber(row.level)
	local jsonValue, jsonCost
	if table_ == "bag" then
		local entry = cfg.bags.levels[level]
		jsonValue, jsonCost = entry and entry.capacity, entry and entry.upgradeCash
	elseif table_ == "hand" then
		local entry = cfg.handUpgrades[id][level + 1]
		if entry then
			jsonValue = entry.amount or entry.walkSpeed or (entry.enabled and 1 or 0)
			jsonCost = entry.nextCash
		end
	elseif table_ == "tool_upgrade" then
		local entry = cfg.toolUpgrades[system][id][level + 1]
		if entry then
			jsonValue = entry.yield or entry.rainbowChance or entry.seconds or entry.value
			jsonCost = entry.nextCash
		end
	elseif table_ == "daily" then
		local entry = cfg.dailyRewards[level]
		jsonValue = entry and entry.gems
	elseif table_ == "class" then
		for _, entry in ipairs(cfg.classes.weights) do
			if entry.id == id then
				jsonValue = entry.weight
			end
		end
		jsonCost = cfg.classes.rollGemCost
	elseif table_ == "tool" and system == "acquisition" then
		local toolId, suffix = string.match(id, "^(%a+)(OneRound)$")
		if not toolId then
			toolId, suffix = string.match(id, "^(%a+)(Permanent)$")
		end
		toolId = toolId or id
		local tool = cfg.tools[toolId]
		if tool then
			if suffix == "OneRound" then
				jsonCost = tool.oneRoundRobux
			elseif suffix == "Permanent" then
				jsonCost = tool.permanentRobux
			else
				jsonCost = tool.softCashPrice or tool.softGemPrice
			end
			jsonValue = 1
		end
	elseif table_ == "sale" then
		jsonValue = 1
		jsonCost = if id == "standardFeather"
			then cfg.selling.cashPerStandardFeather
			else cfg.selling.cashPerStandardFeather * cfg.selling.rainbowFeatherMultiplier
	elseif table_ == "product" then
		local map = {
			gemBundle100 = { 100, cfg.monetization.gemBundles[1].robux },
			gemBundle400 = { 400, cfg.monetization.gemBundles[2].robux },
			doubleGems = { 2, cfg.monetization.passes.doubleGems.robux },
			doubleLuck = { 2, cfg.classes.products.doubleLuckRobux },
			fastRolls = { 1, cfg.classes.products.fastRollsRobux },
			extraClassSlot = { 1, cfg.classes.products.extraSlotRobux },
			infiniteBag = { -1, cfg.monetization.passes.infiniteBag.robux },
		}
		local entry = map[id]
		if entry then
			jsonValue, jsonCost = entry[1], entry[2]
		end
	elseif table_ == "event" then
		if id == "chestSingle" then
			jsonValue, jsonCost = 1, cfg.monetization.eventChest.tokenCost
		else
			local count = tonumber(string.match(id, "chest(%d+)"))
			for _, bundle in ipairs(cfg.monetization.eventChest.robuxBundles) do
				if bundle.count == count then
					jsonValue, jsonCost = count, bundle.robux
				end
			end
		end
	elseif table_ == "perk" then
		local perk = cfg.permanentPerks[id]
		if perk then
			jsonValue, jsonCost = perk.valuePerLevel, perk.baseGemCost
		end
	elseif table_ == "reward" then
		local chapter = cfg.chapters[system]
		local rewards = chapter and chapter[id .. "Rewards"]
		if rewards then
			local expected = string.format("%d_cash_%d_gems", rewards.cash, rewards.gems)
			if not string.find(row.next_value, expected, 1, true) then
				mismatches += 1
				fail(string.format("csv reward %s/%s next_value %q does not contain %q", system, id, row.next_value, expected))
			end
			compared += 1
		end
		continue
	else
		continue
	end
	compared += 1
	local csvValue, csvCost = num(row.value), num(row.cost)
	if csvValue ~= nil and jsonValue ~= nil and not near(csvValue, jsonValue) then
		mismatches += 1
		fail(string.format("csv %s/%s/%s L%s value %s vs json %s", table_, system, id, row.level, tostring(csvValue), tostring(jsonValue)))
	end
	if csvCost ~= nil and jsonCost ~= nil and not near(csvCost, jsonCost) then
		mismatches += 1
		fail(string.format("csv %s/%s/%s L%s cost %s vs json %s", table_, system, id, row.level, tostring(csvCost), tostring(jsonCost)))
	end
	if jsonValue == nil and jsonCost == nil then
		mismatches += 1
		fail(string.format("csv %s/%s/%s L%s has no json counterpart", table_, system, id, row.level))
	end
end
if mismatches == 0 then
	pass(string.format("ECONOMY_TABLES.csv agrees with SYSTEM_CONFIG.json (%d rows compared)", compared))
end

-- 3. Forbidden literal scan ----------------------------------------------------------------------
print("[check] forbidden literals")
local function walk(dir, out)
	for _, name in ipairs(fs.readDir(dir)) do
		local path = dir .. "/" .. name
		if fs.isDir(path) then
			walk(path, out)
		elseif string.match(name, "%.luau$") then
			table.insert(out, path)
		end
	end
	return out
end
local files = walk("src", {})
local literalHits = 0
for _, path in ipairs(files) do
	local text = fs.readFile(path)
	if string.match(path, "Deployment/ProductIds") then
		continue
	end
	local n = 0
	for line in string.gmatch(text .. "\n", "([^\n]*)\n") do
		n += 1
		local trimmed = string.gsub(line, "^%s*%-%-.*$", "")
		if trimmed == "" then
			continue
		end
		if
			string.match(trimmed, "[Rr]obux%s*=%s*%d")
			or string.match(trimmed, "[Pp]roductId%s*=%s*%d")
			or string.match(trimmed, "[Gg]amePassId%s*=%s*%d")
			or string.match(trimmed, "PromptProductPurchase%(.-,%s*%d")
		then
			literalHits += 1
			fail(string.format("%s:%d hard-coded price/product literal", path, n))
		end
	end
end
if literalHits == 0 then
	pass(string.format("no hard-coded product ids or Robux prices in %d source files", #files))
end

-- 3b. Shadowed definitions -----------------------------------------------------------------------
-- A module that defines `Module.thing` twice compiles clean, lints clean and typechecks clean: the
-- second definition simply wins and the first becomes dead code. That is exactly how a rewritten
-- `WorldShellService.applyLeaderboards` sat unused behind a stale copy while the leaderboards stayed
-- blank. Nothing else in the toolchain sees it, so it is checked here.
print("[check] shadowed definitions")
local shadowHits = 0
for _, path in ipairs(files) do
	local text = fs.readFile(path)
	local seen = {}
	local n = 0
	for line in string.gmatch(text .. "\n", "([^\n]*)\n") do
		n += 1
		local owner, name = string.match(line, "^function%s+([%w_]+)[%.:]([%w_]+)%s*%(")
		if owner and name then
			local key = owner .. "." .. name
			if seen[key] then
				shadowHits += 1
				fail(string.format("%s:%d redefines %s (first at line %d); the earlier one is dead", path, n, key, seen[key]))
			else
				seen[key] = n
			end
		end
	end
end
if shadowHits == 0 then
	pass(string.format("no function is defined twice in %d source files", #files))
end

-- 4. Format and lint ------------------------------------------------------------------------------
print("[check] stylua --check")
local stylua = process.exec("stylua", { "--check", "src", "tests", "lune" })
if stylua.ok then
	pass("stylua")
else
	fail("stylua --check reported differences")
	print(stylua.stdout)
end
print("[check] selene")
local selene = process.exec("selene", { "src", "tests", "lune" })
if selene.ok then
	pass("selene")
else
	fail("selene reported problems")
	print(selene.stdout)
	print(selene.stderr)
end

if #failures > 0 then
	print(string.format("[check] FAILED (%d)", #failures))
	process.exit(1)
end
print("[check] OK")
process.exit(0)
