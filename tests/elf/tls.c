/* A test library of the ELF loader: a local and a global thread-local
 * variable. tests/elf-tls.sh builds it. On AArch64 each access is a TLS
 * descriptor (R_AARCH64_TLSDESC, and R_X86_64_TLSDESC with
 * -mtls-dialect=gnu2).
 * SPDX-License-Identifier: BSD-2-Clause */
static __thread int counter = 5;
__thread long shared_value = 7;
int *counter_addr(void) { return &counter; }
long bump(void) { counter += 1; shared_value += 10; return counter * 1000 + shared_value; }
