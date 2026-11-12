#!/usr/bin/env python3
"""Verify two real media sessions and a rejected key against one persistent host."""
import hashlib
import base64
import json
import os
from pathlib import Path
import socket
import subprocess
import time
import uuid

root = Path(__file__).resolve().parent.parent
app = root / '.build/DerivedData/Build/Products/Release/KKRemoteLabMac.app/Contents/MacOS/KKRemoteLabMac'
run = 'reconnect-' + uuid.uuid4().hex[:10]
work = Path.home() / 'Library/Containers/com.cabinw.kkremote.lab.mac/Data/LiveTesting' / run
work.mkdir(parents=True, mode=0o700)
output = root / '.build/live-testing' / run
output.mkdir(parents=True, mode=0o700)
key = work / 'pairing.key'

def port(kind):
    with socket.socket(socket.AF_INET, kind) as s:
        s.bind(('127.0.0.1', 0))
        return str(s.getsockname()[1])

params = ['--route', 'fixed-udp-v2', '--bridge-transport', 'socket', '--port', port(socket.SOCK_STREAM),
          '--media-port', port(socket.SOCK_DGRAM), '--resolution', '1280x720', '--fps', '30',
          '--mbps', '8', '--pattern', 'grid']
log_path = output / 'host.log'
host = None

def wait_for(predicate, seconds=15):
    deadline = time.monotonic() + seconds
    while not predicate():
        if host.poll() is not None or time.monotonic() >= deadline:
            raise RuntimeError('Persistent host did not reach expected state; inspect ' + str(log_path))
        time.sleep(.1)

def viewer(name, key_file, success):
    report = work / (name + '.json')
    with (output / (name + '.log')).open('w') as log:
        result = subprocess.run([str(app), '--lab-role', 'viewer', '--host', '127.0.0.1',
            '--duration', '8', '--key-file', str(key_file), '--report', str(report)] + params,
            stdout=log, stderr=subprocess.STDOUT, timeout=20)
    if success:
        assert result.returncode == 0, 'Valid viewer failed: ' + name
        samples = json.loads(report.read_text())['samples']
        assert samples[-1]['framesDecoded'] >= 60 and samples[-1]['bridge']['authenticated']
    else:
        assert result.returncode != 0, 'Wrong key unexpectedly connected'
        samples = json.loads(report.read_text())['samples']
        assert all(s.get('framesDecoded', 0) == 0 for s in samples)

try:
    with log_path.open('w') as log:
        host = subprocess.Popen([str(app), '--lab-role', 'host', '--persistent-host', '--duration', '90',
            '--key-file', str(key), '--report', str(work / 'host.json')] + params,
            stdout=log, stderr=subprocess.STDOUT)
        wait_for(lambda: 'LAB_HOST_LISTENING session=1' in log_path.read_text())
        original = hashlib.sha256(key.read_bytes()).digest()
        viewer('first', key, True)
        wait_for(lambda: 'LAB_HOST_LISTENING session=2' in log_path.read_text())
        wrong = work / 'wrong.key'
        wrong.write_bytes(base64.b64encode(os.urandom(32)))
        wrong.chmod(0o600)
        viewer('wrong', wrong, False)
        wait_for(lambda: 'LAB_HOST_LISTENING session=3' in log_path.read_text())
        viewer('second', key, True)
        wait_for(lambda: 'LAB_HOST_LISTENING session=4' in log_path.read_text())
        assert hashlib.sha256(key.read_bytes()).digest() == original
        assert len(list(work.glob('host.session-*.json'))) == 3
        assert (work / 'host.json').exists(), 'Live telemetry snapshot missing'
        assert len(json.loads((work / 'host.json').read_text())['samples']) <= 5
        print('PASS: two authenticated video sessions, wrong key rejected, same host PID/key, session reports retained')
finally:
    if host is not None and host.poll() is None:
        host.terminate()
        host.wait(timeout=10)
    key.unlink(missing_ok=True)
    (work / 'wrong.key').unlink(missing_ok=True)
