#!/usr/bin/env python3
"""Recover a complete single-epoch report from a bounded asynchronous CLI journal."""
import argparse
import hashlib
import json
from pathlib import Path


def reconstruct(report, data):
    status = report.get('sampleJournal') or {}
    if status.get('closed') is not True or any(status.get(k) != 0 for k in ['pending', 'dropped', 'writeFailures']):
        raise ValueError('Journal did not close without loss')
    if not data.endswith(b'\n'):
        raise ValueError('Journal has an incomplete final record')
    records = [json.loads(line) for line in data.splitlines()]
    if not records or [r.get('sequence') for r in records] != list(range(len(records))):
        raise ValueError('Missing, repeated or reordered journal sequence')
    if status.get('written') != len(records) or status.get('submitted') != len(records):
        raise ValueError('Journal count does not match final report')
    samples = [r['sample'] for r in records]
    counter = 'framesEncoded' if report['mode'] == 'host' else 'framesDecoded'
    if any(b['seconds'] <= a['seconds'] or b[counter] < a[counter] for a, b in zip(samples, samples[1:])):
        raise ValueError('Clock or media epoch reset; never merge separate sessions')
    retained = report.get('samples', [])
    if not retained or retained != samples[-len(retained):]:
        raise ValueError('Final retained report differs from journal tail')
    return {**report, 'samples': samples,
            'sampleJournalReconstruction': {'schemaVersion': 1, 'sha256': hashlib.sha256(data).hexdigest(),
                                             'records': len(records), 'originalRetainedRecords': len(retained),
                                             'sequenceContinuous': True, 'tailMatchesFinalReport': True},
            'notes': report.get('notes', []) + ['Full sample history reconstructed from the process-local ordered JSONL journal; final report and every sequence verified.']}


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--report', type=Path, required=True); p.add_argument('--journal', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    a = p.parse_args()
    result = reconstruct(json.loads(a.report.read_text()), a.journal.read_bytes())
    a.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(result['sampleJournalReconstruction']))
