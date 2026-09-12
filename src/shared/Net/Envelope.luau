--!strict
-- Sanitized request/result envelopes. Internal error text never crosses the network; clients
-- receive an enumerated code plus an optional short, localizable message key.

local Envelope = {}

export type Envelope<T> = { ok: boolean, data: T?, code: string?, message: string? }

-- Enumerated rejection codes. Adding a code here is the only way a new failure reaches clients.
Envelope.Codes = table.freeze({
	OK = "ok",
	UNKNOWN_MESSAGE = "unknown_message",
	INVALID_PAYLOAD = "invalid_payload",
	PAYLOAD_TOO_LARGE = "payload_too_large",
	RATE_LIMITED = "rate_limited",
	NOT_AUTHORIZED = "not_authorized",
	INVALID_STATE = "invalid_state",
	STALE_TOKEN = "stale_token",
	OUT_OF_RANGE = "out_of_range",
	NOT_FOUND = "not_found",
	INSUFFICIENT_FUNDS = "insufficient_funds",
	ALREADY_DONE = "already_done",
	UNAVAILABLE = "unavailable",
	INTERNAL = "internal",
})

local codeLookup: { [string]: boolean } = {}
for _, code in pairs(Envelope.Codes) do
	codeLookup[code] = true
end

function Envelope.ok<T>(data: T?): Envelope<T>
	return { ok = true, data = data, code = Envelope.Codes.OK }
end

function Envelope.fail(code: string, message: string?): Envelope<any>
	assert(codeLookup[code], "unknown envelope code " .. tostring(code))
	if message ~= nil then
		assert(type(message) == "string" and #message <= 80, "envelope message must be a short key")
	end
	return { ok = false, code = code, message = message }
end

function Envelope.isEnvelope(value: any): boolean
	return type(value) == "table" and type(value.ok) == "boolean" and (value.code == nil or codeLookup[value.code] == true)
end

return Envelope
