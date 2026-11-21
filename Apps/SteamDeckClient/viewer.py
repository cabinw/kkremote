"""Read-only SteamOS window viewer for KKRemote's direct-ICE Host."""
import argparse
import asyncio
import base64
import getpass
import hashlib
import json
import os
from pathlib import Path
import ssl
import struct
import sys
import uuid

os.environ.setdefault("PYGAME_HIDE_SUPPORT_PROMPT", "1")
import pygame
from aiortc import RTCConfiguration, RTCPeerConnection, RTCSessionDescription
from aiortc.mediastreams import MediaStreamError
from aiortc.sdp import candidate_from_sdp


def pairing_context(text):
    if len(text) == 6 and text.isascii() and text.isdigit():
        secret = hashlib.sha256(("kkremote-lab-pairing-code-v1:" + text).encode()).digest()
    else:
        secret = base64.b64decode(text, validate=True)
        if len(secret) != 32:
            raise ValueError("Expected a six-digit code or a 32-byte pairing key")
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.minimum_version = context.maximum_version = ssl.TLSVersion.TLSv1_2
    # Authentication uses only the pinned PSK cipher, which has no certificates.
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    context.set_ciphers("PSK-AES128-GCM-SHA256")
    context.set_psk_client_callback(lambda hint: ("kkremote-lab-v1", secret))
    return context


async def receive(reader):
    size, = struct.unpack(">I", await reader.readexactly(4))
    if not 0 < size <= 256 * 1024:
        raise ValueError("Invalid signaling frame length")
    return json.loads(await reader.readexactly(size))


async def send(writer, message):
    frame = json.dumps(message).encode()
    writer.write(struct.pack(">I", len(frame)) + frame)
    await writer.drain()


async def select_window(reader, writer, application):
    async def command(action, **fields):
        await send(writer, {"type": "window", "session": session, "window": {
            "version": 1, "action": action, "requestID": request_id, **fields}})

    session = None
    selected = None
    request_id = str(uuid.uuid4())
    while True:
        message = await receive(reader)
        if message["type"] == "bridge":
            raise ValueError("Start the Host in direct-ice mode")
        if message["type"] == "offer" and session is None:
            if message.get("windowProtocol") != 1:
                raise ValueError("Host does not advertise the window catalog")
            session = message["windowSession"]
            await command("list")
        if message["type"] != "window" or message["session"] != session:
            continue
        window = message["window"]
        if window.get("requestID") != request_id or window.get("version") != 1:
            continue
        if window.get("error"):
            raise RuntimeError("Host could not list or select the requested window")
        if window["action"] == "catalog" and selected is None:
            matches = [w for w in window["windows"] if w["application"].casefold() == application.casefold()]
            if not matches:
                raise ValueError(f"No visible window for {application}")
            selected = max(matches, key=lambda w: w["widthPoints"] * w["heightPoints"])
            request_id = str(uuid.uuid4())
            await command("select", windowID=selected["id"])
        elif selected and window["action"] == "prepare":
            await command("ready")
        elif selected and window["action"] == "selected" and window["selected"]["id"] == selected["id"]:
            print(f"Selected {application} ({selected['widthPoints']:g} × {selected['heightPoints']:g} points)", flush=True)
            return session, window["mediaSession"]


class ViewerClosed(Exception):
    pass


async def present(track, application):
    pygame.display.init()
    try:
        screen = pygame.display.set_mode((0, 0), pygame.FULLSCREEN)
        pygame.display.set_caption("KKRemote · " + application)
        pygame.mouse.set_visible(False)
        clock = asyncio.get_running_loop()
        count = 0
        last_frame = clock.time()
        next_report = last_frame + 30
        pending = asyncio.create_task(track.recv())
        try:
            while True:
                for event in pygame.event.get():
                    if event.type == pygame.QUIT or (event.type == pygame.KEYDOWN and event.key == pygame.K_ESCAPE):
                        raise ViewerClosed()
                done, _ = await asyncio.wait([pending], timeout=0.05)
                if not done:
                    if clock.time() - last_frame > 20:
                        raise TimeoutError("No video frames for 20 seconds")
                    continue
                last_frame = clock.time()
                frame = pending.result()
                pending = asyncio.create_task(track.recv())
                rgb = frame.reformat(format="bgra")
                plane = rgb.planes[0]
                image = pygame.image.frombuffer(plane, (rgb.width, rgb.height), "BGRA", pitch=plane.line_size)
                bounds = screen.get_rect()
                target = image.get_rect().fit(bounds)
                screen.fill("black")
                screen.blit(pygame.transform.smoothscale(image, target.size), target)
                pygame.display.flip()
                count += 1
                if count == 1 or clock.time() >= next_report:
                    print(f"Presented frames: {count} · stream {rgb.width}x{rgb.height} · display {bounds.w}x{bounds.h}", flush=True)
                    next_report = clock.time() + 30
        finally:
            pending.cancel()
            await asyncio.gather(pending, return_exceptions=True)
    finally:
        pygame.display.quit()


async def watch(reader, writer, application):
    window_session, media = await asyncio.wait_for(select_window(reader, writer, application), 25)
    pc = RTCPeerConnection(RTCConfiguration(iceServers=[]))
    loop = asyncio.get_running_loop()
    track_ready = loop.create_future()
    failed = asyncio.Event()

    @pc.on("track")
    def on_track(track):
        if track.kind == "video" and not track_ready.done():
            track_ready.set_result(track)

    @pc.on("connectionstatechange")
    def on_state():
        if pc.connectionState == "failed":
            failed.set()

    @pc.on("datachannel")
    def on_channel(channel):
        @channel.on("message")
        def echo(message):
            if isinstance(message, str) and len(message) < 256 and message.startswith("ping:"):
                channel.send("pong:" + message[5:])

    async def signaling():
        queued = []
        while True:
            m = await receive(reader)
            if m["type"] == "window" and m["session"] == window_session and m["window"]["action"] == "unavailable":
                raise RuntimeError("The selected window is no longer available")
            if m["session"] != media:
                continue
            if m["type"] == "offer":
                await pc.setRemoteDescription(RTCSessionDescription(sdp=m["sdp"], type="offer"))
                for candidate in queued:
                    await pc.addIceCandidate(candidate)
                queued.clear()
                await pc.setLocalDescription(await pc.createAnswer())
                await send(writer, {"type": "answer", "session": media, "sdp": pc.localDescription.sdp,
                                    "videoFormat": "h264-sdr"})
            elif m["type"] == "candidate":
                candidate = candidate_from_sdp(m["candidate"].removeprefix("candidate:"))
                candidate.sdpMid, candidate.sdpMLineIndex = m.get("mid"), m["line"]
                if pc.remoteDescription:
                    await pc.addIceCandidate(candidate)
                elif len(queued) < 128:
                    queued.append(candidate)
                else:
                    raise ValueError("Too many pending ICE candidates")

    async def playback():
        track = await asyncio.wait_for(track_ready, 20)
        await present(track, application)

    tasks = [asyncio.create_task(fn()) for fn in (signaling, playback, failed.wait)]
    try:
        done, _ = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
        for task in done:
            task.result()
        if failed.is_set():
            raise ConnectionError("WebRTC connection failed")
    finally:
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        await pc.close()


async def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", type=int, default=45990)
    parser.add_argument("--application", default="PopAgent")
    parser.add_argument("--key-file", type=Path)
    args = parser.parse_args()
    pairing = args.key_file.read_text().strip() if args.key_file else getpass.getpass("Host pairing code: ").strip()
    context = pairing_context(pairing)
    reader, writer = await asyncio.wait_for(asyncio.open_connection(args.host, args.port, ssl=context), 12)
    try:
        await watch(reader, writer, args.application)
    finally:
        writer.close()
        await writer.wait_closed()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except (ViewerClosed, KeyboardInterrupt):
        pass
    except (ConnectionError, OSError, ValueError, RuntimeError, EOFError, MediaStreamError) as exc:
        sys.exit(f"KKRemote: {type(exc).__name__}: {exc}")
