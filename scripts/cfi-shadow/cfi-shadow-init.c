/* Give bionic's cross-DSO CFI shadow the initialisation libhybris never gave it.
 *
 * The problem, measured (docs/ubuntu-touch/65-*):
 *
 *   test_camera -> libcamera.so.1 -> android_dlopen("libcamera_compat_layer.so")
 *                                  -> libcamera_client.so -> SEGV
 *
 *   pc  /android/system/lib64/libdl.so +0x1124   __cfi_slowpath_diag+36
 *   ldrh w8, [x8, x9]        x8 = 0    x9 = 0x3c1b0e     si_addr = 0x3c1b0e
 *
 * libcamera_client.so is built with `-fsanitize-cfi-cross-dso`, so calls through function pointers
 * in it are checked against a process-wide shadow array. The check lives in libdl.so:
 *
 *   __cfi_init(shadow_base)                 // 0x1068: stores shadow_base, returns &slot
 *   __cfi_slowpath_diag(TypeId, Ptr, Diag): // 0x1100:
 *       if (MemToShadowOffset(Ptr) > kShadowSize) -> invalid
 *       v = *(uint16_t *)(*slot + MemToShadowOffset(Ptr))     <- the ldrh; *slot == 0 -> SEGV
 *       v == 1 (kUncheckedShadow) -> return
 *       v == 0 (kInvalidShadow)   -> __loader_cfi_fail(...)
 *       else                      -> call __cfi_check at the encoded address
 *
 * `*slot` is only ever written by `__cfi_init`, and bionic's only caller of `__cfi_init` is
 * `CFIShadowWriter::NotifyLibDl`, reached from `InitialLinkDone()` -- which bionic calls once at the
 * end of `__linker_init_post_relocation`, after the initial link. libhybris ships its own copy of
 * that function (`hybris/common/o/linker_main.cpp`), re-entered as `android_linker_init()`, and it
 * stops after `init_default_namespaces()`: no `InitialLinkDone()`, so `initial_link_done` stays
 * false, `CFIShadowWriter::AfterLoad()` early-returns for every library, and the shadow is never
 * mapped. Nothing outside can set that slot, and HYBRIS_LD_PRELOAD cannot override libdl.so's
 * symbols (libhybris resolves a library's symbols from its own local group first and libdl.so is in
 * it), so the fix has to bypass hybris' symbol resolution entirely.
 *
 * This is that: an ordinary glibc shared object, loaded with LD_PRELOAD on the *host* side, which
 * interposes `android_dlopen` -- the one hybris entry point the consumer calls, exported by
 * libhybris-common.so.1 and imported by /usr/lib/aarch64-linux-gnu/libcamera.so.1. Before letting
 * the first call through it does the two things the linker was supposed to do:
 *
 *   1. mmap the shadow. kShadowSize is 2 GiB (bionic/libc/private/CFIShadow.h: 2 bytes per 2**18
 *      bytes of address space over a 48-bit target range), mapped MAP_NORESERVE because almost all
 *      of it stays untouched.
 *   2. fill the part of it that matters with 0x0001, kUncheckedShadow, and hand it to libdl.so's
 *      `__cfi_init`. Addresses in a filled range then pass the check with no validation.
 *
 * Which part matters: MemToShadowOffset(Ptr) = (Ptr >> 18) << 1, so the shadow is a 2-byte entry per
 * 256 KiB of address space and a band of addresses costs band_size / 2**17 bytes. Filling the first
 * 8 MiB covers every address below 1 TiB, and the Android libraries land far inside that: measured
 * on two live hybris processes, every /android/ mapping sits in [0x7000000000, 0x8000000000), i.e.
 * 448-512 GiB (scripts/cfi-shadow/measure-band.py):
 *
 *   lomiri-system-compositor  232 mappings  0x7a405c9000 .. 0x7a5991c000
 *   sensorfwd                  19 mappings  0x723905d000 .. 0x72393fa000
 *
 * 8 MiB of writes, not 2 GiB: the shadow is sparse and this fills only the sparse part in use.
 * Anything outside the filled band still reads as 0 -- kInvalidShadow -- which routes the call to
 * __loader_cfi_fail instead of into an unmapped page; that is the correct path (hybris' own
 * CFIShadowWriter::CfiFail validates the call properly), just slower, and it is only reached if a
 * library ever appears above 1 TiB. Every mapping found is logged either way, so that assumption is
 * checked on the device rather than believed.
 *
 * Read it as a workaround: it restores the *effect* of the missing initial link by declaring a range
 * unchecked, so cross-DSO CFI stops validating calls in that range. The real fix is one line in
 * libhybris -- `get_cfi_shadow()->InitialLinkDone(solist)` at the end of `android_linker_init()`,
 * minus the `CHECK(!initial_link_done)` since hybris' linker is not the process entry point and
 * there is no initial link to wait for -- and that needs a libhybris rebuild plus a write to the
 * read-only rootfs. This needs neither, is per-process, and is removed by unsetting LD_PRELOAD.
 *
 * Build: scripts/cfi-shadow/build.sh      Run: scripts/cfi-shadow/run-test-camera.sh
 */

#define RTLD_NEXT ((void *)-1L)

/* No aarch64 glibc sysroot is needed for any of this, so the prototypes are declared here and the
 * object is linked with -nostdlib; every one of these resolves at load time from the libc.so.6 the
 * process already has. */
extern void *dlsym(void *handle, const char *symbol);
extern void *dlopen(const char *path, int flags);
extern void *mmap(void *addr, unsigned long length, int prot, int flags, int fd, long offset);
extern int open(const char *path, int flags, ...);
extern long read(int fd, void *buf, unsigned long count);
extern long write(int fd, const void *buf, unsigned long count);
extern int close(int fd);
extern int getpid(void);

typedef unsigned long u64;

#define PROT_READ 0x1
#define PROT_WRITE 0x2
#define MAP_PRIVATE 0x02
#define MAP_ANONYMOUS 0x20
#define MAP_NORESERVE 0x4000
#define O_RDONLY 0
#define O_WRONLY 1
#define O_CREAT 0100
#define O_APPEND 02000
#define RTLD_NOW 2
#define RTLD_GLOBAL 0x100

/* bionic/libc/private/CFIShadow.h */
#define SHADOW_GRANULARITY 18
#define K_SHADOW_SIZE (2UL * 1024 * 1024 * 1024)
#define K_UNCHECKED_SHADOW 1
/* Addresses below this get a filled (unchecked) shadow entry: 1 TiB, i.e. 2**40. */
#define FILLED_BELOW (1UL << 40)
/* ... which is (FILLED_BELOW >> 18) << 1 = 8 MiB of shadow. */
#define FILLED_BYTES (((FILLED_BELOW >> SHADOW_GRANULARITY) << 1))

#define LOGBUF 512
#define LOGFILE "/userdata/zl1-cfi/cfi-shadow.log"
#define MAPSBUF 65536

typedef void *(*dlopen_fn)(const char *, int);
typedef void *(*dlsym_fn)(void *, const char *);

static dlopen_fn real_dlopen;
static dlsym_fn real_dlsym;
static char *shadow; /* the mapped shadow */
static int state;    /* 0 unprimed, 1 priming, 2 primed */
static int inside;   /* re-entrancy guard: hybris' dlopen may call back into ours */

/* --- logging, hand-rolled: no headers, so no stdio --- */
static char logbuf[LOGBUF];
static char *logp;

/* Copy while there is room, and stop at the end of the source. Two things to keep in mind if this
 * is ever touched: the loop must advance `s` (a version that copied `*s` without `s++` made clang
 * emit `memset(logbuf, 'c', 510)` -- a correct optimization of an infinite copy of the first
 * character, and indistinguishable at a glance from a compiler bug); and the bound is
 * LOGBUF-2 rather than LOGBUF because logflush appends the newline afterwards. */
static void logstr(const char *s) {
  while (*s && logp < logbuf + LOGBUF - 2)
    *logp++ = *s++;
}

static void loghex(u64 v) {
  char tmp[20];
  int n = 0;
  int i, started = 0;
  for (i = 60; i >= 0; i -= 4) {
    int d = (int)((v >> i) & 0xf);
    if (d || started || i == 0) {
      tmp[n++] = (char)(d < 10 ? '0' + d : 'a' + d - 10);
      started = 1;
    }
  }
  tmp[n] = 0;
  logstr("0x");
  logstr(tmp);
}

static void lognum(u64 v) {
  char tmp[24];
  int n = 0;
  if (v == 0)
    tmp[n++] = '0';
  while (v) {
    tmp[n++] = (char)('0' + (int)(v % 10));
    v /= 10;
  }
  tmp[n] = 0;
  {
    char out[24];
    int i;
    for (i = 0; i < n; i++)
      out[i] = tmp[n - 1 - i];
    out[n] = 0;
    logstr(out);
  }
}

static void logflush(void) {
  int fd;
  *logp++ = '\n';
  write(2, logbuf, (unsigned long)(logp - logbuf));
  fd = open(LOGFILE, O_WRONLY | O_CREAT | O_APPEND, 0644);
  if (fd >= 0) {
    write(fd, logbuf, (unsigned long)(logp - logbuf));
    close(fd);
  }
}

static void logbegin(const char *what) {
  logp = logbuf;
  logstr("cfi-shadow-init[");
  lognum((u64)getpid());
  logstr("] ");
  logstr(what);
}

/* --- the shadow --- */

/* One 2-byte kUncheckedShadow entry per 256 KiB of [lo, hi). Idempotent. */
static void fill_range(u64 lo, u64 hi) {
  u64 o = (lo >> SHADOW_GRANULARITY) << 1;
  u64 end = (hi >> SHADOW_GRANULARITY) << 1;
  if (!shadow)
    return;
  if (end > K_SHADOW_SIZE)
    end = K_SHADOW_SIZE;
  for (; o < end; o += 2)
    *(volatile unsigned short *)(shadow + o) = K_UNCHECKED_SHADOW;
}

/* Walk /proc/self/maps, fill in whatever the hybris linker has mapped under /android/, and report
 * the span. The band above should already cover these; this is here so an address outside the band
 * is recorded rather than assumed away, and so later loads are correct even if they are. */
static void scan_maps(u64 *out_lo, u64 *out_hi, int *out_count) {
  static char buf[MAPSBUF];
  static long have;
  u64 lo = ~0UL, hi = 0;
  int count = 0;
  int fd = open("/proc/self/maps", O_RDONLY);
  long n;

  if (fd < 0)
    return;
  have = 0;
  while ((n = read(fd, buf + have, sizeof(buf) - (unsigned long)have - 1)) > 0) {
    long end = have + n;
    long i = 0, cut;
    buf[end] = 0;
    /* Only whole lines are parsed; a partial tail is kept for the next read. */
    cut = end;
    while (cut > 0 && buf[cut - 1] != '\n')
      cut--;
    for (i = 0; i < cut;) {
      long e = i;
      u64 a = 0, b = 0;
      int is_android = 0;
      char *p;
      while (e < cut && buf[e] != '\n')
        e++;
      p = buf + i;
      while (p < buf + e && *p != '-') {
        int d = *p++;
        if (d >= '0' && d <= '9')
          a = (a << 4) | (u64)(d - '0');
        else if (d >= 'a' && d <= 'f')
          a = (a << 4) | (u64)(d - 'a' + 10);
      }
      p++;
      while (p < buf + e && *p != ' ') {
        int d = *p++;
        if (d >= '0' && d <= '9')
          b = (b << 4) | (u64)(d - '0');
        else if (d >= 'a' && d <= 'f')
          b = (b << 4) | (u64)(d - 'a' + 10);
      }
      {
        long q;
        for (q = i; q + 9 <= e; q++) {
          if (buf[q] == '/' && buf[q + 1] == 'a' && buf[q + 2] == 'n' && buf[q + 3] == 'd' &&
              buf[q + 4] == 'r' && buf[q + 5] == 'o' && buf[q + 6] == 'i' && buf[q + 7] == 'd' &&
              buf[q + 8] == '/') {
            is_android = 1;
            break;
          }
        }
      }
      if (is_android && b > a) {
        fill_range(a, b);
        if (a < lo)
          lo = a;
        if (b > hi)
          hi = b;
        count++;
      }
      i = e + 1;
    }
    if (cut < end) {
      long k;
      for (k = 0; k < end - cut; k++)
        buf[k] = buf[cut + k];
      have = end - cut;
    } else {
      have = 0;
    }
  }
  close(fd);
  if (out_lo)
    *out_lo = lo;
  if (out_hi)
    *out_hi = hi;
  if (out_count)
    *out_count = count;
}

/* Resolve the real hybris entry points this shim forwards to.
 *
 * RTLD_NEXT is the right first try -- it is how this was written, and it is what works for
 * test_camera, where libcamera.so.1 is a DT_NEEDED of the executable and libhybris-common.so.1 is
 * therefore in the *global* scope before the first call. It is not enough in general:
 * libhybris-common can also arrive inside the *local* scope of a library glvnd dlopens
 * (libEGL_libhybris.so.0 is dlopened by libEGL.so.1 in every Qt process), and RTLD_NEXT cannot see
 * a local scope. When that happens dlsym(RTLD_NEXT) returns NULL, and because android_dlopen()
 * below forwards through real_dlopen, the shim then fails *every* hybris dlopen in the process.
 *
 * That is not hypothetical: it is what broke the UT camera app (docs/ubuntu-touch/80). The log said
 * "no android_dlopen/android_dlsym after this object -- not priming", libEGL_libhybris.so.0 could
 * no longer resolve its Android dependencies, glvnd fell through to Mesa (which wants /dev/dri and
 * cannot work here at all), and the app died in eglInitialize -- while libhybris' EGL itself was
 * fine, as the same probe without this preload shows.
 *
 * So: fall back to loading libhybris-common.so.1 by name -- it is on the host's ld path, and
 * RTLD_GLOBAL puts it in the scope every later lookup uses -- and take the two symbols from that
 * handle. Idempotent; returns non-zero when both are resolved.
 */
static int resolve_real(void) {
  if (!real_dlopen)
    real_dlopen = (dlopen_fn)dlsym(RTLD_NEXT, "android_dlopen");
  if (!real_dlsym)
    real_dlsym = (dlsym_fn)dlsym(RTLD_NEXT, "android_dlsym");
  if (real_dlopen && real_dlsym)
    return 1;
  {
    void *h = dlopen("libhybris-common.so.1", RTLD_NOW | RTLD_GLOBAL);
    if (!h) {
      logbegin("RTLD_NEXT could not see android_dlopen and dlopen(\"libhybris-common.so.1\") failed");
      logflush();
      return 0;
    }
    if (!real_dlopen)
      real_dlopen = (dlopen_fn)dlsym(h, "android_dlopen");
    if (!real_dlsym)
      real_dlsym = (dlsym_fn)dlsym(h, "android_dlsym");
    if (real_dlopen && real_dlsym) {
      logbegin("resolved android_dlopen via dlopen(\"libhybris-common.so.1\") -- "
               "RTLD_NEXT could not see it (libhybris-common is not in the global scope)");
      logflush();
      return 1;
    }
    logbegin("libhybris-common.so.1 exports no android_dlopen/android_dlsym");
    logflush();
  }
  return 0;
}

/* What the linker would have done in InitialLinkDone() -> MaybeInit() -> NotifyLibDl(). Returns 1
 * when the shadow was primed, 0 when this call could not (so the caller can try again later). */
static int prime(void) {
  typedef u64 *(*cfi_init_fn)(u64);
  cfi_init_fn cfi_init;
  void *h;
  u64 lo = 0, hi = 0;
  int count = 0;

  inside = 1;
  if (!resolve_real()) {
    logbegin("no android_dlopen/android_dlsym available -- not priming");
    logflush();
    inside = 0;
    return 0;
  }

  /* libdl.so is standalone-loadable and defines __cfi_init. Loading it by name here, rather than
   * waiting for libcamera_client.so to pull it in, is what makes this early enough to matter. */
  h = real_dlopen("libdl.so", RTLD_NOW);
  if (!h) {
    logbegin("android_dlopen(\"libdl.so\") failed -- not priming");
    logflush();
    inside = 0;
    return 0;
  }
  cfi_init = (cfi_init_fn)real_dlsym(h, "__cfi_init");
  if (!cfi_init) {
    logbegin("libdl.so exports no __cfi_init -- not priming");
    logflush();
    inside = 0;
    return 0;
  }

  shadow = (char *)mmap((void *)0, K_SHADOW_SIZE, PROT_READ | PROT_WRITE,
                        MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
  if (shadow == (void *)-1) {
    shadow = (char *)0;
    logbegin("mmap of the 2 GiB shadow failed -- not priming");
    logflush();
    inside = 0;
    return 0;
  }

  logbegin("shadow at ");
  loghex((u64)shadow);
  logstr(", filling the first ");
  lognum(FILLED_BYTES);
  logstr(" bytes (every address below 0x10000000000) with kUncheckedShadow");
  logflush();

  fill_range(0, FILLED_BELOW);
  cfi_init((u64)shadow);
  inside = 0;

  scan_maps(&lo, &hi, &count);
  if (count) {
    logbegin("hybris already has ");
    lognum((u64)count);
    logstr(" /android/ mappings, ");
    loghex(lo);
    logstr(" .. ");
    loghex(hi);
    logflush();
  }
  return 1;
}

void *android_dlopen(const char *name, int flags) {
  if (!inside && __atomic_load_n(&state, __ATOMIC_ACQUIRE) == 0) {
    if (__atomic_exchange_n(&state, 1, __ATOMIC_ACQ_REL) == 0) {
      /* A "not yet" must not be cached as "never": the first call can arrive before
       * libhybris-common is in any scope resolve_real() can reach, and caching that as final is the
       * bug this shim hit on 2026-09-23 (see resolve_real). Failed attempts leave state at 0, so the
       * next call tries again. */
      int ok = prime();
      __atomic_store_n(&state, ok ? 2 : 0, __ATOMIC_RELEASE);
    } else {
      /* Another thread is priming. It is not waiting on us, so spinning is safe. */
      while (__atomic_load_n(&state, __ATOMIC_ACQUIRE) == 1)
        ;
    }
  }
  if (!real_dlopen) {
    /* Nothing to forward to; try to resolve it now rather than fail the process's dlopens. */
    inside = 1;
    resolve_real();
    inside = 0;
  }
  if (!real_dlopen)
    return (void *)0;
  {
    void *r = real_dlopen(name, flags);
    /* Cheap and idempotent: catch anything the filled band missed, before it is used again. */
    if (shadow && name) {
      u64 lo = 0, hi = 0;
      scan_maps(&lo, &hi, (int *)0);
      if (hi > FILLED_BELOW) {
        logbegin("mapping above the filled band: ");
        loghex(lo);
        logstr(" .. ");
        loghex(hi);
        logstr(" (only addresses below 0x10000000000 are unchecked)");
        logflush();
      }
    }
    return r;
  }
}

/* Not a hook: a "the preload actually loaded" line, so a log with nothing else in it is not
 * ambiguous. */
__attribute__((constructor)) static void cfi_shadow_init_loaded(void) {
  logbegin("loaded");
  logflush();
}
