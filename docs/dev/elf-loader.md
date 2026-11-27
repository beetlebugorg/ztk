# The ELF loader of the static Linux program

Issue #241. A static Linux ztk (x86_64-linux-musl or aarch64-linux-musl) has no dynamic linker, so `dlopen` of the C library cannot open the Vulkan loader of the system. `src/sys/elf/loader.zig` loads `libvulkan.so.1`, the GPU driver that it opens, and their libraries. `src/render/vulkan.zig` uses it in a static program and `std.DynLib` in the other builds.

## How a load works

1. The loader finds the file in the folders of `LD_LIBRARY_PATH`, `DT_RPATH` or `DT_RUNPATH` (with `$ORIGIN`), `/etc/ld.so.conf` with its `include` lines, and the default folders.
2. It reserves the span of the `PT_LOAD` segments with no access, maps each segment at its offset, and zeroes `.bss`.
3. It loads each `DT_NEEDED` library. The libraries of glibc (`libc.so.6`, `libm.so.6`, `libpthread.so.0`, `libdl.so.2`, `librt.so.1`, `libutil.so.1`, `libresolv.so.2`, and `ld-linux-x86-64.so.2`) do not load. Their functions come from the C library of the program by the table `libc_names.zig`, and from `shim.c` for the functions that only glibc has (the `_chk` functions, `__isoc23_strtol`, `arc4random`, and others).
4. It applies `DT_RELR`, `DT_RELA`, and `DT_JMPREL`. The symbol search goes to the table first, then to each loaded library in load order, with the GNU hash or the System V hash and the symbol versions.
5. It makes `PT_GNU_RELRO` read-only and runs `DT_INIT` and `DT_INIT_ARRAY`, the libraries that a library needs first.

`dlopen`, `dlsym`, `dlerror`, `dladdr`, and `dl_iterate_phdr` in the table use the same modules. The Vulkan loader opens the driver with `dlopen`, and the unwinder of `libgcc_s` finds the frames of C++ code through `dl_iterate_phdr`.

## Limits

- x86-64 and AArch64 only. Other targets give `error.Unsupported` with that reason.
- TLS of the dynamic model only (`DTPMOD64`, `DTPOFF64`, `__tls_get_addr`, and `TLSDESC`). A TLS descriptor gets the function `tlsdescDynamic`, which calls `__tls_get_addr` of the loader and returns the address minus the thread pointer. On AArch64 it saves x1 to x18, x29, x30, and q0 to q31. On x86-64 it saves rcx, rdx, rsi, rdi, and r8 to r11, and the x87, SSE, AVX, and AVX-512 state with XSAVE (mask 0xe7); a processor with no OSXSAVE gives the load an error with that reason. Each access to a TLS variable through a descriptor makes that call. The CI log of PR #269 showed `libvulkan_radeon.so` and `libvulkan_asahi.so` of Ubuntu with `R_X86_64_TLSDESC` (type 36), which the loader did not support before. A library with `TPOFF64` (initial-exec TLS) fails with that reason, and the Vulkan loader then skips that driver. The test machine has the NVIDIA driver installed too, and the Vulkan tests ran on the Intel driver.
- A library does not unload. `dlclose` returns 0 and keeps the library.
- A function of a library with no definition in the table gets a stub. The stub stops the program with the name of the function when it runs.
- The destructors of `thread_local` objects of C++ do not run (`__cxa_thread_atexit_impl` of `shim.c`).
- A mutex from a static initializer of glibc (`PTHREAD_RECURSIVE_MUTEX_INITIALIZER_NP`) has its kind in the fifth int, and musl reads the type from the first int. The `pthread_mutex_*` functions of `shim.c` call `pthread_mutex_init` with that kind before the first lock. Without that step, lavapipe (LLVM has `std::recursive_mutex` objects) waited forever on its second lock in CI.
- The structures that glibc and musl share (`struct stat`, `pthread_mutex_t`, `sigset_t`, `struct dirent`) have the same layout on x86-64. On AArch64, `struct stat` (128 bytes, `st_size` at 48, `st_mtim` at 88), `pthread_cond_t` (48), `sigset_t` (128), and `struct dirent` (280, `d_name` at 19) are the same, from the headers of both C libraries in Zig 0.17.0. `pthread_mutex_t` is 48 bytes in glibc and 40 in musl, and `pthread_attr_t` 64 and 56, so musl uses a part of the memory of the library. An AArch64 IFUNC resolver gets `AT_HWCAP` with bit 62 and a pointer to the size, `AT_HWCAP`, and `AT_HWCAP2`. The C library of AArch64 has no `arch_prctl`, `ioperm`, or `iopl`, so the table leaves them out there. A library that reads the fields of `FILE` through a glibc macro reads wrong values.

## The table

`libc_names.zig` has 1,696 names: the names that the Vulkan loader, the Intel drivers, and their libraries need (measured with `nm -D --undefined-only` on the closure of `libvulkan.so.1` and `libvulkan_intel.so`), and each other export of `libc.so.6` and `libm.so.6` that the C library of the static program has. A name in the `_FloatN` forms (`acosf64`) is left out. The `*64` names (`fstat64`), the `__isoc99_` and `__isoc23_` names, and the `__*_l` names go to the plain names.

## Measured

On 2026-11-27, on the development machine (Intel HD Graphics 530, Mesa `libvulkan_intel_hasvk.so`, Vulkan loader 1.4.363):

- `zig build test -Dtarget=x86_64-linux-musl -Dtest-filter=vulkan --summary all`: 11 of 11 tests pass. Each golden scene has 0 pixels that differ by more than 2 from the CPU renderer. `vulkan-speed` gives 26.905 ms for one draw of 10,000 quads (debug), and the glibc build gave 26.930 ms on the same machine.
- `sh tests/elf-tls.sh aarch64` (in qemu-aarch64): 10 of 12 tests pass, and 2 skip with no AArch64 `libz.so.1` or `libstdc++.so.6` on the machine. The test library `tests/elf/tls.c` has a local and a global TLS variable, each with an `R_AARCH64_TLSDESC` relocation, and a second thread starts from the initial values. `sh tests/elf-tls.sh` on x86-64 builds the library with `-mtls-dialect=gnu2` (two `R_X86_64_TLSDESC` relocations): 12 of 12 pass. The CI job `Test (Linux AArch64)` runs the same tests and the Vulkan tests with lavapipe on an Arm runner.
- `zig build test -Dtarget=x86_64-linux-musl -Dtest-filter=elf --summary all`: 9 of 9 tests pass: `libz.so.1` with `zlibVersion` and `crc32`, a missing library, `dlopen(NULL)` with `dlsym`, and a TLS block of `libstdc++` for each thread.

## Next

The Wayland backend renders on the CPU and sends `wl_shm` buffers. The next step is the dmabuf path (`zwp_linux_dmabuf_v1`) with a Vulkan swapchain, and a fallback to the CPU renderer that prints `vulkan.reason()`.
