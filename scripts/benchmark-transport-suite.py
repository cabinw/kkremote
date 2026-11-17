#!/usr/bin/env python3
"""Sequential, isolated real-window loopbacks; saves failures as well as successful cases."""
import argparse
import hashlib
import json
from pathlib import Path
import resource
import subprocess
import time

def summarize(report):
    samples = report['samples']
    active = [s for s in samples if s['framesDecoded'] or s['framesEncoded']]
    if len(active) < 2:
        return {'usable': False}
    start = next((s for s in active if s['seconds'] >= active[0]['seconds'] + 5), active[0])
    end = active[-1]
    duration = end['seconds'] - start['seconds']
    counter = 'framesDecoded' if end['framesDecoded'] else 'framesEncoded'
    window = [s for s in active if start['seconds'] <= s['seconds'] <= end['seconds']]
    if any(b['seconds'] <= a['seconds'] or b[counter] < a[counter] for a,b in zip(window,window[1:])):
        return {'usable': False, 'reason': 'Non-monotonic clock or media counter reset; split epochs before analysis.'}
    weighted = sum(b['videoMbps'] * (b['seconds'] - a['seconds']) for a, b in zip(window, window[1:]))
    def quantiles(values):
        import math
        values = sorted(values)
        return None if not values else {'p50': values[math.ceil(len(values)*.5)-1], 'p95':values[math.ceil(len(values)*.95)-1], 'max':max(values), 'min':min(values)}
    return {'usable': duration > 0, 'seconds': end['seconds'], 'steadySeconds':duration,
        'fps': (end[counter]-start[counter])/duration if duration else None,
        'actualVideoMbps': weighted/duration if duration else None,
        'oneSecondMbps':quantiles([s['videoMbps'] for s in window]),
        'fractionSamplesAtLeast15Mbps':sum(s['videoMbps']>=15 for s in window)/len(window),
        'frameGapMs':quantiles([s['frameGapMaxMilliseconds'] for s in window if s.get('frameGapMaxMilliseconds') is not None]),
        'frameGapStatistic':'Quantiles of per-sample maximum renderer callback gaps, not quantiles of all frames.',
        'controlRTTMs':quantiles([s['controlRTTMilliseconds'] for s in window if s.get('controlRTTMilliseconds') is not None]),
        'jitterBufferMs':quantiles([s['jitterBufferMilliseconds'] for s in window if s.get('jitterBufferMilliseconds') is not None]),
        'resources':{key:quantiles([s['resources'][key] for s in window if (s.get('resources') or {}).get(key) is not None]) for key in ['cpuPercent','residentBytes','physicalFootprintBytes']},
        'thermalStates':sorted({s['resources']['thermalState'] for s in window if s.get('resources')}),
        'tailFPS':sum(s['fps'] for s in window[-10:])/len(window[-10:]),
        'last':{k:end.get(k) for k in ['codec','width','height','framesDecoded','framesEncoded','framesDropped','freezeCount','packetsLost','nackCount','pliCount','encoderDetails','captureDetails','receiverDetails','bridge']}}

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app',type=Path,required=True)
    parser.add_argument('--directory',type=Path,required=True)
    parser.add_argument('--window-id',type=int,required=True)
    parser.add_argument('--duration',type=int,default=40)
    parser.add_argument('--cases',nargs='+',default=['off1','on1','on2','off2','loss1','loss3','outage200','outage1200','jitter','bandwidth-drop'])
    parser.add_argument('--pacing',choices=['interactive','smooth'],default='interactive')
    parser.add_argument('--playout',choices=['adaptive','realtime'],default='realtime')
    parser.add_argument('--sdr',action='store_true')
    parser.add_argument('--capture-depth',type=int,choices=[3,5,8],default=3)
    args=parser.parse_args()
    if not 30<=args.duration<=3600:parser.error('duration must be 30...3600')
    allowed={'off1','off2','on1','on2','loss1','loss3','outage200','outage1200','jitter','bandwidth-drop'}
    if not set(args.cases)<=allowed:parser.error('Unknown case')
    args.directory.mkdir(parents=True,exist_ok=True)
    fixture=Path(__file__).resolve().parents[1]/'Tests/Fixtures/window-capture/high-load.html'
    (args.directory/'fixture.html').write_bytes(fixture.read_bytes())
    manifest={'scope':'single-Mac real-window loopback; not remote Ponte','width':2560,'height':1440,'fps':60,'ceilingMbps':20,
              'hdrRequested':not args.sdr,'playout':args.playout,'pacing':args.pacing,'captureDepth':args.capture_depth,'binarySHA256':hashlib.sha256(args.app.read_bytes()).hexdigest(),
              'fixtureSHA256':hashlib.sha256(fixture.read_bytes()).hexdigest(),'cases':[]}
    for name in args.cases:
        folder=args.directory/name;folder.mkdir(exist_ok=False)
        impairment=name if name in allowed-{'off1','off2','on1','on2'} else 'none'
        enabled=not name.startswith('off')
        command=[str(args.app.resolve()),'--self-test','--duration',str(args.duration),'--window-id',str(args.window_id),
                 '--resolution','2560x1440','--fps','60','--mbps','20','--route','fixed-udp-v2','--bridge-transport','socket',
                 '--playout',args.playout,'--pacing',args.pacing,'--port','56090','--media-port','56091',
                 '--report',str(folder/'viewer.json'),'--host-report',str(folder/'host.json'),'--diagnostic-impairment',impairment]
        if enabled:command+=['--frame-trace-dir',str(folder/'trace')]
        if args.capture_depth != 3:command+=['--capture-depth',str(args.capture_depth)]
        if not args.sdr:command+=['--hdr']
        before=resource.getrusage(resource.RUSAGE_CHILDREN);start=time.monotonic()
        with (folder/'run.log').open('w') as log:
            try:code=subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,timeout=args.duration+45).returncode
            except subprocess.TimeoutExpired:code='timeout'
        after=resource.getrusage(resource.RUSAGE_CHILDREN)
        case={'name':name,'impairment':impairment,'traceEnabled':enabled,'exitCode':code,'wallSeconds':time.monotonic()-start,
              'processCPUSeconds':after.ru_utime+after.ru_stime-before.ru_utime-before.ru_stime}
        for role in ['host','viewer']:
            path=folder/(role+'.json')
            if path.exists():case[role]=summarize(json.loads(path.read_text()))
        manifest['cases'].append(case)
        (args.directory/'summary.json').write_text(json.dumps(manifest,indent=2)+'\n')
        v=case.get('viewer',{});print(json.dumps({'case':name,'exit':code,'fps':v.get('fps'),'Mbps':v.get('actualVideoMbps'),'tailFPS':v.get('tailFPS'),'loss':v.get('last',{}).get('packetsLost')}),flush=True)
    return 1 if any(c['exitCode']!=0 for c in manifest['cases']) else 0

if __name__=='__main__':raise SystemExit(main())
