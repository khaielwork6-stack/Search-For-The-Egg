--!strict
-- Ordered, pure, idempotent profile migrations (DATASTORE_SCHEMA.md section 7). Each migration
-- has a stable id; the id is appended to migrationHistory only after it applies successfully.
-- Migrations never reduce premium currency or owned cosmetics.

local ProfileSchema = require(script.Parent.ProfileSchema)

local Migrations = {}

export type Migration = {
	id: string,
	from: number,
	to: number,
	apply: (profile: { [string]: any }, now: number) -> { [string]: any },
}

Migrations.list = {
	{
		id = "v0_to_v1_initial_profile",
		from = 0,
		to = 1,
		apply = function(profile, now)
			-- Pre-schema saves (if any) carried a flat `gems` field; preserve earned value.
			if type(profile.gems) == "number" and type(profile.currencies) ~= "table" then
				profile.currencies = { gems = math.max(0, math.floor(profile.gems)), eventTokens = 0 }
				profile.gems = nil
			end
			profile.schemaVersion = 1
			if profile.createdAt == nil then
				profile.createdAt = now
			end
			return profile
		end,
	},
} :: { Migration }

-- Applies every pending migration in order. Returns the (same) profile table and the ids applied
-- during this call. Re-running on an up-to-date profile applies nothing.
function Migrations.apply(profile: { [string]: any }, now: number): ({ [string]: any }, { string })
	if type(profile.migrationHistory) ~= "table" then
		profile.migrationHistory = {}
	end
	local applied: { string } = {}
	local version = if type(profile.schemaVersion) == "number" then profile.schemaVersion else 0
	for _, migration in ipairs(Migrations.list) do
		if table.find(profile.migrationHistory, migration.id) then
			continue
		end
		if version >= migration.to then
			continue
		end
		if version ~= migration.from then
			error(string.format("Migrations: cannot apply %s from schema %d (expects %d)", migration.id, version, migration.from))
		end
		profile = migration.apply(profile, now)
		profile.schemaVersion = migration.to
		version = migration.to
		table.insert(profile.migrationHistory, migration.id)
		table.insert(applied, migration.id)
	end
	if version ~= ProfileSchema.SCHEMA_VERSION then
		error(string.format("Migrations: profile ended at schema %d, expected %d", version, ProfileSchema.SCHEMA_VERSION))
	end
	return profile, applied
end

function Migrations.latestVersion(): number
	local latest = 0
	for _, migration in ipairs(Migrations.list) do
		latest = math.max(latest, migration.to)
	end
	return latest
end

return Migrations
