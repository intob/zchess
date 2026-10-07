#!/usr/bin/env python3
"""Fill the review report template with a `zchess review` JSON file.

usage: scripts/review-report.py review.json > report.html
"""
import json
import pathlib
import sys

data = json.loads(pathlib.Path(sys.argv[1]).read_text())
template = (pathlib.Path(__file__).parent / "review-report.html").read_text()
title = f"<title>{data['user']} Game Review</title>"
payload = json.dumps(data, separators=(",", ":")).replace("</", "<\\/")
html = template.replace("<title>fingjoey Game Review</title>", title, 1).replace("/*REVIEW_DATA*/", payload, 1)
sys.stdout.write(html)
