"""Local PSK-authenticated 3DS window relay. Session key file is created by the launcher."""
import argparse
import hmac
import ipaddress
from pathlib import Path
import secrets
import socket
import ssl
import struct
import subprocess


def read_exact(stream, size):
    parts = bytearray()
    while len(parts) < size:
        chunk = stream.read(size - len(parts))
        if not chunk:
            raise EOFError("peer closed")
        parts.extend(chunk)
    return parts


def serve(peer, target):
    helper = subprocess.Popen([str(Path(__file__).resolve().parent / ".build/capture"), str(target)],
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE, bufsize=0)
    presented = False
    try:
        with peer.makefile("rb") as requests:
            while True:
                mark, action, x, y = struct.unpack("!BBHH", read_exact(requests, 6))
                if mark not in (0x31, 0x32) or action > 4 or x >= 400 or y >= 240:
                    raise ValueError("invalid input frame")
                if mark == 0x32 and not presented:
                    print("PEER_DISPLAYED_FRAME", flush=True)
                    presented = True
                helper.stdin.write(f"{action} {x} {y}\n".encode("ascii"))
                header = read_exact(helper.stdout, 5)
                status, size = struct.unpack("!BI", header)
                if status > 1 or size > 150000:
                    raise ValueError("invalid capture frame")
                peer.sendall(header + read_exact(helper.stdout, size))
    finally:
        helper.stdin.close()
        try:
            helper.wait(timeout=2)
        except subprocess.TimeoutExpired:
            helper.kill()
            helper.wait()
        helper.stdout.close()


def serve_desk(peer):
    capture = Path(__file__).resolve().parent / ".build/capture"
    with subprocess.Popen([str(capture), "--desk"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, bufsize=0) as helper:
        last_displayed = None
        try:
            with peer.makefile("rb") as requests:
                while True:
                    mark, index, action, value, x, y = struct.unpack("!BBBBHH", read_exact(requests, 8))
                    legacy = mark in (0x44, 0x45)
                    detail = mark in (0x56, 0x57)
                    if legacy:
                        x, y = x * 2, y * 2
                    if (not legacy and mark not in range(0x54, 0x58)) or action not in (0, 1, 2, 3, 4, 255) or x >= 800 or y >= 480:
                        raise ValueError("invalid desktop request")
                    if action == 255:
                        command = "catalog"
                        last_displayed = None
                    else:
                        command = f"{index} {action} {value} {x} {y} {int(detail)}"
                        if mark & 1 and last_displayed != (index, detail):
                            print(f"DESK_DISPLAYED slot={index} detail={int(detail)}", flush=True)
                            last_displayed = (index, detail)
                    helper.stdin.write((command + "\n").encode("ascii"))
                    header = read_exact(helper.stdout, 5)
                    status, size = struct.unpack("!BI", header)
                    if status > 3 or size > (2000000 if action == 255 else 150000):
                        raise ValueError("invalid desktop response")
                    peer.sendall(header + read_exact(helper.stdout, size))
        finally:
            helper.stdin.close()


def psk_context(key):
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.maximum_version = ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.options |= ssl.OP_NO_TICKET
    ctx.set_ciphers("PSK-AES128-GCM-SHA256")
    ctx.set_psk_server_callback(lambda name: key if hmac.compare_digest(name or "", "kk3ds") else b"")
    return ctx


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("bind", type=ipaddress.IPv4Address)
    parser.add_argument("peer", type=ipaddress.IPv4Address)
    parser.add_argument("window", type=int, nargs="?")
    parser.add_argument("--desk", action="store_true", help="interactive window Dock and keyboard")
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--sender", type=Path, help="3dslink executable; generate a fresh LAN session and deploy the client")
    source.add_argument("--key-file", type=Path, help="use an existing 256-bit session secret for a local integration test")
    parser.add_argument("--port", type=int, default=39463)
    args = parser.parse_args()
    if args.bind.is_unspecified or not args.bind.is_private or not args.peer.is_private:
        parser.error("select a local LAN interface and a single peer")
    if args.desk == (args.window is not None):
        parser.error("select either a window number or --desk")
    key = bytes.fromhex(args.key_file.read_text().strip()) if args.key_file else secrets.token_bytes(32)
    if len(key) != 32:
        parser.error("need a 256-bit session key")
    ctx = psk_context(key)
    with socket.create_server((str(args.bind), args.port)) as listener:
        listener.settimeout(600)
        print("READY", flush=True)
        if args.sender:
            binary = Path(__file__).resolve().parent / ".build/KKRemote-LAN.3dsx"
            result = subprocess.call([str(args.sender.resolve()), "-a", str(args.peer), str(binary),
                                      str(args.bind), str(args.port), key.hex()] + (["desk"] if args.desk else []))
            if result:
                raise SystemExit("Netloader deployment failed; press Y in hbmenu and retry")
        while True:
            try:
                conn, address = listener.accept()
            except TimeoutError:
                break
            with conn:
                if address[0] != str(args.peer):
                    continue
                try:
                    conn.settimeout(12)
                    with ctx.wrap_socket(conn, server_side=True) as peer:
                        print("TLS_CONNECTED", flush=True)
                        if args.desk:
                            serve_desk(peer)
                        else:
                            serve(peer, args.window)
                except (OSError, EOFError, ValueError) as error:
                    print("Session closed:", error, flush=True)


if __name__ == "__main__":
    main()
