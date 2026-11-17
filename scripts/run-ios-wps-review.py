#!/usr/bin/env python3
"""Build/launch only the isolated WPS host and a fixed iOS simulator."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / '.build/ios-wps-control'
CLIENT = ROOT / '.build/ios-client-review'
APP_ID = 'com.cabinw.kkremote.clientreview.simulator'
HOST_BINARY = BASE / 'DerivedData/Build/Products/Debug/KKRemoteWPSReviewHost.app/Contents/MacOS/KKRemoteWPSReviewHost'


def run(*args, **kwargs):
    return subprocess.run(args, cwd=ROOT, check=True, text=True, **kwargs)


def output(*args):
    return run(*args, capture_output=True).stdout.strip()


def listener_pids(port):
    result = subprocess.run(['lsof', '-tiTCP:' + str(port), '-sTCP:LISTEN'], capture_output=True, text=True)
    if result.returncode not in (0, 1):
        raise RuntimeError('Cannot inspect port ownership')
    return set(result.stdout.split())


def stop_own_host():
    pids = listener_pids(48273) | listener_pids(48274)
    for pid in pids:
        command = output('ps', '-p', pid, '-o', 'comm=')
        if (ROOT / command).resolve() != HOST_BINARY.resolve():
            raise RuntimeError('Refusing to stop an unrelated process on the review ports')
    for pid in pids:
        os.kill(int(pid), signal.SIGTERM)
    for _ in range(50):
        if not (listener_pids(48273) | listener_pids(48274)):
            return
        time.sleep(.1)
    raise RuntimeError('Review ports did not close')


def build():
    specs = [
        ('Apps/WPSReviewHost/project.yml', BASE / 'project', 'KKRemoteWPSReviewHost', 'platform=macOS,arch=arm64', BASE),
        ('Apps/IOSInteractionLab/client-project.yml', CLIENT, 'KKRemoteClientReview', 'generic/platform=iOS Simulator', CLIENT),
    ]
    for spec, project_dir, scheme, destination, derived in specs:
        project_dir.mkdir(parents=True, exist_ok=True)
        run('xcodegen', 'generate', '--spec', spec, '--project', str(project_dir))
        log = BASE / (scheme + '-build.log')
        with log.open('w') as stream:
            run('xcodebuild', '-project', str(project_dir / (scheme + '.xcodeproj')), '-scheme', scheme,
                '-destination', destination, '-derivedDataPath', str(derived / 'DerivedData'),
                '-clonedSourcePackagesDirPath', str(ROOT / '.build/SourcePackages'),
                '-disableAutomaticPackageResolution', '-jobs', '2', 'build', stdout=stream, stderr=subprocess.STDOUT)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--simulator', default='D4B1A386-60E4-4268-A691-2C38E278D540')
    parser.add_argument('--build', action='store_true')
    parser.add_argument('--stop', action='store_true')
    args = parser.parse_args()
    devices = json.loads(output('xcrun', 'simctl', 'list', 'devices', 'available', '-j'))['devices']
    device = next((d for group in devices.values() for d in group if d['udid'] == args.simulator), None)
    if device is None:
        raise RuntimeError('The destination must be an available simulator UDID')
    BASE.mkdir(parents=True, exist_ok=True)
    stop_own_host()
    subprocess.run(['xcrun', 'simctl', 'terminate', args.simulator, APP_ID], capture_output=True)
    if args.stop:
        print('Stopped only the isolated WPS review session.')
        return
    if args.build:
        build()
    app = CLIENT / 'DerivedData/Build/Products/Debug-iphonesimulator/KKRemoteClientReview.app'
    if not HOST_BINARY.exists() or not app.exists():
        raise RuntimeError('Run again with --build to build the isolated applications')
    if device['state'] != 'Booted':
        run('xcrun', 'simctl', 'boot', args.simulator)
    run('xcrun', 'simctl', 'bootstatus', args.simulator, '-b')
    run('xcrun', 'simctl', 'install', args.simulator, str(app))
    config = BASE / 'interactive-config.json'
    config.unlink(missing_ok=True)
    with (BASE / 'host-run.log').open('w') as log:
        process = subprocess.Popen([str(HOST_BINARY), str(BASE)], cwd=ROOT, stdout=log,
                                   stderr=subprocess.STDOUT, start_new_session=True)
    (BASE / 'host.pid').write_text(str(process.pid))
    for _ in range(100):
        if config.exists():
            break
        if process.poll() is not None:
            raise RuntimeError('Review Host exited; inspect host-run.log')
        time.sleep(.1)
    else:
        process.terminate()
        raise RuntimeError('Review Host could not open the named WPS test workbook; inspect host-run.log')
    container = Path(output('xcrun', 'simctl', 'get_app_container', args.simulator, APP_ID, 'data'))
    target = container / 'Documents/WPSInteractiveReview.json'
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(config.read_bytes())
    target.chmod(0o600)
    run('xcrun', 'simctl', 'launch', args.simulator, APP_ID, '--wps-interactive-review')
    print('WPS review ready on simulator', args.simulator, '; isolated Host PID', process.pid)


if __name__ == '__main__':
    main()
