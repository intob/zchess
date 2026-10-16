#!/usr/bin/env python3
"""Fill the review report template with a `zchess review` JSON file.

Adds your leaks (scripts/leaks.py) and opening drills: positions from your
games while still in opening theory, with what strong players play there.

usage: scripts/review-report.py review.json > report.html
"""
import json
import pathlib
import sys

import leaks

data = json.loads(pathlib.Path(sys.argv[1]).read_text())

ranked = leaks.leaks(data)
top = leaks.top_leak(ranked)
data["leaks"] = [{**t, "text": leaks.describe(t)} for t in ranked]
data["top_leak"] = top["lesson"] if top else ""
data["lesson_names"] = {k: what for k, (what, _) in leaks.LESSONS.items()}
data["puzzle_types"] = {**{k: "find" for k in leaks.FIND}, **{k: "threat" for k in leaks.THREAT}}
for g in data["games"]:
    for f in g["flags"]:
        f.setdefault("lesson", leaks.lesson_of(f))

# Opening drills: positions from your games while still in opening theory.
# Kept: where leaving theory cost you (3+ points of winning chances), and
# positions you reach often (twice or more) and play a book move in at least
# once. A cheap deviation you make on purpose (1.Nc3, say) isn't drilled.
COSTLY = 3
positions = {}
for g in sorted(data["games"], key=leaks.game_order):
    for m in g.get("opening_moves", []):
        key = " ".join(m["fen"].split()[:4])
        d = positions.setdefault(key, {"color": g["color"], "games": 0, "played_counts": {}, "ok_moves": {}, "costly": False, "in_book": False})
        d.update({k: m[k] for k in ("fen", "move_no", "book", "total", "opening", "eco")})
        d["line"] = g["moves"][:m["ply"]]
        d["games"] += 1
        d["played_counts"][m["played"]] = d["played_counts"].get(m["played"], 0) + 1
        d["costly"] |= m["exit"] and m["drop"] >= COSTLY
        # Your own moves that didn't cost anything count as right answers too.
        if not (m["exit"] and m["drop"] >= COSTLY):
            d["ok_moves"][m["played_uci"]] = m["played"]
        d["in_book"] |= not m["exit"]
        d["last_date"] = g["date"]
data["drills"] = sorted((d for d in positions.values() if d["costly"] or (d["in_book"] and d["games"] >= 2)),
                        key=lambda d: (not d["costly"], -d["games"], len(d["line"])))

template = (pathlib.Path(__file__).parent / "review-report.html").read_text()
title = f"<title>{data['user']} Game Review</title>"
payload = json.dumps(data, separators=(",", ":")).replace("</", "<\\/")
html = template.replace("<title>fingjoey Game Review</title>", title, 1).replace("/*REVIEW_DATA*/", payload, 1)
sys.stdout.write(html)
