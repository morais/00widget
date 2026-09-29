#!/usr/bin/env python3
"""Look and Pinch target audit for hzos panels on the Spatial Simulator.

Lists every element the system treats as actionable (the same semantics
Look and Pinch's UI understanding reads), with its label and size in dp,
and flags targets under 48dp and targets that overlap.

    scripts/lookpinch-audit.py [-d DEVICE] WIDTH_DP [WIDTH_DP ...]

One WIDTH_DP per app window, in dump order (topmost first). A window's dp
width is in `metavr shell dumpsys activity activities` ("w480dp h700dp");
the defaults are dashboard 1280, card detail 1024, Settings 480. The CLI
reports screen pixels, and each window is composited at its own scale, so
sizes are the window's on-screen width over its dp width.

A target that ends on its window's top or bottom edge is cut off (by
the screen or by scrolling) and is listed but not judged: scroll it into
view and run again.
"""
import argparse
import itertools
import json
import subprocess
import sys

MIN_DP = 48


def label(node):
    for key in ("content_desc", "text"):
        if node.get(key):
            return node[key]
    for child in node.get("children", []):
        found = label(child)
        if found:
            return found
    return "?"


def targets(node, out):
    if node.get("clickable") or node.get("checkable"):
        out.append((label(node), node["bounds"]))
    for child in node.get("children", []):
        targets(child, out)
    return out


def overlaps(a, b):
    return min(a[2], b[2]) - max(a[0], b[0]) > 1 and min(a[3], b[3]) - max(a[1], b[1]) > 1


def contains(outer, inner):
    return all(inner[i] >= outer[i] for i in (0, 1)) and all(inner[i] <= outer[i] for i in (2, 3))


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("-d", "--device", default=None)
    parser.add_argument("widths", nargs="+", type=float, metavar="WIDTH_DP")
    args = parser.parse_args()

    cmd = ["metavr"] + (["-d", args.device] if args.device else []) + ["ui", "dump", "--json"]
    dump = json.loads(subprocess.run(cmd, check=True, capture_output=True, text=True).stdout)
    windows = dump["elements"]
    if len(args.widths) != len(windows):
        sys.exit(f"{len(windows)} windows in the dump, {len(args.widths)} widths given")

    problems = 0
    for index, (root, width_dp) in enumerate(zip(windows, args.widths)):
        scale = (root["bounds"][2] - root["bounds"][0]) / width_dp
        found = targets(root, [])
        print(f"window {index}: {width_dp:.0f}dp wide, {scale:.2f} px/dp, {len(found)} targets")
        edge = (root["bounds"][1], root["bounds"][3])
        for name, b in found:
            w, h = (b[2] - b[0]) / scale, (b[3] - b[1]) / scale
            if b[1] <= edge[0] or b[3] >= edge[1]:
                note = "  (cut off at the window edge, not judged)"
            # Half a dp of slack: bounds are whole screen pixels.
            elif min(w, h) < MIN_DP - 0.5:
                problems += 1
                note = "  <-- under 48dp"
            else:
                note = ""
            print(f"  {w:6.0f} x {h:4.0f} dp  {name[:48]}{note}")
        for (na, a), (nb, b) in itertools.combinations(found, 2):
            if overlaps(a, b) and not contains(a, b) and not contains(b, a):
                problems += 1
                print(f"  OVERLAP: {na[:30]} / {nb[:30]}")
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
