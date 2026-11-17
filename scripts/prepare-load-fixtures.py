#!/usr/bin/env python3
"""Prepare a local, stream-copied native-60-fps excerpt and its provenance."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source', type=Path, required=True)
parser.add_argument('--start', type=float, default=420)
parser.add_argument('--duration', type=float, default=30)
parser.add_argument('--output', type=Path, default=Path('.build/load-fixtures'))
args = parser.parse_args()
if args.start < 0 or not 10 <= args.duration <= 120:
    parser.error('start must be nonnegative; duration must be 10...120 seconds')
source = args.source.resolve(strict=True)
args.output.mkdir(parents=True, exist_ok=True)
clip = args.output / 'bbb-highmotion-60.mp4'
if clip.exists():
    parser.error('Output already exists; use a new output directory to preserve provenance')

def probe(path):
    return json.loads(subprocess.check_output([
        'ffprobe', '-v', 'error', '-select_streams', 'v:0', '-show_entries',
        'stream=codec_name,profile,width,height,pix_fmt,color_space,color_transfer,color_primaries,avg_frame_rate,r_frame_rate,nb_frames,bit_rate:format=duration,size:format_tags=title,comment',
        '-of', 'json', str(path)]))

def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()

original = probe(source)
stream = original['streams'][0]
if original.get('format', {}).get('tags', {}).get('title') != 'Big Buck Bunny, Sunflower version':
    parser.error('This recipe is for Big Buck Bunny Sunflower; preserve the correct source credit')
if stream['avg_frame_rate'] != '60/1':
    parser.error('Expected native 60/1 source; do not interpolate or relabel frame rate')
subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'warning', '-nostdin',
                '-ss', str(args.start), '-i', str(source), '-t', str(args.duration),
                '-map', '0:v:0', '-an', '-c:v', 'copy', '-avoid_negative_ts', 'make_zero',
                '-movflags', '+faststart', str(clip)], check=True)
photo = args.output / 'photo.jpg'
subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-nostdin',
                '-ss', '9', '-i', str(clip), '-frames:v', '1', '-q:v', '2', str(photo)], check=True)
manifest = {
    'fixtureID': 'bbb-highmotion-60-v1',
    'sourceName': source.name, 'sourceSHA256': sha(source), 'sourceMetadata': original,
    'requestedStartSeconds': args.start, 'requestedDurationSeconds': args.duration,
    'method': 'video stream copy, keyframe preroll possible; no interpolation or re-encoding',
    'sourceCredit': 'Big Buck Bunny, Sunflower version / Blender Foundation / CC BY 3.0',
    'sourceURL': 'https://download.blender.org/demo/movies/BBB/',
    'dynamicRange': 'SDR source; capturing in a PQ stream does not make this an HDR-mastered scene',
    'clipSHA256': sha(clip), 'clipMetadata': probe(clip),
    'photo': {'file': photo.name, 'clipTimeSeconds': 9, 'jpegQuality': 2, 'sha256': sha(photo)},
}
(args.output / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2)+'\n')
print(json.dumps({'clip':str(clip), 'metadata':manifest['clipMetadata']}, ensure_ascii=False))
