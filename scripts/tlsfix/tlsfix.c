/*
 * Superset of libtls-padding.so:
 *   * the 128-byte TLS padding that Hybris devices preload so bionic's writes to
 *     TLS slot 2 (TP+16, glibc's first static TLS block) land in padding;
 *   * plus filling TLS slot 1 (TP+8, glibc's unused tcbhead_t::private) with a
 *     bionic pthread_internal_t, which is what __get_thread() reads.
 *
 * The second part is what libhybris' o linker never does: the only code that
 * initialises a bionic thread is __libc_init_main_thread(), which lives in the
 * Android linker and is compiled out under DISABLED_FOR_HYBRIS_SUPPORT.
 *
 * The constructor can only do that for the thread it runs on — the main one. Every
 * thread created later gets a fresh, zeroed TCB, so TP+8 is 0 again and the same
 * fault returns on that thread. That is not hypothetical: the shell starts Mir,
 * Mir creates its server thread, and the server thread is where the SEGV lands
 * (the core the kernel wrote for an earlier one is named `core.MirServerThread.*`).
 * So we also interpose pthread_create and fill the slot in the new thread before
 * its entry point runs.
 *
 * Interposition, not a linker feature, because the slot has to be filled on the
 * *new* thread and there is no other hook that runs there. malloc/dlsym are the
 * only libc entry points used, and both failures fall back to the real
 * pthread_create rather than failing the call.
 */
#define TLS_SLOT_THREAD_ID 1

__thread char tls_padding[128]
    __attribute__((tls_model("initial-exec"), used, visibility("default")));

static char fake_thread[2816 + 8];   /* pthread_internal_t::bionic_tls is at +2816 */
static char fake_bionic_tls[4096];   /* bionic_tls::locale is at +0; zeroed => NULL  */

/* Deliberately not libc headers: this object is built -nostdlib so that it stays
 * loadable in the odd contexts libhybris puts things in. */
extern void *dlsym(void *handle, const char *name);
extern void *malloc(unsigned long size);
extern void free(void *p);
#define RTLD_NEXT ((void *)-1L)

static long sys(long n, long a, long b, long c) {
    register long x0 __asm__("x0") = a;
    register long x1 __asm__("x1") = b;
    register long x2 __asm__("x2") = c;
    register long x8 __asm__("x8") = n;
    __asm__ volatile("svc #0" : "+r"(x0) : "r"(x1), "r"(x2), "r"(x8) : "memory");
    return x0;
}

static void puthex(unsigned long v, char *out) {   /* returns out+len via global */
    static const char d[] = "0123456789abcdef";
    out[0] = '0'; out[1] = 'x';
    for (int i = 0; i < 16; i++) out[2 + i] = d[(v >> (60 - 4 * i)) & 0xf];
}

/* One line per process is useful; one line per thread of a shell that makes hundreds
 * is noise. Six is enough to show the interposer is live. */
static int reported;

static void report(const char *what, void **tp) {
    if (reported >= 6) return;
    reported++;
    char msg[128];
    int n = 0;
    const char *p = "tlsfix2 ";
    while (*p) msg[n++] = *p++;
    p = what; while (*p) msg[n++] = *p++;
    p = " pid="; while (*p) msg[n++] = *p++;
    puthex(sys(172, 0, 0, 0), msg + n); n += 18;        /* __NR_getpid */
    p = " tp="; while (*p) msg[n++] = *p++;
    puthex((unsigned long)tp, msg + n); n += 18;
    p = " slot1_was="; while (*p) msg[n++] = *p++;
    puthex(tp ? (unsigned long)tp[TLS_SLOT_THREAD_ID] : 0, msg + n); n += 18;
    msg[n++] = '\n';
    sys(64, 2, (long)msg, n);                            /* __NR_write */
}

/* Returns 1 if this thread's slot was empty and we filled it. */
static int fill_slot(void) {
    void **tp;
    __asm__ volatile("mrs %0, tpidr_el0" : "=r"(tp));
    if (!tp || tp[TLS_SLOT_THREAD_ID]) return 0;
    *(void **)(fake_thread + 2816) = fake_bionic_tls;
    tp[TLS_SLOT_THREAD_ID] = fake_thread;
    tls_padding[0] = 1;   /* keep the padding TLS alive */
    return 1;
}

__attribute__((used, constructor)) static void tlsfix_init(void) {
    void **tp;
    __asm__ volatile("mrs %0, tpidr_el0" : "=r"(tp));
    report("main", tp);
    fill_slot();
}

/* ---------------------------------------------------------------- threads */

typedef unsigned long zl1_pthread_t;           /* aarch64 glibc: unsigned long */
typedef union { char __size[56]; long __align; } zl1_pthread_attr_t;
typedef void *(*zl1_start_routine_t)(void *);
typedef int (*zl1_pthread_create_t)(zl1_pthread_t *, const zl1_pthread_attr_t *,
                                    zl1_start_routine_t, void *);

struct zl1_thread { zl1_start_routine_t fn; void *arg; };

static zl1_pthread_create_t real_create;

static void *zl1_thread_main(void *p) {
    struct zl1_thread t = *(struct zl1_thread *)p;
    free(p);
    void **tp;
    __asm__ volatile("mrs %0, tpidr_el0" : "=r"(tp));
    report("thread", tp);
    fill_slot();
    return t.fn(t.arg);
}

int pthread_create(zl1_pthread_t *t, const zl1_pthread_attr_t *a,
                   zl1_start_routine_t fn, void *arg) {
    if (!real_create)
        real_create = (zl1_pthread_create_t)dlsym(RTLD_NEXT, "pthread_create");
    if (!real_create || !fn)
        return real_create ? real_create(t, a, fn, arg) : 11;   /* EAGAIN */
    struct zl1_thread *w = (struct zl1_thread *)malloc(sizeof *w);
    if (!w)
        return real_create(t, a, fn, arg);
    w->fn = fn; w->arg = arg;
    int rc = real_create(t, a, zl1_thread_main, w);
    if (rc) free(w);
    return rc;
}
