#!/usr/bin/env python3
"""Build task-local capture probes using an already configured development signing identity."""
import argparse
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--signed-app',type=Path,required=True,help='Existing signed KKRemoteLabMac.app; does not change its files')
a=p.parse_args();base=a.signed_app.resolve(strict=True)
root=Path(__file__).resolve().parents[1]
details=subprocess.run(['codesign','-dv','--verbose=4',str(base)],capture_output=True,text=True,check=True).stderr
identity=next((line.removeprefix('Authority=') for line in details.splitlines() if line.startswith('Authority=Apple Development:')),None)
if not identity:raise SystemExit('An existing Apple Development signature is required; configure signing through the normal project workflow.')
for name in ['CaptureCadenceProbe','CaptureIdentityProbe']:
    app=root/'.build'/(name+'.app');(app/'Contents/MacOS').mkdir(parents=True,exist_ok=True)
    info=plistlib.loads((base/'Contents/Info.plist').read_bytes());info['LSUIElement']=True
    (app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    profile=base/'Contents/embedded.provisionprofile'
    if profile.exists():shutil.copy2(profile,app/'Contents/embedded.provisionprofile')
    command=['xcrun','swiftc','-O','-target',platform.machine()+'-apple-macos15.0']
    if name=='CaptureCadenceProbe':command+=['-parse-as-library']
    subprocess.run(command+[str(root/'Tests'/(name+'.swift')),'-o',str(app/'Contents/MacOS/KKRemoteLabMac')],check=True)
    subprocess.run(['codesign','--force','--sign',identity,'--entitlements',str(root/'Config/TransportLabMac.entitlements'),str(app)],check=True)
    print(app)
