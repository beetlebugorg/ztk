// The glibc functions that a library from the system can call and that
// the C library of a static ztk (musl) does not have. The ELF loader
// (loader.zig) gives each one to the libraries under its glibc name.
// Each `_chk` function checks its buffer size as its glibc name implies
// and then calls the plain function. The prototypes follow the Linux
// Standard Base (LSB) Core specification of these interfaces.
// SPDX-License-Identifier: BSD-2-Clause

#define _GNU_SOURCE
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/random.h>
#include <syslog.h>
#include <unistd.h>
#include <wchar.h>

static void chk_fail(void) {
    static const char msg[] = "ztk: a buffer overflow in a loaded library\n";
    write(2, msg, sizeof msg - 1);
    abort();
}

// libstdc++ reads this byte to skip atomic operations. 0: threads exist.
char ztk___libc_single_threaded = 0;

int ztk___printf_chk(int flag, const char *fmt, ...) {
    (void)flag;
    va_list ap;
    va_start(ap, fmt);
    int n = vprintf(fmt, ap);
    va_end(ap);
    return n;
}

int ztk___fprintf_chk(FILE *f, int flag, const char *fmt, ...) {
    (void)flag;
    va_list ap;
    va_start(ap, fmt);
    int n = vfprintf(f, fmt, ap);
    va_end(ap);
    return n;
}

int ztk___vfprintf_chk(FILE *f, int flag, const char *fmt, va_list ap) {
    (void)flag;
    return vfprintf(f, fmt, ap);
}

int ztk___vprintf_chk(int flag, const char *fmt, va_list ap) {
    (void)flag;
    return vprintf(fmt, ap);
}

int ztk___sprintf_chk(char *s, int flag, size_t slen, const char *fmt, ...) {
    (void)flag;
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(s, slen, fmt, ap);
    va_end(ap);
    if (n >= 0 && (size_t)n >= slen) chk_fail();
    return n;
}

int ztk___vsprintf_chk(char *s, int flag, size_t slen, const char *fmt, va_list ap) {
    (void)flag;
    int n = vsnprintf(s, slen, fmt, ap);
    if (n >= 0 && (size_t)n >= slen) chk_fail();
    return n;
}

int ztk___snprintf_chk(char *s, size_t maxlen, int flag, size_t slen, const char *fmt, ...) {
    (void)flag;
    if (slen < maxlen) chk_fail();
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(s, maxlen, fmt, ap);
    va_end(ap);
    return n;
}

int ztk___vsnprintf_chk(char *s, size_t maxlen, int flag, size_t slen, const char *fmt, va_list ap) {
    (void)flag;
    if (slen < maxlen) chk_fail();
    return vsnprintf(s, maxlen, fmt, ap);
}

int ztk___asprintf_chk(char **out, int flag, const char *fmt, ...) {
    (void)flag;
    va_list ap;
    va_start(ap, fmt);
    int n = vasprintf(out, fmt, ap);
    va_end(ap);
    return n;
}

int ztk___vasprintf_chk(char **out, int flag, const char *fmt, va_list ap) {
    (void)flag;
    return vasprintf(out, fmt, ap);
}

void ztk___syslog_chk(int prio, int flag, const char *fmt, ...) {
    (void)flag;
    va_list ap;
    va_start(ap, fmt);
    vsyslog(prio, fmt, ap);
    va_end(ap);
}

void *ztk___memcpy_chk(void *d, const void *s, size_t n, size_t dlen) {
    if (dlen < n) chk_fail();
    return memcpy(d, s, n);
}

void *ztk___memmove_chk(void *d, const void *s, size_t n, size_t dlen) {
    if (dlen < n) chk_fail();
    return memmove(d, s, n);
}

void *ztk___memset_chk(void *d, int c, size_t n, size_t dlen) {
    if (dlen < n) chk_fail();
    return memset(d, c, n);
}

void *ztk___mempcpy_chk(void *d, const void *s, size_t n, size_t dlen) {
    if (dlen < n) chk_fail();
    return (char *)memcpy(d, s, n) + n;
}

char *ztk___strcpy_chk(char *d, const char *s, size_t dlen) {
    if (strlen(s) >= dlen) chk_fail();
    return strcpy(d, s);
}

char *ztk___stpcpy_chk(char *d, const char *s, size_t dlen) {
    if (strlen(s) >= dlen) chk_fail();
    return stpcpy(d, s);
}

char *ztk___strncpy_chk(char *d, const char *s, size_t n, size_t dlen) {
    if (dlen < n) chk_fail();
    return strncpy(d, s, n);
}

char *ztk___strcat_chk(char *d, const char *s, size_t dlen) {
    if (strlen(d) + strlen(s) >= dlen) chk_fail();
    return strcat(d, s);
}

char *ztk___strncat_chk(char *d, const char *s, size_t n, size_t dlen) {
    size_t sl = strnlen(s, n);
    if (strlen(d) + sl >= dlen) chk_fail();
    return strncat(d, s, n);
}

wchar_t *ztk___wmemcpy_chk(wchar_t *d, const wchar_t *s, size_t n, size_t dlen) {
    if (dlen < n) chk_fail();
    return wmemcpy(d, s, n);
}

wchar_t *ztk___wmemset_chk(wchar_t *d, wchar_t c, size_t n, size_t dlen) {
    if (dlen < n) chk_fail();
    return wmemset(d, c, n);
}

void ztk___explicit_bzero_chk(void *p, size_t n, size_t dlen) {
    if (dlen < n) chk_fail();
    explicit_bzero(p, n);
}

size_t ztk___fread_chk(void *p, size_t plen, size_t size, size_t n, FILE *f) {
    if (size != 0 && n > plen / size) chk_fail();
    return fread(p, size, n, f);
}

ssize_t ztk___read_chk(int fd, void *buf, size_t n, size_t buflen) {
    if (buflen < n) chk_fail();
    return read(fd, buf, n);
}

ssize_t ztk___readlink_chk(const char *path, char *buf, size_t n, size_t buflen) {
    if (buflen < n) chk_fail();
    return readlink(path, buf, n);
}

ssize_t ztk___readlinkat_chk(int dirfd, const char *path, char *buf, size_t n, size_t buflen) {
    if (buflen < n) chk_fail();
    return readlinkat(dirfd, path, buf, n);
}

char *ztk___realpath_chk(const char *path, char *resolved, size_t rlen) {
    if (resolved != NULL && rlen < PATH_MAX) chk_fail();
    return realpath(path, resolved);
}

char *ztk___getcwd_chk(char *buf, size_t n, size_t buflen) {
    if (buflen < n) chk_fail();
    return getcwd(buf, n);
}

size_t ztk___mbsrtowcs_chk(wchar_t *d, const char **s, size_t n, mbstate_t *ps, size_t dlen) {
    if (d != NULL && dlen < n) chk_fail();
    return mbsrtowcs(d, s, n, ps);
}

size_t ztk___mbstowcs_chk(wchar_t *d, const char *s, size_t n, size_t dlen) {
    if (d != NULL && dlen < n) chk_fail();
    return mbstowcs(d, s, n);
}

char *ztk___fgets_chk(char *s, size_t slen, int n, FILE *f) {
    if ((size_t)n > slen) chk_fail();
    return fgets(s, n, f);
}

// The 2-argument forms of open that the fortified headers call when the
// flags have no O_CREAT.
int ztk___open_2(const char *path, int flags) { return open(path, flags); }
int ztk___open64_2(const char *path, int flags) { return open(path, flags); }
int ztk___openat_2(int fd, const char *path, int flags) { return openat(fd, path, flags); }
int ztk___openat64_2(int fd, const char *path, int flags) { return openat(fd, path, flags); }

int ztk___register_atfork(void (*prepare)(void), void (*parent)(void), void (*child)(void), void *dso) {
    (void)dso;
    return pthread_atfork(prepare, parent, child);
}

// The destructors of thread_local objects of C++. The loader does not
// unload libraries and the static C library has no hook at thread exit,
// so a destructor does not run.
int ztk___cxa_thread_atexit_impl(void (*dtor)(void *), void *obj, void *dso) {
    (void)dtor;
    (void)obj;
    (void)dso;
    return 0;
}

unsigned int ztk_arc4random(void) {
    unsigned int v;
    while (getrandom(&v, sizeof v, 0) != (ssize_t)sizeof v) {}
    return v;
}

void ztk_arc4random_buf(void *p, size_t n) {
    char *b = p;
    while (n > 0) {
        ssize_t r = getrandom(b, n, 0);
        if (r > 0) {
            b += r;
            n -= (size_t)r;
        }
    }
}

unsigned int ztk_arc4random_uniform(unsigned int bound) {
    if (bound < 2) return 0;
    unsigned int min = -bound % bound;
    for (;;) {
        unsigned int r = ztk_arc4random();
        if (r >= min) return r % bound;
    }
}

// __float128 with the precision of long double. On AArch64, long double
// is the IEEE quad type.
#if defined(__aarch64__)
typedef long double ztk_f128;
#else
typedef __float128 ztk_f128;
#endif
ztk_f128 ztk_strtof128(const char *s, char **end) { return (ztk_f128)strtold(s, end); }

int ztk_strfromf128(char *s, size_t n, const char *fmt, ztk_f128 v) {
    // fmt is "%[.precision]conversion" with no length modifier: add L.
    char f[32];
    size_t len = strlen(fmt);
    if (len < 2 || len + 2 > sizeof f) return -1;
    memcpy(f, fmt, len - 1);
    f[len - 1] = 'L';
    f[len] = fmt[len - 1];
    f[len + 1] = 0;
    return snprintf(s, n, f, (long double)v);
}

#if defined(__aarch64__)
// The exceptions with traps on: the trap enable bits 8 to 12 of FPCR, in
// the order of the FE_ bits of AArch64.
int ztk_fegetexcept(void) {
    unsigned long m;
    __asm__ volatile("mrs %0, fpcr" : "=r"(m));
    return (int)(m >> 8) & 0x1f;
}
#else
// The exceptions with traps on: the mask bits of MXCSR are 1 for an
// exception with no trap.
int ztk_fegetexcept(void) {
    unsigned int m;
    __asm__("stmxcsr %0" : "=m"(m));
    return (int)(~m >> 7) & 0x3f;
}
#endif

// The function forms of isnan of glibc. musl has only the macro.
int ztk_isnan(double x) { return __builtin_isnan(x); }
int ztk___isnan(double x) { return __builtin_isnan(x); }
int ztk_isnanf(float x) { return __builtin_isnan(x); }
int ztk___isnanf(float x) { return __builtin_isnan(x); }
int ztk_isnanl(long double x) { return __builtin_isnan(x); }

wchar_t *ztk_wmempcpy(wchar_t *d, const wchar_t *s, size_t n) { return wmemcpy(d, s, n) + n; }

// A mutex of a glibc library can come from a static initializer, such as
// PTHREAD_RECURSIVE_MUTEX_INITIALIZER_NP. That initializer puts the kind
// in the fifth int of the mutex, and musl reads the type from the first
// int, so musl locks a recursive mutex as a normal one and a second lock
// of the same thread waits forever. Before each lock, a mutex with 0 in
// the first int and a kind in the fifth int gets pthread_mutex_init with
// that type. A mutex that musl made has its type in the first int and 0
// in the fifth int (it is not robust), so the check is false for it.
static pthread_mutex_t convert_lock = PTHREAD_MUTEX_INITIALIZER;

static void convert(pthread_mutex_t *m) {
    volatile int *w = (volatile int *)m;
    if (w[0] != 0 || w[4] == 0) return;
    pthread_mutex_lock(&convert_lock);
    if (w[0] == 0 && w[4] != 0) {
        int kind = w[4] & 3;
        pthread_mutexattr_t a;
        pthread_mutexattr_init(&a);
        pthread_mutexattr_settype(&a, kind == 1 ? PTHREAD_MUTEX_RECURSIVE : kind == 2 ? PTHREAD_MUTEX_ERRORCHECK : PTHREAD_MUTEX_NORMAL);
        pthread_mutex_init(m, &a);
        pthread_mutexattr_destroy(&a);
    }
    pthread_mutex_unlock(&convert_lock);
}

int ztk_pthread_mutex_lock(pthread_mutex_t *m) {
    convert(m);
    return pthread_mutex_lock(m);
}

int ztk_pthread_mutex_trylock(pthread_mutex_t *m) {
    convert(m);
    return pthread_mutex_trylock(m);
}

int ztk_pthread_mutex_timedlock(pthread_mutex_t *m, const struct timespec *at) {
    convert(m);
    return pthread_mutex_timedlock(m, at);
}

int ztk_pthread_mutex_unlock(pthread_mutex_t *m) {
    convert(m);
    return pthread_mutex_unlock(m);
}
