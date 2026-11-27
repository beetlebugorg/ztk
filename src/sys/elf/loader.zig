//! A loader of ELF shared libraries for a static Linux program, so a
//! static ztk can use the Vulkan loader and the GPU driver of the system.
//!
//! A static program has no dynamic linker. `open` does its work:
//!
//! 1. Find the file: an absolute path, or a name in the folders of
//!    `LD_LIBRARY_PATH`, of the `DT_RUNPATH` or `DT_RPATH` of the library
//!    that needs it (with `$ORIGIN`), of `/etc/ld.so.conf`, and the
//!    default folders.
//! 2. Map each `PT_LOAD` segment at its offset from one base, in a span
//!    that is reserved first with no access, and zero the part past the
//!    file (`.bss`).
//! 3. Read `PT_DYNAMIC` and load each `DT_NEEDED` library the same way.
//!    The libraries of glibc (`libc.so.6`, `libm.so.6`, and the others of
//!    `glibc_names`) are not loaded. Their functions come from the C
//!    library of this program and from `shim.c`, by the table of
//!    `libc_names.zig`.
//! 4. Apply the relocations of `DT_RELA`, `DT_JMPREL`, and `DT_RELR`
//!    (x86-64: `RELATIVE`, `64`, `GLOB_DAT`, `JUMP_SLOT`, `IRELATIVE`,
//!    `DTPMOD64`, and `DTPOFF64`). A symbol is found first in the table,
//!    then in each loaded library in load order, with the GNU hash or the
//!    System V hash of the library and its version (`DT_VERSYM`,
//!    `DT_VERDEF`, `DT_VERNEED`). An `STT_GNU_IFUNC` symbol gives the
//!    address that its resolver returns. A function with no definition
//!    gets a stub that stops the program with its name when it runs.
//! 5. Make `PT_GNU_RELRO` read-only, and run `DT_INIT` and
//!    `DT_INIT_ARRAY` of each library after the libraries it needs.
//!
//! Thread-local storage uses the dynamic model only: `__tls_get_addr`
//! of this file gives each thread its own copy of the `PT_TLS` block of
//! a library, made at the first access. A relocation of the static model
//! (`TPOFF64`) cannot use the TLS of the static C library, so the load
//! fails with that reason. `dlopen`, `dlsym`, `dladdr`, and
//! `dl_iterate_phdr` of the table use the same modules, so the Vulkan
//! loader can open a driver and the unwinder of C++ finds the frames.
//!
//! The code follows the System V gABI (the ELF format), the x86-64 psABI
//! (the relocations), and the paper "ELF Handling For Thread-Local
//! Storage" (docs/references/elf-loader.md). A library is never unloaded.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

/// True where the loader works: a static x86-64 Linux program.
pub const supported = builtin.os.tag == .linux and builtin.cpu.arch == .x86_64 and builtin.link_mode == .static and builtin.link_libc;

pub const Error = error{ NotFound, BadElf, Unsupported, Unresolved, OutOfMemory, MapFailed };

const page = 4096;

// ---- The structures and numbers of the gABI ----

const Ehdr = extern struct { e_ident: [16]u8, e_type: u16, e_machine: u16, e_version: u32, e_entry: u64, e_phoff: u64, e_shoff: u64, e_flags: u32, e_ehsize: u16, e_phentsize: u16, e_phnum: u16, e_shentsize: u16, e_shnum: u16, e_shstrndx: u16 };
const Phdr = extern struct { p_type: u32, p_flags: u32, p_offset: u64, p_vaddr: u64, p_paddr: u64, p_filesz: u64, p_memsz: u64, p_align: u64 };
const Dyn = extern struct { d_tag: i64, d_val: u64 };
const Sym = extern struct {
    st_name: u32,
    st_info: u8,
    st_other: u8,
    st_shndx: u16,
    st_value: u64,
    st_size: u64,
    fn bind(s: Sym) u8 {
        return s.st_info >> 4;
    }
    fn kind(s: Sym) u8 {
        return s.st_info & 0xf;
    }
};
const Rela = extern struct { r_offset: u64, r_info: u64, r_addend: i64 };
const Verdef = extern struct { vd_version: u16, vd_flags: u16, vd_ndx: u16, vd_cnt: u16, vd_hash: u32, vd_aux: u32, vd_next: u32 };
const Verdaux = extern struct { vda_name: u32, vda_next: u32 };
const Verneed = extern struct { vn_version: u16, vn_cnt: u16, vn_file: u32, vn_aux: u32, vn_next: u32 };
const Vernaux = extern struct { vna_hash: u32, vna_flags: u16, vna_other: u16, vna_name: u32, vna_next: u32 };

const ET_DYN = 3;
const EM_X86_64 = 62;
const PT_LOAD = 1;
const PT_DYNAMIC = 2;
const PT_TLS = 7;
const PT_GNU_RELRO = 0x6474e552;
const PF_X = 1;
const PF_W = 2;
const PF_R = 4;
const STB_LOCAL = 0;
const STB_WEAK = 2;
const STT_NOTYPE = 0;
const STT_FUNC = 2;
const STT_GNU_IFUNC = 10;
const SHN_UNDEF = 0;
const DT_NULL = 0;
const DT_NEEDED = 1;
const DT_PLTRELSZ = 2;
const DT_HASH = 4;
const DT_STRTAB = 5;
const DT_SYMTAB = 6;
const DT_RELA = 7;
const DT_RELASZ = 8;
const DT_INIT = 12;
const DT_SONAME = 14;
const DT_RPATH = 15;
const DT_REL = 17;
const DT_TEXTREL = 22;
const DT_JMPREL = 23;
const DT_INIT_ARRAY = 25;
const DT_INIT_ARRAYSZ = 27;
const DT_RUNPATH = 29;
const DT_RELRSZ = 35;
const DT_RELR = 36;
const DT_GNU_HASH = 0x6ffffef5;
const DT_VERSYM = 0x6ffffff0;
const DT_VERDEF = 0x6ffffffc;
const DT_VERDEFNUM = 0x6ffffffd;
const DT_VERNEED = 0x6ffffffe;
const DT_VERNEEDNUM = 0x6fffffff;

/// The libraries of glibc. Their functions come from this program.
const glibc_names = [_][]const u8{ "libc.so.6", "libm.so.6", "libpthread.so.0", "libdl.so.2", "librt.so.1", "libutil.so.1", "libresolv.so.2", "ld-linux-x86-64.so.2" };

const Module = struct {
    name: []const u8,
    path: [:0]const u8,
    base: usize,
    map_start: usize,
    map_len: usize,
    phdr: [*]const Phdr,
    phnum: u16,
    dynamic: [*]const Dyn,
    symtab: [*]const Sym = undefined,
    strtab: [*:0]const u8 = undefined,
    gnu_hash: ?[*]const u32 = null,
    sysv_hash: ?[*]const u32 = null,
    versym: ?[*]const u16 = null,
    /// The name of each version index of DT_VERDEF and DT_VERNEED.
    versions: []?[*:0]const u8 = &.{},
    needed: []*Module = &.{},
    tls_id: usize = 0,
    relro: ?[2]usize = null,
    inited: bool = false,

    fn str(m: *const Module, off: usize) [*:0]const u8 {
        return m.strtab + off;
    }

    fn dyn(m: *const Module, tag: i64) ?u64 {
        var i: usize = 0;
        while (m.dynamic[i].d_tag != DT_NULL) : (i += 1) if (m.dynamic[i].d_tag == tag) return m.dynamic[i].d_val;
        return null;
    }
};

const Tls = struct { image: usize, filesz: usize, memsz: usize, alignment: usize };

var lock: std.c.pthread_mutex_t = .{};
/// The thread that holds `lock`, and its depth: an init function can call
/// dlopen or dladdr while `open` holds the lock.
var lock_owner = std.atomic.Value(i32).init(0);
var lock_depth: u32 = 0;

fn lockIt() void {
    const me: i32 = @intCast(linux.gettid());
    if (lock_owner.load(.monotonic) == me) {
        lock_depth += 1;
        return;
    }
    _ = std.c.pthread_mutex_lock(&lock);
    lock_owner.store(me, .monotonic);
    lock_depth = 1;
}

fn unlockIt() void {
    lock_depth -= 1;
    if (lock_depth > 0) return;
    lock_owner.store(0, .monotonic);
    _ = std.c.pthread_mutex_unlock(&lock);
}
var modules: std.ArrayList(*Module) = .empty;
var reason_buf: [512]u8 = undefined;
var reason_len: usize = 0;
var reason_new = false;
/// The TLS blocks of the modules, by module id - 1. The array has a fixed
/// size, so `__tls_get_addr` reads it without the lock.
var tls_mods: [64]Tls = undefined;
var tls_count = std.atomic.Value(usize).init(0);
var search_dirs: ?[]const []const u8 = null;

fn gpa() std.mem.Allocator {
    return std.heap.c_allocator;
}

fn setReason(comptime fmt: []const u8, args: anytype) void {
    const s: []u8 = std.fmt.bufPrint(&reason_buf, fmt, args) catch &reason_buf;
    reason_len = s.len;
    reason_new = true;
}

/// The reason of the last failure of `open` or `sym`.
pub fn lastError() []const u8 {
    return reason_buf[0..reason_len];
}

pub const Handle = *Module;

/// Loads the library `name` (a path, or a name to search for) and the
/// libraries it needs, and runs their init functions. A library that is
/// already loaded gives the same handle.
pub fn open(name: []const u8) Error!Handle {
    if (!supported) {
        setReason("{s}: the ELF loader works only in a static x86-64 Linux program", .{name});
        return error.Unsupported;
    }
    lockIt();
    defer unlockIt();
    const start = modules.items.len;
    const m = load(name, null) catch |e| {
        // The modules of a failed load stay mapped, but no symbol search
        // uses them.
        modules.shrinkRetainingCapacity(start);
        return e;
    };
    for (modules.items[start..]) |mod| relocate(mod) catch |e| {
        modules.shrinkRetainingCapacity(start);
        return e;
    };
    runInit(m);
    return m;
}

/// The address of the symbol `name` of `h` or of the libraries it needs,
/// or null.
pub fn sym(h: Handle, name: [*:0]const u8) ?*anyopaque {
    lockIt();
    defer unlockIt();
    if (scopedLookup(h, std.mem.span(name), null)) |v| return @ptrFromInt(v);
    setReason("{s}: no symbol {s}", .{ h.name, name });
    return null;
}

// ---- Finding a file ----

fn isGlibc(name: []const u8) bool {
    for (glibc_names) |g| if (std.mem.eql(u8, g, name)) return true;
    return false;
}

fn defaultDirs() []const []const u8 {
    if (search_dirs) |d| return d;
    var list: std.ArrayList([]const u8) = .empty;
    readConf(&list, "/etc/ld.so.conf", 0);
    for ([_][]const u8{ "/lib64", "/usr/lib64", "/lib/x86_64-linux-gnu", "/usr/lib/x86_64-linux-gnu", "/lib", "/usr/lib" }) |d| list.append(gpa(), d) catch {};
    search_dirs = list.items;
    return list.items;
}

/// Reads the folders of an ld.so.conf file: one folder on each line, `#`
/// comments, and `include PATTERN` lines with one `*` in the last part.
fn readConf(list: *std.ArrayList([]const u8), path: []const u8, depth: u32) void {
    if (depth > 4) return;
    const text = readWhole(path) orelse return;
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw[0 .. std.mem.indexOfScalar(u8, raw, '#') orelse raw.len], " \t");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "include")) {
            const pat = std.mem.trim(u8, line[7..], " \t");
            const dir = std.fs.path.dirname(pat) orelse continue;
            const base = std.fs.path.basename(pat);
            const star = std.mem.indexOfScalar(u8, base, '*') orelse {
                readConf(list, pat, depth + 1);
                continue;
            };
            var names: std.ArrayList([]const u8) = .empty;
            listDir(dir, &names);
            std.mem.sort([]const u8, names.items, {}, struct {
                fn lt(_: void, x: []const u8, y: []const u8) bool {
                    return std.mem.lessThan(u8, x, y);
                }
            }.lt);
            for (names.items) |n| {
                if (!std.mem.startsWith(u8, n, base[0..star]) or !std.mem.endsWith(u8, n, base[star + 1 ..])) continue;
                const full = std.fs.path.join(gpa(), &.{ dir, n }) catch continue;
                readConf(list, full, depth + 1);
            }
        } else list.append(gpa(), gpa().dupe(u8, line) catch continue) catch {};
    }
}

fn readWhole(path: []const u8) ?[]u8 {
    const z = gpa().dupeSentinel(u8, path, 0) catch return null;
    const fd = std.c.open(z, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    if (fd < 0) return null;
    defer _ = std.c.close(fd);
    var out: std.ArrayList(u8) = .empty;
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = std.c.read(fd, &buf, buf.len);
        if (n <= 0) break;
        out.appendSlice(gpa(), buf[0..@intCast(n)]) catch return null;
    }
    return out.items;
}

fn listDir(dir: []const u8, out: *std.ArrayList([]const u8)) void {
    const z = gpa().dupeSentinel(u8, dir, 0) catch return;
    const d = std.c.opendir(z) orelse return;
    defer _ = std.c.closedir(d);
    while (std.c.readdir(d)) |e| {
        const n = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&e.name)), 0);
        if (n[0] == '.') continue;
        out.append(gpa(), gpa().dupe(u8, n) catch continue) catch {};
    }
}

/// Opens the first file of `name` in the folders that is an x86-64 ELF
/// shared library. Gives the descriptor and the path.
const Opened = struct { fd: c_int, path: [:0]u8 };

fn find(name: []const u8, by: ?*Module) ?Opened {
    if (std.mem.indexOfScalar(u8, name, '/') != null) return tryOpen(name);
    var dirs: std.ArrayList([]const u8) = .empty;
    if (by) |m| {
        const runpath = m.dyn(DT_RUNPATH);
        if (runpath == null) if (m.dyn(DT_RPATH)) |rp| addPath(&dirs, std.mem.span(m.str(rp)), m);
        if (std.c.getenv("LD_LIBRARY_PATH")) |lp| addPath(&dirs, std.mem.span(lp), null);
        if (runpath) |rp| addPath(&dirs, std.mem.span(m.str(rp)), m);
    } else if (std.c.getenv("LD_LIBRARY_PATH")) |lp| addPath(&dirs, std.mem.span(lp), null);
    dirs.appendSlice(gpa(), defaultDirs()) catch {};
    for (dirs.items) |d| {
        const full = std.fs.path.join(gpa(), &.{ d, name }) catch continue;
        if (tryOpen(full)) |r| return r;
    }
    return null;
}

fn addPath(dirs: *std.ArrayList([]const u8), list: []const u8, origin: ?*Module) void {
    var parts = std.mem.tokenizeScalar(u8, list, ':');
    while (parts.next()) |p| {
        if (std.mem.startsWith(u8, p, "$ORIGIN") or std.mem.startsWith(u8, p, "${ORIGIN}")) {
            const m = origin orelse continue;
            const rest = p[(if (p[1] == '{') 9 else 7)..];
            const dir = std.fs.path.dirname(m.path) orelse continue;
            dirs.append(gpa(), std.mem.concat(gpa(), u8, &.{ dir, rest }) catch continue) catch {};
        } else dirs.append(gpa(), p) catch {};
    }
}

fn tryOpen(path: []const u8) ?Opened {
    const z = gpa().dupeSentinel(u8, path, 0) catch return null;
    const fd = std.c.open(z, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    if (fd < 0) return null;
    var eh: Ehdr = undefined;
    const n = std.c.pread(fd, @ptrCast(&eh), @sizeOf(Ehdr), 0);
    if (n != @sizeOf(Ehdr) or !std.mem.eql(u8, eh.e_ident[0..4], "\x7fELF") or eh.e_ident[4] != 2 or eh.e_ident[5] != 1 or eh.e_machine != EM_X86_64 or eh.e_type != ET_DYN) {
        _ = std.c.close(fd);
        return null;
    }
    return .{ .fd = fd, .path = z };
}

// ---- Mapping ----

fn findLoaded(name: []const u8) ?*Module {
    for (modules.items) |m| {
        if (std.mem.eql(u8, m.name, name) or std.mem.eql(u8, m.path, name)) return m;
    }
    return null;
}

fn load(name: []const u8, by: ?*Module) Error!*Module {
    if (findLoaded(name)) |m| return m;
    const f = find(name, by) orelse {
        setReason("{s}: no such library", .{name});
        return error.NotFound;
    };
    defer _ = std.c.close(f.fd);
    const m = try mapFile(f.fd, f.path);
    m.name = if (m.dyn(DT_SONAME)) |so| std.mem.span(m.str(so)) else gpa().dupe(u8, name) catch return error.OutOfMemory;
    if (findLoaded(m.name)) |old| return old;
    modules.append(gpa(), m) catch return error.OutOfMemory;
    var needed: std.ArrayList(*Module) = .empty;
    var i: usize = 0;
    while (m.dynamic[i].d_tag != DT_NULL) : (i += 1) {
        if (m.dynamic[i].d_tag != DT_NEEDED) continue;
        const dep = std.mem.span(m.str(m.dynamic[i].d_val));
        if (isGlibc(dep)) continue;
        const d = try load(dep, m);
        needed.append(gpa(), d) catch return error.OutOfMemory;
    }
    m.needed = needed.items;
    return m;
}

fn mapFile(fd: c_int, path: [:0]const u8) Error!*Module {
    var eh: Ehdr = undefined;
    if (std.c.pread(fd, @ptrCast(&eh), @sizeOf(Ehdr), 0) != @sizeOf(Ehdr)) return error.BadElf;
    if (eh.e_phentsize != @sizeOf(Phdr) or eh.e_phnum == 0 or eh.e_phnum > 64) {
        setReason("{s}: bad program headers", .{path});
        return error.BadElf;
    }
    var ph: [64]Phdr = undefined;
    const ph_len = @as(usize, eh.e_phnum) * @sizeOf(Phdr);
    if (std.c.pread(fd, @ptrCast(&ph), ph_len, @intCast(eh.e_phoff)) != @as(isize, @intCast(ph_len))) return error.BadElf;
    const phs = ph[0..eh.e_phnum];
    var lo: usize = std.math.maxInt(usize);
    var hi: usize = 0;
    var max_align: usize = page;
    for (phs) |p| if (p.p_type == PT_LOAD) {
        lo = @min(lo, std.mem.alignBackward(usize, p.p_vaddr, page));
        hi = @max(hi, std.mem.alignForward(usize, p.p_vaddr + p.p_memsz, page));
        if (p.p_align > max_align and p.p_align <= 1 << 21) max_align = p.p_align;
    };
    if (hi <= lo) {
        setReason("{s}: no PT_LOAD segment", .{path});
        return error.BadElf;
    }
    // Reserve the span with room to align the base to the largest p_align.
    const span = hi - lo;
    const res = std.c.mmap(null, span + max_align, .{}, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
    if (res == std.c.MAP_FAILED) return error.MapFailed;
    const res_addr = @intFromPtr(res);
    const start = std.mem.alignForward(usize, res_addr, max_align);
    if (start > res_addr) _ = std.c.munmap(@ptrFromInt(res_addr), start - res_addr);
    const end_res = res_addr + span + max_align;
    if (end_res > start + span) _ = std.c.munmap(@ptrFromInt(start + span), end_res - (start + span));
    const base = start - lo;

    var dynamic: ?usize = null;
    var phdr_addr: ?usize = null;
    var tls: ?Phdr = null;
    var relro: ?[2]usize = null;
    for (phs) |p| switch (p.p_type) {
        PT_LOAD => {
            const prot: std.c.PROT = .{ .READ = p.p_flags & PF_R != 0, .WRITE = p.p_flags & PF_W != 0, .EXEC = p.p_flags & PF_X != 0 };
            const seg = base + std.mem.alignBackward(usize, p.p_vaddr, page);
            const off = std.mem.alignBackward(usize, p.p_offset, page);
            const file_end = base + p.p_vaddr + p.p_filesz;
            const mem_end = base + p.p_vaddr + p.p_memsz;
            if (p.p_filesz > 0) {
                const len = file_end - seg;
                var wprot = prot;
                if (p.p_memsz > p.p_filesz) wprot.WRITE = true;
                const r = std.c.mmap(@ptrFromInt(seg), len, wprot, .{ .TYPE = .PRIVATE, .FIXED = true }, fd, @intCast(off));
                if (r == std.c.MAP_FAILED) return error.MapFailed;
            }
            if (p.p_memsz > p.p_filesz) {
                // Zero the rest of the last file page, then map zero pages.
                const zero_page_end = @min(std.mem.alignForward(usize, file_end, page), mem_end);
                if (p.p_filesz > 0 and zero_page_end > file_end) @memset(@as([*]u8, @ptrFromInt(file_end))[0 .. zero_page_end - file_end], 0);
                const anon = if (p.p_filesz > 0) std.mem.alignForward(usize, file_end, page) else seg;
                const anon_end = std.mem.alignForward(usize, mem_end, page);
                if (anon_end > anon) {
                    const r = std.c.mmap(@ptrFromInt(anon), anon_end - anon, prot, .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .FIXED = true }, -1, 0);
                    if (r == std.c.MAP_FAILED) return error.MapFailed;
                }
                if (p.p_filesz > 0 and !prot.WRITE) _ = std.c.mprotect(@ptrFromInt(seg), std.mem.alignForward(usize, file_end, page) - seg, prot);
            }
            if (eh.e_phoff >= p.p_offset and eh.e_phoff + ph_len <= p.p_offset + p.p_filesz) phdr_addr = base + p.p_vaddr + (eh.e_phoff - p.p_offset);
        },
        PT_DYNAMIC => dynamic = base + p.p_vaddr,
        PT_TLS => tls = p,
        PT_GNU_RELRO => relro = .{ base + std.mem.alignBackward(usize, p.p_vaddr, page), base + std.mem.alignBackward(usize, p.p_vaddr + p.p_memsz, page) },
        else => {},
    };
    const dyn_addr = dynamic orelse {
        setReason("{s}: no PT_DYNAMIC", .{path});
        return error.BadElf;
    };
    // The program headers in memory, for dl_iterate_phdr.
    const phdr: [*]const Phdr = if (phdr_addr) |a| @ptrFromInt(a) else (gpa().dupe(Phdr, phs) catch return error.OutOfMemory).ptr;
    const m = gpa().create(Module) catch return error.OutOfMemory;
    m.* = .{ .name = "", .path = path, .base = base, .map_start = start, .map_len = span, .phdr = phdr, .phnum = eh.e_phnum, .dynamic = @ptrFromInt(dyn_addr), .relro = relro };
    try readDynamic(m);
    if (tls) |p| {
        const id = tls_count.load(.acquire);
        if (id >= tls_mods.len) {
            setReason("{s}: more than {d} libraries with TLS", .{ path, tls_mods.len });
            return error.Unsupported;
        }
        tls_mods[id] = .{ .image = base + p.p_vaddr, .filesz = p.p_filesz, .memsz = p.p_memsz, .alignment = @max(p.p_align, 16) };
        tls_count.store(id + 1, .release);
        m.tls_id = id + 1;
    }
    return m;
}

fn readDynamic(m: *Module) Error!void {
    var vers_max: usize = 0;
    var i: usize = 0;
    while (m.dynamic[i].d_tag != DT_NULL) : (i += 1) {
        const d = m.dynamic[i];
        const addr = m.base + d.d_val;
        switch (d.d_tag) {
            DT_STRTAB => m.strtab = @ptrFromInt(addr),
            DT_SYMTAB => m.symtab = @ptrFromInt(addr),
            DT_GNU_HASH => m.gnu_hash = @ptrFromInt(addr),
            DT_HASH => m.sysv_hash = @ptrFromInt(addr),
            DT_VERSYM => m.versym = @ptrFromInt(addr),
            DT_REL, DT_TEXTREL => {
                setReason("{s}: DT_REL or a text relocation", .{m.path});
                return error.Unsupported;
            },
            else => {},
        }
    }
    if (m.gnu_hash == null and m.sysv_hash == null) {
        setReason("{s}: no symbol hash table", .{m.path});
        return error.BadElf;
    }
    // The version names: DT_VERDEF gives the versions of this module,
    // DT_VERNEED the versions it needs from others.
    if (m.dyn(DT_VERDEF)) |vd| {
        var at = m.base + vd;
        var n = m.dyn(DT_VERDEFNUM) orelse 0;
        while (n > 0) : (n -= 1) {
            const v: *const Verdef = @ptrFromInt(at);
            vers_max = @max(vers_max, v.vd_ndx);
            if (v.vd_next == 0) break;
            at += v.vd_next;
        }
    }
    if (m.dyn(DT_VERNEED)) |vn| {
        var at = m.base + vn;
        var n = m.dyn(DT_VERNEEDNUM) orelse 0;
        while (n > 0) : (n -= 1) {
            const v: *const Verneed = @ptrFromInt(at);
            var aux_at = at + v.vn_aux;
            var k: usize = 0;
            while (k < v.vn_cnt) : (k += 1) {
                const a: *const Vernaux = @ptrFromInt(aux_at);
                vers_max = @max(vers_max, a.vna_other);
                if (a.vna_next == 0) break;
                aux_at += a.vna_next;
            }
            if (v.vn_next == 0) break;
            at += v.vn_next;
        }
    }
    const names = gpa().alloc(?[*:0]const u8, vers_max + 1) catch return error.OutOfMemory;
    @memset(names, null);
    if (m.dyn(DT_VERDEF)) |vd| {
        var at = m.base + vd;
        var n = m.dyn(DT_VERDEFNUM) orelse 0;
        while (n > 0) : (n -= 1) {
            const v: *const Verdef = @ptrFromInt(at);
            const aux: *const Verdaux = @ptrFromInt(at + v.vd_aux);
            names[v.vd_ndx] = m.str(aux.vda_name);
            if (v.vd_next == 0) break;
            at += v.vd_next;
        }
    }
    if (m.dyn(DT_VERNEED)) |vn| {
        var at = m.base + vn;
        var n = m.dyn(DT_VERNEEDNUM) orelse 0;
        while (n > 0) : (n -= 1) {
            const v: *const Verneed = @ptrFromInt(at);
            var aux_at = at + v.vn_aux;
            var k: usize = 0;
            while (k < v.vn_cnt) : (k += 1) {
                const a: *const Vernaux = @ptrFromInt(aux_at);
                names[a.vna_other] = m.str(a.vna_name);
                if (a.vna_next == 0) break;
                aux_at += a.vna_next;
            }
            if (v.vn_next == 0) break;
            at += v.vn_next;
        }
    }
    m.versions = names;
}

// ---- Symbols ----

fn gnuHash(name: []const u8) u32 {
    var h: u32 = 5381;
    for (name) |c| h = h *% 33 +% c;
    return h;
}

fn sysvHash(name: []const u8) u32 {
    var h: u32 = 0;
    for (name) |c| {
        h = (h << 4) +% c;
        const g = h & 0xf0000000;
        if (g != 0) h ^= g >> 24;
        h &= ~g;
    }
    return h;
}

/// The index of the defined symbol `name` of `m` that fits the version
/// `ver`, or null.
fn lookupIn(m: *const Module, name: []const u8, ver: ?[]const u8) ?usize {
    if (m.gnu_hash) |h| {
        const nbuckets = h[0];
        const symoffset = h[1];
        const bloom_size = h[2];
        const shift: u5 = @intCast(h[3] & 31);
        const bloom: [*]align(4) const u64 = @ptrCast(h + 4);
        const buckets = h + 4 + bloom_size * 2;
        const chain = buckets + nbuckets;
        const hv = gnuHash(name);
        const word = bloom[(hv / 64) % bloom_size];
        const mask = (@as(u64, 1) << @intCast(hv % 64)) | (@as(u64, 1) << @intCast((hv >> shift) % 64));
        if (word & mask != mask) return null;
        var i = buckets[hv % nbuckets];
        if (i < symoffset) return null;
        while (true) : (i += 1) {
            const h2 = chain[i - symoffset];
            if ((hv | 1) == (h2 | 1) and fits(m, i, name, ver)) return i;
            if (h2 & 1 != 0) return null;
        }
    }
    const h = m.sysv_hash.?;
    const nbucket = h[0];
    const buckets = h + 2;
    const chains = buckets + nbucket;
    var i = buckets[sysvHash(name) % nbucket];
    while (i != 0) : (i = chains[i]) if (fits(m, i, name, ver)) return i;
    return null;
}

fn fits(m: *const Module, i: usize, name: []const u8, ver: ?[]const u8) bool {
    const s = m.symtab[i];
    if (s.st_shndx == SHN_UNDEF or s.bind() == STB_LOCAL) return false;
    if (!std.mem.eql(u8, std.mem.span(m.str(s.st_name)), name)) return false;
    const vs = m.versym orelse return true;
    const idx = vs[i] & 0x7fff;
    const hidden = vs[i] & 0x8000 != 0;
    if (ver) |want| {
        if (idx < 2) return true;
        const have = if (idx < m.versions.len) m.versions[idx] else null;
        return have != null and std.mem.eql(u8, std.mem.span(have.?), want);
    }
    return !hidden;
}

/// The address of a defined symbol, after the resolver of an IFUNC.
fn symAddr(m: *const Module, i: usize) usize {
    const s = m.symtab[i];
    const a = m.base + s.st_value;
    if (s.kind() == STT_GNU_IFUNC) {
        const resolver: *const fn () callconv(.c) usize = @ptrFromInt(a);
        return resolver();
    }
    return a;
}

const Found = struct { mod: ?*const Module, index: usize, addr: usize };

/// The definition of `name` in the table of this program or in a loaded
/// library, in that order.
fn globalLookup(name: []const u8, ver: ?[]const u8) ?Found {
    if (ver == null or std.mem.startsWith(u8, ver.?, "GLIBC_")) {
        if (bridge.get(name)) |a| return .{ .mod = null, .index = 0, .addr = a };
    }
    for (modules.items) |m| if (lookupIn(m, name, ver)) |i| return .{ .mod = m, .index = i, .addr = symAddr(m, i) };
    return null;
}

/// dlsym of a handle: the module, then the modules it needs, breadth first.
fn scopedLookup(h: *Module, name: []const u8, ver: ?[]const u8) ?usize {
    var queue: std.ArrayList(*Module) = .empty;
    defer queue.deinit(gpa());
    queue.append(gpa(), h) catch return null;
    var k: usize = 0;
    while (k < queue.items.len) : (k += 1) {
        const m = queue.items[k];
        if (lookupIn(m, name, ver)) |i| return symAddr(m, i);
        for (m.needed) |d| {
            if (std.mem.indexOfScalar(*Module, queue.items, d) == null) queue.append(gpa(), d) catch return null;
        }
    }
    if (bridge.get(name)) |a| return a;
    return null;
}

// ---- Relocation ----

const R_X86_64_NONE = 0;
const R_X86_64_64 = 1;
const R_X86_64_COPY = 5;
const R_X86_64_GLOB_DAT = 6;
const R_X86_64_JUMP_SLOT = 7;
const R_X86_64_RELATIVE = 8;
const R_X86_64_DTPMOD64 = 16;
const R_X86_64_DTPOFF64 = 17;
const R_X86_64_TPOFF64 = 18;
const R_X86_64_IRELATIVE = 37;

const Missing = struct { at: usize, name: [*:0]const u8 };

fn relocate(m: *Module) Error!void {
    var missing: std.ArrayList(Missing) = .empty;
    defer missing.deinit(gpa());
    // DT_RELR: the relative relocations as addresses and bitmaps.
    if (m.dyn(DT_RELR)) |relr| {
        const n = (m.dyn(DT_RELRSZ) orelse 0) / 8;
        const ents: [*]const u64 = @ptrFromInt(m.base + relr);
        var where: usize = 0;
        for (ents[0..n]) |e| {
            if (e & 1 == 0) {
                where = m.base + e;
                @as(*usize, @ptrFromInt(where)).* += m.base;
                where += 8;
            } else {
                var bits = e >> 1;
                var k: usize = 0;
                while (bits != 0) : ({
                    bits >>= 1;
                    k += 1;
                }) if (bits & 1 != 0) {
                    @as(*usize, @ptrFromInt(where + k * 8)).* += m.base;
                };
                where += 63 * 8;
            }
        }
    }
    if (m.dyn(DT_RELA)) |rela| try applyRela(m, @ptrFromInt(m.base + rela), (m.dyn(DT_RELASZ) orelse 0) / @sizeOf(Rela), &missing);
    if (m.dyn(DT_JMPREL)) |jr| try applyRela(m, @ptrFromInt(m.base + jr), (m.dyn(DT_PLTRELSZ) orelse 0) / @sizeOf(Rela), &missing);
    if (missing.items.len > 0) try makeStubs(missing.items);
    if (m.relro) |r| if (r[1] > r[0]) {
        _ = std.c.mprotect(@ptrFromInt(r[0]), r[1] - r[0], .{ .READ = true });
    };
}

fn applyRela(m: *Module, relas: [*]const Rela, n: usize, missing: *std.ArrayList(Missing)) Error!void {
    var irel: std.ArrayList(Rela) = .empty;
    defer irel.deinit(gpa());
    for (relas[0..n]) |r| {
        const at = m.base + r.r_offset;
        const slot: *usize = @ptrFromInt(at);
        const ty: u32 = @truncate(r.r_info);
        const si: u32 = @truncate(r.r_info >> 32);
        const addend: usize = @bitCast(r.r_addend);
        switch (ty) {
            R_X86_64_NONE => {},
            R_X86_64_RELATIVE => slot.* = m.base +% addend,
            // An IRELATIVE resolver can call a function of the module, so
            // it runs after the other relocations.
            R_X86_64_IRELATIVE => irel.append(gpa(), r) catch return error.OutOfMemory,
            R_X86_64_64, R_X86_64_GLOB_DAT, R_X86_64_JUMP_SLOT => {
                const s = m.symtab[si];
                const name = std.mem.span(m.str(s.st_name));
                const f = resolve(m, si) orelse {
                    if (s.bind() == STB_WEAK) {
                        slot.* = 0;
                        continue;
                    }
                    if (ty == R_X86_64_JUMP_SLOT or s.kind() == STT_FUNC or s.kind() == STT_NOTYPE) {
                        missing.append(gpa(), .{ .at = at, .name = m.str(s.st_name) }) catch return error.OutOfMemory;
                        continue;
                    }
                    setReason("{s}: the object {s} has no definition", .{ m.name, name });
                    return error.Unresolved;
                };
                slot.* = if (ty == R_X86_64_64) f.addr +% addend else f.addr;
            },
            R_X86_64_DTPMOD64 => {
                if (si == 0) {
                    slot.* = m.tls_id;
                } else {
                    const f = resolve(m, si) orelse return unresolvedTls(m, si);
                    slot.* = if (f.mod) |d| d.tls_id else 0;
                }
            },
            R_X86_64_DTPOFF64 => {
                if (si == 0) {
                    slot.* = addend;
                } else {
                    const f = resolve(m, si) orelse return unresolvedTls(m, si);
                    const d = f.mod orelse return unresolvedTls(m, si);
                    slot.* = d.symtab[f.index].st_value +% addend;
                }
            },
            R_X86_64_TPOFF64 => {
                setReason("{s}: initial-exec TLS (R_X86_64_TPOFF64) needs the static TLS of glibc", .{m.name});
                return error.Unsupported;
            },
            R_X86_64_COPY => {
                setReason("{s}: R_X86_64_COPY in a library", .{m.name});
                return error.Unsupported;
            },
            else => {
                setReason("{s}: relocation type {d} is not supported", .{ m.name, ty });
                return error.Unsupported;
            },
        }
    }
    for (irel.items) |r| {
        const resolver: *const fn () callconv(.c) usize = @ptrFromInt(m.base +% @as(usize, @bitCast(r.r_addend)));
        @as(*usize, @ptrFromInt(m.base + r.r_offset)).* = resolver();
    }
}

fn unresolvedTls(m: *const Module, si: u32) Error {
    setReason("{s}: the TLS symbol {s} has no definition", .{ m.name, m.str(m.symtab[si].st_name) });
    return error.Unresolved;
}

/// The definition of symbol `si` of `m`: its own definition when it has
/// one and the symbol is not preemptible is the result of the global
/// search too, as the module is in the global list.
fn resolve(m: *const Module, si: u32) ?Found {
    const s = m.symtab[si];
    const name = std.mem.span(m.str(s.st_name));
    var ver: ?[]const u8 = null;
    if (m.versym) |vs| {
        const idx = vs[si] & 0x7fff;
        if (idx >= 2 and idx < m.versions.len) if (m.versions[idx]) |v| {
            ver = std.mem.span(v);
        };
    }
    if (s.bind() == STB_LOCAL) {
        if (s.st_shndx == SHN_UNDEF) return null;
        return .{ .mod = m, .index = si, .addr = symAddr(m, si) };
    }
    return globalLookup(name, ver);
}

/// Points each missing function at a stub: `mov rdi, name; mov rax,
/// missingFn; jmp rax`.
fn makeStubs(list: []const Missing) Error!void {
    const size = 24;
    const len = std.mem.alignForward(usize, list.len * size, page);
    const mem = std.c.mmap(null, len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
    if (mem == std.c.MAP_FAILED) return error.MapFailed;
    const code: [*]u8 = @ptrCast(mem);
    for (list, 0..) |mis, k| {
        const c = code + k * size;
        c[0] = 0x48;
        c[1] = 0xbf;
        std.mem.writeInt(u64, c[2..10], @intFromPtr(mis.name), .little);
        c[10] = 0x48;
        c[11] = 0xb8;
        std.mem.writeInt(u64, c[12..20], @intFromPtr(&missingFn), .little);
        c[20] = 0xff;
        c[21] = 0xe0;
        @as(*usize, @ptrFromInt(mis.at)).* = @intFromPtr(c);
    }
    _ = std.c.mprotect(@alignCast(mem), len, .{ .READ = true, .EXEC = true });
}

fn missingFn(name: [*:0]const u8) callconv(.c) noreturn {
    var buf: [256]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "ztk: a loaded library called {s}, which has no definition\n", .{name}) catch "ztk: a loaded library called a function with no definition\n";
    _ = std.c.write(2, s.ptr, s.len);
    std.c.abort();
}

// ---- Init ----

extern "c" var environ: [*:null]?[*:0]u8;

fn runInit(m: *Module) void {
    if (m.inited) return;
    m.inited = true;
    for (m.needed) |d| runInit(d);
    var argv = [_:null]?[*:0]u8{null};
    const Init = *const fn (c_int, [*:null]?[*:0]u8, [*:null]?[*:0]u8) callconv(.c) void;
    if (m.dyn(DT_INIT)) |a| @as(Init, @ptrFromInt(m.base + a))(0, &argv, environ);
    if (m.dyn(DT_INIT_ARRAY)) |a| {
        const n = (m.dyn(DT_INIT_ARRAYSZ) orelse 0) / 8;
        const fns: [*]const usize = @ptrFromInt(m.base + a);
        for (fns[0..n]) |f| if (f != 0 and f != std.math.maxInt(usize)) @as(Init, @ptrFromInt(f))(0, &argv, environ);
    }
}

// ---- TLS ----

extern "c" fn aligned_alloc(alignment: usize, size: usize) ?*anyopaque;

threadlocal var dtv: [64]?[*]u8 = @splat(null);

/// `__tls_get_addr` for the loaded libraries: the argument is the module
/// id and the offset of a `tls_index`.
fn tlsGetAddr(ti: *const [2]usize) callconv(.c) ?*anyopaque {
    const id = ti[0];
    if (id == 0 or id > tls_count.load(.acquire)) return null;
    const block = dtv[id - 1] orelse blk: {
        const m = tls_mods[id - 1];
        const mem = aligned_alloc(m.alignment, std.mem.alignForward(usize, @max(m.memsz, 1), m.alignment)) orelse return null;
        const b: [*]u8 = @ptrCast(mem);
        @memcpy(b[0..m.filesz], @as([*]const u8, @ptrFromInt(m.image))[0..m.filesz]);
        @memset(b[m.filesz..m.memsz], 0);
        dtv[id - 1] = b;
        break :blk b;
    };
    return block + ti[1];
}

// ---- The dl functions of the table ----

const RTLD_NOLOAD = 4;
/// The handle of dlopen(NULL): the global scope.
var global_handle: u8 = 0;

fn dlopenFn(name: ?[*:0]const u8, flags: c_int) callconv(.c) ?*anyopaque {
    const n = name orelse return &global_handle;
    const s = std.mem.span(n);
    if (isGlibc(s)) return &global_handle;
    if (flags & RTLD_NOLOAD != 0) {
        lockIt();
        defer unlockIt();
        return findLoaded(s);
    }
    const h = open(s) catch return null;
    return h;
}

fn dlsymFn(handle: ?*anyopaque, name: [*:0]const u8) callconv(.c) ?*anyopaque {
    lockIt();
    defer unlockIt();
    const s = std.mem.span(name);
    const h = handle orelse return globalAddr(s);
    if (h == @as(*anyopaque, &global_handle) or @intFromPtr(h) == std.math.maxInt(usize)) return globalAddr(s);
    if (scopedLookup(@ptrCast(@alignCast(h)), s, null)) |a| return @ptrFromInt(a);
    setReason("dlsym: no symbol {s}", .{s});
    return null;
}

fn globalAddr(s: []const u8) ?*anyopaque {
    if (globalLookup(s, null)) |f| return @ptrFromInt(f.addr);
    setReason("dlsym: no symbol {s}", .{s});
    return null;
}

fn dlerrorFn() callconv(.c) ?[*:0]const u8 {
    if (!reason_new) return null;
    reason_new = false;
    if (reason_len >= reason_buf.len) reason_len = reason_buf.len - 1;
    reason_buf[reason_len] = 0;
    return @ptrCast(&reason_buf);
}

fn dlcloseFn(_: ?*anyopaque) callconv(.c) c_int {
    return 0;
}

const DlInfo = extern struct { fname: ?[*:0]const u8, fbase: ?*anyopaque, sname: ?[*:0]const u8, saddr: ?*anyopaque };

fn dladdrFn(addr: ?*const anyopaque, info: *DlInfo) callconv(.c) c_int {
    const a = @intFromPtr(addr);
    lockIt();
    defer unlockIt();
    for (modules.items) |m| {
        if (a < m.map_start or a >= m.map_start + m.map_len) continue;
        info.* = .{ .fname = m.path, .fbase = @ptrFromInt(m.map_start), .sname = null, .saddr = null };
        var best: usize = 0;
        const n = symCount(m);
        for (1..n) |i| {
            const s = m.symtab[i];
            if (s.st_shndx == SHN_UNDEF or s.st_value == 0) continue;
            const sa = m.base + s.st_value;
            if (sa <= a and sa > best and (s.st_size == 0 or a < sa + s.st_size)) {
                best = sa;
                info.sname = m.str(s.st_name);
                info.saddr = @ptrFromInt(sa);
            }
        }
        return 1;
    }
    return 0;
}

fn symCount(m: *const Module) usize {
    if (m.sysv_hash) |h| return h[1];
    const h = m.gnu_hash.?;
    const nbuckets = h[0];
    const symoffset = h[1];
    const buckets = h + 4 + h[2] * 2;
    const chain = buckets + nbuckets;
    var last: u32 = 0;
    for (buckets[0..nbuckets]) |b| last = @max(last, b);
    if (last < symoffset) return symoffset;
    while (chain[last - symoffset] & 1 == 0) last += 1;
    return last + 1;
}

const PhdrInfo = extern struct {
    addr: usize,
    name: ?[*:0]const u8,
    phdr: [*]const Phdr,
    phnum: u16,
    adds: u64,
    subs: u64,
    tls_modid: usize,
    tls_data: ?*anyopaque,
};
const PhdrCallback = *const fn (*PhdrInfo, usize, ?*anyopaque) callconv(.c) c_int;
extern "c" fn dl_iterate_phdr(cb: PhdrCallback, data: ?*anyopaque) c_int;

/// The program (from the C library), then each loaded library.
fn dlIteratePhdrFn(cb: PhdrCallback, data: ?*anyopaque) callconv(.c) c_int {
    const r = dl_iterate_phdr(cb, data);
    if (r != 0) return r;
    lockIt();
    const list = gpa().dupe(*Module, modules.items) catch {
        unlockIt();
        return 0;
    };
    unlockIt();
    defer gpa().free(list);
    for (list) |m| {
        var info: PhdrInfo = .{ .addr = m.base, .name = m.path, .phdr = m.phdr, .phnum = m.phnum, .adds = modules.items.len, .subs = 0, .tls_modid = m.tls_id, .tls_data = null };
        const v = cb(&info, @sizeOf(PhdrInfo), data);
        if (v != 0) return v;
    }
    return 0;
}

// ---- The table ----

const libc_names = @import("libc_names.zig").names;

/// The functions of this file under their glibc names.
const own = [_]struct { []const u8, *const anyopaque }{
    .{ "__tls_get_addr", &tlsGetAddr },
    .{ "dlopen", &dlopenFn },
    .{ "dlsym", &dlsymFn },
    .{ "dlvsym", &dlsymFn },
    .{ "dlclose", &dlcloseFn },
    .{ "dlerror", &dlerrorFn },
    .{ "dladdr", &dladdrFn },
    .{ "dl_iterate_phdr", &dlIteratePhdrFn },
};

/// The index of each glibc name of `libc_names.zig`.
const name_index = if (supported) std.StaticStringMap(u16).initComptime(blk: {
    @setEvalBranchQuota(200_000);
    var kv: [libc_names.len]struct { []const u8, u16 } = undefined;
    for (libc_names, 0..) |p, k| kv[k] = .{ p[0], k };
    break :blk kv;
}) else std.StaticStringMap(u16).initComptime(.{});

/// The address of each definition of `libc_names.zig` in this program.
const name_addrs = if (supported) blk: {
    @setEvalBranchQuota(20_000);
    var a: [libc_names.len]*const anyopaque = undefined;
    for (libc_names, 0..) |p, k| a[k] = @extern(*const anyopaque, .{ .name = p[1] });
    break :blk a;
} else [_]*const anyopaque{};

/// The table of this program: a glibc name gives an address.
const bridge = struct {
    fn get(name: []const u8) ?usize {
        inline for (own) |o| if (std.mem.eql(u8, o[0], name)) return @intFromPtr(o[1]);
        const i = name_index.get(name) orelse return null;
        return @intFromPtr(name_addrs[i]);
    }
};

const t = std.testing;

test "elf: the GNU hash of the empty name" {
    try t.expectEqual(@as(u32, 5381), gnuHash(""));
}

test "elf: a system library loads and its functions run" {
    if (!supported) return error.SkipZigTest;
    const h = open("libz.so.1") catch |e| {
        if (e == error.NotFound) return error.SkipZigTest;
        std.debug.print("elf: {s}\n", .{lastError()});
        return e;
    };
    const version: *const fn () callconv(.c) [*:0]const u8 = @ptrCast(sym(h, "zlibVersion") orelse return error.NoSymbol);
    try t.expect(std.mem.startsWith(u8, std.mem.span(version()), "1."));
    const crc32: *const fn (c_ulong, [*]const u8, c_uint) callconv(.c) c_ulong = @ptrCast(sym(h, "crc32") orelse return error.NoSymbol);
    try t.expectEqual(@as(c_ulong, 0x352441c2), crc32(0, "abc", 3));
    // A second open gives the same module.
    try t.expectEqual(h, try open("libz.so.1"));
}

test "elf: a missing library gives its name in the reason" {
    if (!supported) return error.SkipZigTest;
    try t.expectError(error.NotFound, open("libno-such-library.so.9"));
    try t.expect(std.mem.indexOf(u8, lastError(), "libno-such-library.so.9") != null);
}

test "elf: dlopen(NULL) and dlsym find the functions of the table" {
    if (!supported) return error.SkipZigTest;
    const g = dlopenFn(null, 0);
    const strlen_fn: *const fn ([*:0]const u8) callconv(.c) usize = @ptrCast(dlsymFn(g, "strlen") orelse return error.NoSymbol);
    try t.expectEqual(@as(usize, 3), strlen_fn("abc"));
    try t.expect(dlsymFn(g, "no_such_function_here") == null);
    try t.expect(dlerrorFn() != null);
    try t.expect(dlerrorFn() == null);
}

test "elf: each thread has its own TLS block of a library" {
    if (!supported) return error.SkipZigTest;
    // __cxa_get_globals of libstdc++ gives the address of a thread-local object.
    const h = open("libstdc++.so.6") catch return error.SkipZigTest;
    const get: *const fn () callconv(.c) ?*anyopaque = @ptrCast(sym(h, "__cxa_get_globals") orelse return error.NoSymbol);
    const here = get() orelse return error.NoTls;
    try t.expectEqual(here, get().?);
    var there: ?*anyopaque = null;
    const th = try std.Thread.spawn(.{}, struct {
        fn run(f: *const fn () callconv(.c) ?*anyopaque, out: *?*anyopaque) void {
            out.* = f();
        }
    }.run, .{ get, &there });
    th.join();
    try t.expect(there != null and there.? != here);
}

test "elf: a recursive mutex from the glibc initializer locks twice" {
    if (!supported) return error.SkipZigTest;
    // PTHREAD_RECURSIVE_MUTEX_INITIALIZER_NP of glibc: the kind 1 in the fifth int.
    var m: [10]i32 = @splat(0);
    m[4] = 1;
    const Fn = *const fn (*anyopaque) callconv(.c) c_int;
    const lock_fn: Fn = @ptrFromInt(bridge.get("pthread_mutex_lock").?);
    const unlock_fn: Fn = @ptrFromInt(bridge.get("pthread_mutex_unlock").?);
    const try_fn: Fn = @ptrFromInt(bridge.get("pthread_mutex_trylock").?);
    try t.expectEqual(@as(c_int, 0), lock_fn(&m));
    try t.expectEqual(@as(c_int, 0), try_fn(&m));
    try t.expectEqual(@as(c_int, 0), unlock_fn(&m));
    try t.expectEqual(@as(c_int, 0), unlock_fn(&m));
}

