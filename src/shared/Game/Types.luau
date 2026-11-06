--!strict
-- Shared game types. The server owns GameState; clients only ever see a view of it.

export type Line = "Front" | "Energy"
export type ZoneName = "Deck" | "Hand" | "Life" | "Front" | "Energy" | "Outside" | "Remove" | "Under" | "Resolving"
export type Phase = "Setup" | "Start" | "Move" | "Main" | "Attack" | "End" | "GameOver"

-- One physical card in a game. Zones hold uids; this holds the per-card state.
export type CardInst = {
	uid: number,
	key: string,
	owner: number,
	zone: ZoneName,
	rested: boolean,
	under: { number }, -- cards below this one after Raid, top-most last
	bpTurn: number, -- BP change that ends with the turn
	bpManual: number, -- BP change set by hand (manual tools), cleared when it leaves the field
	granted: { [string]: any }, -- keywords gained until end of turn
	attacksThisTurn: number,
	blocksThisTurn: number,
}

export type APCard = {
	rested: boolean,
}

export type PlayerState = {
	id: number,
	deck: { number }, -- index 1 is the top
	hand: { number },
	life: { number },
	front: { number },
	energy: { number },
	outside: { number },
	remove: { number },
	ap: { APCard },
	turnsTaken: number,
	extraDrawUsed: boolean,
}

-- What a decision's answer looks like: pick = chosen uids or positions, option = chosen word.
export type Choice = {
	pick: { number }?,
	option: string?,
}

export type Decision = {
	id: number,
	player: number,
	kind: string, -- "Mulligan" | "Block" | "ChooseLife" | "UseTrigger" | "ChooseCards" | "Discard" | "ChooseOption"
	prompt: string,
	candidates: { number }?,
	min: number?,
	max: number?,
	options: { string }?,
	validate: (choice: any) -> (boolean, string?),
}

export type GameState = {
	players: { PlayerState },
	cards: { [number]: CardInst },
	firstPlayer: number,
	turnPlayer: number,
	turnNumber: number,
	phase: Phase,
	winner: number?,
	winReason: string?,
	pending: Decision?,
	log: { string },
	rng: Random,
	nextUid: number,
	nextDecisionId: number,
	co: thread?,
}

export type Action = { [string]: any } -- always has `type: string`

return {}
