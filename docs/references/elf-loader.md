# ELF loader

`src/sys/elf/loader.zig` loads shared libraries in a static Linux program. This page lists the documents that the code follows. No code of glibc, musl, or another dynamic linker went into ztk, and the work did not read their source.

| Source | License | Use |
|---|---|---|
| System V Application Binary Interface, Generic ABI (gABI), chapters "Object Files" and "Program Loading and Dynamic Linking" | Specification | The headers, the segments, the dynamic section, the symbol table, the System V hash, `DT_RELR`, and the order of the init functions |
| System V Application Binary Interface, AMD64 Architecture Processor Supplement (x86-64 psABI) | Specification | The relocation types and their formulas, `R_X86_64_IRELATIVE`, and the `tls_index` argument of `__tls_get_addr` |
| Arm, "ELF for the Arm 64-bit Architecture (AArch64)" (aaelf64) | Specification | The AArch64 relocation types and their formulas, `R_AARCH64_TLSDESC`, and `R_AARCH64_IRELATIVE` |
| Alexandre Oliva and Guido Araujo, "Speeding Up Thread-Local Storage Access in Dynamic Libraries in the ARM platform" | Paper | The TLS descriptor: two words, a function and its argument, and the calling convention that keeps each register but x0 |
| Intel 64 and IA-32 Architectures Software Developer's Manual, volume 1, chapter 13 (XSAVE) | Specification | The XSAVE area, its 64-byte alignment, the header, and the state components of the mask 0xe7 |
| Linux kernel documentation, `Documentation/arch/arm64/elf_hwcaps.rst` | Documentation | `AT_HWCAP` and `AT_HWCAP2`, the arguments of an IFUNC resolver |
| Ulrich Drepper, "ELF Handling For Thread-Local Storage" | Paper | The dynamic TLS model, the module id, and the per-thread blocks |
| Ali Bahrami, "GNU Hash ELF Sections" (Oracle blog) | Article | The layout of `DT_GNU_HASH`: the Bloom filter, the buckets, and the chains |
| Linux Standard Base Core Specification, the symbol versioning and the interfaces of `libc` | Specification | `DT_VERSYM`, `DT_VERDEF`, `DT_VERNEED`, and the prototypes of the `_chk` functions in `shim.c` |
| The manual pages `dlopen(3)`, `dladdr(3)`, `dl_iterate_phdr(3)`, `ld.so(8)`, and `ldconfig(8)` | Documentation | The behavior of the `dl` functions, the search order of the folders, and the form of `/etc/ld.so.conf` |
