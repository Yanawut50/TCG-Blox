"""Split a card's JP effect text into abilities for the game's EffectRegistry.

Uses the same tag conversion and sentence split as tools/ua_translate.py, so a
step's key is the sentence template from translations_sentences.json, except
that card names / traits are numbered per step (⟨n0⟩, ⟦t0⟧ ...) and reminder
text in （…） is dropped.

ability = {
  "timing": "OnPlay" | "WhenAttacking" | "WhenBlocking" | "OnRetire" | "ActivateMain"
            | "Static" | "Event",
  "conds":  ["yourTurn" | "oppTurn" | "front" | "energy" | ...],
  "costs":  {"rest": true, "ap": n, "discard": n, "retireSelf": true},
  "once":   true | absent,
  "steps":  [{"key": str, "nums": [int], "names": [str], "traits": [str], "bullet": bool}],
}
"""
from __future__ import annotations

import importlib.util
import re
from pathlib import Path

_UA = None


def _load_ua(root: Path):
    global _UA
    if _UA is not None:
        return _UA
    for d in (root, *root.parents):
        p = d / "tools" / "ua_translate.py"
        if p.exists():
            spec = importlib.util.spec_from_file_location("ua_translate", p)
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)  # type: ignore[union-attr]
            _UA = mod
            return mod
    raise FileNotFoundError("tools/ua_translate.py not found in this repo or a parent folder")


TIMINGS = {
    "On Play": "OnPlay",
    "When Attacking": "WhenAttacking",
    "When Blocking": "WhenBlocking",
    "On Retire": "OnRetire",
    "Activate: Main": "ActivateMain",
}
CONDS = {
    "During Your Turn": "yourTurn",
    "During Opponent's Turn": "oppTurn",
    "While in Front Line": "front",
    "While in Energy Line": "energy",
    "While in Outside Area": "outside",
    "While in Remove Area": "remove",
}
KEYWORD_TAG = re.compile(r"^(Step|Snipe|Double Attack|Double Block|Impact Nullify|Impact [+\d]+|Damage [+\d]+|Raid)$")
RAID_HEADER = re.compile(r"^⟨n\d+⟩アクティブにし、フロントLに移動できる$|^⟦t\d+⟧アクティブにし、フロントLに移動できる$")
SPLIT_SENT = r"(?<=。)|(?=・)|(?<=アクティブにし、フロントLに移動できる)(?=[^）)])"
SPLIT_PIECE = r"(?:(?<=^)|(?<=[)\]）”]))(?=\[(?!(?:Red|Blue|Yellow|Green|Purple)(?: x\d+)?\]))"


def _local_key(piece: str, names: list[str], traits: list[str], ua) -> dict:
    piece = re.sub(r"（[^）]*）", "", piece).strip()
    local_names: list[str] = []
    local_traits: list[str] = []

    def rn(m):
        local_names.append(names[int(m.group(1))])
        return f"⟨n{len(local_names) - 1}⟩"

    def rt(m):
        local_traits.append(traits[int(m.group(1))])
        return f"⟦t{len(local_traits) - 1}⟧"

    piece = re.sub(r"⟨n(\d+)⟩", rn, piece)
    piece = re.sub(r"⟦t(\d+)⟧", rt, piece)
    key, nums = ua.template_key(piece)
    # English for prompts (e.g. "choose one of the following"): rebuild the JP
    # sentence with its real names/traits and run the project's translator on it.
    jp = re.sub(r"⟨n(\d+)⟩", lambda m: "〈" + local_names[int(m.group(1))] + "〉", piece)
    jp = re.sub(r"⟦t(\d+)⟧", lambda m: "［特徴：" + local_traits[int(m.group(1))] + "］", jp)
    try:
        en = ua.translate(jp)[0]
    except Exception:  # the translator is best-effort; never block the export
        en = ""
    return {"key": key, "nums": [int(n) for n in nums], "names": local_names, "traits": local_traits, "en": en}


def parse(effect_jp: str, card_type: str, root: Path) -> list[dict]:
    if not effect_jp or effect_jp.strip() in ("-", "－"):
        return []
    ua = _load_ua(root)
    names: list[str] = []
    traits: list[str] = []

    def keep_name(m):
        names.append(m.group(1))
        return f"⟨n{len(names) - 1}⟩"

    def keep_trait(m):
        traits.append(m.group(1))
        return f"⟦t{len(traits) - 1}⟧"

    t = ua.translate_keywords(effect_jp)
    t = re.sub(r"〈([^〉]+)〉", keep_name, t)
    t = re.sub(r"［特徴：([^］]+)］", keep_trait, t)

    default_timing = "Event" if card_type == "Event" else "Static"
    abilities: list[dict] = []
    current: dict | None = None
    pending_tags: list[str] = []

    def new_ability(timing: str) -> dict:
        a = {"timing": timing, "conds": [], "costs": {}, "steps": []}
        abilities.append(a)
        return a

    for line in t.split("\n"):
        for sent in re.split(SPLIT_SENT, line):
            bullet = sent.strip().startswith("・")
            sent = sent.strip().lstrip("・").rstrip("。")
            for piece in re.split(SPLIT_PIECE, sent):
                if not piece.strip():
                    continue
                tags: list[str] = []
                while mm := re.match(r"^\s*\[([^\]]+)\]", piece):
                    tags.append(mm.group(1))
                    piece = piece[mm.end():]
                    if re.match(r"^\s*\[(?!(?:Red|Blue|Yellow|Green|Purple)(?: x\d+)?\])", piece) is None:
                        break
                body = piece.strip()
                # Tags arrive one per piece ("[Activate: Main]", "[Rest this card]", ...):
                # hold them until a piece with real text comes.
                if not re.sub(r"（[^）]*）", "", body).strip() or RAID_HEADER.match(body):
                    pending_tags.extend(tags)
                    continue
                tags = pending_tags + tags
                pending_tags.clear()
                ability_tags = [x for x in tags if not KEYWORD_TAG.match(x)]
                if ability_tags:
                    timing = next((TIMINGS[x] for x in ability_tags if x in TIMINGS), None)
                    current = new_ability(timing or default_timing)
                    for x in ability_tags:
                        if x in CONDS:
                            current["conds"].append(CONDS[x])
                        elif x == "Once Per Turn":
                            current["once"] = True
                        elif x == "Rest this card":
                            current["costs"]["rest"] = True
                        elif x == "Retire this card":
                            current["costs"]["retireSelf"] = True
                        elif m := re.fullmatch(r"Pay (\d+) AP", x):
                            current["costs"]["ap"] = int(m.group(1))
                        elif m := re.fullmatch(r"Put (\d+) card\(s\) from your hand into your Outside Area", x):
                            current["costs"]["discard"] = int(m.group(1))
                        elif x not in TIMINGS:
                            current.setdefault("unknownTags", []).append(x)
                if current is None:
                    current = new_ability(default_timing)
                step = _local_key(body, names, traits, ua)
                step["bullet"] = bullet
                current["steps"].append(step)
    return [a for a in abilities if a["steps"]]
