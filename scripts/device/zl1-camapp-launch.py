#!/usr/bin/env python3
"""Launch a UT app in the zl1's session, from the host, with the session's own environment.

Why a Python launcher and not a shell one-liner: the app has to run with *the running shell's*
environment (that is where the port's HYBRIS_LD_LIBRARY_PATH, LD_PRELOAD, QT_* and Mir settings
live, and hand-picking them from the outside got the EGL initialisation wrong), and /proc/<pid>/
environ is NUL-separated, which the device's /bin/sh (dash) cannot read without a quoting dance.
Python reads it as bytes, and then os.execvpe() gives the app exactly what the shell would have.

This must run inside the container's PID namespace (nsenter -t <container> -p -- ...), because the
camera path is Android binder (libcamera.so.1 -> libcamera_compat_layer.so -> cameraserver), and
binder does not cross PID namespaces.

Usage: zl1-camapp-launch.py <app-binary> <app-id> <app-dir> [shell-pid] [args...]

Environment: ZL1_SET_<NAME>=<value> exports <NAME> to the app on top of the session's environment;
ZL1_PRELOAD_EXTRA adds LD_PRELOAD entries.
"""
import os
import sys

binary, app_id, app_dir = sys.argv[1], sys.argv[2], sys.argv[3]
shell_pid = sys.argv[4] if len(sys.argv) > 4 else None
# Anything after the shell pid is passed through to the app, so this launcher can also run a
# diagnostic binary (the EGL probe) in the session's exact environment.
app_argv = [binary] + sys.argv[5:]

env = {}
if shell_pid:
    try:
        with open("/proc/%s/environ" % shell_pid, "rb") as fh:
            for kv in fh.read().split(b"\0"):
                if b"=" in kv:
                    k, v = kv.split(b"=", 1)
                    env[k.decode()] = v.decode()
    except OSError as exc:
        print("warning: could not read /proc/%s/environ: %s" % (shell_pid, exc), file=sys.stderr)

# The app is a Mir *client*, not the server: drop the server-side settings the shell carries and
# point the client at the same socket, and pick the QtMir client platform plugin.
for k in list(env):
    if k.startswith("MIR_SERVER_") or k == "QT_QPA_PLATFORM":
        del env[k]
env["MIR_SOCKET"] = env.get("MIR_SOCKET") or "/run/user/%s/mir_socket" % os.environ.get("ZL1_UID", "32011")
env["QT_QPA_PLATFORM"] = "ubuntumirclient"
env["APP_ID"] = app_id
env["APP_DIR"] = app_dir
# The click package's own libraries, and the desktop entry's Exec runs this wrapper first.
env["PATH"] = "%s/bin:%s" % (app_dir, env.get("PATH", "/usr/bin:/bin"))
# Explicit overrides from outside: any variable named ZL1_SET_<NAME>=<value> in this launcher's own
# environment is exported to the app as <NAME>=<value>, on top of the session's environment. This is
# how an experiment changes one variable (QT_QPA_PLATFORM, EGL_PLATFORM, WAYLAND_DISPLAY) without
# rebuilding the session's environment by hand -- which is what got the EGL initialisation wrong the
# first time.
for k, v in os.environ.items():
    if k.startswith("ZL1_SET_"):
        env[k[len("ZL1_SET_"):]] = v

# Optional extra preloads from outside (colon- or space-separated), appended to whatever the session
# already preloads. This is how the port's own instruments get in: libcfi-shadow-init.so (libcamera
# is built with cross-DSO CFI and hybris' dlopen does not prime the shadow) and crash-dump.so
# (turns the SIGSEGV into a backtrace plus /proc/self/maps instead of a bare "Segmentation fault").
extra = os.environ.get("ZL1_PRELOAD_EXTRA", "").replace(":", " ").split()
if extra:
    env["LD_PRELOAD"] = " ".join([env.get("LD_PRELOAD", "")] + extra).strip()

print("launching %s (APP_ID=%s) with %d environment variables from the session"
      % (binary, app_id, len(env)), file=sys.stderr)
sys.stderr.flush()
# The app resolves its own package directory from the *current directory* ("Camera app directory
# /root" when run from /root, followed by "file:///root/qml/camera-app.qml: No such file or
# directory"), so the launcher has to chdir into the package first.
os.chdir(app_dir)

# Drop to the session's own user, if asked (ZL1_AS_UID=<uid>). Root can read the running shell's
# environment, but it cannot *use* the session: /run/user/32011/bus belongs to user 32011 and the
# session bus rejects a peer whose uid does not match ("Error connecting to unix:path=/run/user/32011
# /bus: The connection is closed"), which is what killed the camera app after it had already
# enumerated both cameras. Reading the environment and the runtime dir has to happen as root first,
# which is why this is the last thing before exec.
as_uid = os.environ.get("ZL1_AS_UID")
if as_uid:
    import grp
    gid = int(os.environ.get("ZL1_AS_GID") or grp.getgrgid(int(as_uid)).gr_gid)
    os.setgroups([gid])
    os.setgid(gid)
    os.setuid(int(as_uid))
    print("dropped to uid %d gid %d" % (int(as_uid), gid), file=sys.stderr)

os.execvpe(binary, app_argv, env)
