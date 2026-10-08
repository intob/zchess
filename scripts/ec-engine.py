#!/usr/bin/env python3
"""Keep zchess's entry in En Croissant up to date after a build (run by `zig build`).

Finds the engine in En Croissant's engines.json whose path is the installed
binary and updates it:
  - name     "zchess"
  - version  embedded net and git commit, e.g. "gen6w c649475" (+"-dirty")
  - elo      the net's rating from nets/ratings.txt, if listed
  - image    zig-out/zchess.png, if it exists
  - settings values kept for options the binary still has (spins clamped to
             their new range); settings for options it no longer has dropped

Does nothing (and never fails the build) if En Croissant isn't installed or
no entry points at this binary. En Croissant reads engines.json at startup, so
restart it to see the changes.

usage: scripts/ec-engine.py <binary to query> <installed path> [net path]
"""
import json
import os
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
ENGINES = pathlib.Path.home() / "Library/Application Support/org.encroissant.app/engines/engines.json"


def uci_options(binary: str) -> dict:
    """name -> {"type", "min", "max"} from the engine's `uci` output."""
    out = subprocess.run([binary], input="uci\nquit\n", capture_output=True, text=True, timeout=10).stdout
    opts = {}
    for line in out.splitlines():
        if not line.startswith("option name "):
            continue
        words = line[len("option name "):].split(" ")
        i = words.index("type")
        o = {"type": words[i + 1]}
        for key in ("min", "max"):
            if key in words[i:]:
                o[key] = int(words[words.index(key, i) + 1])
        opts[" ".join(words[:i])] = o
    return opts


def git_version() -> str:
    def git(*args):
        return subprocess.run(["git", "-C", str(ROOT), *args], capture_output=True, text=True).stdout.strip()

    rev = git("rev-parse", "--short", "HEAD")
    return rev + ("-dirty" if git("status", "--porcelain", "--untracked-files=no") else "")


def rating(net: str) -> int | None:
    path = ROOT / "nets/ratings.txt"
    if not net or not path.exists():
        return None
    for line in path.read_text().splitlines():
        parts = line.split("#")[0].split()
        if len(parts) == 2 and parts[0] == net:
            return int(parts[1])
    return None


def main() -> None:
    binary, installed = sys.argv[1], os.path.realpath(sys.argv[2])
    net_path = sys.argv[3] if len(sys.argv) > 3 else ""
    if not ENGINES.exists():
        return
    engines = json.loads(ENGINES.read_text())
    mine = [e for e in engines if e.get("path") and os.path.realpath(e["path"]) == installed]
    if not mine:
        return

    net = pathlib.Path(net_path).stem if net_path else "hce"
    opts = uci_options(binary)
    elo = rating(net)
    image = pathlib.Path(installed).parent.parent / "zchess.png"
    for e in mine:
        e["name"] = "zchess"
        e["version"] = f"{net} {git_version()}"
        if elo is not None:
            e["elo"] = elo
        if image.exists():
            e["image"] = str(image)
        settings = []
        for s in e.get("settings", []):
            o = opts.get(s.get("name"))
            if o is None:
                continue
            if o["type"] == "spin" and isinstance(s.get("value"), (int, float)):
                s["value"] = max(o.get("min", s["value"]), min(o.get("max", s["value"]), s["value"]))
            settings.append(s)
        e["settings"] = settings

    text = json.dumps(engines, indent=4)
    if text == ENGINES.read_text():
        return
    # Atomic replace, so En Croissant never reads a half-written file.
    fd, tmp = tempfile.mkstemp(dir=ENGINES.parent, prefix=".engines-")
    with os.fdopen(fd, "w") as f:
        f.write(text)
    os.replace(tmp, ENGINES)
    print(f"ec-engine: En Croissant entry updated: zchess {mine[0]['version']}", file=sys.stderr)


if __name__ == "__main__":
    try:
        main()
    except Exception as err:  # never break the build over En Croissant
        print(f"ec-engine: skipped ({err})", file=sys.stderr)
