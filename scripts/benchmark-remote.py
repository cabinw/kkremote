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
parser.add_argument('--duration', type=int, default=40)
parser.add_argument('--resolution', choices=['1280x720', '1920x1080', '2560x1440'], default='1920x1080')
parser.add_argument('--fps', type=int, choices=[30, 60], default=60)
parser.add_argument('--mbps', type=int, default=25)
parser.add_argument('--pattern', choices=['grid', 'noise'], default='grid')
args = parser.parse_args()
if not 10 <= args.duration <= 600 or not 1 <= args.mbps <= 120 or not args.remote_app.startswith('/'):
    parser.error('duration 10...600, Mbps 1...120, absolute remote-app required')
root = Path(__file__).resolve().parent.parent
app = root / '.build/DerivedData/Build/Products/Release/KKRemoteLabMac.app/Contents/MacOS/KKRemoteLabMac'
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
    'durationSeconds': args.duration, 'route': args.route, 'pacing': args.pacing,
    'resolution': args.resolution, 'fps': args.fps, 'ceilingMbps': args.mbps, 'pattern': args.pattern}, indent=2) + '\n')
remote_dir = f'{remote_home}/Library/Containers/com.cabinw.kkremote.lab.mac/Data/RemoteBench/{run_id}'
remote(['mkdir', '-p', '-m', '700', remote_dir])
key = container / 'pairing.key'
remote_key = f'{remote_dir}/pairing.key'
host_report = container / 'host.json'
parameters = ['--route', args.route, '--pacing', args.pacing, '--resolution', args.resolution, '--fps', str(args.fps),
              '--mbps', str(args.mbps), '--pattern', args.pattern]
host_command = [str(app), '--lab-role', 'host', '--duration', str(args.duration + 20),
                '--key-file', str(key), '--report', str(host_report)] + parameters
host = None
try:
    with (output / 'host.log').open('w') as log:
        host = subprocess.Popen(host_command, stdout=log, stderr=subprocess.STDOUT)
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
        with (output / 'viewer.log').open('w') as viewer_log:
            viewer = subprocess.run(ssh + [shlex.join(viewer_command)], stdout=viewer_log,
                                    stderr=subprocess.STDOUT, timeout=args.duration + 45)
        try: host.wait(timeout=25)
        except subprocess.TimeoutExpired: host.terminate(); host.wait(timeout=5)
    if host_report.exists(): (output / 'host.json').write_bytes(host_report.read_bytes())
    report = remote(['cat', remote_dir + '/viewer.json'], capture_output=True).stdout
    (output / 'viewer.json').write_bytes(report)
    for role in ['host', 'viewer']:
        path = output / f'{role}.json'
        if path.exists():
            data = json.loads(path.read_text()); data['networkLabel'] = args.network
            data['notes'].append('Network label supplied by remote test operator; inspect overlay diagnostics separately.')
            path.write_text(json.dumps(data, indent=2) + '\n')
    # The host normally observes the viewer closing first. Its diagnostics are still retained.
    print(json.dumps({'viewerPassed': viewer.returncode == 0, 'hostExitCode': host.returncode,
                      'reportDirectory': str(output)}), flush=True)
    if viewer.returncode: raise SystemExit(1)
finally:
    if host is not None and host.poll() is None:
        host.terminate(); host.wait(timeout=5)
    key.unlink(missing_ok=True)
    remote(['rm', '-f', '--', remote_key])
