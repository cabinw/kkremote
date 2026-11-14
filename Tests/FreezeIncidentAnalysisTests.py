import importlib.util
from pathlib import Path
import unittest
spec=importlib.util.spec_from_file_location('incident',Path(__file__).parents[1]/'scripts/analyze-freeze-incident.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)

def fixture():
    host={'role':'sender','summary':{'epoch':'s','overwritten':0},'rtp':{'frames':[],'overwrittenFrames':0},'events':[]}
    viewer={'role':'receiver','summary':{'epoch':'v','overwritten':0},'rtp':{'frames':[],'overwrittenFrames':0},'events':[]}
    for i in range(2):
        f=dict(ssrc=5,timestamp=i,kind='primary',packets=1,sequences=[i],acceptedSequences=[i],droppedSequences=[],queueWaitNsMax=100,adapterResidenceNsMax=200)
        host['rtp']['frames'].append(dict(f,direction='outbound',firstPacketNs=10**12+i*16_000_000,lastPacketNs=10**12+i*16_000_000,firstAcceptedNs=10**12+i*16_000_000,lastAcceptedNs=10**12+i*16_000_000))
        ns=10**9+i*200_000_000
        viewer['rtp']['frames'].append(dict(f,direction='inbound',firstPacketNs=ns,lastPacketNs=ns,firstKernelArrivalNs=ns-100_000,lastKernelArrivalNs=ns-100_000,kernelTimestampPackets=1))
        for j,stage in enumerate(['decodeSubmit','decodeOutput','rendererCallback']):
            viewer['events'].append(dict(sequence=len(viewer['events']),stage=stage,uptimeNs=ns+j*1_000_000,rtpTimestamp=i,frameID=i,reason='delta'))
    return host,viewer

class IncidentTests(unittest.TestCase):
    def test_distinct_clocks_compare_only_local_gaps(self):
        h,v=fixture();g=m.analyze(h,v)['gaps'][0]
        self.assertTrue(g['exactPrimaryPairMatched']);self.assertTrue(g['matchingCompleteSequenceSets'])
        self.assertEqual(g['senderFirstAcceptedGapMs'],16)
        self.assertEqual(g['firstKernelArrivalGapMs'],200)
    def test_ssrc_mismatch_never_guessed(self):
        h,v=fixture();h['rtp']['frames'][0]['ssrc']=9
        self.assertFalse(m.analyze(h,v)['gaps'][0]['exactPrimaryPairMatched'])
    def test_incomplete_sequence_metadata_not_complete(self):
        h,v=fixture();h['rtp']['frames'][0]['sequenceMetadataOmitted']=1
        self.assertFalse(m.analyze(h,v)['gaps'][0]['matchingCompleteSequenceSets'])
    def test_wrong_roles_rejected(self):
        h,v=fixture()
        with self.assertRaises(ValueError):m.analyze(v,h)
if __name__=='__main__':unittest.main()
