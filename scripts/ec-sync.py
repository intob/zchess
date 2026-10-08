#!/usr/bin/env python3
"""En Croissant bridge: fetch new Chess.com games, review them with zchess,
and write one annotated PGN per game into En Croissant's Files folder
(~/Documents/EnCroissant), where they show up in the Files tab.

Each game gets evaluations on every move, ?!/?/?? marks, the better line as a
variation, a plain-language label per mistake and a summary comment. Games
already reviewed are remembered in <out>/.reviewed and skipped next time.
The mistakes also become a puzzle database (scripts/ec-puzzles.py).

usage: scripts/ec-sync.py [--user fingjoey] [--months 2] [--threads N]
                          [--nodes 300000] [--out ~/Documents/EnCroissant/zchess] [--all]
"""
import argparse
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
UA = {"User-Agent": "zchess-ec-bridge"}


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
    outcome = "draw" if res == "1/2-1/2" else "win" if res == ("1-0" if user_white else "0-1") else "loss"
    date = header(game, "Date").replace(".", "-")
    name = f"{date} vs {opp} ({outcome})"
    return re.sub(r'[\\/:*?"<>|]', "_", name)


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


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--user", default="fingjoey")
    ap.add_argument("--months", type=int, default=2, help="archive months to check")
    ap.add_argument("--threads", type=int, default=os.cpu_count() or 4)
    ap.add_argument("--nodes", type=int, default=300_000)
    ap.add_argument("--out", default="~/Documents/EnCroissant/zchess")
    ap.add_argument("--all", action="store_true", help="re-review games already done")
    args = ap.parse_args()

    out = pathlib.Path(args.out).expanduser()
    out.mkdir(parents=True, exist_ok=True)
    seen_file = out / ".reviewed"
    seen = set(seen_file.read_text().split()) if seen_file.exists() else set()

    archives = json.loads(get(f"https://api.chess.com/pub/player/{args.user}/games/archives"))["archives"]
    games = []
    for url in archives[-args.months:]:
        games += split_games(get(url + "/pgn"))
    new = [g for g in games if args.all or header(g, "Link") not in seen]
    print(f"{len(games)} games in the last {args.months} months, {len(new)} new")
    if not new:
        return 0

    zchess = ROOT / "zig-out" / "bin" / "zchess"
    with tempfile.TemporaryDirectory() as tmp:
        src, annotated, report = (pathlib.Path(tmp) / n for n in ("new.pgn", "annotated.pgn", "review.json"))
        src.write_text("\n".join(new))
        subprocess.run([str(zchess), "review", "--user", args.user, "--json", str(report), "--pgn", str(annotated),
                        "--nodes", str(args.nodes), "--threads", str(args.threads), str(src)], check=True)
        written = 0
        for game in split_games(annotated.read_text()):
            name = file_name(game, args.user)
            path = out / f"{name}.pgn"
            n = 2
            while path.exists() and header(path.read_text(), "Link") != header(game, "Link"):
                path = out / f"{name} {n}.pgn"
                n += 1
            path.write_text(game)
            written += 1

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
    # Turn the mistakes into puzzles (En Croissant's Puzzles tab).
    subprocess.run([sys.executable, str(ROOT / "scripts" / "ec-puzzles.py"), str(cumulative)], check=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
