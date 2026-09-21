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
 */
#define TLS_SLOT_THREAD_ID 1

__thread char tls_padding[128]
    __attribute__((tls_model("initial-exec"), used, visibility("default")));

static char fake_thread[2816 + 8];   /* pthread_internal_t::bionic_tls is at +2816 */
static char fake_bionic_tls[4096];   /* bionic_tls::locale is at +0; zeroed => NULL  */

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

__attribute__((used, constructor)) static void tlsfix_init(void) {
    void **tp;
    __asm__ volatile("mrs %0, tpidr_el0" : "=r"(tp));
    char msg[128];
    int n = 0;
    const char *p = "tlsfix2 pid=";
    while (*p) msg[n++] = *p++;
    puthex(sys(172, 0, 0, 0), msg + n); n += 18;        /* __NR_getpid */
    p = " tp="; while (*p) msg[n++] = *p++;
    puthex((unsigned long)tp, msg + n); n += 18;
    p = " slot1_was="; while (*p) msg[n++] = *p++;
    puthex(tp ? (unsigned long)tp[TLS_SLOT_THREAD_ID] : 0, msg + n); n += 18;
    msg[n++] = '\n';
    sys(64, 2, (long)msg, n);                            /* __NR_write */
    if (!tp || tp[TLS_SLOT_THREAD_ID]) return;
    *(void **)(fake_thread + 2816) = fake_bionic_tls;
    tp[TLS_SLOT_THREAD_ID] = fake_thread;
    tls_padding[0] = 1;   /* keep the padding TLS alive */
}
