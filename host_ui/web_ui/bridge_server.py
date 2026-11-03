#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
HTTP + serial bridge for the FPGA synth web UI.  Pure standard library.

Why this exists
---------------
Web Serial needs a browser permission prompt and a device picker; on some
machines the picker does not list the CH340 port at all.  This server opens the
serial port itself and republishes the raw 576-byte frames over HTTP, so the
page can consume them with a plain `fetch('/stream')` and no permission at all.

Usage
-----
    python bridge_server.py                 # auto-find CH340, serve on 8080
    python bridge_server.py --com COM13 --port 8080
    python bridge_server.py --no-serial     # static files only

Endpoints
---------
    /                     static files from this folder
    /info                 JSON: port, connected, clients
    /stream               endless raw byte stream (feed it to the same parser
                          the Web Serial path uses)

The page connects with  index.html?bridge=1  (or ?auto=1, which prefers the
bridge when it is alive).
"""
import argparse
import json
import os
import queue
import sys
import threading
import time
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.dirname(os.path.abspath(__file__))

# ---------------------------------------------------------------------------
# serial side
# ---------------------------------------------------------------------------
try:
    import serial
    import serial.tools.list_ports
    HAVE_PYSERIAL = True
except Exception:
    HAVE_PYSERIAL = False

ser = None
ser_lock = threading.Lock()
clients = []
clients_lock = threading.Lock()
SERIAL_NAME = ""
SERIAL_OK = False


def find_serial(preferred=None):
    """CH340 first (VID 1A86), then any FTDI/CP210x, else the given name."""
    if not HAVE_PYSERIAL:
        return None
    ports = list(serial.tools.list_ports.comports())
    if preferred:
        for p in ports:
            if p.device.upper() == preferred.upper():
                return p.device
    for vid_pid in ("1A86:7523", "1A86:5523", "0403:6001", "10C4:EA60"):
        for p in ports:
            if vid_pid.upper() in (p.hwid or "").upper():
                return p.device
    return None


def serial_reader():
    global SERIAL_OK
    backoff = 0.5
    while True:
        if not SERIAL_OK or ser is None:
            time.sleep(backoff)
            continue
        try:
            with ser_lock:
                data = ser.read(8192)
        except Exception as e:
            print("[serial] read failed: %r" % (e,))
            SERIAL_OK = False
            time.sleep(0.5)
            continue
        if data:
            with clients_lock:
                for q in clients:
                    try:
                        q.put_nowait(data)
                    except queue.Full:
                        pass


# ---------------------------------------------------------------------------
# HTTP side
# ---------------------------------------------------------------------------
class Handler(SimpleHTTPRequestHandler):
    protocol_version = "HTTP/1.0"

    def __init__(self, *a, **kw):
        super().__init__(*a, directory=ROOT, **kw)

    def log_message(self, fmt, *args):
        # keep the console readable: only report errors / one-liners
        msg = fmt % args
        if " /stream " in msg or " /info " in msg:
            return
        sys.stderr.write("[http] %s\n" % msg)

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/info":
            return self.json_info()
        if path == "/stream":
            return self.stream()
        return super().do_GET()

    # ------------------------------------------------------------------
    # downlink: POST /cmd  with raw bytes -> write to the serial port
    #   the UI uses this for  A5 01 <wave>  (timbre select)
    # ------------------------------------------------------------------
    def do_POST(self):
        path = self.path.split("?")[0]
        if path != "/cmd":
            self.send_error(404)
            return
        n = int(self.headers.get("Content-Length") or 0)
        data = self.rfile.read(n) if n else b""
        ok, err = False, "serial not connected"
        if SERIAL_OK and ser is not None and data:
            try:
                with ser_lock:
                    ser.write(data)
                    ser.flush()
                ok, err = True, ""
                print("[cmd] wrote %d bytes: %s" % (len(data), data.hex()))
            except Exception as e:
                err = repr(e)
                print("[cmd] write failed:", err)
        body = json.dumps({"ok": ok, "wrote": len(data), "error": err}).encode()
        self.send_response(200 if ok else 503)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def json_info(self):
        body = json.dumps({
            "serial_name": SERIAL_NAME,
            "serial_ok": SERIAL_OK,
            "clients": len(clients),
            "pyserial": HAVE_PYSERIAL,
        }).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def stream(self):
        if not SERIAL_OK:
            body = b"serial not connected"
            self.send_response(503)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        q = queue.Queue(maxsize=512)
        with clients_lock:
            clients.append(q)
        print("[stream] client connected (%d total)" % len(clients))
        try:
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Connection", "close")
            self.end_headers()
            while True:
                try:
                    chunk = q.get(timeout=10.0)
                except queue.Empty:
                    continue
                self.wfile.write(chunk)
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        finally:
            with clients_lock:
                try:
                    clients.remove(q)
                except ValueError:
                    pass
            print("[stream] client gone (%d left)" % len(clients))


def main():
    global ser, SERIAL_NAME, SERIAL_OK
    ap = argparse.ArgumentParser()
    ap.add_argument("--com", default=None, help="serial port, e.g. COM13 (default: auto)")
    ap.add_argument("--port", type=int, default=8080)
    ap.add_argument("--baud", type=int, default=921600,
                    help="921600 matches the current FPGA build (was 115200 before 2026-11-03)")
    ap.add_argument("--no-serial", action="store_true", help="serve files only")
    args = ap.parse_args()

    if not args.no_serial and HAVE_PYSERIAL:
        name = find_serial(args.com)
        if name:
            try:
                ser = serial.Serial(name, args.baud, timeout=0.05)
                SERIAL_NAME = name
                SERIAL_OK = True
                print("[serial] opened %s @%d" % (name, args.baud))
                threading.Thread(target=serial_reader, daemon=True).start()
            except Exception as e:
                print("[serial] open %s failed: %r" % (name, e))
        else:
            print("[serial] no CH340/FTDI/CP210x port found -> file server only")
    elif not HAVE_PYSERIAL:
        print("[serial] pyserial missing: pip install pyserial")

    httpd = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    httpd.daemon_threads = True
    print("[http] serving %s" % ROOT)
    print("[http] open  http://127.0.0.1:%d/index.html?auto=1" % args.port)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n[main] bye")
    finally:
        if ser is not None:
            try:
                ser.close()
            except Exception:
                pass


if __name__ == "__main__":
    main()
