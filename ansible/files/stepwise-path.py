#!/usr/bin/env python3
"""Print a stepwise upgrade path: latest patch of each minor from the installed
version up to the newest (or MAX) minor in a `helm search repo --versions`
JSON dump, one chart version per line. Skipping minors is never emitted.
Minors absent from the repo are skipped; pre-release versions are filtered.
An empty result means the installed version is already at/above the repo.

usage: CUR=1.2.3 [MAX=1.4] python3 stepwise-path.py <helm-search-json>
"""
import json
import os
import sys


def key(v):
    parts = v.lstrip("v").split(".")
    if len(parts) == 3 and all(p.isdigit() for p in parts):
        return tuple(int(p) for p in parts)
    return None


cur = key(os.environ["CUR"].lstrip("v"))
if cur is None:
    sys.exit(f"CUR '{os.environ['CUR']}' is not an x.y.z version")
max_minor = os.environ.get("MAX", "").strip()
charts = sorted({d["version"] for d in json.load(open(sys.argv[1])) if key(d["version"])}, key=key)
if not charts:
    sys.exit("no stable x.y.z chart versions found in repo output")

cur_minor = cur[:2]
target_minor = tuple(int(x) for x in max_minor.split(".")) if max_minor else key(charts[-1])[:2]
if max_minor and target_minor < cur_minor:
    sys.exit(f"MAX {max_minor} is below installed minor {cur[0]}.{cur[1]}")
if target_minor < cur_minor:
    sys.exit(0)  # repo is behind the installed version — nothing to do

path = []
for minor in sorted({key(v)[:2] for v in charts if cur_minor <= key(v)[:2] <= target_minor}):
    latest = [v for v in charts if key(v)[:2] == minor][-1]
    if key(latest) > cur or minor == cur_minor:
        path.append(latest)

print("\n".join(path))
