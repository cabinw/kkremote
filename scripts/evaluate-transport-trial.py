#!/usr/bin/env python3
"""Evaluate narrow transport trial gates, never physical latency or visual quality."""
import argparse
import importlib.util
import json
from pathlib import Path

spec = importlib.util.spec_from_file_location('report_analysis', Path(__file__).with_name('analyze-transport-run.py'))
analysis = importlib.util.module_from_spec(spec)
spec.loader.exec_module(analysis)


def evaluate(host, viewer, guard, requested_seconds):
    checks = {}
    summaries = {}
    for role, document in [('host', host), ('viewer', viewer)]:
        summary = analysis.analyze(document)
        summaries[role] = summary
        active = [s for s in document['samples'] if s['framesEncoded'] or s['framesDecoded']]
        checks[role + '_usable'] = summary['usable']
        # Nominal session includes signalling/startup; allow at most five seconds.
        span = active[-1]['seconds'] - active[0]['seconds'] if len(active) >= 2 else 0
        checks[role + '_duration'] = span >= requested_seconds - 5
        checks[role + '_fps'] = summary.get('fps', 0) >= 59.5 if summary['usable'] else False
        checks[role + '_dimensions'] = bool(active) and all(s.get('width') == 2560 and s.get('height') == 1440 for s in active)
        counter = 'framesEncoded' if role == 'host' else 'framesDecoded'
        checks[role + '_role'] = document.get('mode') == role and bool(active) and active[-1][counter] > 0
        checks[role + '_continuous_epoch'] = bool(active) and all(
            b['seconds'] > a['seconds'] and b[counter] >= a[counter] for a, b in zip(active, active[1:]))
        codecs = {s.get('codec') for s in active}
        checks[role + '_single_codec'] = len(codecs) == 1 and codecs <= {'video/H264', 'video/H265'}
        if document.get('mediaRoute') == 'fixed-udp-v2':
            bridges = [s.get('bridge') for s in active]
            checks[role + '_bounded_bridge'] = bool(bridges) and all(
                b is not None and b.get('transport') in {'socket', 'network'}
                # pending includes both waiting (256) and NW in-flight (32).
                and 0 <= b.get('pendingPackets', -1) <= (256 if b['transport'] == 'socket' else 288)
                and b.get('queueOverflowDrops') == 0 and b.get('queueDeadlineDrops') == 0 for b in bridges)
    # Freeze and drop gates use the ENTIRE session, including warmup.
    active_viewer = [s for s in viewer['samples'] if s['framesDecoded']]
    checks['viewer_zero_freezes'] = bool(active_viewer) and all(s.get('freezeCount') == 0 for s in active_viewer)
    checks['viewer_zero_sdk_drops'] = bool(active_viewer) and all(s.get('framesDropped') == 0 for s in active_viewer)
    checks['matching_codec'] = bool(host['samples']) and bool(viewer['samples']) and host['samples'][-1].get('codec') == viewer['samples'][-1].get('codec')
    samples = guard.get('samples', [])
    checks['source_guard_complete'] = guard.get('valid') is True and guard.get('monitorCompleted') is True
    checks['source_identity'] = bool(samples) and all(s.get('identityMatched') is True for s in samples)
    host_end = max((s['seconds'] for s in host['samples']), default=0)
    checks['source_guard_coverage'] = bool(samples) and samples[0]['elapsedSeconds'] <= 5 and samples[-1]['elapsedSeconds'] >= host_end - 10.5
    checks['source_guard_continuity'] = len(samples) >= 2 and all(
        0 < b['elapsedSeconds'] - a['elapsedSeconds'] <= 20.5 for a, b in zip(samples, samples[1:]))
    return {'schemaVersion': 1, 'transportTrialPassed': all(checks.values()), 'checks': checks,
            'failedChecks': [name for name, passed in checks.items() if not passed],
            'requestedSeconds': requested_seconds, 'summaries': summaries,
            'limits': ['Nominal session duration allows up to five seconds before active media.',
                       'Guard coverage compares first-session elapsed clocks with a ten-second sampling allowance; only use a guard started with this host.',
                       'Guard samples must increase monotonically with gaps no larger than 20.5 seconds; identity between samples remains unobserved.',
                       'Bridge bounds do not prove flat queue age or memory; inspect full curves and resource summaries.',
                       'No gate here certifies physical presentation, optical latency, HDR mastering, visual quality, or sustained full-budget bitrate.']}


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--host', type=Path, required=True)
    p.add_argument('--viewer', type=Path, required=True)
    p.add_argument('--guard', type=Path, required=True)
    p.add_argument('--seconds', type=int, required=True)
    p.add_argument('--output', type=Path, required=True)
    args = p.parse_args()
    if not 30 <= args.seconds <= 3600:
        p.error('seconds must be 30...3600')
    result = evaluate(*(json.loads(path.read_text()) for path in [args.host, args.viewer, args.guard]), args.seconds)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({key: result[key] for key in ['transportTrialPassed', 'failedChecks']}))
    raise SystemExit(0 if result['transportTrialPassed'] else 1)
