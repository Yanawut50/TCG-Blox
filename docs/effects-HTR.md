# Effect coverage: HTR-1 and HTR-2

Measured in Studio with `EffectRegistry.coverage` on 2026-11-06.

| Set | Cards with effects | Fully automatic | Abilities | Automatic |
|---|---|---|---|---|
| HTR-1 | 97 | 37 | 106 | 41 |
| HTR-2 | 70 | 16 | 88 | 27 |
| Both | 167 | 53 (32%) | 194 | 68 (35%) |

An ability runs automatically only when every sentence in it has a handler.
Anything else is logged as `MANUAL` with the English text, and players use the
manual tools. Activate: Main costs are always paid automatically, even when the
effect itself is manual.

## Supported timings

On Play (including Raid), When Attacking, When Blocking, On Retire,
Activate: Main (with rest / AP / discard / remove-this costs and Once Per Turn),
Event cards, "at the end of the Main Phase", and static abilities:
"this character gets BP+X" (with During Your Turn / Opponent's Turn / line
conditions), "+[Color] energy while Active", "enters the field Active".

## Most common templates still missing (count in HTR-1/2)

| # | Template |
|---|---|
| 4 | 自分の場にある⟨n0⟩、⟨n1⟩、⟨n2⟩のカード名の種類の数により、このキャラは以下の効果を全て得る |
| 4 | 」を得る (granting a quoted ability) |
| 4 | 自分の手札を望む枚数公開する |
| 3 | 以下から{0}つ選ぶ (choose one of the bullets) |
| 3 | このキャラの下の裏向きのカード{0}枚につき、このキャラはBP+{1} |
| 2 | {0}種類以上：[During Your Turn]このキャラはBP+{1} |
| 2 | 相手のキャラを{0}枚まで選ぶ |
| 2 | {0}種類以上：カードを{1}枚引く |
| 2 | 自分の場に⟨n0⟩がある場合、『BP{0}以下』に代わる |
| 2 | このカードは⟨n0⟩としても扱う |

After these, almost every remaining template appears on a single card, so the
next gains come one card at a time (step 6).

## How to re-measure

In Studio, press Play and run in the server command bar:

```lua
local ER = require(game.ServerScriptService.Server.Game.EffectRegistry)
local c = ER.coverage({ "HTR-1", "HTR-2" })
print(c.cards, c.autoCards, c.abilities, c.autoAbilities)
```
