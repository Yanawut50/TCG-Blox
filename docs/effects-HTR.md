# Effect coverage: HTR-1 and HTR-2

The full, current report for every set is `docs/effects-coverage.md`
(regenerate with `python tools/effect_report.py`).

| Set | Cards with effects | Fully automatic | Abilities | Automatic |
|---|---|---|---|---|
| HTR-1 | 97 | 41 (42%) | 106 | 45 (42%) |
| HTR-2 | 70 | 18 (26%) | 88 | 30 (34%) |

Step 5 started at 53 of 167 cards; step 6 handlers raised it to 59.

An ability runs automatically only when every sentence in it has a handler.
Anything else is logged as `MANUAL` with the English text, and players use the
manual tools. Activate: Main costs are always paid automatically.

The cards still manual and what blocks each one are in
`docs/effects-manual-cards.csv` (filter the `set` column for HTR-1 / HTR-2).
