"""Summarize one complete pass of a looping video using handheld presentation receipts."""
import argparse
from itertools import groupby, pairwise
import json
import math


def percentile(values, fraction):
    return sorted(values)[math.ceil(fraction * len(values)) - 1]


def summarize(trace, frame_count, loop):
    start = (loop - 1) * frame_count + 1
    stop = start + frame_count
    rows = []
    complete = False
    for line in trace:
        row = json.loads(line)
        if row["seq"] >= stop:
            complete = True
            break
        if row["seq"] >= start:
            rows.append(row)
    if not complete or len(rows) < 2:
        raise ValueError("Wait for a frame from the next loop before measuring this pass")
    gaps = [(b["display_us"] - a["display_us"]) / 1000 for a, b in pairwise(rows)]
    if min(gaps) <= 0 or any(a["seq"] >= b["seq"] for a, b in pairwise(rows)):
        raise ValueError("Out-of-order or repeated receipt")
    result = dict(displayed=len(rows), source_frames=frame_count,
                  fps=round(1000 * len(gaps) / sum(gaps), 2),
                  gaps_over_100_ms=sum(t > 100 for t in gaps))
    for name, values in [
        ("frame_gap_ms", gaps), ("ack_ms", [r["ack_ms"] for r in rows]),
        ("convert_ms", [r["convert_ms"] for r in rows]),
        ("decode_ms", [r["decode_us"] / 1000 for r in rows])
    ]:
        result[name] = {label: round(percentile(values, q), 2)
                        for label, q in [("median", .5), ("p95", .95), ("max", 1)]}
    if "pixel_signature" in rows[0]:
        runs = [sum(1 for _ in group) for _, group in groupby(rows, key=lambda r: r["pixel_signature"])]
        result["adjacent_matching_pixel_samples"] = len(rows) - len(runs)
        result["longest_identical_run"] = max(runs)
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("trace", type=argparse.FileType())
    parser.add_argument("--frames", type=int, default=1253)
    parser.add_argument("--loop", type=int, default=1)
    args = parser.parse_args()
    if args.frames < 2 or args.loop < 1:
        parser.error("expected a positive loop number and at least two source frames")
    print(json.dumps(summarize(args.trace, args.frames, args.loop), indent=2))
