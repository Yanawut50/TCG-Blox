--!strict
-- Step 1 smoke test: prints what the card database looks like on server start.
-- Safe to delete once later steps use CardData for real.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CardData = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("CardData"))

local index = CardData.getIndex()
print(("[CardDataCheck] %d cards in %d sets"):format(index.cardCount, #index.sets))

local htr2 = CardData.getSet("HTR-2")
local n = 0
if htr2 then
	for _ in htr2 do
		n += 1
	end
end
print(("[CardDataCheck] HTR-2 loaded: %d cards"):format(n))

local card = CardData.get("HTR-2-001")
if card then
	print(("[CardDataCheck] %s %s | %s | need %s AP %s BP %s%s"):format(
		card.key,
		card.nameEn,
		card.cardType,
		tostring(card.needEnergy),
		tostring(card.ap),
		tostring(card.bp),
		card.bpMark
	))
	print("[CardDataCheck] effect:", card.effectEn)
else
	warn("[CardDataCheck] HTR-2-001 not found")
end

for name, keys in index.warnings do
	warn(("[CardDataCheck] data warning %s: %d card(s)"):format(name, #keys))
end
