#!/usr/bin/env python3
"""Serve the owned capture fixture and a local, untracked MP4 on loopback only."""
import argparse
import functools
import http.server
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--media', type=Path, required=True)
parser.add_argument('--hdr-media', type=Path)
parser.add_argument('--reference-media', type=Path)
parser.add_argument('--gray-media', type=Path)
parser.add_argument('--port', type=int, default=47980)
args = parser.parse_args()
media = args.media.resolve(strict=True)
media_paths = {'/clip.mp4': media}
if args.hdr_media:
    media_paths['/hdr.mp4'] = args.hdr_media.resolve(strict=True)
if args.reference_media:
    media_paths['/reference.mp4'] = args.reference_media.resolve(strict=True)
if args.gray_media:
    media_paths['/gray.mp4'] = args.gray_media.resolve(strict=True)
fixture = Path(__file__).resolve().parents[1] / 'Tests/Fixtures/window-capture'


class Handler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        media = media_paths.get(self.path.split('?')[0])
        if media is None:
            return super().do_GET()
        size = media.stat().st_size
        start, end = 0, size - 1
        value = self.headers.get('Range')
        if value:
            import re
            match = re.fullmatch(r'bytes=(\d+)-(\d*)', value)
            if not match:
                self.send_error(416)
                return
            start = int(match[1])
            end = min(int(match[2]) if match[2] else end, end)
            if start > end:
                self.send_error(416)
                return
        self.send_response(206 if value else 200)
        self.send_header('Content-Type', 'video/mp4')
        self.send_header('Accept-Ranges', 'bytes')
        self.send_header('Content-Length', str(end - start + 1))
        if value:
            self.send_header('Content-Range', f'bytes {start}-{end}/{size}')
        self.end_headers()
        try:
            with media.open('rb') as file:
                file.seek(start)
                remaining = end - start + 1
                while remaining:
                    chunk = file.read(min(256 * 1024, remaining))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    remaining -= len(chunk)
        except (BrokenPipeError, ConnectionResetError):
            pass


http.server.ThreadingHTTPServer(('127.0.0.1', args.port), functools.partial(Handler, directory=str(fixture))).serve_forever()
