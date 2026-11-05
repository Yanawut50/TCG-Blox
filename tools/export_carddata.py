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
        for e in to_list(r["generated_energy"]):
            if not isinstance(e, dict):
                continue
            raw = str(e.get("color", ""))
            icons = ICON_RE.findall(raw)
            if "".join(icons) != raw:
                warnings["unparsed_generated_energy"].append(key)
            if "+" in icons:
                warnings["energy_plus_icon"].append(key)
            for icon in icons:
                color = "Plus" if icon == "+" else icon
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
            "traits": to_list(r["traits"]),
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
