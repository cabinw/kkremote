#!/usr/bin/env python3
"""Join encoded frames to SRTP headers via exact absolute-capture-time anchors, never timing proximity."""
import argparse
from collections import Counter, defaultdict
import importlib.util
import json
from pathlib import Path

spec = importlib.util.spec_from_file_location("frame_analysis", Path(__file__).with_name("analyze-frame-trace.py"))
frames = importlib.util.module_from_spec(spec)
spec.loader.exec_module(frames)
distribution = frames.distribution
MASK = 2**32 - 1


def unique_index(events, field):
    result = defaultdict(list)
    for event in events:
        if field in event:
            result[event[field]].append(event)
    return {key: values[0] for key, values in result.items() if len(values) == 1}


def analyze(sender, receiver=None):
    encoded = unique_index([e for e in sender['events'] if e['stage'] == 'encodeOutput'], 'rtpTimestamp')
    primary = [f for f in sender['rtp']['frames'] if f['direction'] == 'outbound' and f['kind'] == 'primary']
    streams = defaultdict(list)
    for frame in primary:
        streams[frame['ssrc']].append(frame)
    mappings = {}
    for ssrc, packets in streams.items():
        candidates = []
        # The SDK constructs input NTP milliseconds and the extension using separate integer clock
        # conversions. Accept only a single constant -1/0/+1 ms calibration, never nearest event time.
        base = next(iter(encoded), 0)
        relative = lambda t: ((t - base + (1 << 31)) & MASK) - (1 << 31)
        lo, hi = min(map(relative, encoded), default=0), max(map(relative, encoded), default=0)
        for correction in [-1, 0, 1]:
            offsets, unmatched, interior_misses = [], 0, 0
            for frame in packets:
                if 'absoluteCaptureNtp' not in frame:
                    continue
                ms = (frame['absoluteCaptureNtp'] * 1000 + (1 << 31)) >> 32
                timestamp = ((ms + correction) * 90) & MASK
                if timestamp not in encoded:
                    unmatched += 1
                    interior_misses += lo <= relative(timestamp) <= hi
                    continue
                offsets.append((frame['timestamp'] - timestamp) & MASK)
            if len(offsets) >= 3 and len(set(offsets)) == 1 and not interior_misses:
                candidates.append({'anchors': len(offsets), 'unmatchedAnchors': unmatched,
                                   'offset': offsets[0], 'ntpIntegerClockCorrectionMs': correction})
        mappings[ssrc] = ({'status': 'verified_capture_anchors', **candidates[0]} if len(candidates) == 1
                          else {'status': 'unknown', 'validCalibrationCandidates': len(candidates), 'offset': None})

    rows = []
    for frame in primary:
        mapping = mappings[frame['ssrc']]
        if mapping['offset'] is None:
            continue
        original = encoded.get((frame['timestamp'] - mapping['offset']) & MASK)
        if original is None:
            continue
        delta = (frame['firstPacketNs'] - original['uptimeNs']) / 1e6
        if delta < 0:
            continue
        row = {'frameID': original.get('frameID'), 'ssrc': frame['ssrc'], 'timestamp': frame['timestamp'],
               'frameType': original.get('reason', 'unknown'), 'encodedBytes': original.get('bytes'),
               'encodedToFirstBridgePacketMs': delta,
               'localRTPPacketSpreadMs': (frame['lastPacketNs'] - frame['firstPacketNs']) / 1e6,
               'bridgeFrameMaxQueueWaitMs': frame['queueWaitNsMax'] / 1e6,
               'drops': frame['drops'], 'packets': frame['packets']}
        if 'lastAcceptedNs' in frame:
            row['encodedToLastOSAcceptedMs'] = (frame['lastAcceptedNs'] - original['uptimeNs']) / 1e6
        rows.append(row)
    result = {'schemaVersion': 1, 'senderEpoch': sender['summary']['epoch'], 'mappings': mappings,
              'senderProbes': sender.get('probes', {}),
              'senderSettings': sender.get('settings', {}),
              'senderTraceOverwrittenEvents': sender['summary']['overwritten'],
              'senderTraceOverwrittenRTPFrames': sender['rtp']['overwrittenFrames'],
              'matchedEncodedFrames': len(rows), 'primaryFrameGroups': len(primary),
              'sdkDropReasons': dict(Counter(e.get('reason', 'unknown') for e in sender['events'] if e['stage'] == 'sdkDrop')),
              'packetKinds': dict(Counter(f['kind'] for f in sender['rtp']['frames'])),
              'queueDrops': dict(sum((Counter(f['drops']) for f in sender['rtp']['frames']), Counter())),
              'senderIntervals': {key: distribution([r[key] for r in rows if key in r]) for key in
                                  ['encodedToFirstBridgePacketMs', 'encodedToLastOSAcceptedMs', 'localRTPPacketSpreadMs', 'bridgeFrameMaxQueueWaitMs']},
              'largestSenderCompletionIntervals': sorted(rows, key=lambda r: r.get('encodedToLastOSAcceptedMs', 0), reverse=True)[:10]}
    result['frameTypes'] = {kind: {
        'frames': sum(r['frameType'] == kind for r in rows),
        'encodedBytes': distribution([r['encodedBytes'] for r in rows if r['frameType'] == kind and r['encodedBytes'] is not None]),
        'encodedToLastOSAcceptedMs': distribution([r['encodedToLastOSAcceptedMs'] for r in rows if r['frameType'] == kind and 'encodedToLastOSAcceptedMs' in r])}
        for kind in sorted(set(r['frameType'] for r in rows))}
    if receiver:
        incoming = [f for f in receiver['rtp']['frames'] if f['direction'] == 'inbound' and f['kind'] == 'primary']
        rx = {(f['ssrc'], f['timestamp']): f for f in incoming}
        rendered_events = sorted([e for e in receiver['events'] if e['stage'] == 'rendererCallback'], key=lambda e: e['uptimeNs'])
        rendered = unique_index(rendered_events, 'rtpTimestamp')
        # A renderer callback doesn't expose SSRC. Only correlate when exactly one primary SSRC exists.
        one_stream = len(streams) == 1
        receive_intervals, end_to_callback = [], []
        primary_missing, after_adapter = 0, 0
        recovered_timestamps = []
        shared_indices = [i for i, f in enumerate(primary) if (f['ssrc'], f['timestamp']) in rx]
        covered = primary[min(shared_indices):max(shared_indices) + 1] if shared_indices else []
        for sent in covered:
            received = rx.get((sent['ssrc'], sent['timestamp']), {})
            if sent['sequenceMetadataOmitted'] or received.get('sequenceMetadataOmitted'):
                continue
            absent = set(sent['sequences']) - set(received.get('sequences', []))
            primary_missing += len(absent)
            after_adapter += len(set(sent['acceptedSequences']) - set(received.get('sequences', [])))
            event = rendered.get(sent['timestamp']) if one_stream else None
            if absent and event:
                recovered_timestamps.append(sent['timestamp'])
            if event and received and event['uptimeNs'] >= received['firstPacketNs']:
                receive_intervals.append((event['uptimeNs'] - received['firstPacketNs']) / 1e6)
            if event and sender.get('clockDomain') and sender.get('clockDomain') == receiver.get('clockDomain'):
                mapping = mappings[sent['ssrc']]
                original = encoded.get((sent['timestamp'] - mapping['offset']) & MASK) if mapping['offset'] is not None else None
                if original and event['uptimeNs'] >= original['uptimeNs']:
                    end_to_callback.append((event['uptimeNs'] - original['uptimeNs']) / 1e6)
        gaps = [{'previousRTP': a['rtpTimestamp'], 'rtpTimestamp': b['rtpTimestamp'],
                 'gapMs': (b['uptimeNs'] - a['uptimeNs']) / 1e6}
                for a, b in zip(rendered_events, rendered_events[1:])]
        if one_stream:
            ssrc = next(iter(streams))
            sent_by_time = {f['timestamp']: f for f in primary}
            offset = mappings[ssrc]['offset']
            for gap in gaps:
                previous, current = gap['previousRTP'], gap['rtpTimestamp']
                a, b = sent_by_time.get(previous), sent_by_time.get(current)
                if a and b:
                    gap['senderFirstBridgeIntervalMs'] = (b['firstPacketNs'] - a['firstPacketNs']) / 1e6
                if offset is not None:
                    a, b = encoded.get((previous - offset) & MASK), encoded.get((current - offset) & MASK)
                    if a and b:
                        gap['senderEncodedIntervalMs'] = (b['uptimeNs'] - a['uptimeNs']) / 1e6
                        gap['currentFrameType'] = b.get('reason', 'unknown')
                        gap['currentEncodedBytes'] = b.get('bytes')
                a, b = rx.get((ssrc, previous)), rx.get((ssrc, current))
                event = rendered.get(current)
                if a and b:
                    gap['receiverFirstPrimaryIntervalMs'] = (b['firstPacketNs'] - a['firstPacketNs']) / 1e6
                if b and event:
                    gap['currentFirstPrimaryToRendererMs'] = (event['uptimeNs'] - b['firstPacketNs']) / 1e6
        result['receiver'] = {'epoch': receiver['summary']['epoch'], 'rendererCallbacks': len(rendered_events),
                              'rendererSSRCUnambiguous': one_stream,
                              'senderFrameGroupsOutsideReceiverCoverage': len(primary) - len(covered),
                              'primarySequencesNotSeen': primary_missing,
                              'osAcceptedPrimarySequencesNotSeen': after_adapter,
                              'renderedDespiteMissingOriginalPrimaryCount': len(recovered_timestamps),
                              'firstPrimaryIngressToRendererMs': distribution(receive_intervals),
                              'sameProcessEncodedToRendererMs': distribution(end_to_callback),
                              'rendererGapMs': distribution([g['gapMs'] for g in gaps]),
                              'rendererGapsOver50Ms': sum(g['gapMs'] > 50 for g in gaps),
                              'rendererGapsOver100Ms': sum(g['gapMs'] > 100 for g in gaps),
                              'largestRendererGaps': sorted(gaps, key=lambda g: g['gapMs'], reverse=True)[:10],
                              'packetKinds': dict(Counter(f['kind'] for f in receiver['rtp']['frames']))}
        # Controlled loopback loss only. This is the last observed dropped packet, not the
        # configured blackout end, so this interval is not a pure repair-time measurement.
        drops = [f['lastDropNs'] for f in sender['rtp']['frames']
                 if f['drops'].get('simulated_loss') and 'lastDropNs' in f]
        if drops and sender.get('clockDomain') and sender.get('clockDomain') == receiver.get('clockDomain'):
            last_drop = max(drops)
            after = [e for e in rendered_events if e['uptimeNs'] >= last_drop]
            result['receiver']['lastInjectedDropToNextRendererMs'] = ((after[0]['uptimeNs'] - last_drop) / 1e6) if after else None
    result['limits'] = [
        'Encoded-to-first-bridge-packet combines SDK packetization, pacer and local socket scheduling; it is not direct pacer enqueue instrumentation.',
        'Bridge queue intervals cover the application only. OS acceptance is not physical egress or remote delivery.',
        'Primary sequence differences are only for retained metadata. RTX OSN is encrypted; RTX/padding counts are not repaired-packet counts.',
        'Capture anchors require a single constant -1/0/+1 ms integer-clock calibration, no interior unmatched anchors, and at least three consistent offsets per SSRC. Ambiguous or absent mappings stay unknown.',
        'Receiver intervals end at an independent WebRTC renderer callback, not screen presentation.',
        'Gap rows compare intervals within each clock domain; sender intervals spanning missing rendered frames do not imply sender inactivity.',
        'Cross-peer clock subtraction is emitted only for an identical random process clockDomain. No remote one-way latency is claimed.']
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('sender', type=Path)
    parser.add_argument('--receiver', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    result = analyze(json.loads(args.sender.read_text()), json.loads(args.receiver.read_text()) if args.receiver else None)
    text = json.dumps(result, ensure_ascii=False, indent=2) + '\n'
    if args.output:
        args.output.write_text(text)
    else:
        print(text, end='')
