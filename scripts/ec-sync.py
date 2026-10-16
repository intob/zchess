#!/usr/bin/env python3
"""En Croissant bridge: fetch new Chess.com games, review them with zchess,
and write one annotated PGN per game into En Croissant's Files folder
(~/Documents/EnCroissant), where they show up in the Files tab.

Your games against zchess count too: with Coach on, the engine records each
game it plays in ~/zchess-games (UCI option GameRecord). Finished ones (the
board decided the result, or no move for 30 minutes: a resignation or a flag
never reaches the engine) are reviewed the same way and also added to the
"zchess games" database in En Croissant's Databases tab (tools/ec-db, built on
first use), where you can open them and analyse them with any engine.

Each game gets evaluations on every move, ?!/?/?? marks, the better line as a
variation, a plain-language label per mistake (naming the tactic: fork, pin,
discovered attack, ...) and a summary comment. Games already reviewed are
remembered in <out>/.reviewed and skipped next time.

Then, from all the games reviewed so far:
  - your #1 leak goes into <out>/.focus, which the live coach reads (it names it
    at the start of each game and when you repeat it; scripts/leaks.py);
  - the mistakes become a puzzle database (scripts/ec-puzzles.py);
  - the report page with spaced-repetition puzzles and opening drills is
    rebuilt: data/review/<user>-report.html (scripts/review-report.py).

usage: scripts/ec-sync.py [--user fingjoey] [--months 2] [--threads N]
                          [--nodes 300000] [--out ~/Documents/EnCroissant/zchess]
                          [--played ~/zchess-games] [--all]
"""
import argparse
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import time
import urllib.request

import leaks

ROOT = pathlib.Path(__file__).resolve().parent.parent
UA = {"User-Agent": "zchess-ec-bridge"}
DB_DIR = pathlib.Path.home() / "Library/Application Support/org.encroissant.app/db"
PLAYED_DB = "zchess games"
# A recorded game with no result and no move for this long is over.
IDLE_SECONDS = 30 * 60
# Shorter recorded games are aborted starts, not games.
MIN_PLIES = 6


def get(url: str) -> str:
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read().decode()


def split_games(pgn: str) -> list[str]:
    """Split a multi-game PGN into games (a new game starts at [Event after movetext)."""
    games, cur, seen_moves = [], [], False
    for line in pgn.splitlines():
        if line.startswith("[Event ") and seen_moves:
            games.append("\n".join(cur).strip() + "\n")
            cur, seen_moves = [], False
        if line.strip() and not line.startswith("["):
            seen_moves = True
        cur.append(line)
    if seen_moves:
        games.append("\n".join(cur).strip() + "\n")
    return games


def header(game: str, key: str) -> str:
    m = re.search(r'^\[%s "([^"]*)"\]' % re.escape(key), game, re.M)
    return m.group(1) if m else ""


def file_name(game: str, user: str) -> str:
    white, black = header(game, "White"), header(game, "Black")
    user_white = white.lower() == user.lower()
    opp = black if user_white else white
    res = header(game, "Result")
    outcome = ("draw" if res == "1/2-1/2" else "no result" if res == "*"
               else "win" if res == ("1-0" if user_white else "0-1") else "loss")
    date = header(game, "Date").replace(".", "-")
    name = f"{date} vs {opp} ({outcome})"
    return re.sub(r'[\\/:*?"<>|]', "_", name)


def plies(game: str) -> int:
    """Moves in a game's movetext (outside comments and variations)."""
    text = re.sub(r"\{[^}]*\}", " ", game.split("\n\n", 1)[-1])
    while re.search(r"\([^()]*\)", text):
        text = re.sub(r"\([^()]*\)", " ", text)
    return sum(1 for tok in text.split() if re.match(r"^[a-hKQRBNO]", tok))


def played_games(folder: pathlib.Path, user: str) -> list[str]:
    """Finished games recorded by zchess (see the docstring), as PGN, with the
    player's name filled in when the engine didn't know it."""
    games = []
    now = time.time()
    for path in sorted(folder.glob("*.pgn")):
        game = path.read_text()
        if header(game, "Result") == "*" and now - path.stat().st_mtime < IDLE_SECONDS:
            continue  # maybe still being played
        if plies(game) < MIN_PLIES:
            continue
        games.append(re.sub(r'^\[(White|Black) "You"\]$', rf'[\1 "{user}"]', game, flags=re.M))
    return games


def ec_db() -> pathlib.Path:
    """tools/ec-db, built if needed (cargo)."""
    crate = ROOT / "tools" / "ec-db"
    binary = crate / "target" / "release" / "ec-db"
    sources = [crate / "Cargo.toml", *(crate / "src").iterdir()]
    if not binary.exists() or binary.stat().st_mtime < max(p.stat().st_mtime for p in sources):
        subprocess.run(["cargo", "build", "--release", "--quiet", "--manifest-path", str(crate / "Cargo.toml")], check=True)
    return binary


def recompute_totals(r: dict) -> None:
    """Top-level summary fields from the per-game data (after merging batches)."""
    gs = r["games"]
    r["games_analysed"] = len(gs)
    for key, res in (("wins", "win"), ("draws", "draw"), ("losses", "loss")):
        r[key] = sum(g["result"] == res for g in gs)
    r["avg_accuracy"] = sum(g["accuracy"] for g in gs) / max(len(gs), 1)
    r["totals"] = {k: sum(g["counts"][k] for g in gs) for k in ("inaccuracy", "mistake", "blunder")}
    kinds = {k: 0 for k in r.get("kinds", {})}
    for g in gs:
        for f in g["flags"]:
            if f["cls"] != "inaccuracy":
                kinds[f["kind"]] = kinds.get(f["kind"], 0) + 1
    r["kinds"] = kinds
    lessons = {k: 0 for k in r.get("lessons", {})}
    for g in gs:
        for f in g["flags"]:
            if f["cls"] != "inaccuracy":
                lesson = leaks.lesson_of(f)
                lessons[lesson] = lessons.get(lesson, 0) + 1
    r["lessons"] = lessons


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--user", default="fingjoey")
    ap.add_argument("--months", type=int, default=2, help="archive months to check")
    ap.add_argument("--threads", type=int, default=os.cpu_count() or 4)
    ap.add_argument("--nodes", type=int, default=300_000)
    ap.add_argument("--out", default="~/Documents/EnCroissant/zchess")
    ap.add_argument("--played", default="~/zchess-games", help="games recorded by zchess (GameRecord)")
    ap.add_argument("--all", action="store_true", help="re-review games already done")
    args = ap.parse_args()

    out = pathlib.Path(args.out).expanduser()
    out.mkdir(parents=True, exist_ok=True)
    seen_file = out / ".reviewed"
    seen = set(seen_file.read_text().split()) if seen_file.exists() else set()

    games = []
    try:
        archives = json.loads(get(f"https://api.chess.com/pub/player/{args.user}/games/archives"))["archives"]
        for url in archives[-args.months:]:
            games += split_games(get(url + "/pgn"))
    except OSError as err:
        print(f"can't fetch Chess.com games: {err}", file=sys.stderr)
    new = [g for g in games if args.all or header(g, "Link") not in seen]
    print(f"{len(games)} Chess.com games in the last {args.months} months, {len(new)} new")
    played_dir = pathlib.Path(args.played).expanduser()
    played = [g for g in played_games(played_dir, args.user) if args.all or header(g, "Link") not in seen]
    print(f"{len(played)} new finished games against zchess in {played_dir}")
    new += played
    if not new:
        return 0
    played_links = {header(g, "Link") for g in played}

    zchess = ROOT / "zig-out" / "bin" / "zchess"
    with tempfile.TemporaryDirectory() as tmp:
        src, annotated, report = (pathlib.Path(tmp) / n for n in ("new.pgn", "annotated.pgn", "review.json"))
        src.write_text("\n".join(new))
        subprocess.run([str(zchess), "review", "--user", args.user, "--json", str(report), "--pgn", str(annotated),
                        "--nodes", str(args.nodes), "--threads", str(args.threads), str(src)], check=True)
        written = 0
        to_db = []
        for game in split_games(annotated.read_text()):
            if header(game, "Link") in played_links:
                to_db.append(game)
            name = file_name(game, args.user)
            path = out / f"{name}.pgn"
            n = 2
            while path.exists() and header(path.read_text(), "Link") != header(game, "Link"):
                path = out / f"{name} {n}.pgn"
                n += 1
            path.write_text(game)
            written += 1
        if to_db:
            # Games already in the database (a re-review with --all) aren't added twice.
            db = DB_DIR / f"{PLAYED_DB}.db3"
            if db.exists():
                import sqlite3
                with sqlite3.connect(db) as conn:
                    have = {tuple(r) for r in conn.execute("SELECT Date, UTCTime FROM Games")}
                to_db = [g for g in to_db if (header(g, "UTCDate"), header(g, "UTCTime")) not in have]
        if to_db:
            batch = pathlib.Path(tmp) / "played.pgn"
            batch.write_text("\n".join(to_db))
            DB_DIR.mkdir(parents=True, exist_ok=True)
            subprocess.run([str(ec_db()), str(DB_DIR / f"{PLAYED_DB}.db3"), "--title", PLAYED_DB,
                            "--description", f"{args.user}'s games against zchess, reviewed by zchess", str(batch)],
                           check=True, stdout=subprocess.DEVNULL)
            print(f'added {len(to_db)} games to the "{PLAYED_DB}" database (En Croissant: Databases)')

        # Keep a cumulative review JSON for the report page.
        cumulative = ROOT / "data" / "review" / f"{args.user}-all.json"
        cumulative.parent.mkdir(parents=True, exist_ok=True)
        fresh = json.loads(report.read_text())
        if cumulative.exists():
            old = json.loads(cumulative.read_text())
            links = {g.get("link") for g in fresh["games"]}
            fresh["games"] += [g for g in old["games"] if g.get("link") not in links]
        recompute_totals(fresh)
        cumulative.write_text(json.dumps(fresh))

    seen |= {header(g, "Link") for g in new}
    seen_file.write_text("\n".join(sorted(seen)) + "\n")
    print(f"wrote {written} annotated games to {out} (open them from En Croissant's Files tab)")
    # Your #1 leak, for the live coach.
    review = json.loads(cumulative.read_text())
    top = leaks.top_leak(leaks.leaks(review))
    if top:
        leaks.write_focus(out / ".focus", top)
        print(f"#1 leak: {leaks.describe(top)}\n   habit: {top['habit']}")
    # Turn the mistakes into puzzles (En Croissant's Puzzles tab), and rebuild the report.
    subprocess.run([sys.executable, str(ROOT / "scripts" / "ec-puzzles.py"), str(cumulative)], check=True)
    report = cumulative.with_name(f"{args.user}-report.html")
    with open(report, "w") as f:
        subprocess.run([sys.executable, str(ROOT / "scripts" / "review-report.py"), str(cumulative)], stdout=f, check=True)
    print(f"report with puzzles and opening drills: {report}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
