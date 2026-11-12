#!/usr/bin/env python3
"""Summarize existing reports without conflating control RTT and video latency."""
import argparse
import json
import math
from pathlib import Path
import statistics

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('directories', nargs='+', type=Path)
parser.add_argument('--warmup', type=float, default=10)
args = parser.parse_args()
def metric(values):
    return {'mean': statistics.mean(values), 'p95': sorted(values)[math.ceil(len(values) * .95) - 1]} if values else None
for directory in args.directories:
    row = {'run': directory.name, 'warmupSeconds': args.warmup}
    for role in ['host', 'viewer']:
        path = directory / (role + '.json')
        if not path.exists():
            path = directory / (role.replace('viewer', 'receiver') + '.json')
        if not path.exists(): continue
        report = json.loads(path.read_text())
        samples = [s for s in report['samples'] if s['seconds'] >= args.warmup]
        if not samples: continue
        last = samples[-1]
        result = {'samples': len(samples), 'route': report['mediaRoute'], 'pacing': report.get('pacing', 'upstream'),
                  'preset': report['preset'], 'network': report['networkLabel']}
        for key in ['videoMbps', 'fps', 'controlRTTMilliseconds', 'sendDelayMilliseconds', 'encodeMilliseconds',
                    'decodeMilliseconds', 'jitterBufferMilliseconds']:
            result[key] = metric([s[key] for s in samples if key in s])
        for key in ['callbackMillisecondsP95', 'frameBytesMax', 'frameBytesP95', 'targetMbps']:
            result[key] = metric([s['encoderDetails'][key] for s in samples if key in s.get('encoderDetails', {})])
        result['cumulative'] = {k: last.get(k) for k in ['framesDecoded', 'framesEncoded', 'sourceFrames', 'framesDropped',
                                                       'freezeCount', 'packetsLost', 'nackCount', 'probeSent', 'probeReceived', 'probeExpired']}
        result['bridge'] = last.get('bridge')
        result['encoderDetails'] = last.get('encoderDetails')
        row[role] = result
    print(json.dumps(row, ensure_ascii=False))
