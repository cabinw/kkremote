#!/usr/bin/env python3
"""Summarize transport reports without treating SDK callbacks as physical presentation."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import statistics

spec=importlib.util.spec_from_file_location('suite',Path(__file__).with_name('benchmark-transport-suite.py'))
suite=importlib.util.module_from_spec(spec);spec.loader.exec_module(suite)

def segment(samples, start, end):
    rows=[s for s in samples if start <= s['seconds'] <= end]
    if len(rows)<2:return None
    # summarize() itself discards 5 seconds of initial progression; preserve that explicit rule.
    return suite.summarize({'samples':rows})

def memory_windows(samples):
    points = [(s['seconds'],s['resources']['physicalFootprintBytes']/1048576)
              for s in samples if (s.get('resources') or {}).get('physicalFootprintBytes') is not None]
    def window(rows):
        if len(rows) < 2: return None
        xs,ys = zip(*rows); xm,ym = statistics.mean(xs),statistics.mean(ys)
        denominator = sum((x-xm)**2 for x in xs)
        return {'samples':len(rows), 'startSeconds':xs[0], 'endSeconds':xs[-1],
                'medianMiB':statistics.median(ys), 'minMiB':min(ys), 'maxMiB':max(ys),
                'slopeMiBPerMinute':sum((x-xm)*(y-ym) for x,y in rows)/denominator*60 if denominator else None}
    end = max((t for t,_ in points),default=0)
    return {'after30Seconds':window([(t,y) for t,y in points if t>=30]),
            'after5Minutes':window([(t,y) for t,y in points if t>=300]),
            'last5Minutes':window([(t,y) for t,y in points if t>=end-300]) if end>=600 else None,
            'minutes':[{'minute':i,**w} for i in range(int(end//60)+1)
                       if (w:=window([(t,y) for t,y in points if i*60<=t<(i+1)*60]))]}

def analyze(document):
    result=suite.summarize(document)
    if not result['usable']:return result
    samples=[s for s in document['samples'] if s['framesDecoded'] or s['framesEncoded']]
    result['memoryWindows']=memory_windows(samples)
    result['historyLimit']=document.get('historyLimit')
    result['sampleJournalReconstruction']=document.get('sampleJournalReconstruction')
    result['reportSchemaVersion']=document['schemaVersion']
    result['build']=document['build'];result['route']=document['mediaRoute'];result['playout']=document['playout']
    result['mode']=document['mode'];result['source']=document['videoSource']
    result['outerPath']=document.get('actualOverlayPath','unknown')
    result['first5Minutes']=segment(samples,samples[0]['seconds'],samples[0]['seconds']+300)
    if samples[-1]['seconds']-samples[0]['seconds']>=600:
        result['last5Minutes']=segment(samples,samples[-1]['seconds']-300,samples[-1]['seconds'])
        def median_footprint(section):
            return (section.get('resources',{}).get('physicalFootprintBytes') or {}).get('p50')
        first,last=map(median_footprint,[result['first5Minutes'],result['last5Minutes']])
        result['footprintMedianChangeBytes']=last-first if first is not None and last is not None else None
    points=[(s['seconds'],s['resources']['physicalFootprintBytes']) for s in samples if (s.get('resources') or {}).get('physicalFootprintBytes') is not None and s['seconds']>=30]
    if len(points)>=10:
        xs,ys=zip(*points);xm=statistics.mean(xs);ym=statistics.mean(ys)
        result['footprintSlopeBytesPerMinute']=sum((x-xm)*(y-ym) for x,y in points)/sum((x-xm)**2 for x in xs)*60
    result['queuePendingMax']=max((s.get('bridge',{}).get('pendingPackets',0) for s in samples if s.get('bridge')),default=None)
    result['queueAgeMaxMs']=max((s['bridge']['maxQueueAgeMilliseconds'] for s in samples if s.get('bridge')),default=None)
    start=next((s for s in samples if s['seconds']>=samples[0]['seconds']+5),samples[0]);end=samples[-1]
    span=end['seconds']-start['seconds']
    result['mediaObservedSeconds']=end['seconds']-samples[0]['seconds']
    def delta(path):
        a,b=start,end
        for key in path:
            a=(a or {}).get(key);b=(b or {}).get(key)
        return b-a if a is not None and b is not None and b>=a else None
    counters={key:delta([key]) for key in ['rtpPayloadBytes','rtpHeaderBytes','retransmittedPayloadBytes','retransmittedPacketsReceived','retransmittedPacketsSent','sourceFrames','freezeCount','framesDropped','nackCount','pliCount']}
    direction='sentWireBytes' if document['mode']=='host' else 'receivedWireBytes'
    wire=delta(['bridge',direction])
    result['steadyCounterDeltas']=counters
    result['outerApplicationMbps']=wire*8/span/1e6 if wire is not None and span>0 else None
    result['sourceFPS']=counters['sourceFrames']/span if counters['sourceFrames'] is not None and document['mode']=='host' and span>0 else None
    result['qualityLimitationReasons']=sorted({s.get('qualityLimitationReason','unknown') for s in samples})
    result['lowPowerModeObserved']=any((s.get('resources') or {}).get('lowPowerMode',False) for s in samples)
    result['limits']=['RTP/codec/decode/renderer counters are not physical screen presentation.',
                      'First/last segment summaries each exclude their first 5 seconds.',
                      'Resource metrics describe this process only; slope alone is not proof of a leak.',
                      'Frozen/framesDropped are cumulative SDK counters; latest replacements are separate.',
                      'Network labels do not verify the outer overlay topology.',
                      'Outer application Mbps counts encapsulated UDP payload only; IP/UDP headers and Surge overhead are excluded.',
                      'playout is this process sender policy, not the remote sender policy; inspect host report for phone comparisons.']
    return result

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('report',type=Path);p.add_argument('--output',type=Path,required=True)
    a=p.parse_args();data=a.report.read_bytes();r=analyze(json.loads(data));r['reportSHA256']=hashlib.sha256(data).hexdigest()
    a.output.write_text(json.dumps(r,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps({k:r.get(k) for k in ['build','seconds','fps','actualVideoMbps','thermalStates','queuePendingMax','footprintMedianChangeBytes']},ensure_ascii=False))
