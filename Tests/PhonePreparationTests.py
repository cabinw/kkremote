#!/usr/bin/env python3
"""A simulated USB failure must stop only the test host it just created."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


class PhonePreparationTests(unittest.TestCase):
    def test_failed_usb_launch_releases_host(self):
        script = Path(__file__).resolve().parents[1] / 'scripts/prepare-phone-transport-run.py'
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            host = root / 'fake-host'
            host.write_text('#!' + sys.executable + '\nimport time\ntime.sleep(60)\n')
            host.chmod(0o700)
            xcrun = root / 'xcrun'
            xcrun.write_text('#!/bin/sh\nexit 42\n')
            xcrun.chmod(0o700)
            key = root / 'fixture.key'; key.write_text('fixture-only')
            state = root / 'state.json'
            env = dict(os.environ, PATH=str(root) + os.pathsep + os.environ['PATH'])
            result = subprocess.run([sys.executable, str(script), '--app', str(host), '--key-file', str(key),
                                     '--directory', str(root / 'runs'), '--state', str(state), '--window-id', '1',
                                     '--device', 'SIMULATED-NO-DEVICE', '--name', 'failed-launch', '--duration', '30'],
                                    env=env, capture_output=True, text=True, timeout=15)
            self.assertNotEqual(result.returncode, 0)
            self.assertTrue((root / 'runs/failed-launch/PREPARATION_FAILED.json').is_file())
            pid = json.loads(state.read_text())['pid']
            with self.assertRaises(ProcessLookupError): os.kill(pid, 0)


if __name__ == '__main__':
    unittest.main()
