#!/usr/bin/env python3
import copy
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('trial', Path(__file__).resolve().parents[1] / 'scripts/evaluate-transport-trial.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


def fixture():
    base = {'schemaVersion': 10, 'build': 'test', 'mediaRoute': 'direct-ice', 'playout': 'realtime', 'videoSource': 'fixture',
            'samples': [{'seconds': t, 'framesEncoded': 0, 'framesDecoded': t * 60, 'fps': 60, 'videoMbps': 16,
                         'width': 2560, 'height': 1440, 'codec': 'video/H265', 'freezeCount': 0, 'framesDropped': 0}
                        for t in range(1, 61)]}
    viewer = dict(base, mode='viewer')
    host = copy.deepcopy(dict(base, mode='host'))
    for s in host['samples']:
        s['framesEncoded'] = s['framesDecoded']; s['framesDecoded'] = 0
    guard = {'valid': True, 'monitorCompleted': True,
             'samples': [{'elapsedSeconds': t, 'identityMatched': True} for t in range(0, 61, 10)]}
    return host, viewer, guard


class TrialTests(unittest.TestCase):
    def test_full_valid_session(self):
        self.assertTrue(m.evaluate(*fixture(), 60)['transportTrialPassed'])

    def test_freeze_in_warmup_is_not_hidden(self):
        h, v, g = fixture()
        for row in v['samples'][1:]: row['freezeCount'] = 1
        self.assertIn('viewer_zero_freezes', m.evaluate(h, v, g, 60)['failedChecks'])

    def test_last_five_samples_are_not_a_long_run(self):
        h, v, g = fixture(); h['samples'] = h['samples'][-5:]
        self.assertIn('host_duration', m.evaluate(h, v, g, 60)['failedChecks'])

    def test_unfinished_guard_cannot_pass(self):
        h, v, g = fixture(); g.pop('monitorCompleted')
        self.assertIn('source_guard_complete', m.evaluate(h, v, g, 60)['failedChecks'])

    def test_late_guard_gap_is_invalid(self):
        h, v, g = fixture(); g['samples'] = g['samples'][:3]
        self.assertIn('source_guard_coverage', m.evaluate(h, v, g, 60)['failedChecks'])

    def test_internal_guard_gap_is_invalid(self):
        h, v, g = fixture(); g['samples'] = [g['samples'][0], g['samples'][-1]]
        self.assertIn('source_guard_continuity', m.evaluate(h, v, g, 60)['failedChecks'])

    def test_guard_clock_reversal_is_invalid(self):
        h, v, g = fixture(); g['samples'][2]['elapsedSeconds'] = 5
        self.assertIn('source_guard_continuity', m.evaluate(h, v, g, 60)['failedChecks'])

    def test_network_pending_includes_inflight(self):
        h, v, g = fixture()
        for report in [h, v]:
            report['mediaRoute'] = 'fixed-udp-v2'
            for row in report['samples']:
                row['bridge'] = {'transport': 'network', 'pendingPackets': 288,
                                 'queueOverflowDrops': 0, 'queueDeadlineDrops': 0, 'maxQueueAgeMilliseconds': 1}
        self.assertTrue(m.evaluate(h, v, g, 60)['transportTrialPassed'])
        for row in v['samples']: row['bridge']['pendingPackets'] = 289
        self.assertIn('viewer_bounded_bridge', m.evaluate(h, v, g, 60)['failedChecks'])

    def test_socket_has_no_network_inflight_allowance(self):
        h, v, g = fixture(); v['mediaRoute'] = 'fixed-udp-v2'
        for row in v['samples']:
            row['bridge'] = {'transport': 'socket', 'pendingPackets': 257,
                             'queueOverflowDrops': 0, 'queueDeadlineDrops': 0, 'maxQueueAgeMilliseconds': 1}
        self.assertIn('viewer_bounded_bridge', m.evaluate(h, v, g, 60)['failedChecks'])

    def test_resolution_fallback_is_not_1440p_pass(self):
        h, v, g = fixture(); v['samples'][30]['width'] = 1280
        self.assertIn('viewer_dimensions', m.evaluate(h, v, g, 60)['failedChecks'])

    def test_reset_in_warmup_is_not_hidden(self):
        h, v, g = fixture(); v['samples'][3]['framesDecoded'] = 1
        self.assertIn('viewer_continuous_epoch', m.evaluate(h, v, g, 60)['failedChecks'])

    def test_viewer_report_cannot_replace_host(self):
        _, v, g = fixture()
        self.assertIn('host_role', m.evaluate(v, v, g, 60)['failedChecks'])

    def test_different_codecs_cannot_be_one_media_session(self):
        h, v, g = fixture()
        for row in h['samples']: row['codec'] = 'video/H264'
        self.assertIn('matching_codec', m.evaluate(h, v, g, 60)['failedChecks'])


if __name__ == '__main__':
    unittest.main()
