#!/usr/bin/env python3
"""Collect one bounded interval from a live host's rolling five-sample report.

Does not launch a second encoder, alter the host, or merge across reconnects.
"""
import argparse
import hashlib
import json
from pathlib import Path
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--report', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--duration', type=float, default=55)
parser.add_argument('--label', required=True)
parser.add_argument('--fixture', type=Path, help='Archive the exact source fixture alongside this interval')
args = parser.parse_args()
if not 20 <= args.duration <= 1800:
    parser.error('duration must be 20...1800 seconds')
if args.output.exists():
    parser.error('Output already exists; preserve prior measurements')
initial = json.loads(args.report.read_text())
if not initial.get('samples'):
    parser.error('Host has no samples')
floor = initial['samples'][-1]['seconds']
last = floor
collected = {}
deadline = time.monotonic() + args.duration
modified = args.report.stat().st_mtime_ns
reads = 0
args.output.mkdir(parents=True)
fixture_sha = None
if args.fixture:
    fixture_bytes = args.fixture.read_bytes()
    (args.output/'fixture.html').write_bytes(fixture_bytes)
    fixture_sha = hashlib.sha256(fixture_bytes).hexdigest()
while time.monotonic() < deadline:
    stamp = args.report.stat().st_mtime_ns
    if stamp != modified:
        modified = stamp
        current = json.loads(args.report.read_text())
        rows = current.get('samples', [])
        if rows:
            end = rows[-1]['seconds']
            if end < last:
                raise SystemExit('Session restarted; refusing to combine separate sessions')
            last = end
            for sample in rows:
                if sample['seconds'] > floor:
                    collected[sample['seconds']] = sample
            reads += 1
    time.sleep(.5)
if len(collected) < 10:
    raise SystemExit('Too few fresh samples; check active media session')
output = {**initial, 'samples': [collected[k] for k in sorted(collected)]}
payload = json.dumps(output, ensure_ascii=False, indent=2)+'\n'
(args.output/'host.json').write_text(payload)
(args.output/'collection.json').write_text(json.dumps({
    'label':args.label, 'requestedSeconds':args.duration, 'snapshotReads':reads,
    'samples':len(collected), 'sourceFloorSeconds':floor,
    'scope':'existing persistent host; source-load calibration, not receiver qualification',
    'hostReportSHA256':hashlib.sha256(payload.encode()).hexdigest(),
    'fixtureSHA256':fixture_sha
}, ensure_ascii=False, indent=2)+'\n')
print(json.dumps({'label':args.label,'samples':len(collected),'output':str(args.output)},ensure_ascii=False))
