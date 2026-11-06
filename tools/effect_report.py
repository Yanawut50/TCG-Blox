"""Effect coverage report: which cards run automatically and what is missing.

Reads the handler keys straight from src/server/Game/EffectRegistry.luau and
the abilities from src/carddata/sets/*.json, using the same rules as
EffectRegistry.isSupported:
  - timing must be one of AUTO_TIMINGS (or Static with only static keys),
  - no "choose one of the bullets" steps, no unknown tags,
  - every step has a handler, directly or after a known prefix.

Writes:
  docs/effects-coverage.md            per series / set summary
  docs/effects-missing-templates.csv  missing templates ranked by how many abilities need them
  docs/effects-manual-cards.csv       every card that is not fully automatic, with what blocks it

Usage:  python tools/effect_report.py [--top N]
"""
from __future__ import annotations

import argparse
import csv
import json
import re
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REGISTRY = ROOT / "src" / "server" / "Game" / "EffectRegistry.luau"
SETS_DIR = ROOT / "src" / "carddata" / "sets"
DOCS = ROOT / "docs"

AUTO_TIMINGS = {"OnPlay", "WhenAttacking", "WhenBlocking", "OnRetire", "ActivateMain", "Event"}
COLORS = ["Red", "Blue", "Yellow", "Green", "Purple"]


def load_registry() -> tuple[set[str], set[str], list[str]]:
    src = REGISTRY.read_text(encoding="utf-8")
    handlers: set[str] = set()
    # Keys contain "{0}", so take every string literal between "register(" and "function".
    for m in re.finditer(r"register\((.*?),\s*function", src, re.S):
        handlers.update(re.findall(r'"([^"]*)"', m.group(1)))
    prefixes = re.findall(r'\{\s*prefix\s*=\s*"([^"]*)"', src)
    # Keys registered in loops: marker tables / constants, and the name-list variants.
    for name in ("LIMIT_KEYS", "CHOOSE_KEYS"):
        if m := re.search(r"local " + name + r" = \{(.*?)\}\n", src):
            handlers.update(re.findall(r'\["([^"]*)"\]', m.group(1)))
    for name in ("PLAYED_THIS_TURN", "BP_SUBST"):
        if m := re.search(r"local " + name + r' = "([^"]*)"', src):
            handlers.add(m.group(1))
    for n in range(2, 5):
        handlers.add("その中から" + "か".join(f"⟨n{i}⟩" for i in range(n)) + "を{0}枚まで公開し手札に加える")
    static: set[str] = set()
    if m := re.search(r'local STATIC_BP = "([^"]*)"', src):
        static.add(m.group(1))
    if m := re.search(r"local ENTERS_ACTIVE = \{(.*?)\}\n", src):
        static.update(re.findall(r'\["([^"]*)"\]', m.group(1)))
    static.update(re.findall(r'STATIC_KEYS\["([^"]*)"\] = true', src))
    # STATIC_KEYS[SOME_CONSTANT] = true  ->  local SOME_CONSTANT = "..."
    for const in re.findall(r"STATIC_KEYS\[([A-Z_]+)\] = true", src):
        if m := re.search(r"local " + const + r' = "([^"]*)"', src):
            static.add(m.group(1))
    if m := re.search(r'local k = "([^"]*)" \.\. color \.\. "([^"]*)"', src):
        static.update(m.group(1) + c + m.group(2) for c in COLORS)
    return handlers, static, prefixes


def step_ok(key: str, handlers: set[str], prefixes: list[str]) -> bool:
    if key in handlers:
        return True
    return any(key.startswith(p) and key[len(p):] in handlers for p in prefixes)


def ability_blockers(a: dict, handlers, static, prefixes) -> list[str]:
    """Empty list = runs automatically. Otherwise the reasons / missing keys."""
    if a.get("unknownTags"):
        return ["tag:" + t for t in a["unknownTags"]]
    if a["timing"] == "Static":
        return [s["key"] for s in a["steps"] if s["key"] not in static]
    if a["timing"] not in AUTO_TIMINGS:
        return ["timing:" + a["timing"]]
    out = []
    seen_choose = False
    for s in a["steps"]:
        inner = next((s["key"][len(p):] for p in prefixes if s["key"].startswith(p)), s["key"])
        if s.get("bullet") and not seen_choose:
            out.append("(bullet without choice) " + s["key"])
        elif not step_ok(s["key"], handlers, prefixes):
            out.append(s["key"])
        if inner in ("以下から{0}つ選ぶ", "以下から{0}つまで選ぶ"):
            seen_choose = True
    return out


def series_of(set_id: str) -> str:
    return re.split(r"[-_]", set_id)[0]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--top", type=int, default=40)
    args = ap.parse_args()

    handlers, static, prefixes = load_registry()
    per_set: dict[str, Counter] = defaultdict(Counter)
    missing: Counter = Counter()
    missing_cards: dict[str, set[str]] = defaultdict(set)
    manual_rows = []

    for f in sorted(SETS_DIR.glob("*.json")):
        set_id = f.stem
        for key, card in json.loads(f.read_text(encoding="utf-8")).items():
            abilities = card.get("abilities") or []
            if not abilities:
                continue
            c = per_set[set_id]
            c["cards"] += 1
            card_block = []
            for a in abilities:
                c["abilities"] += 1
                b = ability_blockers(a, handlers, static, prefixes)
                if b:
                    card_block += b
                    for k in set(b):
                        missing[k] += 1
                        missing_cards[k].add(key)
                else:
                    c["autoAbilities"] += 1
            if card_block:
                manual_rows.append([key, set_id, card.get("nameEn") or card.get("nameJp"), " | ".join(dict.fromkeys(card_block))])
            else:
                c["autoCards"] += 1

    DOCS.mkdir(exist_ok=True)
    total = Counter()
    by_series: dict[str, Counter] = defaultdict(Counter)
    for s, c in per_set.items():
        total.update(c)
        by_series[series_of(s)].update(c)

    def pct(a, b):
        return f"{100 * a / b:.0f}%" if b else "-"

    lines = [
        "# Effect coverage (all sets)",
        "",
        "Generated by `python tools/effect_report.py` from the handler keys in",
        "`src/server/Game/EffectRegistry.luau` and the abilities in `src/carddata`.",
        "A card is *automatic* when every one of its abilities runs without the manual tools.",
        "",
        f"**Total:** {total['autoCards']} / {total['cards']} cards automatic ({pct(total['autoCards'], total['cards'])}), "
        f"{total['autoAbilities']} / {total['abilities']} abilities ({pct(total['autoAbilities'], total['abilities'])}). "
        f"Handlers: {len(handlers)} step templates + {len(static)} static templates.",
        "",
        "## By series",
        "",
        "| Series | Cards with effects | Automatic | Abilities | Automatic |",
        "|---|---|---|---|---|",
    ]
    for s in sorted(by_series, key=lambda x: -by_series[x]["autoCards"] / max(1, by_series[x]["cards"])):
        c = by_series[s]
        lines.append(f"| {s} | {c['cards']} | {c['autoCards']} ({pct(c['autoCards'], c['cards'])}) | {c['abilities']} | {c['autoAbilities']} ({pct(c['autoAbilities'], c['abilities'])}) |")
    lines += ["", "## By set", "", "| Set | Cards | Automatic | Abilities | Automatic |", "|---|---|---|---|---|"]
    for s in sorted(per_set):
        c = per_set[s]
        lines.append(f"| {s} | {c['cards']} | {c['autoCards']} ({pct(c['autoCards'], c['cards'])}) | {c['abilities']} | {c['autoAbilities']} ({pct(c['autoAbilities'], c['abilities'])}) |")
    lines += [
        "",
        f"## Top {args.top} missing templates",
        "",
        "Count = abilities that need this template. Full list: `docs/effects-missing-templates.csv`;",
        "every manual card and what blocks it: `docs/effects-manual-cards.csv`.",
        "",
        "| Abilities | Cards | Template |",
        "|---|---|---|",
    ]
    for k, n in missing.most_common(args.top):
        lines.append(f"| {n} | {len(missing_cards[k])} | {k.replace('|', '/')} |")
    (DOCS / "effects-coverage.md").write_text("\n".join(lines) + "\n", encoding="utf-8")

    with open(DOCS / "effects-missing-templates.csv", "w", encoding="utf-8-sig", newline="") as f:
        w = csv.writer(f)
        w.writerow(["abilities", "cards", "template", "example_cards"])
        for k, n in missing.most_common():
            w.writerow([n, len(missing_cards[k]), k, " ".join(sorted(missing_cards[k])[:5])])
    with open(DOCS / "effects-manual-cards.csv", "w", encoding="utf-8-sig", newline="") as f:
        w = csv.writer(f)
        w.writerow(["card", "set", "name", "blocked_by"])
        w.writerows(sorted(manual_rows))

    htr = Counter()
    for s in ("HTR-1", "HTR-2"):
        htr.update(per_set.get(s, Counter()))
    print(f"total {total['autoCards']}/{total['cards']} cards, {total['autoAbilities']}/{total['abilities']} abilities")
    print(f"HTR-1+2 {htr['autoCards']}/{htr['cards']} cards, {htr['autoAbilities']}/{htr['abilities']} abilities")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
