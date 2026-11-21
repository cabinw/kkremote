"""Pace live stereo by the original PTS. Bound the transport queue and collect stereo presentation receipts."""
import argparse
import asyncio
from collections import deque
import contextlib
import ipaddress
import json
from pathlib import Path
import secrets
import socket
import struct
import sys
import time

HERE = Path(__file__).resolve().parent
LAN = HERE.parent / "lan-window"
sys.path.insert(0, str(LAN))
from relay import psk_context
from avc import signal_display_order

FRAME = struct.Struct("!IQQQI")
PACED_ACK = struct.Struct("!IQIIIII")
ACK = struct.Struct("!IQIII")


def clock_ns():
    return time.clock_gettime_ns(time.CLOCK_MONOTONIC_RAW)


async def play(reader, writer, model, movie, codec, trace):
    first, _, initial_status, _, slider = ACK.unpack(await asyncio.wait_for(reader.readexactly(ACK.size), 10))
    if first != 0 or slider > 255:
        raise ValueError(f"bad viewer hello, decoder status {initial_status:#x}")
    converter = await asyncio.create_subprocess_exec(
        str(HERE / ".build/live"), str(model), str(movie), codec,
        stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE)
    converter.stdin.write(bytes([slider]))
    pending = deque()
    capacity = 16 if codec == "h264" else 2
    in_flight = {}
    changed = asyncio.Event()

    async def produce():
        need_key = True
        while True:
            seq, pts, start, ready, tagged = FRAME.unpack(await converter.stdout.readexactly(FRAME.size))
            size = tagged & 0x7fffffff
            keyframe = bool(tagged >> 31)
            if not 0 < size <= 200000:
                raise ValueError("invalid stereo packet size")
            data = await converter.stdout.readexactly(size)
            if codec == "h264" and keyframe:
                data = signal_display_order(data)
            if codec == "jpeg":
                pending.clear()
            elif len(pending) >= 8:
                # A broken reference chain resumes at the next independently decodable IDR.
                pending.clear()
                need_key = True
            if need_key and not keyframe:
                continue
            need_key = False
            pending.append((seq, pts, start, ready, data))
            changed.set()

    async def transmit():
        while True:
            await changed.wait()
            changed.clear()
            while pending and len(in_flight) < capacity:
                seq, pts, start, ready, data = pending.popleft()
                in_flight[seq] = (pts, start, ready)
                header = struct.pack("!II", seq, len(data))
                if codec == "h264":
                    header += struct.pack("!Q", pts)
                writer.write(header + data)
                await writer.drain()

    async def feedback():
        nonlocal slider
        count = 0
        while True:
            layout = PACED_ACK if codec == "h264" else ACK
            seq, display_us, decode_us, draw_us, value, *details = layout.unpack(
                await asyncio.wait_for(reader.readexactly(layout.size), 20))
            ack_ns = clock_ns()
            if seq not in in_flight or value > 255:
                raise ValueError(f"unexpected acknowledgment id={seq} status={decode_us:#x}")
            pts, start, ready = in_flight.pop(seq)
            if not start <= ready <= ack_ns:
                raise ValueError("Mac clock mismatch")
            if value != slider:
                slider = value
                converter.stdin.write(bytes([slider]))
                await converter.stdin.drain()
            row = dict(seq=seq, pts_us=pts, display_us=display_us, decode_us=decode_us, draw_us=draw_us,
                       slider=value, convert_ms=(ready-start)/1e6, ack_ms=(ack_ns-start)/1e6)
            if details:
                row.update(pixel_signature=details[0], ack_wait_us=details[1])
            trace.write(json.dumps(row, separators=(",", ":")) + "\n")
            count += 1
            if count == 1 or count % 60 == 0:
                trace.flush()
                print(f"displayed={count} source={seq} slider={slider}/255", flush=True)
            changed.set()

    tasks = [asyncio.create_task(f()) for f in (produce, transmit, feedback)]
    try:
        done, _ = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
        for task in done:
            task.result()
    finally:
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        if converter.returncode is None:
            converter.terminate()
        # Drain stdout even during shutdown; a full subprocess pipe can block wait().
        await converter.communicate()


async def run(args):
    key = secrets.token_bytes(32)
    finished = asyncio.Event()
    accepted = False

    async def session(reader, writer):
        nonlocal accepted
        if writer.get_extra_info("peername")[0] != str(args.viewer) or accepted:
            writer.close()
            return
        accepted = True
        writer.get_extra_info("socket").setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        try:
            with args.trace.open("x") as trace:
                print("Authenticated viewer; converting source video", flush=True)
                await play(reader, writer, args.model, args.movie, args.codec, trace)
        except (asyncio.IncompleteReadError, ConnectionError, TimeoutError) as exc:
            print("Viewer disconnected:", type(exc).__name__, flush=True)
        finally:
            writer.close()
            with contextlib.suppress(OSError, TimeoutError):
                await asyncio.wait_for(writer.wait_closed(), 3)
            finished.set()

    server = await asyncio.start_server(session, str(args.bind), args.port, ssl=psk_context(key))
    async with server:
        sender = await asyncio.create_subprocess_exec(
            str(args.sender), "-a", str(args.viewer), str(LAN / ".build/KKRemote-LAN.3dsx"),
            str(args.bind), str(args.port), key.hex(), "stereo-avc" if args.codec == "h264" else "stereo")
        if await sender.wait():
            raise SystemExit("Netloader send failed")
        await finished.wait()


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("bind", type=ipaddress.IPv4Address)
    p.add_argument("viewer", type=ipaddress.IPv4Address)
    p.add_argument("--codec", choices=["jpeg","h264"], default="h264")
    p.add_argument("--port", type=int, default=39465)
    p.add_argument("--sender", type=Path, required=True)
    p.add_argument("--model", type=Path, default=HERE.parent/"stereo-mac/.build/DepthAnythingV2SmallF16.mlmodelc")
    p.add_argument("--movie", type=Path, default=HERE.parent/"stereo-mac/.build/sintel.mp4")
    p.add_argument("--trace", type=Path, required=True)
    args = p.parse_args()
    if args.bind.is_unspecified or not args.bind.is_private or not args.viewer.is_private:
        p.error("use local LAN addresses")
    if args.trace.exists() or not args.model.is_dir() or not args.movie.is_file():
        p.error("check model, source movie, and new trace filename")
    asyncio.run(run(args))
