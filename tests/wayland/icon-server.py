# SPDX-License-Identifier: BSD-2-Clause
"""A small Wayland server for tests/wayland-icon.sh.

No compositor on the test machines has the protocol xdg-toplevel-icon-v1,
so this server has it. It offers wl_compositor, wl_shm, xdg_wm_base, and
xdg_toplevel_icon_manager_v1, sends the configure events of one toplevel,
and records each icon that the client sets: the size, the format, and the
pixels of each buffer. At the end of the connection it writes the icons as
JSON to the file of its second argument.

The source of the wire format is the Wayland protocol document and the
protocol XML files (stable/xdg-shell, staging/xdg-toplevel-icon).

Use: python3 -I icon-server.py SOCKET OUT.json
"""

import array
import json
import mmap
import os
import socket
import struct
import sys

GLOBALS = [
    ("wl_compositor", 4),
    ("wl_shm", 1),
    ("xdg_wm_base", 2),
    ("xdg_toplevel_icon_manager_v1", 1),
]


class Server:
    def __init__(self, conn):
        self.conn = conn
        self.buf = b""
        self.fds = []
        # The interface of each object of the client.
        self.objects = {1: "wl_display"}
        self.pools = {}
        self.buffers = {}
        self.icons = {}
        self.set_icons = []
        self.toplevel_surface = None
        self.xdg_surface_of = {}
        self.configured = False
        self.serial = 1

    def send(self, obj, op, payload=b""):
        self.conn.sendall(struct.pack("<II", obj, ((8 + len(payload)) << 16) | op) + payload)

    @staticmethod
    def string(s):
        b = s.encode() + b"\0"
        return struct.pack("<I", len(b)) + b + b"\0" * (-len(b) % 4)

    def read(self):
        data, anc, _, _ = self.conn.recvmsg(65536, socket.CMSG_SPACE(28 * 4))
        for level, kind, d in anc:
            if level == socket.SOL_SOCKET and kind == socket.SCM_RIGHTS:
                a = array.array("i")
                a.frombytes(d[: len(d) - (len(d) % 4)])
                self.fds.extend(a)
        if not data:
            return False
        self.buf += data
        while len(self.buf) >= 8:
            obj, word = struct.unpack_from("<II", self.buf)
            size, op = word >> 16, word & 0xFFFF
            if len(self.buf) < size:
                break
            body = self.buf[8:size]
            self.buf = self.buf[size:]
            self.request(obj, op, body)
        return True

    def request(self, obj, op, body):
        iface = self.objects.get(obj, "")
        u = lambda i: struct.unpack_from("<I", body, 4 * i)[0]
        i32 = lambda i: struct.unpack_from("<i", body, 4 * i)[0]
        if iface == "wl_display" and op == 0:
            cb = u(0)
            self.send(cb, 0, struct.pack("<I", 0))
            self.send(1, 1, struct.pack("<I", cb))
        elif iface == "wl_display" and op == 1:
            reg = u(0)
            self.objects[reg] = "wl_registry"
            for n, (name, version) in enumerate(GLOBALS, 1):
                self.send(reg, 0, struct.pack("<I", n) + self.string(name) + struct.pack("<I", version))
        elif iface == "wl_registry" and op == 0:
            n = u(0)
            length = u(1)
            at = 8 + length + (-length % 4)
            _, new_id = struct.unpack_from("<II", body, at)
            name = GLOBALS[n - 1][0]
            self.objects[new_id] = name
            if name == "wl_shm":
                self.send(new_id, 0, struct.pack("<I", 0))
                self.send(new_id, 0, struct.pack("<I", 1))
            elif name == "xdg_toplevel_icon_manager_v1":
                self.send(new_id, 0, struct.pack("<i", 64))
                self.send(new_id, 1)
        elif iface == "wl_compositor" and op == 0:
            self.objects[u(0)] = "wl_surface"
        elif iface == "wl_surface" and op == 3:
            self.objects[u(0)] = "wl_callback"
        elif iface == "wl_surface" and op == 6:
            if obj == self.toplevel_surface and not self.configured:
                self.configured = True
                top, xdg = self.xdg_surface_of[obj]
                self.send(top, 0, struct.pack("<iiI", 0, 0, 0))
                self.send(xdg, 0, struct.pack("<I", self.serial))
        elif iface == "xdg_wm_base" and op == 2:
            self.objects[u(0)] = "xdg_surface"
            self.xdg_surface_of[u(0)] = u(1)
        elif iface == "xdg_surface" and op == 1:
            self.objects[u(0)] = "xdg_toplevel"
            surface = self.xdg_surface_of[obj]
            self.toplevel_surface = surface
            self.xdg_surface_of[surface] = (u(0), obj)
        elif iface == "wl_shm" and op == 0:
            self.objects[u(0)] = "wl_shm_pool"
            self.pools[u(0)] = (self.fds.pop(0), i32(1))
        elif iface == "wl_shm_pool" and op == 0:
            self.objects[u(0)] = "wl_buffer"
            self.buffers[u(0)] = (obj, i32(1), i32(2), i32(3), i32(4), u(5))
        elif iface == "xdg_toplevel_icon_manager_v1" and op == 1:
            self.objects[u(0)] = "xdg_toplevel_icon_v1"
            self.icons[u(0)] = []
        elif iface == "xdg_toplevel_icon_manager_v1" and op == 2:
            icon = u(1)
            top_ok = self.objects.get(u(0)) == "xdg_toplevel"
            self.set_icons.append({"toplevel": top_ok, "buffers": self.icons.get(icon, [])})
        elif iface == "xdg_toplevel_icon_v1" and op == 2:
            pool, offset, w, h, stride, fmt = self.buffers[u(0)]
            fd, size = self.pools[pool]
            with mmap.mmap(fd, size, prot=mmap.PROT_READ) as m:
                px = m[offset : offset + stride * h]
            self.icons[obj].append({"width": w, "height": h, "stride": stride, "format": fmt, "scale": i32(1), "pixels": px.hex()})


def main():
    path, out = sys.argv[1], sys.argv[2]
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(path)
    srv.listen(1)
    srv.settimeout(30)
    conn, _ = srv.accept()
    s = Server(conn)
    try:
        while s.read():
            pass
    except (ConnectionResetError, BrokenPipeError):
        pass
    with open(out, "w") as f:
        json.dump(s.set_icons, f)
    for fd, _ in s.pools.values():
        os.close(fd)


main()
