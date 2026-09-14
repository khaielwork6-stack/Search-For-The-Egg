--!strict
-- DEPLOYMENT-ONLY mapping of product keys to live Roblox IDs. Server-only (ServerScriptService).
-- Every value is intentionally nil until the owner creates the products in the target experience
-- and supplies real IDs (START_HERE.md "Deployment IDs"). Nothing here is ever invented.
-- Status: DEPLOYED (ids from the owner, 14 Sep 2026; place ids still pending)

return {
	placeIds = {
		lobby = nil :: number?,
		chapter1 = nil :: number?,
		chapter2 = nil :: number?,
	},
	gamePasses = {
		doubleGems = 1979703354,
		infiniteBag = 1975737798,
		doubleLuck = 1979913310,
		fastRolls = 1977243715,
		extraClassSlot = 1975947765,
		nestRakePermanent = 1975521824,
		confettiChargePermanent = 1976757816,
		featherVacPermanent = 1979955280,
		scoutChickPermanent = 1979865313,
	},
	developerProducts = {
		gemBundle100 = 3712859281,
		gemBundle400 = 3712859307,
		gemBundle1500 = nil :: number?, -- 1,500 Gems (POPULAR, 199 R$): owner to create the product
		nestRakeOneRound = 3712859325,
		confettiChargeOneRound = 3712859341,
		featherVacOneRound = 3712859353,
		scoutChickOneRound = 3712859364,
		eventChest3 = 3712859384,
		eventChest5 = 3712859411,
		eventChest10 = 3712859429,
		skipBagUpgrade = 3712859443,
	},
	-- Roblox group whose members may claim the one-time group reward (MASTER_SPEC 11). Nil = unavailable.
	social = {
		groupId = nil :: number?,
	},
}
