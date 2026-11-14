import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('rtp_analysis', Path(__file__).resolve().parents[1] / 'scripts/analyze-rtp-trace.py')
analysis = importlib.util.module_from_spec(spec)
spec.loader.exec_module(analysis)


def fixture(correction=0):
    events, frames = [], []
    for i in range(5):
        ms = 4_000_000_000_000 + i * 17
        timestamp = ((ms + correction) * 90) & 0xffffffff
        ns = i * 17_000_000
        events.append({'stage': 'encodeOutput', 'rtpTimestamp': timestamp, 'frameID': i, 'uptimeNs': ns})
        frames.append({'ssrc': 1, 'timestamp': (timestamp + 0xfafafafa) & 0xffffffff,
                       'absoluteCaptureNtp': (ms * (1 << 32) + 500) // 1000, 'direction': 'outbound', 'kind': 'primary',
                       'firstPacketNs': ns + 2_000_000, 'lastPacketNs': ns + 3_000_000, 'lastAcceptedNs': ns + 3_500_000,
                       'queueWaitNsMax': 2000, 'drops': {}, 'packets': 1, 'sequences': [i], 'acceptedSequences': [i],
                       'sequenceMetadataOmitted': 0})
    return {'summary': {'epoch': 'test', 'overwritten': 0}, 'clockDomain': 'sender', 'events': events,
            'rtp': {'frames': frames, 'overwrittenFrames': 0}}


class RTPTraceAnalysisTests(unittest.TestCase):
    def test_exact_and_one_ms_calibration(self):
        for correction in [-1, 0, 1]:
            result = analysis.analyze(fixture(correction))
            self.assertEqual(result['matchedEncodedFrames'], 5)
            self.assertEqual(result['mappings'][1]['ntpIntegerClockCorrectionMs'], correction)
            self.assertEqual(result['senderIntervals']['encodedToFirstBridgePacketMs']['p95'], 2)

    def test_unsupported_clock_error_and_conflicting_offset(self):
        self.assertEqual(analysis.analyze(fixture(2))['matchedEncodedFrames'], 0)
        d = fixture(); d['rtp']['frames'][2]['timestamp'] += 1
        self.assertEqual(analysis.analyze(d)['mappings'][1]['status'], 'unknown')
        d = fixture(); d['rtp']['frames'] = d['rtp']['frames'][:2]
        self.assertEqual(analysis.analyze(d)['matchedEncodedFrames'], 0)

    def test_remote_clock_subtraction_forbidden(self):
        d = fixture(); receiver = fixture(); receiver['clockDomain'] = 'another-device'
        receiver['events'] = [{'stage': 'rendererCallback', 'rtpTimestamp': f['timestamp'], 'uptimeNs': f['lastPacketNs'] + 5_000_000} for f in receiver['rtp']['frames']]
        for f in receiver['rtp']['frames']: f['direction'] = 'inbound'
        receiver['rtp']['frames'] = receiver['rtp']['frames'][1:-1]
        result = analysis.analyze(d, receiver)['receiver']
        self.assertEqual(result['sameProcessEncodedToRendererMs']['count'], 0)
        self.assertEqual(result['primarySequencesNotSeen'], 0)
        self.assertEqual(result['senderFrameGroupsOutsideReceiverCoverage'], 2)

    def test_gap_evidence_uses_local_intervals(self):
        sender = fixture(); receiver = fixture()
        receiver['clockDomain'] = 'another-device'
        for f in receiver['rtp']['frames']:
            f['direction'] = 'inbound'
            f['firstPacketNs'] += 9_000_000_000
        receiver['events'] = [{'stage': 'rendererCallback', 'rtpTimestamp': f['timestamp'],
                               'uptimeNs': f['firstPacketNs'] + 5_000_000} for f in receiver['rtp']['frames']]
        result = analysis.analyze(sender, receiver)['receiver']
        row = result['largestRendererGaps'][0]
        self.assertEqual(row['senderEncodedIntervalMs'], 17)
        self.assertEqual(row['receiverFirstPrimaryIntervalMs'], 17)
        self.assertEqual(row['currentFirstPrimaryToRendererMs'], 5)
        self.assertEqual(result['sameProcessEncodedToRendererMs']['count'], 0)


if __name__ == '__main__': unittest.main()
