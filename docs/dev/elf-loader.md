# The ELF loader of the static Linux program

Issue #241. A static Linux ztk (x86_64-linux-musl) has no dynamic linker, so `dlopen` of the C library cannot open the Vulkan loader of the system. `src/sys/elf/loader.zig` loads `libvulkan.so.1`, the GPU driver that it opens, and their libraries. `src/render/vulkan.zig` uses it in a static program and `std.DynLib` in the other builds.

## How a load works

1. The loader finds the file in the folders of `LD_LIBRARY_PATH`, `DT_RPATH` or `DT_RUNPATH` (with `$ORIGIN`), `/etc/ld.so.conf` with its `include` lines, and the default folders.
2. It reserves the span of the `PT_LOAD` segments with no access, maps each segment at its offset, and zeroes `.bss`.
3. It loads each `DT_NEEDED` library. The libraries of glibc (`libc.so.6`, `libm.so.6`, `libpthread.so.0`, `libdl.so.2`, `librt.so.1`, `libutil.so.1`, `libresolv.so.2`, and `ld-linux-x86-64.so.2`) do not load. Their functions come from the C library of the program by the table `libc_names.zig`, and from `shim.c` for the functions that only glibc has (the `_chk` functions, `__isoc23_strtol`, `arc4random`, and others).
4. It applies `DT_RELR`, `DT_RELA`, and `DT_JMPREL`. The symbol search goes to the table first, then to each loaded library in load order, with the GNU hash or the System V hash and the symbol versions.
5. It makes `PT_GNU_RELRO` read-only and runs `DT_INIT` and `DT_INIT_ARRAY`, the libraries that a library needs first.

`dlopen`, `dlsym`, `dlerror`, `dladdr`, and `dl_iterate_phdr` in the table use the same modules. The Vulkan loader opens the driver with `dlopen`, and the unwinder of `libgcc_s` finds the frames of C++ code through `dl_iterate_phdr`.

## Limits

- x86-64 only. Other targets give `error.Unsupported` with that reason.
- TLS of the dynamic model only (`DTPMOD64`, `DTPOFF64`, `__tls_get_addr`). A library with `TPOFF64` (initial-exec TLS) fails with that reason, and the Vulkan loader then skips that driver. The test machine has the NVIDIA driver installed too, and the Vulkan tests ran on the Intel driver.
- A library does not unload. `dlclose` returns 0 and keeps the library.
- A function of a library with no definition in the table gets a stub. The stub stops the program with the name of the function when it runs.
- The destructors of `thread_local` objects of C++ do not run (`__cxa_thread_atexit_impl` of `shim.c`).
- The structures that glibc and musl share (`struct stat`, `pthread_mutex_t`, `sigset_t`, `struct dirent`) have the same layout on x86-64. A library that reads the fields of `FILE` through a glibc macro reads wrong values.

## The table

`libc_names.zig` has 1,696 names: the names that the Vulkan loader, the Intel drivers, and their libraries need (measured with `nm -D --undefined-only` on the closure of `libvulkan.so.1` and `libvulkan_intel.so`), and each other export of `libc.so.6` and `libm.so.6` that the C library of the static program has. A name in the `_FloatN` forms (`acosf64`) is left out. The `*64` names (`fstat64`), the `__isoc99_` and `__isoc23_` names, and the `__*_l` names go to the plain names.

## Measured

On 2026-11-27, on the development machine (Intel HD Graphics 530, Mesa `libvulkan_intel_hasvk.so`, Vulkan loader 1.4.363):

- `zig build test -Dtarget=x86_64-linux-musl -Dtest-filter=vulkan --summary all`: 11 of 11 tests pass. Each golden scene has 0 pixels that differ by more than 2 from the CPU renderer. `vulkan-speed` gives 26.905 ms for one draw of 10,000 quads (debug), and the glibc build gave 26.930 ms on the same machine.
- `zig build test -Dtarget=x86_64-linux-musl -Dtest-filter=elf --summary all`: 9 of 9 tests pass: `libz.so.1` with `zlibVersion` and `crc32`, a missing library, `dlopen(NULL)` with `dlsym`, and a TLS block of `libstdc++` for each thread.

## Next

The Wayland backend renders on the CPU and sends `wl_shm` buffers. The next step is the dmabuf path (`zwp_linux_dmabuf_v1`) with a Vulkan swapchain, and a fallback to the CPU renderer that prints `vulkan.reason()`.
