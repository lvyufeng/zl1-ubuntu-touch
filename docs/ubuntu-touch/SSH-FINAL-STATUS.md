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

## Root cause found (2026-09-17)

Two things were wrong, and both had to be fixed.

**1. The key was written to a path that nothing reads.**

The June attempts (see `install-ssh-to-userdata.sh` above) wrote to
`/userdata/root/.ssh/authorized_keys`. But `/root` does not resolve there: the
writable-paths `auto` destination for a mount point lives under
`/userdata/system-data/`, so `/root` comes from `/userdata/system-data/root`.
The device still carries the stray copy at `/data/root/.ssh/` — it was never read.

**2. `AuthorizedKeysFile` is unset, so sshd looked in the wrong place anyway.**

The rootfs's `sshd_config` never sets `AuthorizedKeysFile`, so sshd uses its default,
`.ssh/authorized_keys` relative to the user's home. Combined with (1), the key could not
be found even once the file was in the right directory.

On top of both: `PasswordAuthentication=no` is set by
`/etc/ssh/sshd_config.d/50-lxc-android-config.conf`, and the server confirms it — the
only method offered is `publickey` (OpenSSH 9.6p1 Ubuntu-3ubuntu13.16). There is no
password fallback.

### The fix

Stop depending on which home directory root ends up with. `/etc/ssh` is a persistent
writable-path, bind-mounted from `/userdata/system-data/etc/ssh` — it holds the host keys
and the config, and it demonstrably survives reboots. So:

```
AuthorizedKeysFile /etc/ssh/authorized_keys.d/%u
```

applied to `/data/system-data/etc/ssh/sshd_config`, with the key at
`/etc/ssh/authorized_keys.d/root` (0644 root:root) and also in
`/data/system-data/root/.ssh/authorized_keys` (0600) as a second chance.

Script: [`scripts/fix-ssh-authorized-keys.sh`](../../scripts/fix-ssh-authorized-keys.sh)
(run from TWRP; idempotent). It is also folded into
[`scripts/twrp-one-shot-setup.sh`](../../scripts/twrp-one-shot-setup.sh).

Verified on hardware 2026-09-16 that the device does run sshd: port 22 is listening
(`LISTEN 0 128 0.0.0.0:22`) and it answered with the OpenSSH banner before rejecting the
key, which is consistent with the key simply not being at the path sshd looked at.
Whether the fix works has not been confirmed yet — the next boot will tell.
