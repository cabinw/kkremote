#!/usr/bin/env python3
"""Analyze sender-local frame identity. Never infer cross-host latency or a wire RTP mapping."""
import argparse
from collections import Counter, defaultdict
import json
import math
from pathlib import Path


def distribution(values):
    values = sorted(values)
    if not values:
        return {"count": 0}
    return {"count": len(values), "p50": values[math.ceil(len(values) * .5) - 1],
            "p95": values[math.ceil(len(values) * .95) - 1], "max": values[-1]}


def analyze(document):
    events = document["events"]
    if len({e["sequence"] for e in events}) != len(events):
        raise ValueError("Duplicate event sequence")
    stages = defaultdict(list)
    for event in events:
        stages[event["stage"]].append(event)
    stopped_at = min((e["uptimeNs"] for e in stages["mediaStop"]), default=None)
    active_events = [e for e in events if stopped_at is None or e["uptimeNs"] < stopped_at]
    # Only an explicitly observed wrapper identity can link source and encoder.
    by_frame = defaultdict(lambda: defaultdict(list))
    for event in active_events:
        if event.get("frameID") is not None:
            by_frame[event["frameID"]][event["stage"]].append(event)
    rows = []
    ambiguous = 0
    for frame_id, frame in by_frame.items():
        if any(len(frame.get(stage, [])) > 1 for stage in ["capture", "sourceSubmit", "encodeSubmit", "encodeOutput"]):
            ambiguous += 1
            continue
        row = {"frameID": frame_id}
        for stage in ["capture", "sourceSubmit", "encodeSubmit", "encodeOutput"]:
            if frame.get(stage):
                row[stage] = frame[stage][0]
        if "encodeSubmit" in row and row["encodeSubmit"].get("reason") != "exact_wrapper_identity":
            continue
        rows.append(row)

    def interval(row, begin, end):
        if begin not in row or end not in row:
            return None
        value = (row[end]["uptimeNs"] - row[begin]["uptimeNs"]) / 1e6
        return value if value >= 0 else None

    durations = {}
    for name, begin, end in [("captureCallbackToSourceMs", "capture", "sourceSubmit"),
                             ("sourceToEncoderMs", "sourceSubmit", "encodeSubmit"),
                             ("encoderCallbackMs", "encodeSubmit", "encodeOutput"),
                             ("sourceToEncodedMs", "sourceSubmit", "encodeOutput")]:
        durations[name] = distribution([value for row in rows if (value := interval(row, begin, end)) is not None])
    output_rows = sorted([r for r in rows if "encodeOutput" in r], key=lambda r: r["encodeOutput"]["uptimeNs"])
    gaps = []
    for previous, current in zip(output_rows, output_rows[1:]):
        gap = {"previousFrameID": previous["frameID"], "frameID": current["frameID"]}
        for stage in ["sourceSubmit", "encodeSubmit", "encodeOutput"]:
            if stage in previous and stage in current:
                gap[stage + "GapMs"] = (current[stage]["uptimeNs"] - previous[stage]["uptimeNs"]) / 1e6
        gap["sourceToEncoderMs"] = interval(current, "sourceSubmit", "encodeSubmit")
        gap["encoderCallbackMs"] = interval(current, "encodeSubmit", "encodeOutput")
        gaps.append(gap)
    newest = max((e["uptimeNs"] for e in active_events), default=0)
    old_unmatched_source = sum("sourceSubmit" in r and "encodeSubmit" not in r
                               and newest - r["sourceSubmit"]["uptimeNs"] >= 2e9 for r in rows)
    return {
        "schemaVersion": 1, "trace": document["summary"], "stageCounts": dict(Counter(e["stage"] for e in events)),
        "reasonCounts": dict(Counter(e["stage"] + ":" + e["reason"] for e in events if "reason" in e)),
        "ambiguousFrameIdentities": ambiguous,
        "shutdownBoundaryRecorded": stopped_at is not None,
        "eventsAtOrAfterStop": len(events) - len(active_events),
        "encoderInputsWithoutSourceIdentity": sum("frameID" not in e for e in stages["encodeSubmit"]),
        "sourceWithoutEncoderAfterTwoSecondsUnknown": old_unmatched_source,
        "intervals": durations,
        "encodedCallbackGapsMs": distribution([g["encodeOutputGapMs"] for g in gaps]),
        "largestEncodedCallbackGaps": sorted(gaps, key=lambda g: g["encodeOutputGapMs"], reverse=True)[:10],
        "limits": ["Only retained events; overwritten history and unmatched tail are not classified as drops.",
                   "Exact RTC wrapper identity only; changed wrappers and missing observations remain unknown.",
                   "Source without encoder can reflect adaptation or another unobserved path; not proof of VT or network loss.",
                   "Sender-local only. No packet/receiver/display timestamps or physical end-to-end measurement.",
                   "Gap rows show observations, not a unique causal attribution; RTP timestamps here are pre-packetization."]}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("trace", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    result = json.dumps(analyze(json.loads(args.trace.read_text())), ensure_ascii=False, indent=2) + "\n"
    if args.output:
        args.output.write_text(result)
    else:
        print(result, end="")
