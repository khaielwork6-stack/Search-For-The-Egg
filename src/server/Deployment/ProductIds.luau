--!strict
-- DEPLOYMENT-ONLY mapping of product keys to live Roblox IDs. Server-only (ServerScriptService).
-- Every value is intentionally nil until the owner creates the products in the target experience
-- and supplies real IDs (START_HERE.md "Deployment IDs"). Nothing here is ever invented.
-- Status: TODO_DEPLOYMENT_IDS

return {
	placeIds = {
		lobby = nil :: number?,
		chapter1 = nil :: number?,
		chapter2 = nil :: number?,
	},
	gamePasses = {
		doubleGems = nil :: number?,
		infiniteBag = nil :: number?,
		doubleLuck = nil :: number?,
		fastRolls = nil :: number?,
		extraClassSlot = nil :: number?,
		nestRakePermanent = nil :: number?,
		confettiChargePermanent = nil :: number?,
		featherVacPermanent = nil :: number?,
		scoutChickPermanent = nil :: number?,
	},
	developerProducts = {
		gemBundle100 = nil :: number?,
		gemBundle400 = nil :: number?,
		nestRakeOneRound = nil :: number?,
		confettiChargeOneRound = nil :: number?,
		featherVacOneRound = nil :: number?,
		scoutChickOneRound = nil :: number?,
		eventChest3 = nil :: number?,
		eventChest5 = nil :: number?,
		eventChest10 = nil :: number?,
		skipBagUpgrade = nil :: number?,
	},
}
