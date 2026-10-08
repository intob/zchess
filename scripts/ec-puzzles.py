#!/usr/bin/env python3
"""Puzzle database from your own games, for En Croissant's Puzzles tab.

Reads a `zchess review` JSON (default: the cumulative one ec-sync.py keeps) and
writes a database in the same format as En Croissant's Lichess puzzles:
  - "find the win": you missed a capture or a mate. The opponent's previous
    move is played, then you find the move you missed.
  - "spot the threat": you hung a piece or allowed mate. Your move is played,
    then you find how your opponent punishes it.
Lichess convention: `fen` is the position before the first move of `moves`,
which En Croissant plays automatically; the solver plays the next move.

usage: scripts/ec-puzzles.py [review.json] [--name "fingjoey mistakes"]
"""
import argparse
import json
import pathlib
import sqlite3
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
PUZZLES = pathlib.Path.home() / "Library/Application Support/org.encroissant.app/puzzles"

SCHEMA = """
CREATE TABLE puzzles (
    id INTEGER PRIMARY KEY,
    fen TEXT,
    moves TEXT,
    rating INTEGER,
    rating_deviation INTEGER,
    popularity INTEGER,
    nb_plays INTEGER);
CREATE TABLE themes (
    id INTEGER PRIMARY KEY,
    name TEXT UNIQUE);
CREATE TABLE puzzle_themes (
    puzzle_id INTEGER,
    theme_id INTEGER,
    PRIMARY KEY (theme_id, puzzle_id),
    FOREIGN KEY(puzzle_id) REFERENCES puzzles(id),
    FOREIGN KEY(theme_id) REFERENCES themes(id)) WITHOUT ROWID;
CREATE INDEX idx_puzzles_rating ON puzzles(rating);
CREATE INDEX idx_puzzle_themes_puzzle_id ON puzzle_themes(puzzle_id);
"""


def solver_line(line: list[str], mate: bool) -> list[str]:
    """The solution moves (solver, reply, solver, ...), ending on a solver move.
    Mates keep the whole line; anything else is a one-move puzzle."""
    if not line:
        return []
    if not mate:
        return line[:1]
    return line[: len(line) if len(line) % 2 == 1 else len(line) - 1]


def make_puzzle(flag: dict) -> dict | None:
    kind = flag["kind"]
    if flag["cls"] == "inaccuracy":
        return None
    if kind in ("missed_capture", "missed_mate"):
        if "setup_fen" not in flag:
            return None
        mate = kind == "missed_mate"
        solution = solver_line(flag.get("best_line_uci", []), mate)
        fen, setup, theme = flag["setup_fen"], flag["setup_uci"], "findTheWin"
    elif kind in ("hung_piece", "allowed_mate"):
        mate = kind == "allowed_mate"
        solution = solver_line(flag.get("refutation_uci", []), mate)
        fen, setup, theme = flag["fen"], flag["played_uci"], "spotTheThreat"
    else:
        return None
    if not solution or "0000" in solution:
        return None
    solver_moves = (len(solution) + 1) // 2
    themes = [theme, flag["phase"]]
    if mate:
        themes += ["mate", f"mateIn{solver_moves}"]
        rating = 900 + 200 * (solver_moves - 1)
    else:
        themes += ["hangingPiece", "oneMove"]
        rating = 700 if theme == "findTheWin" else 800
    return {"fen": fen, "moves": " ".join([setup] + solution), "rating": rating, "themes": themes}


def legal(puzzles: list[dict]) -> list[bool]:
    """Replay each puzzle through zchess, which reports moves it can't play."""
    zchess = ROOT / "zig-out" / "bin" / "zchess"
    script = "".join(f"position fen {p['fen']} moves {p['moves']}\nisready\n" for p in puzzles) + "quit\n"
    out = subprocess.run([str(zchess)], input=script, capture_output=True, text=True, check=True).stdout
    ok, cur = [], True
    for line in out.splitlines():
        if line.startswith("info string"):
            cur = False
        elif line == "readyok":
            ok.append(cur)
            cur = True
    assert len(ok) == len(puzzles), "zchess output out of step"
    return ok


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("review", nargs="?", default=str(ROOT / "data/review/fingjoey-all.json"))
    ap.add_argument("--name", default=None, help="database name in En Croissant")
    args = ap.parse_args()

    review = json.loads(pathlib.Path(args.review).read_text())
    name = args.name or f"{review['user']} mistakes"
    puzzles, seen = [], set()
    for game in review["games"]:
        for flag in game["flags"]:
            p = make_puzzle(flag)
            if p and (p["fen"], p["moves"]) not in seen:
                seen.add((p["fen"], p["moves"]))
                puzzles.append(p)
    checked = legal(puzzles)
    if not all(checked):
        print(f"dropping {checked.count(False)} puzzles with illegal moves", file=sys.stderr)
        puzzles = [p for p, ok in zip(puzzles, checked) if ok]

    PUZZLES.mkdir(parents=True, exist_ok=True)
    path = PUZZLES / f"{name}.db3"
    tmp = path.with_suffix(".tmp")
    tmp.unlink(missing_ok=True)
    db = sqlite3.connect(tmp)
    db.executescript(SCHEMA)
    theme_ids = {}
    for i, p in enumerate(puzzles, 1):
        db.execute("INSERT INTO puzzles VALUES (?, ?, ?, ?, 100, 100, 0)", (i, p["fen"], p["moves"], p["rating"]))
        for t in p["themes"]:
            if t not in theme_ids:
                theme_ids[t] = len(theme_ids) + 1
                db.execute("INSERT INTO themes VALUES (?, ?)", (theme_ids[t], t))
            db.execute("INSERT OR IGNORE INTO puzzle_themes VALUES (?, ?)", (i, theme_ids[t]))
    db.commit()
    db.close()
    tmp.replace(path)

    kinds = {}
    for p in puzzles:
        kinds[p["themes"][0]] = kinds.get(p["themes"][0], 0) + 1
    print(f"{len(puzzles)} puzzles ({', '.join(f'{v} {k}' for k, v in kinds.items())}) -> {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
