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
parser.add_argument('--relative-warmup', action='store_true',
                    help='Measure warmup from the first media sample (for persistent hosts)')
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
        frame_key = 'framesEncoded' if role == 'host' else 'framesDecoded'
        origin = next((s['seconds'] for s in report['samples'] if s.get(frame_key, 0) > 0), 0) if args.relative_warmup else 0
        samples = [s for s in report['samples'] if s['seconds'] >= origin + args.warmup]
        if not samples: continue
        last = samples[-1]
        result = {'samples': len(samples), 'warmupOriginSeconds': origin, 'route': report['mediaRoute'], 'pacing': report.get('pacing', 'upstream'),
                  'playout': report.get('playout'),
                  'preset': report['preset'], 'network': report['networkLabel'], 'receiveDepth': report.get('bridgeReceiveDepth',1), 'bridgeTransport': report.get('bridgeTransport','network')}
        for key in ['videoMbps', 'fps', 'controlRTTMilliseconds', 'sendDelayMilliseconds', 'encodeMilliseconds',
                    'decodeMilliseconds', 'jitterBufferMilliseconds', 'jitterBufferTargetMilliseconds', 'jitterBufferMinimumMilliseconds', 'frameGapP95Milliseconds', 'frameGapMaxMilliseconds']:
            result[key] = metric([s[key] for s in samples if key in s])
        for key in ['callbackMillisecondsP95', 'frameBytesMax', 'frameBytesP95', 'targetMbps']:
            result[key] = metric([s['encoderDetails'][key] for s in samples if key in s.get('encoderDetails', {})])
        result['cumulative'] = {k: last.get(k) for k in ['framesDecoded', 'framesEncoded', 'sourceFrames', 'framesDropped',
                                                       'freezeCount', 'packetsLost', 'packetsReceived', 'packetsSent', 'retransmittedPacketsReceived', 'retransmittedPacketsSent', 'pliCount', 'nackCount', 'probeSent', 'probeReceived', 'probeExpired']}
        result['fpsBelow58Intervals'] = sum(s.get('fps', 0) < 58 for s in samples)
        result['fpsMinimum'] = min(s.get('fps',0) for s in samples)
        result['frameGapMaximumMs'] = max((s.get('frameGapMaxMilliseconds',0) for s in samples),default=0)
        result['observedSeconds'] = samples[-1]['seconds'] - samples[0]['seconds']
        first = samples[0]
        span = result['observedSeconds']
        def counter_rate(key, parent=None):
            before, after = (first.get(parent, {}), last.get(parent, {})) if parent else (first, last)
            a, b = before.get(key), after.get(key)
            return (b - a) / span if span > 0 and a is not None and b is not None and b >= a else None
        result['counterFPS'] = counter_rate('framesEncoded' if role == 'host' else 'framesDecoded')
        result['actualFormat'] = {k: last.get(k) for k in ['width', 'height', 'codec', 'decodedPixelFormat', 'playoutDelayExtensionNegotiated']}
        result['byteRatesMbps'] = {}
        for key, parent in [('rtpPayloadBytes', None), ('rtpHeaderBytes', None), ('retransmittedPayloadBytes', None),
                            ('transportBytesSent', None), ('transportBytesReceived', None),
                            ('sentWireBytes', 'bridge'), ('receivedWireBytes', 'bridge'), ('encodedBytes', 'encoderDetails')]:
            rate = counter_rate(key, parent)
            result['byteRatesMbps'][key] = rate * 8 / 1_000_000 if rate is not None else None
        result['steadyCounterDelta'] = {k: last.get(k, 0) - first.get(k, 0) for k in ['freezeCount', 'packetsLost', 'nackCount', 'pliCount']}
        result['bridge'] = last.get('bridge')
        result['encoderDetails'] = last.get('encoderDetails')
        row[role] = result
    print(json.dumps(row, ensure_ascii=False))
