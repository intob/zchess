#!/usr/bin/env python3
"""Your biggest leaks: which kind of mistake has cost you in the most of your
recent games, with the habit that fixes it.

Reads a `zchess review` JSON (default: the cumulative one ec-sync.py keeps).
Mistakes and blunders are grouped by their lesson (hung piece, allowed fork,
missed mate, ...). The top leak is written to a focus file that the live coach
reads (UCI option CoachGames points at its folder): the first comment of
every game names it, and a mistake of the same kind says so.

usage: scripts/leaks.py [review.json] [--recent 20] [--focus <file>]
"""
import argparse
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

# lesson: (what happened, the habit that fixes it)
LESSONS = {
    "hung_piece": ("left a piece hanging",
                   "Before every move, check what your opponent's last move attacks, and that every piece you own is still defended after the move you want to play."),
    "missed_capture": ("missed a free capture",
                       "Every move, look first at every capture you have: is anything of theirs undefended or attacked more often than it is defended?"),
    "bad_capture": ("captured into a losing exchange",
                    "Before you capture, count the attackers and defenders on that square."),
    "allowed_mate": ("allowed checkmate",
                     "Before every move, look at every check your opponent could give next, and keep an escape square for your king."),
    "missed_mate": ("missed checkmate",
                    "Look at every check you have, every move: checks first, then captures, then threats."),
    "allowed_fork": ("walked into a fork",
                     "Look for squares where an enemy knight, pawn or queen could hit two of your pieces at once, above all your king or queen plus anything undefended."),
    "missed_fork": ("missed a fork",
                    "Look for a square where one of your pieces would hit two targets at once: the king, the queen, or anything undefended."),
    "allowed_pin": ("allowed a pin",
                    "Don't leave a piece in front of your king or queen on a line an enemy bishop, rook or queen can reach."),
    "missed_pin": ("missed a pin",
                   "When an enemy piece stands in front of its king or queen, look for a way to pin it."),
    "allowed_skewer": ("allowed a skewer",
                       "Keep your king and queen off lines an enemy bishop, rook or queen can reach when something else stands behind them."),
    "missed_skewer": ("missed a skewer",
                      "When the enemy king or queen shares a line with another piece, look for a check or attack along it."),
    "allowed_discovery": ("allowed a discovered attack",
                          "When an enemy piece stands between its bishop, rook or queen and one of your pieces, ask what happens when it moves away with a threat."),
    "missed_discovery": ("missed a discovered attack",
                         "When one of your pieces blocks your own bishop, rook or queen, ask what it could attack if it moved with a threat."),
    "trapped_piece": ("let a piece get trapped",
                      "Before a piece grabs a pawn or goes deep into enemy territory, check that it has a way back."),
    "missed_trap": ("missed trapping a piece",
                    "When an enemy piece has few squares, look for a move that takes the last ones away."),
    "allowed_removal": ("lost a key defender",
                        "When one piece guards another, it's a target: ask what falls if it gets captured."),
    "missed_removal": ("missed removing a defender",
                       "When an enemy piece is guarded only once, look for a way to capture or chase the guard."),
    "deep_tactic": ("walked into a combination",
                    "When your opponent has a capture or a check, follow the line two moves further before you commit."),
    "king_safety": ("left your king exposed",
                    "Castle early, and think twice before moving the pawns in front of your king."),
    "positional": ("made positional mistakes",
                   "When nothing is hanging, improve your worst-placed piece and keep your pawns and centre solid."),
}

# Older reports have no lesson field.
LEGACY = {"other": "positional"}

EARLY_MOVE = 12

# Lessons whose puzzle is finding your own move (the rest: spotting the reply).
FIND = {"missed_capture", "missed_mate", "missed_fork", "missed_pin", "missed_skewer",
        "missed_discovery", "missed_trap", "missed_removal"}
THREAT = {"hung_piece", "allowed_mate", "allowed_fork", "allowed_pin", "allowed_skewer",
          "allowed_discovery", "trapped_piece", "allowed_removal", "deep_tactic"}

# Lichess puzzle theme names (En Croissant uses the same ones).
MOTIF_THEME = {
    "fork": "fork", "pin": "pin", "skewer": "skewer", "discovered_attack": "discoveredAttack",
    "discovered_check": "discoveredAttack", "double_check": "doubleCheck", "trapped_piece": "trappedPiece",
    "removed_defender": "capturingDefender", "back_rank_mate": "backRankMate", "smothered_mate": "smotheredMate",
}


def lesson_of(flag: dict) -> str:
    return flag.get("lesson") or LEGACY.get(flag["kind"], flag["kind"])


def puzzle_type(flag: dict) -> str | None:
    """"find" (find your better move), "threat" (find the punishment) or None."""
    lesson = lesson_of(flag)
    return "find" if lesson in FIND else "threat" if lesson in THREAT else None


def game_order(game: dict) -> str:
    return (game.get("date") or "") + (game.get("link") or "")


def serious(game: dict) -> list[dict]:
    return [f for f in game["flags"] if f["cls"] != "inaccuracy"]


def leaks(review: dict, recent: int = 20) -> list[dict]:
    """Lessons ranked by how many of the last `recent` games they cost
    something in, with counts for the window before for a trend."""
    games = sorted(review["games"], key=game_order, reverse=True)
    window, before = games[:recent], games[recent:2 * recent]

    def tally(gs):
        out = {}
        for g in gs:
            seen = set()
            for f in serious(g):
                lesson = lesson_of(f)
                t = out.setdefault(lesson, {"lesson": lesson, "count": 0, "games": 0, "early": 0, "blunders": 0, "pieces": {}})
                t["count"] += 1
                t["blunders"] += f["cls"] == "blunder"
                t["early"] += f["move_no"] <= EARLY_MOVE
                if f.get("piece"):
                    t["pieces"][f["piece"]] = t["pieces"].get(f["piece"], 0) + 1
                if lesson not in seen:
                    seen.add(lesson)
                    t["games"] += 1
        return out

    now, prev = tally(window), tally(before)
    out = []
    for lesson, t in now.items():
        what, habit = LESSONS.get(lesson, (lesson.replace("_", " "), ""))
        p = prev.get(lesson, {})
        out.append({**t, "what": what, "habit": habit, "window": len(window),
                    "prev_games": p.get("games", 0), "prev_window": len(before),
                    "piece": max(t["pieces"], key=t["pieces"].get) if t["pieces"] else ""})
    out.sort(key=lambda t: (t["lesson"] != "positional", t["games"], t["count"]), reverse=True)
    return out


def top_leak(ranked: list[dict]) -> dict | None:
    """The leak to work on: the most widespread one that is a habit, not
    positional play (that's too broad to fix with one check)."""
    for t in ranked:
        if t["lesson"] != "positional":
            return t
    return ranked[0] if ranked else None


def describe(t: dict) -> str:
    """One sentence: what, how often, when."""
    s = f"You {t['what']} in {t['games']} of your last {t['window']} games"
    extra = []
    if t["count"] > t["games"]:
        extra.append(f"{t['count']} times")
    if t["early"] * 2 > t["count"]:
        extra.append(f"{t['early']} of them by move {EARLY_MOVE}")
    if t["lesson"] == "hung_piece" and t["piece"]:
        extra.append(f"mostly your {t['piece']}s")
    if extra:
        s += " (" + ", ".join(extra) + ")"
    # A trend only with enough games behind it to mean something.
    if t["prev_window"] >= t["window"] // 2 and t["prev_window"] and max(t["games"], t["prev_games"]) >= 4:
        before = t["prev_games"] * t["window"] / t["prev_window"]
        if t["games"] < before * 0.75:
            s += f", down from {t['prev_games']} in the {t['prev_window']} before"
        elif t["games"] > before * 1.25:
            s += f", up from {t['prev_games']} in the {t['prev_window']} before"
    return s + "."


def write_focus(path: pathlib.Path, t: dict) -> None:
    """The focus file the live coach reads (see coach.zig)."""
    def clean(s):
        return s.replace("\n", " ").strip()
    path.write_text(f"lesson={t['lesson']}\ntext={clean(describe(t))}\nhabit={clean(t['habit'])}\n")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("review", nargs="?", default=str(ROOT / "data/review/fingjoey-all.json"))
    ap.add_argument("--recent", type=int, default=20, help="games to judge by (most recent)")
    ap.add_argument("--focus", help="also write the top leak to this focus file")
    args = ap.parse_args()

    review = json.loads(pathlib.Path(args.review).read_text())
    ranked = leaks(review, args.recent)
    top = top_leak(ranked)
    if not top:
        print("no mistakes or blunders yet")
        return 0
    print(f"#1 leak: {describe(top)}\n   habit: {top['habit']}")
    for t in [t for t in ranked if t is not top][:4]:
        print(f"   then: {describe(t)}")
    if args.focus:
        write_focus(pathlib.Path(args.focus).expanduser(), top)
        print(f"-> {args.focus}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
