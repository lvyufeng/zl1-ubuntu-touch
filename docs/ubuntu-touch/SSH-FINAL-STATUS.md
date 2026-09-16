# SSH Access - Final Investigation Status

## All Attempts Exhausted

### Attempt 1-3: Install to /mnt/rootfs/root/.ssh/
Result: FAILED - /root is bind-mounted from userdata at runtime

### Attempt 4: Install to /tmpmnt/root/.ssh/ (userdata)
Result: FAILED - Still permission denied despite correct location

## Possible Remaining Causes

1. **sshd_config restriction**: PermitRootLogin may be "no" or "prohibit-password"
2. **AppArmor/SELinux**: Blocking sshd from reading authorized_keys
3. **Ubuntu Touch security model**: May require phablet user login first
4. **File permissions in userdata**: May need specific ownership (phablet uid?)
5. **PAM restrictions**: Additional authentication requirements

## Alternative Access Methods

### Option A: Enable Password Authentication
Modify /etc/ssh/sshd_config in userdata:
```
PasswordAuthentication yes
```
Set root password in /etc/shadow

### Option B: Use Android ADB Shell
Since device runs Android base, try:
```bash
# Enable adbd on TCP
adb tcpip 5555
adb connect 10.15.19.82:5555
```

### Option C: Modify Status Server for Commands
Enhance the HTTP 8080 status server to accept commands via HTTP POST

### Option D: Serial Console
If available, access via serial console (USB or UART)

## Recommendation

Given time constraints and consistent SSH failures, **proceed with peripheral investigation using HTTP 8080 endpoint enhancements** rather than continuing to debug SSH.

The status server can be modified to:
- Execute commands and return output
- Read files and return contents  
- Provide detailed hardware information

This bypasses SSH entirely and uses the already-working HTTP channel.


---

## Root cause found (2026-09-16)

The failures above are explained. **`/root` is not persistent**, so no public key
placed under `/root/.ssh/` can ever take effect:

- The UT rootfs image's `/etc/system-image/writable-paths` has no `/root` entry, so
  `/root` is just the read-only rootfs's own directory. The running mounts do show
  `/dev/sda10 /root`, but that is a bind mount of a *different* path — and in any case
  nothing under it survives in the way `/root/.ssh/authorized_keys` needs.
- `/etc/ssh` **is** persistent (`/etc/ssh  auto  persistent  none  none`), and at runtime
  it really is a bind mount from userdata.
- `sshd_config` never sets `AuthorizedKeysFile`, so it uses the default
  `.ssh/authorized_keys` relative to the user's home — the one place that does not work.

`PasswordAuthentication=no` is set by
`/etc/ssh/sshd_config.d/50-lxc-android-config.conf`, and the server confirms it: the only
method offered is `publickey` (OpenSSH 9.6p1 Ubuntu-3ubuntu13.16).

**The fix for the next image:** set

```
AuthorizedKeysFile /etc/ssh/authorized_keys.d/%u
```

in the rootfs. `/etc/ssh` is already a persistent, writable bind mount, so keys placed
there survive reboots and can be updated without rebuilding the rootfs.

Verified on hardware 2026-09-16: the device does run sshd on port 22
(`LISTEN 0 128 0.0.0.0:22`), and it rejects the host key with
`Permission denied (publickey)` — consistent with the file simply not being at the path
sshd looks at. See [`21-stage2-first-cold-boot.md`](21-stage2-first-cold-boot.md) §5.
