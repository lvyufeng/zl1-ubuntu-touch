/* The Android framework services this Halium container does not have, provided in raw binder.
 *
 * The camera cannot open, and the reason is not the camera:
 *
 *   test_camera -> libcamera.so.1 -> android_dlopen(libcamera_compat_layer) -> ICameraService
 *   -> cameraserver -> CameraService::connect
 *      -> connectHelper                       (mServiceLock taken, held to the end of the call)
 *         -> validateClientPermissionsLocked
 *            -> checkPermission("android.permission.CAMERA", pid, uid)       [libbinder]
 *               -> checkService("permission")   <- no such service, so: sleep(1) and retry, forever
 *
 * android::checkPermission (frameworks/native/libs/binder/IServiceManager.cpp:81) is a retry loop:
 * while checkService("permission") returns NULL it logs "Waiting to check permission ..." and
 * sleeps a second, with no timeout. The "permission" service is android.os.IPermissionController,
 * which on a phone is registered by system_server -- and a Halium container has no system_server.
 * So the loop never ends, and it never releases mServiceLock; every later connect queues behind
 * that lock forever. That is exactly what the device showed:
 *
 *   /proc/<cameraserver> (32-bit, inner pid 1021)
 *     thread 49944   futex_wait on 0xf504d008 (heap)  <- mServiceLock, word=Contended, 3 waiters
 *     thread 1597268 hrtimer_nanosleep                <- the 1 s sleep in that loop
 *     thread 3254879 futex_wait on 0xf504d008         <- our connect, waiting for the lock
 *     thread 3254880 futex_wait on 0xf504d008
 *   /sys/kernel/debug/binder/transaction_log:
 *     10x "call from 49944:1597268 to 41134 node 43 handle 0 size 92:0"   -> servicemanager
 *     10x "reply from 41134:41134 to 49944:1597268 ... size 4:0"          -> no object, no service
 *   logcat:
 *     "Waiting to check permission android.permission.CAMERA from uid=0 pid=12667"
 *
 * The 92 bytes are checkService("permission") and nothing else: 4 strict-mode + 4 + 26*2 + 2 (the
 * interface token "android.os.IServiceManager", padded to 64) + 4 + 10*2 + 2 (the name, padded to
 * 28) = 92. The 4-byte reply is the servicemanager's did-not-have-it answer.
 *
 * Right behind that one is a second missing service, for the same reason:
 *
 *   connectHelper -> finishConnectLocked -> Client::startCameraOps
 *      -> mAppOpsManager.startOpNoThrow(...)   -> checkService("appops") -> 10 s -> NULL
 *      -> APP_OPS_MANAGER_UNAVAILABLE_MODE == MODE_IGNORED   (AppOpsManager.cpp:32-34, !__BRILLO__)
 *      -> returns -EACCES -> the connect fails with 'Access for "..." has been restricted'
 *
 * So both names have to exist. Neither has to *do* anything: this is port bring-up in a container
 * with SELinux disabled and no application model, and what the HAL stack wants from these two is
 * permission to proceed. Every request is logged with service, code and fields, so what the camera
 * stack asks for ends up on the record rather than assumed -- the appops transaction codes in
 * particular come from the AIDL declaration order and are checked by running it, not trusted.
 *
 * With both registered, connect() got past that and then stopped at the next thing no system_server
 * exists to provide (device log, same cameraserver):
 *
 *   CameraService: Check passed after 1630 seconds for android.permission.CAMERA from uid=0 pid=12667
 *   CameraService: CameraService::connect X (PID 12667) rejected
 *                  (cannot connect from device user 0, currently allowed device users: )
 *
 * The check is CameraService.cpp:938 --
 *   if (callingPid != getpid() && (mAllowedUsers.find(clientUserId) == mAllowedUsers.end()))
 * -- and mAllowedUsers is only ever written by CameraService::doUserSwitch (CameraService.cpp:1862),
 * which a phone reaches through system_server's CameraServiceProxy calling
 * ICameraService::notifySystemEvent(EVENT_USER_SWITCHED, {userId}). No system_server means nobody
 * ever tells cameraserver that any user is allowed, so the set stays empty and *every* client is
 * rejected however the permission question was answered. There is no other writer of that set.
 *
 * So this registers those two services and then, as a client, tells cameraserver what system_server
 * would have told it: notifySystemEvent(1, {0}) on "media.camera". EVENT_USER_SWITCHED is also the
 * only event, and it is oneway, so there is no reply to read. `--notify-user-switch` re-sends just
 * that one transaction, which is what to run again if cameraserver is ever restarted: a restarted
 * cameraserver starts with an empty mAllowedUsers all over again.
 *
 * That event was being sent for weeks and never arrived, and the reason was one missing pair of
 * bytes rather than anything about cameraserver: a handle out of checkService() is a *weak*
 * reference until its new owner acquires it, and the driver refuses a transaction to a weak handle
 * (binder_get_ref_olocked(..., require_strong)). libbinder acquires it in BpBinder::onFirstRef ->
 * incStrongHandle -> BC_ACQUIRE; a program that speaks raw binder has to send that itself. Without
 * it every attempt read, in /sys/kernel/debug/binder/failed_transaction_log,
 *
 *     async from <this process> to 0:0 context binder node 0 handle 1 size 84:0 ret 29201/-22 l=3009
 *
 * -- BR_FAILED_REPLY (29201) / -EINVAL, at the kernel's `if (!target_node)` after the handle branch
 * gave up on the ref. Silent, because a oneway call has no reply to carry the error back: the only
 * visible symptom was mAllowedUsers staying empty. See binder_acquire().
 *
 * And the user switch itself needs a third name, because its handler asks for one before it applies
 * anything -- CameraUidPolicy::registerSelf() -> ActivityManager::getService() -> "activity", in a
 * loop with no healthy exit. With nothing answering to that name the event never lands and every
 * connect stays rejected however the permissions were answered. Measured on the device as 40
 * lookups a second for an 8-character name that never resolves; see serve_activity.
 *
 * One more, on the far side of the user gate: CameraService::handleEvictionsLocked asks
 * ProcessInfoService for the state and OOM score of every pid holding a camera, and without
 * "processinfo" libbinder retries for BINDER_ATTEMPT_LIMIT seconds and then returns ETIMEDOUT, so
 * connect() fails with -110. See serve_processinfo.
 *
 * And a fifth, which is the one that hangs the *preview* rather than the connect. Unlike the other
 * four it is asked for from inside a client call, on a loop with no timeout, no log and no exit:
 *
 *   Camera3Device::configureStreamsLocked (Camera3Device.cpp:2565-2582), the last thing it does
 *   after the client's streams have been handed to the HAL --
 *     property_get("camera.fifo.disable", value, "0");
 *     if (disableFifo != 1) {
 *         res = requestPriority(getpid(), mRequestThread->getTid(), kRequestThreadPriority, ...)
 *   -> android::requestPriority (frameworks/av/media/utils/SchedulingPolicyService.cpp:31)
 *     for (;;) {
 *         sp<IBinder> binder = defaultServiceManager()->checkService(_scheduling_policy);
 *         if (binder == 0) { sleep(1); continue; }
 *
 * The thread asleep in that sleep(1) is the one serving the client's startPreview (ICamera's
 * START_PREVIEW, binder code 5), so the client waits for a reply that never comes. Measured on the
 * device with the camera stack reset, one snapshot of both processes:
 *
 *   app  main thread   binder_thread_read                 <- waiting for the reply to code 5
 *   app  input thread  nanosleep, 100 ms at a time         <- the input layer; a separate problem
 *   cs   Binder:_3     nanosleep({tv_sec=1}) forever       <- requestPriority's sleep(1)
 *
 * and the binder tracepoints named the transaction that sleep sits between:
 *
 *   binder_transaction: dest_node=43 dest_proc=<servicemanager> reply=0 flags=0x10 code=0x2
 *   binder_transaction_alloc_buf: data_size=104 offsets_size=0
 *
 * -- a synchronous CHECK_SERVICE_TRANSACTION to servicemanager every 1.0002 s, which is the
 * checkService above. The 104 bytes give the name without reading the payload: 4 strict-mode + 60
 * (the 27-char token "android.os.IServiceManager" with its NUL, 4+56) + 4 + pad4(2L+2) = 104, so
 * pad4(2L+2) = 36, i.e. 16 or 17 characters. Read out of cameraserver's own /proc/<pid>/mem beside
 * that token the name is 17: "scheduling_policy". The same arithmetic on the app's own poll -- the
 * input layer waiting for SurfaceFlinger -- gives 100 bytes and 14 characters, and the app's log
 * says SurfaceFlinger, which is the check on the method.
 *
 * What the call is for is the only thing the camera wants that has nothing to do with the camera:
 * SCHED_FIFO for its request-processing thread. This container has no system_server, so the name
 * resolves to nothing and the loop never gets past its first branch. serve_scheduling_policy
 * answers it and does the boost it asked for.
 *
 * The same three lines carry an escape hatch: camera.fifo.disable=1 skips the call entirely. That
 * is a way to prove this is the blocker (set the property, restart cameraserver, watch the preview
 * start) and it is not how this port fixes it -- the property would have to live in the container's
 * build, and a phone has the service.
 *
 * Answering:
 *   permission   android.os.IPermissionController  checkPermission -> true,
 *                                                  isRuntimePermission -> true,
 *                                                  getPackagesForUid -> one synthetic package,
 *                                                  noteOp -> MODE_ALLOWED
 *   appops       android.app.IAppOpsService        startOperation/checkOperation -> MODE_ALLOWED(0),
 *                                                  getToken -> a binder of our own,
 *                                                  everything else -> success, no data
 *   activity     android.app.IActivityManager      isUidActive -> true (the answer CameraUidPolicy
 *                                                  itself gives for a system uid), registerUidObserver
 *                                                  accepted and never called back, everything else 0
 *   processinfo  android.os.IProcessInfoService    every pid it asks about exists and is in the
 *                                                  foreground: state 2 (PROCESS_STATE_TOP), score 0
 *   scheduling_policy
 *                android.os.ISchedulingPolicyService
 *                                                  requestPriority -> SCHED_FIFO is set on the tid
 *                                                  it names (best effort; OK is replied either way),
 *                                                  requestCpusetBoost -> OK, nothing moved

 *
 * Why raw binder rather than a C++ service: a BnPermissionController subclass would have to be
 * built against the container's libbinder/libutils ABI (this image is a *different build* of the
 * same Lineage-16 tree -- libutils is byte-identical in size, libbinder is not), and a wrong vtable
 * or RefBase layout there is a crash inside the client. The wire format is a documented struct, so
 * this needs no Android libraries at all. Same reasoning as scripts/cfi-shadow/cfi-shadow-init.c.
 *
 * And it needs no libc either: every call it makes is a raw aarch64 syscall, so the result is a
 * static binary that runs on the host, under nsenter, and on the container's bionic side alike.
 *
 * The addService parcel is what libbinder's BpServiceManager writes and what servicemanager's
 * bio_get_string16/bio_get_ref/bio_get_uint32 read back (frameworks/native/cmds/servicemanager/
 * service_manager.c:274-320 -- it consumes the strict-mode word first, then the interface token,
 * then the name, then the object, then two ints):
 *
 *   u32 strictModePolicy   u32 26  "android.os.IServiceManager"
 *   u32 len  <name as UTF-16, NUL, padded>
 *   struct flat_binder_object {type=BINDER_TYPE_BINDER, flags, binder, cookie}  <- listed in offs[]
 *   u32 allowIsolated   u32 dumpsysPriority
 *
 * Build: scripts/android-fw-stubs/build.sh    Run: scripts/android-fw-stubs/run-on-device.sh
 */

typedef unsigned char u8;
typedef unsigned short u16;
typedef unsigned int u32;
typedef unsigned long long u64;

/* --------------------------------------------------------------------------- syscalls ----------
 * aarch64 syscall numbers; the wrapper puts the args in x0-x5 and the number in x8, which is the
 * whole calling convention. */
#define SYS_ioctl 29
#define SYS_write 64
#define SYS_openat 56
#define SYS_close 57
#define SYS_getpid 172
#define SYS_mmap 222
#define SYS_exit_group 94
#define AT_FDCWD (-100)

static long sys6(long n, long a, long b, long c, long d, long e, long f) {
  register long x0 __asm__("x0") = a;
  register long x1 __asm__("x1") = b;
  register long x2 __asm__("x2") = c;
  register long x3 __asm__("x3") = d;
  register long x4 __asm__("x4") = e;
  register long x5 __asm__("x5") = f;
  register long x8 __asm__("x8") = n;
  __asm__ volatile("svc #0"
                   : "+r"(x0)
                   : "r"(x1), "r"(x2), "r"(x3), "r"(x4), "r"(x5), "r"(x8)
                   : "memory");
  return x0;
}

static int sys_open(const char *path, int flags, int mode) {
  return (int)sys6(SYS_openat, AT_FDCWD, (long)path, flags, mode, 0, 0);
}
static long sys_write(int fd, const void *buf, unsigned long n) {
  return sys6(SYS_write, fd, (long)buf, (long)n, 0, 0, 0);
}
static int sys_close(int fd) { return (int)sys6(SYS_close, fd, 0, 0, 0, 0, 0); }
static long sys_ioctl(int fd, unsigned long req, void *arg) {
  return sys6(SYS_ioctl, fd, (long)req, (long)arg, 0, 0, 0);
}
static void *sys_mmap(void *addr, unsigned long len, int prot, int flags, int fd, long off) {
  return (void *)sys6(SYS_mmap, (long)addr, (long)len, prot, flags, fd, off);
}
static int sys_getpid(void) { return (int)sys6(SYS_getpid, 0, 0, 0, 0, 0, 0); }

/* clang turns the struct copies below into calls to these even when freestanding, so they have to
 * exist somewhere; nothing else in this program needs libc. */
void *memcpy(void *dst, const void *src, unsigned long n) {
  unsigned char *d = dst;
  const unsigned char *s = src;
  while (n--)
    *d++ = *s++;
  return dst;
}

void *memset(void *dst, int c, unsigned long n) {
  unsigned char *d = dst;
  while (n--)
    *d++ = (unsigned char)c;
  return dst;
}

/* ------------------------------------------------------------------ binder ABI (64-bit) --------
 * _IOC(dir,type,nr,size) = (dir << 30) | (size << 16) | (type << 8) | nr; dir none 0, write 1,
 * read 2; 'b' 0x62, 'c' 0x63, 'r' 0x72. One value of this table can be checked against the running
 * device: BINDER_WRITE_READ = 0xc0306201, which is what a live binder ioctl shows in
 * /proc/<pid>/syscall. */
#define BINDER_WRITE_READ 0xc0306201UL

/* struct binder_transaction_data is 0x40 bytes in a 64-bit process: 8+8+4+4+4+4+8+8+16. */
#define BC_TRANSACTION 0x40406300UL
#define BC_REPLY 0x40406301UL
#define BC_FREE_BUFFER 0x40086303UL
#define BC_ENTER_LOOPER 0x0000630cUL
/* _IOW('c', 4|5, __u32): the two commands a binder client sends to take a reference on a handle it
 * has just been given. See binder_acquire() -- without them a handle from checkService() cannot be
 * transacted with at all, and the notifySystemEvent below is the transaction that proves it. */
#define BC_INCREFS 0x40046304UL
#define BC_ACQUIRE 0x40046305UL
#define BINDER_TYPE_BINDER 0x73622a85U /* B_PACK_CHARS('s','b','*',0x85) */
/* Only ever seen in a reply, and only for a name that is registered *by the receiving process*:
 * servicemanager answers with a handle, and the driver rewrites it back into a local object when
 * the node it names turns out to live in the receiving process -- which is what checkService on
 * one of our own two names does. A handle to somebody else's service stays a handle. */
#define BINDER_TYPE_HANDLE 0x73682a85U /* B_PACK_CHARS('s','h','*',0x85) */
#define FLAT_BINDER_FLAG_ACCEPTS_FDS 0x100U
#define TF_ACCEPT_FDS 0x10U
#define TF_ONE_WAY 0x01U
#define ADD_SERVICE_TRANSACTION 3U /* BpServiceManager: GET 1, CHECK 2, ADD 3, LIST 4 */
#define CHECK_SERVICE_TRANSACTION 2U
#define ISERVICEMANAGER_DESC "android.os.IServiceManager"

/* android.hardware.ICameraService, from frameworks/av/camera/aidl/android/hardware/
 * ICameraService.aidl, whose methods get transaction codes in declaration order:
 *   1 getNumberOfCameras  2 getCameraInfo      3 connect        4 connectDevice
 *   5 connectLegacy       6 addListener        7 removeListener 8 getCameraCharacteristics
 *   9 getCameraVendorTagDescriptor             10 getCameraVendorTagCache
 *  11 getLegacyParameters 12 supportsCameraApi 13 setTorchMode   14 notifySystemEvent
 * notifySystemEvent is `oneway void notifySystemEvent(int eventId, in int[] args)`, and
 * EVENT_USER_SWITCHED is the only event it defines. */
#define ICAMERASERVICE_DESC "android.hardware.ICameraService"
#define ICAMERASERVICE_NOTIFY_SYSTEM_EVENT 14U
#define ICAMERASERVICE_EVENT_USER_SWITCHED 1U
#define CAMERA_SERVICE_NAME "media.camera"

/* android.app.IActivityManager, from frameworks/base/core/java/android/app/IActivityManager.aidl.
 * The ordinal is what the AIDL generator assigns, counting methods in declaration order, and the
 * first four are exactly the four libbinder's native ActivityManager class calls:
 *   1 openContentUri(String)  2 registerUidObserver(IUidObserver, int, int, String)
 *   3 unregisterUidObserver(IUidObserver)  4 isUidActive(int, String)
 * -- which is corroboration for the numbering, not just a reading of the file (the same four, in
 * the same order, as ActivityManager.cpp). The running stub logs the code it is handed, so a client
 * built from a different AIDL would show up in that log as a mismatch. */
#define IACTIVITYMANAGER_REGISTER_UID_OBSERVER 2U
#define IACTIVITYMANAGER_IS_UID_ACTIVE 4U
#define IACTIVITYMANAGER_DESC "android.app.IActivityManager"
#define ACTIVITY_SERVICE_NAME "activity"

/* android.os.IProcessInfoService, from frameworks/base/core/java/android/os/IProcessInfoService.aidl:
 *   1 void getProcessStatesFromPids(in int[] pids, out int[] states)
 *   2 void getProcessStatesAndOomScoresFromPids(in int[] pids, out int[] states, out int[] scores)
 * Reached from CameraService::handleEvictionsLocked (CameraService.cpp:1044), which asks for the
 * state and OOM score of every client that holds a camera before it will hand one out. libbinder's
 * ProcessInfoService retries the lookup BINDER_ATTEMPT_LIMIT times with a one-second sleep between
 * them and then returns TIMED_OUT, so the camera's first connect after the permission and user
 * questions were answered failed with exactly that:
 *   handleEvictionsLocked: Priority score query failed: -110
 *   CameraBase: An error occurred while connecting to camera 1: Status(-8): '10: connectHelper:1375:
 *               Unexpected error Connection timed out (-110) opening camera "1"'
 * -110 is ETIMEDOUT. There is no process model in this container to report, and nothing else holds
 * a camera, so every pid it asks about is answered as a process that exists and is in the
 * foreground (state 2 = PROCESS_STATE_TOP, score 0) -- which is what makes the eviction policy
 * decide there is nothing to evict, and is the truth for the only client there is. */
#define IPROCESSINFOSERVICE_DESC "android.os.IProcessInfoService"
#define IPROCESSINFOSERVICE_GET_STATES 1U
#define IPROCESSINFOSERVICE_GET_STATES_AND_SCORES 2U
#define PROCESSINFO_SERVICE_NAME "processinfo"
#define PROCESS_STATE_TOP 2U

/* android.os.ISchedulingPolicyService, from frameworks/av/media/utils/ISchedulingPolicyService.h
 * ("keep in sync with frameworks/base/core/java/android/os/ISchedulingPolicyService.aidl"):
 *   1 int requestPriority(int32 pid, int32 tid, int32 prio, bool isForApp, bool asynchronous)
 *   2 int requestCpusetBoost(bool enable, IBinder client)
 * system_server registers it as "scheduling_policy" (SystemServer.java:828) -- the fifth name this
 * container has no system_server to provide. Unlike the other four it is asked for *from inside* a
 * client's call and on a loop with no timeout and no log; the header has the measurement.
 *
 * Both methods reply writeNoException() and then an int32 status (the Bp side in
 * ISchedulingPolicyService.cpp ends with reply.readInt32()); the second one's `client` argument is
 * a binder and therefore arrives in the offsets array, which this program does not need to read. */
#define ISCHEDULINGPOLICYSERVICE_DESC "android.os.ISchedulingPolicyService"
#define ISCHEDULINGPOLICY_REQUEST_PRIORITY 1U
#define ISCHEDULINGPOLICY_REQUEST_CPUSET_BOOST 2U
#define SCHEDULING_POLICY_SERVICE_NAME "scheduling_policy"
/* sched_setscheduler(2) on aarch64, and the policy the camera asks for -- the same thing the real
 * service does for this call. */
#define SYS_sched_setscheduler 119
#define SCHED_FIFO 1

/* BR_* are matched on (type, nr) only. The kernel encodes them _IOW('r', nr, ...) and libbinder
 * mirrors that, but the direction bit is not worth betting the program on. */
#define BR_IS(cmd, nr) ((((cmd) & 0xff) == (nr)) && ((((cmd) >> 8) & 0xff) == 0x72))
#define BR_TRANSACTION_NR 2
#define BR_REPLY_NR 3
#define BR_DEAD_REPLY_NR 5
#define BR_TRANSACTION_COMPLETE_NR 6
#define BR_NOOP_NR 12
#define BR_SPAWN_LOOPER_NR 13
#define BR_DEAD_BINDER_NR 15
#define BR_CLEAR_DEATH_NOTIFICATION_DONE_NR 16
#define BR_FAILED_REPLY_NR 17

/* Transactions every libbinder BBinder answers, whether or not it implements anything. PING matters
 * here: AppOpsManager::getService() polls isBinderAlive() before it will use a service, and
 * checkPermission() calls it too if the controller answers false. */
#define PING_TRANSACTION 0x5f504e47U      /* 'PNG'  */
#define DUMP_TRANSACTION 0x5f444d50U      /* 'DUMP' */
#define INTERFACE_TRANSACTION 0x5f4e5446U /* 'INTF' */

struct binder_write_read {
  u64 write_size;
  u64 write_consumed;
  u64 write_buffer;
  u64 read_size;
  u64 read_consumed;
  u64 read_buffer;
};

struct binder_transaction_data {
  union {
    u32 handle;
    u64 ptr;
  } target;
  u64 cookie;
  u32 code;
  u32 flags;
  int sender_pid;
  u32 sender_euid;
  u64 data_size;
  u64 offsets_size;
  union {
    struct {
      u64 buffer;
      u64 offsets;
    } ptr;
    u8 buf[8];
  } data;
};

struct flat_binder_object {
  u32 type;
  u32 flags;
  u64 binder;
  u64 cookie;
};

/* --------------------------------------------------------------------------------- logging ----- */
#define LOGBUF 1024
#define LOGFILE "/userdata/zl1-fw-stubs/service-stub.log"

static char logbuf[LOGBUF];
static char *logp;

static void logstr(const char *s) {
  while (*s && logp < logbuf + LOGBUF - 2)
    *logp++ = *s++;
}

static void loghex(u64 v) {
  char tmp[20];
  int n = 0, i, started = 0;
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

static void lognum(long v) {
  char tmp[24];
  int n = 0;
  unsigned long u;
  if (v < 0) {
    *logp++ = '-';
    u = (unsigned long)(-v);
  } else {
    u = (unsigned long)v;
  }
  if (u == 0)
    tmp[n++] = '0';
  while (u) {
    tmp[n++] = (char)('0' + (int)(u % 10));
    u /= 10;
  }
  while (n--)
    *logp++ = tmp[n];
}

/* The text of a parcel string16 at `d` (which points at its 4-byte length). */
static void logutf16(const u8 *d, long maxchars) {
  long i;
  u32 len = *(const u32 *)(const void *)d;
  if (len == 0) {
    logstr("(empty)");
    return;
  }
  if ((long)len > maxchars)
    len = (u32)maxchars;
  for (i = 0; i < (long)len; i++) {
    u16 c = *(const u16 *)(const void *)(d + 4 + 2 * i);
    *logp++ = (c >= 32 && c < 127) ? (char)c : '?';
  }
}

static void logflush(void) {
  int fd;
  *logp++ = '\n';
  sys_write(2, logbuf, (unsigned long)(logp - logbuf));
  fd = sys_open(LOGFILE, 1 | 0100 | 02000 /* O_WRONLY|O_CREAT|O_APPEND */, 0644);
  if (fd >= 0) {
    sys_write(fd, logbuf, (unsigned long)(logp - logbuf));
    sys_close(fd);
  }
}

static void logbegin(const char *what) {
  logp = logbuf;
  logstr("fwsvc[");
  lognum((long)sys_getpid());
  logstr("] ");
  logstr(what);
}

/* ------------------------------------------------------------------------------ parcels -------- */
#define MAXOFFS 4
struct pbuf {
  u64 len;
  u64 offs[MAXOFFS];
  int noffs;
  u8 d[1024];
};

static void p_init(struct pbuf *p) {
  p->len = 0;
  p->noffs = 0;
}

static void p_pad(struct pbuf *p) {
  while (p->len & 3)
    p->d[p->len++] = 0;
}

static void p_u32(struct pbuf *p, u32 v) {
  *(u32 *)(void *)(p->d + p->len) = v;
  p->len += 4;
}

/* writeString16: the length, the chars, a NUL, padded to 4 -- which is the (len+1)*2 bytes that
 * servicemanager's bio_get_string16 consumes. */
static void p_str16(struct pbuf *p, const char *s) {
  int i, n = 0;
  while (s[n])
    n++;
  p_u32(p, (u32)n);
  for (i = 0; i < n; i++) {
    *(u16 *)(void *)(p->d + p->len) = (u16)(u8)s[i];
    p->len += 2;
  }
  *(u16 *)(void *)(p->d + p->len) = 0;
  p->len += 2;
  p_pad(p);
}

/* A local binder object, and its offset in the offsets array -- the driver walks that array and
 * rewrites this struct into a handle for whoever the transaction goes to. `ptr` is the driver's key
 * for the node (unique per process, so two services need two values) and `cookie` comes back with
 * every transaction that arrives, which is how one process serves several names. */
static void p_fbo(struct pbuf *p, u64 ptr, u64 cookie) {
  struct flat_binder_object *o = (struct flat_binder_object *)(void *)(p->d + p->len);
  if (p->noffs < MAXOFFS)
    p->offs[p->noffs++] = p->len;
  o->type = BINDER_TYPE_BINDER;
  o->flags = 0x7f | FLAT_BINDER_FLAG_ACCEPTS_FDS;
  o->binder = ptr;
  o->cookie = cookie;
  p->len += sizeof(struct flat_binder_object);
  p_pad(p);
}

static void copy_bytes(void *dst, const void *src, u64 n) {
  u64 i;
  for (i = 0; i < n; i++)
    ((u8 *)dst)[i] = ((const u8 *)src)[i];
}

/* ------------------------------------------------------------------------- the binder calls --- */
/* The handle out of the last reply that carried a flat_binder_object: what checkService() hands
 * back for a name that exists, and the only way to address that service afterwards. */
static u32 last_handle;

/* Both defined further down (the services they speak for are below the parcel helpers). Declared
 * here because a reply wait can turn into a nested call that has to be answered in place. */
static void answer(int fd, const struct binder_transaction_data *tr, const u8 *d, u64 len);
static const char *service_name(u64 cookie);
static void serve_activity(u32 code, const u8 *d, u64 len, struct pbuf *p);
static void serve_processinfo(u32 code, const u8 *d, u64 len, struct pbuf *p);
static void serve_scheduling_policy(u32 code, const u8 *d, u64 len, struct pbuf *p);

/* Give a binder buffer back. libbinder does this from the Parcel that owns it; here it is explicit,
 * because every buffer left unreleased stays allocated in this process's binder mapping until the
 * process dies -- and this process is meant to live as long as the camera does. */
static void free_buffer(int fd, u64 buffer) {
  u8 wbuf[12];
  struct binder_write_read bwr;
  u64 i;

  *(u32 *)(void *)wbuf = BC_FREE_BUFFER;
  copy_bytes(wbuf + 4, &buffer, 8);
  for (i = 0; i < sizeof(bwr); i++)
    ((u8 *)(void *)&bwr)[i] = 0;
  bwr.write_size = 12;
  bwr.write_buffer = (u64)(unsigned long)wbuf;
  sys_ioctl(fd, BINDER_WRITE_READ, &bwr);
}

/* Take a reference on a handle this process has just been given, in the two commands libbinder
 * sends for the same reason: BpBinder::BpBinder -> incWeakHandle (BC_INCREFS) and, on the first
 * sp<>, BpBinder::onFirstRef -> IPCThreadState::incStrongHandle (BC_ACQUIRE).
 *
 * This is not bookkeeping -- it is the difference between a usable handle and an unusable one. The
 * driver only delivers a BC_TRANSACTION whose target ref is *strong*: binder_transaction() resolves
 * the target with binder_get_ref_olocked(proc, tr->target.handle, true), where that last argument
 * means require_strong (kernel/leeco/msm8996/drivers/staging/android/binder.c, the
 * tr->target.handle branch), and a handle that arrived in a reply is a *weak* ref until its new
 * owner says otherwise. Skip this and
 * every transaction to a handle is refused with BR_FAILED_REPLY/-EINVAL, at that same file's
 * `if (!target_node)` after `goto err_invalid_target_handle`, which is what the device's
 * /sys/kernel/debug/binder/failed_transaction_log showed for this program:
 *
 *     async from 1463216:1463216 to 0:0 context binder node 0 handle 1 size 84:0 ret 29201/-22 l=3009
 *
 * -- the notify below, silently dropped, because a oneway transaction has no reply to carry the
 * error back. Its only symptom on the device was that cameraserver's mAllowedUsers stayed empty and
 * every connect() was rejected with "cannot open camera ... from device user 0". The same process's
 * calls to the servicemanager (handle 0, the context manager, which no strong ref is required for)
 * read `ret 0/0` in transaction_log right next to it. */
static void binder_acquire(int fd, u32 handle) {
  u8 wbuf[16];
  struct binder_write_read bwr;
  u64 i;

  *(u32 *)(void *)wbuf = BC_INCREFS;
  copy_bytes(wbuf + 4, &handle, 4);
  *(u32 *)(void *)(wbuf + 8) = BC_ACQUIRE;
  copy_bytes(wbuf + 12, &handle, 4);
  for (i = 0; i < sizeof(bwr); i++)
    ((u8 *)(void *)&bwr)[i] = 0;
  bwr.write_size = 16;
  bwr.write_buffer = (u64)(unsigned long)wbuf;
  sys_ioctl(fd, BINDER_WRITE_READ, &bwr);
}

/* One BINDER_WRITE_READ carrying [u32 cmd][struct binder_transaction_data], which is how libbinder
 * lays it out in IPCThreadState::writeTransactionData. If want_reply, the reply's first words are
 * logged and its size returned. */
static int binder_transact(int fd, struct pbuf *p, u32 handle, u32 cmd, u32 code, int want_reply,
                           u32 flags) {
  u8 wbuf[8 + sizeof(struct binder_transaction_data)];
  u8 rbuf[1024];
  struct binder_write_read bwr;
  struct binder_transaction_data tr;
  u64 i;
  long n;

  tr.target.handle = handle;
  tr.cookie = 0;
  tr.code = code;
  tr.flags = flags;
  tr.sender_pid = 0;
  tr.sender_euid = 0;
  tr.data_size = p->len;
  tr.offsets_size = (u64)p->noffs * sizeof(u64);
  tr.data.ptr.buffer = (u64)(unsigned long)p->d;
  tr.data.ptr.offsets = (u64)(unsigned long)p->offs;

  *(u32 *)(void *)wbuf = cmd;
  copy_bytes(wbuf + 4, &tr, sizeof(tr));

  for (i = 0; i < sizeof(bwr); i++)
    ((u8 *)(void *)&bwr)[i] = 0;
  bwr.write_size = 4 + sizeof(tr);
  bwr.write_buffer = (u64)(unsigned long)wbuf;
  /* A oneway transaction has no reply coming, so there is nothing to read and reading anyway would
   * only swallow the next command -- see send_reply. The driver still has a BR_TRANSACTION_COMPLETE
   * to hand over for the write, and the main loop picks that up when it reads next. */
  if (want_reply) {
    bwr.read_size = sizeof(rbuf);
    bwr.read_buffer = (u64)(unsigned long)rbuf;
  }

  n = sys_ioctl(fd, BINDER_WRITE_READ, &bwr);
  if (n < 0)
    return -1;
  if (!want_reply)
    return 0;

  for (i = 0; i + 4 <= bwr.read_consumed;) {
    u32 c;
    while (i & 3)
      i++;
    if (i + 4 > bwr.read_consumed)
      break;
    c = *(u32 *)(void *)(rbuf + i);
    i += 4;
    if (BR_IS(c, BR_REPLY_NR)) {
      struct binder_transaction_data *r = (struct binder_transaction_data *)(void *)(rbuf + i);
      u64 sz = r->data_size;
      u64 buf = r->data.ptr.buffer;
      logbegin("  reply: ");
      lognum((long)sz);
      logstr(" bytes");
      if (sz >= 4) {
        u8 *d = (u8 *)(unsigned long)buf;
        logstr(", first word ");
        lognum((long)*(u32 *)(void *)d);
        if (sz >= 24) {
          /* A 24-byte reply is one flat_binder_object and nothing else, which is what the
           * servicemanager answers a found name with: type, flags 0x7f|ACCEPTS_FDS, then the
           * union at +8 and the cookie at +16. */
          const u32 type = *(const u32 *)(const void *)d;
          logstr(", ");
          if (type == BINDER_TYPE_HANDLE) {
            last_handle = (u32) * (const u64 *)(const void *)(d + 8);
            /* Log the number, not the type: the number is what every later transaction names, and
             * printing the type here once made a wrong handle look right. */
            logstr("handle ");
            lognum((long)last_handle);
            logstr(" of type ");
            loghex(type);
            /* And make it usable, which it is not until this is sent -- see binder_acquire(). */
            binder_acquire(fd, last_handle);
          } else {
            last_handle = 0;
            logstr("local object of type ");
            loghex(type);
          }
        }
      }
      logflush();
      /* The reply buffer is allocated out of this process's binder mapping and is ours to release;
       * left unfreed, every checkService would leak one, and the device showed five of them
       * ("buffer ... delivered") held open before the camera ever connected. */
      free_buffer(fd, buf);
      return (int)sz;
    }
    if (BR_IS(c, BR_DEAD_REPLY_NR) || BR_IS(c, BR_FAILED_REPLY_NR)) {
      logbegin("  transaction failed (dead/failed reply)");
      logflush();
      return -1;
    }
    if (BR_IS(c, BR_TRANSACTION_NR)) {
      /* A call can arrive on this thread while we are waiting for a reply. It has been delivered
       * to us and will not come again, so it has to be answered here -- dropping it is exactly the
       * failure that wedged cameraserver. */
      struct binder_transaction_data *in = (struct binder_transaction_data *)(void *)(rbuf + i);
      logbegin("transaction for ");
      logstr(service_name(in->cookie));
      logstr(" code ");
      lognum((long)in->code);
      logstr(" (nested, while waiting for a reply)");
      logflush();
      if (in->data.ptr.buffer)
        answer(fd, in, (const u8 *)(unsigned long)in->data.ptr.buffer, in->data_size);
      i += sizeof(struct binder_transaction_data);
    } else if (BR_IS(c, BR_NOOP_NR) || BR_IS(c, BR_TRANSACTION_COMPLETE_NR)) {
      ;
    } else {
      break;
    }
  }
  return 0;
}

static int add_service(int fd, const char *name, u64 ptr, u64 cookie) {
  struct pbuf p;
  p_init(&p);
  p_u32(&p, 0x00400000); /* strict mode policy: STRICT_MODE_PENALTY_GATHER, as libbinder sends */
  p_str16(&p, ISERVICEMANAGER_DESC);
  p_str16(&p, name);
  p_fbo(&p, ptr, cookie);
  p_u32(&p, 0); /* allowIsolated */
  p_u32(&p, 0); /* dumpsysPriority */
  logbegin("addService(\"");
  logstr(name);
  logstr("\"): ");
  lognum((long)p.len);
  logstr(" bytes, object at +");
  lognum((long)p.offs[0]);
  logflush();
  return binder_transact(fd, &p, 0, BC_TRANSACTION, ADD_SERVICE_TRANSACTION, 1, TF_ACCEPT_FDS);
}

static int check_service(int fd, const char *name) {
  struct pbuf p;
  int sz;
  p_init(&p);
  p_u32(&p, 0x00400000);
  p_str16(&p, ISERVICEMANAGER_DESC);
  p_str16(&p, name);
  logbegin("checkService(\"");
  logstr(name);
  logstr("\"):");
  logflush();
  last_handle = 0;
  sz = binder_transact(fd, &p, 0, BC_TRANSACTION, CHECK_SERVICE_TRANSACTION, 1, TF_ACCEPT_FDS);
  /* A handle to the service is a flat_binder_object; fewer than 24 bytes means the name is not
   * there (the servicemanager answers a bare status word). */
  return sz >= 24;
}

/* ----------------------------------------------------------------------------- the services ---- */
/* The driver hands the node's cookie back with every transaction, so one process can serve several
 * names: this is what tells them apart. */
#define COOKIE_PERMISSION 0x5e12u
#define COOKIE_APPOPS 0x5ea2u
#define COOKIE_ACTIVITY 0x5e32u
#define COOKIE_PROCESSINFO 0x5e42u
#define COOKIE_SCHEDULING_POLICY 0x5e52u

/* What the runner registers, by name: the node pointer has to be unique per name (it is the
 * driver's key for the node) and the cookie is what comes back with every transaction. */
static const struct {
  const char *name;
  u64 ptr;
  u64 cookie;
} service_table[] = {
    {"permission", 0x5e11, COOKIE_PERMISSION},
    {"appops", 0x5e21, COOKIE_APPOPS},
    {"activity", 0x5e31, COOKIE_ACTIVITY},
    {"processinfo", 0x5e41, COOKIE_PROCESSINFO},
    {"scheduling_policy", 0x5e51, COOKIE_SCHEDULING_POLICY},
    {0, 0, 0},
};

static const char *service_name(u64 cookie) {
  if ((u32)cookie == COOKIE_PERMISSION)
    return "permission";
  if ((u32)cookie == COOKIE_APPOPS)
    return "appops";
  if ((u32)cookie == COOKIE_ACTIVITY)
    return "activity";
  if ((u32)cookie == COOKIE_PROCESSINFO)
    return "processinfo";
  if ((u32)cookie == COOKIE_SCHEDULING_POLICY)
    return "scheduling_policy";
  return "?";
}

/* Every transaction's arguments start two fields in. `data.writeInterfaceToken()` in libbinder
 * writes the caller's strict-mode policy word and then the interface name, before the method's own
 * arguments, so the first argument is at the end of the second string16 -- reading from offset 0
 * gets the interface name and reports it as an argument, which is how the first version of this
 * log managed to print "permission=android.os.IPermissionController" for a request that was
 * actually asking about android.permission.CAMERA.
 *
 * The 140-byte real example, from this device: 4 strict + 4+64+2 (32 chars, padded to 72)
 * + 4+50+2 (25 chars) + 4 pid + 4 uid. */
static u64 str16_end(const u8 *d, u64 off, u64 len) {
  u64 n;
  if (off + 4 > len)
    return len;
  n = *(const u32 *)(const void *)(d + off);
  if (n > (len - off) / 2)
    return len; /* not a string16 -- do not walk off the end */
  return off + 4 + ((n * 2 + 2 + 3) & ~3ULL);
}

/* Offset of the first argument, or 0 if the parcel is too short to have one. */
static u64 args_start(const u8 *d, u64 len) {
  u64 end;
  if (len < 8)
    return len; /* nothing: every read below is guarded by len */
  end = str16_end(d, 4, len);
  return end <= len ? end : len;
}

/* android.os.IPermissionController (frameworks/native/libs/binder/IPermissionController.cpp):
 * 1 CHECK_PERMISSION(String16, int32, int32)   2 NOTE_OP(String16, int32, String16)
 * 3 GET_PACKAGES_FOR_UID(int32)                4 IS_RUNTIME_PERMISSION(String16)
 * 5 GET_PACKAGE_UID(String16, int32)
 * Every reply is writeNoException() and then the method's result (the caller already put that word
 * in the reply buffer). */
static void serve_permission(u32 code, const u8 *d, u64 len, struct pbuf *p) {
  u64 o = args_start(d, len);
  logbegin("permission: method ");
  lognum((long)code);
  if (code == 1 || code == 4) {
    u64 str_end = str16_end(d, o, len);
    logstr(" permission=");
    logutf16(d + o, 48);
    if (code == 1 && len >= str_end + 8) {
      logstr(" pid=");
      lognum((long)*(const u32 *)(const void *)(d + str_end));
      logstr(" uid=");
      lognum((long)*(const u32 *)(const void *)(d + str_end + 4));
    }
    logflush();
    p_u32(p, 1); /* true */
    return;
  }
  if (code == 2) {
    logstr(" op=");
    logutf16(d + o, 48);
    logflush();
    p_u32(p, 0); /* MODE_ALLOWED */
    return;
  }
  if (code == 3) {
    logstr(" uid=");
    lognum((long)*(const u32 *)(const void *)(d + o));
    logflush();
    p_u32(p, 1);
    p_str16(p, "hybris");
    return;
  }
  logstr(" (unimplemented)");
  logflush();
  p_u32(p, 0);
}

/* android.app.IAppOpsService, in AIDL declaration order:
 *  1 checkOperation(int code, int uid, String packageName, String attributionTag)
 *  2 noteOperation(int code, int uid, String packageName, String attributionTag)
 *  3 startOperation(IBinder token, int code, int uid, String packageName, ...)
 *  4 finishOperation(IBinder token, int code, int uid, String packageName, ...)
 *  5 startWatchingMode(int op, String packageName, IAppOpsCallback callback)
 *  6 stopWatchingMode(IAppOpsCallback callback)
 *  7 getToken(IBinder clientToken)
 *  8 permissionToOpCode(String permission)
 * The code numbers are reported as they arrive, so a mismatch with the running cameraserver shows up
 * in the log instead of being silently wrong. */
static void serve_appops(u32 code, const u8 *d, u64 len, struct pbuf *p) {
  u64 o = args_start(d, len);
  logbegin("appops: method ");
  lognum((long)code);
  logstr(" size ");
  lognum((long)len);
  if ((code == 1 || code == 2) && len >= o + 8) {
    logstr(" code=");
    lognum((long)*(const u32 *)(const void *)(d + o));
    logstr(" uid=");
    lognum((long)*(const u32 *)(const void *)(d + o + 4));
  }
  logflush();
  if (code == 7) { /* getToken -> an IBinder of our own */
    p_fbo(p, 0x5e21, 0x5e22);
    return;
  }
  if (code == 1 || code == 2 || code == 3 || code == 8) {
    p_u32(p, 0); /* MODE_ALLOWED */
    return;
  }
  /* void methods: writeNoException() is already the whole reply */
}

/* Send a reply and release the incoming buffer. Not freeing it would leak this process's binder
 * buffer one transaction at a time until the service stopped answering -- which, for a service that
 * cameraserver polls, would look like the same hang all over again. */
/* Send a reply and release the incoming buffer. Not freeing it would leak this process's binder
 * buffer one transaction at a time until the service stopped answering -- which, for a service that
 * cameraserver polls, would look like the same hang all over again.
 *
 * Both ioctls are write-only, and that is not a detail: `BINDER_WRITE_READ` reads as well when
 * read_size is non-zero, and anything it reads lands in a buffer local to this function, which
 * would then be thrown away. That is a lost transaction -- the driver has delivered it to
 * userspace, so the main loop will never see it, and the caller waits for a reply that cannot come.
 * The first version of this file passed a 256-byte read buffer to both calls, and the device showed
 * exactly that: cameraserver's checkPermission was sitting in this process's todo list, unanswered,
 * while the process blocked in binder_thread_read. Reads belong to the main loop, so read_size is 0
 * here and every command is parsed in one place. */
static void send_reply(int fd, const struct binder_transaction_data *in, struct pbuf *p) {
  u8 wbuf[8 + sizeof(struct binder_transaction_data)];
  struct binder_write_read bwr;
  struct binder_transaction_data tr;
  u64 i;

  tr.target.ptr = 0;
  tr.cookie = 0;
  tr.code = 0;
  tr.flags = 0;
  tr.sender_pid = 0;
  tr.sender_euid = 0;
  tr.data_size = p->len;
  tr.offsets_size = (u64)p->noffs * sizeof(u64);
  tr.data.ptr.buffer = (u64)(unsigned long)p->d;
  tr.data.ptr.offsets = (u64)(unsigned long)p->offs;

  *(u32 *)(void *)wbuf = BC_REPLY;
  copy_bytes(wbuf + 4, &tr, sizeof(tr));
  for (i = 0; i < sizeof(bwr); i++)
    ((u8 *)(void *)&bwr)[i] = 0;
  bwr.write_size = 4 + sizeof(tr);
  bwr.write_buffer = (u64)(unsigned long)wbuf;
  sys_ioctl(fd, BINDER_WRITE_READ, &bwr);

  free_buffer(fd, in->data.ptr.buffer);
}

static void answer(int fd, const struct binder_transaction_data *tr, const u8 *d, u64 len) {
  struct pbuf p;
  u32 cookie = (u32)tr->cookie;

  p_init(&p);
  p_u32(&p, 0); /* writeNoException() */

  if (tr->code == PING_TRANSACTION) {
    /* an empty reply is the whole answer */
  } else if (tr->code == INTERFACE_TRANSACTION) {
    p_str16(&p, cookie == COOKIE_APPOPS      ? "android.app.IAppOpsService"
               : cookie == COOKIE_ACTIVITY   ? IACTIVITYMANAGER_DESC
               : cookie == COOKIE_PROCESSINFO ? IPROCESSINFOSERVICE_DESC
               : cookie == COOKIE_SCHEDULING_POLICY ? ISCHEDULINGPOLICYSERVICE_DESC
                                             : "android.os.IPermissionController");
  } else if (tr->code == DUMP_TRANSACTION) {
    p_u32(&p, 0);
  } else if (cookie == COOKIE_PERMISSION) {
    serve_permission(tr->code, d, len, &p);
  } else if (cookie == COOKIE_APPOPS) {
    serve_appops(tr->code, d, len, &p);
  } else if (cookie == COOKIE_ACTIVITY) {
    serve_activity(tr->code, d, len, &p);
  } else if (cookie == COOKIE_PROCESSINFO) {
    serve_processinfo(tr->code, d, len, &p);
  } else if (cookie == COOKIE_SCHEDULING_POLICY) {
    serve_scheduling_policy(tr->code, d, len, &p);
  } else {
    logbegin("transaction for an unknown cookie ");
    loghex(cookie);
    logstr(" code ");
    lognum((long)tr->code);
    logflush();
  }

  /* A one-way transaction has nobody waiting for a reply, and the driver rejects BC_REPLY on one
   * ("BC_REPLY with no pending transaction"). The buffer still has to be freed. */
  if (tr->flags & TF_ONE_WAY) {
    logbegin(service_name(cookie));
    logstr(": one-way, so no reply is sent");
    logflush();
    free_buffer(fd, tr->data.ptr.buffer);
    return;
  }

  send_reply(fd, tr, &p);
}

/* android.app.IActivityManager, as much of it as the camera stack uses.
 *
 * Why a third service is needed, measured rather than guessed: the device showed cameraserver
 * polling the servicemanager 40 times a second for a name 8 characters long, and never finding it,
 * from a thread inside notifySystemEvent. "activity" is 8 characters, and libbinder has the code
 * that asks for it by name -- ActivityManager::getService (frameworks/native/libs/binder/
 * ActivityManager.cpp:33):
 *
 *   while (service == NULL || !IInterface::asBinder(service)->isBinderAlive()) {
 *       sp<IBinder> binder = defaultServiceManager()->checkService(String16("activity"));
 *       if (binder == NULL) {
 *           if (startTime == 0) ALOGI("Waiting for activity service");
 *           else if ((uptimeMillis() - startTime) > 1000000) { ALOGW("... giving up"); break; }
 *           usleep(25000);
 *       } else { service = interface_cast<IActivityManager>(binder); mService = service; }
 *   }
 *
 * -- a loop with no healthy exit: it gives up only after 1000 seconds, and then the caller gets
 * NULL. The caller here is CameraUidPolicy::registerSelf(), which notifySystemEvent calls *before*
 * doUserSwitch -- so with nothing answering to "activity", the user-switch event that would let a
 * client connect never gets applied, and every connect stays rejected however many permissions are
 * answered. (Ping is what makes isBinderAlive() true, which is why answer() handles PING for every
 * name and not just this one.)
 *
 * Answering it is deliberately generic. Everything it is asked is either void or a question whose
 * safe answer is 0, and the reply shape for an AIDL method whose result is not read is
 * writeNoException() and nothing else -- a client that reads an int past the end of the reply gets
 * 0 from Parcel, not a crash. What is logged is the method code, so what the camera stack actually
 * asks for is on the record. */
static void serve_activity(u32 code, const u8 *d, u64 len, struct pbuf *p) {
  u64 o = args_start(d, len);
  logbegin("activity: method ");
  lognum((long)code);
  logstr(" size ");
  lognum((long)len);
  if (code == 0) { /* nothing declared takes code 0; anything here would be a misread */
    logstr(" (code 0)");
  }
  /* isUidActive(uid, package) and a handful of others ask a yes/no question. Nothing in this
   * container has an application model, so "yes" is the answer that lets work proceed, and it is
   * the same answer CameraUidPolicy itself gives for a system uid (uid < AID_APP_START). */
  if (code == IACTIVITYMANAGER_IS_UID_ACTIVE) {
    logstr(" uid=");
    lognum((long)*(const u32 *)(const void *)(d + o));
    logflush();
    p_u32(p, 1);
    return;
  }
  if (code == IACTIVITYMANAGER_REGISTER_UID_OBSERVER) {
    logstr(" (registerUidObserver: a uid observer of theirs, which this container will never "
           "call back -- nothing here changes uid state)");
  }
  logflush();
  p_u32(p, 0);
}

/* android.os.IProcessInfoService (see the constants at the top for why the camera needs it).
 * `pids` is an int[] in, so it arrives as a count and then the pids; both replies are arrays in the
 * same shape, one per requested pid. */
static void serve_processinfo(u32 code, const u8 *d, u64 len, struct pbuf *p) {
  u64 o = args_start(d, len);
  u32 n = 0;
  u32 i;
  int want_scores = (code == IPROCESSINFOSERVICE_GET_STATES_AND_SCORES);

  if (len >= o + 4)
    n = *(const u32 *)(const void *)(d + o);
  if (n > 256)
    n = 256; /* a paranoid bound: the reply is written into a fixed buffer */

  logbegin("processinfo: method ");
  lognum((long)code);
  logstr(" size ");
  lognum((long)len);
  logstr(" pids=");
  lognum((long)n);
  for (i = 0; i < n && len >= o + 8 + 4 * i; i++) {
    logstr(" ");
    lognum((long)*(const u32 *)(const void *)(d + o + 4 + 4 * i));
  }
  logflush();

  p_u32(p, n);
  for (i = 0; i < n; i++)
    p_u32(p, PROCESS_STATE_TOP);
  if (want_scores) {
    p_u32(p, n);
    for (i = 0; i < n; i++)
      p_u32(p, 0); /* an oom score of 0: the most important process there is */
  }
}

/* android.os.ISchedulingPolicyService -- see the header for why the camera needs this one and how
 * it was found. The call that matters is made from Camera3Device::configureStreamsLocked, so a
 * client's startPreview() is blocked until this answers.
 *
 * requestPriority(pid, tid, prio, isForApp) is answered by doing what the service is for: the
 * SCHED_FIFO boost is applied to the thread it names. The real service checks first that the caller
 * is allowed to touch that thread (frameworks/native/services/schedulerservice checks the uid); the
 * one caller here is cameraserver and the thread is cameraserver's own request thread, so the only
 * question left is whether the syscall itself works, and the answer is logged rather than assumed.
 * The reply is OK either way: the boost is best effort, a refusal costs a warning in cameraserver's
 * log and nothing else, and withholding the reply would put the client back where it was. */
static void serve_scheduling_policy(u32 code, const u8 *d, u64 len, struct pbuf *p) {
  u64 o = args_start(d, len);
  logbegin("scheduling_policy: method ");
  lognum((long)code);

  if (code == ISCHEDULINGPOLICY_REQUEST_PRIORITY) {
    u32 pid = 0, tid = 0, prio = 0, is_for_app = 0;
    int param;
    long rc;
    if (len >= o + 4)
      pid = *(const u32 *)(const void *)(d + o);
    if (len >= o + 8)
      tid = *(const u32 *)(const void *)(d + o + 4);
    if (len >= o + 12)
      prio = *(const u32 *)(const void *)(d + o + 8);
    if (len >= o + 16)
      is_for_app = *(const u32 *)(const void *)(d + o + 12);
    logstr(" requestPriority pid=");
    lognum((long)pid);
    logstr(" tid=");
    lognum((long)tid);
    logstr(" prio=");
    lognum((long)prio);
    logstr(" isForApp=");
    lognum((long)is_for_app);
    logstr(": ");
    /* struct sched_param is a bare int in the aarch64 uapi, and the tid is this namespace's, which
     * is the caller's too: this program runs inside the container. */
    param = (int)prio;
    rc = sys6(SYS_sched_setscheduler, (long)(int)tid, SCHED_FIFO, (long)(unsigned long)&param, 0, 0,
              0);
    if (rc == 0) {
      logstr("SCHED_FIFO set");
    } else {
      logstr("sched_setscheduler refused, rc=");
      lognum(rc);
    }
    logflush();
    p_u32(p, 0);
    return;
  }

  if (code == ISCHEDULINGPOLICY_REQUEST_CPUSET_BOOST) {
    /* Nothing in the camera path asks for this (ResourceManagerService does), there is no cpuset
     * policy in this container, and there is nothing to move either way. */
    logstr(" requestCpusetBoost: no cpuset policy here, replied OK");
    logflush();
    p_u32(p, 0);
    return;
  }

  logstr(" (no such method, replied OK)");
  logflush();
  p_u32(p, 0);
}

/* ------------------------------------------------------------------- the camera user switch ---- */
/* Tell cameraserver which device users may connect, which is the one thing it would otherwise have
 * learned from system_server (see the header). Sent as a client over the same /dev/binder fd, to
 * the handle checkService("media.camera") just returned.
 *
 * The parcel is what BpCameraService::notifySystemEvent writes: strict-mode word, interface name,
 * int eventId, then the int[] as a count and its elements.
 *
 * It is oneway, so nothing is read back -- and if cameraserver's handler blocks or dies, that is a
 * camera thread, not this process. Note what EVENT_USER_SWITCHED does first:
 * mUidPolicy->registerSelf(), which asks ActivityManager for UID policy callbacks and has no
 * ActivityManager to ask here. There is nothing to be done about that from outside; if it turns
 * out to block, it blocks a thread of cameraserver's, and the device log will say so. */
static int notify_user_switch(int fd) {
  struct pbuf p;
  int sz;
  logbegin("notifySystemEvent(EVENT_USER_SWITCHED, {0}) to \"");
  logstr(CAMERA_SERVICE_NAME);
  logstr("\": ");
  logflush();

  if (!check_service(fd, CAMERA_SERVICE_NAME)) {
    logbegin("  no such service -- cameraserver is not up; try again once it is");
    logflush();
    return -1;
  }
  if (last_handle == 0) {
    logbegin("  it answered with a local object, not a handle: not something to transact with");
    logflush();
    return -1;
  }

  p_init(&p);
  p_u32(&p, 0x00400000); /* strict mode policy */
  p_str16(&p, ICAMERASERVICE_DESC);
  p_u32(&p, ICAMERASERVICE_EVENT_USER_SWITCHED);
  p_u32(&p, 1); /* int[] args: one element */
  p_u32(&p, 0); /* args[0] = user 0, the only user this container has */
  sz = binder_transact(fd, &p, last_handle, BC_TRANSACTION, ICAMERASERVICE_NOTIFY_SYSTEM_EVENT, 0,
                       TF_ACCEPT_FDS | TF_ONE_WAY);
  logbegin(sz < 0 ? "  the transaction could not be sent" : "  sent (oneway)");
  logflush();
  return sz;
}

/* ------------------------------------------------------------------------------- main loop ----- */
static int binder_open(void) {
  int fd = sys_open("/dev/binder", 2 /* O_RDWR */, 0);
  void *m;
  if (fd < 0) {
    logbegin("open(/dev/binder) failed");
    logflush();
    return -1;
  }
  /* PROT_READ + MAP_PRIVATE only: binder_mmap rejects a writable or shared mapping. */
  m = sys_mmap((void *)0, 128 * 1024, 1 /*PROT_READ*/, 2 /*MAP_PRIVATE*/, fd, 0);
  if (m == (void *)-1) {
    logbegin("mmap of the binder buffer failed");
    logflush();
    sys_close(fd);
    return -1;
  }
  return fd;
}

static int streq(const char *a, const char *b) {
  while (*a && *a == *b) {
    a++;
    b++;
  }
  return *a == *b;
}

int service_stub_main(int argc, char **argv) {
  int fd;
  int i;
  u8 wbuf[8];
  u8 rbuf[2048];
  struct binder_write_read bwr;
  u64 k;

  logbegin("starting, ");
  lognum((long)argc - 1);
  logstr(" service name(s) requested");
  logflush();

  fd = binder_open();
  if (fd < 0)
    return 1;

  /* One-shot mode: re-send only the user-switch event, for when cameraserver has been restarted
   * and came back with an empty mAllowedUsers. */
  if (argc >= 2 && streq(argv[1], "--notify-user-switch")) {
    logbegin("(one-shot)");
    logflush();
    return notify_user_switch(fd) < 0 ? 1 : 0;
  }

  /* BC_ENTER_LOOPER, which IPCThreadState::joinThreadPool sends before waiting for work. */
  *(u32 *)(void *)wbuf = BC_ENTER_LOOPER;
  for (k = 0; k < sizeof(bwr); k++)
    ((u8 *)(void *)&bwr)[k] = 0;
  bwr.write_size = 4;
  bwr.write_buffer = (u64)(unsigned long)wbuf;
  bwr.read_size = sizeof(rbuf);
  bwr.read_buffer = (u64)(unsigned long)rbuf;
  sys_ioctl(fd, BINDER_WRITE_READ, &bwr);

  for (i = 1; i < argc && i < 8; i++) {
    int t;
    for (t = 0; service_table[t].name; t++)
      if (streq(argv[i], service_table[t].name))
        break;
    if (!service_table[t].name) {
      logbegin("no such service in the table: \"");
      logstr(argv[i]);
      logstr("\" (want one of permission, appops, activity, processinfo, scheduling_policy)");
      logflush();
      continue;
    }
    logbegin("registering \"");
    logstr(argv[i]);
    logstr("\" as node ");
    loghex(service_table[t].ptr);
    logstr(" cookie ");
    loghex(service_table[t].cookie);
    logflush();
    add_service(fd, argv[i], service_table[t].ptr, service_table[t].cookie);
    logbegin(check_service(fd, argv[i]) ? "  -> the name resolves"
                                        : "  -> the name does NOT resolve");
    logflush();
  }

  /* Last, because a connect() that is already in flight has finished with all of this by now, and
   * because the event wants the two names to exist: cameraserver's handler for it may ask. */
  notify_user_switch(fd);

  logbegin("entering the loop");
  logflush();

  for (;;) {
    for (k = 0; k < sizeof(bwr); k++)
      ((u8 *)(void *)&bwr)[k] = 0;
    bwr.read_size = sizeof(rbuf);
    bwr.read_buffer = (u64)(unsigned long)rbuf;
    if (sys_ioctl(fd, BINDER_WRITE_READ, &bwr) < 0) {
      logbegin("the binder read failed");
      logflush();
      return 1;
    }
    for (k = 0; k + 4 <= bwr.read_consumed;) {
      u32 cmd;
      while (k & 3)
        k++;
      if (k + 4 > bwr.read_consumed)
        break;
      cmd = *(u32 *)(void *)(rbuf + k);
      k += 4;
      if (BR_IS(cmd, BR_TRANSACTION_NR)) {
        struct binder_transaction_data *tr = (struct binder_transaction_data *)(void *)(rbuf + k);
        logbegin("transaction for ");
        logstr(service_name(tr->cookie));
        logstr(" code ");
        lognum((long)tr->code);
        logstr(" size ");
        lognum((long)tr->data_size);
        logstr(" from pid ");
        lognum((long)tr->sender_pid);
        logstr(" uid ");
        lognum((long)tr->sender_euid);
        logflush();
        if (tr->data.ptr.buffer)
          answer(fd, tr, (const u8 *)(unsigned long)tr->data.ptr.buffer, tr->data_size);
        k += sizeof(struct binder_transaction_data);
      } else if (BR_IS(cmd, BR_DEAD_BINDER_NR) ||
                 BR_IS(cmd, BR_CLEAR_DEATH_NOTIFICATION_DONE_NR)) {
        k += 8;
      } else if (BR_IS(cmd, BR_REPLY_NR)) {
        k += sizeof(struct binder_transaction_data);
      } else if (BR_IS(cmd, BR_NOOP_NR) || BR_IS(cmd, BR_TRANSACTION_COMPLETE_NR) ||
                 BR_IS(cmd, BR_SPAWN_LOOPER_NR)) {
        /* nothing to do */
      } else if (BR_IS(cmd, BR_FAILED_REPLY_NR) || BR_IS(cmd, BR_DEAD_REPLY_NR)) {
        /* A transaction we sent went nowhere: the target died, which is what happens to a client
         * that had one of these services in flight when the service was restarted. Its own caller
         * is told by the driver; there is nothing for this process to do. */
      } else {
        logbegin("ignoring command ");
        loghex(cmd);
        logflush();
      }
    }
  }
  return 0;
}

/* The process entry point: there is no libc here, so _start unpacks argc/argv from the stack the
 * kernel set up and calls the real main. */
__asm__(".text\n"
        ".globl _start\n"
        ".type _start,@function\n"
        "_start:\n"
        "  mov x29, #0\n"
        "  mov x30, #0\n"
        "  ldr x0, [sp]\n"
        "  add x1, sp, #8\n"
        "  bl service_stub_main\n"
        "  mov x8, #94\n" /* exit_group */
        "  svc #0\n"
        "  brk #0\n");
