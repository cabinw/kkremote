import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

class CaptureGuardTests(unittest.TestCase):
    def run_guard(self, matching_title=True, matching_owner=True, persistent=False, display_mode=None):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory).resolve()
            app = folder / 'fake-catalog'
            app.write_text('#!' + sys.executable + '\n' +
                'import sys,json,time\nfrom pathlib import Path\n' +
                'if "--list-windows" in sys.argv:\n' +
                ' Path(sys.argv[sys.argv.index("--report")+1]).write_text(json.dumps(' +
                repr([{'id':7,'application':'Google Chrome','title':'KKRemote Repeatable Load Fixture' if matching_title else 'Changed',
                       'widthPoints':1280,'heightPoints':720}]) + '))\n' +
                'else: time.sleep(30)\n')
            app.chmod(0o700)
            host = subprocess.Popen([str(app), str(folder)])
            try:
                report = folder / 'guard.json'
                additional=[]
                if persistent:
                    helper=folder/'identity-probe'
                    value={'found':True,'application':'Google Chrome','title':'KKRemote Repeatable Load Fixture' if matching_title else 'Changed','dimensionsPoints':[1280,720]}
                    if display_mode:
                        value.update(displayObservationComplete=True,displays=[{'id':1,'modePixels':[2560,1440],'modePoints':[1280,720],'nominalRefreshHz':60}])
                    rows=[value.copy() for _ in range(50)]
                    if display_mode == 'changed':
                        for row in rows[1:]: row['displays']=[dict(value['displays'][0],nominalRefreshHz=120)]
                    if display_mode == 'missing':
                        for row in rows[1:]: row.pop('displayObservationComplete');row.pop('displays')
                    if display_mode == 'unavailable':
                        for row in rows: row['displayObservationComplete']=False
                    if display_mode == 'bad-size':
                        for row in rows: row['dimensionsPoints']=None
                    if display_mode == 'bad-display':
                        for row in rows: row['displays']=[{}]
                    helper.write_text('#!'+sys.executable+'\nimport json,time\nfor row in '+repr(rows)+':\n print(json.dumps(row),flush=True)\n time.sleep(.05)\n')
                    helper.chmod(0o700);additional=['--identity-probe',str(helper)]
                result = subprocess.run([sys.executable,str(ROOT/'scripts/capture-source-guard.py'),
                    '--app',str(app),'--window-id','7','--pid',str(host.pid),'--process-marker',str(folder) if matching_owner else '/not-owned',
                    '--report',str(report),'--seconds','1']+additional,timeout=8)
                data = json.loads(report.read_text())
                if (not matching_title or display_mode in ['changed','missing','unavailable','bad-size','bad-display']) and matching_owner: host.wait(timeout=3)
                return result.returncode, data, host.poll()
            finally:
                if host.poll() is None: host.terminate(); host.wait(timeout=3)

    def test_valid_identity(self):
        code,report,host = self.run_guard()
        self.assertEqual(code,0); self.assertTrue(report['valid']); self.assertTrue(report['samples']); self.assertIsNone(host)

    def test_changed_identity_stops_owned_host(self):
        code,report,host = self.run_guard(False)
        self.assertEqual(code,2); self.assertFalse(report['valid']); self.assertIsNotNone(host)
        self.assertNotIn('Changed', json.dumps(report))

    def test_does_not_signal_unrelated_pid(self):
        code,report,host = self.run_guard(False,False)
        self.assertEqual(code,0); self.assertEqual(report['samples'],[]); self.assertIsNone(host)
    def test_persistent_probe(self):
        code,report,host=self.run_guard(persistent=True)
        self.assertEqual(code,0);self.assertTrue(report['valid']);self.assertIsNone(host)
        self.assertEqual(report['method'],'persistent-coregraphics-metadata')
    def test_persistent_probe_rejects_changed_title(self):
        code,report,host=self.run_guard(False,persistent=True)
        self.assertEqual(code,2);self.assertFalse(report['valid']);self.assertIsNotNone(host)

    def test_display_mode_stable(self):
        code,report,host=self.run_guard(persistent=True,display_mode='stable')
        self.assertEqual(code,0);self.assertTrue(report['displayGuardAvailable']);self.assertIsNone(host)

    def test_refresh_changed_without_window_resize(self):
        code,report,host=self.run_guard(persistent=True,display_mode='changed')
        self.assertEqual(code,2);self.assertFalse(report['valid']);self.assertIsNotNone(host)
        self.assertFalse(report['samples'][-1]['displayMatched'])

    def test_display_metadata_cannot_silently_disappear(self):
        code,report,host=self.run_guard(persistent=True,display_mode='missing')
        self.assertEqual(code,2);self.assertFalse(report['valid']);self.assertIsNotNone(host)

    def test_display_query_failure_invalidates(self):
        code,report,host=self.run_guard(persistent=True,display_mode='unavailable')
        self.assertEqual(code,2);self.assertFalse(report['valid']);self.assertIsNotNone(host)

    def test_malformed_metadata_stops_only_owned_host(self):
        for mode in ['bad-size','bad-display']:
            with self.subTest(mode=mode):
                code,report,host=self.run_guard(persistent=True,display_mode=mode)
                self.assertEqual(code,2);self.assertFalse(report['valid']);self.assertIsNotNone(host)

if __name__ == '__main__': unittest.main()
