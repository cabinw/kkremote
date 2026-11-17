#!/usr/bin/env python3
"""Sequential trace off/on/on/off loopbacks. Uses random local ports, never the phone's live host."""
import argparse
import importlib.util
import json
from pathlib import Path
import resource
import statistics
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--app", type=Path, required=True)
parser.add_argument("--directory", type=Path, required=True, help="Writable by the sandboxed Mac app")
parser.add_argument("--duration", type=int, default=35)
parser.add_argument("--window-id", type=int)
args = parser.parse_args()
args.directory.mkdir(parents=True, exist_ok=True)
spec = importlib.util.spec_from_file_location("trace_analysis", Path(__file__).with_name("analyze-frame-trace.py"))
analysis = importlib.util.module_from_spec(spec)
spec.loader.exec_module(analysis)


def summarize(path):
    report = json.loads(path.read_text())
    samples = [s for s in report["samples"] if s["seconds"] >= 5]
    if len(samples) < 5:
        raise RuntimeError("Insufficient steady-state samples")
    def mean(key):
        values = [s[key] for s in samples if s.get(key) is not None]
        return statistics.mean(values) if values else None
    return {"samples": len(samples), "fpsMean": mean("fps"), "fpsMin": min(s["fps"] for s in samples),
            "videoMbpsMean": mean("videoMbps"), "encodeMsMean": mean("encodeMilliseconds"),
            "decodeMsMean": mean("decodeMilliseconds"), "receiveBufferMsMean": mean("jitterBufferMilliseconds"),
            "sendDelayMsMean": mean("sendDelayMilliseconds"),
            "frameGapMaxMs": max((s.get("frameGapMaxMilliseconds", 0) for s in samples), default=0),
            "last": {k: samples[-1].get(k) for k in ["framesEncoded", "framesDecoded", "framesDropped", "freezeCount", "packetsLost", "encoderDetails", "captureDetails"]}}


cases = [(f"{source}-{index}-{'on' if enabled else 'off'}", source, enabled)
         for source in ["hdr", "desktop"] for index, enabled in enumerate([False, True, True, False], 1)]
if args.window_id:
    cases.append(("hdr-window-on", "window", True))
cases.append(("noise-on", "noise", True))
results = []
for name, source, enabled in cases:
    folder = args.directory / name
    folder.mkdir(exist_ok=False)
    command = [str(args.app.resolve()), "--self-test", "--duration", str(args.duration), "--resolution", "2560x1440",
               "--fps", "60", "--mbps", "20", "--route", "fixed-udp-v2", "--bridge-transport", "socket",
               "--playout", "realtime", "--report", str(folder / "viewer.json"), "--host-report", str(folder / "host.json")]
    if source in ["hdr", "window"]:
        command += ["--hdr"]
    else:
        command += ["--pattern", source]
    if source == "window":
        command += ["--window-id", str(args.window_id)]
    if enabled:
        command += ["--frame-trace-dir", str(folder)]
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    start = time.monotonic()
    with (folder / "run.log").open("w") as log:
        process = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=args.duration + 40)
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    if process.returncode:
        raise RuntimeError(f"{name} failed; inspect its run.log")
    result = {"case": name, "traceEnabled": enabled, "source": source, "scope": "single-Mac loopback; not Ponte",
              "wallSeconds": time.monotonic() - start,
              "processCPUSeconds": after.ru_utime + after.ru_stime - before.ru_utime - before.ru_stime,
              "host": summarize(folder / "host.json"), "viewer": summarize(folder / "viewer.json")}
    if enabled:
        traces = list(folder.glob("sender-*.json"))
        if len(traces) != 1:
            raise RuntimeError("Expected exactly one successfully exported sender trace")
        result["traceAnalysis"] = analysis.analyze(json.loads(traces[0].read_text()))
    results.append(result)
    (args.directory / "summary.json").write_text(json.dumps(results, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"case": name, "fps": result["viewer"]["fpsMean"], "Mbps": result["viewer"]["videoMbpsMean"],
                      "cpuSeconds": result["processCPUSeconds"], "unknownSourceIdentity": result.get("traceAnalysis", {}).get("encoderInputsWithoutSourceIdentity")}), flush=True)
