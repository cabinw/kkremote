#!/usr/bin/env python3
"""Receiver-local decode/scheduling/display submission; never physical presentation or network one-way time."""
import argparse
from collections import Counter, defaultdict
import importlib.util
import json
from pathlib import Path

spec = importlib.util.spec_from_file_location('rtp_analysis', Path(__file__).with_name('analyze-rtp-trace.py'))
rtp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rtp)
distribution, unique_index = rtp.distribution, rtp.unique_index


def select_window(document, seconds, tail_margin=2):
    """Select equal receiver-local windows, excluding stop UI; keep original overflow evidence."""
    if seconds <= 0 or tail_margin < 0:
        raise ValueError('Invalid window duration')
    outputs = [e['uptimeNs'] for e in document['events'] if e['stage'] == 'displayEnqueue']
    if not outputs:
        raise ValueError('No display submission to anchor window')
    end = max(outputs) - int(tail_margin * 1e9)
    start = end - int(seconds * 1e9)
    if min(e['uptimeNs'] for e in document['events']) > start:
        raise ValueError('Requested window is not fully retained')
    result = {**document, 'events': [e for e in document['events'] if start <= e['uptimeNs'] <= end]}
    result['rtp'] = {**document['rtp'], 'frames': [f for f in document['rtp']['frames'] if start <= f['firstPacketNs'] <= end]}
    result['selection'] = {'seconds': seconds, 'tailMarginSeconds': tail_margin, 'startUptimeNs': start, 'endUptimeNs': end,
                           'eventWindowFullyRetained': True, 'boundaryFramesMayLackEarlierStages': True}
    return result


def analyze(document):
    if len({e['sequence'] for e in document['events']}) != len(document['events']):
        raise ValueError('Duplicate event sequence')
    stages = defaultdict(list)
    for event in document['events']:
        stages[event['stage']].append(event)
    indexed = {stage: unique_index(events, 'rtpTimestamp') for stage, events in stages.items()}
    incoming = [f for f in document['rtp']['frames'] if f['direction'] == 'inbound' and f['kind'] == 'primary']
    ingress = unique_index(incoming, 'timestamp') if len({f['ssrc'] for f in incoming}) == 1 else {}
    rows = {}
    for timestamp, submitted in indexed.get('decodeSubmit', {}).items():
        row = {'rtpTimestamp': timestamp, 'frameType': submitted.get('reason'), 'decodeSubmit': submitted}
        for stage in ['decodeVTSubmit', 'decodeVTOutput', 'decodeOutput']:
            event = indexed.get(stage, {}).get(timestamp)
            if event and event.get('frameID') is not None and event.get('frameID') == submitted.get('frameID'):
                row[stage] = event
        if timestamp in ingress:
            row['firstIngress'] = {'uptimeNs': ingress[timestamp]['firstPacketNs']}
            row['lastIngress'] = {'uptimeNs': ingress[timestamp]['lastPacketNs']}
            packet = ingress[timestamp]
            # Only compare kernel frame boundaries when every primary packet has a valid timestamp.
            if packet.get('kernelTimestampPackets') == packet.get('packets', -1) and not packet.get('invalidKernelTimestampPackets'):
                for field, stage in [('firstKernelArrivalNs','firstKernelArrival'), ('lastKernelArrivalNs','lastKernelArrival')]:
                    if field in packet: row[stage] = {'uptimeNs': packet[field]}
                row['kernelToBridgeNsMax'] = packet.get('kernelToBridgeNsMax')
        if 'decodeOutput' in row and timestamp in indexed.get('rendererCallback', {}):
            row['rendererCallback'] = indexed['rendererCallback'][timestamp]
        rows[timestamp] = row

    def duration(row, a, b):
        if a in row and b in row:
            value = (row[b]['uptimeNs'] - row[a]['uptimeNs']) / 1e6
            if value >= 0:
                return value

    pairs = [('firstKernelToBridgeMs', 'firstKernelArrival', 'firstIngress'),
             ('lastKernelToBridgeMs', 'lastKernelArrival', 'lastIngress'),
             ('firstIngressToDecodeSubmitMs', 'firstIngress', 'decodeSubmit'),
             ('lastPrimaryIngressToDecodeSubmitMs', 'lastIngress', 'decodeSubmit'),
             ('decodeCallbackMs', 'decodeSubmit', 'decodeOutput'),
             ('videoToolboxCallbackMs', 'decodeVTSubmit', 'decodeVTOutput'),
             ('decodeOutputToSDKRendererMs', 'decodeOutput', 'rendererCallback')]
    summary = lambda values: {name: distribution([d for row in values if (d := duration(row, a, b)) is not None])
                              for name, a, b in pairs}
    # Mac CLI viewers have an SDK renderer but no application display observer.
    # Keep these separate from the physical-screen / per-view enqueue measurements.
    renderer_events = sorted(indexed.get('rendererCallback', {}).values(), key=lambda e: e['uptimeNs'])
    renderer_gaps = []
    for previous, current in zip(renderer_events, renderer_events[1:]):
        a, b = previous['rtpTimestamp'], current['rtpTimestamp']
        row = {'previousRTP': a, 'rtpTimestamp': b, 'gapMs': (current['uptimeNs'] - previous['uptimeNs']) / 1e6,
               'frameType': rows.get(b, {}).get('frameType')}
        for stage in ['firstKernelArrival', 'lastKernelArrival', 'firstIngress', 'lastIngress', 'decodeSubmit', 'decodeOutput']:
            first, second = rows.get(a, {}).get(stage), rows.get(b, {}).get(stage)
            if first and second: row[stage+'GapMs'] = (second['uptimeNs'] - first['uptimeNs']) / 1e6
        for name, start, end in pairs: row[name] = duration(rows.get(b, {}), start, end)
        renderer_gaps.append(row)
    observers = {}
    for observer in {e['observerID'] for e in document['events'] if 'observerID' in e}:
        events = [e for e in document['events'] if e.get('observerID') == observer]
        views = defaultdict(list)
        for event in events:
            views[event['stage']].append(event)
        display_rows = {}
        for stage, values in views.items():
            for timestamp, event in unique_index(values, 'rtpTimestamp').items():
                display_rows.setdefault(timestamp, {})[stage] = event
        for timestamp, row in display_rows.items():
            if 'decodeOutput' in rows.get(timestamp, {}):
                row['decodeOutput'] = rows[timestamp]['decodeOutput']
            if timestamp in ingress:
                row['firstIngress'] = {'uptimeNs': ingress[timestamp]['firstPacketNs']}
        times = [('decodeOutputToDisplayInputMs', 'decodeOutput', 'displayInput'),
                 ('displayMainQueueMs', 'displayInput', 'displayMainDequeue'),
                 ('displayPreparationMs', 'displayMainDequeue', 'displayEnqueue'),
                 ('firstIngressToDisplayEnqueueMs', 'firstIngress', 'displayEnqueue')]
        enqueued = sorted(views['displayEnqueue'], key=lambda e: e['uptimeNs'])
        gaps = []
        for previous, current in zip(enqueued, enqueued[1:]):
            a, b = previous['rtpTimestamp'], current['rtpTimestamp']
            row = {'previousRTP': a, 'rtpTimestamp': b, 'gapMs': (current['uptimeNs'] - previous['uptimeNs']) / 1e6,
                   'frameType': rows.get(b, {}).get('frameType')}
            for stage in ['firstIngress', 'decodeSubmit', 'decodeOutput']:
                first, second = rows.get(a, {}).get(stage), rows.get(b, {}).get(stage)
                if first and second:
                    row[stage + 'GapMs'] = (second['uptimeNs'] - first['uptimeNs']) / 1e6
            for name, start, end in times:
                row[name] = duration(display_rows[b], start, end)
            gaps.append(row)
        observers[observer] = {'stages': dict(Counter(e['stage'] for e in events)),
            'drops': dict(Counter(e.get('reason', 'unknown') for e in views['displayDrop'])),
            'intervals': {name: distribution([d for row in display_rows.values() if (d := duration(row, a, b)) is not None])
                          for name, a, b in times},
            'enqueueGapMs': distribution([g['gapMs'] for g in gaps]),
            'enqueueGapsOver50Ms': sum(g['gapMs'] > 50 for g in gaps),
            'enqueueGapsOver100Ms': sum(g['gapMs'] > 100 for g in gaps),
            'largestEnqueueGaps': sorted(gaps, key=lambda g: g['gapMs'], reverse=True)[:10]}
    return {'schemaVersion': 1, 'epoch': document['summary']['epoch'], 'selection': document.get('selection'),
        'overwrittenEvents': document['summary']['overwritten'], 'overwrittenRTPFrames': document['rtp']['overwrittenFrames'],
        'stages': dict(Counter(e['stage'] for e in document['events'])),
        'failures': dict(Counter(e.get('reason', 'unknown') for e in stages['decodeFailure'])),
        'unknown': dict(Counter(e.get('reason', 'unknown') for e in stages['decodeUnknown'])),
        'exactMatchedDecoderOutputs': sum('decodeOutput' in r for r in rows.values()),
        'intervals': summary(rows.values()),
        'frameTypes': {kind: summary([r for r in rows.values() if r['frameType'] == kind]) for kind in ['key', 'delta']},
        'sdkRenderer': {'gapMs': distribution([g['gapMs'] for g in renderer_gaps]),
                        'largestGaps': sorted(renderer_gaps, key=lambda g:g['gapMs'], reverse=True)[:10]},
        'observers': observers,
        'limits': ['All intervals use one receiver clock. There is no cross-peer clock subtraction.',
                   'Kernel timestamp is Darwin IP-stack delivery in mach_absolute_time converted to uptime nanoseconds, not outer tunnel/NIC arrival. Missing/partial timestamps are excluded.',
                   'Last primary ingress is not guaranteed complete assembly: RTX is encrypted and arrives separately.',
                   'RTP correlation requires unique timestamps and one ingress primary SSRC. Decode stages require the same exact frame ID.',
                   'Display enqueue means API submission, not photons or verified scanout. SDK renderer and display observers are parallel callbacks.',
                   'Per-view observer IDs isolate bindings. Long gaps can contain missing frames; they do not by themselves locate a stall.']}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('receiver', type=Path)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--last-seconds', type=float)
    parser.add_argument('--tail-margin-seconds', type=float, default=2)
    args = parser.parse_args()
    document = json.loads(args.receiver.read_text())
    if args.last_seconds is not None:
        document = select_window(document, args.last_seconds, args.tail_margin_seconds)
    text = json.dumps(analyze(document), ensure_ascii=False, indent=2) + '\n'
    if args.output:
        args.output.write_text(text)
    else:
        print(text, end='')
