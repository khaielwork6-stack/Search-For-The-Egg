# Painted art the Class Forge and Plume's Market look for

Both screens first look up a painted image by role in `AssetManifest.images`; when the role is
absent they fall back to the icon the item has always used. Dropping an asset id into the manifest
under any of these roles upgrades that card with no code change. Square PNGs, transparent
background, 512×512 (cards) / 256×256 (chips), same painterly style as the reference frames.

| Role | Where it shows | Subject (from the reference) |
|---|---|---|
| `class.card.newcomer` … `class.card.masterForager` | Forge carousel card, result card, YOUR CLASSES chip, EQUIPPED slot | one illustration per class id (`newcomer`, `nestCarrier`, `eggTrader`, `rakeExpert`, `blastArtist`, `gemSeeker`, `automationExpert`, `masterForager`) |
| `forge.egg` | the golden egg pointer over the chosen card | golden egg, 40 px |
| `perk.bagSize`, `perk.handGrab`, `perk.gemValue`, `perk.featherValue` | Market PERKS cards (large) and the before→after strip (small) | sack of feathers; white glove; purple gems; golden feather egg |
| `bundle.gems100`, `bundle.gems400`, `bundle.gems1500` | Market GEMS cards | gem pouch; gem crate; gem chest |
| `pass.doubleGems`, `pass.infiniteBag` | Market FOREVER cards and the PERKS strip minis | gem cluster; golden feather |
| `shop.mascot` | (reserved) the chicken vendor peeking in from the left | not yet wired |

Everything else on these screens (frames, plaques, ribbons, glow, rarity colours, rainbow borders,
pips, buttons) is drawn from vectors and gradients in code and needs no asset.
