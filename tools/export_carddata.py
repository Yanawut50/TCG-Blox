"""Export Union Arena cards from union_arena.db to JSON for Rojo.

Output (Rojo turns each .json into a ModuleScript that returns a table):
  src/carddata/index.json        set list + key -> set map + data warnings
  src/carddata/sets/<SET>.json   { "<card_key>": Card, ... }

The DB is copied to a temp folder and read from there, never opened in place.
Only the .db file is copied; a stray .db-journal next to it is ignored on purpose
(applying a stale journal corrupted a test copy).

DB location: --db PATH, otherwise the first tools/data/union_arena.db found in this
repo or a parent folder (so it also works from a git worktree nested in the repo).

Usage:  python tools/export_carddata.py [--db PATH]
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
import sqlite3
import sys
import tempfile
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import effect_parse  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
OUT_DIR = ROOT / "src" / "carddata"
SETS_DIR = OUT_DIR / "sets"
DB_REL = Path("tools") / "data" / "union_arena.db"

COLUMNS = (
    "card_key, card_number_jp, name_en, name_jp, series, set_en, card_type, colors, "
    "rarity, need_energy, ap, bp, generated_energy, traits, effect_jp, effect_en, "
    "trigger_type, trigger_jp, trigger_en, image_url_jp"
)

BASE_COLORS = {"Red", "Blue", "Yellow", "Green", "Purple"}
ICON_RE = re.compile(r"Red|Blue|Yellow|Green|Purple|\+")


def find_db() -> Path | None:
    for d in (ROOT, *ROOT.parents):
        p = d / DB_REL
        if p.exists():
            return p
    return None


def set_of(key: str) -> str:
    """HTR-1-030 -> HTR-1, AOT-P-001 -> AOT-P, ARK-AP01 -> ARK, 2023-AP01 -> AP-2023, IMS_AP04 -> IMS."""
    if "-" not in key:
        return key.split("_", 1)[0]
    prefix = key.rsplit("-", 1)[0]
    if prefix.isdigit():
        return "AP-" + prefix
    return prefix


def to_int(v) -> int | None:
    if v is None or v == "" or v == "None":
        return None
    try:
        return int(v)
    except (TypeError, ValueError):
        return None


def to_list(v) -> list:
    if not v:
        return []
    try:
        x = json.loads(v)
        return x if isinstance(x, list) else [x]
    except json.JSONDecodeError:
        return [v]


def parse_bp(v) -> tuple[int | None, str]:
    """3000 -> (3000, ""), "3000+" -> (3000, "+"). The mark is printed on the card next to BP."""
    if v is None or v == "" or v == "None":
        return None, ""
    m = re.fullmatch(r"(\d+)\s*([+\-±]?)", str(v).strip())
    if not m:
        return None, str(v)
    return int(m.group(1)), m.group(2)


# Keyword effects (Asia rule manual p.14), by their JP bracket text.
KEYWORDS = {
    "ステップ": ("step", True),
    "狙い撃ち": ("calledStrike", True),
    "2回アタック": ("doubleAttack", True),
    "2回ブロック": ("doubleBlock", True),
    "インパクト（1）": ("impact", 1),
    "インパクト（+1）": ("impactPlus", 1),
    "ダメージ（2）": ("damage", 2),
    "ダメージ（+1）": ("damagePlus", 1),
    "インパクト無効": ("nullifyImpact", True),
}
KW_RE = re.compile(r"【(" + "|".join(re.escape(k) for k in KEYWORDS) + r")】(（[^）]*）)?")


def parse_keywords(effect_jp: str) -> dict:
    """Unconditional keywords only: the keyword starts an ability (text start, or right
    after "。", "）" or another bracket) and is not followed by を得る/を与える/と
    (which mean it is granted conditionally or to another card). Conditional keywords
    are left to effect handlers."""
    out: dict = {}
    for m in KW_RE.finditer(effect_jp):
        before = effect_jp[: m.start()]
        after = effect_jp[m.end():]
        # "...アクティブにし、フロントLに移動できる" is the end of a Raid header.
        if before and before[-1] not in "。）】" and not before.endswith("移動できる"):
            continue
        if before.endswith("【起動メイン】") or re.search(r"【(アタック時|ブロック時|登場時|退場時)】$", before):
            continue
        if re.match(r"\s*(を得る|を得て|を与える|と|や|を持つ|を失)", after):
            continue
        name, value = KEYWORDS[m.group(1)]
        out[name] = value
    return out


def parse_raid(effect_jp: str) -> dict | None:
    """【レイド】〈name〉 or 【レイド】［特徴：trait］ at the start of an ability."""
    m = re.search(r"【レイド】(〈([^〉]+)〉|［特徴：([^］]+)］)", effect_jp)
    if not m:
        return None
    if m.group(2):
        return {"kind": "name", "value": m.group(2)}
    return {"kind": "trait", "value": m.group(3)}


def parse_deck_limit(effect_jp: str) -> int | None:
    m = re.search(r"デッキに(\d+)枚まで入れられる", effect_jp)
    return int(m.group(1)) if m else None


_abilities_ok = True


def parse_abilities(effect_jp: str, card_type: str) -> list:
    """Abilities for EffectRegistry. Needs tools/ua_translate.py (in this repo or a parent)."""
    global _abilities_ok
    if not _abilities_ok:
        return []
    try:
        return effect_parse.parse(effect_jp, card_type, ROOT)
    except FileNotFoundError as e:
        _abilities_ok = False
        print(f"WARNING: {e}; cards are exported without abilities (effects will all be manual)", file=sys.stderr)
        return []


def clean_text(v) -> str:
    return "" if v in (None, "-") else str(v)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", type=Path, default=None)
    args = ap.parse_args()

    db_path = args.db or find_db()
    if not db_path or not db_path.exists():
        print(f"DB not found (looked for {DB_REL} from {ROOT} upward)", file=sys.stderr)
        return 1
    print(f"Reading {db_path}")

    with tempfile.TemporaryDirectory() as tmp:
        tmp_db = Path(tmp) / "union_arena.db"
        shutil.copyfile(db_path, tmp_db)
        con = sqlite3.connect(tmp_db)
        con.row_factory = sqlite3.Row
        if con.execute("pragma integrity_check").fetchone()[0] != "ok":
            print("integrity_check failed on the DB copy", file=sys.stderr)
            return 1
        rows = con.execute(f"select {COLUMNS} from cards_full order by card_key").fetchall()
        con.close()

    sets: dict[str, dict[str, dict]] = defaultdict(dict)
    set_meta: dict[str, dict] = {}
    warnings: dict[str, list[str]] = defaultdict(list)

    for r in rows:
        key = r["card_key"]
        # The scraper glued energy icons together ("PurplePurple", "Yellow+") and its
        # "count" is wrong for those, so recount from the icon names.
        energy: list[dict] = []
        energy_mark = False
        for e in to_list(r["generated_energy"]):
            if not isinstance(e, dict):
                continue
            raw = str(e.get("color", ""))
            icons = ICON_RE.findall(raw)
            if "".join(icons) != raw:
                warnings["unparsed_generated_energy"].append(key)
            # Rulebook p.01-02: "+" only marks that an effect may raise this card's
            # energy generation. It is not an energy icon, so it is kept as a flag.
            if "+" in icons:
                energy_mark = True
            for icon in icons:
                if icon == "+":
                    continue
                color = icon
                if energy and energy[-1]["color"] == color:
                    energy[-1]["count"] += 1
                else:
                    energy.append({"color": color, "count": 1})
        bp, bp_mark = parse_bp(r["bp"])

        card = {
            "key": key,
            "numberJp": r["card_number_jp"] or "",
            "nameEn": r["name_en"] or "",
            "nameJp": r["name_jp"] or "",
            "series": r["series"] or "",
            "setName": r["set_en"] or "",
            "cardType": r["card_type"] or "",
            "colors": [p for c in to_list(r["colors"]) for p in str(c).split("/") if p],
            "rarity": r["rarity"] or "",
            "needEnergy": to_int(r["need_energy"]),
            "ap": to_int(r["ap"]),
            "bp": bp,
            "bpMark": bp_mark,
            "generatedEnergy": energy,
            "energyMark": energy_mark,
            "traits": to_list(r["traits"]),
            "keywords": parse_keywords(clean_text(r["effect_jp"])),
            "raid": parse_raid(clean_text(r["effect_jp"])),
            "deckLimit": parse_deck_limit(clean_text(r["effect_jp"])),
            "abilities": parse_abilities(clean_text(r["effect_jp"]), r["card_type"] or ""),
            "effectJp": clean_text(r["effect_jp"]),
            "effectEn": clean_text(r["effect_en"]),
            "triggerType": r["trigger_type"] or "",
            "triggerJp": clean_text(r["trigger_jp"]),
            "triggerEn": clean_text(r["trigger_en"]),
            "imageUrl": r["image_url_jp"] or "",
        }
        if card["cardType"] == "Character" and card["bp"] is None:
            warnings["character_without_bp"].append(key)
        if any(c not in BASE_COLORS for c in card["colors"]):
            warnings["odd_colors"].append(key)

        s = set_of(key)
        sets[s][key] = card
        meta = set_meta.setdefault(s, {"id": s, "series": card["series"], "setNames": set(), "count": 0})
        meta["count"] += 1
        if card["setName"]:
            meta["setNames"].add(card["setName"])

    # Rewrite the sets folder from scratch so removed sets don't linger.
    if SETS_DIR.exists():
        shutil.rmtree(SETS_DIR)
    SETS_DIR.mkdir(parents=True)

    for s, cards in sorted(sets.items()):
        with open(SETS_DIR / f"{s}.json", "w", encoding="utf-8", newline="\n") as f:
            json.dump(cards, f, ensure_ascii=False, indent=1)

    index = {
        "version": 1,
        "cardCount": len(rows),
        "sets": [{**m, "setNames": sorted(m["setNames"])} for _, m in sorted(set_meta.items())],
        "keyToSet": {k: s for s, cards in sorted(sets.items()) for k in cards},
        "warnings": {k: sorted(set(v)) for k, v in sorted(warnings.items())},
    }
    with open(OUT_DIR / "index.json", "w", encoding="utf-8", newline="\n") as f:
        json.dump(index, f, ensure_ascii=False, indent=1)

    print(f"Exported {len(rows)} cards into {len(sets)} sets -> {OUT_DIR}")
    for k, v in index["warnings"].items():
        print(f"  warning {k}: {len(v)} card(s), e.g. {v[:3]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
