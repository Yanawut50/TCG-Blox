--!strict
-- Numbers from the Union Arena Official Rule Manual (Asia/EN, updated 2023-11-22).
-- Page numbers refer to that manual.

local Constants = {}

Constants.DECK_SIZE = 50 -- p.05
Constants.MAX_COPIES = 4 -- p.05, same card number
Constants.MAX_PER_SPECIAL_TRIGGER = 4 -- p.05, per trigger type: Special, Color, Final
Constants.LIMITED_TRIGGERS = { "Special", "Color", "Final" }
Constants.AP_CARDS = 3 -- p.05

Constants.STARTING_HAND = 7 -- p.05
Constants.MULLIGANS = 1 -- p.05
Constants.STARTING_LIFE = 7 -- p.04-05

Constants.LINE_SIZE = 4 -- p.04, Front Line and Energy Line each
Constants.HAND_LIMIT = 8 -- p.13, checked in End Phase

-- p.08: AP cards in the AP Area on a player's 1st, 2nd, 3rd+ turn.
Constants.AP_BY_TURN_FIRST = { 1, 2, 3 }
Constants.AP_BY_TURN_SECOND = { 2, 2, 3 }

Constants.EXTRA_DRAW_COST = 1 -- p.08, once per turn

Constants.ACTIVE_TRIGGER_BP = 3000 -- trigger text in card data: "[Active] ... BP+3000 this turn"

Constants.PHASES = { "Start", "Move", "Main", "Attack", "End" }

return Constants
