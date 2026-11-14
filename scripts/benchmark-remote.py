#!/usr/bin/env python3
"""Send to an already provisioned Mac viewer over LAN or Ponte, controlled through existing SSH."""
import argparse
import hashlib
import json
from pathlib import Path
import shlex
import subprocess
import time
import uuid

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--ssh', required=True, help='Existing SSH alias; no password or host-key bypass')
parser.add_argument('--remote-app', required=True, help='Absolute path to the matching .app on the viewer Mac')
parser.add_argument('--host', required=True, help='Sender address as seen by viewer: LAN IP or name.sgponte')
parser.add_argument('--network', choices=['LAN', 'Surge Ponte'], required=True)
parser.add_argument('--route', choices=['direct-ice', 'fixed-udp-v1', 'fixed-udp-v2'], default='fixed-udp-v2')
parser.add_argument('--pacing', choices=['upstream', 'interactive', 'smooth'], default='interactive')
parser.add_argument('--bridge-transport', choices=['network','socket'], default='network')
parser.add_argument('--receive-depth', type=int, choices=[1,16], default=16)
parser.add_argument('--duration', type=int, default=40)
parser.add_argument('--resolution', choices=['1280x720', '1920x1080', '2560x1440'], default='1920x1080')
parser.add_argument('--fps', type=int, choices=[30, 60], default=60)
parser.add_argument('--mbps', type=int, default=25)
parser.add_argument('--pattern', choices=['grid', 'noise', 'desktop'], default='grid')
parser.add_argument('--sender-app', type=Path, help='Matching local .app (use independent DerivedData)')
parser.add_argument('--port', type=int, default=56090, help='Isolated signalling port; does not replace the phone host')
parser.add_argument('--media-port', type=int, default=56091)
parser.add_argument('--window-id', type=int)
parser.add_argument('--expected-window-title', help='Abort and invalidate if the capture window identity changes')
parser.add_argument('--live-host', action='store_true', help='Write bounded live host samples; retain the full first media session at completion')
parser.add_argument('--identity-probe', type=Path, help='Signed metadata-only source identity helper')
parser.add_argument('--hdr', action='store_true')
parser.add_argument('--playout', choices=['adaptive', 'realtime'], default='realtime')
parser.add_argument('--frame-trace', action='store_true')
parser.add_argument('--sdk-drop-diagnostics', action='store_true')
parser.add_argument('--hevc-keyframe-seconds', type=int, choices=[2,10], default=10)
parser.add_argument('--sample-journal', action='store_true', help='Complete ordered samples with bounded asynchronous disk writing')
parser.add_argument('--report-history-limit', type=int, choices=[60,300,3600], default=3600)
args = parser.parse_args()
if args.sample_journal and args.live_host:
    parser.error('sample-journal requires single-session hosts, not live-host restarts')
if args.report_history_limit != 3600 and not args.sample_journal:
    parser.error('Shorter history requires a complete sample journal')
if args.sdk_drop_diagnostics and not args.frame_trace:
    parser.error('SDK drop diagnostics requires --frame-trace')
if args.expected_window_title and not args.window_id:
    parser.error('expected-window-title requires window-id')
if not 10 <= args.duration <= 1800 or not 1 <= args.mbps <= 120 or not args.remote_app.startswith('/'):
    parser.error('duration 10...1800, Mbps 1...120, absolute remote-app required')
root = Path(__file__).resolve().parent.parent
if not all(1 <= port <= 65535 for port in [args.port, args.media_port]) or args.port == args.media_port:
    parser.error('Distinct valid test ports required')
app = (args.sender_app.resolve() if args.sender_app else root / '.build/DerivedData/Build/Products/Release/KKRemoteLabMac.app') / 'Contents/MacOS/KKRemoteLabMac'
run_id = uuid.uuid4().hex[:12]
container = Path.home() / 'Library/Containers/com.cabinw.kkremote.lab.mac/Data/RemoteBench' / run_id
container.mkdir(parents=True, mode=0o700)
output = root / '.build/remote-bench' / run_id
output.mkdir(parents=True)
ssh = ['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8', args.ssh]
def remote(words, **kwargs):
    return subprocess.run(ssh + [shlex.join(words)], check=True, **kwargs)
remote_home = remote(['printenv', 'HOME'], capture_output=True, text=True).stdout.strip()
if not remote_home.startswith('/') or '\n' in remote_home:
    raise SystemExit('Invalid remote home')
binary_sha = hashlib.sha256(app.read_bytes()).hexdigest()
remote_sha = remote(['shasum', '-a', '256', args.remote_app + '/Contents/MacOS/KKRemoteLabMac'], capture_output=True, text=True).stdout.split()[0]
if binary_sha != remote_sha:
    raise SystemExit('Sender/viewer executables differ; deploy the matching Release app before benchmarking')
(output / 'manifest.json').write_text(json.dumps({'binarySHA256': binary_sha, 'sameExecutableVerified': True,
    'durationSeconds': args.duration, 'bridgeReceiveDepth': args.receive_depth, 'bridgeTransport': args.bridge_transport, 'route': args.route, 'pacing': args.pacing,
    'resolution': args.resolution, 'fps': args.fps, 'ceilingMbps': args.mbps,
    'liveHostReport': args.live_host, 'sourceKind': 'window' if args.window_id else 'pattern', 'pattern': None if args.window_id else args.pattern,
    'hdrRequested': args.hdr, 'frameTraceEnabled': args.frame_trace, 'playout': args.playout,
    'sdkDropDiagnostics': args.sdk_drop_diagnostics,
    'requestedHEVCKeyframeSeconds': args.hevc_keyframe_seconds,
    'sampleJournal': args.sample_journal, 'reportHistoryLimit': args.report_history_limit,
    'networkLabel': args.network, 'outerOverlayPathVerified': False}, indent=2) + '\n')
print(json.dumps({'startedRunID':run_id,'durationSeconds':args.duration,'frameTrace':args.frame_trace,'historyLimit':args.report_history_limit}),flush=True)
remote_dir = f'{remote_home}/Library/Containers/com.cabinw.kkremote.lab.mac/Data/RemoteBench/{run_id}'
remote(['mkdir', '-p', '-m', '700', remote_dir])
key = container / 'pairing.key'
remote_key = f'{remote_dir}/pairing.key'
host_report = container / 'host.json'
parameters = ['--port',str(args.port),'--media-port',str(args.media_port),'--playout',args.playout,'--bridge-transport',args.bridge_transport,'--receive-depth', str(args.receive_depth), '--route', args.route, '--pacing', args.pacing, '--resolution', args.resolution, '--fps', str(args.fps),
              '--mbps', str(args.mbps), '--pattern', args.pattern]
if args.hdr: parameters += ['--hdr']
if args.sample_journal: parameters += ['--sample-journal','--report-history-limit',str(args.report_history_limit)]
host_command = [str(app), '--lab-role', 'host', '--duration', str(args.duration + 20),
                '--key-file', str(key), '--report', str(host_report)] + parameters
if args.live_host: host_command += ['--persistent-host']
if args.window_id: host_command += ['--window-id', str(args.window_id)]
if args.frame_trace: host_command += ['--frame-trace-dir', str(container)]
if args.sdk_drop_diagnostics: host_command += ['--sdk-drop-diagnostics']
host_command += ['--hevc-keyframe-seconds', str(args.hevc_keyframe_seconds)]
host = None
guard = None
guard_report = container / 'source-guard.json'
try:
    with (output / 'host.log').open('w') as log:
        host = subprocess.Popen(host_command, stdout=log, stderr=subprocess.STDOUT)
        if args.expected_window_title:
            guard = subprocess.Popen(['python3', str(root / 'scripts/capture-source-guard.py'), '--app', str(app),
                '--window-id', str(args.window_id), '--title', args.expected_window_title,
                '--pid', str(host.pid), '--process-marker', str(container), '--report', str(guard_report),
                '--seconds', str(args.duration + 45)] + (['--identity-probe',str(args.identity_probe.resolve())] if args.identity_probe else []), stdout=log, stderr=subprocess.STDOUT)
            deadline = time.monotonic() + 8
            while not guard_report.exists() and guard.poll() is None and time.monotonic() < deadline: time.sleep(.05)
            if not guard_report.exists() or not json.loads(guard_report.read_text()).get('samples') or not json.loads(guard_report.read_text()).get('valid'):
                raise RuntimeError('Source guard failed before viewer start')
        until = time.monotonic() + 12
        while not key.exists() or key.stat().st_size == 0:
            if host.poll() is not None or time.monotonic() > until:
                raise RuntimeError('Sender failed to start; inspect host.log')
            time.sleep(.05)
        # Key travels only through authenticated SSH stdin, never command arguments or logs.
        subprocess.run(ssh + ['umask 077; cat > ' + shlex.quote(remote_key)], input=key.read_bytes(), check=True)
        viewer_command = [args.remote_app + '/Contents/MacOS/KKRemoteLabMac', '--lab-role', 'viewer',
                          '--host', args.host, '--duration', str(args.duration), '--key-file', remote_key,
                          '--report', remote_dir + '/viewer.json'] + parameters
        if args.frame_trace: viewer_command += ['--frame-trace-dir', remote_dir]
        with (output / 'viewer.log').open('w') as viewer_log:
            viewer = subprocess.run(ssh + [shlex.join(viewer_command)], stdout=viewer_log,
                                    stderr=subprocess.STDOUT, timeout=args.duration + 45)
        try: host.wait(timeout=25)
        except subprocess.TimeoutExpired: host.terminate(); host.wait(timeout=5)
    complete_host_report = container / 'host.session-001.json' if args.live_host else host_report
    if complete_host_report.exists(): (output / 'host.json').write_bytes(complete_host_report.read_bytes())
    report = remote(['cat', remote_dir + '/viewer.json'], capture_output=True).stdout
    (output / 'viewer.json').write_bytes(report)
    if args.sample_journal:
        (output / 'host.samples.jsonl').write_bytes((container / 'host.samples.jsonl').read_bytes())
        (output / 'viewer.samples.jsonl').write_bytes(remote(['cat',remote_dir+'/viewer.samples.jsonl'],capture_output=True).stdout)
        for role in ['host','viewer']:
            path = output / (role+'.json')
            if not path.exists(): continue  # Guard/crash may have prevented a final report.
            tail = output / (role+'.retained.json')
            tail.write_bytes(path.read_bytes())
            subprocess.run(['python3', str(root/'scripts/reconstruct-sample-journal.py'), '--report',str(tail),
                            '--journal',str(output/(role+'.samples.jsonl')),'--output',str(path)],check=True)
    if args.frame_trace:
        for path in container.glob('sender-*.json'): (output / path.name).write_bytes(path.read_bytes())
        # List only task-owned trace metadata, never directory-wide logs or keys.
        names = remote(['find', remote_dir, '-maxdepth', '1', '-name', 'receiver-*.json', '-type', 'f'], capture_output=True, text=True).stdout.splitlines()
        for name in names:
            if not name.startswith(remote_dir + '/') or Path(name).name != name[len(remote_dir) + 1:]:
                raise RuntimeError('Unexpected remote trace path')
            (output / Path(name).name).write_bytes(remote(['cat', name], capture_output=True).stdout)
        if len(list(output.glob('sender-*.json'))) != 1 or len(list(output.glob('receiver-*.json'))) != 1:
            raise RuntimeError('Missing or ambiguous trace export; do not accept this run as frame-trace evidence')
        incidents = output/'incidents'; incidents.mkdir(exist_ok=True)
        for path in (container/'incidents').glob('*.json'): (incidents/path.name).write_bytes(path.read_bytes())
        names = remote(['find',remote_dir,'-maxdepth','2','-name','*-first-freeze.json','-type','f'],capture_output=True,text=True).stdout.splitlines()
        for name in names:
            if not name.startswith(remote_dir+'/incidents/') or Path(name).name != name[len(remote_dir+'/incidents/'):]:
                raise RuntimeError('Unexpected incident path')
            (incidents/Path(name).name).write_bytes(remote(['cat',name],capture_output=True).stdout)
    for role in ['host', 'viewer']:
        path = output / f'{role}.json'
        if path.exists():
            data = json.loads(path.read_text()); data['networkLabel'] = args.network
            data['notes'].append('Network label supplied by remote test operator; inspect overlay diagnostics separately.')
            path.write_text(json.dumps(data, indent=2) + '\n')
    # The host normally observes the viewer closing first. Its diagnostics are still retained.
    source_valid = True
    if guard is not None:
        try: guard.wait(timeout=12)
        except subprocess.TimeoutExpired: guard.terminate(); guard.wait(timeout=5)
        guarded = json.loads(guard_report.read_text()) if guard_report.exists() else {}
        source_valid = guard.returncode == 0 and guarded.get('valid', False) and guarded.get('monitorCompleted', False)
        if guard_report.exists(): (output / 'source-guard.json').write_bytes(guard_report.read_bytes())
        if not source_valid:
            (output / 'INVALIDATION.json').write_text(json.dumps({'reason': 'Capture source identity failed; results excluded.'}) + '\n')
    print(json.dumps({'viewerPassed': viewer.returncode == 0, 'hostExitCode': host.returncode,
                      'sourceIdentityValid': source_valid if guard else None, 'fullHostReportPresent': complete_host_report.exists(), 'reportDirectory': str(output)}), flush=True)
    if viewer.returncode or not source_valid or not complete_host_report.exists(): raise SystemExit(1)
finally:
    if host is not None and host.poll() is None:
        host.terminate(); host.wait(timeout=5)
    if guard is not None and guard.poll() is None:
        guard.terminate(); guard.wait(timeout=5)
    if guard_report.exists():
        (output / 'source-guard.json').write_bytes(guard_report.read_bytes())
        guard_state = json.loads(guard_report.read_text())
        if not guard_state.get('valid') or not guard_state.get('monitorCompleted'):
            (output/'INVALIDATION.json').write_text(json.dumps({'reason':guard_state.get('reason','Source guard incomplete; results excluded.')})+'\n')
    key.unlink(missing_ok=True)
    remote(['rm', '-f', '--', remote_key])
