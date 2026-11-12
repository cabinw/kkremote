#!/usr/bin/env python3
"""Runs real codec + TLS + media loopback. Never claims this is a cross-device test."""
import argparse
import json
import math
from pathlib import Path
import shutil
import statistics
import subprocess
import uuid

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--host', default='127.0.0.1', help='Self address or this Mac\'s own .sgponte name; NOT a remote host')
parser.add_argument('--route', choices=['fixed-udp-v1', 'fixed-udp-v2', 'direct-ice'], default='fixed-udp-v2')
parser.add_argument('--pacing', choices=['upstream', 'interactive', 'smooth'], default='interactive')
parser.add_argument('--rates', default='20,45,80,120')
parser.add_argument('--duration', type=int, default=40)
parser.add_argument('--resolution', choices=['1280x720', '1920x1080', '2560x1440'], default='2560x1440')
parser.add_argument('--pattern', choices=['grid', 'noise'], default='noise')
args = parser.parse_args()
rates = [int(x) for x in args.rates.split(',')]
if args.duration < 20 or any(x < 1 or x > 120 for x in rates):
    parser.error('duration >= 20 and rates in 1...120 required')
app = root / '.build/DerivedData/Build/Products/Release/KKRemoteLabMac.app/Contents/MacOS/KKRemoteLabMac'
if not app.exists():
    parser.error('Run scripts/build-lab.sh mac-release first')
run_id = uuid.uuid4().hex[:12]
# The signed application stays sandboxed. The parent process copies reports out afterwards.
container = Path.home() / 'Library/Containers/com.cabinw.kkremote.lab.mac/Data/MediaBench' / run_id
container.mkdir(parents=True, mode=0o700)
output = root / '.build/media-bench' / run_id
output.mkdir(parents=True)
def percentile(values, p):
    return sorted(values)[max(0, math.ceil(len(values) * p) - 1)] if values else None
def summary(path):
    samples = json.loads(path.read_text())['samples']
    steady = [s for s in samples if s['seconds'] >= 10]
    def values(key): return [s[key] for s in steady if s.get(key) is not None]
    return {
        'steadySamples': len(steady), 'videoMbpsMean': statistics.mean(values('videoMbps')) if steady else None,
        'videoMbpsP95': percentile(values('videoMbps'), .95), 'fpsMedian': statistics.median(values('fps')) if steady else None,
        'controlRTTP95ms': percentile(values('controlRTTMilliseconds'), .95),
        'encodeMeanP95ms': percentile(values('encodeMilliseconds'), .95),
        'decodeMeanP95ms': percentile(values('decodeMilliseconds'), .95),
        'jitterBufferMeanP95ms': percentile(values('jitterBufferMilliseconds'), .95),
        'sendDelayMeanP95ms': percentile(values('sendDelayMilliseconds'), .95),
        'last': samples[-1] if samples else None,
    }
results = []
for rate in rates:
    host = container / f'{rate}-host.json'
    viewer = container / f'{rate}-viewer.json'
    command = [str(app), '--self-test', '--host', args.host, '--route', args.route, '--duration', str(args.duration),
               '--pacing', args.pacing, '--resolution', args.resolution, '--fps', '60', '--mbps', str(rate), '--pattern', args.pattern,
               '--host-report', str(host), '--report', str(viewer)]
    with (output / f'{rate}.log').open('w') as log:
        completed = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=args.duration + 45)
    for source in [host, viewer]:
        if source.exists(): shutil.copy2(source, output / source.name)
    if completed.returncode:
        raise SystemExit(f'Failed at {rate} Mbps; inspect {output / f"{rate}.log"}')
    result = {'ceilingMbps': rate, 'host': summary(host), 'viewer': summary(viewer)}
    results.append(result)
    print(json.dumps({'ceilingMbps': rate, 'actualMbps': result['viewer']['videoMbpsMean'],
                      'fpsMedian': result['viewer']['fpsMedian'], 'controlRTTP95ms': result['viewer']['controlRTTP95ms']}), flush=True)
report = {'scope': 'single Mac, self-endpoint only; not cross-device Ponte', 'route': args.route,
          'pacing': args.pacing, 'resolution': args.resolution, 'pattern': args.pattern, 'durationSeconds': args.duration,
          'warmupExcludedSeconds': 10, 'results': results}
(output / 'summary.json').write_text(json.dumps(report, indent=2) + '\n')
print(f'Reports: {output}', flush=True)
