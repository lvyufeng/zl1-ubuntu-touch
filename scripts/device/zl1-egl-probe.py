#!/usr/bin/env python3
"""Ask the zl1's EGL the only question that matters for a Qt app: who can give a display, and to whom?

Why this exists (docs/ubuntu-touch/80). The UT camera app dies with
    ASSERT: "(mEglDisplay = eglGetDisplay(mEglNativeDisplay)) != EGL_NO_DISPLAY"
        or  "eglInitialize(mEglDisplay, nullptr, nullptr) == EGL_TRUE"
in qtmir's ubuntumirclient plugin. strace of the app says why:

  openat("/usr/share/glvnd/egl_vendor.d/10_libhybris.json")  = 8
  openat("/lib/aarch64-linux-gnu/libEGL_libhybris.so.0")     = 8     <- hybris' EGL *is* read
  openat("/system/build.prop")                               = 8
  openat("/usr/lib/aarch64-linux-gnu/libhybris/linker/o.so") = 8
  openat("/usr/lib/aarch64-linux-gnu/libhybris/eglplatform_*.so")    <- never opened
  openat("/usr/share/glvnd/egl_vendor.d/50_mesa.json")       = 8
  openat("/lib/aarch64-linux-gnu/libEGL_mesa.so.0")          = 8     <- so glvnd went to Mesa
  openat("/dev/dri", O_DIRECTORY)                            = -1 ENOENT
  --- SIGABRT ---

i.e. glvnd (libEGL.so.1.1.0) read both vendor libraries, hybris' never reached its platform module,
and Mesa's — the one that *was* used — cannot work on this device at all: it wants /dev/dri and the
GPU here is kgsl (/dev/kgsl-3d0), not DRM.

The working shell does not go through glvnd for hybris: Mir's own platform plugins
(mir1/server-platform/graphics-android2.so, mir1/client-platform/android2.so) dlopen
libEGL_libhybris.so.0 themselves, which is why lomiri has libEGL_libhybris.so.0, libEGL_adreno.so
and /android/system/lib64/libEGL.so mapped, and the app has none of them.

This probe isolates the decision glvnd makes. It does, in order:
  1. dlopen libEGL_libhybris.so.0        -- what does the ICD actually export?
  2. dlopen libEGL.so.1, eglGetDisplay(EGL_DEFAULT_DISPLAY), eglInitialize
  3. mir_connect_sync + mir_connection_get_egl_native_display -- exactly what the QPA plugin does
  4. eglGetDisplay(<that value>) and eglGetDisplay(0) through glvnd, with eglInitialize for each

Step 3 is the measurement that decides the fix: if the native display is a non-zero pointer, glvnd has
to *recognise* it to route it to a vendor, and it does not -- so the fix is to make the value 0
(EGL_DEFAULT_DISPLAY), which takes glvnd's default-display path and tries the vendors in order
(10_libhybris before 50_mesa). If it is already 0, the theory is wrong and the answer is elsewhere.

Run it with scripts/device/zl1-camapp-launch.py, which supplies the running session's environment
(HYBRIS_LD_LIBRARY_PATH / HYBRIS_LINKER / MIR_SOCKET / DISPLAY / WAYLAND_DISPLAY):

  A=$(lxc-info -n android -pH); P=$(pgrep -x lomiri | head -1)
  for PL in "" null hwcomposer; do
    nsenter -t $A -p -- env ZL1_SET_EGL_PLATFORM=$PL \
      python3 zl1-camapp-launch.py /usr/bin/python3 zl1-egl-probe /tmp $P /tmp/zl1-egl-probe.py
  done

EGL_PLATFORM selects libhybris' own platform module
(/usr/lib/aarch64-linux-gnu/libhybris/eglplatform_{null,hwcomposer,wayland,fbdev}.so). There is no
mir module on this host.
"""
import ctypes
import os
import sys

EGL_VENDOR = 0x3053
EGL_VERSION = 0x3054
EGL_EXTENSIONS = 0x3055


def probe(lib_name, native_display):
    """dlopen lib_name, eglGetDisplay(native_display), eglInitialize. Print everything, never die."""
    try:
        lib = ctypes.CDLL(lib_name)
    except OSError as exc:
        print("  %-26s DLOPEN FAILED: %s" % (lib_name, exc))
        return None
    try:
        get_display = lib.eglGetDisplay
    except AttributeError:
        print("  %-26s loaded, but exports no eglGetDisplay -- it is a glvnd vendor ICD "
              "(entry point __egl_Main), not a full EGL" % lib_name)
        return None
    get_display.restype = ctypes.c_void_p
    get_display.argtypes = [ctypes.c_void_p]
    dpy = get_display(ctypes.c_void_p(native_display))
    what = "EGL_DEFAULT_DISPLAY" if native_display == 0 else hex(native_display)
    print("  %-26s eglGetDisplay(%s) = %s"
          % (lib_name, what, "EGL_NO_DISPLAY" if not dpy else hex(dpy)))
    if not dpy:
        return None
    lib.eglInitialize.restype = ctypes.c_uint
    lib.eglInitialize.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_int)]
    maj, mnr = ctypes.c_int(), ctypes.c_int()
    ok = lib.eglInitialize(ctypes.c_void_p(dpy), ctypes.byref(maj), ctypes.byref(mnr))
    print("  %-26s eglInitialize = %d (%d.%d)" % ("", ok, maj.value, mnr.value))
    if not ok:
        return None
    lib.eglQueryString.restype = ctypes.c_char_p
    lib.eglQueryString.argtypes = [ctypes.c_void_p, ctypes.c_uint]
    for name, enum in (("vendor", EGL_VENDOR), ("version", EGL_VERSION), ("extensions", EGL_EXTENSIONS)):
        text = (lib.eglQueryString(ctypes.c_void_p(dpy), enum) or b"").decode("utf-8", "replace")
        if name == "extensions":
            plats = sorted(p for p in text.split() if "platform" in p.lower())
            text = "%d stated; platform extensions: %s" % (len(text.split()), " ".join(plats) or "(none)")
        print("  %-26s %s = %s" % ("", name, text))
    return dpy


def mir_native_display():
    """What qtmir's ubuntumirclient plugin hands to eglGetDisplay. Returns the value, or None."""
    try:
        mir = ctypes.CDLL("libmir1client.so.9")
    except OSError as exc:
        print("  libmir1client.so.9 DLOPEN FAILED: %s" % exc)
        return None
    mir.mir_connect_sync.restype = ctypes.c_void_p
    mir.mir_connect_sync.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
    mir.mir_connection_is_valid.restype = ctypes.c_bool
    mir.mir_connection_is_valid.argtypes = [ctypes.c_void_p]
    mir.mir_connection_get_error_message.restype = ctypes.c_char_p
    mir.mir_connection_get_error_message.argtypes = [ctypes.c_void_p]
    mir.mir_connection_get_egl_native_display.restype = ctypes.c_void_p
    mir.mir_connection_get_egl_native_display.argtypes = [ctypes.c_void_p]

    conn = mir.mir_connect_sync(None, b"zl1-egl-probe")
    if not conn:
        print("  mir_connect_sync returned NULL")
        return None
    if not mir.mir_connection_is_valid(ctypes.c_void_p(conn)):
        print("  Mir connection INVALID: %s" % mir.mir_connection_get_error_message(ctypes.c_void_p(conn)))
        return None
    print("  Mir connection valid (MIR_SOCKET=%r)" % os.environ.get("MIR_SOCKET"))
    nd = mir.mir_connection_get_egl_native_display(ctypes.c_void_p(conn))
    print("  mir_connection_get_egl_native_display() = %s"
          % ("EGL_DEFAULT_DISPLAY (0)" if not nd else hex(nd)))
    return nd


print("EGL_PLATFORM=%r HYBRIS_LINKER=%r" % (os.environ.get("EGL_PLATFORM"), os.environ.get("HYBRIS_LINKER")))
print("HYBRIS_LD_LIBRARY_PATH=%s" % os.environ.get("HYBRIS_LD_LIBRARY_PATH"))
print("LD_PRELOAD=%s" % os.environ.get("LD_PRELOAD"))
print("DISPLAY=%r WAYLAND_DISPLAY=%r MIR_SOCKET=%r"
      % (os.environ.get("DISPLAY"), os.environ.get("WAYLAND_DISPLAY"), os.environ.get("MIR_SOCKET")))
print("-- what the glvnd vendor library for hybris actually is")
probe("libEGL_libhybris.so.0", 0)
print("-- the library Qt calls, through glvnd: default display")
probe("libEGL.so.1", 0)
print("-- the code path of qtmir's ubuntumirclient plugin, without Qt")
nd = mir_native_display()
print("-- eglGetDisplay(<the Mir native display>) through glvnd (what Qt does)")
probe("libEGL.so.1", nd or 0)
print("-- eglGetDisplay(EGL_DEFAULT_DISPLAY) through glvnd (what that same call becomes if it is 0)")
probe("libEGL.so.1", 0)
sys.exit(0)
