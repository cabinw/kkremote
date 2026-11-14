import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("trace_analysis", Path(__file__).resolve().parents[1] / "scripts/analyze-frame-trace.py")
analysis = importlib.util.module_from_spec(spec)
spec.loader.exec_module(analysis)


class FrameTraceAnalysisTests(unittest.TestCase):
    def test_no_timestamp_proximity_match_and_wrap(self):
        events = []
        def add(stage, time, **fields):
            events.append(dict(sequence=len(events), stage=stage, uptimeNs=time, **fields))
        add("sourceSubmit", 1_000_000, frameID=1, ptsNs=999_999)
        add("encodeSubmit", 2_000_000, frameID=1, ptsNs=1_004_000, rtpTimestamp=2**32 - 1, reason="exact_wrapper_identity")
        add("encodeOutput", 6_000_000, frameID=1, rtpTimestamp=2**32 - 1)
        add("sourceSubmit", 17_000_000, frameID=2, ptsNs=17_000_000)
        add("encodeSubmit", 17_000_001, ptsNs=17_000_001, rtpTimestamp=0, reason="source_identity_unknown")
        add("encodeOutput", 21_000_000, rtpTimestamp=0)
        add("sourceSubmit", 3_000_000_000, frameID=3)
        result = analysis.analyze({"summary": {"overwritten": 8}, "events": events})
        self.assertEqual(result["intervals"]["sourceToEncoderMs"], {"count": 1, "p50": 1, "p95": 1, "max": 1})
        self.assertEqual(result["intervals"]["encoderCallbackMs"]["p95"], 4)
        self.assertEqual(result["encoderInputsWithoutSourceIdentity"], 1)
        self.assertEqual(result["sourceWithoutEncoderAfterTwoSecondsUnknown"], 1)
        self.assertEqual(result["trace"]["overwritten"], 8)
        self.assertFalse(any("drops" in key.lower() for key in result))

    def test_ambiguous_identity_is_not_used(self):
        events = [dict(sequence=i, uptimeNs=i, stage=stage, frameID=1, reason="exact_wrapper_identity")
                  for i, stage in enumerate(["sourceSubmit", "sourceSubmit", "encodeSubmit", "encodeOutput"])]
        result = analysis.analyze({"summary": {}, "events": events})
        self.assertEqual(result["ambiguousFrameIdentities"], 1)
        self.assertEqual(result["intervals"]["sourceToEncoderMs"]["count"], 0)


if __name__ == "__main__":
    unittest.main()
