#!/usr/bin/env python3
"""Prepare one authorized USB phone experiment; never modifies the endpoint or pairing file."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import time

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--app',type=Path,required=True)
p.add_argument('--key-file',type=Path,required=True)
p.add_argument('--directory',type=Path,required=True)
p.add_argument('--state',type=Path,required=True)
p.add_argument('--window-id',type=int,required=True)
p.add_argument('--expected-window-title',help='Stop host if captured test window identity changes')
p.add_argument('--identity-probe',type=Path,help='Signed metadata-only source identity helper')
p.add_argument('--device',required=True)
p.add_argument('--name',required=True)
p.add_argument('--duration',type=int,default=60)
p.add_argument('--impairment',choices=['none','loss1','loss3','outage200','outage1200','jitter','bandwidth-drop'],default='none')
p.add_argument('--pacing',choices=['interactive','smooth'],default='interactive')
p.add_argument('--playout',choices=['adaptive','realtime'],default='realtime')
p.add_argument('--frame-trace',action='store_true')
p.add_argument('--port',type=int,default=45990)
p.add_argument('--media-port',type=int,default=45991)
a=p.parse_args()
import re
if not re.fullmatch(r'[A-Za-z0-9_-]{1,60}',a.name) or not 30<=a.duration<=1800:
    p.error('safe run name and duration 30...1800 required')
binary=a.app.resolve(strict=True);key=a.key_file.resolve(strict=True)
if a.state.exists():
    old=json.loads(a.state.read_text())
    process=subprocess.run(['ps','-p',str(old['pid']),'-o','command='],capture_output=True,text=True)
    if process.returncode==0:
        if old['args'][0] not in process.stdout or old['run'] not in process.stdout:raise RuntimeError('PID no longer belongs to recorded test host')
        os.kill(old['pid'],signal.SIGTERM)
        for _ in range(50):
            try:os.kill(old['pid'],0)
            except ProcessLookupError:break
            time.sleep(.1)
        else:raise RuntimeError('Previous host still running')
run=a.directory.resolve()/a.name;run.mkdir(parents=True,exist_ok=False)
args=[str(binary),'--lab-role','host','--persistent-host','--duration',str(a.duration+300),'--hdr','--resolution','2560x1440',
      '--fps','60','--mbps','20','--window-id',str(a.window_id),'--route','fixed-udp-v2','--bridge-transport','socket',
      '--pacing',a.pacing,'--playout',a.playout,'--receive-depth','16','--port',str(a.port),'--media-port',str(a.media_port),
      '--key-file',str(key),'--report',str(run/'host.json'),'--hevc-keyframe-seconds','10','--diagnostic-impairment',a.impairment]
if a.frame_trace:args+=['--frame-trace-dir',str(run/'trace')]
with (run/'host.log').open('w') as log:host=subprocess.Popen(args,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
a.state.parent.mkdir(parents=True,exist_ok=True)
a.state.write_text(json.dumps({'pid':host.pid,'args':args,'run':str(run)}))
guard = None
if a.expected_window_title:
    guard_report=run/'source-guard.json'
    with (run/'guard.log').open('w') as log:
        guard=subprocess.Popen(['python3',str(Path(__file__).parent/'capture-source-guard.py'),'--app',str(binary),
            '--window-id',str(a.window_id),'--title',a.expected_window_title,'--pid',str(host.pid),
            '--process-marker',str(run),'--report',str(guard_report),'--seconds',str(a.duration+300)]+
            (['--identity-probe',str(a.identity_probe.resolve())] if a.identity_probe else []),
            stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
    deadline=time.monotonic()+8
    while not guard_report.exists() and guard.poll() is None and time.monotonic()<deadline:time.sleep(.05)
    if not guard_report.exists() or not json.loads(guard_report.read_text()).get('samples') or not json.loads(guard_report.read_text()).get('valid'):
        host.terminate()
        if guard.poll() is None:guard.terminate()
        raise RuntimeError('Source guard failed before phone launch')
command=['xcrun','devicectl','device','process','launch','--device',a.device,'--terminate-existing',
         'com.cabinw.kkremote.lab','--media-diagnostics-run',a.name,'--media-diagnostics-seconds',str(a.duration)]
if a.frame_trace:command+=['--media-frame-trace']
try:
    subprocess.run(command,check=True,timeout=60)
except (OSError, subprocess.SubprocessError):
    # A locked/disconnected phone is not a media trial. Do not leave an idle
    # diagnostic host and guard occupying the user's normal endpoint.
    if host.poll() is None:
        host.terminate(); host.wait(timeout=5)
    if guard is not None and guard.poll() is None:
        guard.terminate(); guard.wait(timeout=5)
    (run/'PREPARATION_FAILED.json').write_text(json.dumps({
        'reason':'USB application launch failed or timed out; no media trial completed.',
        'name':a.name})+'\n')
    raise
print(json.dumps({'name':a.name,'seconds':a.duration,'profile':a.impairment,'trace':a.frame_trace,'hostPID':host.pid,
                  'next':'Connect using the existing phone profile; report is saved automatically when the diagnostic timer ends.'}))
