#!/usr/bin/env python3
"""Fake Emacs client for the wm-poc control socket.

Exercises the protocol end to end without elisp: handshake, frame/window events,
layout snapshots, key bindings and injection. Logs everything to /tmp/fake.log.

usage: fake-client.py <socket-path> [--inject-after N] [--quiet]
"""
import json
import socket
import sys
import time

LOG = open("/tmp/fake.log", "w")


def log(*a):
    print(*a, file=LOG, flush=True)


class Client:
    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(path)
        self.sock.settimeout(0.2)
        self.buf = b""
        self.epoch = 0
        self.frames = {}     # fid -> {"name":..., "oid":...}
        self.windows = {}    # wid -> {"title":..., "app_id":..., "frame":...}
        self.gen = 0
        self.visible_fid = None
        self.started = time.time()
        self.injected = False
        self.inject_after = 6.0
        self.keys = []
        self.usable = {"x": 0, "y": 0, "w": 1264, "h": 1352}

    def send(self, msg):
        line = (json.dumps(msg) + "\n").encode()
        self.sock.sendall(line)

    def push_layout(self):
        self.gen += 1
        frames = []
        for fid in self.frames:
            frames.append({
                "fid": fid,
                "oid": 0,
                "visible": fid == self.visible_fid,
            })
        # tile app windows side by side inside the visible frame
        apps = [wid for wid, w in self.windows.items() if w.get("frame") is None]
        n = max(len(apps), 1)
        uw, uh = self.usable["w"], self.usable["h"]
        windows = []
        for i, wid in enumerate(apps):
            windows.append({
                "wid": wid,
                "frame": self.visible_fid,
                "x": (uw // n) * i,
                "y": 0,
                "w": uw // n,
                "h": uh,
                "visible": True,
                "float": False,
            })
        focus = {"frame": self.visible_fid}
        if apps:
            focus["window"] = apps[0]
        self.send({
            "t": "layout", "epoch": self.epoch, "gen": self.gen,
            "frames": frames, "windows": windows, "focus": focus,
        })
        log(f"-> layout gen {self.gen}: {len(frames)} frames, {len(windows)} windows, focus {focus}")

    def handle(self, msg):
        t = msg.get("t")
        if t == "hello":
            self.epoch = msg["epoch"]
            log(f"<- hello epoch {self.epoch} caps {msg.get('caps')}")
            self.send({"t": "hello-ack", "v": 0, "epoch": self.epoch})
            self.send({"t": "bind", "bid": 1, "name": "C-x", "key": ord("x"), "mods": 4})
            self.send({"t": "bind", "bid": 2, "name": "C-t", "key": ord("t"), "mods": 4})
        elif t == "output":
            self.usable = msg["usable"]
            log(f"<- output oid={msg['oid']} {msg['w']}x{msg['h']} usable={msg['usable']}")
        elif t == "frame":
            self.frames[msg["fid"]] = msg
            log(f"<- frame fid={msg['fid']} name={msg['name']!r}")
            if self.visible_fid is None:
                self.visible_fid = msg["fid"]
            self.push_layout()
        elif t == "frame-gone":
            log(f"<- frame-gone fid={msg['fid']}")
            self.frames.pop(msg["fid"], None)
            if self.visible_fid == msg["fid"]:
                self.visible_fid = next(iter(self.frames), None)
            self.push_layout()
        elif t == "window":
            self.windows[msg["wid"]] = {"frame": None}
            log(f"<- window wid={msg['wid']}")
            self.push_layout()
        elif t == "gone":
            log(f"<- gone wid={msg['wid']}")
            self.windows.pop(msg["wid"], None)
            self.push_layout()
        elif t in ("title", "app-id", "size", "identifier", "parent"):
            log(f"<- {t} {msg}")
            push = False
            if t == "title":
                self.windows.setdefault(msg["wid"], {})["title"] = msg["title"]
                push = True
            if t == "app-id":
                self.windows.setdefault(msg["wid"], {})["app_id"] = msg["app_id"]
                push = True
            # NB: no push on "size" -- that event is caused by our own layout and
            # re-pushing would loop.
            if push:
                self.push_layout()
        elif t == "key":
            self.keys.append((msg["bid"], msg["state"]))
            log(f"<- key bid={msg['bid']} state={msg['state']}")
            if msg["bid"] == 2 and msg["state"] == "press":
                # pretend the user pressed the C-t binding: type "hi" + Return
                self.send({"t": "inject", "keys": [{"name": "h"}, {"name": "i"},
                                                   {"name": "Return"}]})
                log("-> inject h i Return")
                self.injected = True
            if msg["bid"] == 1 and msg["state"] == "press":
                log("-> (C-x prefix seen, nothing to do in the fake client)")
        else:
            log(f"<- {msg}")

    def run(self):
        while True:
            if self.started and not self.injected and time.time() - self.started > self.inject_after:
                self.injected = True
                self.send({"t": "inject", "keys": [{"name": "j"}, {"name": "Return"}]})
                log("-> inject j Return (timer)")
            try:
                data = self.sock.recv(8192)
            except socket.timeout:
                continue
            except OSError as e:
                log(f"socket error: {e}")
                return
            if not data:
                log("socket closed")
                return
            self.buf += data
            while b"\n" in self.buf:
                line, self.buf = self.buf.split(b"\n", 1)
                if not line.strip():
                    continue
                try:
                    self.handle(json.loads(line))
                except Exception as e:  # keep the fake client alive
                    log(f"error handling {line[:120]!r}: {e}")


if __name__ == "__main__":
    path = sys.argv[1]
    if "--inject-after" in sys.argv:
        pass
    Client(path).run()
