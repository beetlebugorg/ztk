#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-2-Clause
# Writes src/platform/wl/keysyms.zig from the X11 keysymdef.h, which has
# the license of The Open Group (a permissive license, in the output).
# Use: python3 -I tools/gen-keysyms.py /usr/include/X11/keysymdef.h > src/platform/wl/keysyms.zig
import re, sys
src = open(sys.argv[1]).read()
notice = src[src.index('Copyright 1987, 1994'):src.index('from The Open Group.') + len('from The Open Group.')]
names = {}
uni = {}
for m in re.finditer(r'^#define XK_(\w+)\s+0x([0-9a-fA-F]+)\s*(?:/\*\s*(\(?)U\+([0-9A-Fa-f]{4,6}))?', src, re.M):
    name, val, paren, cp = m.group(1), int(m.group(2), 16), m.group(3), m.group(4)
    names.setdefault(name, val)
    if cp and not paren and val not in uni and not (0x20 <= val <= 0xff):
        uni[val] = int(cp, 16)
out = sys.stdout
out.write('//! The names of the X11 key symbols and the Unicode code point of each\n')
out.write('//! symbol that has one. tools/gen-keysyms.py made this file from\n')
out.write('//! keysymdef.h of the X11 protocol headers, which has this notice:\n//!\n')
for line in notice.splitlines():
    out.write(('//! ' + line).rstrip() + '\n')
out.write('\npub const Name = struct { name: []const u8, sym: u32 };\n')
out.write('pub const Code = struct { sym: u32, cp: u21 };\n\n')
out.write('/// Sorted by name, for a binary search.\npub const names = [_]Name{\n')
for n in sorted(names):
    out.write('    .{ .name = "%s", .sym = 0x%x },\n' % (n, names[n]))
out.write('};\n\n/// Sorted by symbol: the symbols outside Latin-1 that have a code point.\npub const codes = [_]Code{\n')
for v in sorted(uni):
    out.write('    .{ .sym = 0x%x, .cp = 0x%x },\n' % (v, uni[v]))
out.write('};\n')
