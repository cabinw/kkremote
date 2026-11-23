#!/usr/bin/env python3
"""Repeatable, sequential local playout A/B tests, including controlled RTP loss.

This verifies compatibility and recovery, not cellular or cross-device latency.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import uuid

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--app', type=Path, default=Path('.build/DerivedData/Build/Products/Release/KKRemoteLabMac.app'))
parser.add_argument('--duration', type=int, default=45)
parser.add_argument('--window-id', type=int)
parser.add_argument('--hdr', action='store_true')
parser.add_argument('--include-loss', action='store_true')
parser.add_argument('--modes', nargs='+', choices=['adaptive', 'realtime'],
                    default=['adaptive', 'realtime'])
parser.add_argument('--port', type=int, default=46990)
parser.add_argument('--mbps', type=int, default=20)
args = parser.parse_args()
if not 20 <= args.duration <= 600 or not 1024 <= args.port <= 65534 or not 1 <= args.mbps <= 120:
    parser.error('duration 20...600, port 1024...65534, Mbps 1...120 required')
root = Path(__file__).resolve().parent.parent
binary = args.app.resolve() / 'Contents/MacOS/KKRemoteLabMac'
if not binary.is_file():
    parser.error('Build a signed Release Mac app first')
run = uuid.uuid4().hex[:12]
output = root / '.build/playout-bench' / run
output.mkdir(parents=True)
container = Path.home() / 'Library/Containers/com.cabinw.kkremote.lab.mac/Data/PlayoutBench' / run
container.mkdir(parents=True, mode=0o700)
manifest = {'scope': 'single Mac loopback, not cross-device or cellular',
            'binarySHA256': hashlib.sha256(binary.read_bytes()).hexdigest(),
            'durationSeconds': args.duration, 'width': 2560, 'height': 1440, 'fps': 60,
            'ceilingMbps': args.mbps, 'hdr': args.hdr,
            'videoSource': 'window' if args.window_id else 'synthetic', 'runs': []}
for loss in ([False, True] if args.include_loss else [False]):
    for mode in dict.fromkeys(args.modes):
        name = mode + ('-loss' if loss else '-clean')
        destination = output / name
        destination.mkdir()
        reports = {role: container / f'{name}-{role}.json' for role in ['host', 'viewer']}
        command = [str(binary), '--self-test', '--host', '127.0.0.1', '--route', 'fixed-udp-v2',
                   '--bridge-transport', 'socket', '--pacing', 'interactive', '--playout', mode,
                   '--port', str(args.port), '--media-port', str(args.port + 1),
                   '--resolution', '2560x1440', '--fps', '60', '--mbps', str(args.mbps),
                   '--pattern', 'desktop', '--duration', str(args.duration),
                   '--report', str(reports['viewer']), '--host-report', str(reports['host'])]
        if args.hdr:
            command.append('--hdr')
        if loss:
            command.append('--simulate-loss')
        if args.window_id:
            command.extend(['--window-id', str(args.window_id)])
        with (destination / 'run.log').open('w') as log:
            completed = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=args.duration + 45)
        for role, source in reports.items():
            if source.exists():
                (destination / f'{role}.json').write_bytes(source.read_bytes())
        reports_valid = all(source.exists() and json.loads(source.read_text()).get('samples') for source in reports.values())
        manifest['runs'].append({'name': name, 'exitCode': completed.returncode, 'reportsPresent': bool(reports_valid)})
        (output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
        print(json.dumps({'run': name, 'exitCode': completed.returncode, 'directory': str(destination)}), flush=True)
        if completed.returncode or not reports_valid:
            raise SystemExit(1)
print(f'Reports: {output}', flush=True)
