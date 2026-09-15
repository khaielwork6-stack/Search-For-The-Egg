--!strict
-- Studio-only server counterpart to `src/client/AutoProbe.client.luau`.
--
-- The Studio assistant's command thread runs without the capability to invoke a BindableFunction, so
-- it cannot reach `ServerStorage.SFE_DebugInvoke` and therefore cannot grant an entitlement, inspect
-- a round, or drive anything server-authoritative. This script runs as an ordinary server Script,
-- which has those capabilities, and exposes the same text channel the client probe uses:
--
--   workspace:SetAttribute("SFE_ServerProbeCommand", "setEntitlement 123 confettiChargePermanent true")
--   workspace.SFE_ServerProbeOut.Value  -- the hook's JSON reply
--
-- Inert outside Studio and inert until a command is written, so it costs a live server nothing.

local RunService = game:GetService("RunService")
if not RunService:IsStudio() then
	return
end

local ServerStorage = game:GetService("ServerStorage")

local COMMAND_ATTRIBUTE = "SFE_ServerProbeCommand"

local out = Instance.new("StringValue")
out.Name = "SFE_ServerProbeOut"
out.Value = "ready"
out.Parent = workspace

local function bridge(): BindableFunction?
	local found = ServerStorage:FindFirstChild("SFE_DebugInvoke")
	return if found and found:IsA("BindableFunction") then found else nil
end

-- Bare words become numbers, booleans or strings; "~" stands in for a space so an argument can
-- carry one through the attribute channel.
local function parse(words: { string }, from: number): { any }
	local args: { any } = {}
	for index = from, #words do
		local word = words[index]
		local number = tonumber(word)
		if number then
			table.insert(args, number)
		elseif word == "true" then
			table.insert(args, true)
		elseif word == "false" then
			table.insert(args, false)
		else
			table.insert(args, (string.gsub(word, "~", " ")))
		end
	end
	return args
end

workspace:GetAttributeChangedSignal(COMMAND_ATTRIBUTE):Connect(function()
	local command = workspace:GetAttribute(COMMAND_ATTRIBUTE)
	if type(command) ~= "string" or command == "" then
		return
	end
	out.Value = "running: " .. command
	local invoke = bridge()
	if not invoke then
		out.Value = "no SFE_DebugInvoke bridge"
		return
	end
	local words = string.split(command, " ")
	local args = parse(words, 2)
	local ok, result = pcall(function()
		return invoke:Invoke(words[1], table.unpack(args))
	end)
	out.Value = if ok then tostring(result) else ("error: " .. tostring(result))
end)
