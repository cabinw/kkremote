#!/usr/bin/env python3
"""Counter resets / missing telemetry must never manufacture measured throughput."""
import importlib.util
from pathlib import Path
import unittest
spec=importlib.util.spec_from_file_location('analysis',Path(__file__).resolve().parents[1]/'scripts/analyze-transport-run.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)

def report():
    return {'schemaVersion':10,'build':'test','mediaRoute':'fixed-udp-v2','playout':'realtime','mode':'viewer','videoSource':'remote',
            'samples':[{'seconds':s,'framesDecoded':s*60,'framesEncoded':0,'fps':60,'videoMbps':8,
                        'resources':None,'rtpPayloadBytes':s*1_000_000,'bridge':None} for s in range(1,11)]}

class AnalysisTests(unittest.TestCase):
    def test_missing_resource_and_bridge_stay_unknown(self):
        r=m.analyze(report())
        self.assertEqual(r['fps'],60)
        self.assertEqual(r['actualVideoMbps'],8)
        self.assertIsNone(r['outerApplicationMbps'])
        self.assertIsNone(r['resources']['cpuPercent'])
        self.assertEqual(r['steadyCounterDeltas']['rtpPayloadBytes'],4_000_000)
    def test_reset_is_unknown_not_negative_or_full_session_count(self):
        d=report();d['samples'][-1]['rtpPayloadBytes']=1
        self.assertIsNone(m.analyze(d)['steadyCounterDeltas']['rtpPayloadBytes'])
    def test_memory_windows_exclude_warmup_and_keep_missing_unknown(self):
        samples=[{'seconds':s,'resources':{'physicalFootprintBytes':int((20+min(s,300)/60)*1048576)}} for s in range(1,901)]
        result=m.memory_windows(samples)
        self.assertAlmostEqual(result['after5Minutes']['slopeMiBPerMinute'],0)
        self.assertAlmostEqual(result['last5Minutes']['medianMiB'],25)
        self.assertEqual(len(result['minutes']),15)
        self.assertIsNone(m.memory_windows(report()['samples'])['after30Seconds'])

    def test_no_media_is_not_success(self):
        d=report()
        for s in d['samples']:s['framesDecoded']=0
        self.assertFalse(m.analyze(d)['usable'])
    def test_decoded_counter_reset_is_not_valid_fps(self):
        d=report();d['samples'][-1]['framesDecoded']=10
        self.assertFalse(m.analyze(d)['usable'])

if __name__=='__main__':unittest.main()
