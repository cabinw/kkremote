#!/usr/bin/env python3
"""Generate a neutral, 10-bit limited-range PQ chart without an 8-bit RGB intermediate."""
from array import array
import json
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
work = root / '.build/hdr'
work.mkdir(parents=True, exist_ok=True)
width, height = 2560, 1440
near_black = [0, .01, .03, .1, .3, 1, 3, 10]
white_steps = [10, 25, 50, 100, 203, 400, 700, 1000]


def pq(nits):
    # BT.2100 inverse PQ EOTF. Labels describe authored signal levels, not measured display output.
    # https://registry.khronos.org/DataFormat/specs/1.4/dataformat.1.4.html#TRANSFER_PQ
    m1, m2 = 2610 / 16384, 2523 / 32
    c1, c2, c3 = 3424 / 4096, 2413 / 128, 2392 / 128
    linear = (nits / 10000) ** m1
    return ((c1 + c2 * linear) / (1 + c3 * linear)) ** m2


def code(nits):
    return round(64 + 876 * pq(nits))


def le_bytes(values):
    data = array('H', values)
    if sys.byteorder != 'little':
        data.byteswap()
    return data.tobytes()


rows = [le_bytes([code(levels[min(7, x * 8 // width)]) for x in range(width)])
        for levels in (near_black, white_steps)]
rows.append(le_bytes([round(64 + (code(1000) - 64) * x / (width - 1)) for x in range(width)]))
raw = work / 'pq-gray.yuv'
with raw.open('wb') as file:
    for row in rows:
        file.write(row * (height // 3))
    # Neutral chroma. Each 4:2:0 plane is one quarter of the luma plane.
    file.write(le_bytes([512]) * (width * height // 2))
assert raw.stat().st_size == width * height * 3
assert code(0) == 64 and code(10000) == 940
assert len(set(code(n) for n in near_black + white_steps)) == len(set(near_black + white_steps))
manifest = {'width': width, 'height': height, 'fps': 60, 'durationSeconds': 10,
            'pixelFormat': 'yuv420p10le', 'primaries': 'bt2020', 'transfer': 'smpte2084',
            'matrix': 'bt2020nc', 'range': 'tv', 'neutralChroma': 512,
            'nearBlackNits': near_black, 'nearBlackCodes': [code(v) for v in near_black],
            'whiteStepNits': white_steps, 'whiteStepCodes': [code(v) for v in white_steps],
            'rampCodes': [64, code(1000)],
            'note': 'Nominal authored PQ signal levels; no mastering/peak-display certification. Static chart in a 60fps video container; lossless fixture encoding, independent of the live VT encoder.'}
(work / 'pq-gray-reference.json').write_text(json.dumps(manifest, indent=2) + '\n')
encoded = work / 'pq-gray-encoded.mp4'
output = work / 'pq-gray-reference.mp4'
subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'warning', '-y', '-stream_loop', '-1',
    '-f', 'rawvideo', '-pixel_format', 'yuv420p10le', '-video_size', f'{width}x{height}',
    '-framerate', '60', '-i', str(raw), '-t', '10', '-an', '-c:v', 'libx265',
    '-preset', 'ultrafast', '-profile:v', 'main10', '-pix_fmt', 'yuv420p10le',
    '-x265-params', 'lossless=1:pools=2:frame-threads=2:bframes=0:keyint=120:min-keyint=120:scenecut=0:log-level=error:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:range=limited',
    '-tag:v', 'hvc1',
    '-color_primaries', 'bt2020', '-color_trc', 'smpte2084', '-colorspace', 'bt2020nc',
    '-color_range', 'tv', '-movflags', '+faststart', str(encoded)], check=True)
subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'warning', '-y', '-i', str(encoded),
    '-c', 'copy', '-bsf:v', 'hevc_metadata=colour_primaries=9:transfer_characteristics=16:matrix_coefficients=9',
    '-color_primaries', 'bt2020', '-color_trc', 'smpte2084', '-colorspace', 'bt2020nc',
    '-color_range', 'tv', '-tag:v', 'hvc1', '-movflags', '+faststart', str(output)], check=True)
decoded = work / 'pq-gray-decoded.yuv'
subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-i', str(output),
    '-frames:v', '1', '-pix_fmt', 'yuv420p10le', '-f', 'rawvideo', str(decoded)], check=True)
assert decoded.read_bytes() == raw.read_bytes(), 'Fixture compression changed the reference code values'
probe = json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-select_streams', 'v:0',
    '-show_entries', 'stream=profile,pix_fmt,color_range,color_space,color_transfer,color_primaries,avg_frame_rate,nb_frames',
    '-of', 'json', str(output)]))['streams'][0]
assert probe['profile'] == 'Main 10' and probe['pix_fmt'] == 'yuv420p10le'
assert probe['color_primaries'] == 'bt2020' and probe['color_transfer'] == 'smpte2084'
assert probe['color_space'] == 'bt2020nc' and probe['color_range'] == 'tv'
assert probe['avg_frame_rate'] == '60/1' and probe['nb_frames'] == '600'
(work / 'pq-gray-file-validation.json').write_text(json.dumps({'firstFrameBitExact': True, 'stream': probe}, indent=2) + '\n')
print(json.dumps(manifest, indent=2))
print(output)
