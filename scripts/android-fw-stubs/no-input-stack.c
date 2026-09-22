/* no-input-stack.so -- an LD_PRELOAD instrument, not a fix and not a replacement for anything.
 *
 * What it is for. The host's /usr/bin/test_camera does two unrelated things in one program: it
 * connects to the camera and renders a preview, and it starts libhybris' Android input stack so a
 * touch can drive the shutter. The camera in this Halium container is now reachable end to end
 * (docs/65): cameraserver completes connect(), the HAL opens, appops and processinfo are answered.
 * The input stack is a separate subsystem with its own problems -- it is what pulls
 * libinputflinger -> libgui -> skia, and on this image it ends in a SIGSEGV a few syscalls after
 * EventHub takes its "KeyEvents" wake lock. Measuring the camera should not require measuring that
 * at the same time, and the two are only coupled because of one listener object inside the test
 * program.
 *
 * So this library exports the six android_input_stack_* entry points as no-ops and goes in front of
 * libis.so.1 with LD_PRELOAD. test_camera is dynamically linked, so its calls to those names bind to
 * whatever the dynamic linker finds first, and LD_PRELOAD comes first. Nothing on the Android side
 * changes: libis_compat_layer.so stays where it is, and the real input stack is untouched.
 *
 * The one honest caveat: with this preloaded, test_camera's touch-to-focus listener never receives
 * anything, because nothing is listening. That is exactly the point, and it is why this file is not
 * called libis_compat_layer.so -- the camera measurement in docs/65 says so in as many words.
 *
 * There is no libc here and none is wanted: the functions do nothing, and the single write() below
 * is a raw syscall. clang, -nostdlib and lld are enough to build it (build.sh).
 */

typedef unsigned long u64;
typedef long i64;

static i64 sys_write(int fd, const void *buf, u64 len)
{
    register i64 x0 __asm__("x0") = fd;
    register const void *x1 __asm__("x1") = buf;
    register u64 x2 __asm__("x2") = len;
    register i64 x8 __asm__("x8") = 64; /* __NR_write */
    __asm__ volatile("svc #0" : "+r"(x0) : "r"(x1), "r"(x2), "r"(x8) : "memory");
    return x0;
}

static void say(const char *msg, u64 len)
{
    /* stderr: the caller's own stdout is line-buffered and would swallow this on a crash */
    sys_write(2, msg, len);
}

#define SAY(s) say(s, sizeof(s) - 1)

void android_input_stack_initialize(void *listener, void *config)
{
    (void)listener;
    (void)config;
    SAY("no-input-stack: android_input_stack_initialize() ignored -- the input stack is not part of"
        " this measurement (see no-input-stack.c)\n");
}

void android_input_stack_loop_once(void) { }

void android_input_stack_start(void)
{
    SAY("no-input-stack: android_input_stack_start() ignored\n");
}

/* The one call with an effect: it is called to block until the stack is up, and the caller passes
 * the flag it is waiting on. Nothing will ever set it if this is a no-op, so set it here. */
void android_input_stack_start_waiting_for_flag(int *flag)
{
    SAY("no-input-stack: android_input_stack_start_waiting_for_flag() sets the flag and returns\n");
    if (flag)
        *flag = 1;
}

void android_input_stack_stop(void) { }

void android_input_stack_shutdown(void) { }
