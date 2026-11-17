#!/usr/bin/env python3
"""Reject invalid control messages without changing the live WPS test workbook."""
import json
from pathlib import Path
import time
import urllib.error
import urllib.request

root = Path(__file__).resolve().parents[1]
config = json.loads((root / '.build/ios-wps-control/interactive-config.json').read_text())
sequence = int(time.time() * 1000)


def send(kind, token=None, **overrides):
    global sequence
    sequence += 1
    body = dict(kind=kind, session=config['session'], sequence=sequence, version=0)
    body.update(overrides)
    request = urllib.request.Request(config['url'], data=json.dumps(body).encode(), headers={
        'Content-Type': 'application/json', 'Authorization': 'Bearer ' + (config['token'] if token is None else token)})
    try:
        response = urllib.request.urlopen(request, timeout=10)
    except urllib.error.HTTPError as error:
        response = error
    return response.status, json.load(response)


code, initial = send('status')
assert code == 200, initial.get('error')
version = initial['version']
assert send('tap', token='invalid', x=100, y=300, version=version)[0] == 403
assert send('tap', session='expired', x=100, y=300, version=version)[0] == 409
assert send('tap', x=100, y=300, version=version + 1)[0] == 409
assert send('tap', sequence=-1, x=100, y=300, version=version)[0] == 409
assert send('resize', width=-10, height=700)[0] == 409
assert send('commit', cell=initial['cell'], text='must not appear', id='invalid', version=version)[0] == 409
code, final = send('status')
assert code == 200
for field in ('cell', 'value', 'window', 'version'):
    assert final[field] == initial[field], field
print('PASS: 6 invalid requests rejected; cell, value, geometry and version unchanged')
