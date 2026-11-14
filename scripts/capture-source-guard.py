#!/usr/bin/env python3
"""Monitor an existing benchmark's capture identity; fail the run if it changes.

This reads exact-window metadata through a persistent helper (preferred), or the
legacy SCWindow catalog. Only match status, dimensions and display modes are retained. It cannot
detect changes between polls and never reads browser history or page contents.
"""
import argparse
import json
import math
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import select
import atexit
import sys

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--app', type=Path, required=True)
p.add_argument('--window-id', type=int, required=True)
p.add_argument('--title', default='KKRemote Repeatable Load Fixture')
p.add_argument('--application', default='Google Chrome')
p.add_argument('--pid', type=int, required=True)
p.add_argument('--process-marker', required=True, help='Exact task-owned report directory in process arguments')
p.add_argument('--report', type=Path, required=True)
p.add_argument('--seconds', type=int, required=True)
p.add_argument('--identity-probe', type=Path, help='Signed persistent metadata-only probe; preferred for performance runs')
a = p.parse_args()
if a.seconds < 1 or not a.app.is_file() or not a.process_marker.startswith('/'):
    p.error('valid duration, executable and absolute process marker required')
a.report.parent.mkdir(parents=True, exist_ok=True)
start = time.monotonic()
result = {'schema': 1, 'intervalSeconds': 10, 'windowID': a.window_id, 'valid': True,
          'limitation': 'Identity sampled every 10 seconds; not continuous content attestation.', 'samples': []}
dimensions = None
display_baseline = None
probe = None
if a.identity_probe:
    probe = subprocess.Popen([str(a.identity_probe.resolve(strict=True)),str(a.window_id),str(a.seconds+15)],
                             stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True)
result['method'] = 'persistent-coregraphics-metadata' if probe else 'repeated-screen-capture-catalog'
def cleanup():
    if probe and probe.poll() is None: probe.terminate(); probe.wait(timeout=5)
atexit.register(cleanup)
signal.signal(signal.SIGTERM, lambda signum, frame: sys.exit(128+signum))
def owned():
    proc = subprocess.run(['ps', '-p', str(a.pid), '-o', 'command='], text=True, capture_output=True)
    return proc.returncode == 0 and str(a.app.resolve()) in proc.stdout and a.process_marker in proc.stdout
def save():
    temporary = a.report.with_suffix('.tmp')
    temporary.write_text(json.dumps(result, indent=2) + '\n')
    temporary.replace(a.report)
def valid_size(value):
    return isinstance(value, list) and len(value) == 2 and all(
        isinstance(n, (int, float)) and not isinstance(n, bool) and math.isfinite(n) and n > 0 for n in value)
def valid_modes(value):
    return isinstance(value, list) and bool(value) and all(
        isinstance(mode, dict) and isinstance(mode.get('id'), int) and mode['id'] > 0
        and valid_size(mode.get('modePoints')) and valid_size(mode.get('modePixels'))
        and isinstance(mode.get('nominalRefreshHz'), (int, float))
        and math.isfinite(mode['nominalRefreshHz']) and mode['nominalRefreshHz'] >= 0 for mode in value)
while owned() and time.monotonic() - start < a.seconds:
    sample = {'elapsedSeconds': round(time.monotonic() - start, 3), 'identityMatched': False}
    try:
        if probe:
            if not select.select([probe.stdout],[],[],12)[0]: raise ValueError('Metadata probe stalled')
            row = json.loads(probe.stdout.readline())
            if not isinstance(row, dict): raise ValueError('Invalid metadata record')
            size = row.get('dimensionsPoints')
        else:
            # Legacy diagnostic fallback. Repeated app launches can disturb capture cadence.
            with tempfile.TemporaryDirectory(prefix='source-guard-', dir=a.report.parent) as directory:
                catalog = Path(directory) / 'windows.json'
                subprocess.run([str(a.app), '--list-windows', '--report', str(catalog)],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5, check=True)
                row = next((x for x in json.loads(catalog.read_text()) if x['id'] == a.window_id), None)
                size = [row['widthPoints'],row['heightPoints']] if row else None
        if not valid_size(size): raise ValueError('Invalid window dimensions')
        sample['elapsedSeconds'] = round(time.monotonic()-start,3)
        sample['identityMatched'] = bool(row and row['title'] == a.title and row['application'] == a.application)
        if sample['identityMatched']:
            if dimensions is None: dimensions = size
            sample['dimensionsPoints'] = size
            sample['identityMatched'] = size == dimensions
        if 'displayObservationComplete' in (row or {}) or display_baseline is not None:
            # New probes catch display changes even when the window size stays fixed.
            # Older reports remain explicitly limited to window metadata.
            modes = row.get('displays')
            complete = row.get('displayObservationComplete') is True and valid_modes(modes)
            if complete and display_baseline is None: display_baseline = modes
            sample['displayMatched'] = complete and modes == display_baseline
            sample['displayModes'] = modes if complete else None
            sample['identityMatched'] = sample['identityMatched'] and sample['displayMatched']
            result['displayGuardAvailable'] = True
        else:
            result['displayGuardAvailable'] = False
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
        sample['catalogError'] = True
    result['samples'].append(sample)
    if not sample['identityMatched']:
        result['valid'] = False
        result['reason'] = 'Capture identity, dimensions or observed display mode changed, or metadata unavailable; do not accept this run.'
        save()
        if owned(): os.kill(a.pid, signal.SIGTERM)
        if probe and probe.poll() is None: probe.terminate(); probe.wait(timeout=5)
        raise SystemExit(2)
    save()
    if not probe: time.sleep(min(10, max(0, a.seconds - (time.monotonic() - start))))
result['monitorCompleted'] = True
save()
if probe and probe.poll() is None: probe.terminate(); probe.wait(timeout=5)
