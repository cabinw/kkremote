import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('receiver', Path(__file__).parents[1] / 'scripts/analyze-receiver-trace.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ReceiverTraceAnalysisTests(unittest.TestCase):
    def fixture(self):
        events = []
        def event(stage, ms, observer=None, identity=1):
            value = dict(sequence=len(events), stage=stage, uptimeNs=int(ms * 1e6), rtpTimestamp=123)
            if observer:
                value['observerID'] = observer
            elif identity is not None:
                value['frameID'] = identity
            if stage == 'decodeSubmit':
                value['reason'] = 'key'
            events.append(value)
        for stage, ms in [('decodeSubmit', 10), ('decodeVTSubmit', 11), ('decodeVTOutput', 14), ('decodeOutput', 15), ('rendererCallback', 17)]:
            event(stage, ms)
        for name, delay in [('inline', 0), ('fullscreen', 3)]:
            for stage, ms in [('displayInput', 17), ('displayMainDequeue', 18), ('displayEnqueue', 19)]:
                event(stage, ms + delay, observer=name)
        return dict(events=events, summary=dict(epoch='test', overwritten=0),
                    rtp=dict(overwrittenFrames=0, frames=[dict(direction='inbound', kind='primary', timestamp=123,
                         ssrc=2, packets=2, firstPacketNs=2_000_000, lastPacketNs=8_000_000)]))

    def test_exact_chain_and_observers(self):
        result = module.analyze(self.fixture())
        self.assertEqual(result['exactMatchedDecoderOutputs'], 1)
        self.assertEqual(result['intervals']['decodeCallbackMs']['p95'], 5)
        self.assertEqual(result['intervals']['videoToolboxCallbackMs']['p95'], 3)
        for name, expected in [('inline', 17), ('fullscreen', 20)]:
            self.assertEqual(result['observers'][name]['intervals']['firstIngressToDisplayEnqueueMs']['p95'], expected)

    def test_ambiguous_timestamp_and_unknown_identity(self):
        document = self.fixture()
        document['events'][3].pop('frameID')
        self.assertEqual(module.analyze(document)['exactMatchedDecoderOutputs'], 0)
        document = self.fixture()
        document['events'].append({**document['events'][0], 'sequence': 100})
        self.assertEqual(module.analyze(document)['exactMatchedDecoderOutputs'], 0)

    def test_multiple_ssrc_never_guessed(self):
        document = self.fixture()
        document['rtp']['frames'].append({**document['rtp']['frames'][0], 'ssrc': 3})
        self.assertEqual(module.analyze(document)['intervals']['firstIngressToDecodeSubmitMs'], {'count': 0})

    def test_kernel_timestamp_requires_complete_coverage(self):
        document = self.fixture()
        packet = document['rtp']['frames'][0]
        packet.update(firstKernelArrivalNs=1_000_000, lastKernelArrivalNs=7_000_000,
                      kernelTimestampPackets=2, kernelToBridgeNsMax=1_000_000)
        result = module.analyze(document)
        self.assertEqual(result['intervals']['firstKernelToBridgeMs']['max'], 1)
        packet['kernelTimestampPackets'] = 1
        self.assertEqual(module.analyze(document)['intervals']['firstKernelToBridgeMs'], {'count':0})
        packet['kernelTimestampPackets'] = 2; packet['invalidKernelTimestampPackets'] = 1
        self.assertEqual(module.analyze(document)['intervals']['firstKernelToBridgeMs'], {'count':0})

    def test_negative_interval_excluded(self):
        document = self.fixture(); document['events'][3]['uptimeNs'] = 1
        self.assertEqual(module.analyze(document)['intervals']['decodeCallbackMs'], {'count': 0})

    def test_window_does_not_hide_overflow(self):
        document = self.fixture(); document['summary']['overwritten'] = 200
        selected = module.select_window(document, .01, 0)
        self.assertEqual(selected['summary']['overwritten'], 200)
        self.assertEqual(selected['selection']['seconds'], .01)
        with self.assertRaises(ValueError):
            module.select_window(document, 50)

    def test_mac_renderer_gap_keeps_ingress_and_decode_separate(self):
        document = self.fixture()
        new_events = []
        for e in document['events'][:5]:
            new_events.append({**e, 'sequence':100+e['sequence'], 'rtpTimestamp':124,
                               'frameID':2,'uptimeNs':e['uptimeNs']+200_000_000})
        document['events'] += new_events
        document['rtp']['frames'].append({**document['rtp']['frames'][0], 'timestamp':124,
                                         'firstPacketNs':22_000_000,'lastPacketNs':28_000_000})
        gap = module.analyze(document)['sdkRenderer']['largestGaps'][0]
        self.assertEqual(gap['gapMs'],200)
        self.assertEqual(gap['firstIngressGapMs'],20)
        self.assertEqual(gap['decodeSubmitGapMs'],200)
        self.assertEqual(gap['decodeCallbackMs'],5)


if __name__ == '__main__':
    unittest.main()
