/* crash-dump.so -- an LD_PRELOAD instrument that turns "exit=139" into a readable report.
 *
 * Why it exists. Everything on this port that fails on the camera side fails the same way: the
 * process dies of SIGSEGV, `out` is empty or half a line, and the only thing on stderr is whatever
 * hybris printed *before* the jump to NULL. A 139 is not a diagnosis, and the interesting crashes
 * here are inside libraries nothing on this machine can debug: the program is a glibc binary, the
 * code that dies is Android code loaded by hybris' own linker (so it is not in /proc/self/maps'
 * dynamic-linker sense, and `dladdr` cannot name it), and the device has no gdb, no lldb, no
 * readelf and no objdump -- only strace and ltrace.
 *
 * What it does. On the five fatal signals it writes three things to stderr and exits 70: the signal
 * number, the whole of /proc/self/maps, and a stack backtrace of the faulting thread taken with
 * glibc's own backtrace(), which is already in the process. The maps are the part that makes the
 * addresses usable: the top frame of the backtrace is the faulting instruction, and the maps say
 * which file that address belongs to, so the offset can be looked up on the host, where readelf and
 * the build tree's symbols are.
 *
 * Nothing is resolved here and nothing is symbolised: this is a device that has no tools, and a
 * signal handler that tries to be clever (malloc, stdio, dladdr) inside a process that has just
 * crashed is a way to get no report at all. The writes are raw syscalls, the backtrace is glibc's,
 * and the only libc symbols it needs are three (see build.sh), resolved from the process's libc.so.6
 * at load time exactly like libcfi-shadow-init.so.
 *
 * It is a measurement, like no-input-stack.so: it changes nothing about the run except that a crash
 * leaves evidence behind, and the exit code (70 instead of 139) says the report was produced.
 *
 * Build: build.sh. Usage: add it to LD_PRELOAD (run-camera-test.sh does this with --crash-dump).
 */

typedef unsigned long u64;
typedef long i64;

/* --- raw syscalls: safe inside a handler, cannot allocate, cannot deadlock on a libc lock ------ */

static i64 syscall3(i64 n, i64 a, i64 b, i64 c)
{
    register i64 x0 __asm__("x0") = a;
    register i64 x1 __asm__("x1") = b;
    register i64 x2 __asm__("x2") = c;
    register i64 x8 __asm__("x8") = n;
    __asm__ volatile("svc #0" : "+r"(x0) : "r"(x1), "r"(x2), "r"(x8) : "memory");
    return x0;
}

#define NR_OPENAT 56
#define NR_CLOSE 57
#define NR_READ 63
#define NR_WRITE 64
#define NR_EXIT_GROUP 94

#define AT_FDCWD (-100)
#define O_RDONLY 0

static void say(const char *s, u64 n) { syscall3(NR_WRITE, 2, (i64)(unsigned long)s, (i64)n); }
#define SAY(s) say(s, sizeof(s) - 1)

static void say_udec(unsigned long v)
{
    char buf[24];
    int i = 24;
    if (v == 0) { SAY("0"); return; }
    while (v && i > 0) { buf[--i] = (char)('0' + (v % 10)); v /= 10; }
    say(buf + i, (u64)(24 - i));
}

/* --- libc, resolved from the process at load time (see build.sh) --------------------------------- */

typedef void (*sighandler_t)(int);
extern sighandler_t signal(int signum, sighandler_t handler);
extern int backtrace(void **buffer, int size);
extern void backtrace_symbols_fd(void *const *buffer, int size, int fd);

static void report(int sig)
{
    void *frames[64];
    int n;

    SAY("\ncrash-dump: caught signal ");
    say_udec((unsigned long)sig);
    SAY(" -- /proc/self/maps follows, then a backtrace of this thread\n");

    {
        i64 fd = syscall3(NR_OPENAT, AT_FDCWD, (i64)(unsigned long)"/proc/self/maps", O_RDONLY);
        if (fd >= 0) {
            char buf[2048];
            i64 r;
            while ((r = syscall3(NR_READ, fd, (i64)(unsigned long)buf, (i64)sizeof buf)) > 0)
                say(buf, (u64)r);
            syscall3(NR_CLOSE, fd, 0, 0);
        } else {
            SAY("crash-dump: /proc/self/maps could not be opened\n");
        }
    }

    SAY("crash-dump: backtrace, innermost first (addresses; the maps above name the library):\n");
    n = backtrace(frames, 64);
    backtrace_symbols_fd(frames, n, 2);

    SAY("crash-dump: done\n");
    syscall3(NR_EXIT_GROUP, 70, 0, 0);
    for (;;) { }  /* exit_group does not return; this is for the compiler */
}

__attribute__((constructor)) static void crash_dump_armed(void)
{
    /* 4 SIGILL, 6 SIGABRT, 7 SIGBUS, 8 SIGFPE, 11 SIGSEGV */
    signal(11, report);
    signal(7, report);
    signal(6, report);
    signal(4, report);
    signal(8, report);
    SAY("crash-dump: armed (SIGSEGV/SIGBUS/SIGABRT/SIGILL/SIGFPE -> maps + backtrace, exit 70)\n");
}
