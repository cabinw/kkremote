#!/usr/bin/env python3
"""Correlate a bounded sender/receiver incident by exact primary RTP identity, never subtract peer clocks."""
import argparse
from collections import defaultdict
import importlib.util
import json
from pathlib import Path

spec=importlib.util.spec_from_file_location('receiver_analysis',Path(__file__).with_name('analyze-receiver-trace.py'))
receiver=importlib.util.module_from_spec(spec);spec.loader.exec_module(receiver)

def analyze(sender_document,receiver_document):
    host=sender_document.get('trace',sender_document);viewer=receiver_document.get('trace',receiver_document)
    if host['role']!='sender' or viewer['role']!='receiver':raise ValueError('Sender and receiver roles required')
    def index(document,direction):
        groups=defaultdict(list)
        for frame in document['rtp']['frames']:
            if frame['direction']==direction and frame['kind']=='primary':
                groups[(frame['ssrc'],frame['timestamp'])].append(frame)
        return {key:values[0] for key,values in groups.items() if len(values)==1}
    incoming=index(viewer,'inbound');outgoing=index(host,'outbound')
    rows=[]
    for gap in receiver.analyze(viewer)['sdkRenderer']['largestGaps']:
        row=dict(gap);keys=[key for key in incoming if key[1]==gap['rtpTimestamp']]
        row['exactPrimaryPairMatched']=False
        if len(keys)==1:
            current=keys[0];previous=(current[0],gap['previousRTP'])
            if all(k in outgoing and k in incoming for k in [previous,current]):
                a,b=outgoing[previous],outgoing[current]
                row['exactPrimaryPairMatched']=True
                row['primarySSRC']=current[0]
                for field in ['firstPacketNs','lastPacketNs','firstAcceptedNs','lastAcceptedNs']:
                    if field in a and field in b:
                        row['sender'+field[:-2][0].upper()+field[:-2][1:]+'GapMs']=(b[field]-a[field])/1e6
                row['senderQueueWaitMaxMs']=b['queueWaitNsMax']/1e6
                row['senderAdapterResidenceMaxMs']=b['adapterResidenceNsMax']/1e6
                row['matchingCompleteSequenceSets']=all(
                    outgoing[k].get('sequenceMetadataOmitted',0)==0 and incoming[k].get('sequenceMetadataOmitted',0)==0
                    and len(outgoing[k]['sequences'])==outgoing[k]['packets']
                    and len(incoming[k]['sequences'])==incoming[k]['packets']
                    and sorted(outgoing[k]['sequences'])==sorted(outgoing[k]['acceptedSequences'])==sorted(incoming[k]['sequences'])
                    and not outgoing[k]['droppedSequences'] for k in [previous,current])
        rows.append(row)
    return {'schemaVersion':1,'senderEpoch':host['summary']['epoch'],'receiverEpoch':viewer['summary']['epoch'],
            'senderReason':sender_document.get('reason'),'receiverReason':receiver_document.get('reason'),
            'gaps':rows,'limits':[
                'Each delta uses one local clock. Cross-peer absolute clocks are never subtracted.',
                'Accepted means local socket/API accepted data, not physical transmission.',
                'Kernel timestamp means Darwin IP-stack delivery; does not reveal outer Ponte/NIC arrival.',
                'Incident snapshots are bounded and captured at different times; missing identities remain unmatched.',
                'SDK renderer callbacks are not physical presentation. Source guard validity must be checked separately.']}

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--sender',type=Path,required=True);p.add_argument('--receiver',type=Path,required=True);p.add_argument('--output',type=Path,required=True)
    a=p.parse_args();a.output.write_text(json.dumps(analyze(json.loads(a.sender.read_text()),json.loads(a.receiver.read_text())),ensure_ascii=False,indent=2)+'\n')
